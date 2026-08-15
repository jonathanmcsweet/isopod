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
    # Apple `container` puts each box on a routable vmnet subnet, so egress is
    # enforced by pf on the macOS HOST (outside the box VM) — not by a host bridge.
    # "Can enforce" here means that host pf is available.
    container) egress_host_pf_supported ;;
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
  if egress_enforce_host_pf; then
    # macOS host-pf backend: the rules live in the Mac's pf anchor.
    egress_pf_loaded
    return
  fi
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

# --- macOS: two egress backends ---------------------------------------------
# On macOS the `isopod` script runs on the Mac, but boxes run inside a guest VM,
# so there is no single obvious place for the firewall. isopod has two backends:
#
#   pf  — HOST-level. When boxes run on a ROUTABLE vmnet subnet (Apple `container`,
#         or a vmnet vfkit/krunkit/krunvm setup), pf on the Mac filters the box
#         subnet in a dedicated anchor, OUTSIDE every guest VM. A box that escapes
#         its container AND its VM still cannot flush it without root on macOS —
#         the escape-resistant boundary. This is the preferred backend.
#   vm  — IN-VM fallback. Under podman machine's default gvproxy networking a box's
#         traffic is host-originated with no routable subnet for pf to scope, so
#         the only place to enforce is INSIDE the podman machine VM (nft, over
#         `podman machine ssh`). That is outside the box container but only a
#         CONTAINER ESCAPE away — weaker than pf. Used when pf can't be scoped.
#
# The allow-list's filtering proxy is a Linux systemd service on either backend,
# so on macOS both enforce lan-deny only (see egress_apply).
#
# NOTE: the Linux host path is covered by CI; both macOS paths (podman-machine ssh,
# and pfctl) have NOT been exercised from CI (no macOS runner) — validate on a real
# Mac. See docs/macos-host-egress.md and test/macos-egress-check.sh.

# Which macOS backend is in force: 'pf' (host-level) or 'vm' (in-VM fallback).
# Override with ISOPOD_EGRESS_BACKEND=pf|vm. Default: pf when the box actually runs
# on a routable vmnet subnet — i.e. the engine is Apple `container` (ENGINE or the
# requested ISOPOD_ENGINE) or ISOPOD_PF_SUBNET pins one — and pfctl exists;
# otherwise the in-VM fallback. Merely having `container` installed does NOT force
# pf: a podman-machine box is behind gvproxy, where pf cannot see it.
egress_macos_backend() {
  case "${ISOPOD_EGRESS_BACKEND:-}" in pf | vm)
    printf '%s' "$ISOPOD_EGRESS_BACKEND"
    return 0
    ;;
  esac
  if egress_host_pf_supported &&
    { [ -n "${ISOPOD_PF_SUBNET:-}" ] || [ "${ENGINE:-${ISOPOD_ENGINE:-}}" = container ]; }; then
    printf 'pf'
  else
    printf 'vm'
  fi
}
egress_enforce_in_vm() { is_macos && [ "$(egress_macos_backend)" = vm ]; }
egress_enforce_host_pf() { is_macos && [ "$(egress_macos_backend)" = pf ]; }

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

# --- macOS host-level backend: pf on the Mac (Apple container / vmnet) -------
# True when host pf egress is usable here: macOS with pfctl.
egress_host_pf_supported() { is_macos && have pfctl; }

# The box vmnet subnet pf scopes to. Order: explicit ISOPOD_PF_SUBNET, else the
# Apple `container` default network's subnet (best-effort parse), else the
# documented default (192.168.64.0/24). Echoes a CIDR.
macos_box_subnet() {
  [ -n "${ISOPOD_PF_SUBNET:-}" ] && {
    printf '%s' "$ISOPOD_PF_SUBNET"
    return 0
  }
  if have container; then
    local s
    s="$(container network inspect default 2>/dev/null |
      grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -n1)"
    valid_cidr "$s" 2>/dev/null && {
      printf '%s' "$s"
      return 0
    }
  fi
  printf '%s' "$ISOPOD_PF_SUBNET_DEFAULT"
}

