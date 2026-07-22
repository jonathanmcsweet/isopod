# macOS host-level egress: enforcing outside the guest VM

On macOS the `isopod` script runs on the Mac, but boxes run inside a guest VM
(`podman machine`, Docker Desktop, or Apple `container`). That split is why
macOS needs its own egress design: a firewall loaded on the Mac and a firewall
loaded inside the guest VM see different traffic, and only one of them is a
boundary a container escape can't cross.

## Status

Implemented and merged to `master`:

- **Host `pf` backend.** `isopod egress apply` renders `security/egress-host.pf`
  (box subnet substituted) into the `com.isopod.egress` pf anchor on the Mac
  host, references it from `/etc/pf.conf` so the anchor re-parses on boot, and
  enables pf. `isopod egress persist` additionally installs a `RunAtLoad`
  LaunchDaemon (`/Library/LaunchDaemons/com.isopod.egress.plist`) that runs
  `pfctl -E -f /etc/pf.conf` at boot, since macOS re-reads `pf.conf` on boot but
  does not re-enable pf on its own. `status`, `rules`, `persist`/`unpersist` all
  follow this backend when it's selected.
- **Backend selection.** `egress_macos_backend()` returns `pf` when `pfctl` is
  present and a routable box subnet is available (Apple `container`,
  `ENGINE=container`, or `ISOPOD_PF_SUBNET` set); otherwise the weaker in-VM
  `nft` fallback. Override with `ISOPOD_EGRESS_BACKEND=pf|vm`.
- **Apple `container` engine.** Recognized and box-lifecycle-wired: `create`,
  `code`, `shell`, `start`, `stop`, and `rm` all work against it
  (`ISOPOD_ENGINE=container` or `--engine container`). `isopod doctor` reports
  its presence and the host-pf availability it unlocks. Two exceptions:
  `reconfigure` is unsupported (the engine has no image-commit primitive), and
  `isopod install` needs more validation. Both fail with a clear error rather
  than a silent no-op.
- **allow-list still degrades to lan-deny on macOS.** The allow-list's filtering
  proxy is a Linux `systemd` service not yet ported to any macOS VM, so on
  macOS `apply`/`persist` enforce `lan-deny`; an explicit `egress allow-list`
  fails closed with a steer to `lan-deny` instead of silently starting an
  unfiltered box.
- **Not CI-exercised.** There is no macOS CI runner, so both macOS code paths
  (`podman machine ssh`, and `pfctl`) are validated by hand rather than by
  automated tests. `test/macos-egress-check.sh` does a read-only dry run
  (renders the ruleset, parse-checks it with `pfctl -n`, no load or enable) so
  you can sanity-check a Mac before running `isopod egress apply` for real.

## The problem with the in-VM approach

Loading the nft ruleset inside the podman machine VM keeps it outside the box
container, so an in-box agent with root and passwordless sudo can't flush it —
that satisfies "root in the box can't turn it off." It does not satisfy the
stronger guarantee the Linux design targets: enforcement on a boundary the box
cannot cross. The rules live in the VM's root netns, one container escape away
from the agent. On Linux a Tier-3 box would have to escape a microVM first, and
the rules sit on the host beyond that.

Egress enforced on the macOS host, outside every guest VM, needs compromising
macOS itself to disable — not just escaping a Linux guest.

## Why the Mac host can't filter podman-machine boxes today

Podman machine on macOS uses `gvproxy` (gvisor-tap-vsock): user-mode
networking. The VM talks to a host process over vsock, and `gvproxy` makes the
real outbound connections as a host process:

- The VM (and every box in it) has no routable interface or subnet on the Mac.
- A box's traffic reaches the network sourced from the Mac itself (the gvproxy
  process), indistinguishable at the IP layer from the Mac's own traffic.
- pf matches packets by interface / address / port, not by process, so it
  cannot select "box traffic" to block. A rule blocking the LAN would block the
  Mac's own LAN access too.

## What enables host-level enforcement: a routable box subnet

pf can enforce box-scoped egress once boxes live on a routable vmnet subnet the
Mac can see. The Linux nft ruleset then maps almost line-for-line to pf, loaded
on the Mac, outside the VM:

```pf
# security/egress-host.pf — loaded with `pfctl` on the macOS HOST, outside the
# guest VM(s). Requires boxes on a routable vmnet subnet ($box_subnet on $vmnet_if).
table <lan> const { 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10 }

# Box-initiated traffic to LAN / link-local / metadata / CGNAT — dropped.
block drop in quick on $vmnet_if inet from $box_subnet to <lan>
# Everything else the box initiates (the public internet) — allowed.
pass       in quick on $vmnet_if inet from $box_subnet to any keep state
```

Because pf runs on macOS, a box that escapes its container and the guest VM
still can't flush it without root on the Mac — the same guarantee as the Linux
host firewall.

Two runtimes give boxes such a subnet:

1. **Apple `container`** (`github.com/apple/container`) — isopod's supported
   path. Runs each container in its own lightweight VM on Hypervisor.framework,
   each with its own IP on a vmnet subnet (e.g. `192.168.64.0/24`).
2. **vmnet-based podman/vfkit/krunkit, or `krunvm`** — also yields a routable
   subnet pf can scope to, but needs non-default networking setup (podman
   machine doesn't use vmnet by default) and isn't wired into isopod as an
   engine. Not the recommended path today.

## Reference

See [docs/opt-in-security.md](opt-in-security.md#macos-the-engine-vm-is-already-the-boundary)
for the user-facing setup steps, and `test/macos-egress-check.sh` to validate a
Mac before applying.
