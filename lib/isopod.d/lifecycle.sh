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
  local d name status port color ssh note
  local -a names=() statuses=() sshs=() ports=() colors=() notes=()
  local nw=4 sw=3 # min widths for the "NAME" and "SSH" headers
  for d in "$BOXES_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    ssh=$(ctr_name "$name")
    status=$(box_status "$name" 2>/dev/null || printf 'missing')
    port=$(meta_get "$name" port || printf '?')
    color=$(meta_get "$name" color || printf '-')
    # Flags worth seeing without running `isopod info` on each box in turn.
    note=""
    box_is_stale "$name" 2>/dev/null && note="stale"
    [ "$(meta_get "$name" egress_degraded 2>/dev/null || printf 0)" = 1 ] &&
      note="${note:+$note, }egress OPEN"
    names+=("$name") statuses+=("$status") sshs+=("$ssh") ports+=("$port") colors+=("$color") notes+=("$note")
    [ "${#name}" -gt "$nw" ] && nw=${#name}
    [ "${#ssh}" -gt "$sw" ] && sw=${#ssh}
  done
  local fmt="%-${nw}s  %-10s  %-${sw}s  %-9s  %-9s  %s\n"
  # shellcheck disable=SC2059
  printf "$fmt" NAME STATUS SSH PORT COLOR NOTES
  local i
  for i in "${!names[@]}"; do
    # shellcheck disable=SC2059
    printf "$fmt" "${names[$i]}" "${statuses[$i]}" "${sshs[$i]}" "${ports[$i]}" "${colors[$i]}" "${notes[$i]}"
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
  # Host services this box can reach at its own loopback, and whether the tunnel
  # carrying them is up right now — a stored forward with a dead tunnel looks
  # identical from inside the box to one that was never added.
  local hostports
  hostports=$(meta_get "$name" host_ports || true)
  if [ -n "$hostports" ]; then
    hostports="$hostports    ($(host_port_running "$name" && printf 'active' || printf 'NOT forwarding — isopod start %s' "$name"))"
  else
    hostports="(none — see host-port add)"
  fi
  render_tmpl info.txt
}

cmd_start() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: isopod start <name>"
  open_box "$name"
  acquire_lock # refresh_port may rewrite the shared ssh_config
  engine start "$(ctr_name "$name")" >/dev/null
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
  # Reopen the host-service forwards. The tunnel is a host-side ssh process, so
  # stopping the box always kills it; nothing else would bring it back. A forward
  # that will not open is a warning inside host_port_sync, never fatal — hence the
  # `|| true`, so `set -e` does not abort a start that otherwise succeeded.
  host_port_sync "$name" || true
  info "started '$name' (ssh $(ctr_name "$name"))"
  # A box built from an older isopod is missing every fix made to the entrypoint,
  # Dockerfile and sysctl baseline since. Nothing else surfaces that, so say it on
  # every start until it is dealt with.
  warn_if_stale "$name"
}

cmd_stop() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: isopod stop <name>"
  open_box "$name"
  # Before the engine stop, so the tunnel is torn down deliberately rather than
  # left to die with the connection and leave a stale pidfile behind.
  host_port_stop "$name"
  engine stop "$(ctr_name "$name")" >/dev/null
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
# The base image tag the CURRENT isopod would build this box from. Recomputed
# from the box's own build inputs (base image, --dev, --nested-containers), so it
# tracks changes to the Dockerfile, entrypoint and sysctl baseline through
# image_tag_for's content hash.
box_wanted_base_tag() { # box_wanted_base_tag <name>
  image_tag_for "$(meta_get "$1" base)" \
    "$(meta_get "$1" dev 2>/dev/null || printf 0)" \
    "$(meta_get "$1" nested 2>/dev/null || printf 0)"
}

# Is the box running something older than what isopod would build today? A box
# created before provenance was recorded has no base_image line — it predates
# this check, so it is by definition older and reports stale.
box_is_stale() { # box_is_stale <name> — rc 0 when out of date
  local recorded want
  recorded="$(meta_get "$1" base_image 2>/dev/null || true)"
  [ -n "$recorded" ] || return 0
  want="$(box_wanted_base_tag "$1" 2>/dev/null)" || return 1
  [ "$recorded" != "$want" ]
}

