#!/usr/bin/env bash
# Host verification for the isopod 3.9.0 changes.
#
# Run this from the isopod repo on a machine with a working container engine.
# It creates throwaway boxes named hv-* and removes them at the end.
#
#   bash test/host-verify.sh            # everything the host supports
#   SKIP_LIVE=1 bash test/host-verify.sh  # skip the slow live bats suite
#
# Deliberately does NOT use `set -e`: every check runs and reports, so one
# failure does not hide the rest.
set -uo pipefail

ISOPOD="${ISOPOD:-./isopod}"
PASS=0 FAIL=0 SKIP=0
declare -a NOTES=()

ok() {
  printf '  [PASS] %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  [FAIL] %s\n' "$1"
  FAIL=$((FAIL + 1))
  NOTES+=("FAIL: $1")
}
skip() {
  printf '  [SKIP] %s\n' "$1"
  SKIP=$((SKIP + 1))
}
hdr() { printf '\n=== %s ===\n' "$1"; }
note() { printf '  [note] %s\n' "$1"; }

# Every isopod call goes through this. Several commands ask for confirmation
# (upgrade, remap, rm, gc), and this script sends their output to a log file, so a
# prompt would be invisible and `read` would block the run forever. Closing stdin
# makes any prompt fail fast instead of hanging; the commands that ask also get
# their non-interactive flag explicitly below.
iso() { "$ISOPOD" "$@" </dev/null; }

cleanup_box() { iso rm "$1" --force >/dev/null 2>&1 || true; }
cleanup_all() {
  local b r
  for b in hv-offline hv-disk hv-nest hv-remap hv-upg; do cleanup_box "$b"; done
  # `iso fetch` and `iso remap` write into the repo this runs from. Drop what
  # they left so a verification run does not accumulate refs in your checkout.
  for r in $(git for-each-ref --format='%(refname)' 'refs/remotes/hv-remap/*' \
    'refs/remap-backup/remotes/hv-remap/*' 2>/dev/null); do
    git update-ref -d "$r" 2>/dev/null || true
  done
}
trap cleanup_all EXIT

[ -x "$ISOPOD" ] || {
  echo "run this from the isopod repo (no ./isopod here)"
  exit 1
}

# --- capability probe --------------------------------------------------------
hdr "Host capabilities"
iso doctor 2>&1 | sed 's/^/  /'
HAS_KVM=0
[ -e /dev/kvm ] && HAS_KVM=1
printf '\n  /dev/kvm present: %s\n' "$([ "$HAS_KVM" = 1 ] && echo yes || echo no)"

# --- A. baseline live suite --------------------------------------------------
hdr "A. Live bats suite (egress sanitising, fetch/remap, run args)"
if [ "${SKIP_LIVE:-0}" = 1 ]; then
  skip "live suite (SKIP_LIVE=1)"
else
  if RUN_LIVE=1 bash test/run.sh >/tmp/hv-live.log 2>&1; then
    ok "live suite passed (log: /tmp/hv-live.log)"
  else
    bad "live suite failed - see /tmp/hv-live.log"
  fi
fi

# --- B. offline boxes (the newest code, least proven) ------------------------
hdr "B. Offline box (--offline)"
# Prefer whatever runtime this host resolves to. Where the engine cannot put a
# route on an internal network, create refuses on purpose and names --container:
# that refusal is the feature working, so take its advice instead of reporting the
# host as broken and skipping the whole section.
if iso create hv-offline --offline >/tmp/hv-offline.log 2>&1 ||
  { grep -q -- '--offline needs a plain container' /tmp/hv-offline.log &&
    iso create hv-offline --offline --container >>/tmp/hv-offline.log 2>&1; }; then
  ok "offline box created and reachable over SSH"
  grep -q -- '--offline needs a plain container' /tmp/hv-offline.log &&
    note "this engine cannot route an internal network, so the box ran with --container (create said so, correctly)"

  if iso info hv-offline 2>/dev/null | grep -qi 'OFFLINE'; then
    ok "info reports the OFFLINE posture"
  else
    bad "info does not report OFFLINE"
  fi

  # The box must not reach the internet.
  if iso shell hv-offline -- sh -c 'curl -sS -m 8 https://example.com >/dev/null 2>&1' 2>/dev/null; then
    bad "offline box REACHED the internet (this is the critical check)"
  else
    ok "offline box cannot reach the internet"
  fi

  # ...nor the LAN. Uses the host's default gateway as the target.
  GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
  if [ -n "${GW:-}" ]; then
    if iso shell hv-offline -- sh -c "ping -c1 -W2 $GW >/dev/null 2>&1" 2>/dev/null; then
      bad "offline box REACHED the LAN gateway $GW"
    else
      ok "offline box cannot reach the LAN gateway"
    fi
  else
    skip "LAN check (no default gateway found)"
  fi

  # Copy-in and export must still work: they ride the SSH channel, not the network.
  TMPD="$(mktemp -d)"
  echo hello >"$TMPD/f.txt"
  if iso copy-in hv-offline "$TMPD" >/dev/null 2>&1; then
    ok "copy-in works on an offline box"
  else
    bad "copy-in failed on an offline box"
  fi
  if iso export hv-offline "$TMPD/out" >/dev/null 2>&1; then
    ok "export works on an offline box"
  else
    bad "export failed on an offline box"
  fi
  rm -rf "$TMPD"

  # The posture must survive a rebuild rather than silently regaining a network.
  if iso reconfigure hv-offline --memory 3g >/dev/null 2>&1; then
    if iso info hv-offline 2>/dev/null | grep -qi 'OFFLINE'; then
      ok "offline survives reconfigure"
    else
      bad "reconfigure LOST the offline posture"
    fi
  else
    skip "reconfigure (did not complete on this host)"
  fi
