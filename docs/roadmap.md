# Roadmap

Work that is decided but not built. Each item records the shape we settled on and
why, so the reasoning survives between branches. Roughly in the order we would
take them.

Several items come from a microVM hardening assessment run outside this repo
(`sandbox-hardening-report.md`, with ready-to-use profile files in
`isopod-strict/`). Where a finding is named below (F2, F4) it refers to that
report, and the detail here is enough to act on without it.

## Per-box egress allow-list

One allow-list covers every box on the host today, so `isopod egress allow
api.openai.com` for a scraper box opens it for the work box too. The agent
installers already say so out loud, which is how this surfaced.

Settled shape: the second layer becomes per-box rather than gaining a third.
`isopod egress allow <box> <domain>` is the normal form, `isopod egress allow
--all <domain>` is the deliberate host-wide act, and the existing
`egress-allowlist.conf` keeps working as that `--all` layer. The model stays two
layers deep, and the narrow one becomes the default.

Why it is not a small change: tinyproxy holds one filter file per process and has
no per-client rules, so a single shared proxy cannot enforce different lists for
different boxes. Per-box means one proxy per box, or a different proxy. Either
way each box needs a pinned address, which isopod does not do today (there is no
`--ip` in the run args), because the client address is the only handle for
telling boxes apart.

The nft side can stay static and stay cheap. A concatenated set (`ip saddr . tcp
dport { 10.88.7.2 . 8120, ... }`) generated once at `egress apply` covers every
address the subnet can hand out, so creating a box still needs no root, and the
per-box proxies are ordinary host processes. `sudo` stays exactly where it is
today, on the single `egress apply`.

Has to ship with it:

- `isopod info <box>` shows the effective list for that box, otherwise the
  question "why can this box reach it and that one not" becomes guesswork.
- The list lives in box meta, survives `reconfigure` and `upgrade`, and goes away
  with `rm`, the same rule as the rest of box meta.
- `doctor` and `info` say plainly when a box's proxy is not running, because that
  box then has no egress at all. Failing closed is right, but it is a new way for
  a box to be offline.
- The agent installers drop the "one allow-list covers every box on this host"
  line, since it stops being true.

This one needs a real rootful podman host to land safely: per-box proxies, pinned
addresses and a new nft set are all things a stubbed test suite can render but not
prove. Build it with a host in the loop, not blind.

## Desktop apps from a box, Wayland only

`isopod gui <box>` to run a graphical program from inside a box on the host's
display.

Primary route is waypipe over the SSH connection already in place: one app at a
time, drawn by whatever compositor the user runs (GNOME, KDE, Hyprland including
Omarchy, Sway). Fallback for a whole desktop rather than one app is a nested
compositor inside the box with a viewer on the host.

X11 stays off, deliberately and permanently. `X11Forwarding no` in
`share/Dockerfile`, `ForwardX11 no` in both ssh_config entries, and the
`-o ForwardX11=no` on the ssh command line are there on purpose, and this feature
does not reopen them.

Needs: waypipe in the box image (or installed on demand), a host-side check that
waypipe is present, and a clear message when the host session is X11 rather than
Wayland.

## Settled: what is exported at `/proc` over virtiofs (F4)

No longer open. Settled on 2026-09-13 against a real box and the two upstream sources. A microVM
box shows this:

```
21 1 0:20 / /     rw,relatime shared:1 - virtiofs /dev/root rw
23 21 0:21 / /proc rw,relatime shared:5 - virtiofs none     rw
24 23 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:6 - proc proc rw
25 21 0:23 / /sys  rw,nosuid,nodev,noexec,relatime shared:7 - sysfs sysfs rw
```

Neither party adds a second export. crun's krun handler calls
`krun_add_virtiofs2(ctx, tag, "/", shm_size)` exactly once, for the container
rootfs, and libkrun's guest init mounts only `proc` on `/proc`
(`init/init-binary/src/fs.rs`). So device 0:21 is not a separate export of the
host's procfs: it is the container's own `/proc`, surfacing as its own virtiofs
superblock because it is a submount inside the rootfs export, instantiated when
init traversed the directory and then covered by the guest's procfs.

That makes it the container's procfs, in the container's PID namespace, so it
never held the host's process list and the report's "high" rating does not
stand. What it does hold is the per-kernel files, which are the host's values:
`/proc/cmdline`, `/proc/config.gz`, `/proc/modules` and `/proc/version`, all
four masked under a microVM, which is precisely why those masks are not
redundant there.

Residual risk, unchanged: the only things keeping it out of reach are the mount
ordering and `CapEff=0`. Anything that later grants the box `CAP_SYS_ADMIN` or a
user namespace puts it back in play, and the masks are what limit it then.
`test/host-verify.sh` prints the stack for a box you point it at.

## Trim the remaining guest device nodes

The entrypoint drops `mem`, `port`, the per-CPU `msr` and `cpuid` nodes,
`userfaultfd`, `uinput`, `btrfs-control`, `device-mapper`, `loop-control` and the
unbound loop devices on a hardened microVM box.

`/dev/vsock` is still there: it is the guest's transport to the VMM, and nothing
we could run from the host proved that removing it is safe. Establish that, then
either drop it too or record why it stays. `hvc*` and `vport*` stay for the same
reason (console and serial), and `/dev/kmsg` because `kernel.dmesg_restrict`
already gates it.

The stronger version of all of this is compiling loop, device-mapper and btrfs out
of the guest kernel, which means building libkrunfw ourselves. See below.

## Decided against, and why

**Masking `DirectMap*` in `/proc/meminfo` (F2).** The line reveals that the guest's
RAM is backed by 1 GiB hugepages, a host performance setting. It cannot be closed
the way the other `/proc` leaks were: the file the box reads is the guest kernel's
own procfs, generated live, and the mask mechanism only covers the container's
copy underneath it. Masking a single line out of a live procfs file needs a FUSE
overlay, and a static `/proc/meminfo` breaks every memory-aware program in the box.
Low value, no safe mechanism.

**Masking the container's `/proc/meminfo`, `/proc/cpuinfo` and `/proc/stat` under a
microVM.** Free on paper, by the same argument that added `/proc/version`: the box
reads the guest's copy, so the container's is dead weight. The difference is that
the VMM process runs inside that container namespace, and those three files are
exactly the ones a libc, an allocator or the VMM itself may read at startup.
`/proc/version` is safe because nothing reads it programmatically. Revisit only
with a real box to test against.

**Building the libkrunfw guest kernel ourselves.** It would fix the guest's own
`/proc/version` build string (`KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST`,
`KBUILD_BUILD_TIMESTAMP`), let us compile out loop, device-mapper and btrfs, and
build in Yama so `kernel.yama.ptrace_scope` exists for the strict profile. It also
makes isopod responsible for shipping and patching a kernel. Not worth it for what
it closes, which is a fingerprint of libkrunfw's build farm rather than of your
machine.