# One-line staleness nudge, safe to call on any box. Kept quiet when the box is
# current, because it runs on every start.
warn_if_stale() { # warn_if_stale <name>
  box_is_stale "$1" 2>/dev/null || return 0
  local built
  built="$(meta_get "$1" built_version 2>/dev/null || true)"
  warn "box '$1' was built from an older isopod${built:+ ($built; this is $ISOPOD_VERSION)} and does not
     have fixes made since. Rebuild it onto the current image: isopod upgrade $1"
}

# Rebuild a box onto the image the current isopod would produce. This exists
# because nothing else does it: `start` re-runs the same image, and `reconfigure`
# COMMITS the container layer, which carries the old entrypoint forward and pins
# the box to a snapshot. So a fix shipped in the entrypoint, the Dockerfile or the
# sysctl baseline could never reach a box that already existed.
#
# Default is a rebase: build the current base image and move $WORKSPACE across to
# a fresh container. That also picks up base-image security updates, at the cost of
# OS state outside the workspace (installed packages) — which is why --in-place
# exists for the case where that state is expensive to recreate.
cmd_upgrade() {
  local name="" in_place=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --in-place)
        in_place=1
        shift
        ;;
      --force | -f | --yes | -y)
        force=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option for upgrade: $1" ;;
      *)
        [ -z "$name" ] && name="$1" || die "unexpected argument: $1"
        shift
        ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod upgrade <name> [--in-place] [--yes]"
  open_box "$name"
  acquire_lock

  [ "$ENGINE" = container ] &&
    die "upgrade is not supported on the Apple 'container' engine (it has no image commit
     or loopback publish to reuse). Recreate the box: copy your work out with
     'isopod export $name ...', then 'isopod rm $name' and 'isopod create $name ...'."

  # Both paths need the box up: the rebase streams the workspace out over SSH, and
  # the in-place refresh writes files into the running box.
  local status
  status=$(box_status "$name" 2>/dev/null || true)
  [ "$status" = "running" ] || cmd_start "$name"
  refresh_port "$name"

  if [ "$in_place" -eq 1 ]; then
    upgrade_in_place "$name"
    return
  fi
  upgrade_rebase "$name" "$force"
}

