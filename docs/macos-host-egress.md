# macOS host-level egress: enforcing *outside* the guest VM

## Status (implemented, experimental)

The host-`pf` backend described below is now wired in isopod (branch
`macos-egress-and-tier3`) and selected automatically on macOS when a routable box
subnet is available:

- `isopod egress apply` renders `security/egress-host.pf` (box subnet substituted)
  into the `com.isopod.egress` pf anchor on the Mac host, references it from
  `/etc/pf.conf` (so its rules re-parse on boot), and enables pf. `isopod egress
  persist` additionally installs a `RunAtLoad` LaunchDaemon
  (`/Library/LaunchDaemons/com.isopod.egress.plist`) that runs `pfctl -E -f
  /etc/pf.conf` at boot, because macOS re-reads pf.conf on boot but does not
  re-enable pf on its own. `status`, `rules`, `persist`/`unpersist` all follow the
  pf backend.
- Backend selection: `egress_macos_backend()` returns pf when `pfctl` plus a
  routable box subnet are available (Apple `container` present, `ENGINE=container`,
  or `ISOPOD_PF_SUBNET` set); otherwise the weaker **in-VM nft** fallback. Override
  with `ISOPOD_EGRESS_BACKEND=pf|vm`.
- Apple `container` is recognised as an experimental engine: `isopod doctor`
  reports it and the host-pf availability.

### Box lifecycle port

Because isopod drives every box operation over SSH, the engine-specific surface for
the lifecycle is small. 
- `box_ssh_addr()` resolves a box's SSH target per engine: `127.0.0.1 + published
  port` for podman/docker (unchanged), or the box's vmnet IP + in-box sshd port
  for Apple `container` (`container_box_ip()` parses `container inspect`). `box_ssh`,
  `scan_host_key`, `write_ssh_include`, and the generated `~/.ssh/config` entry all
  now go through it, so VSCodium Remote-SSH targets the box's real IP directly —
  which also sidesteps the loopback port-forward fragility entirely.

Still to port (the `container` CLI specifics — highest risk to write without a Mac,
so left for on-device iteration): image build (`container build`), box run
(`container run` flags: `--network`, name, env, volumes), and `rm`/`list`. Once
those land, `ISOPOD_ENGINE=container isopod create` + `isopod code` will bring up a
per-box VM with host-pf egress and a directly-SSH'able IP.

---


## The problem with the in-VM approach

Loads the nft ruleset **inside the podman machine VM**. That is outside the box 
container, so an in-box agent with root + passwordless sudo cannot flush it — it 
satisfies the "root in the box can't turn it off" philosophy.

But it does not satisfy the stronger guarantee the Linux design targets:
enforcement on a boundary the box cannot cross. The nft rules live in that VM's
root netns — one container escape away from the agent. On Linux a Tier-3 box
would have to escape a microVM first, and the rules sit on the host beyond that.

Egress must be enforced on the macOS host, outside every guest VM — where disabling 
it would require compromising macOS itself, not just escaping a Linux guest.

## Why the Mac host can't filter podman-machine boxes today

Podman machine on macOS uses `gvproxy` (gvisor-tap-vsock): user-mode
networking. The VM talks to a host process over vsock, and `gvproxy` makes the
real outbound connections as a host process:

- The VM (and every box in it) has no routable interface or subnet on the Mac.
- A box's traffic reaches the network sourced from the Mac itself (the gvproxy
  process), indistinguishable at the IP layer from your own Mac traffic.
- pf matches packets by interface / address / port — not by process — so it
  cannot select "box traffic" to block. A rule blocking the LAN would block *your
  Mac's* LAN access too.

## What does enable host-level enforcement: a routable box subnet

pf can enforce box-scoped egress the moment boxes live on a routable vmnet
subnet the Mac can see. Then the Linux nft ruleset maps almost line-for-line to
pf, loaded on the Mac, outside the VM:

```pf
# security/egress-host.pf — loaded with `pfctl` on the macOS HOST, outside the
# guest VM(s). Requires boxes on a routable vmnet subnet ($box_subnet on $vmnet_if).
table <lan> const { 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10 }

# Box-initiated traffic to LAN / link-local / metadata / CGNAT — dropped.
# Per the Apple container thread, the match is on the INBOUND direction at the
# vmnet interface, with the box subnet as the source.
block drop in quick on $vmnet_if inet from $box_subnet to <lan>
# Everything else the box initiates (the public internet) — allowed.
pass       in quick on $vmnet_if inet from $box_subnet to any keep state
```

Because pf runs on macOS, a box that escapes its container and the guest VM
still cannot flush it without root on the Mac. This is the true analog of the
Linux host firewall.

Two runtimes give boxes such a subnet:

1. Apple `container` (`github.com/apple/container`). Runs each container in its
   own lightweight VM on Hypervisor.framework, each with its own IP on a vmnet
   subnet (e.g. `192.168.64.0/24`).

2. vmnet-based podman/vfkit/krunkit or `krunvm`. A vmnet network (not gvproxy)
   also yields a routable subnet pf can scope to. More configuration, and podman
   machine does not use vmnet by default.

## Options for isopod

| Direction | Egress enforced on… | Tier-3? | Cost |
| --- | --- | --- | --- |
| **A. Apple `container` engine backend** | macOS host (pf, per-box subnet) | Yes (per-box VM) | New engine backend in isopod (like the krunvm idea, but also solves egress) |
| **B. vmnet networking for podman/krunvm + pf** | macOS host (pf, vmnet subnet) | Only with krunvm/nested | Non-default networking setup; pf apply path |
| **C. Keep in-VM nft** | podman VM (not escape-proof) | No | Done; weakest of the three |
