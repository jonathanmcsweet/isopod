#!/usr/bin/env bash
# Host verification for the isopod 3.10.0 changes.
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

# The box sshd does NOT listen on 22: isopod publishes the host port onto
# BOX_SSHD_PORT inside the box. Probing 22 connects to nothing, which reads
# exactly like a blocked neighbour. Read the real value from the script instead
# of keeping a copy here that can drift out of step with it.
BOX_SSHD_PORT="$(ISOPOD_SOURCED=1 bash -c 'source "$1" >/dev/null 2>&1; printf %s "${BOX_SSHD_PORT:-}"' _ "$ISOPOD" 2>/dev/null)"
[ -n "$BOX_SSHD_PORT" ] || BOX_SSHD_PORT=2222

# Run one shell command inside a box.
#
# `isopod shell <box> -- a b c` reaches the box as the joined string "a b c":
# ssh concatenates its argv and the box's shell re-splits it, which is the
# documented behaviour. Quoting written here does not survive that, so
# `sh -c 'curl -m 8 https://example.com'` arrives as `sh -c curl -m 8 ...` and
# runs curl with no arguments: exit 2, whatever the network can reach. Six
# checks in this script were reading that as proof of isolation. Pass ONE
# already-quoted word and let the box shell run it.
in_box() { # in_box <box> <shell-command>
  iso shell "$1" -- "$2"
}

cleanup_box() { iso rm "$1" --force >/dev/null 2>&1 || true; }
cleanup_all() {
  local b r
  for b in hv-offline hv-offline2 hv-offline3 hv-disk hv-nest hv-remap hv-upg; do cleanup_box "$b"; done
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
  # Scalar, not `[ -z "${OFF_EXTRA+x}" ]` on the array below: for an array that
  # expansion tests element 0, so an EMPTY array reads as unset and B2 skipped
  # itself on every host where --offline did not need the --container fallback,
  # which is precisely where B2 can run.
  OFF_READY=1
  OFF_EXTRA=()
  grep -q -- '--offline needs a plain container' /tmp/hv-offline.log && {
    OFF_EXTRA=(--container)
    note "this engine cannot route an internal network, so the box ran with --container (create said so, correctly)"
  }

  if iso info hv-offline 2>/dev/null | grep -qi 'OFFLINE'; then
    ok "info reports the OFFLINE posture"
  else
    bad "info does not report OFFLINE"
  fi

  # The box must not reach the internet. Check curl is there first: without the
  # control, a missing curl exits 127 and reads exactly like a blocked network.
  if ! in_box hv-offline 'command -v curl' >/dev/null 2>&1; then
    skip "internet check (no curl in the box, so the probe would prove nothing)"
  elif in_box hv-offline 'curl -sS -m 8 -o /dev/null https://example.com' >/dev/null 2>&1; then
    bad "offline box REACHED the internet (this is the critical check)"
  else
    ok "offline box cannot reach the internet"
  fi

  # ...nor the LAN. The image has no ping (no iputils-ping in the Dockerfile),
  # so ICMP is not available to probe with.
  #
  # The route table is NOT the check it looks like. Where the engine can install
  # static routes, ensure_offline_network creates the internal network WITH
  # `--route 0.0.0.0/0`, because a microVM reaches its guest through passt and
  # passt picks its template interface by following the default route. So an
  # offline microVM box has a default route by design, pointing at a bridge with
  # no path off the host. Its presence proves nothing either way; report it and
  # let the reachability probes decide. Field 2 of /proc/net/route is the
  # destination, 00000000 being the default route.
  if in_box hv-offline 'cut -f2 /proc/net/route | grep -qx 00000000' >/dev/null 2>&1; then
    note "the box has a default route: expected here, the internal network is created with --route so passt can find its interface"
  else
    note "the box has no default route (this engine cannot install one, so the box is a plain container)"
  fi

  # Corroboration, not proof: a gateway that refuses TCP/22 looks the same as one
  # the box cannot reach. Only the connecting case is conclusive, and that case
  # is a real failure.
  GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
  if [ -n "${GW:-}" ]; then
    if in_box hv-offline "timeout 5 bash -c 'exec 3<>/dev/tcp/$GW/22'" >/dev/null 2>&1; then
      bad "offline box OPENED TCP to the LAN gateway $GW"
    else
      ok "offline box could not open TCP to the LAN gateway $GW"
    fi
  else
    skip "LAN gateway probe (no default gateway found)"
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

# --- B2. neighbour isolation (--guest-inbound, new in 3.10) ------------------
hdr "B2. Box-to-box isolation on a shared network"
# Offline boxes share one internal engine network, so with nothing filtering
# inbound traffic box A can open a connection to box B's sshd. 3.10 loads an nft
# input chain inside the box that drops anything not from the host. This is the
# only check that exercises that change, and it needs a second box.
#
# The chain is loaded by the box's own entrypoint, so it exists ONLY on a microVM
# box: a plain container has no CAP_NET_ADMIN to load a ruleset with. Where
# --offline had to fall back to --container, the protection is absent by
# construction, and this section says so instead of reporting a pass.
if [ "${OFF_READY:-0}" != 1 ]; then
  skip "neighbour isolation (no offline box to test from)"
elif iso create hv-offline2 --offline ${OFF_EXTRA+"${OFF_EXTRA[@]}"} >/tmp/hv-offline2.log 2>&1; then
  ok "second offline box created"
  TIER="$(iso info hv-offline 2>/dev/null | awk -F': *' '/isolation/{print $2; exit}')"
  note "offline boxes on this host run as: ${TIER:-unknown}"
  case "${TIER:-}" in
    microVM*) ;;
    *) note "the in-box inbound filter is microVM-only, so a reach below is a known gap, not a regression" ;;
  esac
  B_IP="$(in_box hv-offline2 'hostname -I' 2>/dev/null | awk '{print $1}')"
  if [ -z "${B_IP:-}" ]; then
    skip "neighbour isolation (could not read the second box's address)"
  elif ! in_box hv-offline "timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$BOX_SSHD_PORT'" >/dev/null 2>&1; then
    # Control: a box that cannot open TCP at all would read as isolated.
    skip "neighbour isolation (the box cannot reach even its own sshd, so a refusal would prove nothing)"
  elif in_box hv-offline "timeout 5 bash -c 'exec 3<>/dev/tcp/$B_IP/$BOX_SSHD_PORT'" >/dev/null 2>&1; then
    bad "offline box REACHED its neighbour's sshd at $B_IP:$BOX_SSHD_PORT"
  else
    ok "offline box cannot reach its neighbour's sshd at $B_IP:$BOX_SSHD_PORT"
    # Positive control. Without it, "cannot reach" could equally mean the two
    # boxes were never on the same network, and the pass above would be empty.
    # With the filter off, the identical probe must connect.
    if iso create hv-offline3 --offline --guest-inbound off ${OFF_EXTRA+"${OFF_EXTRA[@]}"} >/tmp/hv-offline3.log 2>&1; then
      C_IP="$(in_box hv-offline3 'hostname -I' 2>/dev/null | awk '{print $1}')"
      if [ -n "${C_IP:-}" ] &&
        in_box hv-offline "timeout 5 bash -c 'exec 3<>/dev/tcp/$C_IP/$BOX_SSHD_PORT'" >/dev/null 2>&1; then
        ok "control: the same probe DOES reach a neighbour created with --guest-inbound off"
      else
        bad "control failed: the probe cannot reach an unprotected neighbour either, so the pass above proves nothing"
      fi
    else
      skip "control box (--guest-inbound off) failed to create - see /tmp/hv-offline3.log"
    fi
  fi
