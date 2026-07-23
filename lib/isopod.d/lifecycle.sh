#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines box lifecycle, reconfigure, shell, and IDE launch.

cmd_list() {
  if [ "${1:-}" = "--json" ]; then
    cmd_list_json
    return
  fi
  detect_engine
  # Two passes so the NAME/SSH columns size to the actual data instead of a fixed
  # width that long box names would overflow.
  local d name status port color ssh
  local -a names=() statuses=() sshs=() ports=() colors=()
  local nw=4 sw=3 # min widths for the "NAME" and "SSH" headers
  for d in "$BOXES_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    ssh=$(ctr_name "$name")
    status=$(box_status "$name" 2>/dev/null || printf 'missing')
    port=$(meta_get "$name" port || printf '?')
    color=$(meta_get "$name" color || printf '-')
    names+=("$name") statuses+=("$status") sshs+=("$ssh") ports+=("$port") colors+=("$color")
    [ "${#name}" -gt "$nw" ] && nw=${#name}
    [ "${#ssh}" -gt "$sw" ] && sw=${#ssh}
  done
  local fmt="%-${nw}s  %-10s  %-${sw}s  %-9s  %s\n"
  # shellcheck disable=SC2059
  printf "$fmt" NAME STATUS SSH PORT COLOR
  local i
  for i in "${!names[@]}"; do
    # shellcheck disable=SC2059
    printf "$fmt" "${names[$i]}" "${statuses[$i]}" "${sshs[$i]}" "${ports[$i]}" "${colors[$i]}"
  done
}

cmd_info() {
  local name="" json=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      *) [ -z "$name" ] && name="$a" ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod info <name> [--json]"
  open_box "$name"
  acquire_lock # refresh_port may rewrite the shared ssh_config
  refresh_port "$name"
  if [ "$json" = 1 ]; then
    cmd_info_json "$name"
    return
  fi
  local forwards
  forwards=$(meta_get "$name" expose || true)
  [ -n "$forwards" ] || forwards="(none — see --expose)"
  # names and targets only — secret values never leave the host store
  local secretnames
  secretnames=$(meta_get "$name" secrets || true)
  [ -n "$secretnames" ] || secretnames="(none — see create --secret)"
  render_tmpl info.txt
}

cmd_start() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: isopod start <name>"
  open_box "$name"
  acquire_lock # refresh_port may rewrite the shared ssh_config
  "$ENGINE" start "$(ctr_name "$name")" >/dev/null
  refresh_port "$name"
  # A box created with egress is on the isopod bridge; its isolation is the host
  # firewall, which a reboot / firewalld reload can silently drop. Say so loudly
  # rather than start it OPEN in silence.
  egress_start_check "$name"
  # Re-pin the host key to catch a loopback-port takeover on restart. Apple
  # `container` boxes are exempt: their key is pinned by HostKeyAlias (stable across
  # the per-start IP change) and SSH verifies it on connect, so a re-scan here would
  # only race the box's sshd coming up at its new IP for no added protection.
  [ "$(box_engine "$name")" = container ] ||
    scan_host_key "$name" >/dev/null || true # keeps stderr: a key-change warning must show
  # The secrets tmpfs is memory-backed, so a stopped box holds no secrets —
  # re-inject them on every start. Boxes without secrets skip the SSH wait.
  if [ -n "$(meta_get "$name" secrets 2>/dev/null || true)" ]; then
    wait_for_ssh "$name" || die "box started but SSH never came up — secrets were NOT injected (check: isopod info $name)"
    inject_secrets "$name"
  fi
  info "started '$name' (ssh $(ctr_name "$name"))"
}

cmd_stop() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: isopod stop <name>"
  open_box "$name"
  "$ENGINE" stop "$(ctr_name "$name")" >/dev/null
  info "stopped '$name'"
}

# Print a box's config.yaml (the readable record of its reconfigurable settings).
cmd_config() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: isopod config <name>"
  require_box "$name"
  [ -f "$(box_config_file "$name")" ] || write_box_config "$name"
  cat "$(box_config_file "$name")"
}

