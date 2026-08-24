#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines engine run-argument assembly.

# Validate --expose specs ('PORT' or 'HOSTPORT:CONTAINERPORT') into the global
# EXPOSE_SPECS array (bash can't return arrays); dies on a bad spec. Shared by
# create and reconfigure so the two can't drift. build_run_args publishes each on
# 127.0.0.1 only. Fills in the caller's process (not a subshell) so `die` aborts.
EXPOSE_SPECS=()
parse_expose_specs() { # parse_expose_specs <spec...>
  EXPOSE_SPECS=()
  local spec host_p ctr_p
  for spec in "$@"; do
    [ -z "$spec" ] && continue
    case "$spec" in
      *:*) host_p="${spec%%:*}" ctr_p="${spec##*:}" ;;
      *) host_p="$spec" ctr_p="$spec" ;;
    esac
    valid_port "$host_p" && valid_port "$ctr_p" ||
      die "invalid --expose '$spec' (use PORT or HOSTPORT:CONTAINERPORT, 1-65535)"
    EXPOSE_SPECS+=("$host_p:$ctr_p")
  done
}

# Validate a --disk spec ('SIZE' or 'SIZE:MOUNTPOINT') into the globals DISK_SIZE,
# DISK_MOUNT and the normalized DISK_SPEC ("SIZE:MOUNTPOINT", what create records
# in meta and passes to the box). Dies on a bad spec. Fills in the caller's
# process (not a subshell) so `die` aborts. An empty spec clears the globals.
DISK_SIZE=""
DISK_MOUNT=""
# DISK_SPEC is consumed by cmd_create (another module), which shellcheck lints
# separately and so cannot see.
# shellcheck disable=SC2034
DISK_SPEC=""
parse_disk_spec() { # parse_disk_spec <spec>
  DISK_SIZE="" DISK_MOUNT="" DISK_SPEC=""
  local spec="${1:-}"
  [ -z "$spec" ] && return 0
  case "$spec" in
    *:*)
      DISK_SIZE="${spec%%:*}"
      DISK_MOUNT="${spec#*:}"
      ;;
    *)
      DISK_SIZE="$spec"
      DISK_MOUNT="$BOX_DISK_DEFAULT_MOUNT"
      ;;
  esac
  valid_memory "$DISK_SIZE" ||
    die "invalid --disk size '$DISK_SIZE' (use an engine size like 20g or 512m)"
  # The mountpoint reaches the box as an environment value the entrypoint expands,
  # so keep it to a plain absolute path — no shell metacharacters, no whitespace.
  [[ "$DISK_MOUNT" =~ ^/[a-zA-Z0-9._/-]*$ ]] ||
    die "invalid --disk mountpoint '$DISK_MOUNT' (an absolute path: letters, digits, . _ - /)"
  # '/' first: it also matches the trailing-slash pattern, and deserves its own
  # message. Mounting the volume over the box's root would break the box.
  case "$DISK_MOUNT" in
    /) die "invalid --disk mountpoint '/' (pick a subdirectory, e.g. $BOX_DISK_DEFAULT_MOUNT)" ;;
    */) die "invalid --disk mountpoint '$DISK_MOUNT' (no trailing slash)" ;;
    *..*) die "invalid --disk mountpoint '$DISK_MOUNT' (no '..' segments)" ;;
  esac
  # shellcheck disable=SC2034  # read by cmd_create (create.sh), linted separately
  DISK_SPEC="$DISK_SIZE:$DISK_MOUNT"
}