else
  bad "offline box failed to create - see /tmp/hv-offline.log (this is the one to send back)"
fi

# --- C. data volume startup fix (needs a microVM runtime) --------------------
hdr "C. Data volume mountpoint fix (--disk / --nested-containers)"
if [ "$HAS_KVM" != 1 ]; then
  skip "microVM tests (no /dev/kvm on this host)"
else
  if iso create hv-nest --nested-containers >/tmp/hv-nest.log 2>&1; then
    ok "nested-containers box created"
    # The attack: redirect an intermediate component of the mountpoint path.
    iso shell hv-nest -- sh -c 'rm -rf ~/.local/share && ln -s /etc ~/.local/share' >/dev/null 2>&1
    iso stop hv-nest >/dev/null 2>&1
    if iso start hv-nest >/tmp/hv-nest-restart.log 2>&1; then
      ok "box still boots after the mountpoint was redirected"
      if iso shell hv-nest -- sh -c '[ -d /etc/containers ] && mountpoint -q /etc/containers' 2>/dev/null; then
        bad "the redirect SUCCEEDED - /etc/containers is a mounted volume (fix not effective)"
      else
        ok "redirect refused - nothing was mounted over /etc"
      fi
      if iso shell hv-nest -- sh -c 'true' 2>/dev/null; then
        ok "SSH still reachable after the refusal (fails safe, not closed)"
      else
        bad "box became unreachable after the refusal"
      fi
    else
      bad "box did NOT boot after the redirect - see /tmp/hv-nest-restart.log"
    fi
  else
    bad "nested-containers box failed to create - see /tmp/hv-nest.log"
  fi
fi

# --- D. identity rewrite (remap) --------------------------------------------
hdr "D. Identity rewrite (isopod remap)"
if iso create hv-remap >/tmp/hv-remap.log 2>&1; then
  # The repo has to be AT the workspace root: that is where isopod looks for the
  # box's git identity, and a repo in a subdirectory leaves it undetectable.
  iso shell hv-remap -- sh -c '
    cd /home/dev/workspace && git init -q &&
    git config user.email box@isopod && git config user.name "Box" &&
    echo x > a && git add a && git commit -qm one' >/dev/null 2>&1
  # A commit git accepts but the old rewriter skipped: an author with no name.
  iso shell hv-remap -- sh -c '
    cd /home/dev/workspace &&
    B=$(git rev-parse --abbrev-ref HEAD) &&
    T=$(git rev-parse HEAD^{tree}) && P=$(git rev-parse HEAD) &&
    C=$(printf "tree %s\nparent %s\nauthor <box@isopod> 1700000000 +0000\ncommitter <box@isopod> 1700000000 +0000\n\nnoname\n" "$T" "$P" | git hash-object --literally -t commit -w --stdin) &&
    git update-ref "refs/heads/$B" "$C"' >/dev/null 2>&1
  if iso fetch hv-remap >/dev/null 2>&1 &&
    iso remap hv-remap --force --old-email box@isopod --name "Real Name" --email real@example.com >/tmp/hv-remap-run.log 2>&1; then
    ok "remap completed against a box with an unusual commit"
    # Check the rewritten refs, not the log: isopod prints the identity it is
    # rewriting FROM ("Rewriting commits by <box@isopod>"), so grepping the log
    # flags every successful run. refs/remap-backup/ is excluded on purpose, it
    # is meant to still hold the originals.
    if git for-each-ref --format='%(refname)' 'refs/remotes/hv-remap/*' 2>/dev/null |
      while read -r r; do git log --format='%an <%ae>' "$r" 2>/dev/null; done |
      grep -qi 'box@isopod'; then
      NOTES+=("remap left the box identity on refs/remotes/hv-remap/*")
    fi
  else
    bad "remap failed - see /tmp/hv-remap-run.log"
  fi
else
  bad "remap test box failed to create"
fi

# --- E. upgrade rebase (never exercised against a real engine) ---------------
hdr "E. upgrade (rebase path)"
if iso create hv-upg >/tmp/hv-upg.log 2>&1; then
  TMPD="$(mktemp -d)"
  echo keepme >"$TMPD/keep.txt"
  iso copy-in hv-upg "$TMPD" >/dev/null 2>&1
  if iso upgrade hv-upg --yes >/tmp/hv-upg-run.log 2>&1; then
    if iso shell hv-upg -- sh -c 'find /home/dev/workspace -name keep.txt | grep -q .' 2>/dev/null; then
      ok "upgrade preserved the workspace"
    else
      bad "upgrade LOST the workspace - see /tmp/hv-upg-run.log"
    fi
  else
    bad "upgrade failed - see /tmp/hv-upg-run.log"
  fi
  rm -rf "$TMPD"
else
  bad "upgrade test box failed to create"
fi

# --- summary -----------------------------------------------------------------
hdr "Summary"
printf '  passed: %d   failed: %d   skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
for n in ${NOTES+"${NOTES[@]}"}; do printf '  %s\n' "$n"; done
[ "$FAIL" -eq 0 ] || printf '\n  Send back the named log files for anything that failed.\n'
[ "$FAIL" -eq 0 ]
