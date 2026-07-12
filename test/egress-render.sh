#!/usr/bin/env bash
# Egress guard: prove the `egress allow-list` / `lan-deny` templates render and
# (where nft is available) parse. These files are host-security-critical and are
# assembled from templates via render_tmpl, whose dynamic-scope variables can
# drift from the script silently. This catches that with no engine, no root, and
# no network — so it runs identically on your machine, under act, on GitHub, and
# on GitLab. Where the `nft` binary is present AND usable it also parses the
# rendered rulesets; where it is not (unprivileged CI, no nft) it skips cleanly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
c_grn=$'\033[32m'
c_red=$'\033[31m'
c_yel=$'\033[33m'
c_rst=$'\033[0m'
ok() { printf '%s  ok%s %s\n' "$c_grn" "$c_rst" "$1"; }
skip() { printf '%sskip%s %s\n' "$c_yel" "$c_rst" "$1"; }
fail() {
  printf '%sFAIL%s %s\n' "$c_red" "$c_rst" "$1" >&2
  exit 1
}

# A rendered file must not still contain an unexpanded isopod variable, which
# would mean a template referenced a name absent where render_tmpl ran.
assert_no_unexpanded() { # assert_no_unexpanded <label> <text>
  case "$2" in
    *'$ISOPOD_'* | *'$FILTER_DEFAULT_DENY'*) fail "$1: unexpanded variable in rendered output" ;;
  esac
}

# --- nftables rulesets ------------------------------------------------------
lan_deny="$(ISOPOD_EGRESS=lan-deny ./isopod egress rules)"
allow_list="$(ISOPOD_EGRESS=allow-list ./isopod egress rules)"

assert_no_unexpanded "egress-host.nft" "$lan_deny"
case "$lan_deny" in *"table inet isopod"*) ok "lan-deny ruleset renders" ;; *) fail "lan-deny ruleset missing table" ;; esac

assert_no_unexpanded "egress-allowlist.nft" "$allow_list"
case "$allow_list" in *"table inet isopod"*) : ;; *) fail "allow-list ruleset missing table" ;; esac
# The allow-list ruleset must drop box-initiated egress and open ONLY the proxy.
case "$allow_list" in *"tcp dport 8118"*) : ;; *) fail "allow-list ruleset does not open the proxy port" ;; esac
case "$allow_list" in *"ip saddr 10.88.7.0/24 drop"*) : ;; *) fail "allow-list ruleset does not default-deny box egress" ;; esac
ok "allow-list ruleset renders, default-denies, opens only the proxy port"

# Both rulesets must drop box-initiated IPv6 (scoped to the isopod bridge) and
# spare host IPv6 on other interfaces — the host-enforced backstop to the v4 rules.
for pair in "lan-deny:$lan_deny" "allow-list:$allow_list"; do
  label="${pair%%:*}"
  rs="${pair#*:}"
  case "$rs" in *'meta nfproto ipv6 iifname "isopod-egr" drop'*) : ;; *) fail "$label ruleset does not drop box IPv6 egress on the isopod bridge" ;; esac
  case "$rs" in *'meta nfproto ipv6 iifname != "isopod-egr" accept'*) : ;; *) fail "$label ruleset does not spare non-box host IPv6" ;; esac
done
ok "both rulesets drop box IPv6 egress (scoped to the isopod bridge), spare host IPv6"

# --- tinyproxy config + systemd unit ----------------------------------------
# Render exactly as egress_apply_proxy does: source isopod for render_tmpl and
# set the variables the templates read via dynamic scope.
proxy_conf="$(
  ISOPOD_SOURCED=1 . ./isopod
  FILTER_DEFAULT_DENY=Yes ISOPOD_EGRESS_PROXY_USER=tinyproxy ISOPOD_EGRESS_PROXY_GROUP=tinyproxy \
    render_tmpl tinyproxy.conf.tmpl
)"
assert_no_unexpanded "tinyproxy.conf" "$proxy_conf"
for directive in "Listen 10.88.7.1" "Port 8118" "FilterDefaultDeny Yes" "Allow 10.88.7.0/24"; do
  case "$proxy_conf" in *"$directive"*) : ;; *) fail "tinyproxy.conf missing: $directive" ;; esac
done
ok "tinyproxy.conf renders with the expected directives"

unit="$(ISOPOD_SOURCED=1 . ./isopod && render_tmpl isopod-egress-proxy.service.tmpl)"
assert_no_unexpanded "systemd unit" "$unit"
# systemd expands %MAINPID itself, so $MAINPID must survive the render literally.
case "$unit" in *'kill -HUP $MAINPID'*) : ;; *) fail "systemd unit: \$MAINPID was not preserved literally" ;; esac
case "$unit" in *"ExecStart=tinyproxy -d -c"*) : ;; *) fail "systemd unit: ExecStart is wrong" ;; esac
ok "systemd unit renders (ExecStart + literal \$MAINPID)"

