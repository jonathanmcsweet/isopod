#!/usr/bin/env bash
#
# diagnose-microvm-ssh.sh — check whether a box's runtime can carry VSCodium /
# Cursor / JetBrains Remote-SSH, i.e. whether real IDE traffic survives an SSH
# port-forward into a service on the box's loopback.
#
# Symptom this explains: the IDE connects, then dies with "Could not fetch
# remote environment" / WebSocket close 1006, even though `isopod shell` works.
# Cause: the krun (libkrun) microVM runtime uses TSI networking. SSH *exec*
# channels are fast, but bulk data over an SSH *port-forward* into a guest
# loopback service can STALL — and the IDE reaches its remote server over
# exactly such a forward. isopod's own ops (shell, copy, export, fetch) use exec
# channels, so they work fine and never expose this.
#
# Upstream libkrun bugs behind this (both OPEN as of this writing):
#   containers/libkrun#579 — TSI drops a large single TX (BufDescTooSmall) and
#     the sender hangs. Triggered by large writes / uploads, NOT small chunks.
#   containers/libkrun#510 — TSI wrongly intercepts guest-internal *unix-socket*
#     loopback traffic, routing the IDE server's socket through the host VMM.
#
# WHY THIS SCRIPT WAS HARDENED: an earlier version tested only a chunked HTTP
# *download* (GET) over a TCP forward. That path can survive TSI even when the
# real IDE fails — a false PASS. The VS Code / VSCodium remote server instead:
#   (a) has the client *upload* a large payload host->guest,
#   (b) exchanges sustained *bidirectional* traffic (its WebSocket), and
#   (c) commonly listens on a *unix domain socket* the client forwards to.
# So this probe now exercises all of (a)-(c) — the exact conditions #579/#510
# break — over both a TCP forward and a UNIX-socket forward. A PASS here means
# the runtime really can carry Remote-SSH.
#
# Usage:   ./diagnose-microvm-ssh.sh <box-name>
#
# Exit codes: 0 = all IDE-shaped transfers survive (runtime is Remote-SSH capable),
#             1 = at least one stalls (IDE will fail — e.g. krun/TSI; use a real
#                 virtio-net microVM or `--container`),
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
command -v python3 >/dev/null || {
  echo "error: python3 is required on the host to run this probe" >&2
  exit 2
}

BOX_USER="${ISOPOD_BOX_USER:-dev}" # in-box user; override with ISOPOD_BOX_USER
SIZE="${ISOPOD_DIAG_BYTES:-16000000}" # bulk payload (16 MB, like the IDE server)
SMALL=1000
GPORT=47000                       # guest loopback TCP listener
GSOCK=/tmp/.isopod-diag.sock      # guest loopback UNIX socket (the IDE pattern)
LTCP=47001                        # host end of the TCP -L forward
LUDS=47002                        # host end of the UNIX-socket -L forward
SOPTS=(-p "$PORT" -i "$KEY"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes -o ConnectTimeout=8)

echo "box '$BOX' -> 127.0.0.1:$PORT (user $BOX_USER), payload $((SIZE / 1000000))MB"

# Host-side client: drive one transfer over an already-open forward and verify
# the whole payload survives within a timeout. Protocol (newline header):
#   DOWN n  -> guest sends n bytes (one large write; stresses #579)
#   UP   n  -> host sends n bytes, guest replies "OK <count>"
#   ECHO n  -> host sends n while reading n back (bidirectional; the WebSocket)
HOST_CLIENT="$(mktemp)"
cat >"$HOST_CLIENT" <<'PY'
import socket, sys, threading, time
mode, host, port, n = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
try:
    s = socket.create_connection((host, port), timeout=10)
except OSError as e:
    sys.stderr.write(f"connect failed: {e}\n"); sys.exit(1)
s.settimeout(40)
buf = b"\0" * min(n, 1 << 20)
start = time.time(); total = 0
try:
    s.sendall(f"{mode} {n}\n".encode())
    if mode == "DOWN":
        while total < n:
            b = s.recv(1 << 20)
            if not b: break
            total += len(b)
    elif mode == "UP":
        sent = 0
        while sent < n:
            s.sendall(buf[: min(len(buf), n - sent)]); sent += min(len(buf), n - sent)
        s.shutdown(socket.SHUT_WR)
        total = n if s.recv(64).startswith(b"OK") else 0
    elif mode == "ECHO":
        def send():
            sent = 0
            try:
                while sent < n:
                    s.sendall(buf[: min(len(buf), n - sent)]); sent += min(len(buf), n - sent)
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        threading.Thread(target=send, daemon=True).start()
        while total < n:
            b = s.recv(1 << 20)
            if not b: break
            total += len(b)
except OSError as e:
    sys.stderr.write(f"transfer error: {e}\n")
dur = time.time() - start
sys.stdout.write(f"{total}B in {dur:.3f}s\n")
sys.exit(0 if total >= n else 1)
PY

cleanup() {
  pkill -f "L $LTCP:127.0.0.1:$GPORT" 2>/dev/null
  pkill -f "L $LUDS:$GSOCK" 2>/dev/null
  ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" \
    "pkill -f isopod-diag-server; rm -f $GSOCK /tmp/.isopod-diag-server.py" 2>/dev/null
  rm -f "$HOST_CLIENT"
}
trap cleanup EXIT

