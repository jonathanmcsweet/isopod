#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines box removal, garbage collection, and doctor.

cmd_rm() {
  local name="" force=0
  while [ $# -gt 0 ]; do
    # accept --opt=value as an alias for --opt value
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --force | -f)
        force=1
        shift
        ;;
      -*) die "unknown option: $1" ;;
      *)
        name="$1"
        shift
        ;;
    esac
  done
  [ -n "$name" ] || die "usage: isopod rm <name> [--force]"
  open_box "$name"
  if [ "$force" -ne 1 ]; then
    printf "Delete sandbox '%s'? Anything not pushed/exported is lost. [y/N] " "$name"
    read -r ans
    case "$ans" in y | Y | yes | YES) ;; *) die "aborted" ;; esac
  fi
  acquire_lock # serialize the box-dir removal + ssh_config rewrite
  # The tunnel is a host-side process; removing the box dir below would orphan it
  # along with the pidfile that identifies it.
  host_port_stop "$name"
  engine rm -f "$(ctr_name "$name")" >/dev/null 2>&1 || true
  # Drop this box's snapshot images too (reconfigure leaves localhost/isopod-box-<name>:*),
  # so they don't accumulate. Exact-prefix match (awk index, not a regex) so box
  # 'a' never matches box 'ab'; the trailing ':' pins the boundary. The shared
  # base image (localhost/isopod-base:*) is left alone — use `isopod gc` for that.
  # Apple `container` has no image commit, so its boxes leave no snapshot images
  # (and no `images --format`); skip the sweep there.
  if [ "$ENGINE" != container ]; then
    local img
    while IFS= read -r img; do
      [ -n "$img" ] && engine rmi -f "$img" >/dev/null 2>&1 || true
    done < <(engine images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
      awk -v p="localhost/isopod-box-$name:" 'index($0, p) == 1')
  fi
  rm -rf "$(box_dir "$name")"
  write_ssh_include
  info "removed '$name'"
}