# nft boot-persistence unit (isopod egress persist). The nft binary path is
# resolved at persist time and passed via ISOPOD_NFT_BIN.
nft_unit="$(ISOPOD_SOURCED=1 . ./isopod && ISOPOD_NFT_BIN=/usr/sbin/nft render_tmpl isopod-egress-nft.service.tmpl)"
assert_no_unexpanded "egress nft unit" "$nft_unit"
case "$nft_unit" in *"ExecStart=/usr/sbin/nft -f "*) : ;; *) fail "nft unit: ExecStart is wrong" ;; esac
case "$nft_unit" in *"After=nftables.service firewalld.service"*) : ;; *) fail "nft unit: boot ordering is wrong" ;; esac
ok "egress nft persistence unit renders (ExecStart + boot ordering)"

# macOS pf boot-persistence LaunchDaemon (isopod egress persist on the pf backend).
# The Label is the anchor and the loaded conf is pf.conf; both come from ISOPOD_PF_* globals.
pf_plist="$(ISOPOD_SOURCED=1 . ./isopod && render_tmpl isopod-egress-pf.plist.tmpl)"
assert_no_unexpanded "pf LaunchDaemon" "$pf_plist"
case "$pf_plist" in *"<string>com.isopod.egress</string>"*) : ;; *) fail "pf plist: Label is not the isopod anchor" ;; esac
case "$pf_plist" in *"<string>/sbin/pfctl</string>"*"<string>-E</string>"*"<string>-f</string>"*"<string>/etc/pf.conf</string>"*) : ;; *) fail "pf plist: does not run 'pfctl -E -f /etc/pf.conf' at boot" ;; esac
case "$pf_plist" in *"<key>RunAtLoad</key>"*"<true/>"*) : ;; *) fail "pf plist: not set to RunAtLoad" ;; esac
ok "pf persistence LaunchDaemon renders (RunAtLoad + pfctl -E -f pf.conf)"
# plutil validates the plist is well-formed where it exists (macOS); skip on Linux CI.
if command -v plutil >/dev/null 2>&1; then
  if printf '%s\n' "$pf_plist" | plutil -lint - >/dev/null 2>&1; then
    ok "pf LaunchDaemon passes plutil -lint"
  else
    fail "pf LaunchDaemon: plutil -lint rejected the rendered plist"
  fi
else
  skip "plutil not installed — pf plist lint skipped (render checks above still ran)"
fi

# --- allow-list -> filter regexes -------------------------------------------
regexes="$(ISOPOD_SOURCED=1 . ./isopod && egress_filter_regexes | sort -u)"
[ -n "$regexes" ] || fail "allow-list produced no filter regexes"
# Anchoring must reject a look-alike host, or the allow-list leaks.
printf '%s\n' "$regexes" | grep -qE '^\^\(\.\*' || fail "filter regexes are not anchored as expected"
if printf 'evilgithub.com\n' | grep -qE "$(printf '%s\n' "$regexes" | tr '\n' '|' | sed 's/|$//')"; then
  fail "filter regexes match a look-alike host (evilgithub.com) — anchoring is broken"
fi
ok "allow-list generates anchored filter regexes (rejects look-alike hosts)"

# --- optional: real nft parse where the binary is usable --------------------
# nft check-mode still talks to the kernel: it needs privilege AND a working
# nf_tables/netlink subsystem. Classify both "no privilege" (unprivileged CI)
# and "no nf_tables kernel" (containers / emulated runners, where nft is
# installed but netlink won't initialize) as skip, and only fail on a genuine
# parse error. Strip the add/delete idempotency preamble so we validate the rule
# syntax itself, independent of current kernel state.
nft_check() { # nft_check <label> <rendered ruleset>
  local label="$1" body err
  body="$(printf '%s\n' "$2" | grep -vE '^(add|delete) table ')"
  if err="$(printf '%s\n' "$body" | nft -c -f - 2>&1)"; then
    ok "$label parses under nft -c"
    return 0
  fi
  case "$err" in
    *"permission denied"* | *"Operation not permitted"* | *"not permitted"* | *"Could not"* | *"Unable to initialize Netlink"* | *"Protocol not supported"*)
      skip "$label: nft -c can't reach nf_tables here (no privilege or no kernel support) — parse check skipped"
      ;;
    *) fail "$label: nft rejected the ruleset:
$err" ;;
  esac
}
if command -v nft >/dev/null 2>&1; then
  nft_check "lan-deny" "$lan_deny"
  nft_check "allow-list" "$allow_list"
else
  skip "nft not installed — ruleset parse check skipped (render checks above still ran)"
fi

printf '%segress render checks passed%s\n' "$c_grn" "$c_rst"