# Apply changed run settings to an existing box. Container run-config (ports,
# memory, cpus, masks) can't be changed in place, so we snapshot the box to an
# image (preserving its workspace + installed packages), then recreate from that
# image with the new flags. Identity (SSH key, host key, color, ssh_config) is
# preserved. Desired settings come from config.yaml; flags override it.
cmd_reconfigure() {
  local name="" memory="" cpus="" color="" memory_set=0 cpus_set=0 color_set=0 expose_set=0
  local -a exposes=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --memory)
        memory="$2" memory_set=1
        shift 2
        ;;
      --cpus)
        cpus="$2" cpus_set=1
        shift 2
        ;;
      --color)
        color="$2" color_set=1
        shift 2
        ;;
      --expose)
        exposes+=("$2") expose_set=1
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option for reconfigure: $1" ;;
      *)
        [ -z "$name" ] && name="$1" || die "unexpected argument: $1"
        shift
        ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod reconfigure <name> [--memory|--cpus|--color|--expose ...]"
  open_box "$name"
  acquire_lock

  # reconfigure snapshots the box to an image (engine `commit`) then recreates from
  # it. Apple `container` has no image-commit, so the snapshot step can't run there.
  # Recreate the box instead (copy your work out first with `isopod copy-out`).
  [ "$ENGINE" = container ] &&
    die "reconfigure is not supported on the Apple 'container' engine (it has no image commit).
     Recreate the box with the new settings: copy your work out (isopod copy-out $name ...),
     then 'isopod rm $name' and 'isopod create $name ...'."

  # Reproduce the box's isolation tier: recreate it under the SAME runtime it was
  # created with, rather than re-defaulting (which could silently flip a plain
  # container into a microVM, or vice versa). "container" == plain Tier 1. A box
  # created before this was recorded (no key) falls back to the current default.
  local saved_rt
  saved_rt=$(meta_get "$name" runtime 2>/dev/null || true)
  case "$saved_rt" in
    container) export ISOPOD_FORCE_CONTAINER=1 ;;
    "") resolve_runtime "$ENGINE" 0 ;;
    *) export ISOPOD_RUNTIME="$saved_rt" ;;
  esac
  # Degrade default-on egress gracefully instead of blocking the recreate.
  resolve_egress "$ENGINE"

  # config.yaml is the source of truth (synthesize it for pre-feature boxes),
  # with any flags overriding individual fields.
  [ -f "$(box_config_file "$name")" ] || write_box_config "$name"
  local d_memory d_cpus d_color
  d_memory=$(config_get "$name" mem_limit || true)
  d_cpus=$(config_get "$name" cpus || true)
  d_color=$(config_get "$name" x-isopod-color || true)
  local -a d_expose=()
  mapfile -t d_expose < <(config_expose "$name")
  [ "$memory_set" = 1 ] && d_memory="$memory"
  [ "$cpus_set" = 1 ] && d_cpus="$cpus"
  [ "$color_set" = 1 ] && d_color="$color"
  [ "$expose_set" = 1 ] && d_expose=("${exposes[@]}")

  # validate + normalize the exposes into EXPOSE_SPECS
  parse_expose_specs "${d_expose[@]:-}"
  [ -n "$d_memory" ] && { valid_memory "$d_memory" || die "invalid memory '$d_memory' (e.g. 512m, 2g)"; }
  [ -n "$d_cpus" ] && { valid_cpus "$d_cpus" || die "invalid cpus '$d_cpus' (a positive number, e.g. 1 or 1.5)"; }

  # resolve color to a hex (keep the current one if unset)
  local hex
  hex=$(meta_get "$name" color || true)
  if [ -n "$d_color" ]; then
    hex=$(resolve_color "$d_color") || die "unknown color '$d_color' (use a preset or '#rrggbb')"
  fi

  local ctr
  ctr=$(ctr_name "$name")
  "$ENGINE" inspect "$ctr" >/dev/null 2>&1 || die "container for '$name' is missing; recreate the box"

  # Re-check egress enforcement + network before recreating (the profile may have
  # changed since create; no-op unless `egress lan-deny` is configured).
  egress_preflight "$ENGINE"
  # Re-check the runtime too — the profile's `runtime` directive may have changed.
  runtime_preflight "$ENGINE"

  # Snapshot the box so the recreate keeps the workspace + installed packages.
  local snap old_img
  old_img=$(meta_get "$name" image || true)
  snap="localhost/isopod-box-$name:r$(date -u +%Y%m%d%H%M%S)"
  info "Snapshotting '$name' (preserves your workspace and installed packages)..."
  "$ENGINE" commit "$ctr" "$snap" >/dev/null || die "could not snapshot the box"

  # Recreate from the snapshot with the new flags, reusing the box's SSH port.
  local port
  port=$(meta_get "$name" port)
  "$ENGINE" rm -f "$ctr" >/dev/null 2>&1 || true
  build_run_args "$name" "$snap" "127.0.0.1:$port:$BOX_SSHD_PORT" "$d_memory" "$d_cpus" "${EXPOSE_SPECS[@]:-}"
  info "Recreating the container with the new settings ($ENGINE)..."
  if ! "$ENGINE" "${RUN_ARGS[@]}" >/dev/null; then
    die "recreate failed — your snapshot is saved as '$snap'"
  fi

  # Refresh runtime state and the box's records.
  local hostport
  hostport=$(resolve_port "$name") || die "could not determine published SSH port"
  meta_set "$name" image "$snap"
  meta_set "$name" port "$hostport"
  meta_set "$name" runtime "$(active_runtime 2>/dev/null | grep . || printf container)"
  meta_set "$name" egress "$(active_egress)"
  meta_set "$name" memory "$d_memory"
  meta_set "$name" cpus "$d_cpus"
  meta_set "$name" color "$hex"
  meta_set "$name" expose "$(
    IFS=,
    printf '%s' "${EXPOSE_SPECS[*]:-}"
  )"
  write_ssh_include
  scan_host_key "$name" >/dev/null || true # keeps stderr: a key-change warning must show
  if wait_for_ssh "$name"; then
    # The recreated box has a fresh (empty) secrets tmpfs — re-inject.
    inject_secrets "$name"
  else
    if [ -n "$(meta_get "$name" secrets 2>/dev/null || true)" ]; then
      warn "box recreated but SSH didn't authenticate yet — secrets were NOT injected (retry: isopod stop $name && isopod start $name)"
    else
      warn "box recreated but SSH didn't authenticate yet (check: isopod info $name)"
    fi
  fi
  apply_color "$name" "$hex" || warn "could not apply window color (the box is fine without it)"
  write_box_config "$name"

  # Drop the previous snapshot image (never the shared base).
  case "$old_img" in
    localhost/isopod-box-"$name":*) "$ENGINE" rmi "$old_img" >/dev/null 2>&1 || true ;;
  esac

  info "reconfigured '$name' — see: isopod info $name"
  egress_posture_note "$name"
}

