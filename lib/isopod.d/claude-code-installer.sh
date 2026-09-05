# shellcheck shell=bash
#
# claude-code-installer — put Claude Code inside a box.
#
# The binary is fetched and verified on the HOST, then streamed into the box over
# the existing SSH channel. Nothing in the box downloads or executes a remote
# installer, so the box needs no install-time network and the bytes are checked
# before they cross the boundary.
#
# Freshness is a one-time event: whatever is newest at install time goes in, and
# from then on the person using the box upgrades it with Claude Code's own
# updater. isopod pins no version and re-checks nothing on later launches.
#
# The launcher (cmd_claude) lives in lifecycle.sh beside cmd_shell — launching a
# box session is not this module's job.

# Artifacts the upstream bootstrap publishes. Anything else is refused rather
# than guessed at, since the token becomes part of a URL and a cache path.
CLAUDE_PLATFORMS="linux-x64 linux-arm64 linux-x64-musl linux-arm64-musl"

# Where the box user's PATH may hide the binary. `claude install` decides the
# final location, and a non-login SSH command does not source a shell rc, so both
# candidates are put on PATH explicitly rather than assumed.
CLAUDE_BOX_PATH='$HOME/.local/bin:$HOME/.claude/bin:$PATH'

# Resolve the artifact for the BOX, never the host: isopod runs on macOS and
# Linux, a box is always Linux, and both sides come in amd64 and arm64. The
# tokens and the musl markers mirror the upstream bootstrap script so a box gets
# the same build a normal install would.
claude_box_platform() { # claude_box_platform <name> -> platform token
  local plat
  plat="$(box_ssh "$1" -- 'sh -c '"$(shq '
    case "$(uname -m)" in
      x86_64|amd64)  a=x64 ;;
      aarch64|arm64) a=arm64 ;;
      *) exit 1 ;;
    esac
    if [ -e "/lib/libc.musl-x86_64.so.1" ] || [ -e "/lib/libc.musl-aarch64.so.1" ] ||
       ldd /bin/ls 2>&1 | grep -q musl; then
      printf "linux-%s-musl" "$a"
    else
      printf "linux-%s" "$a"
    fi')" 2>/dev/null)" ||
    die "could not read the architecture of box '$1' (is it running?)"
  # The box answered, but the answer still becomes a URL and a path: only the
  # published set passes.
  case " $CLAUDE_PLATFORMS " in
    *" $plat "*) printf '%s' "$plat" ;;
    *) die "box '$1' reports an architecture Claude Code has no build for: '${plat:-unknown}'" ;;
  esac
}

# The newest published version, as a bare string. Validated before it is used:
# it becomes both a URL segment and a cache directory name.
claude_latest_version() {
  local ver
  ver="$(claude_curl "$ISOPOD_CLAUDE_BASE_URL/latest")" ||
    die "could not reach $ISOPOD_CLAUDE_BASE_URL/latest — check your network, or a proxy that blocks it"
  ver="$(printf '%s' "$ver" | tr -d '\r\n')"
  [[ "$ver" =~ ^[0-9][0-9A-Za-z.+-]{0,63}$ ]] ||
    die "the release endpoint returned something that is not a version: '$(sanitize "$ver")'"
  printf '%s' "$ver"
}

# The published SHA-256 for one platform of one version.
claude_checksum() { # claude_checksum <version> <platform>
  local helper="$ISOPOD_LIB/claude_manifest.py" sum
  [ -f "$helper" ] || die "missing helper: $helper (is your isopod install complete?)"
  have python3 || die "isopod claude-code needs python3 on the host to read the release manifest"
  sum="$(claude_curl "$ISOPOD_CLAUDE_BASE_URL/$1/manifest.json" | python3 "$helper" "$2")" ||
    die "could not read a checksum for $2 from the $1 manifest"
  printf '%s' "$sum"
}

# One place for the fetch flags, so every request in this module is HTTPS-only
# with a bounded wait rather than hanging a launch on a stalled endpoint.
claude_curl() { # claude_curl <url> [curl-args...]
  local url="$1"
  shift
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 "$@" "$url"
}

# Download and verify, or reuse an already-verified copy. Prints the path to the
# cached binary. Nothing reaches its final name until the digest matches, so a
# failed or interrupted download can never be picked up as a cache hit later.
claude_fetch_verified() { # claude_fetch_verified <version> <platform> -> path
  local ver="$1" plat="$2" dir cached tmp want got
  dir="$CACHE_DIR/claude/$ver/$plat"
  cached="$dir/claude"
  [ -x "$cached" ] && {
    printf '%s' "$cached"
    return 0
  }
  have curl || die "isopod claude-code needs curl on the host to download Claude Code"
  want="$(claude_checksum "$ver" "$plat")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.claude-XXXXXX")"
  # This function's stdout IS the path the caller reads, so progress goes to
  # stderr or it would be captured as part of that path.
  info "Downloading Claude Code $ver ($plat)..." >&2
  if ! claude_curl "$ISOPOD_CLAUDE_BASE_URL/$ver/$plat/claude" -o "$tmp"; then
    rm -f "$tmp"
    die "download failed: $ISOPOD_CLAUDE_BASE_URL/$ver/$plat/claude"
  fi
  got="$(sha256_full <"$tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    die "checksum mismatch for Claude Code $ver ($plat).
     expected $want
     got      $got
     Nothing was installed. Retry, and if it persists do not install this build."
  fi
  chmod 755 "$tmp"
  mv "$tmp" "$cached"
  printf '%s' "$cached"
}