# --in-place: replace the isopod-owned files in the running box and reboot it.
# Fast and keeps every installed package, but it only refreshes what isopod ships
# — the base image underneath keeps whatever CVEs it had, and the box drifts
# further from anything reproducible. Deliberately does NOT touch base_image, so
# the box still reports stale and the nudge to do a real rebase does not go away.
upgrade_in_place() { # upgrade_in_place <name>
  local name="$1"
  info "Refreshing isopod's own files inside '$name' (in place)..."
  # Root is needed to write under /usr/local/bin and /etc. Prefer the
  # administrative key; fall back to sudo for a box that predates it.
  local -a asroot=()
  if [ -f "$(box_dir "$name")/id_ed25519_root" ]; then
    asroot=(root_ssh "$name")
  elif [ "$(meta_get "$name" sudo 2>/dev/null || printf 1)" = 1 ]; then
    asroot=(box_ssh "$name")
  else
    die "'$name' has neither an administrative root key nor sudo, so its files cannot be
     replaced in place. Use a full rebase instead: isopod upgrade $name"
  fi
  local sudo_prefix=""
  [ "${asroot[0]}" = box_ssh ] && sudo_prefix="sudo "

  "${asroot[@]}" -- "${sudo_prefix}sh -c 'cat >/usr/local/bin/isopod-entrypoint.new && chmod 755 /usr/local/bin/isopod-entrypoint.new && mv /usr/local/bin/isopod-entrypoint.new /usr/local/bin/isopod-entrypoint'" \
    <"$ISOPOD_ENTRYPOINT" || die "could not replace the entrypoint in '$name'"
  "${asroot[@]}" -- "${sudo_prefix}sh -c 'mkdir -p /etc/isopod && cat >/etc/isopod/hardening-sysctl.conf'" \
    <"$ISOPOD_SYSCTL_CONF" || die "could not replace the sysctl baseline in '$name'"
  # Ship the egress ruleset too, so the files the new entrypoint reads are all
  # present and consistent. It does NOT make guest egress usable here: the nft
  # binary lives in the image, which only a full rebase replaces (see the warning
  # below), and enforcement stays off for this box either way.
  "${asroot[@]}" -- "${sudo_prefix}sh -c 'mkdir -p /etc/isopod && cat >/etc/isopod/egress-guest.nft'" \
    <"$ISOPOD_GUEST_EGRESS_NFT" || die "could not replace the egress ruleset in '$name'"

  # Say this BEFORE stopping. A restart kills every process in the box, and when
  # one of them is a long-running agent session the symptom reads as a network
  # fault rather than a restart: the box comes back, SSH reconnects, but whatever
  # you were talking to is gone and never answers.
  warn "Restarting '$name' now — this TERMINATES everything running inside it,
     including any agent or editor session. Reconnect after it comes back up."
  info "Restarting '$name' so the new entrypoint runs..."
  cmd_stop "$name" >/dev/null 2>&1 || true
  cmd_start "$name"
  # built_version is deliberately NOT bumped. It records which isopod BUILT the
  # box's image, and an in-place refresh does not rebuild it — writing the current
  # version here while base_image stays old made warn_if_stale contradict itself
  # ("built from an older isopod (2.18.0; this is 2.18.0)").
  info "in-place upgrade of '$name' done."
  warn "This refreshed only isopod's own FILES. Two things it cannot do:
       - the base image is unchanged, so its packages keep whatever CVEs they had
       - anything applied through engine run flags is NOT applied, because a
         container's flags are fixed when it is created: network isolation
         (--guest-egress), the administrative root key, and no-new-privileges
     '$name' therefore still reports stale, and correctly so. Run 'isopod upgrade $name'
     (no --in-place) to get all of it, when you can afford to lose packages installed
     inside the box."
}

