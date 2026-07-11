#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines egress isolation, allow-list proxy, and the egress subcommand.

# ---------------------------------------------------------------------------
# network egress isolation (`egress lan-deny`)
# ---------------------------------------------------------------------------
# Resolve the egress mode the same way as active_runtime: ISOPOD_EGRESS wins,
# else the last `egress`/`no-egress` across the baseline and the user override.
# Echoes "allow-list", "lan-deny", or "" (off). The DEFAULT (nothing configured
# anywhere) is the strict "allow-list" — egress isolation is on by default so a
# box cannot exfiltrate to arbitrary hosts. An explicit `off`/`no-egress` (or
# ISOPOD_EGRESS=off) still turns it off; see egress_explicitly_set.
active_egress() {
  local r
  if [ -n "${ISOPOD_EGRESS+x}" ]; then
    r="$ISOPOD_EGRESS" # env set (even to "off"/"") — an explicit choice
  else
    r="__unset__"
    local f key val _
    for f in "$HARDENING_CONF" "$USER_HARDENING_CONF"; do
      [ -f "$f" ] || continue
      while read -r key val _; do
        case "$key" in
          egress) r="$val" ;;
          no-egress) r="off" ;;
        esac
      done <"$f"
    done
  fi
  # Nothing configured anywhere -> default to the strict allow-list.
  [ "$r" = "__unset__" ] && r="allow-list"
  # Only the two known modes are "on"; anything else (off, blank, a typo) is
  # treated as disabled so a bad directive fails safe rather than half-enabling.
  case "$r" in lan-deny | allow-list) ;; *) r="" ;; esac
  printf '%s' "$r"
}

# True when the egress mode was chosen explicitly (ISOPOD_EGRESS set, or an
# `egress`/`no-egress` directive in a profile), vs. left at the default. Callers
# use this to keep the fail-closed preflight for boxes that ASKED for egress,
# while letting the default-on egress degrade gracefully instead of blocking a
# create (see resolve_egress).
egress_explicitly_set() {
  [ -n "${ISOPOD_EGRESS+x}" ] && return 0
  local f key _
  for f in "$HARDENING_CONF" "$USER_HARDENING_CONF"; do
    [ -f "$f" ] || continue
    while read -r key _; do
      case "$key" in egress | no-egress) return 0 ;; esac
    done <"$f"
  done
  return 1
}

# Validate the egress network parameters before they are interpolated into an
# nft ruleset that is loaded as root, or into the engine run args. These are
# env-overridable; a malformed value (a typo in ISOPOD_EGRESS_SUBNET, say) would
# otherwise render a silently-broken firewall loaded under sudo — fail closed
# with a clear error instead of fail-open.
egress_validate_vars() {
  valid_cidr "$ISOPOD_EGRESS_SUBNET" ||
    die "ISOPOD_EGRESS_SUBNET='$ISOPOD_EGRESS_SUBNET' is not a valid IPv4 CIDR (e.g. 10.88.7.0/24)"
  valid_ipv4 "$ISOPOD_EGRESS_GATEWAY" ||
    die "ISOPOD_EGRESS_GATEWAY='$ISOPOD_EGRESS_GATEWAY' is not a valid IPv4 address"
  valid_ipv4 "$ISOPOD_EGRESS_DNS" ||
    die "ISOPOD_EGRESS_DNS='$ISOPOD_EGRESS_DNS' is not a valid IPv4 address"
  valid_port "$ISOPOD_EGRESS_PROXY_PORT" ||
    die "ISOPOD_EGRESS_PROXY_PORT='$ISOPOD_EGRESS_PROXY_PORT' is not a valid TCP port (1-65535)"
  valid_ifname "$ISOPOD_EGRESS_IFACE" ||
    die "ISOPOD_EGRESS_IFACE='$ISOPOD_EGRESS_IFACE' is not a valid interface name (<=15 chars, [A-Za-z0-9._-])"
}

# The active nftables ruleset for the current mode: the default LAN-deny rules,
# or the default-deny allow-list rules that force traffic through the proxy.
egress_ruleset() {
  case "$(active_egress)" in
    allow-list) printf '%s' "$ISOPOD_EGRESS_ALLOWLIST_RULESET" ;;
    *) printf '%s' "$ISOPOD_EGRESS_RULESET" ;;
  esac
}

# True when the engine places boxes on a HOST-namespace bridge, which is where
# the security/egress-host.nft rules take effect. Rootful podman (netavark) and
# rootful docker qualify. A rootless engine routes the box through a userspace
# stack (pasta/slirp4netns) with no host bridge, so host firewall rules never see
# the box's traffic and `egress lan-deny` cannot be enforced.
egress_can_enforce() { # egress_can_enforce <engine>
  case "$1" in
    podman) [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = false ] ;;
    docker)
      # Docker has no boolean rootless field; SecurityOptions is a list whose
      # entries look like 'name=seccomp,profile=default' or 'name=rootless'.
      # Match the exact 'name=rootless' token (one entry per line) rather than a
      # bare 'rootless' substring, which could match a profile path.
      ! docker info --format '{{range .SecurityOptions}}{{println .}}{{end}}' 2>/dev/null |
        grep -qx 'name=rootless'
      ;;
    *) return 1 ;;
  esac
}

