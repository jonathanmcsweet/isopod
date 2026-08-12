#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines host-service forwarding.
#
# Makes a service on the HOST reachable from inside a box, which is the opposite
# direction to --expose. The box's own loopback is its own, so a host service on
# 127.0.0.1 is otherwise unreachable no matter what the firewall allows.
#
# The mechanism is SSH remote forwarding (`ssh -R`) over the channel isopod
# already owns. That was chosen over opening the guest ruleset because:
#
#   - it works the same on every engine and OS (podman, docker, krun+passt,
#     Apple `container`), since SSH is the one transport isopod needs everywhere
#   - it needs no firewall change: the tunnel rides inside the established SSH
#     connection, which the guest ruleset already accepts
#   - it opens exactly one port on the box's own loopback, which is narrower
#     than anything a firewall exemption could express
#
# The forward target is resolved and connected FROM THE HOST, so a host that is
# only reachable through the host's VPN works too — the box needs no route to it.

# One ssh process per box carries all of that box's forwards. Add or remove one
# and the process is restarted, which briefly drops the others; that is the
# trade for not running (and tracking) a process per forward.
host_port_pidfile() { # host_port_pidfile <name>
  printf '%s/host-port.pid' "$(box_dir "$1")"
}

# Validate one spec into the normalized form this module stores and forwards:
#   PORT                        box 127.0.0.1:PORT     -> host 127.0.0.1:PORT
#   BOXPORT:HOSTPORT            box 127.0.0.1:BOXPORT  -> host 127.0.0.1:HOSTPORT
#   BOXPORT:TARGET:TARGETPORT   box 127.0.0.1:BOXPORT  -> TARGET:TARGETPORT
#   BOXPORT:[IPv6]:TARGETPORT   the same, IPv6 target
# Echoes "BOXPORT TARGET TARGETPORT" on success. Fills in the caller's process so
# a caller can `die` with its own message.
host_port_parse() { # host_port_parse <spec>
  local spec="${1:-}" boxp="" target="" tgtp="" rest
  case "$spec" in
    "" | *[[:space:],]*) return 1 ;;
  esac
  case "$spec" in
    *:*)
      boxp="${spec%%:*}"
      rest="${spec#*:}"
      case "$rest" in
        # Bracketed IPv6 target: [addr]:port
        "["*)
          case "$rest" in *"]:"*) ;; *) return 1 ;; esac
          tgtp="${rest##*]:}"
          target="${rest#"["}"
          target="${target%%]:*}"
          # Inside brackets it must actually be an IPv6 literal.
          case "$target" in *[!0-9a-fA-F:]*) return 1 ;; esac
          case "$target" in *:*) ;; *) return 1 ;; esac
          ;;
        *:*)
          target="${rest%:*}"
          tgtp="${rest##*:}"
          ;;
        *)
          target="127.0.0.1"
          tgtp="$rest"
          ;;
      esac
      ;;
    *)
      boxp="$spec"
      target="127.0.0.1"
      tgtp="$spec"
      ;;
  esac
  [ -n "$target" ] || return 1
  valid_port "$boxp" || return 1
  valid_port "$tgtp" || return 1
  # The box-side listener is opened by sshd as the box user, which cannot bind a
  # privileged port. Rejected here with a reason rather than left to fail as an
  # opaque "remote port forwarding failed" at connect time.
  [ "$boxp" -ge 1024 ] || return 2
  # A target that is neither an IP literal nor a plausible hostname would be
  # handed to ssh as an argument; keep it to the characters a host can contain.
  case "$target" in
    *[!0-9a-zA-Z.:_-]*) return 1 ;;
  esac
  printf '%s %s %s\n' "$boxp" "$target" "$tgtp"
}

