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
# Pin the in-VM (nft) backend: on a macOS host where Apple `container` is installed
# `egress rules` renders the pf ruleset instead, so force `vm` to exercise the nft
# templates here. On Linux this override is a no-op (the host-pf backend is macOS-only).
lan_deny="$(ISOPOD_EGRESS_BACKEND=vm ISOPOD_EGRESS=lan-deny ./isopod egress rules)"
allow_list="$(ISOPOD_EGRESS_BACKEND=vm ISOPOD_EGRESS=allow-list ./isopod egress rules)"

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

# --- macOS host-pf ruleset (Apple `container` / vmnet backend) ---------------
# Rendered directly (the `egress rules` path is OS-gated to macOS). Assert the box
# vmnet subnet substitutes and the LAN block uses the vmnet-correct INBOUND
# direction ('block ... in ... from <subnet>'); 'block out' does not filter
# vmnet-bridged traffic. Runs identically on Linux and macOS.
pf_rules="$(ISOPOD_SOURCED=1 . ./isopod && ISOPOD_PF_SUBNET=192.168.64.0/24 render_tmpl "$ISOPOD_EGRESS_PF_RULESET")"
assert_no_unexpanded "egress-host.pf" "$pf_rules"
case "$pf_rules" in *"192.168.64.0/24"*) : ;; *) fail "pf ruleset: box subnet not substituted" ;; esac
case "$pf_rules" in *"block drop in quick"*) : ;; *) fail "pf ruleset: LAN block is not inbound-direction (vmnet needs 'block in', not 'block out')" ;; esac
ok "macOS host-pf ruleset renders (box subnet substituted, inbound-direction LAN block)"

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
# --- guest ruleset (loaded INSIDE a microVM box by the entrypoint) ----------
# Rendered the same way share/isopod-entrypoint renders it: the gateway from
# /proc/net/route, and one accept pair per resolver in /etc/resolv.conf. Checked
# here because nothing else ever parsed it — a version of this file once placed
# the generated rules above `table ... {`, which nft rejects, and the only symptom
# was every microVM box failing closed with no sshd.
guest_tmpl="$ROOT/share/egress-guest.nft"
guest_ep="$ROOT/share/isopod-entrypoint"
[ -f "$guest_tmpl" ] || fail "missing guest ruleset template: $guest_tmpl"
[ -f "$guest_ep" ] || fail "missing entrypoint: $guest_ep"

# All three awk programs are extracted from the entrypoint and run for real,
# rather than reimplemented here — a copy would have kept passing while the
# shipped program was broken, which is how the misplaced-rules bug reached a box.
ns_prog="$(sed -n "/iso_ns_rules=\$(awk '/,/}' \/etc\/resolv.conf/p" "$guest_ep" |
  sed "1s/.*awk '//; \$s/}'.*/}/")"
[ -n "$ns_prog" ] || fail "could not extract the resolver-rule program from the entrypoint"
allow_prog="$(sed -n "/iso_allow_rules=\$(awk -v specs=/,/}' <\/dev\/null)/p" "$guest_ep" |
  sed "1s/.*awk -v specs=\"\${ISOPOD_GUEST_EGRESS_ALLOW:-}\" '//; \$s/' <\/dev\/null)//")"
[ -n "$allow_prog" ] || fail "could not extract the lan-allow program from the entrypoint"
render_prog="$(sed -n "/-v logging=\"\$1\" -v log4=/,/' \/etc\/isopod\/egress-guest.nft/p" "$guest_ep" |
  sed "1s/.*-v log6=\"\$iso_log6\" '//; \$s/' \/etc\/isopod.*//")"
[ -n "$render_prog" ] || fail "could not extract the ruleset render program from the entrypoint"
# The log rules are shipped as shell strings; use those, not copies.
log4="$(sed -n "s/^  iso_log4='\(.*\)'\$/\1/p" "$guest_ep")"
log6="$(sed -n "s/^  iso_log6='\(.*\)'\$/\1/p" "$guest_ep")"
[ -n "$log4" ] && [ -n "$log6" ] || fail "could not extract the drop-log rules from the entrypoint"

# A resolv.conf shaped like the one a box inherits behind a VPN: two resolvers in
# ranges the ruleset blocks, one on the gateway, and a malformed line that must
# never become a rule.
guest_rules="$(printf '%s\n' \
  'search lan' \
  'nameserver 169.254.1.1' \
  'nameserver 100.64.0.12' \
  'nameserver 192.168.1.1' \
  'nameserver bogus;accept' | awk "$ns_prog")"
[ -n "$guest_rules" ] || fail "the entrypoint's resolver program produced no rules"
printf '%s\n' "$guest_rules" | grep -q 'bogus' &&
  fail "a malformed nameserver reached the ruleset"
ok "guest resolver rules generated from resolv.conf (malformed entries dropped)"

# lan-allow specs, run through the shipped program. The malformed entries are the
# point: this text becomes firewall rules, so anything that is not a bare literal
# must be dropped rather than substituted.
allow_rules="$(awk -v specs='10.20.30.40,10.20.0.0/16,10.20.30.40:5432,fd00::1,[fd00::1]:5432' \
  "$allow_prog" </dev/null)"
[ -n "$allow_rules" ] || fail "the entrypoint's lan-allow program produced no rules"
for want in 'ip daddr 10.20.30.40 accept' 'ip daddr 10.20.0.0/16 accept' \
  'ip daddr 10.20.30.40 tcp dport 5432 accept' 'ip6 daddr fd00::1 accept' \
  'ip6 daddr fd00::1 udp dport 5432 accept'; do
  printf '%s\n' "$allow_rules" | grep -q "$want" ||
    fail "lan-allow program did not emit: $want"
