#!/usr/bin/env bash
#
# verify-host-isolation.sh — empirically confirm an isopod container cannot
# see host-machine information.
#
# It probes the box exactly the way an AI agent extension would: through the
# same shell/process environment the remote extension host runs in. It dumps
# what the box sees and flags anything that looks like it leaked from the host.
#
# Usage:
#   ./verify-host-isolation.sh <box-ssh-host>      # e.g. isopod-myproject
#   ./verify-host-isolation.sh isopod-myproject --strict
#
# Exit codes: 0 = no host leakage detected, 1 = potential leak, 2 = usage error.
#
# This trusts NOTHING from the code audit — it observes runtime behavior.

set -uo pipefail

BOX="${1:-}"
STRICT="${2:-}"

if [[ -z "$BOX" ]]; then
  echo "usage: $0 <box-ssh-host> [--strict]" >&2
  exit 2
fi

# --strict: treat checks that could not actually be performed (e.g. no
# extension-host process is running yet) as failures rather than skippable
# notes, so a PASS means every probe really ran.
strict=0
[[ "$STRICT" == "--strict" ]] && strict=1

# --- Gather host-side fingerprints we will look for inside the box ----------
HOST_HOSTNAME="$(hostname 2>/dev/null || echo __nohost__)"
HOST_USER="$(id -un 2>/dev/null || echo __nouser__)"
HOST_HOME="${HOME:-__nohome__}"
HOST_KERNEL="$(uname -r 2>/dev/null || echo __nokernel__)"
# A few host env values that should NEVER appear in the box:
HOST_SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}"

leak=0
note() { printf '  %s\n' "$*"; }
flag() {
  printf '  [!] %s\n' "$*" >&2
  leak=1
}

run_in_box() {
  # -o BatchMode forces non-interactive; no agent, no X11, no extra env sent.
  ssh -o BatchMode=yes -o ForwardAgent=no -o ForwardX11=no "$BOX" "$@" 2>/dev/null
}

echo "=== isopod host-isolation verification ==="
echo "Box SSH host : $BOX"
echo "Host machine : user=$HOST_USER host=$HOST_HOSTNAME kernel=$HOST_KERNEL"
echo

# --- 0. Connectivity --------------------------------------------------------
if ! run_in_box true; then
  echo "Cannot SSH to '$BOX' non-interactively. Is the box running?" >&2
  exit 2
fi

# --- 1. Identity the box reports -------------------------------------------
echo "--- 1. Identity as seen INSIDE the box ---"
BOX_HOSTNAME="$(run_in_box hostname)"
BOX_USER="$(run_in_box id -un)"
BOX_KERNEL="$(run_in_box uname -r)"
note "container hostname : $BOX_HOSTNAME"
note "container user     : $BOX_USER"
note "container kernel   : $BOX_KERNEL"
[[ "$BOX_HOSTNAME" == "$HOST_HOSTNAME" ]] && flag "container hostname EQUALS host hostname ($HOST_HOSTNAME)"
# Note: with Podman sharing the host kernel, BOX_KERNEL == HOST_KERNEL is EXPECTED
# and is not a host-info leak through VSCodium — it's the container model itself.
[[ "$BOX_KERNEL" == "$HOST_KERNEL" ]] && note "(kernel matches host — expected for Podman; not a VSCodium leak)"
echo

# --- 2. Environment the box's shell exposes --------------------------------
echo "--- 2. Environment variables visible in the box ---"
BOX_ENV="$(run_in_box env)"
# Look for host fingerprints leaking into the box env.
if grep -qiF "$HOST_USER" <<<"$BOX_ENV" && [[ "$HOST_USER" != "$BOX_USER" ]]; then
  flag "host username '$HOST_USER' appears in container env:"
  grep -iF "$HOST_USER" <<<"$BOX_ENV" | sed 's/^/      /' >&2
fi
if [[ -n "$HOST_HOME" && "$HOST_HOME" != "__nohome__" ]] && grep -qF "$HOST_HOME" <<<"$BOX_ENV"; then
  flag "host HOME path '$HOST_HOME' appears in container env:"
  grep -F "$HOST_HOME" <<<"$BOX_ENV" | sed 's/^/      /' >&2
