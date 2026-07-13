# Security Features and Defaults

As of v2.0.0 the two strongest features are **on by default**: `isopod create`
runs the box in a **microVM** (its own guest kernel) when a microVM runtime and
`/dev/kvm` are available, and network egress uses the **allow-list**. When a
default can't be honored, isopod degrades with a warning rather than failing —
the runtime falls back microVM → gVisor → plain container, and egress falls back
allow-list → lan-deny → open. Force a plain container with `isopod create
--container`; turn egress off with `ISOPOD_EGRESS=off` or a `no-egress` directive.

The runtimes below still need host-side setup (installing/registering the runtime
with your engine). They complement the always-on
[fingerprint hardening](../README.md#fingerprint-hardening) and
[isolation model](../README.md#the-isolation-model) described in the README.

## gVisor (`runsc`) syscall-virtualizing runtime

Isopod can run containers under a syscall-virtualizing runtime — **gVisor
(`runsc`)** — which presents a synthetic `/proc`, `/sys`, `uname`, and CPU to the
container instead of the host's. It's off by default because it requires host-side
setup. Enable it per-container with `ISOPOD_RUNTIME=runsc isopod create …`, or
persistently by adding `runtime runsc` to your override file at
`~/.config/isopod/hardening.conf` (don't edit the shipped baseline — upgrades
replace it).

**What you must do on the host to use these features**:

- **Podman:** install gVisor's `runsc`, then register it under `[engine.runtimes]` in `containers.conf` (e.g. `runsc = ["/usr/local/bin/runsc"]`).
- **Docker:** add it to `/etc/docker/daemon.json` (`"runtimes": {"runsc": {"path": "/usr/local/bin/runsc"}}`) and restart the daemon.
- `isopod doctor` warns if a configured runtime isn't found on the host.

Caveats: gVisor is Linux-only (under `podman machine` / Docker Desktop on macOS it runs inside that VM); some syscall-heavy or low-level workloads run slower or are unsupported under it.

gVisor hides the **CPU identity**, **kernel build string**, and **host boot
epoch / boot id** that a plain shared-kernel container otherwise leaks (see
[What still can't be mitigated](../README.md#what-still-cant-be-mitigated)). Only a
true VM boundary closes the timing channels too.

## microVM runtimes (Kata, krun) — Tier 3

For the strongest boundary, isopod can run each box in a **microVM** — a
lightweight VM with its own guest kernel and a hardware (KVM) boundary to the
host. This is the answer to "containers share the host kernel": a kernel exploit
or container escape is contained by the VM. Enable it through the **same**
`runtime` directive as gVisor — isopod treats any runtime as a drop-in:

- **Kata Containers** (pluggable Firecracker / Cloud Hypervisor / QEMU backend):
  `ISOPOD_RUNTIME=kata isopod create …` — the supported Tier 3 microVM; the default
  when installed, and it works with VSCodium Remote-SSH (`isopod code`).
- **krun** (libkrun, Podman-native): `ISOPOD_RUNTIME=krun isopod create …` — the
  lightest microVM, but its TSI networking breaks `isopod code` (see below), so it
  is never auto-selected and is only for `isopod shell`/copy/export.

> **crun-vm is not usable with isopod.** It boots VM disk images (a containerdisk,
> a `--rootfs` disk image, or a bootc container), not the plain OCI container image
> isopod builds — so it cannot start an isopod box.

Because isopod brings a box up entirely over SSH (no `engine exec`/`cp`), every
operation — clone, copy-in, export, fetch, remap, shell — enters the guest
correctly under a microVM. (`engine exec` does **not** enter a krun guest, which
is exactly why isopod never uses it.)

isopod fails closed on the runtime: if you configure a Tier 2/3 runtime that is
not registered with your engine or on `PATH`, `isopod create` stops with a clear
error before starting instead of silently running the box without the isolation
you asked for.

### What you must do on the host

Both engines need **`/dev/kvm`** (bare metal or a KVM-enabled VM; nested virt is
often off in cloud CI) and a microVM runtime **registered under the name you
pass to `ISOPOD_RUNTIME`**. `isopod doctor` reports `/dev/kvm`, whether the
configured runtime is found, and — when no runtime is set — **auto-detects which
sandboxed runtimes (kata, krun, runsc) are already available to enable**,
so you can see your options at a glance. Package names and binary paths vary by
distro — doctor is the check that it's wired up.

**Podman + krun** (lightest microVM — krun is a [crun](https://github.com/containers/crun)
handler backed by [libkrun](https://github.com/containers/libkrun), so it's
Podman-native):

> **⚠ krun breaks `isopod code`.** libkrun's TSI networking stalls bulk data over
> the SSH port-forward the IDE's remote server needs (upstream bugs
> [libkrun#579](https://github.com/libkrun/libkrun/issues/579) and
> [#510](https://github.com/libkrun/libkrun/issues/510)), so VSCodium/Cursor/
> JetBrains fail to connect (WebSocket 1006). isopod never auto-selects krun; use
> it only for `isopod shell`/copy/export, or use **Kata** for the IDE.

Fedora example (more distros to come):
```sh
sudo dnf install -y crun-krun        # Fedora (recent releases, or the slp Copr)
sudo usermod -aG kvm "$USER"          # rootless access to /dev/kvm (re-login after)

mkdir -p ~/.config/containers         # register a runtime named "krun"
cat >> ~/.config/containers/containers.conf <<'EOF'
[engine.runtimes]
krun = ["/usr/bin/crun-krun"]
EOF
```

Then `ISOPOD_RUNTIME=krun isopod create …`.

**Podman or Docker + Kata Containers** (boots a microVM via Firecracker / Cloud
Hypervisor / QEMU; works with either engine). Install Kata (distro package or the
project's `kata-deploy`), then register it under the name `kata`:

- **Podman** — in `~/.config/containers/containers.conf` (or `/etc/containers/…`):
  ```ini
  [engine.runtimes]
  kata = ["/usr/bin/kata-runtime"]
  ```
- **Docker** — in `/etc/docker/daemon.json`, then `sudo systemctl restart docker`:
  ```json
  { "runtimes": { "kata": { "path": "/usr/bin/kata-runtime" } } }
  ```

Then `ISOPOD_RUNTIME=kata isopod create …`. **Docker's microVM path is Kata** —
krun is a crun/Podman handler, so with Docker use Kata (or switch to Podman for
krun).

When a Tier 3 runtime is active and you pass no `--memory`, isopod sizes the
guest with a default (2g; override with `--memory` or `ISOPOD_MICROVM_MEMORY`),
since a microVM boots a fixed-size guest. The Tier 1 fingerprint masks become
largely redundant under a microVM — the guest has its own `/proc` and `/sys`, so
they are left on but cost nothing.

### Tuning the guest (krun annotations)

libkrun reads `krun.*` OCI annotations to tune the guest. Pass them with
`ISOPOD_MICROVM_ANNOTATIONS` (a space-separated `key=value` list); isopod adds
each as a `--annotation` when a microVM runtime is active. This is **Podman-only**
— annotations are a crun/krun feature, and `docker run` has no `--annotation`.

```sh
# allow nested virtualization inside the box (e.g. to run KVM workloads in-guest)
ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=krun isopod create dev
```

> A microVM adds a **kernel** boundary, not a **network** one. A box under Kata or
> krun still reaches your LAN the same way — pair it with egress isolation below to
> stop network reconnaissance.

### macOS: the engine VM is already the boundary

macOS has no `/dev/kvm`. The equivalent capability — hardware virtualization — is
Apple's Hypervisor.framework, and there is no device node for it; `isopod
doctor` probes it with `sysctl kern.hv_support` (1 = available). More importantly,
on macOS every box already runs inside the `podman machine` / Docker Desktop
Linux VM, which is itself a hardware VM built on Hypervisor.framework. That VM
boundary is the Tier-3-class isolation on a Mac — a kernel exploit or container
escape inside a box lands in the engine VM, not on macOS. So a plain container on
macOS is already VM-isolated from your machine in a way it is not on Linux.

If you want a per-box hardware boundary (each box its own VM, not just one shared
engine VM), there are a few routes on macOS, and `isopod doctor` reports which your
Mac can use:

1. **Apple `container` — a native per-box VM (recommended; any Apple Silicon).**
   Apple's [`container`](https://github.com/apple/container) It is a macOS-native engine
   (not a Linux port), and each box gets a routable per-box vmnet subnet the host pf
   egress backend already scopes to, so a box that escapes its VM still can't flush the
   firewall without root on your Mac. This is the intended "Tier 3 for macOS."

3. **Nested `krun`/`kata` inside the engine VM (needs Apple M3+/macOS 15).** Apple
   exposes nested virtualization only on M3 or later chips running macOS
   15+. Doctor tells you when your chip/OS qualifies and marks it experimental. On other
   Macs the engine VM stays the boundary.

5. **krunvm (fallback).** [krunvm](https://github.com/containers/krunvm) also boots an
   OCI image as its own microVM on Hypervisor.framework, but it is Linux-oriented and
   not well tested on macOS, so it is a fallback rather than the recommended path.
   `isopod doctor` notes it if `brew install krunvm` has made it available.

## Network egress isolation (`egress lan-deny`)
- a dedicated bridge network (`isopod0`, fixed subnet) the firewall can target;
- `--dns` pinned to a public resolver, so the box can't query the host's
  internal/forwarding resolver (which knows your PTRs and split-horizon names);
- `--cap-drop NET_RAW,NET_ADMIN`, so the box can't craft raw scan packets or
  re-route around the rules.

Enable it in your override file (`~/.config/isopod/hardening.conf`):

```
egress lan-deny
```

or per-run with `ISOPOD_EGRESS=lan-deny isopod create …`.

### What you must do on the host

Egress isolation needs a **rootful** podman or docker: a rootless engine routes
boxes through a userspace network stack with no host bridge for the firewall to
hook, so `isopod create` **refuses** rather than start an unprotected box. On a
rootful engine, load the firewall once (needs root):

```sh
sudo isopod egress apply      # renders security/egress-host.nft and loads it
isopod egress status          # mode, network, and whether it's loaded
isopod doctor                 # also reports enforcement + loaded state
```

The rules are **not persistent** across reboot, a `firewalld` reload, or an engine
restart — re-run `sudo isopod egress apply` afterward, or include the ruleset from
`/etc/nftables.conf`. `isopod doctor` flags when it isn't loaded.

#### macOS

```sh
podman machine start          # the VM must be up
isopod egress apply           # loads security/egress-host.nft INSIDE the VM
isopod egress status          # reports the in-VM firewall state
isopod egress persist         # survive a machine restart (see below)
```

**Persistence.** A plain `apply` is lost when the VM stops (`podman machine stop`
/ reboot). `isopod egress persist` installs a small systemd unit **inside the
podman machine VM** (`isopod-egress.service`, loading `/etc/isopod/egress.nft`)
that re-applies the ruleset on VM boot — the macOS equivalent of the Linux host
boot unit. `isopod egress unpersist` removes it. Re-run `persist` if you change
any `ISOPOD_EGRESS_*` variable, since the unit loads a snapshot.

**allow-list on macOS.** The allow-list's filtering proxy is a Linux systemd
service and is not ported to the VM yet, so on macOS `apply`/`persist` enforce
**lan-deny**; an explicit `egress allow-list` fails closed with a steer to
lan-deny rather than silently starting an unfiltered box. Porting the proxy into
the VM (which has systemd) is the natural follow-up.

> **Two macOS backends — pick host `pf` when you can.** isopod has two macOS
> egress backends, selected by `egress_macos_backend()` (override with
> `ISOPOD_EGRESS_BACKEND=pf|vm`):
>
> - **`pf` (host-level, escape-resistant, preferred).** When boxes run on a
>   routable vmnet subnet (Apple `container`, or a vmnet vfkit/krunkit/krunvm
>   setup), `isopod egress apply` loads `security/egress-host.pf` into the
>   `com.isopod.egress` pf anchor **on the Mac host, outside every guest VM**, and
>   references it from `/etc/pf.conf`. `isopod egress persist` then installs a
>   `RunAtLoad` LaunchDaemon (`/Library/LaunchDaemons/com.isopod.egress.plist`) that
>   runs `pfctl -E -f /etc/pf.conf` at boot, since macOS re-reads pf.conf on boot but
>   does **not** re-enable pf on its own. A box that escapes its container *and* its VM
>   still can't flush it without root on macOS.
> - **`vm` (in-VM nft, weaker fallback).** Under podman machine's default gvproxy
>   networking a box has no routable subnet for pf to scope, so the rules load
>   inside the podman machine VM — out of reach of an in-box agent with root/sudo,
>   but only a **container escape** away. isopod labels this honestly and steers you
>   to the pf backend.
>
> The Apple `container` engine (per-box VM + vmnet subnet) is the intended home for
> the pf backend and is detected by `isopod doctor`; its box lifecycle integration
> is experimental. See **[docs/macos-host-egress.md](macos-host-egress.md)** and
> validate with `test/macos-egress-check.sh`.

**Fails closed.** If a box is configured for `egress lan-deny` but the host firewall
is not loaded, `isopod create` (and `reconfigure`) **refuse**, rather than starting a
box that only *looks* isolated. Load the firewall first, or — to start on the bridge
anyway without the LAN block actually in effect — set `ISOPOD_EGRESS_ALLOW_UNLOADED=1`
(you'll get a warning instead of a hard stop). When the firewall's state can't be read
without root, isopod can't confirm either way and warns rather than blocking.

### Limits

- Blocks your **LAN/host/metadata/internal-DNS**, not exfiltration to arbitrary
  **public** IPs — the box still has public internet (that's what keeps `apt`/`pip`
  working). For a fully offline box, use `ISOPOD_RUN_ARGS="--network=none"`.
- The isopod network is **IPv4-only** so a box has no IPv6 route to slip around the
  v4 rules; if you make it dual-stack, also load the commented `ip6` rules in
  `security/egress-host.nft`.
- Same-bridge boxes can still discover each other at L2, but not reach each other
  at L3 (dropped) — and both are equally locked down, so this leaks nothing about
  the host.

## Network egress allow-list (`egress allow-list`)

Where `lan-deny` blocks your local network but leaves the public internet open,
`allow-list` inverts the default: a box may reach **only the hostnames you
approve**, and nothing else. It exists to limit **data exfiltration** — a rogue
in-box agent can't POST your code to an arbitrary server, because the connection
never leaves the host.

Everything is enforced by the engine and the host. An agent with in-box root and
passwordless `sudo` cannot turn it off: there is no in-box proxy or firewall to
change, and unsetting the box's `http_proxy` just removes its only route out.

**How it works.** Two host-side pieces:

- a **filtering proxy** ([tinyproxy](https://tinyproxy.github.io/)) running on the
  egress bridge gateway, which allows or denies each request by the requested
  hostname (`CONNECT` target / `Host` header). It filters on the name, not the
  payload, so there is **no TLS interception and no CA certificate** to install.
- a **host firewall** (`security/egress-allowlist.nft`) that drops every
  box-initiated flow *except* to the proxy — so the proxy is the box's only way
  out. Boxes also get `--cap-drop NET_RAW,NET_ADMIN` so they can't re-route
  around it, and **no DNS** (the proxy resolves allow-listed names itself, which
  also closes DNS-tunnel exfil).

**Enable it** in your override file (`~/.config/isopod/hardening.conf`):

```
egress allow-list
```

or per-run with `ISOPOD_EGRESS=allow-list isopod create …`.

### What you must do on the host

Same rootful-engine requirement as `lan-deny`, plus `tinyproxy` and `systemd`.
One-time (needs root), which loads the firewall **and** starts the proxy as the
`isopod-egress-proxy` unit:

```sh
sudo isopod egress apply       # start the proxy + load the firewall
isopod egress status           # mode, proxy state, allow-list size, firewall state
```

The default allow-list (`security/egress-allowlist.conf`) covers common package
registries and source hosts (Debian/Ubuntu apt, PyPI, npm, crates.io, Go modules,
GitHub/GitLab). Your own additions go in `~/.config/isopod/egress-allowlist.conf`
and survive upgrades.

### Building and growing the allow-list

You rarely know every domain a workflow needs up front. **Observe mode** runs the
proxy permit-all but logs everything, so you can discover them from real traffic,
then lock it down:

```sh
sudo isopod egress observe     # permit all, but log every request
# …run your workflow once…
isopod egress denied           # hostnames that would be blocked under enforce
isopod egress allow files.pythonhosted.org   # approve one (reloads, no restart)
sudo isopod egress apply       # switch back to enforcing the allow-list
```

Day to day, when an agent hits a wall the blocked host shows up in the log:

```sh
isopod egress log -f           # watch requests live (allowed + refused)
isopod egress denied           # unique refused hostnames — candidates to allow
isopod egress allow <domain>   # approve it; the proxy reloads without dropping connections
```

Allow-list entries take two forms:

| Entry | Matches |
| --- | --- |
| `github.com` | `github.com` **and** all subdomains (`api.github.com`) |
| `*.githubusercontent.com` | subdomains only (not the apex) |

**Fails closed.** `isopod create` (and `reconfigure`) refuse if the proxy is not
running, rather than start a box with no route out. `isopod egress status` and
`isopod doctor` report whether the proxy and firewall are both up. Like the nft
rules, the systemd unit is what keeps the proxy up across reboots; re-run
`sudo isopod egress apply` after a `firewalld` reload or engine restart.

### Limits

- Filters by **hostname, not payload**. It stops connections to non-allowed
  domains, but cannot stop a secret being sent *into* an allow-listed domain
  (a GitHub gist, an `npm publish`). An allow-list narrows the exfil surface to
  the hosts you trust — it does not eliminate it. Keep the list tight.
- `CONNECT` is limited to the standard TLS ports (443/563), so the tunnel can't
  reach arbitrary services (e.g. `ssh` on 22).
- Clients that ignore `http_proxy` get no network (that's fail-closed). The common
  tools — `apt`, `pip`, `git`, `curl`, `wget` — all honor it.
- **Linux only.** Unlike `lan-deny`, the allow-list's filtering proxy is a host
  `systemd` service (`tinyproxy`), which is not ported to macOS. On macOS `isopod
  egress apply` falls back to `lan-deny` (loaded inside the `podman machine` VM),
  and an *explicit* `egress allow-list` fails closed with a steer to `lan-deny`
  rather than silently starting a box the proxy isn't filtering. There is no
  Windows-native path (run isopod inside WSL2).
