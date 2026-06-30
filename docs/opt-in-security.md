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
