# Opt-in Security Features

These features are **off by default** because they require host-side setup. They
complement the always-on [fingerprint hardening](../README.md#fingerprint-hardening)
and [isolation model](../README.md#the-isolation-model) described in the README.

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

- **krun** (libkrun, Podman-native): `ISOPOD_RUNTIME=krun isopod create …`
- **Kata Containers** (pluggable Firecracker / Cloud Hypervisor / QEMU backend):
  `ISOPOD_RUNTIME=kata isopod create …`
- **crun-vm** (run a VM disk image as an OCI container): `ISOPOD_RUNTIME=crun-vm …`

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
sandboxed runtimes (krun, crun-vm, kata, runsc) are already available to enable**,
so you can see your options at a glance. Package names and binary paths vary by
distro — doctor is the check that it's wired up.

**Podman + krun** (lightest path — krun is a [crun](https://github.com/containers/crun)
handler backed by [libkrun](https://github.com/containers/libkrun), so it's
Podman-native):

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

## Network egress isolation (`egress lan-deny`)

Stops a rogue in-box agent from **mapping or fingerprinting your local network**:
scanning your LAN, reaching the host, reading cloud metadata
(`169.254.169.254`), or enumerating internal hostnames over DNS. Host-initiated
**published ports keep working** (`--expose` and SSH), and the box keeps
**public internet + DNS** for `apt`/`pip`/`git`.

Everything is enforced by the engine and the host — an agent with in-box root and
passwordless `sudo` cannot turn it off (there is no in-box firewall to flush).

**How it works.** Published ports are host-*initiated*, so a box only ever sends
*reply* traffic on them; a scan is a box-*initiated* new connection. A host
firewall accepts the replies (conntrack `established,related`) and drops
box-initiated traffic to RFC1918, the host, metadata, and multicast — while
letting public destinations through. Three host-set pieces do it:

- a dedicated bridge network (`isopod0`, fixed subnet) the firewall can target;
- `--dns` pinned to a public resolver, so the box can't query the host's
  internal/forwarding resolver (which knows your PTRs and split-horizon names);
- `--cap-drop NET_RAW,NET_ADMIN`, so the box can't craft raw scan packets or
  re-route around the rules.

**Enable it** in your override file (`~/.config/isopod/hardening.conf`):

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
