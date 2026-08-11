# Spike: can `--userns=auto` give a hard egress boundary without rootful containers?

**Time:** ~20 minutes. **Run on:** the host, not in a box. **Destructive:** no — creates
and removes one throwaway box.

## Why

Host-enforced egress (`isopod egress lan-deny`) is the only boundary that survives guest
root, because the rules live outside the VM. It currently requires **rootful podman**
(`egress_can_enforce` tests `Rootless == false`), because rootless podman has no host
bridge to write nftables rules against.

The objection to rootful is real: a full escape chain (guest kernel → libkrun/virtio-fs/
passt) lands as uid 0 instead of uid 1000.

`podman --userns=auto` may resolve both. Under rootful podman it allocates a unique subuid
range per container and maps container-root to an unprivileged host uid. If it composes
with krun, you would get:

- a real bridge in the host netns → **egress is enforceable**
- the VMM running as a per-container unprivileged uid → **an escape lands on a uid that
  owns nothing else on the system**, which is arguably better than rootless, where it lands
  as your uid with all your data

The open question is whether libkrun tolerates being run inside a mapped user namespace.

## Prerequisites

```sh
grep -E '^containers:' /etc/subuid /etc/subgid   # --userns=auto needs this range
# if missing:  sudo usermod --add-subuids 200000-2147483647 --add-subgids 200000-2147483647 containers
```

## Step 1 — does krun start at all under `--userns=auto`?

```sh
sudo podman run --rm --runtime krun --annotation krun.use_passt=1 \
  --userns=auto docker.io/library/debian:bookworm-slim \
  sh -c 'echo BOOTED; id; cat /proc/self/uid_map'
```

- **Prints `BOOTED`** → proceed to step 2.
- **Fails** → note the error. Most likely causes are libkrun needing `/dev/kvm` access the
  mapped uid does not have, or crun refusing the combination. If it is a `/dev/kvm`
  permission problem, retry with the `kvm` group applied to the mapped range; if it is
  structural, the spike ends here and the choice is plain rootful vs. option C.

## Step 2 — what uid does the VMM actually run as on the host?

This is the whole point: confirm the host-side process is not uid 0.

```sh
sudo podman run -d --name usernstest --runtime krun --annotation krun.use_passt=1 \
  --userns=auto docker.io/library/debian:bookworm-slim sleep 300
ps -o pid,user,uid,args -C crun-krun 2>/dev/null || \
  ps -eo pid,user,uid,args | grep -E 'krun|libkrun' | grep -v grep
```

Expect a high, unprivileged uid (200000+). **If it shows `root`/uid 0, the spike has
failed its purpose** — you would be taking rootful's risk without its mitigation.

## Step 3 — is the box on a real bridge that nftables can target?

```sh
sudo podman network create isopod-spike --subnet 10.88.9.0/24 --interface-name isopodspike
sudo podman rm -f usernstest
sudo podman run -d --name usernstest --runtime krun --annotation krun.use_passt=1 \
  --userns=auto --network isopod-spike docker.io/library/debian:bookworm-slim sleep 300
ip -br addr show isopodspike        # the interface must exist on the HOST
```

Note: krun + passt may bypass the bridge even when one is configured, since passt is a
userspace stack. If `ip -br addr show isopodspike` shows the interface but box traffic does
not traverse it, host nftables cannot filter it and this whole approach fails — **that is
the single most likely way this spike returns "no"**, so do not skip step 4.

## Step 4 — the actual test: does a host nft rule stop the box?

```sh
sudo nft add table inet isopodspike
sudo nft add chain inet isopodspike fwd '{ type filter hook forward priority 0; policy accept; }'
sudo nft add rule inet isopodspike fwd iifname "isopodspike" ip daddr 192.168.0.0/16 counter drop

sudo podman exec usernstest sh -c 'apt-get update -qq >/dev/null 2>&1; \
  timeout 3 getent hosts 192.168.1.1 || echo BLOCKED-OR-UNREACHABLE'
sudo nft list table inet isopodspike | grep counter
```

**The counter is the answer.** Non-zero packets → host rules see box traffic → you have a
hard boundary with an unprivileged VMM, and `egress_can_enforce` should be relaxed to
accept this configuration. Zero packets → passt is bypassing the bridge and host-side
filtering cannot work for krun boxes regardless of rootful/rootless.

## Cleanup

```sh
sudo podman rm -f usernstest
sudo podman network rm isopod-spike
sudo nft delete table inet isopodspike
```

## Recording the result

| Step | Question | Result |
|---|---|---|
| 1 | krun boots under `--userns=auto`? | |
| 2 | VMM host uid is unprivileged? | |
| 3 | bridge interface exists on host? | |
| 4 | **host nft counter increments?** | |

If steps 1, 2 and 4 all pass, `egress_can_enforce` should gain a branch for rootful +
`--userns=auto`, and that becomes the recommended posture for agent boxes — option C stays
as defence in depth beneath it.

If step 4 fails, host-side filtering is off the table for krun boxes and the realistic
choices are: keep option C, switch agent boxes to a non-passt runtime, or accept the
network posture deliberately.
