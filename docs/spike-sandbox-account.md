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

Start a box-shaped container under the account:

```sh
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman run -d --name skuidtest \
  --runtime krun --annotation krun.use_passt=1 \
  docker.io/library/debian:bookworm-slim sleep 300
```

Establish the baseline — pick a private address that actually answers on this network
(`169.254.1.1:53` on the host this was written for; substitute a resolver of your own):

```sh
sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman exec skuidtest \
  bash -c 'timeout 3 bash -c "echo > /dev/tcp/169.254.1.1/53" && echo REACHES || echo blocked'
```

Expect `REACHES`. Now load the rule and repeat:

```sh
sudo nft add table inet isopodskuid
sudo nft add chain inet isopodskuid out '{ type filter hook output priority 0; policy accept; }'
sudo nft add rule inet isopodskuid out meta skuid "$SBUID" ip daddr 169.254.1.1 counter drop

sudo -u sandbox XDG_RUNTIME_DIR=/run/user/$SBUID podman exec skuidtest \
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

## Recording the result

| Step | Question | Result |
|---|---|---|
| 1 | rootless podman runs as the account? | |
| 2 | **nft `meta skuid` matches the box's traffic?** | |
| 2c | the rule leaves your own traffic alone? | |
| 3 | published loopback port reachable from your account? | |

## What each outcome means for isopod

**All pass.** Worth building. isopod would need to route engine invocations through the
account while keeping host-side state (box keys, `ssh_config` include, known_hosts) in the
invoking user's home — otherwise everything lands in `/home/sandbox` at mode 700 and
`isopod code` cannot read the box key. Every `$ENGINE` call site is affected, plus a sudoers
rule and a `doctor` check for the account and its subuid range. `egress_can_enforce` gains a
branch that no longer implies a rootful engine.

**Step 1 fails.** The design is not available on this host. Remaining options are the router's
guest network, a separate machine, or the current posture (VPN lockdown plus the in-guest
ruleset, which is field-verified).

**Step 2 fails.** Host-side filtering cannot see krun+passt traffic by any means tested so far
— neither by interface nor by uid. Record it here and stop reopening the question.