done
printf '%s\n' "$allow_rules" | grep -qc 'isopod-lan-allow' >/dev/null ||
  fail "lan-allow rules are not tagged (egress lan-allow could not manage them)"
ok "lan-allow rules generated from specs (addresses, ranges, ports, IPv6)"

for bad in '10.20.30.999' '10.20.30.40/33' '1.1.1.1; nft flush ruleset' 'accept' \
  '10.0.0.1:0' '10.0.0.1:99999' 'zzz' '10.0.0.1 accept'; do
  out="$(awk -v specs="$bad" "$allow_prog" </dev/null)"
  [ -z "$out" ] || fail "lan-allow program accepted a malformed spec '$bad': $out"
done
ok "lan-allow program rejects malformed specs (no rule injection)"

guest="$(awk -v gw="192.168.1.1" -v rules="$guest_rules" -v allow="$allow_rules" \
  -v logging=1 -v log4="$log4" -v log6="$log6" "$render_prog" "$guest_tmpl")"

printf '%s\n' "$guest" | grep -q '@GATEWAY@' &&
  fail "guest ruleset still contains @GATEWAY@ after rendering"
for ph in '^@RESOLVERS@$' '^@ALLOW@$' '^@LOG4@$' '^@LOG6@$'; do
  printf '%s\n' "$guest" | grep -q "$ph" &&
    fail "guest ruleset still contains the ${ph//[\^$]/} placeholder after rendering"
done
ok "guest ruleset renders (gateway, resolver, lan-allow and log placeholders consumed)"

# Every rule must sit inside the table body. This is the exact shape of the bug
# above: an unanchored placeholder match put rules in the header comment block.
guest_head="$(printf '%s\n' "$guest" | sed -n '1,/^table inet isopod_egress/p')"
printf '%s\n' "$guest_head" | grep -qE '^[[:space:]]+(ip|ip6) daddr' &&
  fail "guest ruleset emits rule text before the table declaration"
ok "guest ruleset puts every rule inside the table"

# The resolver exemptions must precede the private-range drop, or they never match.
gr_line="$(printf '%s\n' "$guest" | grep -n 'ip daddr 169\.254\.1\.1 udp' | head -1 | cut -d: -f1)"
gd_line="$(printf '%s\n' "$guest" | grep -n 'counter drop' | head -1 | cut -d: -f1)"
[ -n "$gr_line" ] && [ -n "$gd_line" ] && [ "$gr_line" -lt "$gd_line" ] ||
  fail "guest ruleset orders the resolver exemptions after the drop (they would never match)"
ok "guest ruleset exempts resolvers before the private-range drop"

# The lan-allow exemptions must also precede the drop, for the same reason.
ga_line="$(printf '%s\n' "$guest" | grep -n 'ip daddr 10\.20\.30\.40 accept' | head -1 | cut -d: -f1)"
[ -n "$ga_line" ] && [ "$ga_line" -lt "$gd_line" ] ||
  fail "guest ruleset orders the lan-allow exemptions after the drop (they would never match)"
ok "guest ruleset exempts lan-allow addresses before the private-range drop"

# `limit` stops rule evaluation once the rate is exceeded. If it ever shares a
# rule with the drop, packets over the rate fall past it and are ACCEPTED — the
# rate limiter would silently become a hole in the ruleset. They must stay apart.
# Matches the verdict at end of line, not the word: the log prefix itself
# contains "drop", so a substring test here would always fire.
printf '%s\n' "$guest" | grep -E 'limit rate' | grep -qE '[[:space:]]drop$' &&
  fail "a log rule carries the drop verdict — over the rate limit, traffic would be accepted"
printf '%s\n' "$guest" | grep -q 'log prefix "isopod-egress-drop "' ||
  fail "guest ruleset does not log dropped packets (egress lan-denied would show nothing)"
# And the log must come before the drop, or it never runs.
gl_line="$(printf '%s\n' "$guest" | grep -n 'limit rate' | head -1 | cut -d: -f1)"
[ -n "$gl_line" ] && [ "$gl_line" -lt "$gd_line" ] ||
  fail "guest ruleset logs after the drop (nothing would ever be logged)"
ok "guest ruleset logs drops as a separate rule, ahead of the drop"

# Rendering with nothing optional at all must still produce a loadable ruleset:
# no resolvers, no lan-allow, and logging off (the fallback path for a kernel
# with no log support, which must never be the reason a box fails closed).
guest_empty="$(awk -v gw="192.168.1.1" -v rules="" -v allow="" -v logging=0 \
  "$render_prog" "$guest_tmpl")"
[ "$(printf '%s\n' "$guest_empty" | grep -c '{')" = "$(printf '%s\n' "$guest_empty" | grep -c '}')" ] ||
  fail "guest ruleset has unbalanced braces when rendered with nothing optional"
printf '%s\n' "$guest_empty" | grep -q 'limit rate' &&
  fail "logging=0 still emitted a log rule"
printf '%s\n' "$guest_empty" | grep -qE '^@(RESOLVERS|ALLOW|LOG4|LOG6)@$' &&
  fail "a placeholder survived rendering with nothing optional"
printf '%s\n' "$guest_empty" | grep -q 'counter drop' ||
  fail "logging=0 dropped the drop rules as well"
ok "guest ruleset is balanced and still drops with no resolvers, no lan-allow, no logging"

if command -v nft >/dev/null 2>&1; then
  nft_check "lan-deny" "$lan_deny"
  nft_check "allow-list" "$allow_list"
  nft_check "guest (resolvers + lan-allow + logging)" "$guest"
  nft_check "guest (nothing optional)" "$guest_empty"
else
  skip "nft not installed — ruleset parse check skipped (render checks above still ran)"
fi

printf '%segress render checks passed%s\n' "$c_grn" "$c_rst"