# Ensure the dedicated egress bridge exists, with a fixed subnet the host firewall
# can target and inter-box traffic disabled (docker ICC off; podman relies on the
# ruleset's intra-subnet drop). Idempotent. v4-only on purpose: no IPv6 route means
# no IPv6 egress path for a box to slip around the v4 rules.
# Warn if a pre-existing egress network's subnet(s) don't include the one the host
# firewall targets — otherwise the rules would silently not match the box's IP and
# the box would be unprotected. Best effort: stays quiet when the subnet can't be
# read (empty), so a format-string quirk degrades to no false alarm, not noise.
egress_check_subnet() { # egress_check_subnet <engine> <subnets>
  local engine="$1" subnets="$2"
  [ -n "${subnets// /}" ] || return 0
  # A dual-stack network hands a box a v6 address. isopod drops box IPv6 egress at
  # the host firewall (scoped to its bridge '$ISOPOD_EGRESS_IFACE') and disables
  # IPv6 in the box, so this stays closed — but a network recreated out of band may
  # not carry the fixed bridge name the nft rules target. A v4-only network is
  # cleaner; flag it.
  case "$subnets" in
    *:*) warn "network '$ISOPOD_EGRESS_NET' has an IPv6 subnet. isopod drops box IPv6 egress at the
       host firewall and disables IPv6 in the box, but a v4-only network is cleaner. Recreate it:
       $engine network rm $ISOPOD_EGRESS_NET" ;;
  esac
  case " $subnets " in
    *" $ISOPOD_EGRESS_SUBNET "*) : ;;
    *) warn "network '$ISOPOD_EGRESS_NET' exists with subnet(s) [${subnets% }] but the egress
       firewall targets $ISOPOD_EGRESS_SUBNET — they must match or the LAN block will not apply.
       Recreate it ('$engine network rm $ISOPOD_EGRESS_NET') or set ISOPOD_EGRESS_SUBNET." ;;
  esac
}

ensure_egress_network() { # ensure_egress_network <engine>
  local engine="$1" subnets=""
  # Already present? Confirm its subnet matches the firewall's, then reuse it.
  if [ "$engine" = docker ]; then
    if docker network inspect "$ISOPOD_EGRESS_NET" >/dev/null 2>&1; then
      subnets=$(docker network inspect "$ISOPOD_EGRESS_NET" \
        --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)
      egress_check_subnet "$engine" "$subnets"
      return 0
    fi
  else
    if "$engine" network exists "$ISOPOD_EGRESS_NET" 2>/dev/null; then
      subnets=$("$engine" network inspect "$ISOPOD_EGRESS_NET" \
        --format '{{range .Subnets}}{{.Subnet}} {{end}}' 2>/dev/null || true)
      egress_check_subnet "$engine" "$subnets"
      return 0
    fi
  fi
  info "Creating dedicated egress network '$ISOPOD_EGRESS_NET' ($ISOPOD_EGRESS_SUBNET)..."
  # Pin a fixed host-bridge interface name so the nft rulesets can statically scope
  # their IPv6 drop to it (iifname). Without this the engines pick an unpredictable
  # name (podman1 / br-<id>) the rules could not target.
  if [ "$engine" = docker ]; then
    docker network create --subnet "$ISOPOD_EGRESS_SUBNET" --gateway "$ISOPOD_EGRESS_GATEWAY" \
      -o com.docker.network.bridge.enable_icc=false \
      -o com.docker.network.bridge.name="$ISOPOD_EGRESS_IFACE" "$ISOPOD_EGRESS_NET" >/dev/null ||
      die "could not create docker network '$ISOPOD_EGRESS_NET'"
  else
    podman network create --subnet "$ISOPOD_EGRESS_SUBNET" --gateway "$ISOPOD_EGRESS_GATEWAY" \
      --interface-name "$ISOPOD_EGRESS_IFACE" "$ISOPOD_EGRESS_NET" >/dev/null ||
      die "could not create podman network '$ISOPOD_EGRESS_NET'"
  fi
}

# Is the host egress firewall loaded? 0 = loaded, 1 = not loaded, 2 = unknown
# (nft missing, or reading it needs root we don't have — a false "not loaded"
# would be misleading, so we report unknown instead).
egress_rules_loaded() {
  if egress_enforce_in_vm; then
    # macOS: the rules live inside the podman machine VM. Unreachable VM -> unknown
    # (2), not "not loaded" (1), so a stopped machine never reads as a firewall gap.
    egress_vm_ready || return 2
    egress_vm_root nft list table inet isopod >/dev/null 2>&1 && return 0
    return 1
  fi
  have nft || return 2
  local err
  err=$(nft list table inet isopod 2>&1 >/dev/null) && return 0
  case "$err" in
    *"permission denied"* | *"Operation not permitted"* | *"not permitted"*) return 2 ;;
    *) return 1 ;;
  esac
}

# --- macOS: enforce inside the podman machine VM ----------------------------
# On macOS the `isopod` script runs on the Mac, but boxes run inside the podman
# machine Linux VM — which is where nftables, the box bridge, and the ruleset's
# subnet/gateway/interface actually live. The Mac host has no nftables and no box
# bridge, so the SAME egress ruleset is loaded and inspected INSIDE that VM over
# podman's management SSH rather than on the Mac. (The Mac-native packet filter,
# pf, is the wrong layer: it only sees post-NAT traffic already sourced from the
# VM, so it cannot tell a box-initiated flow from the VM's own and cannot match
# the per-box subnet the rules key on.) The allow-list's filtering proxy is a
# host systemd service and is not ported here, so only lan-deny is VM-enforced.
#
# Windows/WSL users run isopod inside the Linux side, so they take the native
# Linux path above; only macOS routes through the VM.
#
# NOTE: the Linux host path is covered by CI; this podman-machine path has NOT
# been exercised from CI (no macOS runner) — validate on a real Mac. Docker
# Desktop's VM is not a general SSH target, so only podman machine is wired.
egress_enforce_in_vm() { is_macos; }