# Reclaim isopod-managed images no box still references: base images
# (localhost/isopod-base:*), --dockerfile user images (localhost/isopod-user:*),
# and any orphaned snapshots (localhost/isopod-box-*:*). "Referenced" means a
# box's meta still points at it via `image` or `base`. Safe: a removed base
# image is simply rebuilt on the next create.
cmd_gc() {
  local force=0 dry=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      --force | -f)
        force=1
        shift
        ;;
      --dry-run | -n)
        dry=1
        shift
        ;;
      --json)
        json=1
        shift
        ;;
      -h | --help)
        printf 'usage: isopod gc [--dry-run] [--force] [--json]\n'
        printf '  Remove isopod-managed images that no box still references.\n'
        printf '  --json lists the unreferenced images (never removes) for tooling.\n'
        return 0
        ;;
      *) die "unknown option for gc: $1" ;;
    esac
  done
  detect_engine
  # Collect the images every existing box still depends on.
  local -A ref=()
  local d name k v
  for d in "$BOXES_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    for k in image base; do
      v=$(meta_get "$name" "$k" 2>/dev/null || true)
      [ -n "$v" ] && ref["$v"]=1
    done
  done
  # Any isopod-managed image not in that set is a candidate for removal. Sweep
  # BOTH stores: normal boxes' images live in the caller's rootless store,
  # --account boxes' in the sandbox account's. Each victim is tagged with the
  # store it lives in so removal targets the right one. Using the shared `ref` set
  # across both stores is safe in either direction — an image referenced by any
  # box is never a victim — so a base image that happens to exist in both stores
  # is only ever kept (under-collected), never wrongly removed.
  local img store spec acct_uid
  local -a victims=() stores=("0:user")
  # The account store is reachable only via podman as the account, and only once
  # it is set up with a live runtime dir (else engine() would die mid-sweep).
  # Linux-only: the account is a Linux feature, so never consult it elsewhere (a
  # same-named host user on macOS must not trigger the sweep or its warning).
  if is_linux && [ "$ENGINE" = podman ] && account_exists; then
    acct_uid="$(account_uid 2>/dev/null || true)"
    if [ -n "$acct_uid" ] && [ -d "$(account_runtime_dir)" ]; then
      stores+=("1:account")
    else
      warn "sandbox account has no live runtime dir — its image store was not swept
     (its images are not reclaimable until: sudo isopod account setup)"
    fi
  fi
  for spec in "${stores[@]}"; do
    ISOPOD_ENGINE_AS_ACCOUNT="${spec%%:*}"
    store="${spec#*:}"
    while IFS= read -r img; do
      [ -n "$img" ] || continue
      case "$img" in
        localhost/isopod-base:* | localhost/isopod-user:* | localhost/isopod-box-*:*)
          [ -n "${ref[$img]:-}" ] || victims+=("$store"$'\t'"$img")
          ;;
      esac
    done < <(engine images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  done
  ISOPOD_ENGINE_AS_ACCOUNT=0
  # Machine-readable preview: list the candidates, never remove. No prompts, so a
  # UI can show reclaimable images before offering a one-click `gc --force`.
  if [ "$json" -eq 1 ]; then
    if [ "${#victims[@]}" -eq 0 ]; then
      printf '{"images":[]}\n'
    else
      printf '{"images":%s}\n' "$(printf '%s\n' "${victims[@]#*$'\t'}" | json_lines_array)"
    fi
    return 0
  fi
  if [ "${#victims[@]}" -eq 0 ]; then
    info "nothing to collect — no unreferenced isopod images."
    return 0
  fi
  printf 'Unreferenced isopod images:\n'
  for spec in "${victims[@]}"; do
    store="${spec%%$'\t'*}" img="${spec#*$'\t'}"
    if [ "$store" = account ]; then printf '  %s  (account store)\n' "$img"; else printf '  %s\n' "$img"; fi
  done
  if [ "$dry" -eq 1 ]; then
    info "(dry run — nothing removed; re-run without --dry-run to delete)"
    return 0
  fi
  if [ "$force" -ne 1 ]; then
    printf 'Remove these %d image(s)? [y/N] ' "${#victims[@]}"
    local ans
    read -r ans
    case "$ans" in y | Y | yes | YES) ;; *) die "aborted" ;; esac
  fi
  for spec in "${victims[@]}"; do
    store="${spec%%$'\t'*}" img="${spec#*$'\t'}"
    [ "$store" = account ] && ISOPOD_ENGINE_AS_ACCOUNT=1 || ISOPOD_ENGINE_AS_ACCOUNT=0
    if engine rmi "$img" >/dev/null 2>&1; then info "removed $img"; else
      warn "could not remove $img (still in use?)"
    fi
  done
  # Read by engine() in engine.sh (linted separately, so it looks unused here).
  # shellcheck disable=SC2034
  ISOPOD_ENGINE_AS_ACCOUNT=0
}

# `isopod doctor` line(s) for the Tier-3 hardware-virt backend on Linux: /dev/kvm
# and which microVM runtimes are installed to use it.
doctor_virt_linux() {
  if [ -e /dev/kvm ]; then
    local mvm
    mvm="$(detect_microvm_runtimes)"
    if [ -n "$mvm" ]; then
      printf '  [ok]      /dev/kvm present — Tier 3 microVM runtimes detected: %s\n' "$mvm"
      case " $mvm " in
        *" krun "*) printf '  [note]    isopod runs krun with passt (krun.use_passt=1), so `isopod code` works;\n            kata is selected first when both are installed\n' ;;
      esac
    else
      printf '  [ok]      /dev/kvm present — Tier 3 microVM ready; install kata (crun-vm cannot boot isopod images)\n'
    fi
  else
    printf '  [--]      /dev/kvm absent — Tier 3 microVM runtimes unavailable (Tier 1/2 still work)\n'
  fi
}