# Is the isopod pf anchor loaded? 0 = loaded, 1 = not loaded, 2 = unknown (pfctl
# absent, or reading needs root we don't have — a false "not loaded" would mislead).
egress_pf_loaded() {
  have pfctl || return 2
  local out
  out="$(pfctl -a "$ISOPOD_PF_ANCHOR" -s rules 2>&1)" || {
    case "$out" in
      *[Pp]"ermission"* | *"Operation not permitted"* | *root*) return 2 ;;
      *) return 1 ;;
    esac
  }
  [ -n "$out" ] && return 0 || return 1
}

# Idempotently reference the isopod anchor from pf.conf so its rules are actually
# evaluated (and reloaded on boot). Adds an `anchor` + `load anchor` pair once,
# marked with a comment so unpersist can strip it cleanly.
egress_pf_ensure_anchor_ref() {
  egr_run_root grep -q "\"$ISOPOD_PF_ANCHOR\"" "$ISOPOD_PF_CONF" 2>/dev/null && return 0
  printf '\n# isopod egress — added by `isopod egress apply` (remove with: isopod egress unpersist)\nanchor "%s"\nload anchor "%s" from "%s"\n' \
    "$ISOPOD_PF_ANCHOR" "$ISOPOD_PF_ANCHOR" "$ISOPOD_PF_ANCHOR_FILE" |
    egr_run_root tee -a "$ISOPOD_PF_CONF" >/dev/null ||
    die "could not add the isopod anchor to $ISOPOD_PF_CONF"
}

egress_pf_remove_anchor_ref() {
  # macOS sed needs an explicit (empty) -i backup suffix.
  egr_run_root sed -i '' \
    -e '/isopod egress — added by/d' \
    -e "\\|\"$ISOPOD_PF_ANCHOR\"|d" \
    "$ISOPOD_PF_CONF" 2>/dev/null || true
}

# Load the host pf egress rules into the isopod anchor and enable pf. Escape-proof:
# a box can't flush this without root on macOS. Writes root-owned /etc/pf.anchors
# and edits pf.conf (so it survives reboot), then reloads pf.
egress_load_pf() {
  local ISOPOD_PF_SUBNET rendered
  ISOPOD_PF_SUBNET="$(macos_box_subnet)"
  valid_cidr "$ISOPOD_PF_SUBNET" ||
    die "box vmnet subnet '$ISOPOD_PF_SUBNET' is not valid IPv4 CIDR — set ISOPOD_PF_SUBNET (check: container network inspect default)"
  [ -f "$ISOPOD_EGRESS_PF_RULESET" ] || die "missing pf ruleset: $ISOPOD_EGRESS_PF_RULESET"
  have pfctl || die "pfctl not found — host-level egress needs macOS pf"
  rendered="$(render_tmpl "$ISOPOD_EGRESS_PF_RULESET")"
  info "Loading isopod egress firewall on the macOS HOST (pf anchor '$ISOPOD_PF_ANCHOR', box subnet $ISOPOD_PF_SUBNET)..."
  printf '%s\n' "$rendered" | egr_write_root "$ISOPOD_PF_ANCHOR_FILE"
  egress_pf_ensure_anchor_ref
  egr_run_root pfctl -f "$ISOPOD_PF_CONF" >/dev/null 2>&1 ||
    die "pfctl failed to load $ISOPOD_PF_CONF — check syntax with: sudo pfctl -n -f $ISOPOD_PF_CONF"
  egr_run_root pfctl -E >/dev/null 2>&1 || true # enable pf (idempotent; -E refcounts)
  info "egress firewall loaded on the host (pf anchor '$ISOPOD_PF_ANCHOR'); referenced from $ISOPOD_PF_CONF so its rules re-parse on boot."
  info "pf is not re-enabled at boot on its own — run 'sudo isopod egress persist' to keep it in effect across reboots."
}