# Default path: build the current base image and move the workspace onto a fresh
# container, keeping the box's identity (dir, keys, published port, meta).
upgrade_rebase() { # upgrade_rebase <name> <force>
  local name="$1" force="$2"
  local base dev nested newtag oldimg port
  base="$(meta_get "$name" base)"
  dev="$(meta_get "$name" dev 2>/dev/null || printf 0)"
  nested="$(meta_get "$name" nested 2>/dev/null || printf 0)"
  oldimg="$(meta_get "$name" image || true)"
  port="$(meta_get "$name" port)"

  [ -n "$(meta_get "$name" disk 2>/dev/null || true)" ] &&
    die "upgrade cannot rebase a box with a --disk data volume — its contents live in the
     container layer this replaces. Copy the volume out yourself, then 'isopod rm $name'
     and recreate with the new settings."

  if [ "$force" -ne 1 ]; then
    printf 'Rebase '\''%s'\'' onto a freshly built image?\n' "$name"
    printf '  KEPT    : %s, your SSH keys, published port, secrets, colour, settings\n' "$WORKSPACE"
    printf '  LOST    : packages installed inside the box and any OS state outside %s\n' "$WORKSPACE"
    printf 'Proceed? [y/N] '
    local reply
    read -r reply
    case "$reply" in y | Y | yes | YES) ;; *) die "aborted" ;; esac
  fi

  # Reproduce the box's isolation tier and egress posture, exactly as reconfigure
  # does, so a rebase never silently changes what the box is.
  local saved_rt
  saved_rt=$(meta_get "$name" runtime 2>/dev/null || true)
  case "$saved_rt" in
    container) export ISOPOD_FORCE_CONTAINER=1 ;;
    "") resolve_runtime "$ENGINE" 0 ;;
    *) export ISOPOD_RUNTIME="$saved_rt" ;;
  esac
  resolve_egress "$ENGINE"
  egress_preflight "$ENGINE"
  runtime_preflight "$ENGINE"

  # Everything that can still legitimately fail happens BEFORE the container is
  # destroyed. config.yaml is the source of truth for published ports, so
  # synthesize it for a box that predates it (exactly as reconfigure does) — read
  # straight from a missing file, config_expose returns nothing and the rebuilt
  # box would silently lose its port publishings. parse_expose_specs can die, so
  # it has to run here too, not after the container is gone.
  [ -f "$(box_config_file "$name")" ] || write_box_config "$name"
  local -a exposes=()
  mapfile -t exposes < <(config_expose "$name")
  parse_expose_specs "${exposes[@]:-}"

  info "Building the current base image..."
  newtag=$(build_image "$base" "$dev" "$nested")

  # Stream the workspace to a host-side archive FIRST, before anything is
  # destroyed. If any later step fails this file is the user's work, so it is
  # never cleaned up on the error path — the message names it instead.
  local ws
  ws=$(mktemp "${TMPDIR:-/tmp}/isopod-upgrade-$name-XXXXXX.tar")
  info "Copying $WORKSPACE out of '$name'..."
  local -a rc
  set +e
  box_tar_out "$name" "$WORKSPACE" 2> >(grep -v 'file changed as we read it' >&2) >"$ws"
  rc=("${PIPESTATUS[@]}")
  set -e
  if [ "${rc[0]}" -gt 1 ]; then
    rm -f "$ws"
    die "could not read $WORKSPACE out of '$name' — nothing has been changed."
  fi

  info "Replacing the container..."
  local ctr
  ctr=$(ctr_name "$name")
  engine rm -f "$ctr" >/dev/null 2>&1 || true
  # A fresh container generates fresh SSH host keys, so the pin from the old one
  # is expected to fail. Drop it and re-pin below rather than tripping the
  # (correct) fail-closed host-key check in scan_host_key.
  rm -f "$(box_dir "$name")/known_hosts"

  local BOX_SUDO BOX_HARDEN BOX_DISK BOX_NESTED BOX_SECRETS
  # Preserve the box's OWN sudo policy rather than applying today's default. An
  # upgrade is a rebuild, not a policy change, and silently removing sudo from a
  # box someone relies on would be a nasty surprise. A box with no recorded policy
  # predates the setting, when sudo was on — keep that.
  BOX_SUDO="$(meta_get "$name" sudo 2>/dev/null || true)"
  [ -n "$BOX_SUDO" ] || BOX_SUDO=1
  # These are read by build_run_args (another module), which shellcheck lints
  # separately and so cannot see — same convention as cmd_create's block.
  # shellcheck disable=SC2034
  {
    BOX_HARDEN="$(meta_get "$name" harden 2>/dev/null || true)"
    BOX_DISK=""
    BOX_NESTED="$nested"
    BOX_SECRETS="$(meta_get "$name" secrets 2>/dev/null || true)"
  }
  build_run_args "$name" "$newtag" "127.0.0.1:$port:$BOX_SSHD_PORT" \
    "$(meta_get "$name" memory || true)" "$(meta_get "$name" cpus || true)" "${EXPOSE_SPECS[@]:-}"
  if ! engine "${RUN_ARGS[@]}" >/dev/null; then
    die "could not start the rebuilt container. Your workspace is safe at:
     $ws"
  fi

  local hostport
  hostport=$(resolve_port "$name") || die "could not determine published SSH port (workspace kept at $ws)"
  meta_set "$name" image "$newtag"
  meta_set "$name" base_image "$newtag"
  meta_set "$name" built_version "$ISOPOD_VERSION"
  meta_set "$name" port "$hostport"
  meta_set "$name" runtime "$(active_runtime 2>/dev/null | grep . || printf container)"
  meta_set "$name" egress "$(active_egress)"
  write_ssh_include
  scan_host_key "$name" >/dev/null || true
  wait_for_ssh "$name" || die "the rebuilt box did not accept SSH. Your workspace is safe at:
     $ws"

  info "Restoring $WORKSPACE into the rebuilt box..."
  box_ssh "$name" -- "mkdir -p '$WORKSPACE'" ||
    die "could not create $WORKSPACE in the rebuilt box (workspace kept at $ws)"
  box_tar_in "$name" "$WORKSPACE" <"$ws" ||
    die "could not restore the workspace. It is kept at:
     $ws"
  rm -f "$ws"

  inject_secrets "$name"
  # The container is new, so the old tunnel died with the one it replaced.
  # Non-fatal (see cmd_start): a forward that will not open must not abort here.
  host_port_sync "$name" || true
  apply_color "$name" "$(meta_get "$name" color || true)" ||
    warn "could not apply window color (the box is fine without it)"
  write_box_config "$name"
  # Drop the box's previous reconfigure snapshot, never the shared base image.
  case "$oldimg" in
    localhost/isopod-box-"$name":*) engine rmi "$oldimg" >/dev/null 2>&1 || true ;;
  esac
  info "upgraded '$name' to the current image — see: isopod info $name"
  egress_posture_note "$name"
}

