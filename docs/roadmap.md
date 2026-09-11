# Roadmap

Work that is decided but not built. Each item records the shape we settled on and
why, so the reasoning survives between branches. Roughly in the order we would
take them.

Several items come from a microVM hardening assessment run outside this repo
(`sandbox-hardening-report.md`, with ready-to-use profile files in
`isopod-strict/`). Where a finding is named below (F1, F5, B6) it refers to that
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

## Strict hardening profile (`--harden strict`)

`create.sh` already reserves the name and dies with "reserved for a future
release", `share/hardening-sysctl.conf` names the toggles it is waiting on, and
`docs/security-model.md` promises it to the reader. Only the profile itself is
missing.

Four keys, each probed on a 6.12 guest and confirmed to take effect:

| Key | Default profile | Strict |
|---|---|---|
| `kernel.unprivileged_bpf_disabled` | 0 | 1 |
| `kernel.io_uring_disabled` | 0 | 2 |
| `user.max_user_namespaces` | 8081 | 0 |
| `kernel.perf_event_paranoid` | 2 | 3 |
| `vm.unprivileged_userfaultfd` | 0 | pin at 0 |

Two toggles named in the current comment turn out to be moot in a better way:
libkrunfw builds with `CONFIG_MODULES=n` and kexec off, so `modules_disabled` and
`kexec_load_disabled` have nothing to disable. Yama's `ptrace_scope` is not built
in at all and would need a kernel rebuild, so it is out of scope.

Work: add `share/hardening-sysctl-strict.conf`, accept `strict` in `create.sh`,
pick the file in `build_run_args`, and say in the docs what it costs. It breaks
nested containers, io_uring tools, and profiling (bpftrace, perf), which is the
whole reason it is opt-in.

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

## Size the box's own storage

`statfs()` inside a box reports the host filesystem, 1840.8 GiB total and 1204.8
GiB free in the assessment, because the rootfs comes over virtiofs from podman
storage. Two problems in one: it tells the box how big the host disk is, and a box
created without `--disk` can fill the host's disk by writing to its own rootfs.
This is the only denial-of-service in the report that reaches the host.

Options, probably both: have virtiofsd report the guest's own figures rather than
passing `statfs` through, and back the rootfs with a sized volume so the figure is
true. At the very least, make `--disk` the obvious path for anything that writes
a lot and say in the docs that rootfs writes land on host storage.

## Mask the container's `/proc/version` (F1)

The kernel build string names the VMM project, the build distro, the build
machine's timezone, and the toolchain:

```
Linux version 6.12.91 (root@libkrunfw) (gcc (GCC) 16.1.1 ... fc44 ...) ... CEST
```

Two different files, only one of which we can do anything about. The guest's own
`/proc/version` comes from the libkrunfw kernel, and changing it means building
that kernel ourselves with `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST` and
`KBUILD_BUILD_TIMESTAMP` set, which is a much larger piece of work and is not
planned. The container's `/proc/version` is exported to the guest inside the
rootfs, the same way `/proc/cmdline` and `/proc/config.gz` are, and masking it is
one `mask-microvm /proc/version file` line in `security/hardening.conf`.

Note the comment at `security/hardening.conf:154` explains why `/proc/version` is
not in the Tier 1 list: on a shared kernel `uname(2)` gives the release anyway. It
is worth masking under a microVM because the exported copy adds the build host,
distro, timezone, and toolchain that `uname -r` does not.

## Trim the guest device nodes (F5)

`/dev` in a box carries `userfaultfd`, `device-mapper`, `btrfs-control`, `tun`,
`uinput`, `vsock`, `fuse`, `loop-control`, and eight unbound loop devices, none of
which a box with no block storage needs. `userfaultfd` is a well known kernel
exploitation primitive. Drop the nodes from the guest rootfs, pin
`vm.unprivileged_userfaultfd=0`, and consider compiling loop, device-mapper, and
btrfs out of the guest kernel if we ever build one.

## Find out what is exported at `/proc` over virtiofs (F4)

A box shows two mounts at `/proc`: a virtiofs export from the host with the
guest's own procfs mounted on top of it. Nothing reached the export during the
assessment, since it is a different virtiofs device from the root export and
`CapEff=0` denies the mount privileges needed to get underneath, but the defense
is a single mount ordering. Confirm what crun's krun handler is exporting there
and remove it if it is not needed.

## Mask `DirectMap*` in `/proc/meminfo` (F2)

`DirectMap1G` shows the guest's entire RAM is backed by 1 GiB hugepages, which
reveals a host performance setting. Low value, cheap to close, and it belongs
with the other `/proc` masks rather than on its own.

## Re-signing commits that were already remapped

`isopod remap` signs the rewritten commits and probes signing before touching
anything, so a broken setup fails loudly with nothing rewritten. Two gaps remain.

Commits remapped before signing landed (`272c05a`) were never signed, and there is
no way to go back and sign them short of rewriting by hand. A `--sign-only` mode,
or a documented recipe, would cover that.

The probe's failure message is also generic where the most common cause is
specific: `gpg.format=ssh` with a GPG key id in `user.signingkey` makes
`ssh-keygen` treat the key id as a filename, and the error the user sees is
"Couldn't load public key <id>: No such file or directory". Naming that case in
the message would save the diagnosis.

## Check `no-new-privileges` really reaches the guest

`runargs.sh:181` adds `--security-opt no-new-privileges` for every box without
`--sudo`, but on a microVM that flag constrains the VMM process on the host, not
the processes inside the guest. A box created with plain `isopod create` reported
`NoNewPrivs: 0` in the assessment, which fits that reading. The entrypoint already
strips sudo's setuid bit when there is no sudoers entry, which closes the path
that matters most, but the image still ships around a dozen other setuid
binaries (`mount`, `umount`, `su`, `passwd`, `chsh`, `newgrp`).

Confirm what the flag actually does on each tier. If it does not cross the VM
boundary, set `PR_SET_NO_NEW_PRIVS` in the box entrypoint before dropping to the
box user, and drop the setuid bits the box has no use for (B6).