# Is the podman machine VM present and running (a usable nft target)?
egress_vm_ready() {
  have podman || return 1
  podman machine ssh -- true >/dev/null 2>&1
}

# Run a command as root inside the podman machine VM. Stdin is forwarded, so
# `... | egress_vm_root nft -f -` loads a rendered ruleset. Returns 127 when the
# VM is unreachable so callers can tell "can't reach VM" from a real failure.
egress_vm_root() { # egress_vm_root <cmd...>
  have podman || return 127
  podman machine ssh -- sudo "$@"
}

# Fixed in-VM paths for the macOS persistence unit (parity with the Linux boot
# unit, but living inside the podman machine VM's systemd, not the Mac's).
ISOPOD_VM_NFT_FILE="/etc/isopod/egress.nft"
ISOPOD_VM_NFT_UNIT="isopod-egress"

# macOS boot persistence: install a systemd unit INSIDE the podman machine VM
# that re-loads the ruleset on VM boot — the equivalent of the Linux
# egress_persist host unit. The FCOS podman machine ships systemd, so this is the
# natural home. Only lan-deny is enforced on macOS, so persist the lan-deny
# ruleset regardless of a configured allow-list (which has no macOS proxy).
egress_persist_macos() {
  egress_vm_ready ||
    die "podman machine VM is not reachable — start it (podman machine start), then retry."
  egress_validate_vars
  local rendered
  rendered="$(ISOPOD_EGRESS=lan-deny render_tmpl "$ISOPOD_EGRESS_RULESET")"
  info "Installing the egress firewall as a boot unit inside the podman machine VM..."
  egress_vm_root mkdir -p "$(dirname "$ISOPOD_VM_NFT_FILE")" ||
    die "could not prepare state dir inside the VM"
  printf '%s\n' "$rendered" | egress_vm_root tee "$ISOPOD_VM_NFT_FILE" >/dev/null ||
    die "could not write the ruleset inside the VM"
  printf '%s\n' \
    '[Unit]' \
    'Description=isopod egress firewall (nftables)' \
    'After=network-pre.target nftables.service' \
    'Wants=network-pre.target' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=/usr/sbin/nft -f $ISOPOD_VM_NFT_FILE" \
    'RemainAfterExit=yes' \
    '[Install]' \
    'WantedBy=multi-user.target' |
    egress_vm_root tee "/etc/systemd/system/$ISOPOD_VM_NFT_UNIT.service" >/dev/null ||
    die "could not install the systemd unit inside the VM"
  egress_vm_root systemctl daemon-reload
  egress_vm_root systemctl enable --now "$ISOPOD_VM_NFT_UNIT.service" ||
    die "failed to enable $ISOPOD_VM_NFT_UNIT inside the VM — check: podman machine ssh sudo systemctl status $ISOPOD_VM_NFT_UNIT"
  info "egress firewall will re-load on VM boot (unit '$ISOPOD_VM_NFT_UNIT' inside the podman machine)."
  warn "the snapshot is loaded as-is: re-run 'isopod egress persist' if you change ISOPOD_EGRESS_* vars."
}

egress_unpersist_macos() {
  egress_vm_ready ||
    die "podman machine VM is not reachable — start it (podman machine start), then retry."
  egress_vm_root systemctl disable --now "$ISOPOD_VM_NFT_UNIT.service" 2>/dev/null || true
  egress_vm_root rm -f "/etc/systemd/system/$ISOPOD_VM_NFT_UNIT.service" "$ISOPOD_VM_NFT_FILE"
  egress_vm_root systemctl daemon-reload
  info "removed the in-VM egress boot unit ('$ISOPOD_VM_NFT_UNIT'). A loaded ruleset stays until flushed or 'podman machine stop'."
}

# --- egress allow-list: host-side filtering proxy ---------------------------
# The allow-list mode adds a filtering proxy the host firewall forces boxes
# through. Applying it writes root-owned host state (proxy config/filter, a
# systemd unit) and manages a service, so these helpers run privileged steps
# via sudo when not already root, mirroring `egress apply`'s nft loading.
egr_run_root() { # egr_run_root <cmd...>
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else die "'$*' needs root — re-run as root, or install sudo"; fi
}
egr_write_root() { # egr_write_root <path>   (content on stdin)
  if [ "$(id -u)" -eq 0 ]; then
    cat >"$1"
  elif have sudo; then
    sudo tee "$1" >/dev/null
  else die "writing $1 needs root — re-run as root, or install sudo"; fi
}

# Is the filtering proxy running? 0 = active, 1 = not active, 2 = unknown
# (systemctl absent). Reading service state needs no root.
egress_proxy_active() {
  have systemctl || return 2
  systemctl is-active --quiet "$ISOPOD_EGRESS_PROXY_UNIT" 2>/dev/null && return 0
  return 1
}

