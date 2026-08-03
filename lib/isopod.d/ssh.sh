#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines host ssh_config management, box SSH transport, tar streaming.

# ---------------------------------------------------------------------------
# ssh config management
# ---------------------------------------------------------------------------
ensure_ssh_include() {
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$USER_SSH_CONFIG" && chmod 600 "$USER_SSH_CONFIG"
  # Quote the path so an include under a directory with spaces still parses.
  # Detect an existing include by the bare path, so we match whether a prior
  # version wrote it quoted or unquoted (and never add it twice).
  local line="Include \"$SSH_INCLUDE_FILE\""
  if ! grep -qsF "$SSH_INCLUDE_FILE" "$USER_SSH_CONFIG"; then
    # Include must appear before any Host block to apply globally; prepend.
    # Write a sibling temp in ~/.ssh and rename it into place, so a crash or
    # full disk mid-write can never truncate the user's real ssh config — the
    # one file you least want to damage. The rename is atomic within the dir.
    local tmp
    tmp=$(mktemp "$HOME/.ssh/.isopod-config.XXXXXX") || die "could not write to ~/.ssh"
    {
      printf '# isopod sandboxes\n%s\n\n' "$line"
      cat "$USER_SSH_CONFIG"
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$USER_SSH_CONFIG"
    info "Added '$line' to ~/.ssh/config"
  fi
}

# Regenerate the whole include file from per-box metadata.
write_ssh_include() {
  mkdir -p "$CONFIG_DIR"
  local tmp
  tmp=$(mktemp)
  {
    printf '# Managed by isopod — do not edit (regenerated on every change)\n\n'
    local d name host port hostkeyalias
    for d in "$BOXES_DIR"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      # Engine-abstracted address: 127.0.0.1 + published port (podman/docker) or
      # the box's vmnet IP + in-box sshd port (Apple `container`). Skip boxes whose
      # address can't be resolved yet (no port / not running).
      IFS=' ' read -r host port < <(box_ssh_addr "$name") || continue
      [ -n "$host" ] && [ -n "$port" ] || continue
      # Apple `container` reassigns the IP each start; pin the key by the box's
      # stable name so it verifies regardless of the current HostName (see
      # ssh-entry.txt). Consumed by the template via render_tmpl (unseen by the linter).
      hostkeyalias=""
      # shellcheck disable=SC2034
      [ "$(box_engine "$name")" = container ] && hostkeyalias="  HostKeyAlias $(ctr_name "$name")"
      render_tmpl ssh-entry.txt
    done
  } >"$tmp"
  mv "$tmp" "$SSH_INCLUDE_FILE"
  chmod 600 "$SSH_INCLUDE_FILE"
}

meta_set_port() { # meta_set_port <name> <port>
  local f
  f="$(box_dir "$1")/meta"
  if grep -q '^port=' "$f" 2>/dev/null; then
    sed -i.bak "s/^port=.*/port=$2/" "$f" && rm -f "$f.bak"
  else
    printf 'port=%s\n' "$2" >>"$f"
  fi
}

resolve_port() { # resolve_port <name> -> echoes current host port for the box sshd
  local out
  out=$("$ENGINE" port "$(ctr_name "$1")" "$BOX_SSHD_PORT/tcp" 2>/dev/null | head -1) || return 1
  printf '%s' "${out##*:}"
}

# The engine a box runs under (its meta, else the ambient ENGINE). Used by the
# address resolver so podman/docker and Apple `container` boxes are reached the
# right way.
box_engine() { # box_engine <name>
  meta_get "$1" engine 2>/dev/null || printf '%s' "${ENGINE:-}"
}

# The vmnet IP of an Apple `container` box, parsed from `container inspect`. Apple
# `container` runs each box in its own VM with its own routable IP (no loopback
# port publish), so this IP — not 127.0.0.1 — is the SSH target. Best-effort JSON
# parse (first IPv4 in the inspect output); NEEDS validation against a real
# `container inspect` on macOS. Echoes the IP, empty on failure.
container_box_ip() { # container_box_ip <name>
  local ip
  # Pull the IP only from the box's own "ipv4Address" field. A plain first-IP grep
  # is wrong here: with an egress `--dns 1.1.1.1`, inspect lists that nameserver
  # (and the gateway) alongside the box address. Anchor the match on the field name
  # itself (robust to pretty-printed or compact JSON), then take the trailing IP.
  ip="$(container inspect "$(ctr_name "$1")" 2>/dev/null |
    grep -oE '"ipv4Address"[^0-9]*[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' |
    grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)"
  [ -n "$ip" ] && printf '%s' "$ip"
}

