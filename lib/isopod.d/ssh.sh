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
    local d name port
    for d in "$BOXES_DIR"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      port=$(meta_get "$name" port || true)
      [ -n "$port" ] || continue
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

refresh_port() { # refresh stored port + ssh config if the mapping changed
  local name="$1" port
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
# different key. If one does, warn loudly instead of silently re-pinning — that
# is the honest signal that the loopback port may have been taken over. isopod
# still adopts the new key so the tool keeps working; the warning is the alert.
scan_host_key() { # scan_host_key <name>
  local name="$1" port kh tmp tries=0 max="${ISOPOD_SSH_WAIT_TRIES:-30}"
  port=$(meta_get "$name" port)
  kh="$(box_dir "$name")/known_hosts"
  tmp="$kh.scan"
  while [ $tries -lt "$max" ]; do
    if ssh-keyscan -p "$port" -T 3 127.0.0.1 2>/dev/null >"$tmp" && [ -s "$tmp" ]; then
      # Compare only the key material (type + blob), not the leading [host]:port
      # field, which legitimately changes when the box gets a new published port.
      if [ -s "$kh" ] &&
        [ "$(awk '{print $2, $3}' "$kh" | sort -u)" != "$(awk '{print $2, $3}' "$tmp" | sort -u)" ]; then
        warn "SSH host key for box '$name' CHANGED since it was pinned.
     Expected only if you recreated the box. If you did not, another process may have
     taken over its loopback port — stop and investigate. isopod is adopting the new key."
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
  local port
  port=$(meta_get "$name" port)
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
    "${opts[@]}" "$CONTAINER_USER@127.0.0.1" "${rcmd[@]}"
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
box_tar_out() { # box_tar_out <name> <src-dir>  (writes a tar stream to stdout)
  box_ssh "$1" -- tar -C "$2" -cf - .
}

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
