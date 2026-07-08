#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines host-side secret
# storage and per-box secret injection.
#
# Threat model: the box is assumed compromised, so a secret must never appear
# where the box (or anyone inspecting it) can recover it later — image layers,
# `$ENGINE inspect` env, argv, `isopod export` tarballs, or the snapshot images
# `reconfigure` takes. Values live on the host (OS keychain when available) and
# are streamed over the box's SSH channel into a tmpfs at run time; a stopped
# box holds no secrets.

# Which store holds secret values. ISOPOD_SECRET_BACKEND forces one (tests use
# 'file'); otherwise prefer the OS keychain, falling back to a 0600 file.
secret_backend() {
  if [ -n "${ISOPOD_SECRET_BACKEND:-}" ]; then
    printf '%s\n' "$ISOPOD_SECRET_BACKEND"
  elif [ "$(uname -s)" = Darwin ] && have security; then
    printf 'keychain-macos\n'
  elif have secret-tool; then
    printf 'keychain-linux\n'
  else
    printf 'file\n'
  fi
}

valid_secret_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]]; }

# Absolute path, restricted charset. Excluding ':' ',' whitespace and shell
# metacharacters keeps the meta encoding (NAME:path,NAME:path) and the remote
# install command unambiguous — same invariant style as render_tmpl's note.
valid_secret_path() { [[ "$1" =~ ^/[A-Za-z0-9._/+-]+$ ]]; }

# The index records which names isopod manages (never values): `secret ls`
# cannot enumerate a macOS keychain cleanly, so set/rm maintain this list.
_secret_index_add() {
  mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
  grep -qxF "$1" "$SECRETS_INDEX" 2>/dev/null || printf '%s\n' "$1" >>"$SECRETS_INDEX"
}
_secret_index_rm() {
  [ -f "$SECRETS_INDEX" ] || return 0
  grep -vxF "$1" "$SECRETS_INDEX" >"$SECRETS_INDEX.tmp" || true
  mv "$SECRETS_INDEX.tmp" "$SECRETS_INDEX"
}

secret_store_set() { # secret_store_set <name>  (value on stdin)
  local name="$1" value
  value="$(cat)"
  [ -n "$value" ] || die "refusing to store an empty value for secret '$name'"
  case "$(secret_backend)" in
    keychain-linux)
      printf '%s' "$value" | secret-tool store --label "isopod secret $name" service isopod name "$name" ||
        die "secret-tool failed to store '$name'"
      ;;
    keychain-macos)
      # Keep the value out of argv (where `ps` would show it): `security -i` reads
      # its command from stdin, so the value never becomes a process argument.
      # base64-encode it first (openssl for macOS/Linux portability) — a
      # whitespace-free alphabet the -i line tokenizer can't mis-split, so a value
      # with spaces or quotes stores intact; secret_store_get decodes it back.
      # NOTE: pre-2.4 boxes stored the value raw here, so after upgrading re-run
      # 'isopod secret set <name>' on macOS to re-store it base64-encoded.
      printf 'add-generic-password -U -a %s -s %s -w %s\n' \
        "$USER" "isopod/$name" "$(printf '%s' "$value" | openssl base64 -A)" |
        security -i ||
        die "security failed to store '$name'"
      ;;
    file)
      mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
      if [ ! -f "$SECRETS_DIR/.plaintext-warned" ]; then
        warn "no keychain tool found — storing secrets 0600-plaintext under $SECRETS_DIR
       (install secret-tool / libsecret on Linux for keychain storage)"
        : >"$SECRETS_DIR/.plaintext-warned"
      fi
      (umask 077 && printf '%s' "$value" >"$SECRETS_DIR/$name") ||
        die "failed to write $SECRETS_DIR/$name"
      ;;
    *) die "unknown secret backend: $(secret_backend)" ;;
  esac
  _secret_index_add "$name"
}

secret_store_get() { # secret_store_get <name> -> value on stdout; rc 1 if absent
  local name="$1"
  case "$(secret_backend)" in
    keychain-linux) secret-tool lookup service isopod name "$name" ;;
    keychain-macos) security find-generic-password -a "$USER" -s "isopod/$name" -w 2>/dev/null | openssl base64 -d -A ;;
    file) cat "$SECRETS_DIR/$name" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

secret_store_rm() { # secret_store_rm <name>
  local name="$1"
  case "$(secret_backend)" in
    keychain-linux) secret-tool clear service isopod name "$name" 2>/dev/null || true ;;
    keychain-macos) security delete-generic-password -a "$USER" -s "isopod/$name" >/dev/null 2>&1 || true ;;
    file) rm -f "$SECRETS_DIR/$name" ;;
  esac
  _secret_index_rm "$name"
}

secret_store_ls() { # names only, sorted; never values
  [ -f "$SECRETS_INDEX" ] && sort "$SECRETS_INDEX" || true
}