cmd_shell() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: isopod shell <name> [-- command...]"
  shift || true
  # Anything after the name (optionally preceded by `--`) is an inline command to
  # run non-interactively in the workspace, like `docker exec` — e.g.
  # `isopod shell mybox -- ls -la`. With nothing after the name, open an
  # interactive login shell. (Arguments are re-split by the box shell, matching
  # `ssh host cmd args` semantics.)
  [ "${1:-}" = "--" ] && shift
  local -a rcmd=("$@")
  open_box "$name"
  acquire_lock # may start the box and refresh the shared ssh_config
  # Start a stopped box first (like `isopod code`), so `shell` on a stopped box
  # gives a working session instead of a raw SSH connection error.
  local status
  status=$(box_status "$name" 2>/dev/null || true)
  [ "$status" = "running" ] || cmd_start "$name"
  refresh_port "$name"
  # Release the lock before the (possibly long) session so other isopod commands
  # aren't blocked meanwhile; the on-exit trap releases it too.
  release_lock
  # Every box op goes through SSH so it enters the workload under any runtime —
  # including a microVM, where the engine's exec would not. box_ssh is a shell
  # function, so it can't be `exec`'d — call it and let its exit status propagate.
  if [ "${#rcmd[@]}" -gt 0 ]; then
    box_ssh "$name" -- "cd '$WORKSPACE' 2>/dev/null; ${rcmd[*]}"
    return
  fi
  # Interactive shell (-t for a tty), landing in the workspace. Plain `bash`
  # (not `bash -l`) sources ~/.bashrc, matching the old `engine exec` shell.
  box_ssh "$name" -t -- "cd '$WORKSPACE' 2>/dev/null; exec bash"
}

# Resolved IDE launch command (array, since Flatpak needs 'flatpak run <id>')
IDE_CMD=()

flatpak_app() { # flatpak_app <app-id> -> sets IDE_CMD if installed
  have flatpak || return 1
  if flatpak info "$1" >/dev/null 2>&1; then
    IDE_CMD=(flatpak run "$1")
    return 0
  fi
  return 1
}

