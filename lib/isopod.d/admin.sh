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
  "$ENGINE" rm -f "$(ctr_name "$name")" >/dev/null 2>&1 || true
  # Drop this box's snapshot images too (reconfigure leaves localhost/isopod-box-<name>:*),
  # so they don't accumulate. Exact-prefix match (awk index, not a regex) so box
  # 'a' never matches box 'ab'; the trailing ':' pins the boundary. The shared
  # base image (localhost/isopod-base:*) is left alone — use `isopod gc` for that.
  local img
  while IFS= read -r img; do
    [ -n "$img" ] && "$ENGINE" rmi -f "$img" >/dev/null 2>&1 || true
  done < <("$ENGINE" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
    awk -v p="localhost/isopod-box-$name:" 'index($0, p) == 1')
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
  local force=0 dry=0
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
      -h | --help)
        printf 'usage: isopod gc [--dry-run] [--force]\n'
        printf '  Remove isopod-managed images that no box still references.\n'
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
  # Any isopod-managed image not in that set is a candidate for removal.
  local img
  local -a victims=()
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    case "$img" in
      localhost/isopod-base:* | localhost/isopod-user:* | localhost/isopod-box-*:*)
        [ -n "${ref[$img]:-}" ] || victims+=("$img")
        ;;
    esac
  done < <("$ENGINE" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  if [ "${#victims[@]}" -eq 0 ]; then
    info "nothing to collect — no unreferenced isopod images."
    return 0
  fi
  printf 'Unreferenced isopod images:\n'
  printf '  %s\n' "${victims[@]}"
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
  for img in "${victims[@]}"; do
    if "$ENGINE" rmi "$img" >/dev/null 2>&1; then info "removed $img"; else
      warn "could not remove $img (still in use?)"
    fi
  done
}

cmd_doctor() {
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
  if have git-filter-repo; then
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
  else printf '  [--]      podman not installed\n'; fi
  if have docker; then
    if docker info >/dev/null 2>&1; then
      printf '  [ok]      docker (daemon reachable)\n'
    else printf '  [warn]    docker installed but daemon not reachable\n'; fi
  else printf '  [--]      docker not installed\n'; fi
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
      if [ "$tier" = 3 ] && [ ! -e /dev/kvm ]; then
        printf '  [warn]    /dev/kvm absent — the microVM runtime "%s" needs it (KVM / nested virt unavailable here)\n' "$rt"
      fi
      if [ "$(runtime_net "$rt" 2>/dev/null)" = tsi ]; then
        printf '  [warn]    "%s" uses libkrun TSI networking — SSH port-forwards into the box stall on\n' "$rt"
        printf '            bulk, so VSCodium/Cursor/JetBrains (isopod code) cannot connect. Fine for\n'
        printf '            isopod shell/copy/export; for the IDE use kata (Tier 3 microVM) or --container.\n'
      fi
    else
      printf '  [--]      sandboxed runtime: off (Tier 1 masks active; see security/hardening.conf)\n'
      # Auto-detect sandboxed runtimes the user could enable for structural (not
      # mask-based) fingerprint resistance. Tier 3 microVM (own kernel/DMI) is the
      # strongest; Tier 2 (runsc) is a syscall sandbox on the shared kernel.
      local avail
      avail="$(detect_sandboxed_runtimes)"
      if [ -n "$avail" ]; then
        printf '  [--]      available to enable: %s — add e.g. `runtime %s` to hardening.conf\n' \
          "$avail" "${avail%% *}"
      fi
    fi
  else
    printf '  [warn]    hardening profile missing (%s) — boxes start WITHOUT fingerprint masks\n' "$HARDENING_CONF"
  fi

  # Network egress isolation (host firewall; `egress lan-deny` / `allow-list`).
  case "$(active_egress)" in
    allow-list)
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
      ;;
    lan-deny)
      printf '  [ok]      egress isolation: lan-deny (boxes on %s; LAN/host/metadata/internal-DNS blocked)\n' "$ISOPOD_EGRESS_NET"
      egress_doctor_engines_and_fw
      ;;
    *)
      printf '  [--]      egress isolation: off (enable with `egress lan-deny` or `egress allow-list` in hardening.conf)\n'
      ;;
  esac

  if [ -e /dev/kvm ]; then
    local mvm
    mvm="$(detect_microvm_runtimes)"
    if [ -n "$mvm" ]; then
      printf '  [ok]      /dev/kvm present — Tier 3 microVM runtimes detected: %s\n' "$mvm"
      case " $mvm " in
        *" krun "*) printf '  [note]    krun is fine for `isopod shell`/copy/export, but its TSI networking stalls\n            SSH port-forwards, so `isopod code` (Remote-SSH) fails — use kata for the IDE\n' ;;
      esac
    else
      printf '  [ok]      /dev/kvm present — Tier 3 microVM ready; install kata (crun-vm cannot boot isopod images)\n'
    fi
  else
    printf '  [--]      /dev/kvm absent — Tier 3 microVM runtimes unavailable (Tier 1/2 still work)\n'
  fi
  have podman || have docker || {
    printf '\nInstall podman (recommended) or docker.\n'
    ok=0
  }
  [ "$ok" -eq 1 ] && printf '\nAll core prerequisites look good.\n'
}
