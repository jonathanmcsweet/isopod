#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines copy-in, export, fetch, and identity remap.

cmd_copy_in() {
  local name="${1:-}"
  shift || true
  [ -n "$name" ] && [ $# -gt 0 ] || die "usage: isopod copy-in <name> <path>..."
  open_box "$name"
  do_copy_in "$name" "$@"
}

cmd_export() {
  local name="" dest="" gitignore=0
  local -a excludes=()
  while [ $# -gt 0 ]; do
    # accept --opt=value as an alias for --opt value (e.g. --exclude=node_modules)
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --exclude)
        [ -n "${2:-}" ] || die "export: --exclude needs a pattern"
        excludes+=("$2")
        shift 2
        ;;
      --gitignore | --exclude-vcs-ignores)
        gitignore=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option for export: $1" ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        elif [ -z "$dest" ]; then
          dest="$1"
        else die "unexpected argument: $1"; fi
        shift
        ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod export <name> [dest] [--exclude <pattern>]... [--gitignore]"
  open_box "$name"
  dest="${dest:-./isopod-$name-export}"
  [ -e "$dest" ] && die "destination already exists: $dest"

  # Optional filters, applied by the box-side tar so excluded trees are never
  # even read (no bandwidth, no 'file changed' churn). --gitignore honors the
  # box's .gitignore-style files (tar's --exclude-vcs-ignores); --exclude adds
  # explicit glob patterns, single-quoted via shq so the box shell can't expand
  # them before tar does. Both need GNU tar in the box (busybox lacks them).
  local -a tarx=()
  [ "$gitignore" -eq 1 ] && tarx+=(--exclude-vcs-ignores)
  local pat
  for pat in ${excludes[@]+"${excludes[@]}"}; do
    tarx+=("--exclude=$(shq "$pat")")
  done

  info "Copying $WORKSPACE out of the box to $dest ..."
  # Stream the workspace out as a tar archive (preserves mtimes/symlinks). The
  # box may be compromised, so treat its archive as untrusted on the host: drop
  # `-p` and pass --no-same-permissions explicitly (don't honor box-controlled
  # mode bits, incl. setuid/setgid — `-p` is the DEFAULT for a root extract, so
  # relying on its absence is not enough), and force ownership to the extracting
  # user with --no-same-owner. Modern GNU tar also refuses absolute paths / `..`;
  # bsdtar (macOS) differs, so we stay explicit.
  #
  # tar runs inside the LIVE box, so a file can change size/mtime between stat
  # and read (node_modules, a build dir, a lockfile). GNU tar then prints
  # 'file changed as we read it' and exits 1 — a warning, not a corrupt archive.
  # Under `set -o pipefail` a bare `| tar || die` turns that into a failure and
  # deletes the export, so inspect PIPESTATUS: abort only on a fatal box-side
  # error (exit >= 2) or a failed host extract. The warning lines are filtered on
  # the host, which works whatever tar the box ships (busybox lacks --warning).
  mkdir -p "$dest"
  local -a rc
  set +e
  box_tar_out "$name" "$WORKSPACE" ${tarx[@]+"${tarx[@]}"} 2> >(grep -v 'file changed as we read it' >&2) |
    tar -C "$dest" --no-same-owner --no-same-permissions -xf -
  rc=("${PIPESTATUS[@]}")
  set -e
  if [ "${rc[1]}" -ne 0 ] || [ "${rc[0]}" -gt 1 ]; then
    rm -rf "$dest"
    die "export failed (is '$name' running? try: isopod start $name)"
  fi
  [ "${rc[0]}" -eq 1 ] &&
    info "Some files changed while being read (a live workspace) — the copy is a point-in-time snapshot."
  info "Done: $dest"
}

