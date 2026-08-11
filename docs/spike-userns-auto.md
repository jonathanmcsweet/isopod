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
```

If it returns nothing, add the range. podman reads these files directly, so the account
exists only to satisfy `usermod`:

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin containers 2>/dev/null || true
sudo usermod --add-subuids 200000-2147483647 --add-subgids 200000-2147483647 containers
```

On an immutable/ostree Fedora this still works: only `/usr` is read-only, and `/etc` is a
writable overlay whose changes persist across upgrades.

## Read this before step 3

Steps 3 and 4 assume the box's traffic crosses a host bridge that nftables can filter.
For **krun + passt that assumption is probably false, independent of `--userns=auto`**.

passt is a userspace network stack. It does not attach the guest to a bridge — it terminates
the guest's traffic and re-originates it as ordinary socket traffic from the passt process on
the host. That is why a krun box holds the host's own LAN identity and why the host appears at
the gateway address: passt is translating, not bridging.

A rule matching `iifname "isopodspike"` in a `forward` chain therefore has nothing to match.
Expect a zero counter. That is a prediction from architecture, not a measurement — run step 4
anyway, because a zero there is still the answer to the question as originally posed.

**Step 4b below is the test more likely to pass**, and it changes what step 2 is for: the VMM's
uid stops being a sanity check and becomes the thing enforcement hangs on.

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

## Step 4b — the test that sidesteps the bridge entirely

If step 4 gives zero, the traffic is host-local output from the passt process, not forwarded
through a bridge. That is filterable — just not by interface. `--userns=auto` gives each
container its own uid range, so the VMM runs as a uid nothing else on the system uses, and
nftables can match it in the `output` chain.

Take the uid from step 2, then:

```sh
VMMUID=<the uid step 2 printed>
sudo nft add table inet isopodspike2
sudo nft add chain inet isopodspike2 out '{ type filter hook output priority 0; policy accept; }'
sudo nft add rule inet isopodspike2 out meta skuid "$VMMUID" ip daddr 192.168.0.0/16 counter drop

sudo podman exec usernstest sh -c 'timeout 3 getent hosts 192.168.1.1 || echo BLOCKED-OR-UNREACHABLE'
sudo nft list table inet isopodspike2 | grep counter
```

Cleanup: `sudo nft delete table inet isopodspike2`

Non-zero here is the better result than a non-zero step 4 would have been: enforcement lives in
the host kernel keyed on a uid the box cannot change, so it survives guest root **and** does not
depend on the runtime using a bridge. It would work for krun boxes specifically, which is the
configuration this host actually runs.

Under **rootless** podman this cannot work — passt runs as your own uid, indistinguishable from
every other program you run. The per-container uid is the whole reason `--userns=auto` matters
here.

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
| 4 | host nft counter increments (by interface)? | |
| 4b | **host nft counter increments (by uid)?** | |

If steps 1 and 2 pass and **either** 4 or 4b passes, `egress_can_enforce` should gain a branch
for rootful + `--userns=auto`, and that becomes the recommended posture for agent boxes — the
in-guest ruleset stays as defence beneath it. A pass on 4b means the rule is keyed on the VMM's
uid rather than an interface, which is a different shape of enforcement and needs isopod to
record the box's uid range at create time.

If 1 or 2 fails, the configuration is not worth having: without an unprivileged VMM you are
taking rootful's risk without its mitigation.

If both 4 and 4b fail, host-side filtering is off the table for krun boxes and the realistic
choices are: keep the in-guest ruleset, switch agent boxes to a non-passt runtime, or accept
the network posture deliberately. Record that here so the question stays closed.
