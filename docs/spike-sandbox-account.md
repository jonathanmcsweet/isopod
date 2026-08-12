# Spike: host-enforced egress without a root-run engine

**Time:** ~20 minutes, in three parts that can stop early. **Run on:** the host, not in a box.
**Destructive:** no — creates one system account and one throwaway container, both removed by
the cleanup section.

## Why

Host-enforced egress is the only boundary that survives guest root, because the rules live
outside the box. isopod currently requires a **rootful** engine for it (`egress_can_enforce`
tests `Rootless == false`), because the existing design filters a host bridge and only a
rootful engine can create one.

Rootful was declined (see `docs/spike-userns-auto.md`): the engine parses complex, partly
untrusted input, and under rootful an exploitable bug there runs as root.

This spike tests a different shape of the same goal. Run boxes under a **dedicated
unprivileged account** that owns nothing, and key the host firewall on that account rather
than on an interface:

```
traffic from uid(sandbox) to private address space -> drop
```

If that works it gives both things the rootful design promised, without a root-run engine:

- the rule is in the host kernel, so nothing inside the box can remove it — and it still
  applies to an attacker who escaped the box, because that process is still `sandbox`
- an engine exploit lands in an account that owns nothing, instead of on the user's account
- root is used **once**, to load a static rule, and is not running afterwards

What it does not give: per-box granularity. Every box shares the account, so every box gets
the same rule. For a single-box deployment that costs nothing.

## The order matters

Step 1 is the one most likely to fail, and it needs no isopod changes and no firewall rules.
If it fails, the design is dead and the rest is wasted effort. Do not reorder.

## Step 0 — create the account

```sh
sudo useradd --system --create-home --shell /bin/bash sandbox
sudo usermod --add-subuids 300000-365535 --add-subgids 300000-365535 sandbox
sudo loginctl enable-linger sandbox
grep '^sandbox:' /etc/subuid /etc/subgid
```

- `--create-home` is required: rootless podman keeps its image store under the account's home.
- The subuid range is what makes rootless podman work *as that account*; it is separate from
  the range your own user already has.
- `enable-linger` keeps a systemd user manager running for the account, which is what creates
  `/run/user/<uid>`. Rootless podman needs that directory and `sudo -u` does not create one.
- A real shell is used rather than `nologin` because some `sudo` configurations route through
  it. The account has no password, so it still cannot be logged into.

On an immutable/ostree Fedora this works: only `/usr` is read-only, and `/etc` is a writable
overlay whose changes persist across upgrades.

## Step 1 — does rootless podman run as a non-login system account?

The load-bearing question. Rootless podman wants a user session, and this account never logs in.

```sh
SBUID=$(id -u sandbox)
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman info --format '{{.Host.Security.Rootless}}'
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman run --rm \
  docker.io/library/debian:bookworm-slim echo BOOTED
```

- **`true` then `BOOTED`** → proceed to step 2.
- **Fails** → note the error. A missing `/run/user/<uid>` means linger did not take; a subuid
  complaint means step 0's range did not land. Anything structural ends the spike here, and
  the remaining options are the router's guest network, a separate machine, or accepting the
  current posture.

## Step 2 — does an nft rule keyed on the account actually match the box's traffic?

isopod runs krun boxes with passt, a userspace network stack: it terminates the guest's
traffic and re-originates it as ordinary socket traffic from the passt process. So the packets
should carry that process's uid in the `output` hook. Should — that is what this measures.

The probe runs as the container's own command, not through `podman exec`: the engine cannot
exec into a microVM guest, which is the same limitation that makes `isopod install` fall back
to SSH on microVM boxes.

Every `sudo -u sandbox` runs from a directory the account can enter. It inherits the caller's
working directory, and a project directory under another user's home fails with
`cannot chdir ...: Permission denied` before podman starts.

Establish the baseline — pick a private address that actually answers on this network
(`169.254.1.1:53` on the host this was written for; substitute a resolver of your own):

```sh
cd /tmp
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman run --rm \
  --runtime krun --annotation krun.use_passt=1 docker.io/library/debian:bookworm-slim \
  bash -c 'timeout 3 bash -c "echo > /dev/tcp/169.254.1.1/53" && echo REACHES || echo blocked'
```

Expect `REACHES`. Now load the rule and repeat the identical command:

```sh
sudo nft add table inet isopodskuid
sudo nft add chain inet isopodskuid out '{ type filter hook output priority 0; policy accept; }'
sudo nft add rule inet isopodskuid out meta skuid "$SBUID" ip daddr 169.254.1.1 counter drop

sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman run --rm \
  --runtime krun --annotation krun.use_passt=1 docker.io/library/debian:bookworm-slim \
  bash -c 'timeout 3 bash -c "echo > /dev/tcp/169.254.1.1/53" && echo REACHES || echo blocked'
sudo nft list table inet isopodskuid | grep counter
```

**The counter is the answer.** `blocked` with a non-zero counter means host rules see the box's
traffic and can filter it by account — the design works. `REACHES` with a zero counter means
the packets do not carry that uid at the output hook and this approach fails like the
interface-based one did.