# macOS pf boot persistence: install a LaunchDaemon that re-enables pf and re-loads
# pf.conf at boot. macOS re-reads pf.conf on boot but does NOT re-enable pf (the
# 'pfctl -E' refcount does not survive a reboot), so without this the host egress
# block silently lapses after a reboot. Parity with the Linux boot unit and the
# in-VM systemd unit used by the other backends.
egress_persist_pf() {
  have launchctl || die "egress persist on the macOS pf backend needs launchctl (macOS launchd)"
  local plist rendered
  plist="$ISOPOD_PF_LAUNCHD_PLIST"
  rendered="$(render_tmpl isopod-egress-pf.plist.tmpl)"
  info "Installing the pf egress boot LaunchDaemon ($plist)..."
  printf '%s\n' "$rendered" | egr_write_root "$plist"
  egr_run_root launchctl unload "$plist" >/dev/null 2>&1 || true
  egr_run_root launchctl load -w "$plist" ||
    die "failed to load the LaunchDaemon — check: sudo launchctl load -w $plist"
  info "pf egress will re-enable on boot (LaunchDaemon '$ISOPOD_PF_ANCHOR')."
}

egress_unpersist_pf() {
  local plist="$ISOPOD_PF_LAUNCHD_PLIST"
  if have launchctl; then
    egr_run_root launchctl unload -w "$plist" >/dev/null 2>&1 || true
  fi
  egr_run_root rm -f "$plist"
  info "removed the pf egress boot LaunchDaemon ('$ISOPOD_PF_ANCHOR')."
}