# Resolve an IDE name to a launch command via the share/ide-targets table:
# try its PATH binaries, then a macOS app path, then flatpak ids — in that order.
# A name not in the table falls back to running it as a bare PATH binary.
find_ide_bin() { # find_ide_bin <app> -> sets IDE_CMD, returns 0/1
  local app="$1" f="$ISOPOD_SHARE/ide-targets"
  IDE_CMD=()
  [ -f "$f" ] || die "missing IDE target table: $f (is your isopod install complete?)"
  local aliases bins macpath flatpaks b id
  local -a blist flist
  while read -r aliases bins macpath flatpaks; do
    case "$aliases" in '' | '#'*) continue ;; esac # skip blanks and comments
    case ",$aliases," in *",$app,"*) ;; *) continue ;; esac
    IFS=',' read -ra blist <<<"$bins"
    for b in "${blist[@]}"; do
      have "$b" && {
        IDE_CMD=("$b")
        return 0
      }
    done
    [ "$macpath" != "-" ] && [ -x "$macpath" ] && {
      IDE_CMD=("$macpath")
      return 0
    }
    if [ "$flatpaks" != "-" ]; then
      IFS=',' read -ra flist <<<"$flatpaks"
      for id in "${flist[@]}"; do flatpak_app "$id" && return 0; done
    fi
    return 1 # matched this target but nothing is installed for it
  done <"$f"
  # Not a known target: try the literal name as a PATH binary.
  have "$app" && {
    IDE_CMD=("$app")
    return 0
  }
  return 1
}

# Flatpak IDEs run in their own sandbox on the HOST side. The Remote-SSH
# extension (running inside that flatpak) must be able to read isopod's SSH
# config and keys, or every connection will fail with cryptic errors.
flatpak_access_hint() { # flatpak_access_hint <app-id>
  local id="$1" perms
  perms=$(flatpak info --show-permissions "$id" 2>/dev/null || true)
  if printf '%s' "$perms" | grep -qE 'filesystems=.*\b(host|home)\b'; then
    return 0 # broad access already granted; nothing to do
  fi
  warn "the '$id' Flatpak does not appear to have access to your home dir.
         The Remote-SSH extension needs to read ~/.ssh/config and isopod's keys.
         Grant read access with:
           flatpak override --user --filesystem=\$HOME/.ssh:ro \\
             --filesystem=$CONFIG_DIR:ro $id
         then restart VSCodium and retry."
}

cmd_code() {
  local name="" app="codium" new_window=1
  while [ $# -gt 0 ]; do
    # accept --opt=value as an alias for --opt value (e.g. --app=cursor)
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --app)
        app="$2"
        shift 2
        ;;
      --reuse-window)
        new_window=0
        shift
        ;;
      -*) die "unknown option: $1" ;;
      *)
        name="$1"
        shift
        ;;
    esac
  done
  [ -n "$name" ] ||
    die "usage: isopod code <name> [--app codium|cursor|windsurf|code] [--reuse-window]"
  open_box "$name"
  acquire_lock # may start the box and refresh the shared ssh_config

  local status
  status=$(box_status "$name" 2>/dev/null || true)
  [ "$status" = "running" ] || cmd_start "$name"
  refresh_port "$name"

  find_ide_bin "$app" ||
    die "could not find '$app' (checked PATH, /Applications, and Flatpak). \
Flatpak users: 'flatpak list | grep -i ${app}' to confirm the app ID is installed."

  # Flatpak IDE? Check it can actually reach the SSH config/keys on the host.
  if [ "${IDE_CMD[0]}" = "flatpak" ]; then
    flatpak_access_hint "${IDE_CMD[2]}"
  fi

  # For VSCodium, make sure the open-source Remote-SSH extension is present.
  if [ "$app" = "codium" ] || [ "$app" = "vscodium" ]; then
    if ! "${IDE_CMD[@]}" --list-extensions 2>/dev/null | grep -qi '^jeanp413.open-remote-ssh$'; then
      info "Installing 'Open Remote - SSH' extension (jeanp413.open-remote-ssh) from Open VSX..."
      "${IDE_CMD[@]}" --install-extension jeanp413.open-remote-ssh ||
        die "failed to install jeanp413.open-remote-ssh — install it manually from Open VSX, then retry"
    fi
  fi

  local uri ide_log
  local -a ide_args=()
  uri="vscode-remote://ssh-remote+$(ctr_name "$name")$WORKSPACE"
  ide_log="$(box_dir "$name")/ide-launch.log"
  # VS Code and its forks are single-instance: without --new-window a second
  # launch hands the URI to the already-running process, which may reuse the
  # window of another box (or open nothing at all if that instance is stuck).
  [ "$new_window" -eq 1 ] && ide_args+=(--new-window)
  ide_args+=(--folder-uri "$uri")
  info "Opening $app -> $uri"
  # Capture the IDE's own output to a per-box log rather than /dev/null, so a
  # silent launch failure is at least inspectable afterwards.
  "${IDE_CMD[@]}" "${ide_args[@]}" >"$ide_log" 2>&1 &
  disown || true
  info "(if the window doesn't open, check the launch log: $ide_log — an IDE
       process that is already running but not responding will swallow the
       request; quit it and retry)"
  render_tmpl code-note.txt
}