else
  bad "second offline box failed to create - see /tmp/hv-offline2.log"
fi

# --- C. data volume startup fix (needs a microVM runtime) --------------------
hdr "C. Data volume mountpoint fix (--disk / --nested-containers)"
if [ "$HAS_KVM" != 1 ]; then
  skip "microVM tests (no /dev/kvm on this host)"
else
  if iso create hv-nest --nested-containers >/tmp/hv-nest.log 2>&1; then
    ok "nested-containers box created"
    # The attack: redirect an intermediate component of the mountpoint path.
    #
    # Staging it needs the volume unmounted first. ~/.local/share/containers is a
    # live mountpoint on a running box, so `rm -rf ~/.local/share` fails with
    # EBUSY and the && drops the symlink, which is why this section tested
    # nothing. Unmount from the administrative root shell. What is under test is
    # the entrypoint refusing the redirect at the NEXT boot, not who created the
    # symlink, and the box user reaches the same state on a box whose volume is
    # not mounted yet.
    iso root-shell hv-nest -- 'umount /home/dev/.local/share/containers 2>/dev/null; rm -rf /home/dev/.local/share && ln -s /etc /home/dev/.local/share' >/dev/null 2>&1
    # Confirm the redirect is actually in place. It was not, before the quoting
    # fix, which made everything below this a test of nothing.
    if in_box hv-nest '[ -L /home/dev/.local/share ]' >/dev/null 2>&1; then
      ok "attack set up: ~/.local/share redirected to /etc"
    else
      bad "could not set up the redirect, so the checks below prove nothing"
    fi
    iso stop hv-nest >/dev/null 2>&1
    if iso start hv-nest >/tmp/hv-nest-restart.log 2>&1; then
      ok "box still boots after the mountpoint was redirected"
      if in_box hv-nest '[ -d /etc/containers ] && mountpoint -q /etc/containers' >/dev/null 2>&1; then
        bad "the redirect SUCCEEDED - /etc/containers is a mounted volume (fix not effective)"
      else
        ok "redirect refused - nothing was mounted over /etc"
      fi
      if in_box hv-nest 'true' >/dev/null 2>&1; then
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
  in_box hv-remap '
    cd /home/dev/workspace && git init -q &&
    git config user.email box@isopod && git config user.name "Box" &&
    echo x > a && git add a && git commit -qm one' >/dev/null 2>&1
  # A commit git accepts but the old rewriter skipped: an author with no name.
  # shellcheck disable=SC2016  # $T/$P/$B must expand in the box, not here
  in_box hv-remap '
    cd /home/dev/workspace &&
    B=$(git rev-parse --abbrev-ref HEAD) &&
    T=$(git rev-parse HEAD^{tree}) && P=$(git rev-parse HEAD) &&
    C=$(printf "tree %s\nparent %s\nauthor <box@isopod> 1700000000 +0000\ncommitter <box@isopod> 1700000000 +0000\n\nnoname\n" "$T" "$P" | git hash-object --literally -t commit -w --stdin) &&
    git update-ref "refs/heads/$B" "$C"' >/dev/null 2>&1
  # Same reason as section C: without this the box has no repo and the remap
  # below would be rewriting nothing.
  if in_box hv-remap 'git -C /home/dev/workspace rev-parse HEAD' >/dev/null 2>&1; then
    ok "test repo built in the box"
  else
    bad "could not build the test repo, so the remap check below proves nothing"
  fi
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
    if in_box hv-upg 'find /home/dev/workspace -name keep.txt | grep -q .' >/dev/null 2>&1; then
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