# Translate the layered allow-list (baseline + user override) into anchored
# POSIX-extended regexes for tinyproxy's host filter, one per line, on stdout:
#   foo.com    -> ^(.*\.)?foo\.com$   (apex + any subdomain)
#   *.foo.com  -> ^.+\.foo\.com$      (subdomains only, not the apex)
# Both ends are anchored so a pattern can never match a look-alike host as a
# substring (e.g. "foo.com" must not allow "foo.com.evil.net").
egress_filter_regexes() {
  local f line dom _ esc
  for f in "$ISOPOD_EGRESS_ALLOWLIST" "$USER_EGRESS_ALLOWLIST"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"               # strip comments
      read -r dom _ <<<"$line" || true # first token, whitespace-trimmed
      [ -n "${dom:-}" ] || continue
      case "$dom" in
        \*.*)
          esc="${dom#\*.}"
          esc="${esc//./\\.}"
          printf '^.+\\.%s$\n' "$esc"
          ;;
        *)
          esc="${dom//./\\.}"
          printf '^(.*\\.)?%s$\n' "$esc"
          ;;
      esac
    done <"$f"
  done
}

# Write the rendered filter file (deduped) to the host state dir.
egress_write_filter() {
  egress_filter_regexes | sort -u | egr_write_root "$ISOPOD_EGRESS_STATE_DIR/filter"
}

# Load the active nftables ruleset (LAN-deny or allow-list) into the host netns.
egress_load_nft() {
  local rs rendered
  egress_validate_vars
  rs="$(egress_ruleset)"
  [ -f "$rs" ] || die "missing ruleset: $rs"
  rendered="$(render_tmpl "$rs")"
  # macOS: load the ruleset inside the podman machine VM (where nftables and the
  # box bridge live), not on the Mac host.
  if egress_enforce_in_vm; then
    egress_vm_ready || die "on macOS the egress firewall loads inside the podman machine VM, but that
     VM is not reachable. Start it with:  podman machine start
     (Docker Desktop's VM is not supported for host-enforced egress — use podman machine.)"
    info "Loading isopod egress firewall inside the podman machine VM (nftables)..."
    printf '%s\n' "$rendered" | egress_vm_root nft -f - ||
      die "nft failed to load the ruleset inside the podman machine VM"
    info "egress firewall loaded inside the VM (table inet isopod)."
    warn "not persistent across 'podman machine stop' / reboot — re-run 'isopod egress apply' after those."
    return 0
  fi
  have nft || die "nft (nftables) not found — install nftables to apply the egress firewall"
  info "Loading isopod egress firewall into the host network namespace..."
  printf '%s\n' "$rendered" | egr_run_root nft -f - || die "nft failed to load the ruleset"
  info "egress firewall loaded (table inet isopod)."
  warn "not persistent across reboot / firewalld reload — re-run 'sudo isopod egress apply' after
       those. For reboot persistence, run: sudo isopod egress persist"
}

# --- boot persistence (isopod egress persist) -------------------------------
# SCAFFOLD — installs a systemd unit that re-applies the nft ruleset on boot,
# after firewalld/nftables set up, so a box's isolation survives a reboot. It does
# NOT survive a live 'firewalld --reload' / 'nft flush' (no reliable systemd hook
# for those). This path touches root-owned systemd state and has NOT been exercised
# on a live host from CI — validate with RUN_LIVE / on a real systemd + nft host.
egress_persist() {
  local mode rs rendered nftbin
  mode="$(active_egress)"
  case "$mode" in
    lan-deny | allow-list) ;;
    *) die "egress is off — configure 'egress lan-deny'/'allow-list' (or ISOPOD_EGRESS=...) before persisting" ;;
  esac
  # macOS: the firewall lives inside the podman machine VM, so boot persistence is
  # an in-VM systemd unit rather than a host one (egress_persist_macos persists
  # lan-deny, the only mode enforced on macOS).
  if egress_enforce_in_vm; then
    egress_persist_macos
    return 0
  fi
  have systemctl || die "egress persist needs systemd (systemctl) to install a boot unit"
  nftbin="$(command -v nft)" || die "nft (nftables) not found — install nftables"
  egress_validate_vars
  rs="$(egress_ruleset)"
  [ -f "$rs" ] || die "missing ruleset: $rs"
  rendered="$(render_tmpl "$rs")"
  # Write the fully-rendered ruleset to a fixed root-owned file the unit loads.
  egr_run_root mkdir -p "$ISOPOD_EGRESS_STATE_DIR"
  printf '%s\n' "$rendered" | egr_write_root "$ISOPOD_EGRESS_STATE_DIR/egress.nft"
  # ISOPOD_NFT_BIN is read by the unit template via dynamic scope at render time.
  # shellcheck disable=SC2034
  local ISOPOD_NFT_BIN="$nftbin"
  render_tmpl isopod-egress-nft.service.tmpl |
    egr_write_root "/etc/systemd/system/$ISOPOD_EGRESS_NFT_UNIT.service"
  egr_run_root systemctl daemon-reload
  egr_run_root systemctl enable "$ISOPOD_EGRESS_NFT_UNIT" ||
    die "failed to enable $ISOPOD_EGRESS_NFT_UNIT — check: systemctl status $ISOPOD_EGRESS_NFT_UNIT"
  info "egress firewall will re-apply on boot (systemd unit '$ISOPOD_EGRESS_NFT_UNIT')."
  warn "this does NOT survive a live 'firewalld --reload' / 'nft flush' — re-run 'sudo isopod egress
       apply' after those. The unit loads a snapshot: run 'persist' again if you change the egress
       mode or allow-list."
}