# Is Claude Code already in the box? The check is presence, never currency:
# upgrades belong to the person using the box.
claude_in_box() { # claude_in_box <name>
  box_ssh "$1" -- "PATH=$CLAUDE_BOX_PATH command -v claude >/dev/null 2>&1" 2>/dev/null
}

# Put a verified binary in the box and let it install itself. Handing off to
# `claude install` is what the upstream bootstrap does, and it keeps the
# built-in updater wired up — which matters, because from here on updating is
# the box user's job.
claude_ensure_installed() { # claude_ensure_installed <name>
  local name="$1" plat ver cached want
  claude_in_box "$name" && return 0
  plat="$(claude_box_platform "$name")"
  ver="$(claude_latest_version)"
  cached="$(claude_fetch_verified "$ver" "$plat")"
  want="$(sha256_full <"$cached")"

  info "Installing Claude Code $ver into '$name'..."
  box_ssh "$name" -- 'mkdir -p "$HOME/.claude/downloads"' ||
    die "could not create the download directory in '$name'"
  # tar carries the execute bit across, so no second chmod command is needed.
  tar -C "$(dirname "$cached")" -cf - claude |
    box_tar_in "$name" '$HOME/.claude/downloads' ||
    die "could not copy Claude Code into '$name'"
  # Re-hash on the far side: a truncated stream is a corrupt binary, and saying
  # so here beats an unexplained failure at launch.
  box_ssh "$name" -- "cd \"\$HOME/.claude/downloads\" && printf '%s  claude\n' $(shq "$want") | sha256sum -c --status" ||
    die "Claude Code arrived in '$name' corrupted (checksum mismatch after transfer)"
  box_ssh "$name" -- 'cd "$HOME/.claude/downloads" && ./claude install' ||
    die "'claude install' failed inside '$name'"
  claude_in_box "$name" ||
    die "Claude Code installed in '$name' but is not on PATH there — report this with the output above"
  info "Claude Code $ver installed in '$name'"
}

# Offer to store an API key when there is none. Declining is fine: Claude Code
# runs its own sign-in when it starts, and a subscription login needs no key.
claude_ensure_key() {
  CLAUDE_API_KEY=""
  local val
  if val="$(secret_store_get "$ISOPOD_CLAUDE_SECRET" 2>/dev/null)" && [ -n "$val" ]; then
    CLAUDE_API_KEY="$val"
    return 0
  fi
  [ -t 0 ] || return 0 # non-interactive: let Claude Code handle sign-in itself
  info "No $ISOPOD_CLAUDE_SECRET is stored. Paste one to use it in this box, or press enter
       to skip and let Claude Code sign you in its own way."
  printf 'value for %s (input hidden, enter to skip): ' "$ISOPOD_CLAUDE_SECRET" >&2
  local reply
  IFS= read -rs reply
  printf '\n' >&2
  [ -n "$reply" ] || return 0
  printf '%s' "$reply" | secret_store_set "$ISOPOD_CLAUDE_SECRET"
  info "stored secret '$ISOPOD_CLAUDE_SECRET' ($(secret_backend) backend) — reused for every box"
  CLAUDE_API_KEY="$reply"
}

# Hand the key to the box out of band. It goes to /dev/shm, which is a tmpfs the
# engine mounts for every box, so the value is memory-backed, invisible to
# `reconfigure` snapshots and to `export`, and gone when the box stops. The
# session below reads it once and unlinks it. The value travels SSH stdin only,
# never argv or env on either side.
claude_stage_key() { # claude_stage_key <name> -> prints the staged path
  local name="$1" path
  path="/dev/shm/.isopod-claude-$$-$RANDOM"
  printf '%s' "$CLAUDE_API_KEY" |
    box_ssh "$name" -- "umask 077 && cat > $(shq "$path")" ||
    die "could not hand the API key to '$name'"
  printf '%s' "$path"
}

# Tell the user which hostnames an allow-list box needs, and change nothing. The
# allow-list is one filter file for the whole host, so widening it silently would
# affect every allow-list box rather than only this one.
# Read by share/claude-egress.txt at render time (bash dynamic scope).
CLAUDE_MISSING_DOMAINS=""
claude_egress_note() { # claude_egress_note <name>
  [ "$(meta_get "$1" offline 2>/dev/null || true)" = 1 ] && return 0
  [ "$(active_egress)" = "allow-list" ] || return 0
  local allowed missing="" d
  allowed="$(
    egress_allowlist_domains "$ISOPOD_EGRESS_ALLOWLIST"
    egress_allowlist_domains "$USER_EGRESS_ALLOWLIST"
  )"
  # Space-separated constant; the split is the point.
  # shellcheck disable=SC2086
  for d in $ISOPOD_CLAUDE_DOMAINS; do
    printf '%s\n' "$allowed" | grep -qxF "$d" || missing="$missing $d"
  done
  [ -n "$missing" ] || return 0
  CLAUDE_MISSING_DOMAINS="${missing# }"
  render_tmpl claude-egress.txt >&2
}