host_port_invalid_msg() { # host_port_invalid_msg <spec> <rc>
  if [ "${2:-1}" = 2 ]; then
    printf "box port in '%s' must be 1024 or above
     The box-side listener is opened by sshd as the box user, which cannot bind a
     privileged port. Use a high port in the box and the real port on the host,
     e.g. 8443:443." "$1"
    return
  fi
  printf "invalid host-port '%s'
     Use one of:
       5432                  the box reaches the host's 127.0.0.1:5432 at its own
       8080:5432             box 127.0.0.1:8080 -> host 127.0.0.1:5432
       8080:10.20.30.40:443  box 127.0.0.1:8080 -> that host, reached from YOUR host
       8080:[fd00::1]:443    the same, IPv6 target" "$1"
}

# Read a box's stored specs, one per line.
host_port_specs() { # host_port_specs <name>
  local csv
  csv="$(meta_get "$1" host_ports 2>/dev/null || true)"
  [ -n "$csv" ] || return 0
  printf '%s\n' "${csv//,/$'\n'}"
}

# Is the tunnel process for this box alive AND still ours? A bare `kill -0` would
# accept a recycled pid belonging to something else entirely. The box's identity
# file is what identifies it: the path contains the box name and no other process
# would carry it.
host_port_running() { # host_port_running <name>
  local pf pid args
  pf="$(host_port_pidfile "$1")"
  [ -f "$pf" ] || return 1
  pid="$(cat "$pf" 2>/dev/null || true)"
  case "$pid" in "" | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$args" in
    *"$(box_dir "$1")/id_ed25519"*) return 0 ;;
    *) return 1 ;;
  esac
}

host_port_stop() { # host_port_stop <name>
  local pf pid
  pf="$(host_port_pidfile "$1")"
  if host_port_running "$1"; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pf"
}

# (Re)start the tunnel from the box's stored specs. No specs means no process.
# Returns non-zero when the tunnel was wanted but could not be established.
host_port_start() { # host_port_start <name>
  local name="$1" spec parsed boxp target tgtp host port pid
  local -a fwd=()
  host_port_stop "$name"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    parsed="$(host_port_parse "$spec")" || continue
    read -r boxp target tgtp <<<"$parsed"
    fwd+=(-R "127.0.0.1:$boxp:$target:$tgtp")
  done < <(host_port_specs "$name")
  [ "${#fwd[@]}" -gt 0 ] || return 0

  read -r host port <<<"$(box_ssh_addr "$name")" || return 1
  [ -n "$host" ] && [ -n "$port" ] || return 1

  # ExitOnForwardFailure makes a port collision in the box a startup failure
  # rather than a live connection carrying no forwards. ServerAlive* means the
  # process exits when the box goes away instead of lingering forever.
  # nohup (not setsid) so this detaches on macOS as well as Linux.
  nohup ssh -N \
    -p "$port" \
    -i "$(box_dir "$name")/id_ed25519" \
    -o IdentitiesOnly=yes \
    -o UserKnownHostsFile="$(box_dir "$name")/known_hosts" \
    -o StrictHostKeyChecking=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ForwardAgent=no -o ForwardX11=no \
    -o ControlMaster=no -o ControlPath=none \
    "${fwd[@]}" "$CONTAINER_USER@$host" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$(host_port_pidfile "$name")"
  # ssh authenticates and requests the forwards before it is any use, and with
  # ExitOnForwardFailure it exits rather than continuing when one is refused.
  # A short settle lets that failure surface here instead of at first connect.
  local waited=0
  while [ "$waited" -lt 10 ]; do
    host_port_running "$name" || {
      rm -f "$(host_port_pidfile "$name")"
      return 1
    }
    waited=$((waited + 1))
    sleep 0.2
  done
  return 0
}

# Restart the tunnel to match stored state, reporting what happened. Used by
# every path that changes the specs or the box's running state.
host_port_sync() { # host_port_sync <name> [quiet]
  local name="$1" quiet="${2:-}"
  if [ -z "$(host_port_specs "$name")" ]; then
    host_port_stop "$name"
    return 0
  fi
  if [ "$(box_status "$name" 2>/dev/null || true)" != running ]; then
    host_port_stop "$name"
    [ -n "$quiet" ] ||
      warn "host-port forwards are stored but the box is not running — start it: isopod start $name"
    return 0
  fi
  if host_port_start "$name"; then
    return 0
  fi
  [ -n "$quiet" ] ||
    warn "could not open the host-port forwards for $name.
     A port already in use inside the box is the usual cause; check with:
       isopod host-port ls $name"
  return 1
}