cmd_reconfigure() {
  local name="" memory="" cpus="" color="" memory_set=0 cpus_set=0 color_set=0 expose_set=0
  local guest_egress="" guest_egress_set=0
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
      --guest-egress)
        guest_egress="$2" guest_egress_set=1
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

  # A --disk box can't be reconfigured. reconfigure snapshots the container layer
  # with `commit`, and the volume's backing image lives in that layer — the
  # snapshot would copy the whole volume (a 20g disk makes a 20g image), and every
  # box later built from it would carry a copy. Refuse rather than do that.
  [ -n "$(meta_get "$name" disk 2>/dev/null || true)" ] &&
    die "reconfigure is not supported on a box with a --disk data volume (its backing
     image lives in the container layer that reconfigure snapshots).
     Copy your work out (isopod export $name ...) plus anything on the volume, then
     'isopod rm $name' and recreate with the new settings."

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

  # Guest egress can be switched on an existing box, but only onto an image that
  # can actually enforce it. reconfigure recreates from a COMMIT of the current
  # container layer, so a box built before the feature has neither the nft binary
  # nor the ruleset — turning it on there would hit the entrypoint's fail-closed
  # path and leave the box with no sshd. Refuse and point at the rebuild instead.
  local BOX_GUEST_EGRESS=""
  if [ "$guest_egress_set" = 1 ]; then
    case "$guest_egress" in
      on | off) ;;
      *) die "invalid --guest-egress '$guest_egress' (use: on | off)" ;;
    esac
    if [ "$guest_egress" = on ] && box_is_stale "$name" 2>/dev/null; then
      die "'$name' was built from an older isopod, so its image has no egress ruleset to load —
     turning guest egress on would leave it unable to start sshd. Rebuild it first:
       isopod upgrade $name"
    fi
    # Read by build_run_args (another module), which shellcheck lints separately.
    # shellcheck disable=SC2034
    BOX_GUEST_EGRESS="$guest_egress"
    meta_set "$name" guest_egress "$guest_egress"
  fi

  # resolve color to a hex (keep the current one if unset)
  local hex
  hex=$(meta_get "$name" color || true)
  if [ -n "$d_color" ]; then
    hex=$(resolve_color "$d_color") || die "unknown color '$d_color' (use a preset or '#rrggbb')"
  fi

  local ctr
  ctr=$(ctr_name "$name")
  engine inspect "$ctr" >/dev/null 2>&1 || die "container for '$name' is missing; recreate the box"

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
  engine commit "$ctr" "$snap" >/dev/null || die "could not snapshot the box"

  # Recreate from the snapshot with the new flags, reusing the box's SSH port.
  local port
  port=$(meta_get "$name" port)
  engine rm -f "$ctr" >/dev/null 2>&1 || true
  build_run_args "$name" "$snap" "127.0.0.1:$port:$BOX_SSHD_PORT" "$d_memory" "$d_cpus" "${EXPOSE_SPECS[@]:-}"
  info "Recreating the container with the new settings ($ENGINE)..."
  if ! engine "${RUN_ARGS[@]}" >/dev/null; then
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
  # The container is new, so the old tunnel died with the one it replaced.
  # Non-fatal (see cmd_start): a forward that will not open must not abort here.
  host_port_sync "$name" || true
  apply_color "$name" "$hex" || warn "could not apply window color (the box is fine without it)"
  write_box_config "$name"

  # Drop the previous snapshot image (never the shared base).
  case "$old_img" in
    localhost/isopod-box-"$name":*) engine rmi "$old_img" >/dev/null 2>&1 || true ;;
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