fi
if [[ -n "$HOST_SSH_AUTH_SOCK" ]] && grep -qF "$HOST_SSH_AUTH_SOCK" <<<"$BOX_ENV"; then
  flag "host SSH_AUTH_SOCK leaked into container (agent forwarding may be ON):"
  grep -F "SSH_AUTH_SOCK" <<<"$BOX_ENV" | sed 's/^/      /' >&2
fi
# SSH_AUTH_SOCK present at all (even container-side) means forwarding is on.
if grep -q '^SSH_AUTH_SOCK=' <<<"$BOX_ENV"; then
  flag "SSH_AUTH_SOCK is set in the box — SSH agent forwarding appears ENABLED."
  note "    isopod expects ForwardAgent no. Check your ssh_config."
else
  note "SSH_AUTH_SOCK not set in box (agent forwarding off — good)."
fi
echo

# --- 3. Host filesystem reachability ---------------------------------------
echo "--- 3. Host filesystem probes ---"
# These host paths should NOT be readable/visible from inside the box.
for probe in "$HOST_HOME/.ssh/id_rsa" "$HOST_HOME/.aws/credentials" \
  "$HOST_HOME/.config/isopod" "/etc/machine-id-host"; do
  if run_in_box test -e "$probe"; then
    flag "host path is visible inside the box: $probe"
  fi
done
note "checked common host secret paths — none visible unless flagged above"

# Bind-mount detection: isopod should have NO host bind mounts.
BOX_MOUNTS="$(run_in_box cat /proc/mounts)"
if grep -Eq '/host|/mnt/host|host_mnt' <<<"$BOX_MOUNTS"; then
  flag "suspicious host-like bind mount detected in /proc/mounts:"
  grep -E '/host|/mnt/host|host_mnt' <<<"$BOX_MOUNTS" | sed 's/^/      /' >&2
else
  note "no host-like bind mounts in /proc/mounts (good)"
fi
echo

# --- 4. machine-id / network identity --------------------------------------
echo "--- 4. Machine + network identity ---"
HOST_MACHINE_ID="$(cat /etc/machine-id 2>/dev/null || echo __none__)"
BOX_MACHINE_ID="$(run_in_box cat /etc/machine-id 2>/dev/null || echo __none__)"
note "host  /etc/machine-id : $HOST_MACHINE_ID"
note "box   /etc/machine-id : $BOX_MACHINE_ID"
if [[ "$BOX_MACHINE_ID" != "__none__" && "$BOX_MACHINE_ID" == "$HOST_MACHINE_ID" ]]; then
  flag "container machine-id EQUALS host machine-id"
else
  note "machine-id differs from host (good)"
fi
echo

# --- 5. Extension-host process env (closest proxy to what an agent sees) ----
# The remote extension host is a node process; its env is what extensions read
# via process.env. We approximate by inspecting any running server/node procs.
echo "--- 5. Remote extension-host process environment ---"
EH_PIDS="$(run_in_box pgrep -f 'extensionHostProcess|server-main|vscode-server|codium-server' || true)"
if [[ -z "$EH_PIDS" ]]; then
  if [[ "$strict" -eq 1 ]]; then
    flag "no extension-host process found — cannot verify what an agent sees (--strict)"
  else
    note "no extension-host process found (open a window to the box, then re-run for this check)"
  fi
else
  for pid in $EH_PIDS; do
    EH_ENV="$(run_in_box cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n')"
    [[ -z "$EH_ENV" ]] && continue
    if [[ -n "$HOST_HOME" && "$HOST_HOME" != "__nohome__" ]] && grep -qF "$HOST_HOME" <<<"$EH_ENV"; then
      flag "host HOME path appears in extension-host env (pid $pid)"
    fi
    if grep -q '^SSH_AUTH_SOCK=' <<<"$EH_ENV"; then
      flag "extension-host env contains SSH_AUTH_SOCK (pid $pid) — forwarding on"
    fi
  done
  note "inspected extension-host env for host fingerprints"
fi
echo

# --- Verdict ----------------------------------------------------------------
echo "=== Verdict ==="
if [[ "$leak" -eq 0 ]]; then
  echo "PASS — no host-machine information detected leaking into the box."
  exit 0
else
  echo "ATTENTION — potential host-info exposure flagged above. Review [!] lines."
  exit 1
fi