# Assemble the `$ENGINE run` argument list for a box into the global RUN_ARGS
# array (bash can't return arrays). Shared by create and reconfigure so the two
# can't drift. Hardening masks are read fresh from the profile each time.
# Engine flags that would dismantle the sandbox isolation isopod exists to
# provide: host filesystem exposure (-v/--mount), privilege restoration
# (--privileged/--cap-add/--security-opt), or namespace sharing with the host
# (--userns/--pid/--ipc/--uts/--network=host). ISOPOD_RUN_ARGS is an escape hatch
# for unusual environments and is word-split into the engine command line, so
# anything able to set it in the user's shell could otherwise silently turn a
# sandbox into a passthrough — with no sign of it in the box or in `isopod info`.
# Refuse by default. ISOPOD_ALLOW_UNSAFE_RUN_ARGS=1 is the deliberate override,
# because there are legitimate one-off reasons to need these.
assert_safe_run_args() { # assert_safe_run_args <arg...>
  [ "${ISOPOD_ALLOW_UNSAFE_RUN_ARGS:-0}" = 1 ] && return 0
  local a bare val want_net=0
  for a in "$@"; do
    # A flag's value may arrive as `--opt=value` OR as the NEXT token. want_net
    # carries that state for --net/--network, the only pair here whose safety
    # depends on the value; every other flag below is refused whatever it is.
    if [ "$want_net" = 1 ]; then
      want_net=0
      case "$a" in host | container:*) die_unsafe_run_arg "--network $a" ;; esac
      continue
    fi
    bare="${a%%=*}"
    val=""
    [ "$a" != "$bare" ] && val="${a#*=}"
    case "$bare" in
      --net | --network)
        # isopod sets the box's own network itself, so any OTHER value is a
        # deliberate choice worth honoring; only the host/other-container
        # namespaces defeat the sandbox.
        if [ -z "$val" ]; then
          want_net=1
        else
          case "$val" in host | container:*) die_unsafe_run_arg "$a" ;; esac
        fi
        ;;
      -v | --volume | --mount | --privileged | --userns | --pid | --ipc | --uts | --cap-add | --device | --security-opt | --systemd)
        die_unsafe_run_arg "$a"
        ;;
    esac
  done
}

die_unsafe_run_arg() { # die_unsafe_run_arg <arg>
  die "ISOPOD_RUN_ARGS contains '$1', which would break the sandbox isolation isopod
     provides (host mounts, restored privileges, or a shared host namespace).
     If you genuinely need it, set ISOPOD_ALLOW_UNSAFE_RUN_ARGS=1 to confirm."
}

