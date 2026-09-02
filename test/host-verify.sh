#!/usr/bin/env bash
# Host verification for the isopod 3.10.0 changes.
#
# Run this from the isopod repo on a machine with a working container engine.
# It creates throwaway boxes named hv-* and removes them at the end.
#
#   bash test/host-verify.sh              # everything the host supports
#   SKIP_LIVE=1 bash test/host-verify.sh  # skip the slow live bats suite
#   AUDIT_BOX=mybox bash test/host-verify.sh   # audit a box you already have (F)
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

# For reading a box's container log directly. isopod has no `logs` command, and
# sshd runs with -e, so its "Connection from <ip>" lines land there. That is the
# one place the source address a guest actually sees is recorded.
ENGINE_BIN="$(command -v podman || command -v docker || true)"

# Can this box open a TCP connection to <ip>:<port>?
#
# curl, not bash's /dev/tcp. That redirection is a build option a distribution
# can ship disabled, and a probe that fails because the shell lacks a feature is
# indistinguishable from one the network dropped: it reads as isolation either
# way. curl is in the box image and section B already proves it runs there.
# Exit 7 is "could not connect" and 28 is "timed out"; anything else means the
# connection was established, since sshd answers with its banner rather than
# HTTP and curl then complains about the protocol. 255 is ssh's own failure,
# which is no answer at all.
box_can_connect() { # box_can_connect <box> <ip> <port>; 0 open, 1 closed, 2 no answer
  local rc=0
  in_box "$1" "curl -sS -m 5 -o /dev/null http://$2:$3/" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    7 | 28) return 1 ;;
    255) return 2 ;;
    *) return 0 ;;
  esac
}

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
  for b in hv-offline hv-offline2 hv-offline3 hv-disk hv-nest hv-remap hv-upg hv-audit; do cleanup_box "$b"; done
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

  # Establish ONCE that the box can open a TCP connection at all, by reaching its
  # own sshd. Every "could not connect" result below is meaningless without it:
  # a broken probe refuses everything and reads as perfect isolation.
  PROBE_OK=0
  box_can_connect hv-offline 127.0.0.1 "$BOX_SSHD_PORT" && PROBE_OK=1
  if [ "$PROBE_OK" = 1 ]; then
    ok "probe works: the box can open TCP to its own sshd on $BOX_SSHD_PORT"
  else
    bad "probe does NOT work: the box cannot open TCP to its own sshd on $BOX_SSHD_PORT, so every connection check below would pass for the wrong reason"
  fi

  # Corroboration, not proof: a gateway that refuses TCP/22 looks the same as one
  # the box cannot reach. Only the connecting case is conclusive, and that case
  # is a real failure.
  GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
  if [ "$PROBE_OK" != 1 ]; then
    skip "LAN gateway probe (the probe itself does not work)"
  elif [ -n "${GW:-}" ]; then
    if box_can_connect hv-offline "$GW" 22; then
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
  elif [ "${PROBE_OK:-0}" != 1 ]; then
    # Established in section B: a box that cannot open TCP at all reads as isolated.
    skip "neighbour isolation (the box cannot reach even its own sshd, so a refusal would prove nothing)"
  elif box_can_connect hv-offline "$B_IP" "$BOX_SSHD_PORT"; then
    bad "offline box REACHED its neighbour's sshd at $B_IP:$BOX_SSHD_PORT"
    # Answer the obvious next question in the same run instead of another round
    # trip. Two things distinguish the causes:
    #
    #   no table          the entrypoint never loaded it, so the box came up
    #                     unprotected and the fail-closed path did not fire.
    #   table, but the    the rule loaded and did not match. Under passt a
    #   sshd saw the      forwarded connection is a NEW connection opened by
    #   gateway address   passt itself, so it arrives from passt's address,
    #                     which IS the gateway the rule trusts. No in-guest
    #                     saddr rule can tell the host from a neighbour then,
    #                     and the layer cannot work as designed on this runtime.
    note "the neighbour's inbound chain (nothing here means it never loaded):"
    iso root-shell hv-offline2 -- 'nft list table inet isopod_inbound' 2>&1 |
      sed 's/^/        /' | head -20
    note "source address the neighbour's sshd recorded for that probe:"
    if [ -n "$ENGINE_BIN" ]; then
      "$ENGINE_BIN" logs "$(iso info hv-offline2 2>/dev/null | awk -F': *' '/^container/{print $2; exit}')" 2>&1 |
        grep -iE 'connection from|neighbour isolation' | tail -5 | sed 's/^/        /'
    else
      printf '        (no podman or docker on PATH to read the log)\n'
    fi
  else
    ok "offline box cannot reach its neighbour's sshd at $B_IP:$BOX_SSHD_PORT"
    # Positive control. Without it, "cannot reach" could equally mean the two
    # boxes were never on the same network, and the pass above would be empty.
    # With the filter off, the identical probe must connect.
    if iso create hv-offline3 --offline --guest-inbound off ${OFF_EXTRA+"${OFF_EXTRA[@]}"} >/tmp/hv-offline3.log 2>&1; then
      C_IP="$(in_box hv-offline3 'hostname -I' 2>/dev/null | awk '{print $1}')"
      if [ -n "${C_IP:-}" ] &&
        box_can_connect hv-offline "$C_IP" "$BOX_SSHD_PORT"; then
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

