#!/usr/bin/env bash
# test/macos-egress-check.sh — validate isopod's macOS host-pf egress path on a
# real Mac WITHOUT touching your firewall. It renders the pf ruleset, parse-checks
# it with `pfctl -n` (no load, no enable), and reports what `isopod egress apply`
# would do. Safe to run repeatedly.
#
#   ./test/macos-egress-check.sh              # read-only checks + pf syntax parse
#   ISOPOD_PF_SUBNET=192.168.64.0/24 ./test/macos-egress-check.sh   # force a subnet
#
# It does NOT modify /etc/pf.conf, load rules, or enable pf. To actually apply
# (after this passes): ISOPOD_ENGINE=container isopod egress apply
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISOPOD="$ROOT/isopod"
c_grn=$'\033[32m'
c_red=$'\033[31m'
c_yel=$'\033[33m'
c_rst=$'\033[0m'
ok() { printf '%s[ok]%s   %s\n' "$c_grn" "$c_rst" "$1"; }
no() { printf '%s[!!]%s   %s\n' "$c_red" "$c_rst" "$1"; }
note() { printf '%s[--]%s   %s\n' "$c_yel" "$c_rst" "$1"; }

if [ "$(uname -s)" != Darwin ]; then
  no "not macOS — this check is for a Mac host"
  exit 1
fi
ok "macOS host ($(sw_vers -productVersion 2>/dev/null || echo '?'), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?'))"

if command -v pfctl >/dev/null 2>&1; then
  ok "pfctl present"
else
  no "pfctl missing (unexpected on macOS)"
  exit 1
fi

if command -v container >/dev/null 2>&1; then
  ok "Apple container present ($(container --version 2>/dev/null | head -n1 || echo '?'))"
  if container system status >/dev/null 2>&1; then
    ok "container service running"
  else
    note "container service not running — start: container system start"
  fi
else
  note "Apple container NOT installed — install for the host-pf path: brew install container"
fi

# Resolve the box subnet the way isopod will: env override, else Apple container's
# default network, else the documented default.
SUBNET="${ISOPOD_PF_SUBNET:-}"
if [ -z "$SUBNET" ] && command -v container >/dev/null 2>&1; then
  SUBNET="$(container network inspect default 2>/dev/null |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -n1 || true)"
fi
SUBNET="${SUBNET:-192.168.64.0/24}"
printf '\n'
ok "box vmnet subnet pf will scope to: $SUBNET"

# Render the pf ruleset isopod would load.
if ! PF_RULES="$(ISOPOD_PF_SUBNET="$SUBNET" ISOPOD_EGRESS_BACKEND=pf "$ISOPOD" egress rules 2>/dev/null)"; then
  no "could not render pf ruleset (isopod egress rules)"
  exit 1
fi
printf '\n--- rendered pf anchor (security/egress-host.pf) ---\n%s\n---\n\n' "$PF_RULES"

# Parse-check with pfctl WITHOUT loading: build a temp pf.conf that loads the
# anchor inline, and run `pfctl -n -f` (syntax only). Needs sudo to read pf state.
tmp_anchor="$(mktemp -t isopod-egress.XXXXXX)"
tmp_conf="$(mktemp -t isopod-pfconf.XXXXXX)"
trap 'rm -f "$tmp_anchor" "$tmp_conf"' EXIT
printf '%s\n' "$PF_RULES" >"$tmp_anchor"
printf 'anchor "com.isopod.egress"\nload anchor "com.isopod.egress" from "%s"\n' "$tmp_anchor" >"$tmp_conf"
if sudo pfctl -n -f "$tmp_conf" 2>/tmp/isopod-pf-parse.err; then
  ok "pf ruleset parses cleanly (pfctl -n -f) — safe to apply"
else
  no "pf ruleset FAILED to parse:"
  sed 's/^/      /' /tmp/isopod-pf-parse.err
  exit 1
fi

printf '\n--- isopod doctor (egress + virtualization) ---\n'
"$ISOPOD" doctor 2>/dev/null | grep -Ei 'egress|pf |hypervisor|container|vmnet|microvm|kvm|tier' || true

cat <<'EOF'

Next steps (these DO change your firewall — run when ready):
  ISOPOD_ENGINE=container isopod egress apply      # load the pf anchor + enable pf
  isopod egress status                             # confirm loaded
  # from inside a box, verify: a LAN host is blocked, the public internet works
  isopod egress unpersist                          # remove it (flush anchor, clean pf.conf)
EOF