egress_unload_pf() {
  have pfctl || die "pfctl not found"
  egr_run_root pfctl -a "$ISOPOD_PF_ANCHOR" -F rules >/dev/null 2>&1 || true
  egress_pf_remove_anchor_ref
  egr_run_root rm -f "$ISOPOD_PF_ANCHOR_FILE"
  egr_run_root pfctl -f "$ISOPOD_PF_CONF" >/dev/null 2>&1 || true
  info "removed isopod host pf egress (anchor '$ISOPOD_PF_ANCHOR' flushed and de-referenced from $ISOPOD_PF_CONF)."
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

# Read the domains of a single allow-list file to stdout, one per line: the
# first whitespace token of each line, comments (`#…`) stripped, blanks skipped.
# Missing file -> no output. Shared by the --json emitter and any text view.
egress_allowlist_domains() { # egress_allowlist_domains <file>
  local line dom _
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    read -r dom _ <<<"$line" || true
    [ -n "${dom:-}" ] && printf '%s\n' "$dom"
  done <"$1"
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
  # macOS host-pf backend renders and loads its own pf ruleset on the Mac.
  if egress_enforce_host_pf; then
    egress_load_pf
    return 0
  fi
  local rs rendered
  egress_validate_vars
  rs="$(egress_ruleset)"
  [ -f "$rs" ] || die "missing ruleset: $rs"
  rendered="$(render_tmpl "$rs")"
  # macOS in-VM fallback: load the ruleset inside the podman machine VM (where
  # nftables and the box bridge live), not on the Mac host.
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
  # macOS host-pf backend: `egress apply` writes the anchor into pf.conf (its rules
  # re-parse on boot), but macOS does not re-enable pf at boot, so persistence also
  # installs a LaunchDaemon that runs `pfctl -E -f pf.conf` at boot.
  if egress_enforce_host_pf; then
    egress_load_pf
    egress_persist_pf
    return 0
  fi
  # macOS in-VM fallback: boot persistence is an in-VM systemd unit, not a host one
  # (egress_persist_macos persists lan-deny, the only mode enforced on macOS).
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
  if egress_enforce_host_pf; then
    egress_unpersist_pf
    egress_unload_pf
    return 0
  fi
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
    die "'$ISOPOD_EGRESS_PROXY_BIN' not found — install tinyproxy (apt/dnf/pacman/emerge/brew)"
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
  # macOS: report which backend enforces egress and where it lives.
  if is_macos; then
    local backend erc=0
    backend="$(egress_macos_backend)"
    if [ "$backend" = pf ]; then
      printf '  [ok]      macOS egress backend: pf on the HOST (anchor %s, box subnet %s) — outside the guest VM\n' \
        "$ISOPOD_PF_ANCHOR" "$(macos_box_subnet)"
    else
      printf '  [--]      macOS egress backend: in-VM nft (podman machine) — weaker; a container escape reaches it.\n'
      printf '            For host-level enforcement install Apple `container` (per-box vmnet subnet). See docs/macos-host-egress.md\n'
    fi
    egress_rules_loaded || erc=$?
    case "$erc" in
      0) printf '  [ok]      egress firewall loaded (%s)\n' "$([ "$backend" = pf ] && printf 'pf anchor %s' "$ISOPOD_PF_ANCHOR" || printf 'table inet isopod, in VM')" ;;
      1) printf '  [warn]    egress firewall NOT loaded — run: isopod egress apply\n' ;;
      2) printf '  [--]      egress firewall status unknown (need root, or VM/pf unreachable; try: isopod egress status)\n' ;;
    esac
    return 0
  fi
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
  # macOS: the allow-list filtering proxy is Linux-only (both backends), so the
  # achievable strict mode is lan-deny. Downgrade the default allow-list to lan-deny
  # here so the posture reported later is honest (rather than claiming allow-list
  # ACTIVE while nothing filters by hostname).
  if is_macos && [ "$mode" = allow-list ]; then
    warn "egress is on by default as allow-list, but its host filtering proxy is Linux-only; on macOS
     isopod enforces lan-deny (LAN/host/metadata blocked) via the $(egress_macos_backend) backend
     instead. Make it explicit with ISOPOD_EGRESS=lan-deny, or disable with ISOPOD_EGRESS=off."
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
        # The in-guest ruleset is a separate mechanism, and it applies precisely
        # when host enforcement does not — so this branch is exactly where it is
        # most likely to be running. Announcing an unfiltered LAN while nft is
        # dropping that traffic is not a harmless overstatement: it sends the user
        # hunting a hole that is not there, and it hides the layer that IS
        # filtering when something in the box stops reaching the network.
        if [ "$(meta_get "$name" guest_egress 2>/dev/null || true)" = on ] && is_microvm_runtime; then
          warn "Network: no host-enforced boundary here ('$name' runs under a rootless engine), but
     in-box isolation IS active (--guest-egress): the box cannot reach your LAN, and its own
     resolvers stay reachable on port 53 so DNS keeps working. This runs INSIDE the box, so
     guest root could remove it. For a boundary that survives that, use a rootful engine:
       sudo isopod egress apply"
        else
          warn "Network: OPEN — egress isolation is ON by default but could NOT be enforced here, so
     '$name' can reach your LAN and the internet unfiltered. Enable it (needs root, one time):
       sudo isopod egress apply
     then recreate the box (or: isopod reconfigure $name). Silence with ISOPOD_EGRESS=off."
        fi
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

  # macOS host-pf backend (Apple `container` / vmnet): the box already sits on a
  # routable vmnet subnet and egress is enforced by pf on the Mac, OUTSIDE the box
  # VM. There is no rootful host bridge to validate or create — just require the pf
  # anchor to be loaded, with the same fail-closed / degrade behavior as below.
  if egress_enforce_host_pf; then
    if [ "$mode" = allow-list ]; then
      die "egress allow-list is configured, but its host filtering proxy is a Linux systemd service not
     yet supported on macOS. Use 'egress lan-deny' (host pf) on macOS, or set ISOPOD_EGRESS=lan-deny."
    fi
    local prc=0
    egress_rules_loaded || prc=$?
    case "$prc" in
      1)
        if [ "${ISOPOD_EGRESS_ALLOW_UNLOADED:-0}" = 1 ]; then
          warn "egress pf firewall NOT loaded — starting the box WITHOUT the LAN block
       (ISOPOD_EGRESS_ALLOW_UNLOADED=1). Load it with:  sudo isopod egress apply"
        else
          die "egress lan-deny is configured but the host pf firewall is NOT loaded, so the box would
     start with no LAN/host/metadata block actually in effect. Load it once (needs root):
       sudo isopod egress apply
     Then retry. To start anyway (no LAN block): ISOPOD_EGRESS_ALLOW_UNLOADED=1"
        fi
        ;;
      2) warn "cannot confirm the egress pf firewall is loaded (need root to read pf state). If you have
       not loaded it, run:  sudo isopod egress apply   — verify:  sudo isopod egress status" ;;
    esac
    return 0
  fi

  egress_validate_vars
  # macOS: an EXPLICIT allow-list can't be honored (its host proxy is Linux-only).
  # Fail closed with a clear steer rather than silently starting an unfiltered box.
  if is_macos && [ "$mode" = allow-list ]; then
    die "egress allow-list is configured, but its host filtering proxy is a Linux systemd service not
     yet supported on macOS. Use 'egress lan-deny' (host pf, or in-VM nft) on macOS, or set
     ISOPOD_EGRESS=lan-deny."
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
# --- guest ruleset: private-space exemptions (isopod egress lan-allow) --------
# These are per BOX, not per host: the rules live in the box's own nftables
# ruleset (share/egress-guest.nft), so they only mean anything on a microVM box
# with guest egress on. The host-side `egress allow` above is a different thing —
# it adds a DOMAIN to the filtering proxy's allow-list.