# Parse `--secret NAME[:target-path]` specs into SECRET_SPECS ("NAME:/abs/path"
# entries; default path /run/secrets/NAME). Fills the caller's process (not a
# subshell) so `die` aborts — same convention as parse_expose_specs.
SECRET_SPECS=()
parse_secret_specs() { # parse_secret_specs <spec...>
  SECRET_SPECS=()
  local spec name path seen_names="" seen_paths=""
  for spec in "$@"; do
    [ -z "$spec" ] && continue
    name="${spec%%:*}"
    valid_secret_name "$name" || die "invalid secret name: '$name' (letters, digits, _; must not start with a digit)"
    if [ "$spec" = "$name" ]; then
      path="/run/secrets/$name"
    else
      path="${spec#*:}"
      valid_secret_path "$path" ||
        die "invalid secret target path: '$path' (absolute; letters, digits, . _ / + - only)"
    fi
    case "$path/" in
      "$WORKSPACE"/*) die "secret '$name' targets $path — inside the workspace, so 'isopod export' would leak it. Pick a path outside $WORKSPACE." ;;
      /run/secrets/*) ;;
      *) warn "secret '$name' targets $path, outside the /run/secrets tmpfs — it will persist in the container layer and reconfigure snapshots" ;;
    esac
    case " $seen_names " in *" $name "*) die "duplicate secret: $name" ;; esac
    case " $seen_paths " in *" $path "*) die "two secrets target the same path: $path" ;; esac
    seen_names="$seen_names $name"
    seen_paths="$seen_paths $path"
    secret_store_get "$name" >/dev/null ||
      die "secret '$name' not found (set it first: isopod secret set $name)"
    SECRET_SPECS+=("$name:$path")
  done
}

# Stream a box's secrets (from its meta) over SSH into their target paths.
# Runs after sshd is reachable; the tmpfs mount comes from build_run_args.
# Values pass through SSH stdin only — never argv, env, or the engine.
inject_secrets() { # inject_secrets <boxname>
  local name="$1" specs spec sname spath p_b64
  specs="$(meta_get "$name" secrets 2>/dev/null || true)"
  [ -n "$specs" ] || return 0
  local IFS=,
  for spec in $specs; do
    sname="${spec%%:*}"
    spath="${spec#*:}"
    # Re-validate the spec read from meta. valid_secret_* guard the create path,
    # but inject also runs on start/reconfigure straight from the stored meta,
    # which a second tool or a hand-edit could have corrupted — refuse a bad spec
    # rather than carry it onward.
    valid_secret_name "$sname" || die "corrupt secret spec for '$name': bad name '$sname'"
    valid_secret_path "$spath" || die "corrupt secret spec for '$name': bad path '$spath'"
    # Deliver the target path as base64 — a shell-metacharacter-free alphabet — and
    # reconstruct it inside the box, so no host-controlled string is ever parsed by
    # the box's login shell (the remote command re-parses its argv as one string).
    # The value still passes over SSH stdin only — never argv, env, or the engine.
    p_b64="$(printf '%s' "$spath" | base64 | tr -d '\n')"
    secret_store_get "$sname" | box_ssh "$name" -- \
      "t=\$(printf %s '$p_b64' | base64 -d) && umask 277 && mkdir -p \"\$(dirname \"\$t\")\" && cat >\"\$t\" && chmod 400 \"\$t\"" ||
      die "failed to inject secret '$sname' into '$name'"
  done
  info "injected $(printf '%s' "$specs" | awk -F, '{print NF}') secret(s) into '$name'"
}

cmd_secret() {
  local action="${1:-ls}"
  shift 2>/dev/null || true
  case "$action" in
    set)
      local name="${1:-}" value
      [ -n "$name" ] || die "usage: isopod secret set <NAME>  (value read from stdin or prompt)"
      valid_secret_name "$name" || die "invalid secret name: '$name' (letters, digits, _; must not start with a digit)"
      if [ -t 0 ]; then
        # hidden prompt — the value must never appear in argv or shell history
        printf 'value for %s (input hidden): ' "$name" >&2
        local reply
        IFS= read -rs reply
        printf '\n' >&2
        printf '%s' "$reply" | secret_store_set "$name"
      else
        secret_store_set "$name"
      fi
      info "stored secret '$name' ($(secret_backend) backend)"
      ;;
    ls | list) secret_store_ls ;;
    rm | remove | delete)
      local name="${1:-}"
      [ -n "$name" ] || die "usage: isopod secret rm <NAME>"
      secret_store_rm "$name"
      info "removed secret '$name'"
      ;;
    -h | --help | help) render_tmpl secret-help.txt ;;
    *) die "unknown secret action: $action (try: isopod secret set|ls|rm)" ;;
  esac
}