egress_unpersist() {
  if egress_enforce_in_vm; then
    egress_unpersist_macos
    return 0
  fi
  have systemctl || die "needs systemd (systemctl)"
  egr_run_root systemctl disable --now "$ISOPOD_EGRESS_NFT_UNIT" 2>/dev/null || true
  egr_run_root rm -f "/etc/systemd/system/$ISOPOD_EGRESS_NFT_UNIT.service"
  egr_run_root systemctl daemon-reload
  info "removed the egress boot unit ('$ISOPOD_EGRESS_NFT_UNIT'). A currently-loaded ruleset stays until flushed."
}

# Render the proxy config + filter + systemd unit and (re)start the service.
# <deny> is tinyproxy's FilterDefaultDeny: Yes to enforce the allow-list, No for
# observe mode (permit all, still log everything).
egress_apply_proxy() { # egress_apply_proxy <Yes|No>
  # FILTER_DEFAULT_DENY and the proxy user/group below are consumed by the
  # rendered templates via dynamic scope, which shellcheck can't see.
  # shellcheck disable=SC2034
  local FILTER_DEFAULT_DENY="$1"
  have "$ISOPOD_EGRESS_PROXY_BIN" ||
    die "'$ISOPOD_EGRESS_PROXY_BIN' not found — install tinyproxy (apt/dnf/brew install tinyproxy)"
  have systemctl ||
    die "egress allow-list needs systemd (systemctl) to run the proxy as a persistent unit"
  # Prefer the packaged 'tinyproxy' account to drop privileges; fall back to
  # nobody/nogroup. PROXY_GROUP is read only by the rendered tinyproxy template
  # (dynamic scope at render time), which shellcheck can't see, so its assignment
  # block carries an SC2034 disable; PROXY_USER is also used in chown() below.
  local ISOPOD_EGRESS_PROXY_USER ISOPOD_EGRESS_PROXY_GROUP
  if id tinyproxy >/dev/null 2>&1; then ISOPOD_EGRESS_PROXY_USER=tinyproxy; else ISOPOD_EGRESS_PROXY_USER=nobody; fi
  # shellcheck disable=SC2034
  if getent group tinyproxy >/dev/null 2>&1; then
    ISOPOD_EGRESS_PROXY_GROUP=tinyproxy
  elif getent group nogroup >/dev/null 2>&1; then
    ISOPOD_EGRESS_PROXY_GROUP=nogroup
  else ISOPOD_EGRESS_PROXY_GROUP=nobody; fi
  egr_run_root mkdir -p "$ISOPOD_EGRESS_STATE_DIR" "$ISOPOD_EGRESS_PROXY_LOG_DIR"
  render_tmpl tinyproxy.conf.tmpl | egr_write_root "$ISOPOD_EGRESS_STATE_DIR/tinyproxy.conf"
  egress_write_filter
  render_tmpl isopod-egress-proxy.service.tmpl |
    egr_write_root "/etc/systemd/system/$ISOPOD_EGRESS_PROXY_UNIT.service"
  egr_run_root touch "$ISOPOD_EGRESS_PROXY_LOG"
  egr_run_root chown "$ISOPOD_EGRESS_PROXY_USER" "$ISOPOD_EGRESS_PROXY_LOG" 2>/dev/null || true
  info "Starting the egress filtering proxy ($ISOPOD_EGRESS_PROXY_UNIT)..."
  egr_run_root systemctl daemon-reload
  egr_run_root systemctl enable --now "$ISOPOD_EGRESS_PROXY_UNIT" ||
    die "failed to start $ISOPOD_EGRESS_PROXY_UNIT — check: systemctl status $ISOPOD_EGRESS_PROXY_UNIT"
}

# Shared `isopod doctor` reporting for both egress modes: which engines can
# enforce it (rootful host bridge) and whether the host firewall is loaded.
egress_doctor_engines_and_fw() {
  local eng seen=0
  for eng in podman docker; do
    have "$eng" && "$eng" info >/dev/null 2>&1 || continue
    seen=1
    if egress_can_enforce "$eng"; then
      printf '  [ok]      %s can enforce egress (rootful — host bridge)\n' "$eng"
    else
      printf '  [warn]    %s is ROOTLESS — cannot enforce egress; such boxes fail preflight\n' "$eng"
    fi
  done
  [ "$seen" = 1 ] || printf '  [warn]    no working engine to check egress enforcement against\n'
  local erc=0
  egress_rules_loaded || erc=$?
  case "$erc" in
    0) printf '  [ok]      egress firewall loaded (table inet isopod)\n' ;;
    1) printf '  [warn]    egress firewall NOT loaded — run: sudo isopod egress apply\n' ;;
    2) printf '  [--]      egress firewall status unknown (need root; try: sudo isopod egress status)\n' ;;
  esac
}