# Validate one spec. Accepted: ADDR, ADDR/PREFIX, ADDR:PORT, ADDR/PREFIX:PORT for
# IPv4; the same for IPv6, with brackets when a port is present ([ADDR]:PORT), so
# the port separator can't be confused with the address's own colons. Mirrors the
# entrypoint's validation: the host decides what gets stored, the box re-checks
# before anything becomes a rule.
lan_allow_valid() { # lan_allow_valid <spec>
  local spec="${1:-}" addr="" port="" fam=4 base pfx x
  local -a o=()
  # A comma would split the stored list and whitespace would break the rule
  # shape, so neither can appear in a spec.
  case "$spec" in
    "" | *[[:space:],]*) return 1 ;;
  esac
  case "$spec" in
    "["*)
      case "$spec" in *"]:"*) ;; *) return 1 ;; esac
      port="${spec##*]:}"
      addr="${spec#"["}"
      addr="${addr%%]:*}"
      fam=6
      ;;
    # Two or more colons is IPv6; a bare IPv6 cannot carry a port.
    *:*:*) addr="$spec" fam=6 ;;
    *:*)
      port="${spec##*:}"
      addr="${spec%:*}"
      ;;
    *) addr="$spec" ;;
  esac
  [ -n "$addr" ] || return 1
  [ -z "$port" ] || valid_port "$port" || return 1
  case "$addr" in
    */*)
      base="${addr%%/*}"
      pfx="${addr##*/}"
      ;;
    *)
      base="$addr"
      pfx=""
      ;;
  esac
  [ -n "$base" ] || return 1
  if [ "$fam" = 4 ]; then
    IFS=. read -ra o <<<"$base"
    [ "${#o[@]}" -eq 4 ] || return 1
    for x in "${o[@]}"; do
      case "$x" in "" | *[!0-9]*) return 1 ;; esac
      [ "${#x}" -le 3 ] && [ "$x" -le 255 ] || return 1
    done
    [ -z "$pfx" ] && return 0
    case "$pfx" in *[!0-9]*) return 1 ;; esac
    [ "${#pfx}" -le 3 ] && [ "$pfx" -le 32 ] || return 1
  else
    # Strict literal check — a loose "hex and colons" test lets a malformed
    # address (too many groups, a 5-digit group) through, and nft then rejects
    # the whole ruleset, failing the box closed with no sshd.
    valid_ip6 "$base" || return 1
    [ -z "$pfx" ] && return 0
    case "$pfx" in *[!0-9]*) return 1 ;; esac
    [ "${#pfx}" -le 3 ] && [ "$pfx" -le 128 ] || return 1
  fi
  return 0
}

# Turn the stored comma-separated list into nft rule lines, tagged so the in-box
# helper can find and replace exactly these. Assumes each spec already passed
# lan_allow_valid; the box checks the rendered shape again regardless.
lan_allow_rules() { # lan_allow_rules <csv>
  local csv="${1:-}" spec addr port fam kw
  local -a specs=()
  [ -n "$csv" ] || return 0
  IFS=, read -ra specs <<<"$csv"
  for spec in "${specs[@]}"; do
    [ -n "$spec" ] || continue
    port="" fam=4
    case "$spec" in
      "["*)
        port="${spec##*]:}"
        addr="${spec#"["}"
        addr="${addr%%]:*}"
        fam=6
        ;;
      *:*:*) addr="$spec" fam=6 ;;
      *:*)
        port="${spec##*:}"
        addr="${spec%:*}"
        ;;
      *) addr="$spec" ;;
    esac
    kw=ip
    [ "$fam" = 6 ] && kw=ip6
    if [ -z "$port" ]; then
      printf '%s daddr %s accept comment "isopod-lan-allow"\n' "$kw" "$addr"
    else
      printf '%s daddr %s tcp dport %s accept comment "isopod-lan-allow"\n' "$kw" "$addr" "$port"
      printf '%s daddr %s udp dport %s accept comment "isopod-lan-allow"\n' "$kw" "$addr" "$port"
    fi
  done
}

