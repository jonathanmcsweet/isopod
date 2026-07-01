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

Because isopod brings a box up entirely over SSH (no `engine exec`/`cp`), every
operation — clone, copy-in, export, fetch, shell — enters the guest correctly
under a microVM.

**What you must do on the host**:

- Have **`/dev/kvm`** (bare metal or a KVM-enabled VM; nested virt is often off
  in cloud CI). `isopod doctor` reports whether it is present.
- Install and register the runtime with your engine, the same way as `runsc`
  above (`containers.conf` for Podman, `daemon.json` for Docker).

When a Tier 3 runtime is active and you pass no `--memory`, isopod sizes the
guest with a default (2g; override with `--memory` or `ISOPOD_MICROVM_MEMORY`),
since a microVM boots a fixed-size guest. The Tier 1 fingerprint masks become
largely redundant under a microVM — the guest has its own `/proc` and `/sys`, so
they are left on but cost nothing.