# Resolve the EFFECTIVE egress mode for a create/reconfigure, degrading the
# default-on egress instead of blocking the box. Egress is on by default now
# (active_egress -> allow-list), but the strict modes need a rootful engine, a
# running proxy, and a loaded host firewall. When egress was chosen EXPLICITLY
# this is a no-op — egress_preflight keeps failing closed, since the user asked
# for it. When egress is only on by DEFAULT, walk it down with a loud warning:
#   allow-list -> lan-deny (proxy not up) -> off (rootless / firewall not loaded)
# Sets ISOPOD_EGRESS in-process so the rest of the run (preflight, build_run_args)
# sees the achievable mode. Silence any degrade with ISOPOD_EGRESS=off.
resolve_egress() { # resolve_egress <engine>
  local engine="$1" mode
  # Set when default-on egress is walked all the way down to an OPEN network, so
  # create/reconfigure can make that unmissable in their summary (egress_posture_note).
  ISOPOD_EGRESS_DEGRADED=0
  mode="$(active_egress)"
  [ -n "$mode" ] || return 0        # already off
  egress_explicitly_set && return 0 # opt-in: leave fail-closed preflight in charge
  # Rootless engine cannot enforce either mode (no host bridge) -> open network.
  if ! egress_can_enforce "$engine"; then
    warn "egress is on by default but '$engine' is rootless and cannot enforce it — continuing
     with an OPEN network. Use a rootful podman/docker for isolation, or set ISOPOD_EGRESS=off
     to silence this."
    export ISOPOD_EGRESS=off
    ISOPOD_EGRESS_DEGRADED=1
    return 0
  fi
  # macOS: the allow-list filtering proxy is Linux-only, so the achievable strict
  # mode is lan-deny (enforced inside the podman machine VM). Downgrade the
  # default allow-list to lan-deny here so the posture reported later is honest
  # (rather than claiming allow-list ACTIVE while nothing filters by hostname).
  if egress_enforce_in_vm && [ "$mode" = allow-list ]; then
    warn "egress is on by default as allow-list, but its host filtering proxy is Linux-only; on macOS
     isopod enforces lan-deny (LAN/host/metadata blocked) inside the podman machine VM instead. Make
     it explicit with ISOPOD_EGRESS=lan-deny, or disable with ISOPOD_EGRESS=off."
    export ISOPOD_EGRESS=lan-deny
    mode=lan-deny
  fi
  # allow-list needs the filtering proxy; if it is definitively stopped, drop to
  # lan-deny (LAN block without the proxy) rather than leaving the box no route out.
  if [ "$mode" = allow-list ]; then
    local prc=0
    egress_proxy_active || prc=$?
    if [ "$prc" = 1 ]; then
      warn "egress allow-list is on by default but its filtering proxy ($ISOPOD_EGRESS_PROXY_UNIT)
       is not running — falling back to lan-deny. Enable the full allow-list with:
       sudo isopod egress apply"
      export ISOPOD_EGRESS=lan-deny
      mode=lan-deny
    fi
  fi
  # Host firewall definitively not loaded -> the LAN block would not be in effect;
  # continue open rather than fail the create (the explicit path still dies).
  local rc=0
  egress_rules_loaded || rc=$?
  if [ "$rc" = 1 ]; then
    warn "egress is on by default but the host firewall is not loaded, so the block would not be
     in effect — continuing with an OPEN network. Load it with 'sudo isopod egress apply', or set
     ISOPOD_EGRESS=off to silence this."
    export ISOPOD_EGRESS=off
    ISOPOD_EGRESS_DEGRADED=1
  fi
  return 0
}

# Print the box's EFFECTIVE network posture after resolve_egress, so a default-on
# egress that silently degraded to an OPEN network is unmissable at create/
# reconfigure time. Reads the resolved mode and the degrade flag resolve_egress set.
egress_posture_note() { # egress_posture_note <name>
  local name="$1"
  case "$(active_egress)" in
    allow-list) info "Network: egress allow-list ACTIVE — only allow-listed hosts reachable (host-filtered)." ;;
    lan-deny) info "Network: egress lan-deny ACTIVE — LAN/host/metadata blocked, public internet reachable." ;;
    *)
      if [ "${ISOPOD_EGRESS_DEGRADED:-0}" = 1 ]; then
        warn "Network: OPEN — egress isolation is ON by default but could NOT be enforced here, so
     '$name' can reach your LAN and the internet unfiltered. Enable it (needs root, one time):
       sudo isopod egress apply
     then recreate the box (or: isopod reconfigure $name). Silence with ISOPOD_EGRESS=off."
      else
        info "Network: OPEN (egress disabled by config)."
      fi
      ;;
  esac
}

# Re-verify egress enforcement when STARTING an existing box. A box created with
# egress is already attached to the isopod bridge, so its isolation is the HOST
# firewall — which a reboot / 'firewalld --reload' / 'nft flush' can silently drop.
# start rebuilds nothing, so without this the box would run OPEN with no signal.
# We WARN (loud) rather than fail closed: the box already exists and the fix is one
# root command. The box's effective mode is recorded in meta at create/reconfigure.
egress_start_check() { # egress_start_check <name>
  local name="$1" mode
  mode="$(meta_get "$name" egress 2>/dev/null || true)"
  case "$mode" in lan-deny | allow-list) ;; *) return 0 ;; esac
  if ! egress_can_enforce "$ENGINE"; then
    warn "box '$name' was created with egress $mode, but '$ENGINE' is rootless now and cannot enforce
     it — this box is running with an OPEN network. Use a rootful podman/docker for isolation."
    return 0
  fi
  local rc=0
  egress_rules_loaded || rc=$?
  if [ "$rc" = 1 ]; then
    warn "box '$name' expects egress $mode, but the host firewall is NOT loaded — it is running with
     an OPEN network (a reboot or 'firewalld --reload' drops the rules). Reload it (needs root):
       sudo isopod egress apply"
  fi
  if [ "$mode" = allow-list ]; then
    local prc=0
    egress_proxy_active || prc=$?
    [ "$prc" = 1 ] && warn "box '$name' expects the egress allow-list proxy ($ISOPOD_EGRESS_PROXY_UNIT),
     which is NOT running — the box may have no route out. Start it:  sudo isopod egress apply"
  fi
}