cmd_host_port() { # cmd_host_port <add|rm|ls> <box> [spec]
  local action="${1:-}"
  shift 2>/dev/null || true
  case "$action" in
    -h | --help | help | "")
      render_tmpl host-port-help.txt
      return 0
      ;;
    add | rm | remove | ls | list) ;;
    *) die "unknown host-port action: $action (try: add | rm | ls)" ;;
  esac

  local name="${1:-}" spec="${2:-}"
  [ -n "$name" ] || die "usage: isopod host-port $action <box> [spec]"
  open_box "$name"

  local cur new="" e found=0
  cur="$(meta_get "$name" host_ports 2>/dev/null || true)"

  case "$action" in
    ls | list)
      if [ -z "$cur" ]; then
        printf 'no host-port forwards for %s\n' "$name"
        printf '  add one with: isopod host-port add %s <port>\n' "$name"
        return 0
      fi
      local st="not running"
      host_port_running "$name" && st="active"
      printf 'host-port forwards for %s (%s):\n\n' "$name" "$st"
      printf '  %-22s %s\n' 'IN THE BOX' 'REACHES, FROM YOUR HOST'
      local boxp target tgtp parsed
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        parsed="$(host_port_parse "$e")" || continue
        read -r boxp target tgtp <<<"$parsed"
        printf '  %-22s %s\n' "127.0.0.1:$boxp" "$target:$tgtp"
      done < <(host_port_specs "$name")
      [ "$st" = active ] ||
        printf '\nNot currently forwarding. Start the box: isopod start %s\n' "$name"
      return 0
      ;;
    add)
      [ -n "$spec" ] || die "usage: isopod host-port add <box> <port|boxport:hostport|boxport:target:port>"
      local rc=0
      host_port_parse "$spec" >/dev/null || rc=$?
      [ "$rc" = 0 ] || die "$(host_port_invalid_msg "$spec" "$rc")"
      local want_boxp e_boxp
      want_boxp="$(host_port_parse "$spec" | cut -d' ' -f1)"
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ "$e" = "$spec" ]; then
          found=1
          continue
        fi
        # Two forwards cannot share a box-side port: the second would fail under
        # ExitOnForwardFailure and take the whole tunnel — including the first —
        # down with it. Refuse here instead.
        e_boxp="$(host_port_parse "$e" | cut -d' ' -f1)" || continue
        if [ "$e_boxp" = "$want_boxp" ]; then
          die "box port $want_boxp is already forwarded for $name (see: isopod host-port ls $name)"
        fi
      done < <(host_port_specs "$name")
      if [ "$found" = 1 ]; then
        info "$spec is already forwarded for $name"
        return 0
      fi
      new="$cur${cur:+,}$spec"
      ;;
    rm | remove)
      [ -n "$spec" ] || die "usage: isopod host-port rm <box> <spec>"
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ "$e" = "$spec" ]; then
          found=1
          continue
        fi
        new="$new${new:+,}$e"
      done < <(host_port_specs "$name")
      [ "$found" = 1 ] ||
        die "$spec is not forwarded for $name (see: isopod host-port ls $name)"
      ;;
  esac

  meta_set "$name" host_ports "$new"
  # The tunnel carries every forward for the box, so any change restarts it.
  if host_port_sync "$name"; then
    if [ "$action" = add ]; then
      local boxp target tgtp
      read -r boxp target tgtp <<<"$(host_port_parse "$spec")"
      info "$name reaches $target:$tgtp at 127.0.0.1:$boxp"
    else
      info "removed $spec from $name"
    fi
  fi
}