# Warn when the stored list cannot currently take effect. It is still stored, so
# turning guest egress on later picks it up — better than refusing the command
# and losing what the user asked for.
lan_allow_applies() { # lan_allow_applies <name>
  [ "$(meta_get "$1" guest_egress 2>/dev/null || true)" = on ]
}

lan_allow_apply_live() { # lan_allow_apply_live <name> <csv>
  local name="$1" csv="$2" helper="$ISOPOD_LIB/guest_egress_allow.sh"
  [ -f "$helper" ] || die "missing helper: $helper (reinstall isopod)"
  [ "$(box_status "$name" 2>/dev/null || true)" = running ] || return 1
  local rules
  rules="$(lan_allow_rules "$csv")"
  root_ssh "$name" -- "sh -s -- sync $(shq "$rules")" <"$helper" >/dev/null 2>&1 || return 1
  return 0
}

egress_lan_allow() { # egress_lan_allow <name> [--rm] [spec]
  local name="" action=list spec=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rm | --remove)
        action="rm"
        shift
        ;;
      -h | --help)
        render_tmpl egress-help.txt
        return 0
        ;;
      -*) die "unknown option for egress lan-allow: $1" ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        elif [ -z "$spec" ]; then
          spec="$1"
        else
          die "unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done
  [ -n "$name" ] ||
    die "usage: isopod egress lan-allow <box> [--rm] [<addr>[/<prefix>][:<port>]]"
  open_box "$name"
  [ "$action" = rm ] && [ -z "$spec" ] &&
    die "usage: isopod egress lan-allow <box> --rm <addr>"
  [ "$action" = list ] && [ -n "$spec" ] && action=add

  local cur new=""
  cur="$(meta_get "$name" guest_egress_allow 2>/dev/null || true)"

  if [ "$action" = list ]; then
    if [ -z "$cur" ]; then
      printf 'no lan-allow entries for %s\n' "$name"
      printf '  add one with: isopod egress lan-allow %s <addr>[/<prefix>][:<port>]\n' "$name"
    else
      printf '%s\n' "${cur//,/$'\n'}"
    fi
    lan_allow_applies "$name" ||
      warn "guest egress is off for this box, so these entries are stored but not enforced"
    return 0
  fi

  local e found=0
  local -a keep=()
  IFS=, read -ra keep <<<"$cur"
  if [ "$action" = add ]; then
    lan_allow_valid "$spec" || die "invalid address '$spec'
     Use an address or range, with an optional single port:
       10.20.30.40        10.20.0.0/16        10.20.30.40:5432
       fd00::1            fd00::/8            [fd00::1]:5432"
    for e in "${keep[@]}"; do
      [ "$e" = "$spec" ] && found=1
    done
    if [ "$found" = 1 ]; then
      info "$spec is already allowed for $name"
      return 0
    fi
    new="$cur${cur:+,}$spec"
  else
    for e in "${keep[@]}"; do
      [ -z "$e" ] && continue
      if [ "$e" = "$spec" ]; then
        found=1
        continue
      fi
      new="$new${new:+,}$e"
    done
    [ "$found" = 1 ] || die "$spec is not in the lan-allow list for $name"
  fi

  meta_set "$name" guest_egress_allow "$new"
  if ! lan_allow_applies "$name"; then
    info "stored. Guest egress is off for this box, so nothing is being filtered."
    return 0
  fi
  # A box built before this feature has an entrypoint that never reads the list.
  # The live apply below still works — same table, same chain — so the address
  # starts working immediately and then disappears at the next restart, with
  # nothing saying why. Say why now instead.
  local stale=0
  box_is_stale "$name" 2>/dev/null && stale=1
  if lan_allow_apply_live "$name" "$new"; then
    info "$([ "$action" = add ] && printf 'allowed' || printf 'removed') $spec for $name (applied now)"
    if [ "$stale" = 1 ]; then
      warn "this box predates lan-allow, so the change applies NOW but is lost on the
     next restart. Make it stick: isopod upgrade $name"
    fi
  else
    info "$([ "$action" = add ] && printf 'allowed' || printf 'removed') $spec for $name"
    if [ "$stale" = 1 ]; then
      warn "this box predates lan-allow — its ruleset cannot use the list.
     Run: isopod upgrade $name"
    elif [ "$(box_status "$name" 2>/dev/null || true)" != running ]; then
      # lan_allow_apply_live returns non-zero for a stopped box too, so tell a
      # stopped box to start rather than to restart something already down.
      warn "stored; it takes effect when the box starts: isopod start $name"
    else
      warn "could not update the running box — restart it to apply: isopod stop $name && isopod start $name"
    fi
  fi
}

