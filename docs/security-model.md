# Security model

This is the full reference for how isopod isolates a box, covering the always-on
boundaries (the isolation model and the fingerprint masks), what those boundaries
still can't hide, the security defaults, and the opt-in runtime tiers,
network-egress modes, and secrets that let you tighten things further.

## The isolation model

The container cannot see the host filesystem. Files cross the boundary in five ways:

1. `--repo <url>` — a `git clone` executed *inside* the container.
2. `--copy <path>` / `isopod copy-in` — a one-time **copy** of folders you name.
3. `isopod export` to copy changes back to the host machine
4. `isopod fetch` git history copied back to your local machine
5. `git push` to your remote server

A `--disk` data volume is not a sixth way: it is box-local storage (an image file in the box's own layer) and gives the box no access to the host filesystem — see [Data volumes](#data-volumes---disk-and-nested-containers---nested-containers).

Copy-not-mount is an integrity control, not a confidentiality one. Nothing the agent writes reaches your host except through a transfer you invoke and can review. There is no live mount where it could plant git hooks, `Makefile` edits, or editor task files that your host tools would execute the next time you touch the directory. What you copy *in*, however, is fully readable by the agent; limiting where that can be sent is the job of [egress isolation](#network-egress-allow-list-egress-allow-list), not the copy model.

We have some mitigations for a snooping AI agent fingerprinting your host machine from the container. It sees the container's hostname, a generic Linux environment, and the container's network identity — and isopod masks the host-revealing `/proc`/`/sys` paths that common tools read (boot UUIDs, board model, and the `lsblk`/`lspci`/`ip` views — see [Fingerprint hardening](#fingerprint-hardening)). Additional details:

- SSH is bound to `127.0.0.1` only and uses a dedicated per-container ed25519 keypair. The container's host key is pinned on first use (trust-on-first-use); if an already-pinned box ever presents a different key, isopod refuses to connect rather than adopt it (override with `ISOPOD_ACCEPT_NEW_HOSTKEY=1` if you deliberately rebuilt it). Password auth and root login are disabled in the container's sshd.
- SSH agent forwarding and X11 forwarding are explicitly disabled in the generated config, so an agent inside the container cannot borrow your SSH agent to authenticate as you elsewhere.
- With rootless Podman (the recommended engine), even "root" inside the container is just your unprivileged user on the host, remapped.

### What it does not fully protect against

- **Network exfiltration of what's inside the container.** AI agents need network access (APIs, package installs), so the container has it unless you've created an offline container. Anything you copy into the container could be sent out by a misbehaving agent. Only put code/data in the container that you could tolerate leaking, and use narrowly-scoped credentials. To narrow this, [`egress allow-list`](#network-egress-allow-list-egress-allow-list) forces the box through a host-side filtering proxy that permits only allow-listed hostnames — it limits, but does not eliminate, exfiltration (a secret can still be sent *into* an allowed host). Reconnaissance in the *other* direction — a rogue agent scanning your **local network**, the host, or cloud metadata — can be blocked with host-enforced [network egress isolation](#network-egress-isolation-egress-lan-deny), while keeping published ports and public internet working.

- **Every possible exploit an agent could theoretically take in your container.** The in-container user has **no `sudo` by default**, and the box additionally runs with `no-new-privileges`, so an agent that gets code execution as the box user cannot escalate to root inside the box. Administration comes from *outside* instead: `isopod root-shell <name>` logs in as root with a key the host generates per box and never places inside it, so there is no password to capture and no setuid path to abuse. Add system packages that way, or from the host with [`isopod install`](managing-boxes.md#adding-a-system-package-isopod-install). Pass **`--sudo`** to opt back into passwordless in-box sudo for a hands-on box — but understand that anything running as the box user, including an agent, inherits it. The container also intentionally keeps Linux capabilities (no `--cap-drop=ALL`), since `sshd` needs them — see [Fingerprint hardening](#fingerprint-hardening).

- **Unknown exploits.** There is no such thing as perfect security, and isopod can't prevent an exploit no one has discovered yet. It gives you a set of features to incrementally harden your sandbox, not a guarantee.

- **Container escape for standard Podman / Docker containers** Containers share the host kernel. Rootless Podman makes escapes very hard, but a container is not a VM. For "agent might be actively malicious and sophisticated," use the microVM option. For "agent might do dumb destructive things or over-collect data" this is the right tool.

- **Docker's daemon model.** With Docker (non-rootless), the daemon runs as root; a compromise of the daemon is a compromise of the host. Enable Docker rootless mode to avoid this.

## Fingerprint hardening

A standard podman / docker container shares the host's kernel and hardware, so by default a process inside can read a surprising amount about the host through `/proc` and `/sys` — far more than its own hostname. Isopod ships a hardening profile that closes the file-based leaks and supports an optional sandboxed runtime for the rest. The shipped defaults live in **[`security/hardening.conf`](../security/hardening.conf)** — a read-only baseline you don't edit (package upgrades replace it). To customize, drop an override file at **`~/.config/isopod/hardening.conf`** that *layers* on top of the baseline with `mask` / `unmask` / `runtime` / `no-runtime` directives (so you keep getting new masks on upgrade), or toggle the runtime per-run with `ISOPOD_RUNTIME=runsc`.

### What's implemented

Every container masks the host-revealing paths below — the ones common discovery tools (`lsblk`, `lspci`, `ip`, DMI readers) actually read. Podman gets a single `--security-opt mask=…` covering files and directories. Docker gets an empty `tmpfs` per directory; it **cannot** mask `/proc` files — runc rejects bind mounts onto arbitrary `/proc` paths — so `/proc/cmdline`, `/proc/config.gz`, and `/proc/modules` stay readable on Docker (isopod warns at create). Use rootless podman or a Tier 2/3 runtime to close those on Docker.

| Masked path | Data it obfuscates |
|---|---|
| `/proc/cmdline` *(podman)* | host boot args — **LUKS volume UUID, root-fs UUID, OS image / ostree hash** |
| `/proc/config.gz` *(podman)* | host kernel build config (exact kernel version and distro build) |
| `/proc/modules` *(podman)* | loaded host kernel modules (VPNs like WireGuard, DisplayLink, Bluetooth…) |
| `/sys/class/dmi`, `/sys/devices/virtual/dmi`, `/sys/firmware` | SMBIOS: **board model, vendor, BIOS version/date** |
| `/sys/bus/pci` | the `lspci` view of host PCI topology (NVMe, Wi-Fi, USB4/Thunderbolt controllers) |
| `/sys/bus/usb` | the tool-visible list of attached peripherals (keyboard, mouse, NIC, dongles) |
| `/sys/class/net` | the box's own interface name/MAC (host NICs are already hidden by the box's netns) |
| `/sys/block`, `/sys/class/block`, `/sys/class/nvme` | the `lsblk` view of disk models and factory serial numbers |
| `/sys/class/hwmon`, `/sys/class/thermal`, `/sys/class/drm` | sensor/thermal/GPU identity (a board signature) |

Verify from inside a container: after hardening, `cat /proc/cmdline` (podman) and `lsblk -o NAME,SERIAL` come back empty/blank.

> **On Tier 1/2 these masks close the *alias* directories, not the whole device tree.** `/sys/devices/` is not namespaced, and only its DMI subtree is masked there — so a reader walking `/sys/devices/.../serial` or `/sys/devices/pci*/*/vendor` directly can still recover PCI/USB/disk identity (`grep -r . /sys/devices` disproves any "serials are hidden" reading). Masking the whole tree on those tiers is impractical: the container's `/sys` *is* the box's `/sys`, and tools in the box read `/sys/devices/system/cpu`.
>
> **Under a Tier 3 microVM the whole tree is masked** (the `mask-microvm` directive), because the box reads its *guest's* sysfs and the container's copy exists only to be exported to that guest. Note carefully that the guest's synthetic `/sys` is **not** what protects you: crun exports the container's `/sys` to the guest as well, so without this mask a microVM box hands over host NVMe serials and PCI topology just as a plain container does. `verify-host-isolation.sh` probes the device tree directly so it can't be fooled by masking only the aliases.

> **These masks apply under a Tier 3 microVM too.** It is tempting to skip them there — the guest has its own kernel and only virtual devices, so *its* `/proc` and `/sys` describe the guest. But the guest is not the only copy it can reach. crun's krun handler hands the guest the **container's** rootfs over virtio-fs (`krun_add_virtiofs2(ctx, tag, "/")`), and podman mounted the host's procfs and sysfs into that rootfs before handing it over. Root inside the box can read the container's copy through the export and recover `/proc/cmdline` (LUKS volume UUID, ostree deployment hash), `/proc/config.gz` (host kernel build config), `/sys/class/dmi/id/*` (board vendor and product name), and `/sys/block` (host disk devices). Masking costs the guest nothing — its own `/proc` and `/sys` are separate and untouched. The VM is a boundary for host *memory and kernel*; it is not, on its own, a boundary for host *identity* reachable through the exported rootfs.

> isopod launches containers with `podman run`/`docker run`, not Compose, so the profile above is the live source of truth. If you prefer Compose, [`security/compose.yaml`](../security/compose.yaml) expresses the same masks in `podman compose`/`docker compose` form as a reference — it is not executed by the CLI.

> isopod does **not** add `--cap-drop=ALL` or `--read-only` here: the container runs `sshd` (which needs capabilities) and toolchains write to the filesystem, both of which those flags would break. It **does** apply `--security-opt no-new-privileges` on a no-sudo box (the default), and drops `NET_RAW`/`NET_ADMIN` on the host-enforced egress modes. The isolation guarantees in [The isolation model](#the-isolation-model) (no mounts, loopback-only SSH, rootless userns) remain the primary boundary; the masks above are defense-in-depth against *fingerprinting* specifically.

## What still can't be mitigated

Even with every mask on, a **plain shared-kernel container cannot hide these** — the app reads them straight from the CPU or the shared kernel, with no file to mask:

- **CPU identity** — model, family, stepping, **microcode**, feature flags, via the `CPUID` instruction. (Masking `/proc/cpuinfo` doesn't stop `CPUID` and breaks build tools, so isopod leaves it readable.)
- **Kernel build string** — `uname -r` (a syscall, no file to mask) always returns the host kernel version; `/proc/version` adds the build host/toolchain string.
- **Host RAM size** — `/proc/meminfo` (masking it breaks build tools and most memory-aware programs, so it's left readable).
- **The `/sys` device tree** — PCI/USB/NVMe/disk identity under `/sys/devices/`. Not namespaced, so a plain container reads it directly, and on Tier 1/2 only its DMI subtree is masked (see the note above). A Tier 3 microVM box *does* close it.
- **Host boot epoch / boot id** — `/proc/stat`'s `btime` and `/proc/sys/kernel/random/boot_id` are a single value per host boot, identical in every container on that host. (`btime` is left unmasked because masking `/proc/stat` breaks `top`/`htop` and most monitoring.)
- **Timing side channels** — `RDTSC` and clock-skew fingerprints.

A **Tier 2 runtime** (gVisor `runsc`) already presents a synthetic `/proc`/`/sys`, closing the device tree, `/proc/version`, and boot id. A **Tier 3 microVM runtime** (Kata or krun) also closes `uname`, RAM/CPU identity, and the timing channels — the box runs on its own guest kernel behind a hardware boundary. See [microVM runtimes](#microvm-runtimes-kata-krun--tier-3).

Two more, which depend on your egress mode rather than the runtime:

- **Your DNS resolvers** — podman copies the host's `/etc/resolv.conf` into a box by default. isopod removes the **search domain** in every mode (it names your network and is never needed to resolve a public name), and handles the nameservers per egress mode: `allow-list` gives the box **no resolver at all** (the proxy resolves names, so the box never needed one — and a resolver would be a DNS path around the allow-list), `lan-deny` pins a public resolver, and with egress **off** your real nameservers stay visible. That last case is deliberate rather than an oversight: an open box can read them from its own route table anyway, so hiding the file would be cosmetic — enforcing egress is what closes it.
- **Your LAN position** — with egress **off** the box gets an address on your LAN, so `/etc/hosts` discloses your subnet. Under `lan-deny` or `allow-list` the box sits on isopod's own fixed `10.88.7.0/24` bridge, which says nothing about your network.

Rule of thumb: if your threat model is "a sophisticated, actively malicious agent," use a Tier 3 microVM runtime (or a full VM); isopod's container hardening targets "an agent that over-collects host data or does dumb destructive things."

## Security defaults

The two strongest features are **on by default**. `isopod create` runs each box in a **microVM** (its own guest kernel behind a KVM boundary) when a microVM runtime and `/dev/kvm` are available, and network egress uses the **allow-list**. When a default can't be honored, isopod degrades with a warning rather than failing:

- runtime falls back microVM → gVisor (`runsc`) → plain container;
- egress falls back allow-list → lan-deny → open.

Force a plain shared-kernel container with `isopod create --container`. Turn egress off with `ISOPOD_EGRESS=off` or a `no-egress` directive. The runtimes below still need host-side setup (installing and registering the runtime with your engine); the fingerprint masks and isolation model above are always on.

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
[What still can't be mitigated](#what-still-cant-be-mitigated)). Only a
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
  lightest microVM. isopod runs it with passt (`krun.use_passt=1`) so `isopod
  code` works (see the note below); auto-selected when kata is not installed.

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

> **Why passt?** libkrun's *default* TSI networking stalls bulk data over the SSH
> port-forward the IDE's remote server needs (upstream bugs
> [libkrun#579](https://github.com/libkrun/libkrun/issues/579) and
> [#510](https://github.com/libkrun/libkrun/issues/510)), so VSCodium/Cursor/
> JetBrains would fail to connect (WebSocket 1006). isopod therefore always adds
> `krun.use_passt=1`, giving the guest a real virtio-net stack.

Fedora example. On Arch and Gentoo krun is not in the official repositories —
install it from the AUR or build libkrun + crun yourself, then register the
runtime path the same way (only the path in `containers.conf` changes):
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
since a microVM boots a fixed-size guest. isopod keeps the fingerprint masks under
a microVM rather than skipping them: crun's krun handler exports the **container's**
rootfs to the guest over virtio-fs, and podman mounted the host's procfs and sysfs
into that rootfs — so the container's `/proc` and `/sys` reach the guest through
the export, still holding the host's boot line, kernel config, board DMI, and disk
list. The guest's own `/proc` and `/sys` are separate and unaffected. See
[Fingerprint hardening](#fingerprint-hardening).

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
   [`container`](https://github.com/apple/container) is a macOS-native engine
   (not a Linux port). Each box gets a routable per-box vmnet subnet the host pf
   egress backend already scopes to, so a box that escapes its VM still can't
   flush the firewall without root on your Mac. This is the intended "Tier 3
   for macOS," and isopod's box lifecycle (create/code/shell/start/stop/rm) is
   wired to it — `reconfigure` is the one unsupported operation (the engine has
   no image-commit primitive). See [docs/macos-host-egress.md](macos-host-egress.md).

2. **Nested `krun`/`kata` inside the engine VM (needs Apple M3+/macOS 15).**
   Apple exposes nested virtualization only on M3 or later chips running macOS
   15+. `isopod doctor` tells you when your chip/OS qualifies and marks it
   experimental. On other Macs the engine VM stays the boundary.

3. **krunvm (not integrated).** [krunvm](https://github.com/containers/krunvm)
   also boots an OCI image as its own microVM on Hypervisor.framework, but it
   is Linux-oriented, not well tested on macOS, and isopod does not wire it up
   as an engine — mentioned here only as a route that exists upstream.

## Kernel attack-surface hardening (`--harden`)

Beyond the fingerprint masks, isopod applies a small **kernel-hardening profile to every box by default** — a set of low-impact guest sysctls that shrink kernel attack surface without changing how development feels. Because these are guest-*kernel* settings, they take effect on **microVM boxes** (which have their own kernel). A plain container shares the host kernel, so isopod never sets sysctls there — that would change the host — and it keeps the engine's default seccomp/isolation instead.

The default profile sets `kernel.kptr_restrict=2` (hide kernel pointers), `kernel.dmesg_restrict=1` (root-only `dmesg`), `net.core.bpf_jit_harden=2` (harden the eBPF JIT), and `kernel.kexec_load_disabled=1` (block loading a new kernel). These are deliberately conservative: they don't break nested containers, profiling, or normal builds. The heavier toggles that *would* affect those workflows — disabling unprivileged eBPF, io_uring, and user namespaces, or `lockdown` — are reserved for a future opt-in **`--harden strict`** profile.

Turn the profile off with **`--harden off`**. The applied set lives in [`share/hardening-sysctl.conf`](../share/hardening-sysctl.conf); the box entrypoint applies it best-effort at boot, skipping any key the guest kernel doesn't expose.

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
> the pf backend and is detected by `isopod doctor`; its box lifecycle
> (create/code/shell/start/stop/rm) is wired up, though still labeled
> experimental since there's no macOS CI runner to exercise it automatically.
> See **[docs/macos-host-egress.md](macos-host-egress.md)** and validate with
> `test/macos-egress-check.sh`.

**Fails closed.** If a box is configured for `egress lan-deny` but the host firewall
is not loaded, `isopod create` (and `reconfigure`) **refuse**, rather than starting a
box that only *looks* isolated. Load the firewall first, or — to start on the bridge
anyway without the LAN block actually in effect — set `ISOPOD_EGRESS_ALLOW_UNLOADED=1`
(you'll get a warning instead of a hard stop). When the firewall's state can't be read
without root, isopod can't confirm either way and warns rather than blocking.

### Host-enforced egress on a rootless engine (the sandbox account)

The rootful-engine requirement above is a wall if you run rootless podman and want to keep it that way, and the sandbox account is the way around it: a dedicated unprivileged system account whose boxes you launch with `sudo -u`, so their traffic carries that account's uid on the host, where an nftables ruleset keyed on that uid drops everything bound for private ranges. The drop lives on the host and keys on the uid, so it holds even against root inside the box, which is the boundary a rootless bridge cannot give you.

Set it up once as root, then create boxes against it:

```sh
sudo isopod account setup      # account, subuids, linger, the uid-keyed nft rules + boot unit, and a sudoers grant for you
isopod account status          # confirm the account, rules, and grant are all in place
isopod create devbox --account # this box runs under the account, behind the uid-keyed drop
```

`isopod account rules` prints the ruleset for inspection and `sudo isopod account teardown` removes the account and everything setup added. It needs Linux and podman, since it relies on subordinate ids, systemd linger, and nftables, none of which have a rootless-docker or macOS equivalent.

**Why an account rather than a rootful engine?** A rootful podman would also put the firewall outside the box, but the engine parses complex, partly untrusted input like images, archives, and network setup, and under a rootful engine a bug anywhere in that path runs as root rather than as you. The account keeps the engine rootless and still lands any escape in a system account that owns nothing, buying the same host-side boundary without a root-run engine. Rootful is worth reconsidering only if boxes get hosted for untrusted third parties, per-box allow-list egress becomes a requirement, or the engine gains bridge networking for rootless microVMs.

### Limits

- Blocks your **LAN/host/metadata/internal-DNS**, not exfiltration to arbitrary
  **public** IPs — the box still has public internet (that's what keeps `apt`/`pip`
  working). For a fully offline box, use [`isopod create --offline`](#offline-boxes---offline).
- The isopod network is **IPv4-only** so a box has no IPv6 route to slip around the
  v4 rules; if you make it dual-stack, also load the commented `ip6` rules in
  `security/egress-host.nft`.
- Same-bridge boxes can still discover each other at L2, but not reach each other
  at L3 (dropped) — and both are equally locked down, so this leaks nothing about
  the host.

### Reaching one internal service anyway (`egress lan-allow`)

A box that needs an internal registry, a private git server, or a database on the
LAN does not need guest egress turned off. Allow the one address instead:

```sh
isopod egress lan-allow devbox 10.20.30.40        # one host
isopod egress lan-allow devbox 10.20.0.0/16       # a range
isopod egress lan-allow devbox 10.20.30.40:5432   # one host, one port
isopod egress lan-allow devbox                    # list what is allowed
isopod egress lan-allow devbox --rm 10.20.30.40   # remove one
```

IPv6 works the same way, with brackets when a port is given: `[fd00::1]:5432`.
Entries are stored per box, so they survive stop/start, and applied to a running
box immediately — no restart, and no recreate (unlike `--expose`, which has to
rebuild the container). `isopod create --lan-allow <addr>` sets them up front.

**Names already resolve inside a box**, because the ruleset exempts the box's own
resolvers on port 53. So allowing the address is usually the only step: existing
tools keep working with the hostnames they already have, unchanged.

To find out what to allow, ask the box what it was blocked from:

```sh
isopod egress lan-denied devbox
```

The ruleset logs dropped packets (rate-limited, so a retry loop writes a few lines
a minute rather than filling the ring buffer) and this reads them back as
destination/port pairs. On a kernel with no netfilter log support the box says so
at boot and filtering continues unaffected — only the diagnostic is lost.

What an exemption costs: the address is open to **everything** in the box, not
just the tool you had in mind. It is still far narrower than turning guest egress
off, which opens your whole LAN. For a service reachable only from the host —
something on the host's own `127.0.0.1` — an exemption cannot help, because the
box's loopback is its own.

### Reaching a service on your host (`host-port`)

An exemption cannot help with a service on the host's own `127.0.0.1` — the box's
loopback is its own. For that, forward the port instead:

```sh
isopod host-port add devbox 5432              # host's Postgres at the box's 127.0.0.1:5432
isopod host-port add devbox 11434             # a local Ollama
isopod host-port add devbox 8080:gitlab.corp.internal:443
isopod host-port ls devbox
isopod host-port rm devbox 5432
```

`isopod create --host-port <spec>` sets them up front. A bare port uses the same
number on both sides, so nothing inside the box needs reconfiguring — a tool
already pointed at `localhost:5432` just works.

This is SSH remote forwarding over the connection isopod already holds, which is
why it needs no firewall change and behaves identically on every engine and OS.
The target is resolved and connected **from your host**, so an internal name only
your host can see works even when the box has no route to it — a split-tunnel VPN
included.

Limits worth knowing: the box-side port must be **1024 or above** (sshd opens it
as the box user, which cannot bind a privileged port — use `8443:443`), it is
**TCP only**, and one ssh process carries all of a box's forwards, so adding or
removing one briefly restarts the others. Forwards are reopened by `isopod start`
and torn down by `isopod stop`.

## Offline boxes (`--offline`)

`isopod create <name> --offline` gives a box no route off the host. It is the only
network boundary here that needs nothing set up first: no host firewall, no rootful
engine, no `/dev/kvm`. On a stock rootless podman, where `lan-deny` and `allow-list`
both degrade to an open network, this one still holds.

```sh
isopod create review --offline --container --copy ~/src/thing
isopod host-port add review 11434          # optionally, one host service (a local Ollama)
```

**It needs `--container` for now.** A microVM box reaches its guest through passt,
which cannot forward the published SSH port when the container's network namespace
has no gateway, and an internal network has none. The box boots, sshd listens, and
nothing can reach it. `isopod create` refuses `--offline` under a microVM runtime
and names this rather than leaving you to debug a box that looks healthy in its own
logs. So today offline is a choice between the network boundary and the per-box
kernel boundary, not both. Closing that gap means enforcing the drop inside the
guest instead of at the engine, which is a weaker boundary (guest root could remove
it) and is the reason it is not done yet.

**How it works.** The box goes on a dedicated **internal** engine network
(`isopod-offline`, created on first use). It gets an interface, so the loopback SSH
port isopod publishes still works and `code`, `shell`, `copy-in`, `export`, secrets
and host-port forwards all behave normally, but the engine gives that bridge no
route outward. Enforcement is the engine's, so in-box root cannot undo it, and
`NET_RAW`/`NET_ADMIN` are dropped so the box cannot try to re-route around it.

`--network none` would be the obvious way to spell this and is the wrong one: it
leaves the box with only loopback, so the published SSH port has nothing to forward
to and isopod, which brings a box up entirely over SSH, could never reach it.

**What it rules out.** `--repo` needs a network to clone over, so pass `--copy`
instead. `apt`, `pip` and any API the agent wants are all unreachable, which is the
point. `--offline` turns any configured egress mode off, since there is no traffic
left to filter. To let an offline box reach exactly one service on your machine,
forward it with [`isopod host-port`](#reaching-a-service-on-your-host-host-port),
which rides the SSH connection isopod already holds rather than giving the box a
route.

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
  rather than silently starting a box the proxy isn't filtering.

## Data volumes (`--disk`) and nested containers (`--nested-containers`)

`isopod create --disk 20g` gives a box a dedicated ext4 filesystem (default
mountpoint `/mnt/data`). `--nested-containers` builds on it to run rootless
podman inside the box. Both are opt-in and both are microVM-only.

```sh
isopod create build --repo <url> --disk 20g              # ext4 at /mnt/data
isopod create build --repo <url> --disk 50g:/srv/cache   # pick the mountpoint
isopod create ci    --repo <url> --nested-containers      # 20g volume, or --disk 40g
isopod shell ci -- podman run --rm docker.io/library/busybox echo hello
```

### Why the volume is not a host mount

The volume's backing image is a sparse file inside the box's **own container
layer**; the box's entrypoint formats it once and loop-mounts it on every boot.
No engine mount flag is involved and no host path is named, so isopod's
copy-not-mount model is untouched.

The alternative — a host-backed volume or bind mount (`podman -v`) — was
rejected on purpose:

- It reintroduces the live-mount integrity risk copy-not-mount exists to remove:
  a place where an agent can write git hooks, `Makefile` edits, or editor task
  files that your *host* tools execute later.
- On a microVM box it is worse. crun's krun handler exposes the box's root to
  the guest with a single `krun_add_virtiofs2` call, and libkrun's own
  documentation states that virtio-fs gives "no protection against the guest
  attempting to access other directories in the same filesystem, or even other
  filesystems in the host." Handing a host directory to a box that way weakens
  the boundary the microVM was chosen for.

A genuine host-attached **virtio-blk** disk would avoid both problems — the host
would expose one opaque image file with no directory tree and no uid/gid
semantics. It is not reachable today: libkrun implements virtio-blk, but crun's
krun handler exposes no annotation for it (`krun.cpus`, `krun.ram_mib`,
`krun.gpu_flags`, `krun.use_passt`, `krun.nested_virt`, `krun.variant` are the
whole set, and `krun_set_root_disk` is used only for SEV). If that lands
upstream it is the natural backend for this flag; the in-guest loop device is
what makes the feature work now, with strictly less host exposure.

### Why nested containers need the volume

A microVM box boots with its root on **virtiofs**, and container storage cannot
live there — virtiofs cannot carry the multiple uids/gids that
containers/storage needs. Layer extraction fails with:

```
ApplyLayer ... setting up pivot dir: mkdir .../.pivot_root2168677766: permission denied
```

The graph driver is not the variable: `vfs`, `overlay`, and `fuse-overlayfs` all
fail the same way, and upstream podman now refuses to put storage on virtiofs
rather than fix it. Moving the graph root onto a real block device is the fix,
which is why `--nested-containers` implies a `--disk` mounted at
`/home/dev/.local/share/containers`. It also lets podman use `overlay` instead
of falling back to `vfs`, which copies every layer in full.

isopod also hands the box user `/dev/fuse` and `/dev/net/tun`, needed for
fuse-overlayfs storage and slirp4netns networking. They are `chown`ed to that
user with the mode left at `0600`, rather than made world-accessible.

### What to weigh before turning these on

- **Persistence weakens disposability.** A box's whole appeal is that it is
  throwaway. Anything an agent leaves on the volume survives `stop`/`start`.
  It is destroyed with the box (`isopod rm`), and `isopod export` does not
  reach it — treat the volume as scratch space, not as a place to keep the only
  copy of anything.
- **A nested engine is added attack surface inside the box.** The microVM
  boundary is unchanged — nested containers run within it — but the box itself
  now has an engine, subordinate UID ranges, and two more device nodes.
- **No `reconfigure`.** `reconfigure` snapshots the container layer, and the
  volume's image lives in that layer, so a `--disk` box is refused rather than
  turned into a snapshot the size of its disk.

## Secrets

Store a value once on the host, then hand it to specific boxes at create time:

```sh
isopod secret set NPM_TOKEN          # value from stdin or a hidden prompt — never argv
isopod create myproj --secret NPM_TOKEN            # appears at /run/secrets/NPM_TOKEN
isopod create other --secret NPM_TOKEN:/run/secrets/npmrc-token   # custom path
```

Values live in the OS keychain (`security` on macOS, `secret-tool` on Linux; 0600-file fallback) and are streamed over the box's SSH channel into a memory-backed tmpfs. As long as the target path stays under `/run/secrets` (the default), they never appear in image layers, container env, `inspect` output, `isopod export` tarballs, or `reconfigure` snapshots, and a stopped box holds no secrets (they're re-injected on `start`). A custom `--secret NAME:path` target *outside* `/run/secrets` loses that guarantee — it persists in the container layer and in `reconfigure` snapshots like any other file. Manage them with `isopod secret set|ls|rm`.