# Preflight for a box that will run under `egress lan-deny`: the engine must be
# able to enforce it, the dedicated network must exist, and the host firewall
# should already be loaded. Called before build_run_args in create/reconfigure.
# Fails CLOSED — refuses to create a box that asked for `egress lan-deny` but
# would not actually get it, rather than starting a silently unprotected box.
# Two ways it can be unenforceable, both fatal by default:
#   - rootless engine (no host bridge to filter), and
#   - the host firewall is definitively NOT loaded (nft present, table absent).
# The "cannot confirm" case (need root to read nftables) stays a warning, since
# refusing there would break the normal setup where root loaded the rules and an
# unprivileged `isopod create` can't read them. Set ISOPOD_EGRESS_ALLOW_UNLOADED=1
# to downgrade the not-loaded case to a warning (start on the bridge anyway).
egress_preflight() { # egress_preflight <engine>
  local mode
  mode="$(active_egress)"
  case "$mode" in lan-deny | allow-list) ;; *) return 0 ;; esac
  local engine="$1"
  egress_validate_vars
  # macOS: an EXPLICIT allow-list can't be honored (its host proxy is Linux-only).
  # Fail closed with a clear steer rather than silently starting an unfiltered box.
  if egress_enforce_in_vm && [ "$mode" = allow-list ]; then
    die "egress allow-list is configured, but its host filtering proxy is a Linux systemd service not
     yet supported on macOS. Use 'egress lan-deny' (enforced inside the podman machine VM) on macOS,
     or set ISOPOD_EGRESS=lan-deny."
  fi
  if ! egress_can_enforce "$engine"; then
    die "egress $mode needs a rootful engine (host-bridge networking); '$engine' here is rootless.
     A rootless engine routes boxes through a userspace stack with no host bridge, so the
     firewall cannot be enforced. Use a rootful podman/docker, or remove the 'egress' directive."
  fi
  ensure_egress_network "$engine"
  # allow-list: the proxy is the box's ONLY route out, so a definitively-stopped
  # proxy means the box would be created unable to reach anything. Fail closed.
  if [ "$mode" = allow-list ]; then
    local prc=0
    egress_proxy_active || prc=$?
    [ "$prc" = 1 ] && die "egress allow-list is configured but the filtering proxy
     ($ISOPOD_EGRESS_PROXY_UNIT) is NOT running, so the box would have no route out.
     Start it (needs root):  sudo isopod egress apply"
  fi
  local rc=0
  egress_rules_loaded || rc=$?
  case "$rc" in
    1)
      if [ "${ISOPOD_EGRESS_ALLOW_UNLOADED:-0}" = 1 ]; then
        warn "egress firewall NOT loaded — starting on '$ISOPOD_EGRESS_NET' WITHOUT the LAN block
       (ISOPOD_EGRESS_ALLOW_UNLOADED=1). Load it with:  sudo isopod egress apply"
      else
        die "egress lan-deny is configured but the host firewall is NOT loaded, so the box would
     start on '$ISOPOD_EGRESS_NET' without the LAN/host/metadata block actually in effect.
     Load it once (needs root):  sudo isopod egress apply
     Then retry. To start anyway (bridge only, no LAN block): ISOPOD_EGRESS_ALLOW_UNLOADED=1"
      fi
      ;;
    2) warn "cannot confirm the egress firewall is loaded (need root to read nftables). If you have
       not run it, load it with:  sudo isopod egress apply   — verify:  sudo isopod egress status" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# egress — manage the host-side firewall (and, for allow-list, the filtering
# proxy) for `egress lan-deny` / `egress allow-list` boxes
# ---------------------------------------------------------------------------
cmd_egress() {
  local action="${1:-status}"
  shift 2>/dev/null || true
  case "$action" in
    status | "") egress_status ;;
    apply) egress_apply enforce ;;
    observe) egress_apply observe ;;
    persist) egress_persist ;;
    unpersist) egress_unpersist ;;
    allow)
      [ -n "${1:-}" ] || die "usage: isopod egress allow <domain>"
      egress_allow "$1"
      ;;
    log) egress_log "$@" ;;
    denied) egress_denied ;;
    rules | show) render_tmpl "$(egress_ruleset)" ;;
    -h | --help | help) render_tmpl egress-help.txt ;;
    *) die "unknown egress action: $action (try: isopod egress status|apply|observe|persist|unpersist|allow|log|denied|rules)" ;;
  esac
}

egress_status() {
  # Build the mode-specific block and the firewall line as locals, then lay them
  # out via share/egress-status.txt (static text lives in share/, not inline).
  local mode mode_block="" fw_line
  mode="$(active_egress)"
  case "$mode" in
    allow-list)
      local prc=0 svc n
      egress_proxy_active || prc=$?
      case "$prc" in
        0) svc="active ($ISOPOD_EGRESS_PROXY_UNIT)" ;;
        1) svc="NOT running — run: sudo isopod egress apply" ;;
        *) svc="unknown (systemctl not found)" ;;
      esac
      n="$(egress_filter_regexes | sort -u | grep -c . || true)"
      mode_block+="  proxy:     $ISOPOD_EGRESS_GATEWAY:$ISOPOD_EGRESS_PROXY_PORT (host-side, hostname allow-list)"$'\n'
      mode_block+="  proxy svc: $svc"$'\n'
      mode_block+="  allowlist: $n domains ($ISOPOD_EGRESS_ALLOWLIST + $USER_EGRESS_ALLOWLIST)"$'\n'
      mode_block+="  log:       $ISOPOD_EGRESS_PROXY_LOG"$'\n'
      ;;
    lan-deny)
      mode_block="  dns:       $ISOPOD_EGRESS_DNS (public resolver — box cannot query the host/LAN resolver)"$'\n'
      ;;
  esac
  local rc=0
  egress_rules_loaded || rc=$?
  case "$rc" in
    0) fw_line="  firewall:  loaded (table inet isopod)" ;;
    1) fw_line="  firewall:  NOT loaded — run: sudo isopod egress apply" ;;
    *) fw_line="  firewall:  unknown (need root to read nftables; try: sudo isopod egress status)" ;;
  esac
  # Consumed by egress-status.txt via render_tmpl's dynamic scope (invisible to the linter).
  : "$mode" "$mode_block" "$fw_line"
  render_tmpl egress-status.txt
}