# `isopod doctor` line(s) for macOS, where /dev/kvm does not exist. Boxes already
# run inside the podman machine / Docker Desktop VM — a hardware VM built on
# Apple's Hypervisor.framework — so that boundary IS the Tier-3-class isolation.
# Report Hypervisor.framework (the /dev/kvm equivalent) and explain that a nested
# per-box microVM runtime is a separate, still-maturing capability (M3+/macOS 15).
doctor_virt_macos() {
  local hv gen ver
  hv="$(macos_hv_support)"
  gen="$(macos_chip_generation)"
  ver="$(macos_major_version)"
  if [ "$hv" = 1 ]; then
    printf '  [ok]      Apple Hypervisor.framework present (kern.hv_support=1) — the macOS /dev/kvm equivalent\n'
    printf '  [ok]      boxes run inside the podman machine / Docker Desktop VM (a hardware VM boundary —\n'
    printf '            the Tier-3-class isolation on macOS; a plain container here is already VM-isolated)\n'
    # Stronger, PER-BOX isolation on macOS = Apple `container`: each box gets its
    # own VM AND a routable vmnet IP, so egress enforces on the HOST via pf (both
    # goals at once). krunvm is not a fit — its libkrun TSI networking gives no
    # routable per-box IP, so no SSH-by-IP and no host-pf egress. Nested krun inside
    # the engine VM is a separate, still-maturing path (needs M3+/macOS 15).
    if have container; then
      printf '  [ok]      Apple `container` present — per-box VM on a vmnet subnet: Tier-3-class isolation\n'
      printf '            AND host-level (pf) egress outside the VM. Strongest macOS option; isopod\n'
      printf '            engine wired (ISOPOD_ENGINE=container, experimental). See docs/macos-host-egress.md\n'
    else
      printf '  [--]      strongest option: `brew install container` (Apple container) — per-box VM +\n'
      printf '            vmnet subnet, so egress enforces on the macOS host via pf (outside the VM)\n'
    fi
    if macos_nested_virt_capable; then
      printf '  [note]    this Mac (Apple M%s, macOS %s) can expose nested virtualization — a nested microVM\n' "$gen" "$ver"
      printf '            runtime (ISOPOD_RUNTIME=krun) MAY work inside the engine VM. Experimental: needs a\n'
      printf '            krunkit/VMM build that surfaces nested virt. For per-box VMs, prefer Apple `container`.\n'
    elif [ -n "$gen" ]; then
      printf '  [note]    nested per-box microVMs (ISOPOD_RUNTIME=krun) need Apple M3+ on macOS 15+ (this Mac:\n'
      printf '            Apple M%s, macOS %s). For per-box VMs use Apple `container` (ISOPOD_ENGINE=container).\n' "$gen" "$ver"
    else
      printf '  [note]    nested per-box microVMs need Apple M3+ on macOS 15+. For per-box VMs use Apple\n'
      printf '            `container` (ISOPOD_ENGINE=container) — the engine VM stays the boundary otherwise.\n'
    fi
  elif [ -n "$hv" ]; then
    printf '  [warn]    Apple Hypervisor.framework NOT available (kern.hv_support=%s) — the container engine\n' "$hv"
    printf '            cannot start its VM, so no boxes will run. Check virtualization support for this Mac.\n'
  else
    printf '  [--]      could not read kern.hv_support (sysctl unavailable) — cannot report the macOS virt backend\n'
  fi
}

