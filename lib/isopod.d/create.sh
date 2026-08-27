#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines box creation.

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd_create() {
  local name="" branch="" base="$DEFAULT_BASE_IMAGE" color="" port=""
  local memory="" cpus="" sudo_opt=0 no_root_key=0 engine_opt="" dockerfile_opt="" image_opt=0
  local container_opt=0 dev_tools=0 harden_opt="" runtime_opt=""
  local disk_opt="" nested=0 guest_egress_opt="" account_opt=0 offline=0
  local -a lan_allow_opts=() host_port_opts=()
  local -a repos=() copies=() exposes=() secrets=()

  while [ $# -gt 0 ]; do
    # accept --opt=value as an alias for --opt value (e.g. --copy=path)
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --repo)
        repos+=("$2")
        shift 2
        ;;
      --branch)
        branch="$2"
        shift 2
        ;;
      --copy)
        copies+=("$2")
        shift 2
        ;;
      --color)
        color="$2"
        shift 2
        ;;
      --image)
        base="$2"
        image_opt=1
        shift 2
        ;;
      --dockerfile)
        dockerfile_opt="$2"
        shift 2
        ;;
      --expose)
        exposes+=("$2")
        shift 2
        ;;
      --secret)
        secrets+=("$2")
        shift 2
        ;;
      --engine)
        engine_opt="$2"
        shift 2
        ;;
      --memory)
        memory="$2"
        shift 2
        ;;
      --cpus)
        cpus="$2"
        shift 2
        ;;
      --port)
        port="$2"
        shift 2
        ;;
      --sudo)
        sudo_opt=1
        shift
        ;;
      # Maximum lockdown: no in-box sudo AND no administrative key, so the box has
      # no root path from anywhere. Nothing can be installed into it after create.
      --no-root-key)
        no_root_key=1
        shift
        ;;
      # Retained so existing scripts and muscle memory keep working: sudo is off
      # by default now, so this is a no-op rather than an error.
      --no-sudo)
        sudo_opt=0
        shift
        ;;
      --container)
        container_opt=1
        shift
        ;;
      --runtime)
        runtime_opt="$2"
        shift 2
        ;;
      --dev)
        dev_tools=1
        shift
        ;;
      --disk)
        disk_opt="$2"
        shift 2
        ;;
      --nested-containers)
        nested=1
        shift
        ;;
      --offline)
        offline=1
        shift
        ;;
      --harden)
        harden_opt="$2"
        shift 2
        ;;
      --guest-egress)
        guest_egress_opt="$2"
        shift 2
        ;;
      --lan-allow)
        lan_allow_opts+=("$2")
        shift 2
        ;;
      --host-port)
        host_port_opts+=("$2")
        shift 2
        ;;
      --account)
        account_opt=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option for create: $1" ;;
      *)
        [ -z "$name" ] && name="$1" || die "unexpected argument: $1"
        shift
        ;;
    esac
  done

  [ -n "$name" ] || die "usage: isopod create <name> [options]"
  valid_name "$name" || die "invalid name '$name' (letters, digits, . _ - only)"

  # Serialize from here on: the existence check, color rotation, and ssh_config
  # rewrite below all read/write shared state and must not race another create.
  acquire_lock
  [ -d "$(box_dir "$name")" ] && die "sandbox '$name' already exists (isopod rm $name to delete)"
  # Validate --port the way --expose is validated, and reject a port another box
  # already publishes (the engine would otherwise fail with an opaque bind error).
  if [ -n "$port" ]; then
    valid_port "$port" || die "invalid --port '$port' (use a 1-65535 TCP port)"
    local pd pother
    for pd in "$BOXES_DIR"/*/; do
      [ -d "$pd" ] || continue
      pother=$(basename "$pd")
      [ "$(meta_get "$pother" port 2>/dev/null || true)" = "$port" ] &&
        die "--port $port is already used by box '$pother'"
    done
  fi
  [ -n "$memory" ] && { valid_memory "$memory" || die "invalid --memory '$memory' (e.g. 512m, 2g)"; }
  [ -n "$cpus" ] && { valid_cpus "$cpus" || die "invalid --cpus '$cpus' (a positive number, e.g. 1 or 1.5)"; }
  # --nested-containers is --disk mounted at rootless podman's graph root: nested
  # podman only works with its storage on a real block device (see the entry
  # script's NESTED_STORAGE_MOUNT note). An explicit --disk size is honored; an
  # explicit mountpoint is not, because any other one leaves podman unfixed.
  if [ "$nested" -eq 1 ]; then
    case "$disk_opt" in
      *:*) die "--nested-containers sets the --disk mountpoint itself ($NESTED_STORAGE_MOUNT).
     Pass a size only (e.g. --disk 40g), or drop --nested-containers to place the volume yourself." ;;
      "") disk_opt="$NESTED_DISK_DEFAULT_SIZE:$NESTED_STORAGE_MOUNT" ;;
      *) disk_opt="$disk_opt:$NESTED_STORAGE_MOUNT" ;;
    esac
  fi
  # Validates into DISK_SIZE / DISK_MOUNT / DISK_SPEC (no-op when unset).
  parse_disk_spec "$disk_opt"
  if [ "${#repos[@]}" -gt 0 ] && [ "${#copies[@]}" -gt 0 ]; then
    die "use either --repo or --copy, not both (you can 'isopod copy-in' later)"
  fi
  # An offline box has no network to clone over. Checked here with the other
  # argument rules so it fails before any image or container work.
  if [ "$offline" = 1 ] && [ "${#repos[@]}" -gt 0 ]; then
    die "--offline leaves the box no network, so --repo has nothing to clone from.
     Copy the work in instead:  isopod create $name --offline --copy <path>"
  fi
  # Resolve each --repo to its workspace subfolder now and reject collisions,
  # so a bad set fails before the container is created (not half-populated).
  local -a repo_subs=()
  if [ "${#repos[@]}" -gt 0 ]; then
    local _u _sub _s
    for _u in "${repos[@]}"; do
      _sub=$(repo_subdir "$_u") ||
        die "could not derive a folder name from repo URL: $_u"
      for _s in "${repo_subs[@]:-}"; do
        [ "$_s" = "$_sub" ] &&
          die "two --repo values map to the same folder '$_sub' — clone one in by hand under a different name"
      done
      repo_subs+=("$_sub")
    done
  fi
  if [ -n "$dockerfile_opt" ] && [ "$image_opt" -eq 1 ]; then
    die "use either --image or --dockerfile, not both"
  fi
  [ -n "$dockerfile_opt" ] && [ ! -f "$dockerfile_opt" ] &&
    die "--dockerfile not found: $dockerfile_opt"

  # validate copy paths up front
  local p
  for p in "${copies[@]:-}"; do
    [ -z "$p" ] && continue
    [ -e "$p" ] || die "--copy path does not exist: $p"
  done

  # Validate --expose specs into loopback-only port publishings (EXPOSE_SPECS).
  parse_expose_specs "${exposes[@]:-}"

  # Validate --secret specs (SECRET_SPECS) and require every value to exist in
  # the host store now — before the rollback is armed, so a typo leaves no box.
  parse_secret_specs "${secrets[@]:-}"

  # resolve color: default auto-rotates from the name; else preset/hex
  local hex=""
  if [ -z "$color" ]; then
    hex=$(auto_color "$name")
  else
    hex=$(resolve_color "$color") || die "unknown color '$color' (use a preset or '#rrggbb')"
  fi

  detect_engine "$engine_opt"

  # --account: run this box under the sandbox account so the host firewall keyed
  # on that account's uid is its egress boundary — one that survives guest root.
  # account_create_preflight validates the preconditions visible without root and
  # dies with a clear fix if the account is not set up. Turning on engine routing
  # HERE means the base-image build and the container run both go through the
  # account and land in its store; account=1 in meta makes every later command
  # (start/stop/rm/…) route the same way via open_box.
  if [ "$account_opt" = 1 ]; then
    account_create_preflight "$ENGINE"
    # Read by engine() in engine.sh (another module, linted separately).
    # shellcheck disable=SC2034
    ISOPOD_ENGINE_AS_ACCOUNT=1
  fi

  # Resolve the effective runtime (microVM by default, --container to opt out) and
  # egress mode (allow-list by default, degrades gracefully) BEFORE the microVM
  # memory sizing and the preflights below, which both read the resolved values.
  # --runtime <name> pins a specific runtime (e.g. krun); resolve_runtime reads it
  # via active_runtime, and --container still overrides it to a plain container.
  [ -n "$runtime_opt" ] && export ISOPOD_RUNTIME="$runtime_opt"
  resolve_runtime "$ENGINE" "$container_opt"
  resolve_egress "$ENGINE"

  # A data volume is a loop-mounted image inside the box, which needs the box's
  # own kernel: a plain container has no loop devices to attach it to. Fail here
  # rather than hand back a box whose volume silently never mounted. This runs
  # after resolve_runtime so it sees the EFFECTIVE runtime — including a microVM
  # default that degraded to a container because no runtime or KVM was available.
  if [ -n "$DISK_SPEC" ]; then
    [ "$ENGINE" = container ] &&
      die "--disk is not supported on the Apple 'container' engine"
    is_microvm_runtime ||
      die "--disk needs a microVM box — a plain container has no loop devices to mount the volume on.
     This box resolved to a plain container$([ "$container_opt" -eq 1 ] && printf ' (--container)' || printf ' (no microVM runtime or KVM available — see: isopod doctor)').
     Create it under a microVM runtime, or drop --disk/--nested-containers."
  fi

  # --dockerfile: build the project's Dockerfile first and use it as the base the
  # sandbox layers sshd/git onto (same role as --image, you just hand over a
  # Dockerfile). Done before the rollback is armed so a build error leaves no box.
  if [ -n "$dockerfile_opt" ]; then
    # `|| exit 1`, not `|| die`: build_user_image runs in a command substitution,
    # so its own die() exits only that subshell and its message is the specific
    # one (it names the Dockerfile). A second die here would print a vaguer
    # message after it and read as two separate failures.
    base=$(build_user_image "$dockerfile_opt") || exit 1
  fi

  mkdir -p "$(box_dir "$name")"

  # From here a partial box exists on disk; arm rollback so any failure below
  # (image build, sshd never coming up, clone error) leaves nothing behind.
  # read by on_exit (util.sh) to unwind a half-built box; write-only here
  # shellcheck disable=SC2034
  CREATE_ROLLBACK_NAME="$name"
  chmod 700 "$CONFIG_DIR" "$BOXES_DIR" "$(box_dir "$name")" 2>/dev/null || true

  local tag
  tag=$(build_image "$base" "$dev_tools" "$nested")

  info "Generating dedicated SSH keypair for this box..."
  ssh-keygen -t ed25519 -N '' -C "isopod-$name" -f "$(box_dir "$name")/id_ed25519" -q
  # A SECOND keypair, for administrative access as root. It exists so a box does
  # not need in-box privilege escalation to be administrable: the box user has no
  # sudo by default, and root is reached over SSH with a key that lives only on
  # the host (see `isopod root-shell`). Nothing inside the box can escalate to it
  # — there is no password to capture and no setuid path to abuse — which is what
  # a compromised agent running as the box user would otherwise go after. It is
  # also the only root channel a microVM box has: the engine cannot exec into a
  # guest, so `isopod install` depends on this key there.
  if [ "$no_root_key" -eq 0 ]; then
    ssh-keygen -t ed25519 -N '' -C "isopod-$name-root" -f "$(box_dir "$name")/id_ed25519_root" -q
  else
    warn "--no-root-key: this box will have NO root access path at all — no in-box sudo
     (unless --sudo) and no administrative key. 'isopod root-shell' and 'isopod install'
     will not work on it; system packages must be baked in with --dockerfile."
  fi

  # publish sshd on a loopback-only host port; random free port unless --port
  local publish="127.0.0.1::$BOX_SSHD_PORT"
  [ -n "$port" ] && publish="127.0.0.1:$port:$BOX_SSHD_PORT"

  # A Tier 3 microVM runtime boots a fixed-size guest; if the user gave no
  # --memory, size it so the guest isn't starved.
  if [ -z "$memory" ] && is_microvm_runtime; then
    memory="$MICROVM_DEFAULT_MEMORY"
    info "microVM runtime active — defaulting --memory to $memory (override with --memory)"
  fi

  # Sudo is OFF by default (0) and opted back into with --sudo (1). A box exists
  # to contain code that is not trusted, and passwordless sudo hands that code
  # the box's root account for the asking — so the default has to be the closed
  # one. Administration does not need it: root is reachable over SSH with the
  # host-held key generated above (`isopod root-shell`), which nothing in the box
  # can reach. --sudo is for hands-on boxes where you want in-box `sudo apt` and
  # accept that anything running as the box user inherits it. The box entrypoint
  # applies this from the run env; see build_run_args.
  local BOX_SUDO
  [ "$sudo_opt" -eq 1 ] && BOX_SUDO=1 || BOX_SUDO=0
  # Kernel-hardening profile: 'default' (on for every box) or 'off'. 'strict' is
  # reserved for a future release. build_run_args turns this into the microVM
  # guest-sysctl env; container boxes keep the engine defaults regardless.
  local harden="${harden_opt:-default}"
  case "$harden" in
    default | off) ;;
    strict) die "--harden strict is not yet available (reserved for a future release); use 'default' or 'off'" ;;
    *) die "invalid --harden '$harden' (use: default | off)" ;;
  esac
  local BOX_HARDEN="$harden"
  # Guest egress isolation (microVM boxes, and only when host-side egress is not
  # doing the job — see build_run_args). On by default: with krun + passt the guest
  # is handed the host's own LAN identity, so a box with no rules is a machine on
  # your network. 'off' opts out.
  local BOX_GUEST_EGRESS="${guest_egress_opt:-on}"
  case "$BOX_GUEST_EGRESS" in
    on | off) ;;
    *) die "invalid --guest-egress '$BOX_GUEST_EGRESS' (use: on | off)" ;;
  esac
  # Private-space addresses this box may still reach (--lan-allow, repeatable).
  # Validated here so a typo fails at create time rather than silently producing a
  # box that cannot reach the service it was created for.
  local BOX_GUEST_EGRESS_ALLOW="" _la
  for _la in ${lan_allow_opts+"${lan_allow_opts[@]}"}; do
    lan_allow_valid "$_la" || die "invalid --lan-allow '$_la'
     Use an address or range, with an optional single port:
       10.20.30.40        10.20.0.0/16        10.20.30.40:5432
       fd00::1            fd00::/8            [fd00::1]:5432"
    BOX_GUEST_EGRESS_ALLOW="$BOX_GUEST_EGRESS_ALLOW${BOX_GUEST_EGRESS_ALLOW:+,}$_la"
  done
  [ -n "$BOX_GUEST_EGRESS_ALLOW" ] && [ "$BOX_GUEST_EGRESS" = off ] &&
    warn "--lan-allow has no effect with --guest-egress off (nothing is being filtered)"
  # Host services this box can reach at its own loopback (--host-port,
  # repeatable). Validated here so a bad spec fails before the box is built, and
  # checked for box-port collisions because one tunnel carries them all.
  local BOX_HOST_PORTS="" _hp _hp_rc _hp_boxp
  local -a _hp_seen=()
  for _hp in ${host_port_opts+"${host_port_opts[@]}"}; do
    _hp_rc=0
    _hp_boxp="$(host_port_parse "$_hp")" || _hp_rc=$?
    [ "$_hp_rc" = 0 ] || die "$(host_port_invalid_msg "$_hp" "$_hp_rc")"
    _hp_boxp="${_hp_boxp%% *}"
    for _s in ${_hp_seen+"${_hp_seen[@]}"}; do
      [ "$_s" = "$_hp_boxp" ] &&
        die "--host-port $_hp reuses box port $_hp_boxp; one box port can carry one forward"
    done
    _hp_seen+=("$_hp_boxp")
    BOX_HOST_PORTS="$BOX_HOST_PORTS${BOX_HOST_PORTS:+,}$_hp"
  done
  # Data volume + nested-container wiring for build_run_args (which turns these
  # into the entrypoint's boot env) and the meta below.
  local BOX_DISK="$DISK_SPEC"
  local BOX_NESTED="$nested"
  # Secret specs for build_run_args (the tmpfs mount) and the meta below; the
  # VALUES stay in the host store — only name:path pairs travel through here.
  local BOX_SECRETS
  BOX_SECRETS="$(
    IFS=,
    printf '%s' "${SECRET_SPECS[*]:-}"
  )"
  # Offline box: an internal engine network, so it has no route off the host at
  # all. This is the one strong network boundary that needs no host setup (no
  # firewall, no rootful engine, no /dev/kvm), so it stays available on exactly
  # the stock rootless install where the egress modes degrade to an open network.
  # An egress mode has nothing left to filter here, so --offline turns it off.
  # shellcheck disable=SC2034 # read by build_run_args in another module
  local BOX_OFFLINE="$offline"
  if [ "$BOX_OFFLINE" = 1 ]; then
    [ "$ENGINE" = container ] &&
      die "--offline is not supported on the Apple 'container' engine, which has no internal network.
     Use podman or docker for an offline box."
    # A microVM reaches its guest through passt, which picks its template interface
    # by following the container's default route. An internal network gets one only
    # where the engine can install static routes; without it the box boots, sshd
    # listens, and nothing can reach it. Refuse up front and name the trade rather
    # than leave a box that looks healthy in its own logs to be debugged.
    if is_microvm_runtime && ! offline_net_routable "$ENGINE"; then
      die "--offline needs a plain container on $ENGINE. A microVM box reaches its guest
     through passt, which needs a default route that $ENGINE cannot put on an internal
     network, so the box would boot with sshd running and stay unreachable.
     Add --container to trade the per-box kernel boundary for the network one:
       isopod create $name --offline --container
     Or drop --offline and keep the microVM."
    fi
    egress_explicitly_set &&
      warn "--offline overrides the configured egress mode: an offline box has no route out to filter"
    export ISOPOD_EGRESS=off
    # Guest egress goes off too: its in-guest ruleset filters the route out, and an
    # offline box has none. Leaving it on would also load a ruleset whose one job is
    # blocking private ranges the box cannot reach anyway.
    [ "$BOX_GUEST_EGRESS" = on ] && [ -n "$guest_egress_opt" ] &&
      warn "--offline turns --guest-egress off: an offline box has no route out to filter"
    BOX_GUEST_EGRESS=off
    local needs_route=0
    is_microvm_runtime && needs_route=1
    ensure_offline_network "$ENGINE" "$needs_route"
  fi
  # Verify the engine can enforce egress isolation and set up its network before
  # the box starts (no-op unless `egress lan-deny` is configured).
  egress_preflight "$ENGINE"
  # Verify a configured sandboxed runtime (Tier 2/3) can actually run before we
  # start, so a missing/unregistered runtime fails early and clearly instead of
  # as a cryptic engine error (no-op when no runtime is configured).
  runtime_preflight "$ENGINE"
  build_run_args "$name" "$tag" "$publish" "$memory" "$cpus" "${EXPOSE_SPECS[@]:-}"

  info "Starting container ($ENGINE)..."
  engine "${RUN_ARGS[@]}" >/dev/null

  # Apple `container` boxes have no published loopback port — they are reached at
  # their own vmnet IP (box_ssh_addr resolves it live), so there is no host port to
  # resolve or record. podman/docker publish sshd on a loopback port; capture it.
  local hostport=""
  if [ "$ENGINE" != container ]; then
    hostport=$(resolve_port "$name") || die "could not determine published SSH port"
  fi
  {
    printf 'engine=%s\n' "$ENGINE"
    printf 'image=%s\n' "$tag"
    printf 'base=%s\n' "$base"
    # Build provenance, so `isopod upgrade` can tell whether the box is running
    # the image the current isopod would build. image= drifts (reconfigure repoints
    # it at a snapshot of the container layer), so the ORIGINAL base tag is recorded
    # separately and left alone. The tag is a content hash of the Dockerfile,
    # entrypoint and sysctl baseline, so comparing it catches every change to what
    # a box is built from. dev= is recorded because it is part of that hash.
    printf 'base_image=%s\n' "$tag"
    printf 'built_version=%s\n' "$ISOPOD_VERSION"
    printf 'dev=%s\n' "$dev_tools"
    printf 'color=%s\n' "$hex"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'sudo=%s\n' "$BOX_SUDO"
    printf 'harden=%s\n' "$BOX_HARDEN"
    printf 'guest_egress=%s\n' "$BOX_GUEST_EGRESS"
    [ -n "$BOX_GUEST_EGRESS_ALLOW" ] &&
      printf 'guest_egress_allow=%s\n' "$BOX_GUEST_EGRESS_ALLOW"
    [ -n "$BOX_HOST_PORTS" ] && printf 'host_ports=%s\n' "$BOX_HOST_PORTS"
    # Record the effective runtime so reconfigure reproduces the box's isolation
    # tier rather than re-defaulting. "container" == plain Tier 1 (no runtime).
    printf 'runtime=%s\n' "$(active_runtime 2>/dev/null | grep . || printf container)"
    # Effective egress mode (post-resolve), so `start` can re-verify the host
    # firewall is still enforcing it — a reboot / firewalld reload can drop it.
    printf 'egress=%s\n' "$(active_egress)"
    # Whether egress was asked for and could NOT be enforced (rootless engine, no
    # host firewall). resolve_egress computes this and used to discard it after one
    # warning at create — which is exactly how a box ends up running open while its
    # owner believes it is isolated. Recorded so info/list/doctor can keep saying so.
    printf 'egress_degraded=%s\n' "${ISOPOD_EGRESS_DEGRADED:-0}"
    printf 'port=%s\n' "$hostport"
    printf 'memory=%s\n' "$memory"
    printf 'cpus=%s\n' "$cpus"
    printf 'expose=%s\n' "$(
      IFS=,
      printf '%s' "${EXPOSE_SPECS[*]:-}"
    )"
    printf 'secrets=%s\n' "$BOX_SECRETS"
    printf 'disk=%s\n' "$BOX_DISK"
    printf 'nested=%s\n' "$BOX_NESTED"
    printf 'offline=%s\n' "$BOX_OFFLINE"
    [ "$account_opt" = 1 ] && printf 'account=1\n'
  } >"$(box_dir "$name")/meta"
  write_box_config "$name"

  # The box entrypoint has already applied the sudo policy and authorized key
  # from the run env (see build_run_args / share/Dockerfile), so the box is
  # reachable over SSH without any host-side `exec`.
  ensure_ssh_include
  write_ssh_include
  info "Pinning the box's SSH host key..."
  # The rollback prints the box's last output before removing it, so point at that
  # rather than at a log the rollback is about to delete.
  scan_host_key "$name" ||
    die "sshd in the container never came up — the box's own output is shown below."
  wait_for_ssh "$name" || die "could not authenticate to the box over SSH"

  # populate the workspace (over SSH, so it works under any runtime)
  box_ssh "$name" -- mkdir -p "$WORKSPACE"
  # Stream secrets into the tmpfs before any clone, so e.g. a token at a
  # /run/secrets path is usable by follow-up setup inside the box.
  inject_secrets "$name"
  if [ "${#repos[@]}" -gt 0 ]; then
    # Each repo clones into its own subfolder ($WORKSPACE/<name>), so a box can
    # hold more than one repo and any SSH-capable IDE sees them all as folders.
    # repo_subs[] was resolved and collision-checked during validation above.
    local url sub i
    local -a clone
    for i in "${!repos[@]}"; do
      url="${repos[$i]}"
      sub="${repo_subs[$i]}"
      info "Cloning $url -> $WORKSPACE/$sub inside the box..."
      clone=(git clone)
      [ -n "$branch" ] && clone+=(--branch "$branch")
      clone+=("$url" "$WORKSPACE/$sub")
      box_ssh "$name" -- "${clone[@]}" ||
        warn "git clone failed inside the box — the sandbox was still created.
         Fix and retry from inside:  isopod shell $name   then: git clone $url $WORKSPACE/$sub
         (private repo? use an https token URL, or copy a deploy key in with copy-in)"
    done
  elif [ "${#copies[@]}" -gt 0 ]; then
    do_copy_in "$name" "${copies[@]}"
  fi

  # The box is functional now (container up, SSH authenticating, workspace
  # populated). Disarm rollback so the remaining cosmetic step can't undo it.
  # shellcheck disable=SC2034  # read by on_exit (util.sh)
  CREATE_ROLLBACK_NAME=""

  # Open the --host-port forwards now that sshd is up and authenticated. After the
  # rollback is disarmed on purpose: a forward that cannot open (a port already
  # taken in the box) is worth a warning, not the loss of a working box. The `if`
  # plus `|| true` matters — a bare `[ ... ] && host_port_sync` would let `set -e`
  # abort create when the tunnel fails, since the function is the command after
  # the final `&&`; the box would be up but create would exit before its banner.
  if [ -n "$BOX_HOST_PORTS" ]; then
    host_port_sync "$name" || true
  fi

  info "Applying window color $hex (this box only)..."
  apply_color "$name" "$hex" || warn "could not apply window color (the sandbox is fine without it)"

  render_tmpl create-success.txt
  # State the effective network posture plainly — a default-on egress that could
  # not be enforced degraded to an OPEN network above, and that must not be missed.
  egress_posture_note "$name"
  # Same for the isolation tier: the default aims at a microVM and steps down to a
  # plain container on a host without one, which is the common case and is easy to
  # miss when it is only ever a warning.
  runtime_posture_note
  # State the kernel-hardening posture too (its guest-sysctl arm only applies to
  # microVM boxes), so what the box actually got is legible at create time.
  harden_posture_note "$BOX_HARDEN"
  disk_posture_note "$name" "$BOX_DISK" "$BOX_NESTED"
}

# State what a --disk / --nested-containers box actually got. The volume is
# formatted and mounted by the entrypoint at boot, so say where it landed and
# that it is box-local storage that exposes no host directory.
disk_posture_note() { # disk_posture_note <name> <disk-spec> <nested 0|1>
  local name="$1" spec="$2" nested="${3:-0}" size mount
  [ -n "$spec" ] || return 0
  size="${spec%%:*}"
  mount="${spec#*:}"
  info "Data volume: $size ext4 at $mount — box-local (an image in the box's own
     layer, loop-mounted; no host directory is exposed). It survives stop/start
     and is destroyed with the box."
  [ "$nested" = 1 ] &&
    info "Nested containers: rootless podman is installed and its storage sits on that
     volume. Try it with:  isopod shell $name -- podman run --rm docker.io/library/busybox echo hi"
  return 0
}

repo_subdir() { # repo_subdir <url> — print the workspace subfolder name for a repo URL
  # Last path segment, with any trailing slash, ".git" suffix, or scp-style
  # "host:" prefix removed (git@host:org/repo.git -> repo, https://h/me/proj ->
  # proj). Prints nothing and fails when the result would be empty.
  local b="${1%/}"
  b="${b##*/}" # basename after the last '/'
  b="${b##*:}" # scp-style git@host:repo carries no '/'
  b="${b%.git}"
  [ -n "$b" ] || return 1
  printf '%s' "$b"
}

do_copy_in() { # do_copy_in <name> <path>...
  local name="$1"
  shift
  # Stream each item in as a tar archive over SSH: the in-box user runs the
  # extraction (so files arrive owned by it), tar preserves mtimes/modes/symlinks
  # like `$ENGINE cp` did, and it reaches the workload under any runtime.
  box_ssh "$name" -- mkdir -p "$WORKSPACE"
  local p rp base sb
  local -a seen_bases=()
  for p in "$@"; do
    [ -e "$p" ] || die "path does not exist: $p"
    rp=$(realpath "$p")
    base=$(basename "$rp")
    # Two sources sharing a basename land on the same $WORKSPACE/<base> and the
    # later one wins — warn rather than silently overwrite.
    for sb in "${seen_bases[@]:-}"; do
      [ "$sb" = "$base" ] &&
        warn "another --copy source already maps to '$WORKSPACE/$base' — overwriting it"
    done
    seen_bases+=("$base")
    info "Copying $p -> $WORKSPACE/$base (one-time copy, not a mount)"
    tar -C "$(dirname "$rp")" -cf - "$base" | box_tar_in "$name" "$WORKSPACE"
  done
}