egress_lan_denied() { # egress_lan_denied <name> [count]
  local name="${1:-}" n="${2:-20}" helper="$ISOPOD_LIB/guest_egress_allow.sh"
  [ -n "$name" ] || die "usage: isopod egress lan-denied <box> [count]"
  open_box "$name"
  [ -f "$helper" ] || die "missing helper: $helper (reinstall isopod)"
  lan_allow_applies "$name" ||
    die "guest egress is off for $name — nothing is being blocked, so nothing is logged"
  [ "$(box_status "$name" 2>/dev/null || true)" = running ] ||
    die "$name is not running (start it with: isopod start $name)"

  local out
  out="$(root_ssh "$name" -- "sh -s -- denied $n" <"$helper" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    printf 'nothing blocked recently for %s\n' "$name"
    if box_is_stale "$name" 2>/dev/null; then
      printf '  This box predates drop logging, so it has nothing to report.\n'
      printf '  Run: isopod upgrade %s\n' "$name"
    else
      printf '  Either the box has not tried to reach private space, or this kernel\n'
      printf '  cannot log dropped packets (filtering still works either way).\n'
    fi
    return 0
  fi
  printf 'Blocked destinations for %s (most recent last):\n\n' "$name"
  printf '  %-24s %-6s %s\n' DESTINATION PROTO COUNT
  local dest proto count
  while IFS=$'\t' read -r dest proto count; do
    [ -n "$dest" ] || continue
    printf '  %-24s %-6s %s\n' "$dest" "${proto:-?}" "$count"
  done <<<"$out"
  printf '\nAllow one with: isopod egress lan-allow %s <destination>\n' "$name"
}

cmd_egress() {
  local action="${1:-status}"
  shift 2>/dev/null || true
  case "$action" in
    status | "") egress_status "$@" ;;
    apply) egress_apply enforce ;;
    observe) egress_apply observe ;;
    persist) egress_persist ;;
    unpersist) egress_unpersist ;;
    allow)
      [ -n "${1:-}" ] || die "usage: isopod egress allow <domain>"
      egress_allow "$1"
      ;;
    lan-allow) egress_lan_allow "$@" ;;
    lan-denied) egress_lan_denied "$@" ;;
    log) egress_log "$@" ;;
    denied)
      if [ "${1:-}" = "--json" ]; then egress_denied_json; else egress_denied; fi
      ;;
    allowlist)
      if [ "${1:-}" = "--json" ]; then egress_allowlist_json; else egress_allowlist_show; fi
      ;;
    rules | show)
      # On the macOS host-pf backend, show the pf ruleset (with the box subnet
      # substituted); otherwise the active nft ruleset.
      if egress_enforce_host_pf; then
        local ISOPOD_PF_SUBNET
        ISOPOD_PF_SUBNET="$(macos_box_subnet)"
        render_tmpl "$ISOPOD_EGRESS_PF_RULESET"
      else
        render_tmpl "$(egress_ruleset)"
      fi
      ;;
    -h | --help | help) render_tmpl egress-help.txt ;;
    *) die "unknown egress action: $action (try: isopod egress status|apply|observe|persist|unpersist|allow|allowlist|log|denied|rules|lan-allow|lan-denied)" ;;
  esac
}

