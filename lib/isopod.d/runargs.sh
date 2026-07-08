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

# Assemble the `$ENGINE run` argument list for a box into the global RUN_ARGS
# array (bash can't return arrays). Shared by create and reconfigure so the two
# can't drift. Hardening masks are read fresh from the profile each time.
RUN_ARGS=()
build_run_args() { # build_run_args <name> <image> <publish> <memory> <cpus> [host:ctr expose...]
  local name="$1" image="$2" publish="$3" memory="$4" cpus="$5"
  shift 5
  RUN_ARGS=(run -d --name "$(ctr_name "$name")" --hostname "$name"
  --label "isopod=true" --label "isopod.name=$name"
  -p "$publish" --pids-limit 4096)
  # Bootstrap consumed by the box entrypoint, so no host `exec` is needed to make
  # the box reachable (see share/Dockerfile). The box's PUBLIC key for
  # authorized_keys — never a secret, so its presence in the container env /
  # `inspect` is fine. BOX_SUDO (1/0) is set by create only; when unset (e.g.
  # reconfigure) the entrypoint leaves the box's existing sudo policy untouched.
  local pubfile
  pubfile="$(box_dir "$name")/id_ed25519.pub"
  [ -f "$pubfile" ] && RUN_ARGS+=(-e "ISOPOD_AUTHORIZED_KEY=$(cat "$pubfile")")
  [ -n "${BOX_SUDO:-}" ] && RUN_ARGS+=(-e "ISOPOD_SUDO=$BOX_SUDO")
  # Harden a --no-sudo box: with sudo removed there is no legitimate setuid
  # escalation to preserve, so block privilege gains (setuid binaries, newgrp).
  # On create the choice is in BOX_SUDO; on reconfigure (BOX_SUDO unset) read the
  # persisted meta. Absent/1 => sudo box => no flag, matching pre-feature boxes.
  local box_sudo="${BOX_SUDO:-}"
  [ -n "$box_sudo" ] || box_sudo="$(meta_get "$name" sudo 2>/dev/null || true)"
  [ "$box_sudo" = 0 ] && RUN_ARGS+=(--security-opt no-new-privileges)
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
    warn "Docker can't mask these host-info files (runc blocks /proc bind mounts): ${HARD_FMASKS[*]}
     — they stay readable inside the box. Use rootless podman, or a Tier 2/3 runtime
     (runsc/kata/krun), to close them. Directory masks (/sys/*) are applied normally."
  fi
  # Network egress isolation: put the box on the dedicated bridge the host
  # firewall targets and drop the raw-socket / net-admin caps so it cannot craft
  # scan packets or re-route around the host rules. All host-enforced at run time
  # — the box can't undo it. Preflight (create/reconfigure) has already verified
  # the engine can enforce this and created the network.
  case "$(active_egress)" in
    lan-deny)
      # Pin DNS to a public resolver so the box cannot query the host's
      # internal/forwarding resolver for reconnaissance.
      RUN_ARGS+=(--network "$ISOPOD_EGRESS_NET" --dns "$ISOPOD_EGRESS_DNS"
        --cap-drop NET_RAW --cap-drop NET_ADMIN)
      ;;
    allow-list)
      # Force the box through the host-side filtering proxy on the bridge
      # gateway. The host firewall drops every other box-initiated flow, so
      # unsetting these env vars just removes the box's only route out. No --dns:
      # the box gets no resolver (the proxy resolves allow-listed names), which
      # also closes DNS-tunnel exfil.
      local _proxy="http://$ISOPOD_EGRESS_GATEWAY:$ISOPOD_EGRESS_PROXY_PORT"
      RUN_ARGS+=(--network "$ISOPOD_EGRESS_NET" --cap-drop NET_RAW --cap-drop NET_ADMIN
        -e "http_proxy=$_proxy" -e "https_proxy=$_proxy"
        -e "HTTP_PROXY=$_proxy" -e "HTTPS_PROXY=$_proxy"
        -e "no_proxy=localhost,127.0.0.1,::1" -e "NO_PROXY=localhost,127.0.0.1,::1")
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
  # shellcheck disable=SC2206
  [ -n "${ISOPOD_RUN_ARGS:-}" ] && RUN_ARGS+=($ISOPOD_RUN_ARGS)
  RUN_ARGS+=("$image")
}