RUN_ARGS=()
build_run_args() { # build_run_args <name> <image> <publish> <memory> <cpus> [host:ctr expose...]
  local name="$1" image="$2" publish="$3" memory="$4" cpus="$5"
  shift 5
  # Apple `container` runs each box in its own VM on a routable vmnet subnet and
  # takes a different, smaller flag set than podman/docker (no --hostname [set from
  # --name], --pids-limit, --security-opt, --sysctl, or -p publish — the box is
  # reached at its vmnet IP, and egress is enforced on the macOS HOST via pf, not
  # by an in-box bridge). Assemble its args separately rather than guarding each
  # podman flag, then return.
  if [ "$ENGINE" = container ]; then
    build_run_args_container "$name" "$image" "$memory" "$cpus"
    return
  fi
  RUN_ARGS=(run -d --name "$(ctr_name "$name")" --hostname "$name"
  --label "isopod=true" --label "isopod.name=$name"
  -p "$publish" --pids-limit 4096)
  # Bootstrap consumed by the box entrypoint, so no host `exec` is needed to make
  # the box reachable (see share/Dockerfile). The box's PUBLIC key for
  # authorized_keys — never a secret, so its presence in the container env /
  # `inspect` is fine. BOX_SUDO (1/0) is set by create only; when unset (e.g.
  # reconfigure) the entrypoint leaves the box's existing sudo policy untouched.
  local pubfile rootpubfile
  pubfile="$(box_dir "$name")/id_ed25519.pub"
  [ -f "$pubfile" ] && RUN_ARGS+=(-e "ISOPOD_AUTHORIZED_KEY=$(cat "$pubfile")")
  # Administrative root key (see create). Public half only — the private key never
  # leaves the host, so the box holds nothing that grants root to anything running
  # inside it. Absent on boxes created before this existed, which simply get no
  # root login and keep whatever sudo policy they were built with.
  rootpubfile="$(box_dir "$name")/id_ed25519_root.pub"
  [ -f "$rootpubfile" ] && RUN_ARGS+=(-e "ISOPOD_ROOT_AUTHORIZED_KEY=$(cat "$rootpubfile")")
  [ -n "${BOX_SUDO:-}" ] && RUN_ARGS+=(-e "ISOPOD_SUDO=$BOX_SUDO")
  # Harden a --no-sudo box: with sudo removed there is no legitimate setuid
  # escalation to preserve, so block privilege gains (setuid binaries, newgrp).
  # On create the choice is in BOX_SUDO; on reconfigure (BOX_SUDO unset) read the
  # persisted meta. Absent/1 => sudo box => no flag, matching pre-feature boxes.
  local box_sudo="${BOX_SUDO:-}"
  [ -n "$box_sudo" ] || box_sudo="$(meta_get "$name" sudo 2>/dev/null || true)"
  [ "$box_sudo" = 0 ] && RUN_ARGS+=(--security-opt no-new-privileges)
  # Kernel hardening (default profile): on a microVM box — which has its own guest
  # kernel — tell the entrypoint to apply the guest sysctls (share/hardening-sysctl.conf).
  # A container box shares the HOST kernel, so it is never asked to change sysctls
  # (that would affect the host); it keeps the engine's default seccomp/isolation.
  # 'off' disables it. On create the level is in BOX_HARDEN; on reconfigure
  # (unset) read the persisted meta; absent meta => default (breaks nothing).
  local box_harden="${BOX_HARDEN:-}"
  [ -n "$box_harden" ] || box_harden="$(meta_get "$name" harden 2>/dev/null || true)"
  [ -n "$box_harden" ] || box_harden=default
  [ "$box_harden" != off ] && is_microvm_runtime &&
    RUN_ARGS+=(-e "ISOPOD_HARDEN=$box_harden")
  # Guest egress isolation: nft rules loaded INSIDE the box by the entrypoint,
  # blocking private/LAN/CGNAT/link-local destinations. microVM boxes only — a
  # container box's entrypoint has no CAP_NET_ADMIN and could not load them.
  #
  # Mutually exclusive with host-side egress, and that is not a limitation, it is
  # correctness: an allow-list box reaches the world through a proxy on the bridge
  # gateway (10.88.7.1), which is RFC1918 — the guest rules would drop its only
  # route out. Host-side enforcement is also strictly stronger (it survives guest
  # root), so when it is active the in-guest layer has nothing to add.
  # An ABSENT meta key means a box built before this feature: its image has neither
  # the nft binary nor /etc/isopod/egress-guest.nft, so asking it to enforce would
  # hit the entrypoint's fail-closed path and leave the box with no sshd — that is,
  # unreachable, from a `reconfigure` that changed nothing else. Pre-feature boxes
  # therefore default to OFF, matching how the sudo flag treats them. cmd_create
  # always sets BOX_GUEST_EGRESS explicitly, so this fallback only ever applies to
  # boxes that predate the feature. `isopod upgrade` (a full rebase) rebuilds the
  # image and is the supported way to get enforcement onto such a box.
  local box_guest_egress="${BOX_GUEST_EGRESS:-}"
  [ -n "$box_guest_egress" ] || box_guest_egress="$(meta_get "$name" guest_egress 2>/dev/null || true)"
  [ -n "$box_guest_egress" ] || box_guest_egress=off
  if [ "$box_guest_egress" = on ] && [ -z "$(active_egress)" ] && is_microvm_runtime; then
    RUN_ARGS+=(-e "ISOPOD_GUEST_EGRESS=1" -e "ISOPOD_GUEST_EGRESS_DNS=$ISOPOD_EGRESS_DNS")
    # Private-space exemptions (isopod egress lan-allow), comma-separated. Stored
    # per box, so a box keeps them across stop/start and reconfigure. The
    # entrypoint re-validates every entry before it becomes a rule.
    local box_lan_allow="${BOX_GUEST_EGRESS_ALLOW:-}"
    [ -n "$box_lan_allow" ] ||
      box_lan_allow="$(meta_get "$name" guest_egress_allow 2>/dev/null || true)"
    [ -n "$box_lan_allow" ] &&
      RUN_ARGS+=(-e "ISOPOD_GUEST_EGRESS_ALLOW=$box_lan_allow")
  fi
  # Secrets tmpfs: memory-backed, owned by the in-box user, gone when the box
  # stops. inject_secrets streams values in over SSH after boot; nothing about
  # a secret (name or value) is visible to the engine or `inspect`. On create
  # the specs are in BOX_SECRETS; on reconfigure read the persisted meta.
  # Ownership is applied by the entrypoint at boot: tmpfs uid=/gid= mount
  # options need podman >= 4.9 and do not exist in docker.
  local box_secrets="${BOX_SECRETS:-}"
  [ -n "$box_secrets" ] || box_secrets="$(meta_get "$name" secrets 2>/dev/null || true)"
  [ -n "$box_secrets" ] &&
    RUN_ARGS+=(--tmpfs "/run/secrets:rw,noexec,nosuid,nodev,size=1m,mode=0700")
  # Data volume (--disk, "SIZE:MOUNTPOINT"). No engine mount flag is involved:
  # the entrypoint creates a sparse image in the box's own layer, formats it
  # ext4 and loop-mounts it, so no host path is exposed. On create the spec is
  # in BOX_DISK; on reconfigure (unset) read the persisted meta.
  local box_disk="${BOX_DISK:-}"
  [ -n "$box_disk" ] || box_disk="$(meta_get "$name" disk 2>/dev/null || true)"
  [ -n "$box_disk" ] && RUN_ARGS+=(-e "ISOPOD_DISK=$box_disk")
  # Nested containers (--nested-containers): the entrypoint hands /dev/fuse and
  # /dev/net/tun to the box user so rootless podman inside the box can use them.
  local box_nested="${BOX_NESTED:-}"
  [ -n "$box_nested" ] || box_nested="$(meta_get "$name" nested 2>/dev/null || true)"
  [ "$box_nested" = 1 ] && RUN_ARGS+=(-e "ISOPOD_NESTED=1")
  [ -n "$memory" ] && RUN_ARGS+=(--memory "$memory")
  [ -n "$cpus" ] && RUN_ARGS+=(--cpus "$cpus")
  # Anti-fingerprinting hardening from the hardening profile.
  local -a hard_args=()
  mapfile -t hard_args < <(hardening_run_args "$ENGINE")
  [ "${#hard_args[@]}" -gt 0 ] && RUN_ARGS+=("${hard_args[@]}")
  # Tier 3 microVM tuning: pass krun.* OCI annotations to the guest (podman only;
  # annotations are a crun/krun feature and docker run has no --annotation). e.g.
  # ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1".
  if [ "$ENGINE" = podman ] && is_microvm_runtime; then
    local -a annotations=()
    # krun defaults to libkrun TSI networking, which stalls the bulk SSH port-
    # forward that Remote-SSH ('isopod code') rides. Force passt — a real virtio-
    # net stack — so that forward works. krun-only (kata ignores it); the user can
    # override by putting their own krun.use_passt in ISOPOD_MICROVM_ANNOTATIONS.
    local rt
    rt="$(active_runtime)"
    if [ "${rt##*/}" = krun ] && [[ "$ISOPOD_MICROVM_ANNOTATIONS" != *use_passt* ]]; then
      annotations+=("krun.use_passt=1")
    fi
    local ann
    for ann in $ISOPOD_MICROVM_ANNOTATIONS; do [ -n "$ann" ] && annotations+=("$ann"); done
    for ann in "${annotations[@]:-}"; do [ -n "$ann" ] && RUN_ARGS+=(--annotation "$ann"); done
  fi
  # Docker/runc can't bind-mask /proc files; hardening_run_args skipped them.
  # Warn once here (not inside that function, which also renders the reference
  # Compose file) so the user knows those paths stay readable on Docker.
  if [ "$ENGINE" = docker ] && ! is_microvm_runtime && parse_hardening && [ "${#HARD_FMASKS[@]}" -gt 0 ]; then
    warn "SECURITY: Docker (runc) cannot mask these host-info files, so the box agent can READ them:
     ${HARD_FMASKS[*]}. That leaks host fingerprint data (kernel cmdline, disk/LUKS UUIDs, ostree
     commit, loaded modules). Close it with rootless podman or a Tier 2/3 runtime (runsc/kata/krun).
     Directory masks (/sys/*) still apply."
  fi
  # Network egress isolation: put the box on the dedicated bridge the host
  # firewall targets and drop the raw-socket / net-admin caps so it cannot craft
  # scan packets or re-route around the host rules. All host-enforced at run time
  # — the box can't undo it. Preflight (create/reconfigure) has already verified
  # the engine can enforce this and created the network.
  case "$(active_egress)" in
    lan-deny)
      # Pin DNS to a public resolver so the box cannot query the host's
      # internal/forwarding resolver for reconnaissance. --dns-search=. drops the
      # host's search domain, which podman would otherwise copy in: it names your
      # network (e.g. "search lan") and is never needed to resolve a public name.
      RUN_ARGS+=(--network "$ISOPOD_EGRESS_NET" --dns "$ISOPOD_EGRESS_DNS" --dns-search=.
        --cap-drop NET_RAW --cap-drop NET_ADMIN)
      ;;
    allow-list)
      # Force the box through the host-side filtering proxy on the bridge
      # gateway. The host firewall drops every other box-initiated flow, so
      # unsetting these env vars just removes the box's only route out.
      #
      # --dns=none: this box resolves NOTHING itself. Proxied clients send the
      # hostname to the proxy (CONNECT host:443) and the proxy resolves it, which
      # is how the allow-list can match on names at all. Without this, podman
      # copies the host's resolv.conf in, disclosing your resolvers and search
      # domain and leaving a DNS path that bypasses the proxy entirely (queries to
      # a forwarding resolver are an exfil channel no hostname allow-list sees).
      # podman drops the file completely rather than emptying it, so the
      # entrypoint writes an explanatory one — see ISOPOD_DNS_VIA_PROXY there.
      # No --dns-search here: there is no resolv.conf for a search line to go in.
      local _proxy="http://$ISOPOD_EGRESS_GATEWAY:$ISOPOD_EGRESS_PROXY_PORT"
      RUN_ARGS+=(--network "$ISOPOD_EGRESS_NET" --dns=none --cap-drop NET_RAW --cap-drop NET_ADMIN
        -e "ISOPOD_DNS_VIA_PROXY=1"
        -e "http_proxy=$_proxy" -e "https_proxy=$_proxy"
        -e "HTTP_PROXY=$_proxy" -e "HTTPS_PROXY=$_proxy"
        -e "no_proxy=localhost,127.0.0.1,::1" -e "NO_PROXY=localhost,127.0.0.1,::1")
      ;;
    *)
      # Egress off. The box keeps working resolvers — it has an open network and
      # needs them — but still drop the search domain, which is disclosure with no
      # function. Its resolver ADDRESSES stay visible, and hiding them here would
      # be cosmetic: an open box can read them from its own route table anyway.
      # Enforcing egress, not masking resolv.conf, is what closes that.
      RUN_ARGS+=(--dns-search=.)
      ;;
  esac
  # Box IPv6 egress is dropped host-side by the nft rulesets (scoped to the egress
  # bridge). As a belt, also disable IPv6 inside the box so it can't form a v6
  # address at all — covering intra-bridge link-local the forward hook won't see.
  # Best-effort: skip when the host kernel has no IPv6, where the sysctl does not
  # exist and --sysctl would abort container start (and there is no v6 anyway).
  case "$(active_egress)" in
    lan-deny | allow-list)
      if [ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        RUN_ARGS+=(--sysctl net.ipv6.conf.all.disable_ipv6=1
          --sysctl net.ipv6.conf.default.disable_ipv6=1)
      fi
      ;;
  esac
  # Loopback-only app port publishings (from --expose / config.yaml).
  local spec
  for spec in "$@"; do [ -n "$spec" ] && RUN_ARGS+=(-p "127.0.0.1:$spec"); done
  # ISOPOD_RUN_ARGS: extra args for '$ENGINE run' in unusual environments.
  # Checked before they are appended — see assert_safe_run_args.
  # shellcheck disable=SC2206
  if [ -n "${ISOPOD_RUN_ARGS:-}" ]; then
    local -a extra_run=($ISOPOD_RUN_ARGS)
    assert_safe_run_args "${extra_run[@]}"
    RUN_ARGS+=("${extra_run[@]}")
  fi
  RUN_ARGS+=("$image")
}

# Assemble the `container run` argument list for a box (Apple `container` engine)
# into RUN_ARGS. Smaller flag set than podman/docker: the box is a per-box VM
# reached at its vmnet IP (no -p publish), egress is enforced on the macOS HOST by
# pf (not an in-box bridge), and the host-fingerprint masks / OCI-runtime flags do
# not apply to a VM with its own kernel — so none of those are emitted here.
build_run_args_container() { # build_run_args_container <name> <image> <memory> <cpus>
  local name="$1" image="$2" memory="$3" cpus="$4"
  # Attach to the routable vmnet network so the box gets its own IP (the SSH
  # target) on the subnet the host pf egress anchor scopes to. --name also sets the
  # box hostname (container has no separate --hostname).
  RUN_ARGS=(run -d --name "$(ctr_name "$name")"
  --label "isopod=true" --label "isopod.name=$name"
  --network "$ISOPOD_CONTAINER_NET")
  # Bootstrap consumed by the box entrypoint (see share/Dockerfile): the box's
  # PUBLIC key for authorized_keys (never a secret), and the sudo policy (1/0).
  local pubfile rootpubfile
  pubfile="$(box_dir "$name")/id_ed25519.pub"
  [ -f "$pubfile" ] && RUN_ARGS+=(-e "ISOPOD_AUTHORIZED_KEY=$(cat "$pubfile")")
  # Administrative root key (see create). Public half only — the private key never
  # leaves the host, so the box holds nothing that grants root to anything running
  # inside it. Absent on boxes created before this existed, which simply get no
  # root login and keep whatever sudo policy they were built with.
  rootpubfile="$(box_dir "$name")/id_ed25519_root.pub"
  [ -f "$rootpubfile" ] && RUN_ARGS+=(-e "ISOPOD_ROOT_AUTHORIZED_KEY=$(cat "$rootpubfile")")
  [ -n "${BOX_SUDO:-}" ] && RUN_ARGS+=(-e "ISOPOD_SUDO=$BOX_SUDO")
  # Secrets tmpfs (memory-backed, gone when the box stops). container's --tmpfs
  # takes only a path (no size/mode options); the entrypoint owns it at boot.
  local box_secrets="${BOX_SECRETS:-}"
  [ -n "$box_secrets" ] || box_secrets="$(meta_get "$name" secrets 2>/dev/null || true)"
  [ -n "$box_secrets" ] && RUN_ARGS+=(--tmpfs /run/secrets)
  [ -n "$memory" ] && RUN_ARGS+=(--memory "$memory")
  [ -n "$cpus" ] && RUN_ARGS+=(--cpus "$cpus")
  # Egress defense-in-depth INSIDE the box — the escape-resistant block is the host
  # pf anchor, outside the VM. Pin DNS to a public resolver so the box cannot query
  # an internal/forwarding one, and drop raw-socket / net-admin so it cannot craft
  # scan packets or re-route. (Apple `container` caps use the CAP_ prefix.)
  case "$(active_egress)" in
    lan-deny | allow-list)
      RUN_ARGS+=(--dns "$ISOPOD_EGRESS_DNS"
        --cap-drop CAP_NET_RAW --cap-drop CAP_NET_ADMIN)
      ;;
  esac
  # ISOPOD_RUN_ARGS: extra args for the run, for unusual environments.
  # Checked before they are appended — see assert_safe_run_args.
  # shellcheck disable=SC2206
  if [ -n "${ISOPOD_RUN_ARGS:-}" ]; then
    local -a extra_run=($ISOPOD_RUN_ARGS)
    assert_safe_run_args "${extra_run[@]}"
    RUN_ARGS+=("${extra_run[@]}")
  fi
  RUN_ARGS+=("$image")
}