egress_status() { # egress_status [--json]
  if [ "${1:-}" = "--json" ]; then
    egress_status_json
    return
  fi
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
  # ported to either backend, so there is no proxy to observe or enforce. Fall back
  # to lan-deny (host pf, or in-VM nft) rather than failing on missing systemctl.
  if is_macos && [ "$mode" = allow-list ]; then
    [ "$want" = observe ] &&
      die "egress observe needs the filtering proxy, which is Linux-only — not available on macOS yet."
    warn "egress allow-list uses a host filtering proxy (a Linux systemd service) not yet ported to
     macOS. Applying lan-deny instead (LAN/host/cloud-metadata/internal-DNS blocked; public internet
     reachable), via the $(egress_macos_backend) backend ($([ "$(egress_macos_backend)" = pf ] && printf 'host pf' || printf 'in-VM nft'))."
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

# Show the layered allow-list: shipped baseline first, then the user additions.
egress_allowlist_show() {
  local dom
  info "baseline allow-list ($ISOPOD_EGRESS_ALLOWLIST):"
  egress_allowlist_domains "$ISOPOD_EGRESS_ALLOWLIST" | sed 's/^/  /' || true
  info "your additions ($USER_EGRESS_ALLOWLIST):"
  if [ -s "$USER_EGRESS_ALLOWLIST" ]; then
    egress_allowlist_domains "$USER_EGRESS_ALLOWLIST" | sed 's/^/  /'
  else
    printf '  (none — add with: isopod egress allow <domain>)\n'
  fi
}

# One-line description of a box's ACTUAL network posture, for `isopod info`.
# Deliberately reports what is in force, not what was requested: a box whose
# egress degraded at create (rootless engine, host firewall not loaded) was
# previously indistinguishable from an isolated one once the create output
# scrolled away — which is how a box ends up open while its owner believes
# otherwise. Names the in-guest layer too, so "blocked" is never ambiguous about
# which mechanism is doing it.
box_egress_posture() { # box_egress_posture <name>
  local mode degraded guest guest_on=0
  mode="$(meta_get "$1" egress 2>/dev/null || true)"
  degraded="$(meta_get "$1" egress_degraded 2>/dev/null || printf 0)"
  guest="$(meta_get "$1" guest_egress 2>/dev/null || true)"
  # The guest ruleset is loaded by the entrypoint ONLY on a Tier 3 microVM box —
  # build_run_args gates it on is_microvm_runtime. A plain container and a gVisor
  # (Tier 2) box both keep guest_egress=on in meta (create records it regardless
  # of runtime) but never get the ruleset, so the meta flag alone would claim
  # isolation the box does not have. Gate on the box's RECORDED runtime tier —
  # authoritative for what this box actually got, and independent of whatever
  # runtime happens to be active when `isopod info` runs.
  [ "$guest" = on ] &&
    [ "$(runtime_tier "$(meta_get "$1" runtime 2>/dev/null || true)" 2>/dev/null)" = 3 ] &&
    guest_on=1
  # The in-guest layer is reported alongside the host verdict, never instead of it.
  # Reporting only the host side hid an active in-box ruleset behind the 'OPEN'
  # message, so a box whose DNS and outbound traffic were being filtered read as
  # having no isolation at all — which is exactly backwards when something in the
  # box stops working and the ruleset is the first thing worth suspecting.
  local guest_note=''
  [ "$guest_on" = 1 ] &&
    guest_note=' + guest lan-deny (in-box nft; defence in depth, not a hard boundary)'
  # Exemptions belong next to the verdict that would otherwise imply the box can
  # reach nothing in private space. Named here so `isopod info` shows what was
  # opened without the user having to remember or go looking.
  local allow allow_note=''
  allow="$(meta_get "$1" guest_egress_allow 2>/dev/null || true)"
  [ "$guest_on" = 1 ] && [ -n "$allow" ] && allow_note=", except $allow"
  guest_note="$guest_note$allow_note"
  if [ "$degraded" = 1 ]; then
    printf 'OPEN — host enforcement was requested but could not be applied (see: isopod doctor)%s' "$guest_note"
  elif [ -n "$mode" ]; then
    printf '%s (host-enforced)%s' "$mode" "$guest_note"
  elif [ "$guest_on" = 1 ]; then
    printf 'guest lan-deny (in-box nft; defence in depth, not a hard boundary)%s' "$allow_note"
  else
    printf 'OPEN — no egress isolation'
  fi
}