# Administrative root shell in a box, over SSH with the host-held root key.
# The counterpart to `isopod shell`: same box, same transport, the account you
# need for package installs and system changes on a box whose user has no sudo.
cmd_root_shell() {
  local name="" print_config=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --print-ssh-config)
        print_config=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*) die "unknown option for root-shell: $1" ;;
      *)
        [ -z "$name" ] && name="$1" && shift || break
        ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod root-shell <name> [-- command...] | --print-ssh-config"
  local -a rcmd=("$@")
  open_box "$name"

  if [ "$print_config" -eq 1 ]; then
    root_ssh_config_snippet "$name"
    return
  fi

  acquire_lock
  local status
  status=$(box_status "$name" 2>/dev/null || true)
  [ "$status" = "running" ] || cmd_start "$name"
  refresh_port "$name"
  release_lock
  if [ "${#rcmd[@]}" -gt 0 ]; then
    root_ssh "$name" -- "${rcmd[*]}"
    return
  fi
  # Land in /root, NOT in the workspace. The workspace is the one directory in the
  # box an agent fully controls, and a root shell sitting in it is one `make`,
  # `npm install` or `./configure` away from running agent-authored code as root —
  # which is exactly the escalation the no-sudo default exists to prevent. Reaching
  # the workspace from here is deliberate, not the default.
  warn "This is a root shell. Anything you run from $WORKSPACE — a build, a package
     script, a Makefile — is code the box's workspace controls, and it will run as root.
     For a package, prefer: isopod install $name <pkg>"
  root_ssh "$name" -t -- "cd /root; exec bash"
}

# The ssh_config block for a box's root account, printed on request so an IDE that
# drives ssh_config (VSCodium Remote-SSH and friends) can open a root window.
#
# NOT written into the managed include automatically, and that is the point: a
# root-privileged editor window opened on the workspace executes what the workspace
# says to execute — .vscode/tasks.json with "runOn": "folderOpen" runs on connect,
# and extensions activate against workspace settings. On a box whose workspace an
# agent controls, that is a direct path from agent to root. Anyone who wants it can
# paste this in, having been told.
root_ssh_config_snippet() { # root_ssh_config_snippet <name>
  local name="$1"
  # host/port/hostkeyalias are consumed by the template through render_tmpl,
  # which shellcheck cannot see into.
  # shellcheck disable=SC2034
  local host port hostkeyalias=""
  [ -f "$(box_dir "$name")/id_ed25519_root" ] ||
    die "box '$name' has no administrative root key (created with --no-root-key, or it
     predates the feature). Rebuild it onto the current image: isopod upgrade $name"
  # shellcheck disable=SC2034
  IFS=' ' read -r host port < <(box_ssh_addr "$name") ||
    die "could not resolve the SSH address for box '$name' (is it running?)"
  # shellcheck disable=SC2034
  [ "$(box_engine "$name")" = container ] && hostkeyalias="  HostKeyAlias $(ctr_name "$name")"
  render_tmpl ssh-entry-root.txt
  printf '\n'
  warn "Opening $WORKSPACE in a ROOT editor window runs workspace-controlled code as root
     (.vscode/tasks.json 'runOn: folderOpen', extension activation). On a box running an
     agent, treat that as handing the agent root. Prefer 'isopod install $name <pkg>'."
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