# Load the firewall (and, for allow-list, the proxy). <want> is enforce|observe.
egress_apply() { # egress_apply <enforce|observe>
  local want="$1" mode
  mode="$(active_egress)"
  # macOS: the allow-list filtering proxy is a Linux systemd service and is not
  # ported yet, so there is no proxy to observe or enforce. Fall back to lan-deny
  # (loaded inside the podman machine VM) rather than failing on missing systemctl.
  if egress_enforce_in_vm && [ "$mode" = allow-list ]; then
    [ "$want" = observe ] &&
      die "egress observe needs the filtering proxy, which is Linux-only — not available on macOS yet."
    warn "egress allow-list uses a host filtering proxy (a Linux systemd service) not yet ported to
     macOS. Applying lan-deny instead (LAN/host/cloud-metadata/internal-DNS blocked; public internet
     reachable), loaded inside the podman machine VM."
    ISOPOD_EGRESS=lan-deny egress_load_nft
    return 0
  fi
  case "$mode" in
    lan-deny)
      [ "$want" = enforce ] || die "egress observe is only for allow-list mode (current mode: lan-deny)"
      egress_load_nft
      ;;
    allow-list)
      if [ "$want" = observe ]; then egress_apply_proxy No; else egress_apply_proxy Yes; fi
      egress_load_nft
      [ "$want" = observe ] && warn "egress OBSERVE mode: the proxy PERMITS all destinations and logs
       them. Review with 'isopod egress denied' / 'isopod egress log', add domains with
       'isopod egress allow <domain>', then run 'sudo isopod egress apply' to enforce."
      ;;
    *) die "egress is off — set 'egress lan-deny' or 'egress allow-list' in your hardening.conf
     (or ISOPOD_EGRESS=...) first, then apply." ;;
  esac
}

# Add a domain to the user allow-list override and reload the running proxy.
egress_allow() { # egress_allow <domain>
  local dom="$1"
  # Only hostname characters, so an entry can never inject a regex metacharacter
  # into the generated filter file (a security boundary — the filter is trusted).
  case "$dom" in
    "" | *[!a-zA-Z0-9.*-]*) die "invalid domain: '$dom' (letters, digits, '.', '-', leading '*.' only)" ;;
  esac
  mkdir -p "$CONFIG_DIR"
  if [ -f "$USER_EGRESS_ALLOWLIST" ] && grep -qxF "$dom" "$USER_EGRESS_ALLOWLIST" 2>/dev/null; then
    info "'$dom' is already in your allow-list ($USER_EGRESS_ALLOWLIST)"
  else
    printf '%s\n' "$dom" >>"$USER_EGRESS_ALLOWLIST"
    info "added '$dom' to $USER_EGRESS_ALLOWLIST"
  fi
  # Reload the running proxy so the change takes effect without dropping
  # connections; if it was never applied, tell the user to apply.
  if [ -f "$ISOPOD_EGRESS_STATE_DIR/tinyproxy.conf" ]; then
    egress_write_filter
    egr_run_root systemctl reload "$ISOPOD_EGRESS_PROXY_UNIT" &&
      info "proxy reloaded — '$dom' is now allowed"
  else
    warn "proxy not applied yet — run 'sudo isopod egress apply' to enforce the updated list"
  fi
}

egress_log() { # egress_log [-f]
  [ -f "$ISOPOD_EGRESS_PROXY_LOG" ] ||
    die "no proxy log at $ISOPOD_EGRESS_PROXY_LOG (has 'sudo isopod egress apply' run?)"
  if [ "${1:-}" = "-f" ]; then
    egr_run_root tail -f "$ISOPOD_EGRESS_PROXY_LOG"
  else egr_run_root tail -n 200 "$ISOPOD_EGRESS_PROXY_LOG"; fi
}

# Best-effort: pull the host names of refused (filtered) connections out of the
# proxy log, so they can be reviewed and passed to `isopod egress allow`.
egress_denied() {
  [ -f "$ISOPOD_EGRESS_PROXY_LOG" ] ||
    die "no proxy log at $ISOPOD_EGRESS_PROXY_LOG (has 'sudo isopod egress apply' run?)"
  info "hostnames the proxy refused (not on the allow-list):"
  egr_run_root grep -iE 'filter|refused|denied' "$ISOPOD_EGRESS_PROXY_LOG" 2>/dev/null |
    grep -oE '[A-Za-z0-9._-]+\.[A-Za-z]{2,}' | sort -u |
    sed 's/^/  /' || printf '  (none logged)\n'
}