# The SSH transport address for a box, echoed as "HOST PORT". podman/docker publish
# the box sshd to a loopback host port, so it's 127.0.0.1 + the published port
# (from meta). Apple `container` gives the box its own vmnet IP reached directly on
# the in-box sshd port (BOX_SSHD_PORT), no publish — so it's that IP + BOX_SSHD_PORT.
# This is the single place the two networking models diverge for SSH.
box_ssh_addr() { # box_ssh_addr <name> -> "host port"
  local name="$1" ip
  if [ "$(box_engine "$name")" = container ]; then
    ip="$(container_box_ip "$name")" || return 1
    [ -n "$ip" ] || return 1
    printf '%s %s\n' "$ip" "$BOX_SSHD_PORT"
  else
    printf '127.0.0.1 %s\n' "$(meta_get "$name" port)"
  fi
}

# Runtime state of a box's container as a single lowercase word ("running",
# "stopped", ...), or a non-zero return when the engine has no such container.
# podman/docker expose it through an inspect Go-template; Apple `container` has no
# -f/--format, so its state is parsed from the inspect JSON's status.state field.
# Uses the box's own engine (from meta), so a mixed-engine `isopod list` is correct.
box_status() { # box_status <name>
  local name="$1" eng ctr
  eng="$(box_engine "$name")"
  ctr="$(ctr_name "$name")"
  if [ "$eng" = container ]; then
    container inspect "$ctr" 2>/dev/null |
      sed -nE 's/.*"state"[[:space:]]*:[[:space:]]*"([a-zA-Z]+)".*/\1/p' | head -n1 |
      grep . # non-zero when no state line was found (missing box)
  else
    "${eng:-$ENGINE}" inspect -f '{{.State.Status}}' "$ctr" 2>/dev/null
  fi
}

refresh_port() { # refresh stored port + ssh config if the mapping changed
  local name="$1" port
  # Apple `container` gives the box a NEW vmnet IP on every start, so the ssh_config
  # HostName goes stale — rewrite it from the live address. There is no published
  # port to track, and the box's host key is pinned by HostKeyAlias (its stable
  # name), so the key still verifies across the IP change.
  if [ "$(box_engine "$name")" = container ]; then
    write_ssh_include
    return 0
  fi
  port=$(resolve_port "$name") || return 0
  [ -n "$port" ] || return 0
  if [ "$port" != "$(meta_get "$name" port || true)" ]; then
    meta_set_port "$name" "$port"
    write_ssh_include
  fi
}

# Pin the box's SSH host key. This is trust-on-first-use: the very first scan
# (at create) is trusted blindly. A box's key is fixed at first boot and persists
# across start/stop/reconfigure, and a recreated box gets a fresh box dir (hence
# an empty known_hosts), so an already-pinned box should never present a
# different key. If one does, fail closed (refuse to connect) instead of
# silently re-pinning — that is the honest signal that the loopback port may
# have been taken over. ISOPOD_ACCEPT_NEW_HOSTKEY=1 opts back into adopting the
# new key for a deliberate out-of-band rebuild.
scan_host_key() { # scan_host_key <name>
  local name="$1" host port kh tmp tries=0 max="${ISOPOD_SSH_WAIT_TRIES:-30}"
  kh="$(box_dir "$name")/known_hosts"
  tmp="$kh.scan"
  while [ $tries -lt "$max" ]; do
    # Re-resolve the address each pass: Apple `container` may not have assigned the
    # box its vmnet IP yet right after `run`, so box_ssh_addr fails transiently while
    # the VM boots. Retry (like wait_for_ssh) rather than give up on the first miss.
    if IFS=' ' read -r host port < <(box_ssh_addr "$name") &&
      [ -n "$host" ] && [ -n "$port" ] &&
      ssh-keyscan -p "$port" -T 3 "$host" 2>/dev/null >"$tmp" && [ -s "$tmp" ]; then
      # Compare only the key material (type + blob), not the leading [host]:port
      # field, which legitimately changes when the box gets a new published port.
      if [ -s "$kh" ] &&
        [ "$(awk '{print $2, $3}' "$kh" | sort -u)" != "$(awk '{print $2, $3}' "$tmp" | sort -u)" ]; then
        # A box's key is fixed at first boot and persists across start/stop/
        # reconfigure, and a recreated box gets a fresh (empty) known_hosts, so an
        # already-pinned box should never present a different key. If one does, the
        # loopback port may have been taken over — fail CLOSED (refuse to adopt a
        # possibly-hostile key) rather than pin it and connect. ISOPOD_ACCEPT_NEW_HOSTKEY=1
        # restores the old adopt-and-warn behavior for a deliberate out-of-band rebuild.
        if [ "${ISOPOD_ACCEPT_NEW_HOSTKEY:-0}" != 1 ]; then
          rm -f "$tmp"
          die "SSH host key for box '$name' CHANGED since it was pinned ($host:$port).
     A box's key persists across start/stop/reconfigure, so this should not happen unless you
     recreated it — another process may have taken over its address. Refusing to connect.
     If you deliberately recreated it: rm -f '$kh'  then retry, or set
     ISOPOD_ACCEPT_NEW_HOSTKEY=1 to adopt the new key this run."
        fi
        warn "SSH host key for box '$name' CHANGED — adopting it (ISOPOD_ACCEPT_NEW_HOSTKEY=1)."
      fi
      # Apple `container` reassigns the box IP on each start, so pin the key under
      # the box's stable name and connect with HostKeyAlias — SSH then verifies it
      # regardless of address. Rewrite the scanned entries' host field to that name
      # (podman/docker keep the fixed 127.0.0.1, so they stay pinned by host:port).
      if [ "$(box_engine "$name")" = container ]; then
        awk -v a="$(ctr_name "$name")" '!/^#/ && NF >= 3 { $1 = a; print }' "$tmp" >"$tmp.alias" &&
          mv "$tmp.alias" "$tmp"
      fi
      mv "$tmp" "$kh"
      chmod 600 "$kh"
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  rm -f "$tmp"
  return 1
}