cmd_doctor() {
  if [ "${1:-}" = "--json" ]; then
    doctor_json
    return
  fi
  printf 'isopod %s\n\n' "$ISOPOD_VERSION"
  local ok=1
  for t in ssh ssh-keygen ssh-keyscan; do
    if have "$t"; then printf '  [ok]      %s\n' "$t"; else
      printf '  [MISSING] %s\n' "$t"
      ok=0
    fi
  done
  # git (fetch/remap) and a history-rewrite backend (remap). Not core — create,
  # code, and shell work without them — so a miss is a warning, not a failure.
  if have git; then printf '  [ok]      git (needed by fetch, remap)\n'; else
    printf '  [warn]    git not found — isopod fetch/remap need it\n'
  fi
  # Probed, not just looked up: a git-filter-repo whose Python module is missing
  # is present on PATH and still cannot run, and reporting it as the backend
  # would send the user chasing the wrong problem when remap fails.
  if filter_repo_usable; then
    printf '  [ok]      git-filter-repo (remap backend)\n'
  elif have python3; then
    printf '  [ok]      python3 (remap fallback backend)\n'
  else
    printf '  [warn]    no remap backend — install git-filter-repo or python3 for isopod remap\n'
  fi
  if have podman; then
    if podman info >/dev/null 2>&1; then
      printf '  [ok]      podman (working)\n'
    else printf '  [warn]    podman installed but not working (podman machine start?)\n'; fi
    # Rootless podman needs a subuid/subgid range for this user; Arch and Gentoo
    # do not create one with the account.
    if is_linux && [ "$(id -u)" -ne 0 ]; then
      if subid_ranges_ok; then
        printf '  [ok]      rootless subuid/subgid range for %s\n' "$(id -un)"
      else
        printf '  [warn]    no rootless subuid/subgid range — podman cannot start containers as this user\n'
        subid_fix_hint | while IFS= read -r l; do printf '            %s\n' "$l"; done
      fi
    fi
  else printf '  [--]      podman not installed\n'; fi
  if have docker; then
    if docker info >/dev/null 2>&1; then
      printf '  [ok]      docker (daemon reachable)\n'
    else printf '  [warn]    docker installed but daemon not reachable\n'; fi
  else printf '  [--]      docker not installed\n'; fi
  # Apple `container` (macOS): per-box VM on a vmnet subnet — enables host-pf egress
  # + Tier-3-class isolation. EXPERIMENTAL engine: box lifecycle wired to its CLI
  # (ISOPOD_ENGINE=container); reconfigure unsupported. See docs/macos-host-egress.md.
  if have container; then
    if engine_healthcheck container; then
      printf '  [ok]      Apple container (service running) — experimental engine: ISOPOD_ENGINE=container\n'
    else printf '  [warn]    Apple container installed but service not running — start it: container system start\n'; fi
  fi
  for app in codium cursor windsurf code; do
    if find_ide_bin "$app"; then printf '  [ok]      IDE: %-9s (%s)\n' "$app" "${IDE_CMD[*]}"; fi
  done

  # Anti-fingerprinting profile + sandboxed runtime (Tier 2 syscall sandbox /
  # Tier 3 microVM).
  if [ -f "$HARDENING_CONF" ]; then
    printf '  [ok]      hardening profile (%s)\n' "$HARDENING_CONF"
    local rt tier label
    rt="$(active_runtime)"
    if [ -n "$rt" ]; then
      tier="$(runtime_tier "$rt" 2>/dev/null || true)"
      case "$tier" in
        2) label="Tier 2 (syscall sandbox, shared kernel)" ;;
        3) label="Tier 3 (microVM, separate kernel)" ;;
        *) label="custom runtime (tier unknown)" ;;
      esac
      if runtime_available podman "$rt" || runtime_available docker "$rt"; then
        printf '  [ok]      sandboxed runtime: %s — %s\n' "$rt" "$label"
      else
        printf '  [warn]    runtime "%s" not found on host — install/register it or boxes will fail to start\n' "$rt"
      fi
      # Tier-3 hardware-virt check is host-OS specific. On Linux the backing is
      # /dev/kvm (guarded with is_linux to match runtime_preflight, so macOS never
      # gets this false "absent"). On macOS a Tier-3 runtime would run NESTED
      # inside the engine's own VM — a different, stricter requirement.
      if [ "$tier" = 3 ]; then
        if is_linux && [ ! -e /dev/kvm ]; then
          printf '  [warn]    /dev/kvm absent — the microVM runtime "%s" needs it (KVM / nested virt unavailable here)\n' "$rt"
        elif is_macos; then
          printf '  [warn]    runtime "%s" is a Tier 3 microVM; on macOS it would run NESTED inside the podman\n' "$rt"
          printf '            machine / Docker Desktop VM — needs an Apple M3+ chip on macOS 15+ and a VMM that\n'
          printf '            exposes nested virt. That engine VM is already a hardware boundary, so a plain\n'
          printf '            container there is VM-isolated without it.\n'
        fi
      fi
      if [ "$(runtime_net "$rt" 2>/dev/null)" = tsi ]; then
        printf '  [warn]    "%s" uses libkrun TSI networking — SSH port-forwards into the box stall on\n' "$rt"
        printf '            bulk, so VSCodium/Cursor/JetBrains (isopod code) cannot connect. Fine for\n'
        printf '            isopod shell/copy/export; for the IDE use kata (Tier 3 microVM) or --container.\n'
      fi
    else
      # No runtime is PINNED in hardening.conf, but that does not mean boxes run
      # unsandboxed: create auto-selects the strongest runnable sandbox by default
      # (a Tier 3 microVM when /dev/kvm and one are present, else gVisor, else a
      # plain container with a warning). Report that, not a misleading "off".
      local avail
      avail="$(detect_sandboxed_runtimes)"
      if [ -n "$avail" ]; then
        printf '  [ok]      sandboxed runtime: auto — create picks the strongest available by default\n'
        printf '            (candidates: %s; pin one with `runtime %s` in hardening.conf)\n' \
          "$avail" "${avail%% *}"
      else
        printf '  [--]      sandboxed runtime: none available — boxes run as a plain Tier 1 container\n'
        printf '            (fingerprint masks still apply). Install kata/krun (microVM) or runsc to harden.\n'
      fi
    fi
  else
    printf '  [warn]    hardening profile missing (%s) — boxes start WITHOUT fingerprint masks\n' "$HARDENING_CONF"
  fi

  # Network egress isolation (host firewall; `egress lan-deny` / `allow-list`).
  case "$(active_egress)" in
    allow-list)
      if is_macos; then
        # The allow-list proxy is a Linux systemd service; on macOS isopod enforces
        # lan-deny inside the podman machine VM instead. Report that, not a phantom proxy.
        printf '  [--]      egress isolation: allow-list configured, but its host proxy is Linux-only —\n'
        printf '            on macOS isopod enforces lan-deny inside the podman machine VM instead\n'
        egress_doctor_engines_and_fw
      else
        printf '  [ok]      egress isolation: allow-list (boxes forced through host proxy %s:%s; default-deny egress)\n' \
          "$ISOPOD_EGRESS_GATEWAY" "$ISOPOD_EGRESS_PROXY_PORT"
        local prc=0
        egress_proxy_active || prc=$?
        case "$prc" in
          0) printf '  [ok]      egress proxy running (%s)\n' "$ISOPOD_EGRESS_PROXY_UNIT" ;;
          1) printf '  [warn]    egress proxy NOT running — run: sudo isopod egress apply\n' ;;
          2) printf '  [--]      egress proxy status unknown (systemctl not found)\n' ;;
        esac
        egress_doctor_engines_and_fw
      fi
      ;;
    lan-deny)
      printf '  [ok]      egress isolation: lan-deny (boxes on %s; LAN/host/metadata/internal-DNS blocked)\n' "$ISOPOD_EGRESS_NET"
      egress_doctor_engines_and_fw
      ;;
    *)
      printf '  [--]      egress isolation: off (enable with `egress lan-deny` or `egress allow-list` in hardening.conf)\n'
      ;;
  esac

  # Hardware-virtualization backend behind Tier 3, reported per host OS: /dev/kvm
  # on Linux, Apple's Hypervisor.framework on macOS (there is no device node).
  case "$(os_kind)" in
    macos) doctor_virt_macos ;;
    *) doctor_virt_linux ;;
  esac
  doctor_boxes
  have podman || have docker || {
    printf '\nInstall podman (recommended) or docker.\n'
    ok=0
  }
  [ "$ok" -eq 1 ] && printf '\nAll core prerequisites look good.\n'
}

# Per-box health: the two conditions that are invisible day to day but change
# what a box actually is — running an image older than isopod would build now
# (so missing every fix since), and having asked for egress isolation that could
# not be applied. Both were previously reported once, at create or start, and
# then never again; a box you set up months ago is exactly the one you would
# want told about.
doctor_boxes() {
  local d name stale degraded any=0
  [ -d "$BOXES_DIR" ] || return 0
  for d in "$BOXES_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    stale=0
    box_is_stale "$name" 2>/dev/null && stale=1
    degraded=0
    box_egress_degraded "$name" && degraded=1
    [ "$stale" = 1 ] || [ "$degraded" = 1 ] || continue
    [ "$any" = 0 ] && printf '\nBoxes needing attention:\n' && any=1
    [ "$stale" = 1 ] &&
      printf '  [warn]    %s: built from an older isopod — rebuild it: isopod upgrade %s\n' "$name" "$name"
    [ "$degraded" = 1 ] &&
      printf '  [warn]    %s: egress isolation was requested but is NOT in force (open network)\n' "$name"
  done
  return 0
}
