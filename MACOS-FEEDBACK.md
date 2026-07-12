# macOS feedback: the `.nft` egress firewall and the `/dev/kvm` Tier-3 check

Tested `isopod` (installed via `brew`) on macOS. Both host-side security features
assume a Linux host where the `isopod` script, the container bridge, `nftables`,
and `/dev/kvm` all live on **one** machine. On macOS they don't: boxes run inside
the `podman machine` / Docker Desktop **Linux VM**, so the script's host and the
box's host are two different machines. That breaks the two features you asked
about. Branch `macos-egress-and-tier3` has a working first cut; this is the
reasoning behind it.

## 1. The `.nft` egress firewall → it belongs *inside the VM*, not on the Mac

`security/egress-host.nft` is loaded with `nft -f` into "the host network
namespace." On macOS:

- the Mac has no `nftables`, so `isopod egress apply` just dies with
  *"nft not found — install nftables"* (you can't);
- the box bridge (`isopod0`, `$ISOPOD_EGRESS_SUBNET`, `$ISOPOD_EGRESS_IFACE`)
  doesn't exist on the Mac either — it's created **inside the podman machine VM**.

**The bug that matters:** because `nft` is absent, `egress_rules_loaded` returns
"unknown" (not "not loaded") and `egress_proxy_active` returns "unknown" (no
`systemctl`), so `resolve_egress` never degrades. A freshly created box on macOS
prints **"Network: egress allow-list ACTIVE"** while **nothing** is filtering it —
a false sense of security, which is the worst failure mode for this feature.

**Is `pf` the macOS `nftables`?** It's the literal equivalent tool (`pfctl` +
`/etc/pf.conf`), but it's the **wrong layer** here. By the time a box's traffic
reaches the Mac it's already been NAT'd out of the VM and is sourced from the VM's
address — pf can't tell a box-initiated flow from the VM's own, and the per-box
subnet the rules key on is gone. The threat model ("this *box* may not reach the
LAN/host/metadata") can only be enforced where the box identity still exists:
**inside the VM.** And conveniently, the VM *has* nftables and *is* where the
bridge lives — so the existing ruleset is already correct there, unchanged.

**What the branch does:**

- `isopod egress apply` on macOS loads the same `security/egress-host.nft` **inside
  the podman machine VM** via `podman machine ssh sudo nft -f -`. No Mac `sudo`, no
  local nftables — just a running machine.
- `egress_rules_loaded` probes in-VM on macOS (stopped machine → "unknown", not a
  phantom "not loaded").
- The **allow-list** proxy is a Linux `systemd`/`tinyproxy` service, so on macOS
  `egress apply` and the default-on egress fall back to **lan-deny**, and an
  *explicit* `allow-list` **fails closed** with a steer to lan-deny — instead of
  the false "ACTIVE". Porting the proxy (it could run inside the FCOS VM, which
  has systemd) is the natural follow-up.
- Docker Desktop's VM isn't a general SSH target, so host-enforced egress on macOS
  currently requires podman machine; the code says so where it matters.

## 2. The `/dev/kvm` check → macOS uses Hypervisor.framework, and the VM *is* the boundary

`runtime_preflight` / `_runtime_runnable` already skip the `/dev/kvm` check off
Linux (good) — but **`doctor` doesn't**. On macOS it always prints
*"[--] /dev/kvm absent — Tier 3 microVM runtimes unavailable"*, which is
misleading on two counts:

1. **There is no `/dev/kvm` on macOS by design.** The hardware-virt backend is
   Apple's **Hypervisor.framework**; the closest probe is `sysctl kern.hv_support`
   (1 = available). `detect_microvm_runtimes` also looks for `krun`/`kata-runtime`
   on the **Mac** PATH, but on macOS those live in the VM (podman uses libkrun via
   `krunkit`), so it can never find them.
2. **Every box already runs inside the engine's VM** — a hardware VM built on
   Hypervisor.framework. That boundary *is* the Tier-3-class isolation on a Mac: a
   container escape lands in the VM, not on macOS. A plain container on macOS is
   already VM-isolated in a way it isn't on Linux. A **nested** per-box microVM
   (`runtime kata`/`krun` inside that VM) is a separate, still-maturing thing —
   it needs an Apple **M3+** chip on **macOS 15+** plus a VMM that exposes nested
   virt.

**What the branch does:** `doctor` reports Hypervisor.framework via
`kern.hv_support`, explains the VM-is-the-boundary reality, flags nested Tier-3 as
generally N/A on macOS today, and Linux-guards the stray `/dev/kvm` warning in the
runtime block (matching the preflight guards).

New macOS `doctor` virtualization block:

```
  [ok]      Apple Hypervisor.framework present (kern.hv_support=1) — the macOS /dev/kvm equivalent
  [ok]      boxes run inside the podman machine / Docker Desktop VM (a hardware VM boundary —
            the Tier-3-class isolation on macOS; a plain container here is already VM-isolated)
  [note]    a NESTED per-box microVM runtime (kata/krun inside that VM) additionally needs an
            Apple M3+ chip on macOS 15+ and a VMM exposing nested virt (still maturing), so
            `runtime kata`/`krun` is generally N/A on macOS today — the engine VM is the boundary
```

## Status: implemented in branch `macos-egress-and-tier3` (2 commits)

Both goals are now built, not just described:

**Egress (nftables equivalent) — complete for lan-deny.**
`isopod egress apply` loads `security/egress-host.nft` inside the podman machine
VM; `isopod egress persist`/`unpersist` install/remove an in-VM systemd unit
(`isopod-egress.service`) so it survives `podman machine stop`/reboot — parity
with the Linux host boot unit. `status`/`doctor` report the in-VM state
accurately, and the old false "allow-list ACTIVE" is gone. allow-list still
degrades to lan-deny on macOS (its proxy is Linux systemd) — porting the proxy
into the VM is the tracked next step.

**Tier-3 for macOS — detection + guidance, with the real options surfaced.**
`doctor` now probes `kern.hv_support`, the chip generation, and the macOS version,
and recommends the strongest per-box isolation your Mac supports:
- **Apple `container`** — Apple's native Containerization framework runs each box in
  its own lightweight VM on Hypervisor.framework, with a routable per-box vmnet subnet
  that the host pf backend already scopes to. This is the intended "Tier 3 for macOS":
  a macOS-native engine, not a Linux port. Wiring it fully into create/code/export is
  the next build; `doctor` already detects the service and the pf egress backend targets
  its subnet.
- **nested `krun`** inside the engine VM when the Mac is Apple M3+/macOS 15+
  (experimental; needs a krunkit that surfaces nested virt).
- **krunvm** — a per-box microVM engine that also runs on Hypervisor.framework, but it
  is Linux-oriented and not well tested on macOS, so it is a fallback rather than the
  recommended path. `doctor` notes it if present.
- otherwise, the engine VM itself as the boundary.

## Scope / caveats

- Everything is gated behind `is_macos()`, so **Linux paths are byte-for-byte
  unchanged** — 149 unit / 20 theming / 5 security-poc / 74 integration all green;
  `shellcheck -S warning` and `shfmt -i 2 -ci` clean. 9 new unit tests drive the
  macOS branches with stubbed `uname`/`sysctl`/`podman`.
- I don't have a macOS CI runner, so the `podman machine ssh` path is marked
  in-code as needing validation on a real Mac (same disclaimer style as the
  `egress_persist` scaffold). I'm on macOS and happy to test iterations.
- Done since: a launchd-based `egress persist` for the macOS pf backend — a
  `RunAtLoad` LaunchDaemon (`/Library/LaunchDaemons/com.isopod.egress.plist`) runs
  `pfctl -E -f /etc/pf.conf` at boot, so host pf egress stays enforced across reboots
  (macOS re-reads pf.conf on boot but does not re-enable pf). The chip/macOS-version
  capability check is also in place.
- Remaining follow-up: port the allow-list proxy into the FCOS VM (it has systemd) so
  `egress allow-list` filters on macOS instead of degrading to lan-deny.