# --- needs a microVM runtime --------------------
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

# upgrade rebase (never exercised against a real engine) ---------------
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

hdr "F. Box posture (what a box actually came up with)"
AUDIT_BOX="${AUDIT_BOX:-}"
if [ -n "$AUDIT_BOX" ]; then
  if iso info "$AUDIT_BOX" >/dev/null 2>&1; then
    note "auditing the existing box '$AUDIT_BOX'"
  else
    bad "AUDIT_BOX='$AUDIT_BOX' is not a box isopod knows about"
    AUDIT_BOX=""
  fi
elif iso create hv-audit >/tmp/hv-audit.log 2>&1; then
  AUDIT_BOX="hv-audit"
  ok "audit box created with today's defaults"
else
  bad "audit box failed to create - see /tmp/hv-audit.log"
fi

AUDIT_STATUS=""
[ -n "$AUDIT_BOX" ] && AUDIT_STATUS="$(in_box "$AUDIT_BOX" 'cat /proc/self/status' 2>/dev/null)"
if [ -z "$AUDIT_BOX" ]; then
  : # already reported above
elif ! printf '%s\n' "$AUDIT_STATUS" | grep -q '^CapBnd:'; then
  skip "box posture (cannot read /proc/self/status in '$AUDIT_BOX', so nothing below would mean anything)"
