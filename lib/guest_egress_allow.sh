#!/bin/sh
# Apply the box's lan-allow exemptions to the running guest ruleset.
#
# Streamed into a box over the root SSH channel and run there — it is never
# executed on the host. The host renders the rule lines and pipes them in on
# stdin; this script replaces the tagged rules in the live chain with them, so a
# `lan-allow` add or remove takes effect without restarting the box. The stored
# list in config.yaml is what a later boot renders from, so the two agree.
#
# Usage:  guest_egress_allow.sh sync "<rules>"  replace the tagged rules
#         guest_egress_allow.sh denied [n]      show recent dropped destinations
#
# The rules arrive as one newline-separated argument rather than on stdin: the
# script itself is what the host pipes in (`sh -s`), so stdin is already taken.
#
# Every input line is re-checked here against one exact rule shape before it
# reaches nft. The host validates too, but this script turns text into firewall
# rules, so it does not trust the channel it was handed.

set -eu

FAM=inet
TBL=isopod_egress
CHAIN=output
TAG=isopod-lan-allow

die() {
  echo "guest_egress_allow: $1" >&2
  exit 1
}

nft_present() {
  command -v nft >/dev/null 2>&1 || die "the nft binary is not installed in this box"
  nft list table "$FAM" "$TBL" >/dev/null 2>&1 ||
    die "the isopod_egress table is not loaded (guest egress is off for this box)"
}

# Delete every rule carrying the tag. Handles shift as rules are removed, so the
# chain is re-read each time rather than deleted in one pass from a stale list.
drop_tagged() {
  while :; do
    handle=$(nft -a list chain "$FAM" "$TBL" "$CHAIN" 2>/dev/null |
      awk -v tag="$TAG" '$0 ~ tag && /# handle [0-9]+$/ { print $NF; exit }')
    [ -n "$handle" ] || break
    nft delete rule "$FAM" "$TBL" "$CHAIN" handle "$handle" ||
      die "could not delete rule handle $handle"
  done
}

# One accepted shape, anchored end to end. Anything else is refused rather than
# passed to nft: an address, an optional prefix, an optional single TCP/UDP port.
valid_rule() {
  printf '%s\n' "$1" | grep -Eq \
    '^(ip|ip6) daddr [0-9a-fA-F:./]+( (tcp|udp) dport [0-9]{1,5})? accept comment "'"$TAG"'"$'
}

cmd_sync() {
  nft_present
  rules="${1:-}"
  # Validate everything BEFORE changing the ruleset, so a bad line cannot leave
  # the box with its exemptions half-applied. Here-docs keep these loops in the
  # current shell, so a rejection exits the script rather than a subshell.
  #
  # The shape check is the first gate: it fixes what an accepted line may contain
  # (an accept verdict, our tag, one address, one optional port). But its address
  # pattern cannot tell a valid IPv6 literal from a malformed one, and nft rejects
  # the malformed one — so a line that passes here could still fail `nft insert`,
  # and drop_tagged has by then already removed the working exemptions. So follow
  # it with a real parse of the whole set: build a throwaway table holding exactly
  # these rules and run it through `nft -c`. If the parser rejects any of them,
  # nothing has touched the live chain yet, and the existing rules stay put.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    valid_rule "$line" || die "refusing to apply an unrecognised rule: $line"
  done <<EOF
$rules
EOF
  if [ -n "$rules" ]; then
    # A distinct table name and a plain (unhooked) chain, so the check neither
    # collides with the live isopod_egress table nor needs a hook declaration —
    # it is only parsing the rule expressions. The error file lives under /run
    # (root-owned), not /tmp, where the box user could pre-place a symlink at
    # the predictable name for root to write through.
    printf 'table %s isopod_egress_check { chain c {\n%s\n} }\n' "$FAM" "$rules" |
      nft -c -f - 2>/run/isopod-lan-allow.err ||
      die "nft rejected an exemption; the box's existing rules are unchanged:
$(cat /run/isopod-lan-allow.err 2>/dev/null)"
  fi
  drop_tagged
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # insert (not add) places these ahead of the drop rules at the end of the
    # chain. They are accepts, so their order among the other accepts does not
    # matter. $line is split into nft arguments on purpose.
    # shellcheck disable=SC2086
    nft insert rule "$FAM" "$TBL" "$CHAIN" $line || die "nft rejected: $line"
  done <<EOF
$rules
EOF
  echo "isopod: guest ruleset updated"
}

# nft's log target writes to the guest kernel ring buffer. Pull the destination
# and port back out; DPT is absent for protocols that have no ports.
cmd_denied() {
  dmesg 2>/dev/null | awk -v n="${1:-20}" '
    /isopod-egress-drop/ {
      dst = ""; dpt = ""; proto = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^DST=/)   { dst = substr($i, 5) }
        if ($i ~ /^DPT=/)   { dpt = substr($i, 5) }
        if ($i ~ /^PROTO=/) { proto = substr($i, 7) }
      }
      if (dst == "") next
      key = dst (dpt == "" ? "" : ":" dpt)
      if (!(key in seen)) { order[++c] = key; kproto[key] = proto }
      seen[key]++
    }
    END {
      start = c - n + 1
      if (start < 1) start = 1
      for (i = start; i <= c; i++)
        printf "%s\t%s\t%d\n", order[i], kproto[order[i]], seen[order[i]]
    }'
}

case "${1:-}" in
  sync) cmd_sync "${2:-}" ;;
  denied) cmd_denied "${2:-20}" ;;
  *) die "usage: guest_egress_allow.sh sync|denied" ;;
esac