fail=0
note_fail() { fail=1; }

# 1. Reachable at all? (small exec — always works, even under krun/TSI.)
echo -n "[1] small SSH exec ................... "
if timeout 15 ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" 'command -v python3 >/dev/null' 2>/dev/null; then
  echo "ok"
else
  echo "FAILED — box unreachable over SSH, or no python3 in it (isopod start $BOX?)" >&2
  exit 2
fi

# 2. Install + launch the guest diag server (TCP + UNIX socket), detached so
#    this ssh call returns instead of holding the channel.
ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" "cat > /tmp/.isopod-diag-server.py" <<PY 2>/dev/null
import os, socket, threading
TCP_PORT, SOCK_PATH = $GPORT, "$GSOCK"
def handle(conn):
    conn.settimeout(60)
    f = conn.makefile("rb")
    header = f.readline().split()
    if not header:
        conn.close(); return
    op = header[0].decode(); n = int(header[1]) if len(header) > 1 else 0
    try:
        if op == "DOWN":
            conn.sendall(b"\0" * n)                       # one large write
        elif op == "UP":
            got = 0
            while got < n:
                c = f.read(min(1 << 16, n - got))
                if not c: break
                got += len(c)
            conn.sendall(f"OK {got}\n".encode())
        elif op == "ECHO":
            got = 0
            while got < n:
                c = f.read(min(1 << 16, n - got))
                if not c: break
                got += len(c); conn.sendall(c)
    except OSError:
        pass
    conn.close()
def serve(sock):
    while True:
        try: conn, _ = sock.accept()
        except OSError: break
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
t.bind(("127.0.0.1", TCP_PORT)); t.listen(16)
try: os.unlink(SOCK_PATH)
except FileNotFoundError: pass
u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
u.bind(SOCK_PATH); u.listen(16)
threading.Thread(target=serve, args=(t,), daemon=True).start()
serve(u)
PY
# Detached; the '.isopod-diag-server.py' path makes it findable by `pkill -f`.
timeout 15 ssh "${SOPTS[@]}" "$BOX_USER@127.0.0.1" \
  "setsid python3 /tmp/.isopod-diag-server.py </dev/null >/dev/null 2>&1 &" 2>/dev/null
sleep 2

# 3. Bring up both forwards: a TCP forward and a UNIX-socket forward (the latter
#    is how Remote-SSH reaches the VS Code server, and what #510 breaks).
echo -n "[2] TCP + unix-socket forwards ...... "
ok=1
ssh "${SOPTS[@]}" -o ExitOnForwardFailure=yes -fN -L "$LTCP:127.0.0.1:$GPORT" "$BOX_USER@127.0.0.1" 2>/dev/null || ok=0
ssh "${SOPTS[@]}" -o ExitOnForwardFailure=yes -fN -L "$LUDS:$GSOCK" "$BOX_USER@127.0.0.1" 2>/dev/null || ok=0
if [ "$ok" = 1 ]; then echo "ok"; else
  echo "FAILED — could not set up forwards" >&2; exit 1
fi
sleep 1

# Run one leg; small proves the forward works, bulk is the decisive check.
leg() { # leg <label> <mode> <host> <port> <bytes> <decisive 0|1>
  local label="$1" mode="$2" h="$3" p="$4" n="$5" decisive="$6" out
  printf '%-36s' "    $label"
  if out=$(timeout 45 python3 "$HOST_CLIENT" "$mode" "$h" "$p" "$n" 2>/dev/null); then
    echo "$out"
  else
    echo "STALLED (${out:-no data})"
    [ "$decisive" = 1 ] && note_fail
  fi
}

echo "[3] TCP forward:"
leg "small down ................" DOWN 127.0.0.1 "$LTCP" "$SMALL" 0
leg "bulk download (large write)" DOWN 127.0.0.1 "$LTCP" "$SIZE" 1
leg "bulk upload (host->guest) ." UP   127.0.0.1 "$LTCP" "$SIZE" 1
leg "bulk bidirectional echo ..." ECHO 127.0.0.1 "$LTCP" "$SIZE" 1

echo "[4] unix-socket forward (the IDE server's real path):"
leg "small down ................" DOWN 127.0.0.1 "$LUDS" "$SMALL" 0
leg "bulk download (large write)" DOWN 127.0.0.1 "$LUDS" "$SIZE" 1
leg "bulk bidirectional echo ..." ECHO 127.0.0.1 "$LUDS" "$SIZE" 1

echo
if [ "$fail" = 0 ]; then
  echo "PASS — uploads, bidirectional traffic, and unix-socket forwards all survive;"
  echo "       Remote-SSH (isopod code) should work on this runtime."
  exit 0
else
  echo "STALLED — at least one IDE-shaped transfer did not complete." >&2
  echo "VSCodium / Cursor / JetBrains Remote-SSH ('isopod code') will fail (WebSocket 1006)," >&2
  echo "because they reach their remote server over exactly these forwards." >&2
  echo "isopod shell / copy / export (SSH exec channels) are unaffected. Fixes:" >&2
  echo "  - a runtime with a real virtio-net stack (not krun/TSI), or" >&2
  echo "  - a plain container:  isopod create ... --container" >&2
  exit 1
fi