else
  AUDIT_INFO="$(iso info "$AUDIT_BOX" 2>/dev/null)"
  ainfo() { printf '%s\n' "$AUDIT_INFO" | awk -F': *' -v k="^$1" '$0 ~ k {print $2; exit}'; }
  A_TIER="$(ainfo isolation)"
  A_SUDO="$(ainfo sudo)"
  note "runtime:   ${A_TIER:-unknown}"
  note "built:     $(ainfo built)"
  note "neighbors: $(ainfo neighbors)"
  note "sudo:      ${A_SUDO:-unknown}"

  # Crun's krun handler writes the container's OCI config into the rootfs,
  # which on a microVM box IS the guest filesystem, readable by every process in
  # it. The entrypoint removes it on every start. Listed together with a file
  # that must exist, so "not there" cannot come from `ls` failing to run.
  A_LS="$(in_box "$AUDIT_BOX" 'ls -d /.krun_config.json /etc/isopod-user' 2>/dev/null)"
  if ! printf '%s\n' "$A_LS" | grep -q '/etc/isopod-user'; then
    skip "/.krun_config.json (the control file did not list, so an absence proves nothing)"
  elif printf '%s\n' "$A_LS" | grep -q '/\.krun_config\.json'; then
    bad "/.krun_config.json is readable in the box: host username, home layout and UID leak to every process in it"
  else
    ok "/.krun_config.json absent"
  fi

  # A search domain hands the box the host's internal naming, which is both a
  # disclosure and a way for an unqualified name to resolve somewhere internal.
  A_RESOLV="$(in_box "$AUDIT_BOX" 'cat /etc/resolv.conf' 2>/dev/null)"
  if [ -z "$A_RESOLV" ]; then
    skip "resolv.conf (empty read)"
  elif printf '%s\n' "$A_RESOLV" | grep -qiE '^[[:space:]]*search[[:space:]]'; then
    bad "resolv.conf carries a search domain, so the host's internal naming reached the box"
    printf '%s\n' "$A_RESOLV" | sed 's/^/        /'
  else
    ok "resolv.conf has no search domain"
    note "resolvers the box was handed: $(printf '%s\n' "$A_RESOLV" | awk '/^nameserver/{printf "%s ", $2}')"
  fi

  # No-new-privileges is set at run time, and only for a box with no sudo
  # policy. On a --sudo box its absence is the documented design, not a finding.
  A_NNP="$(printf '%s\n' "$AUDIT_STATUS" | awk '/^NoNewPrivs:/{print $2; exit}')"
  case "$A_SUDO" in
    no*)
      if [ "$A_NNP" = 1 ]; then
        ok "no-sudo box has NoNewPrivs=1"
      else
        bad "box declares no sudo but NoNewPrivs=$A_NNP, so the setuid gate is not on"
      fi
      ;;
    *) note "NoNewPrivs=$A_NNP (expected on a sudo box: isopod sets the gate only where sudo is off)" ;;
  esac
  note "Seccomp=$(printf '%s\n' "$AUDIT_STATUS" | awk '/^Seccomp:/{print $2; exit}') CapBnd=$(printf '%s\n' "$AUDIT_STATUS" | awk '/^CapBnd:/{print $2; exit}')  (isopod installs no in-guest seccomp filter; the VM is the boundary)"

  # The policy isopod reports and the policy the box is actually running.
  # These drift on an old box: the entrypoint applies whatever meta says, and
  # meta defaults to sudo=1 for boxes created before the key existed.
  A_USER="$(in_box "$AUDIT_BOX" 'cat /etc/isopod-user' 2>/dev/null | tr -d '\r\n ')"
  A_SUDOERS="$(in_box "$AUDIT_BOX" 'ls -a /etc/sudoers.d' 2>/dev/null)"
  A_SUDOBIN="$(in_box "$AUDIT_BOX" 'ls -l /usr/bin/sudo' 2>/dev/null)"
  case "$A_SUDO" in
    no*) A_WANT=0 ;;
    *) A_WANT=1 ;;
  esac
  if ! printf '%s\n' "$A_SUDOERS" | grep -qx '\.'; then
    skip "sudo policy (/etc/sudoers.d did not list, so an empty result proves nothing)"
  else
    A_HAS=0
    [ -n "$A_USER" ] && printf '%s\n' "$A_SUDOERS" | grep -qx "$A_USER" && A_HAS=1
    if [ "$A_HAS" = "$A_WANT" ]; then
      ok "in-box sudo policy matches what isopod reports (sudoers entry $([ "$A_HAS" = 1 ] && printf present || printf absent))"
    else
      bad "isopod reports sudo='$A_SUDO' but /etc/sudoers.d/$A_USER is $([ "$A_HAS" = 1 ] && printf present || printf absent)"
    fi
    # A no-sudo box that kept a setuid-root sudo is standing escalation surface:
    # a sudo LPE would be root-in-box, the exact path --no-sudo removes.
    A_MODE="$(printf '%s\n' "$A_SUDOBIN" | awk 'NR==1{print $1}')"
    A_SETUID=0
    case "$A_MODE" in ???[sS]*) A_SETUID=1 ;; esac
    if [ -z "$A_MODE" ]; then
      note "no /usr/bin/sudo in this image, so there is no setuid bit to keep in step"
    elif [ "$A_SETUID" = "$A_WANT" ]; then
      ok "sudo's setuid bit is in step with the policy ($A_MODE)"
    else
      bad "sudo is $A_MODE but the policy is $([ "$A_WANT" = 1 ] && printf sudo || printf no-sudo): standing escalation surface"
    fi
  fi

  # Isopod's own files in the box.
  A_ETC="$(in_box "$AUDIT_BOX" 'ls -a /etc/isopod' 2>/dev/null)"
  if ! printf '%s\n' "$A_ETC" | grep -qx '\.'; then
    bad "/etc/isopod does not list at all, so this box predates isopod's in-box files entirely"
  else
    for f in hardening-sysctl.conf egress-guest.nft; do
      if printf '%s\n' "$A_ETC" | grep -qx "$f"; then
        ok "/etc/isopod/$f present"
      else
        bad "/etc/isopod/$f missing (image predates it - run: isopod upgrade $AUDIT_BOX)"
      fi
    done
  fi

  # Read the keys out of the profile rather than copying them here, so this 
  #cannot drift from it.  microVM only: a container shares the host kernel 
  # and is never asked to.
  HCONF=share/hardening-sysctl.conf
  case "${A_TIER:-}" in
    microVM*)
      if [ ! -f "$HCONF" ]; then
        skip "hardening profile (no $HCONF here)"
      else
        A_PATHS=""
        while IFS='=' read -r hk _; do
          case "$hk" in '' | \#*) continue ;; esac
          A_PATHS="$A_PATHS /proc/sys/$(printf '%s' "$hk" | tr . /)"
        done <"$HCONF"
        A_GOT="$(in_box "$AUDIT_BOX" "grep -H . $A_PATHS 2>/dev/null" 2>/dev/null)"
        A_MISS=""
        while IFS='=' read -r hk hv; do
          case "$hk" in '' | \#*) continue ;; esac
          hp="/proc/sys/$(printf '%s' "$hk" | tr . /)"
          got="$(printf '%s\n' "$A_GOT" | awk -F: -v k="$hp" '$1==k{print $2; exit}')"
          if [ -z "$got" ]; then
            A_MISS="$A_MISS $hk(not exposed)"
          elif [ "$got" != "$hv" ]; then
            A_MISS="$A_MISS $hk=$got(want $hv)"
          fi
        done <"$HCONF"
        if [ -z "$A_MISS" ]; then
          ok "every key in $HCONF is applied in the box"
        else
          bad "hardening profile not fully applied:$A_MISS"
        fi
      fi
      ;;
    *) note "hardening sysctls are microVM-only and this box is ${A_TIER:-unknown}, so the profile is not expected here" ;;
  esac

  A_PROP="$(in_box "$AUDIT_BOX" 'grep -H . /proc/sys/kernel/unprivileged_bpf_disabled /proc/sys/kernel/yama/ptrace_scope /proc/sys/vm/unprivileged_userfaultfd /proc/sys/user/max_user_namespaces 2>/dev/null' 2>/dev/null)"
  note "sysctls the 2026-09-01 review proposed adding, as this box has them now:"
  for k in kernel/unprivileged_bpf_disabled kernel/yama/ptrace_scope vm/unprivileged_userfaultfd user/max_user_namespaces; do
    v="$(printf '%s\n' "$A_PROP" | awk -F: -v p="/proc/sys/$k" '$1==p{print $2; exit}')"
    if [ -z "$v" ]; then
      printf '        %-38s absent or unreadable (adding it would change nothing here)\n' "$k"
    else
      printf '        %-38s %s\n' "$k" "$v"
    fi
  done
fi

# --- summary -----------------------------------------------------------------
hdr "Summary"
printf '  passed: %d   failed: %d   skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
for n in ${NOTES+"${NOTES[@]}"}; do printf '  %s\n' "$n"; done
[ "$FAIL" -eq 0 ] || printf '\n  Send back the named log files for anything that failed.\n'
[ "$FAIL" -eq 0 ]