# Connect to a box using its own key/port/known_hosts explicitly, so internal
# SSH never depends on ~/.ssh/config resolution (which OpenSSH derives from the
# passwd database, not $HOME — important for hermetic tests and odd setups).
#
# A remote command passed here runs non-interactively, so it gets sshd's PATH
# (the system default), NOT the PATH your ~/.bashrc would build. Built-in flows
# only need tools on the system PATH (git, python3 in /usr/bin). A box op that
# depends on a tool you added to PATH from a shell rc file will not see it —
# install such tools system-wide, or run them yourself from `isopod shell`.
box_ssh() { # box_ssh <name> [ssh-options...] [-- remote command...]
  local name="$1"
  shift
  local host port
  # Pin IFS to a space for the split: box_ssh_addr emits "host port", but a caller
  # may have a non-default IFS in scope (e.g. inject_secrets sets IFS=, to parse
  # its spec list), which would otherwise swallow the port and yield `ssh -p ''`.
  IFS=' ' read -r host port < <(box_ssh_addr "$name") || die "could not resolve SSH address for box '$name'"
  # Apple `container` boxes are pinned in known_hosts under their stable name (the
  # IP changes each start), so verify the key via HostKeyAlias, not the address.
  local -a hkalias=()
  [ "$(box_engine "$name")" = container ] && hkalias=(-o "HostKeyAlias=$(ctr_name "$name")")
  # Split leading ssh options from the remote command: everything up to the
  # first non-option (or '--') is an ssh option; the rest is the command.
  local -a opts=() rcmd=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        rcmd=("$@")
        break
        ;;
      -o)
        opts+=("$1" "$2")
        shift 2
        ;;
      -*)
        opts+=("$1")
        shift
        ;;
      *)
        rcmd=("$@")
        break
        ;;
    esac
  done
  ssh -p "$port" \
    -i "$(box_dir "$name")/id_ed25519" \
    -o IdentitiesOnly=yes \
    -o UserKnownHostsFile="$(box_dir "$name")/known_hosts" \
    -o StrictHostKeyChecking=yes \
    -o ForwardAgent=no -o ForwardX11=no \
    "${hkalias[@]}" "${opts[@]}" "$CONTAINER_USER@$host" "${rcmd[@]}"
}

# Stream a tar archive between host and box over SSH. File transfer uses tar
# (not scp) so it preserves what `$ENGINE cp` did — mtimes, modes, symlinks, and
# special files — instead of dereferencing symlinks and resetting timestamps the
# way scp would. Going over SSH (not `$ENGINE cp`) also means it reaches the
# workload under any runtime, including a microVM. Callers pipe a tar stream:
#   tar -C src -cf - item | box_tar_in  <name> <dest-dir>      (host -> box)
#   box_tar_out <name> <src-dir> | tar -C dest -xpf -          (box  -> host)
box_tar_in() { # box_tar_in <name> <dest-dir>   (reads a tar stream on stdin)
  box_ssh "$1" -- tar -C "$2" -xpf -
}
box_tar_out() { # box_tar_out <name> <src-dir> [tar-opts...]  (writes a tar stream to stdout)
  local name="$1" src="$2"
  shift 2
  # Extra tar options (e.g. --exclude) go before -c. box_ssh space-joins argv and
  # the box shell re-parses it, so any option carrying a glob must already be
  # quoted for that shell — see shq and 'isopod export --exclude'.
  box_ssh "$name" -- tar -C "$src" "$@" -cf - .
}

# Single-quote a value so a remote POSIX shell reached via box_ssh keeps it
# literal. box_ssh joins its remote argv with spaces and the box's shell parses
# the result, so an unquoted glob like '*.log' would expand in the box before the
# remote program sees it. Wrap in single quotes and escape any embedded quote.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

wait_for_ssh() { # wait until we can actually authenticate
  local name="$1" tries=0 max="${ISOPOD_SSH_WAIT_TRIES:-30}"
  while [ $tries -lt "$max" ]; do
    if box_ssh "$name" -o ConnectTimeout=3 -o BatchMode=yes -- true 2>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}
