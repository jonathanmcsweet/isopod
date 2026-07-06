#!/usr/bin/env bash
#
# diagnose-microvm-ssh.sh — check whether a box's runtime can carry VSCodium /
# Cursor / JetBrains Remote-SSH, i.e. whether bulk data survives an SSH TCP
# port-forward into a service on the box's loopback.
#
# Symptom this explains: the IDE connects, then dies with "Could not fetch
# remote environment" / WebSocket close 1006, even though `isopod shell` works.
# Cause: the krun (libkrun) microVM runtime uses TSI networking. SSH *exec*
# channels are fast, but bulk data over an SSH *port-forward* into a guest
# loopback service STALLS — and the IDE reaches its remote server over exactly
# such a forward. isopod's own ops (shell, copy, export, fetch) use exec
# channels, so they work fine and never expose this.
#
# Upstream libkrun bugs behind this (both open, unfixed as of libkrun 1.19):
#   containers/libkrun#579 — TSI drops transfers larger than a fixed vsock
#     buffer (BufDescTooSmall) and the sender hangs.
#   containers/libkrun#510 — TSI wrongly intercepts guest-internal loopback
#     traffic, routing the IDE server's socket through the host VMM.
#
# This probe replicates the IDE's path precisely: it starts a listener on the
# box's loopback, opens an `ssh -L` forward to it, and pulls a bulk payload
# through that forward, checking it completes within a timeout. A *small*
# forward is checked too, so a pass/stall split is unambiguous. It talks
# straight to the box's own key/port (no isopod wrapper), so it works on any
# isopod version.
#
# Usage:   ./diagnose-microvm-ssh.sh <box-name>
#
# Exit codes: 0 = bulk survives the forward (runtime is Remote-SSH capable),
#             1 = bulk stalls in the forward (IDE will fail — e.g. krun/TSI; use
#                 a virtio-net microVM (kata) or `--container`),
#             2 = usage / setup error.

set -uo pipefail

BOX="${1:-}"
if [ -z "$BOX" ]; then
  echo "usage: $0 <box-name>" >&2
  exit 2
fi

CONFIG_DIR="${ISOPOD_CONFIG_DIR:-$HOME/.config/isopod}"
BOX_DIR="$CONFIG_DIR/boxes/$BOX"
META="$BOX_DIR/meta"
KEY="$BOX_DIR/id_ed25519"
[ -f "$META" ] || {
  echo "error: no box '$BOX' under $CONFIG_DIR/boxes (set ISOPOD_CONFIG_DIR if it lives elsewhere)" >&2
  exit 2
}
[ -f "$KEY" ] || {
  echo "error: missing key $KEY" >&2
  exit 2
}
PORT="$(sed -n 's/^port=//p' "$META")"
[ -n "$PORT" ] || {
  echo "error: no port in $META (is the box running? try: isopod start $BOX)" >&2
  exit 2
}

BOX_USER="${ISOPOD_BOX_USER:-dev}" # in-box user; override with ISOPOD_BOX_USER
GPORT=47000                        # guest loopback listener port
LPORT=47001                        # host end of the ssh -L forward
SOPTS=(-p "$PORT" -i "$KEY"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes -o ConnectTimeout=8)

echo "box '$BOX' -> 127.0.0.1:$PORT (user $BOX_USER)"

cleanup() {
  pkill -f "L $LPORT:127.0.0.1:$GPORT" 2>/dev/null
  ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" \
    "pkill -f 'http.server $GPORT'; rm -f /tmp/.isopod-diag-*.bin" 2>/dev/null
}
trap cleanup EXIT

# 1. Reachable at all? (small exec — always works, even under krun/TSI.)
echo -n "[1] small SSH exec ................ "
if timeout 15 ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" 'command -v python3 >/dev/null' 2>/dev/null; then
  echo "ok"
else
  echo "FAILED — box unreachable over SSH, or no python3 in it (isopod start $BOX?)" >&2
  exit 2
fi

# 2. Start a loopback HTTP server in the guest serving a small + a bulk file,
#    fully detached so this ssh call returns instead of holding the channel.
timeout 15 ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" "
  head -c 1000 /dev/zero >/tmp/.isopod-diag-s.bin
  head -c 16000000 /dev/zero >/tmp/.isopod-diag-b.bin
  cd /tmp
  setsid sh -c 'exec python3 -m http.server $GPORT --bind 127.0.0.1' </dev/null >/dev/null 2>&1 &
" 2>/dev/null
sleep 2

# 3. Open the ssh -L forward into that guest loopback service — the IDE's path.
echo -n "[2] ssh -L forward setup .......... "
if ssh "${SOPTS[@]}" -o ExitOnForwardFailure=yes -fN \
  -L "$LPORT:127.0.0.1:$GPORT" "$BOX_USER@127.0.0.1" 2>/dev/null; then
  echo "ok"
else
  echo "FAILED — could not set up the forward" >&2
  exit 1
fi
sleep 1

# 4. Small vs bulk THROUGH the forward. Small proves the forward works at all;
#    bulk is the decisive check (this is what the IDE's remote server needs).
echo -n "[3] small (1KB) via forward ....... "
if curl -sS -m 20 -o /dev/null -w '%{size_download}B in %{time_total}s\n' \
  "http://127.0.0.1:$LPORT/.isopod-diag-s.bin" 2>/dev/null; then :; else
  echo "FAILED — forward set up but no data flows (unexpected)" >&2
  exit 1
fi

echo -n "[4] bulk (16MB) via forward ....... "
if curl -sS -m 45 -o /dev/null -w '%{size_download}B in %{time_total}s\n' \
  "http://127.0.0.1:$LPORT/.isopod-diag-b.bin" 2>/dev/null; then
  echo
  echo "PASS — bulk survives the forward; Remote-SSH (isopod code) should work."
  exit 0
else
  echo "STALLED"
  echo
  echo "Bulk data stalls in an SSH port-forward into this box's runtime." >&2
  echo "VSCodium / Cursor / JetBrains Remote-SSH ('isopod code') will fail (WebSocket 1006)," >&2
  echo "because they reach their remote server over exactly such a forward." >&2
  echo "isopod shell / copy / export (SSH exec channels) are unaffected. Fixes:" >&2
  echo "  - recreate with a virtio-net microVM:  --runtime kata-runtime" >&2
  echo "  - or a plain container:                isopod create ... --container" >&2
  exit 1
fi