# Pull the box's git history into a host repo. Every box is already a git SSH
# remote (dedicated key, pinned host key, loopback port), so for a git target we
# just `git fetch` straight from it into <name>/* tracking refs — no bundle, no
# temp files. For a non-git target we fall back to a portable .bundle file, the
# one thing plain git-over-SSH can't produce. The git-native counterpart to
# `isopod export` — clean history, no file merges.
cmd_fetch() {
  local name="" target="" inbox_path=""
  while [ $# -gt 0 ]; do
    # accept --opt=value as an alias for --opt value
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --path)
        inbox_path="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option for fetch: $1" ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        elif [ -z "$target" ]; then
          target="$1"
        else die "unexpected argument: $1"; fi
        shift
        ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod fetch <name> [target-repo-dir] [--path <in-box-repo>]"
  require_box "$name"
  have git || die "git is required on the host for 'isopod fetch'"
  detect_engine "$(meta_get "$name" engine || true)"
  acquire_lock # refresh_port may rewrite the shared ssh_config
  refresh_port "$name"
  target="${target:-.}"

  # Locate the git repo inside the box: $WORKSPACE itself, or — if the workspace
  # holds a single git subfolder (e.g. a repo cloned into a named dir) — that one.
  # A box may hold more than one repo (multiple --repo clones), so when the
  # choice is ambiguous we list the repos and ask for --path. lib/find_box_repo.sh
  # runs the probe; stream it into the box over SSH (sh -s reads it from stdin, so
  # the remote shell never re-parses it) and pass $WORKSPACE in as an env var.
  local repo="$inbox_path"
  if [ -z "$repo" ]; then
    local finder="$ISOPOD_LIB/find_box_repo.sh"
    [ -f "$finder" ] || die "missing helper: $finder (is your isopod install complete?)"
    repo=$(box_ssh "$name" -- WORKSPACE="$WORKSPACE" sh -s 2>/dev/null <"$finder") || repo=""
    if [ -z "$repo" ]; then
      # No repo, or more than one — enumerate what's there so the user can pick.
      local repolist
      repolist=$(box_ssh "$name" -- WORKSPACE="$WORKSPACE" LIST_ALL=1 sh -s 2>/dev/null <"$finder") || repolist=""
      # $repolist is box-controlled text going straight to the host terminal.
      [ -n "$repolist" ] &&
        die "more than one repo in the box under $WORKSPACE — pick one with --path <in-box-repo>:
$(printf '%s\n' "$(sanitize "$repolist")" | sed 's/^/    /')"
      die "no git repo found in the box under $WORKSPACE — pass --path <in-box-repo>"
    fi
  fi

  if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Target is a git repo: fetch straight from the box over SSH into <name>/*.
    # The repo-detection above already proved the box is up, so re-pin its host
    # key for the current port — keeps known_hosts valid if it changed ports.
    local top port key kh
    scan_host_key "$name" >/dev/null || true # keeps stderr: a key-change warning must show
    top=$(git -C "$target" rev-parse --show-toplevel)
    port=$(meta_get "$name" port)
    key="$(box_dir "$name")/id_ed25519"
    kh="$(box_dir "$name")/known_hosts"
    info "Fetching history into $top as '$name/*' (over SSH)..."

    # Force-update the box's tracking refs (leading '+'), exactly as a normal
    # remote's '+refs/heads/*:refs/remotes/origin/*' does. Without it, a re-fetch
    # after the box's history was rewritten — e.g. by 'isopod remap', which gives
    # commits new SHAs — is rejected as non-fast-forward. These refs are a mirror
    # namespace isopod owns; the host's own branches (refs/heads/*) are untouched.
    # GIT_SSH_COMMAND pins the box's key/port/host key, mirroring box_ssh.
    GIT_SSH_COMMAND="ssh -p $port -i '$key' -o IdentitiesOnly=yes -o UserKnownHostsFile='$kh' -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ForwardX11=no" \
      git -C "$target" fetch --no-tags "$CONTAINER_USER@127.0.0.1:$repo" \
      "+refs/heads/*:refs/remotes/$name/*" ||
      die "git fetch from the box over SSH failed (is '$name' running? try: isopod start $name)"
    info "Done. Box branches are now available as:"
    # Branch names originate in the box, so strip control characters on the way out.
    git -C "$target" branch -r --list "$name/*" |
      LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/    /'
    printf '\nCheck one out with:\n  git -C %s switch -c <branch> %s/<branch>\n' "$top" "$name"
  else
    # Target is not a git repo: drop a portable bundle for manual use — the one
    # artifact git-over-SSH can't produce. Stream it straight out of the box to
    # stdout (no temp file, no cp), so it works under any runtime. `git bundle
    # create -` (stdout) needs git >= 2.36 in the box; the default base has it,
    # so this only matters for an unusually old custom --dockerfile base.
    local out="$target"
    [ "$out" = "." ] && out="./isopod-$name.bundle"
    [ -d "$out" ] && out="${out%/}/isopod-$name.bundle"
    [ -e "$out" ] && die "destination already exists: $out (remove it or pick another path)"
    info "Bundling $repo inside the box..."
    # HEAD is included so `git clone <bundle>` checks out the box's current
    # branch instead of failing to resolve a remote HEAD.
    box_ssh "$name" -- git -C "$repo" bundle create - HEAD --branches --tags >"$out" || {
      rm -f "$out"
      die "git bundle failed in the box (does $repo have any commits?)"
    }
    info "'$target' is not a git repo — wrote a bundle instead: $out"
    printf '\nUse it from any clone:\n  git -C /path/to/clone fetch %s "refs/heads/*:refs/remotes/%s/*"\nor create a fresh repo from it:\n  git clone %s my-%s\n' "$out" "$name" "$out" "$name"
  fi
}

# Identity fields that are safe to write into a git mailmap. A mailmap is
# line-oriented and field-delimited by '<' '>', so any value placed in one must
# carry neither a line break nor an angle bracket, or it can forge additional
# rewrite rules. Deliberately permissive about the rest of the character set —
# the job here is structural safety, not RFC 5322 conformance, and rejecting a
# legitimate-but-unusual address would be its own bug.
valid_ident_email() { # valid_ident_email <value>
  case "$1" in
    '' | *[$'\n\r<>']* | *' '*) return 1 ;;
  esac
  [ "$1" != "${1#*@}" ] # must contain an '@' to be an address at all
}
# Same structural rule for the NAME half, which may contain spaces.
valid_ident_name() { # valid_ident_name <value>
  case "$1" in
    *[$'\n\r<>']*) return 1 ;;
  esac
  return 0
}

# Split an identity token into a name line and an email line (in that order).
# Accepts "Name <email>", "<email>", a bare "email", or a bare "Name"; either
# field may be empty. Two lines are emitted (not a tab-joined pair) so an empty
# leading name is read back faithfully — `read` would trim a leading tab.
parse_ident() {
  local s="$1" nm="" em=""
  s="${s#"${s%%[![:space:]]*}"}" # ltrim
  s="${s%"${s##*[![:space:]]}"}" # rtrim
  if [[ "$s" == *"<"*">"* ]]; then
    em="${s#*<}"
    em="${em%%>*}"
    nm="${s%%<*}"
    nm="${nm%"${nm##*[![:space:]]}"}" # rtrim the name part
  elif [[ "$s" == *@* && "$s" != *[[:space:]]* ]]; then
    em="$s" # looks like a bare email
  else
    nm="$s"
  fi
  printf '%s\n%s\n' "$nm" "$em"
}

# Translate isopod's 'old -> new' remap file into a git mailmap (which both
# rewrite backends consume). Each non-blank, non-comment line is
# "OLD -> NEW", where OLD must carry an <email> to match on and NEW supplies
# the replacement name and/or <email>. Errors point at the offending line.
remap_to_mailmap() {
  local src="$1" dst="$2" line lineno=0 old new on oe nn ne
  : >"$dst"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"                    # tolerate CRLF line endings
    line="${line#"${line%%[![:space:]]*}"}" # ltrim for the comment/blank test
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *'->'*) ;; *) die "remap file $src line $lineno: expected 'old -> new'" ;; esac
    old="${line%%->*}"
    new="${line#*->}"
    {
      read -r on
      read -r oe
    } < <(parse_ident "$old")
    {
      read -r nn
      read -r ne
    } < <(parse_ident "$new")
    [ -n "$oe" ] || die "remap file $src line $lineno: left side needs an <email> to match"
    [ -n "$nn$ne" ] || die "remap file $src line $lineno: right side needs a name and/or <email>"
    [ -n "$ne" ] || ne="$oe" # rename-only: keep the existing email
    # mailmap line: [new-name] <new-email> [old-name] <old-email>
    {
      [ -n "$nn" ] && printf '%s ' "$nn"
      printf '<%s> ' "$ne"
      [ -n "$on" ] && printf '%s ' "$on"
      printf '<%s>\n' "$oe"
    } >>"$dst"
  done <"$src"
  [ -s "$dst" ] || die "remap file $src has no mappings"
}

# Rewrite the author/committer identity on the commits a box contributed, AFTER
# `isopod fetch` has imported them as refs/remotes/<name>/* tracking refs. Only
# commits whose existing identity matches --old-email (optionally --old-name)
# are touched; commit messages and author/committer DATES are preserved. The
# rewrite is scoped to the box's refs, so the host's own branches are untouched.
# Prefers `git filter-repo`; falls back to the built-in `git filter-branch`.
cmd_remap() {
  local name="" target="" new_name="" new_email="" old_email="" old_name="" remap_file="" force=0
  while [ $# -gt 0 ]; do
    # accept --opt=value as an alias for --opt value (e.g. --name="John Doe")
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --name)
        new_name="$2"
        shift 2
        ;;
      --email)
        new_email="$2"
        shift 2
        ;;
      --remap-file)
        remap_file="$2"
        shift 2
        ;;
      --old-email)
        old_email="$2"
        shift 2
        ;;
      --old-name)
        old_name="$2"
        shift 2
        ;;
      --force | -f)
        force=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option for remap: $1" ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        elif [ -z "$target" ]; then
          target="$1"
        else die "unexpected argument: $1"; fi
        shift
        ;;
    esac
  done

  [ -n "$name" ] || die "usage: isopod remap <name> [target-repo-dir] [--name <new>] [--email <new>] [--old-email <e>] [--old-name <n>] [--remap-file <file>]"
  have git || die "git is required on the host for 'isopod remap'"

  target="${target:-.}"
  git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "'$target' is not a git repo — run this in (or point it at) the repo you fetched into"
  local top
  top=$(git -C "$target" rev-parse --show-toplevel)

  # NOTE: the new-identity defaults + "no new author" checks live in the
  # single-pair branch below ONLY. A --remap-file run supplies every identity
  # from the file, so it must not require a host git identity to be set.

  # The box's commits live under refs/remotes/<name>/* after `isopod fetch`.
  local -a boxrefs=()
  local r
  while IFS= read -r r; do [ -n "$r" ] && boxrefs+=("$r"); done < <(
    git -C "$top" for-each-ref --format='%(refname)' "refs/remotes/$name/"
  )
  [ "${#boxrefs[@]}" -gt 0 ] ||
    die "no refs found under refs/remotes/$name/* — run 'isopod fetch $name $top' first"

  # Resolve a multi-identity remap file (isopod's own 'old -> new' format).
  # Precedence: --remap-file <file>  >  explicit single-pair flags  >  default
  # file ($CONFIG_DIR/remap). The single-pair flags (--old-*/--name/--email)
  # handle the common case ("rewrite this box's identity -> mine") with no file.
  local explicit_pair=0
  [ -n "$new_name$new_email$old_email$old_name" ] && explicit_pair=1

  local remap_src=""
  if [ -n "$remap_file" ]; then
    [ -f "$remap_file" ] || die "remap file not found: $remap_file"
    remap_src="$remap_file"
  elif [ "$explicit_pair" -eq 0 ] && [ -f "$CONFIG_DIR/remap" ]; then
    remap_src="$CONFIG_DIR/remap"
  fi

  # Both backends are driven by a git mailmap; the single-pair branch builds a
  # one-line one, the remap-file branch translates the 'old -> new' rules into
  # one. $mm is the resulting file (a temp we clean up when mm_tmp=1).
  local mm mm_tmp=0
  if [ -n "$remap_src" ]; then
    # Multi-identity mode: rewrite every identity the rules cover, leaving any
    # unmatched identity (e.g. a teammate's commits) untouched.
    mm=$(mktemp "${TMPDIR:-/tmp}/isopod-remap-XXXXXX")
    mm_tmp=1
    remap_to_mailmap "$remap_src" "$mm"
    info "Rewriting box identities per $remap_src ($(wc -l <"$mm" | tr -d ' ') rule(s)) on:"
    printf '    %s\n' "${boxrefs[@]}"
    info "            (in $top)"
  else
    # Single-pair mode. New identity defaults so 'isopod remap <box>' just works:
    #   explicit --name/--email  >  ISOPOD_GIT_NAME/EMAIL  >  host git config.
    [ -n "$new_name" ] || new_name="${ISOPOD_GIT_NAME:-$(git -C "$top" config user.name 2>/dev/null || true)}"
    [ -n "$new_email" ] || new_email="${ISOPOD_GIT_EMAIL:-$(git -C "$top" config user.email 2>/dev/null || true)}"
    [ -n "$new_name" ] || die "no new author name — pass --name, set ISOPOD_GIT_NAME, or set git config user.name"
    [ -n "$new_email" ] || die "no new author email — pass --email, set ISOPOD_GIT_EMAIL, or set git config user.email"

    # If --old-email was omitted, try to learn the box's git identity from the
    # box itself (best effort — the box may be gone, in which case ask for it).
    if [ -z "$old_email" ]; then
      if [ -d "$(box_dir "$name")" ]; then
        detect_engine "$(meta_get "$name" engine || true)"
        # -n: this probe never needs stdin, so don't let ssh touch the stdin the
        # confirmation prompt below reads from.
        old_email=$(box_ssh "$name" -n -- \
          git -C "$WORKSPACE" config --get user.email 2>/dev/null | tr -d '\r') || true
        # This value comes FROM the box, and it is about to be written into a git
        # mailmap the host then executes. A mailmap is line-oriented, so a value
        # carrying a newline injects extra rewrite rules; '<' and '>' would let it
        # forge the field structure of the line. Refuse rather than sanitize, so a
        # box can never silently steer a rewrite it was not asked for. An EMPTY
        # value is not an attack — it just means the box has no identity set — so
        # leave that to the "could not detect" message below.
        [ -z "$old_email" ] || valid_ident_email "$old_email" ||
          die "box '$name' reported an unusable git email — refusing to build a rewrite rule from it.
     Pass the identity yourself: isopod remap $name --old-email <e>"
        [ -n "$old_email" ] && info "Detected box identity from '$name': <$(sanitize "$old_email")>"
      fi
      [ -n "$old_email" ] || die "could not detect the box's email — pass --old-email <e> (the identity to rewrite FROM)"
    fi

    # Structural check on every field that lands in the mailmap. old_email is the
    # box-sourced one (already checked above when auto-detected); the rest come
    # from flags, env or the host's git config, where a stray newline is a
    # mistake rather than an attack — but it would corrupt the mailmap either way.
    valid_ident_email "$old_email" || die "invalid --old-email '$old_email' (no line breaks, spaces or angle brackets)"
    valid_ident_email "$new_email" || die "invalid --email '$new_email' (no line breaks, spaces or angle brackets)"
    valid_ident_name "$new_name" || die "invalid --name '$new_name' (no line breaks or angle brackets)"
    valid_ident_name "$old_name" || die "invalid --old-name '$old_name' (no line breaks or angle brackets)"

    mm=$(mktemp "${TMPDIR:-/tmp}/isopod-remap-XXXXXX")
    mm_tmp=1
    if [ -n "$old_name" ]; then
      printf '%s <%s> %s <%s>\n' "$new_name" "$new_email" "$old_name" "$old_email" >"$mm"
    else
      printf '%s <%s> <%s>\n' "$new_name" "$new_email" "$old_email" >"$mm"
    fi

    info "Rewriting commits by <$old_email>${old_name:+ / \"$old_name\"} on:"
    printf '    %s\n' "${boxrefs[@]}"
    info "            to: \"$new_name\" <$new_email>  (in $top)"
  fi

  if [ "$force" -ne 1 ]; then
    printf 'This rewrites history on those refs (new commit SHAs). Proceed? [y/N] '
    local reply
    read -r reply
    case "$reply" in y | Y | yes | YES) ;; *)
      [ "$mm_tmp" -eq 1 ] && rm -f "$mm"
      die "aborted"
      ;;
    esac
  fi

  # Safety net: snapshot the box refs so the user can undo (git update-ref -d
  # refs/remap-backup/... to discard, or reset a ref back to its backup).
  for r in "${boxrefs[@]}"; do
    git -C "$top" update-ref "refs/remap-backup/${r#refs/}" "$r"
  done
  info "Backed up original refs under refs/remap-backup/ (delete when satisfied)."

  if have git-filter-repo || git -C "$top" filter-repo -h >/dev/null 2>&1; then
    # Preferred path: filter-repo applies the mailmap directly.
    # --refs scopes the rewrite (implies --partial: other refs/origin are kept).
    if ! git -C "$top" filter-repo --force --partial --mailmap "$mm" --refs "${boxrefs[@]}"; then
      [ "$mm_tmp" -eq 1 ] && rm -f "$mm"
      die "git filter-repo failed"
    fi
  elif have python3; then
    # Fallback using ONLY core git: stream the box refs through fast-export,
    # rewrite the matching author/committer/tagger identities, and fast-import
    # them back. This needs no extra tooling (filter-branch is deprecated and
    # often absent), never touches the working tree, and keeps dates verbatim.
    # The rewrite logic lives in lib/remap_identity_filter.py (mailmap-driven and
    # data-block aware, so identity text inside a commit message is left alone).
    local flt="$ISOPOD_LIB/remap_identity_filter.py"
    [ -f "$flt" ] || {
      [ "$mm_tmp" -eq 1 ] && rm -f "$mm"
      die "missing helper: $flt (is your isopod install complete?)"
    }
    if ! git -C "$top" fast-export --no-data --reference-excluded-parents "${boxrefs[@]}" |
      MAILMAP_FILE="$mm" python3 "$flt" |
      git -C "$top" fast-import --force --quiet; then
      [ "$mm_tmp" -eq 1 ] && rm -f "$mm"
      die "the fast-export/fast-import rewrite failed"
    fi
  else
    [ "$mm_tmp" -eq 1 ] && rm -f "$mm"
    die "need 'git filter-repo' or python3 to rewrite history — install one:
    Debian/Ubuntu : sudo apt install git-filter-repo   (or: apt install python3)
    macOS (brew)  : brew install git-filter-repo
    any OS (pip)  : pip install git-filter-repo"
  fi
  [ "$mm_tmp" -eq 1 ] && rm -f "$mm"

  info "Done. Rewritten box branches:"
  git -C "$top" for-each-ref \
    --format='    %(refname:short)  %(authorname) <%(authoremail:trim)>' "${boxrefs[@]}"
  printf '\nCheck the result, then drop the backups when happy:\n  git -C %s for-each-ref refs/remap-backup/\n  git -C %s update-ref -d <each backup ref>\n' "$top" "$top"
}