Control test — the rule must not touch your own traffic:

```sh
timeout 3 bash -c 'echo > /dev/tcp/169.254.1.1/53' && echo "admin still REACHES (correct)" || echo "admin blocked — rule is too broad"
```

## Step 3 — can you still reach a box the account published?

The whole IDE flow depends on connecting to a loopback port published by someone else's podman.

```sh
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman rm -f skuidtest
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman run -d --name skuidtest \
  -p 127.0.0.1:48222:80 docker.io/library/debian:bookworm-slim \
  sh -c 'while true; do printf "HTTP/1.0 200 OK\r\n\r\nhi\r\n" | timeout 5 nc -l -p 80 || sleep 1; done' \
  2>/dev/null || echo "(skip if the image has no nc — publish check can use any listener)"
curl -s --max-time 3 http://127.0.0.1:48222/ && echo "reachable from admin (correct)"
```

A published loopback port is owned by the kernel, not the account, so this is expected to
work. It is here because the design is worthless if it does not.

## Cleanup

```sh
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$(id -u sandbox) podman rm -f skuidtest
sudo nft delete table inet isopodskuid
```

If abandoning the design entirely, also:

```sh
sudo loginctl disable-linger sandbox
sudo userdel -r sandbox
```

Leaving the account in place is harmless — it owns nothing and cannot be logged into.

## Result (2026-08-12, immutable Fedora + rootless podman + krun)

| Step | Question | Result |
|---|---|---|
| 1 | rootless podman runs as the account? | **PASS** — `Rootless: true`, container ran |
| 2 | **nft `meta skuid` matches the box's traffic?** | **PASS** — `blocked`, `counter packets 5 bytes 300` |
| 2c | the rule leaves your own traffic alone? | **PASS** — the invoking user still reached the address |
| 3 | published loopback port reachable from your account? | **PASS** — served over `127.0.0.1` to the invoking user |

**Verdict: the mechanism works.** Host-enforced egress is achievable with a rootless engine,
keyed on a dedicated account. What remains unproven is the isopod side, not the OS side.

Two things cost a round each and are worth knowing in advance:

**`enable-linger` writes its marker but does not necessarily start the user manager**, so
`/run/user/<uid>` was missing immediately afterwards. `sudo systemctl start user@<uid>.service`
created it. After a reboot linger starts it automatically; it is only the first run that needs
the nudge.

**Do not test against `169.254.1.1` (or any passt-internal address).** The first attempt used
the resolver the box inherits, which from inside a box answers but from the host is refused —
because that address *is* passt, not a host-network address. The connection never became host
traffic, so the counter stayed at zero and the run proved nothing. A `drop` rule also produces
a timeout, never `Connection refused`, so a refusal is always a sign the target is wrong rather
than the rule working. Use an address known to traverse the host network (`1.1.1.1:443` here).

That same fact explains the guest-egress DNS outage fixed in 3.1.4: boxes resolve through
passt's forwarder at `169.254.1.1`, and the in-guest ruleset dropped `169.254.0.0/16` — cutting
the box's own DNS service rather than a LAN host.

## What each outcome means for isopod

**All pass** (this is what happened). What building it involves:

- **Route engine invocations through the account, keep everything else where it is.** Host-side
  state — box keys, the `ssh_config` include, `known_hosts` — must stay in the invoking user's
  home. Run isopod wholesale as the account and it all lands in `/home/sandbox` at mode 700,
  where the user's own SSH and editor cannot read the box key, and `isopod code` breaks. Only
  the `$ENGINE` invocation needs to change identity; the box's traffic then originates from the
  account because that is who runs passt.
- **Set a working directory explicitly for those calls.** `sudo -u` inherits the caller's
  directory, which is normally a project directory under the user's home that the account
  cannot enter — every engine call would fail with `cannot chdir ...: Permission denied` before
  podman starts.
- **A sudoers rule** allowing the user to run the engine as the account without a password,
  scoped to the engine binary.
- **`doctor` checks**: account exists, subuid/subgid ranges present, runtime directory present
  (linger enabled), firewall rule loaded.
- **Rule persistence.** `nft add` does not survive a reboot. The rules need an nftables config
  file or a systemd unit, and `egress_start_check` should verify they are still loaded — the
  same failure mode the existing host-egress path already guards against.
- **`egress_can_enforce` gains a branch** that no longer implies a rootful engine.

Scope limit worth deciding up front: this gives **`lan-deny`** cleanly. **`allow-list`** — the
default-deny mode where a filtering proxy is the box's only route out — needs the box's traffic
redirected to that proxy, which is a further design on top of this rather than a consequence of
it.

Platform: Linux only. It depends on subuid ranges, systemd linger, and nftables. The macOS
paths (Apple `container`, podman machine) are unaffected and keep their existing behaviour.

**Step 1 fails.** The design is not available on this host. Remaining options are the router's
guest network, a separate machine, or the current posture (VPN lockdown plus the in-guest
ruleset, which is field-verified).

**Step 2 fails.** Host-side filtering cannot see krun+passt traffic by any means tested so far
— neither by interface nor by uid. Record it here and stop reopening the question.
