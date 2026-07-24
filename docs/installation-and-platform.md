# Installation, platform notes & state layout

This document collects the longer-form installation, platform, and layout
reference for isopod. For the quick install paths (Homebrew and `install.sh`) and
the project overview, see the [README](../README.md).

## Manual installation

### Linux, per-user (recommended; no sudo)

The same steps work on every supported distro:

```sh
mkdir -p ~/.local/share ~/.local/bin
cp -r ./isopod-project ~/.local/share/isopod
chmod +x ~/.local/share/isopod/isopod
ln -sf ~/.local/share/isopod/isopod ~/.local/bin/isopod
```

Then install the runtime prerequisites for your distro **family** and check the
result with `isopod doctor`. Derivatives follow their parent — isopod reads `ID`
and then `ID_LIKE` from `/etc/os-release`, so a distro not named below is
handled as whatever family it declares.

| Family | Covers (non-exhaustive) |
| --- | --- |
| [Debian](#debian-family) | Ubuntu, Linux Mint, Pop!_OS, Zorin OS, MX Linux, elementary OS, Raspberry Pi OS |
| [Fedora](#fedora-family) | RHEL, CentOS Stream, AlmaLinux, Rocky Linux, Nobara |
| [Fedora immutable](#fedora-immutable-family) | Silverblue, Kinoite, Sericea, Bazzite, Bluefin, Aurora (Universal Blue) |
| [Arch](#arch-family) | Manjaro, EndeavourOS, CachyOS, Garuda, ArcoLinux |
| [Gentoo](#gentoo-family) | Calculate Linux, Redcore Linux |

#### Debian family

```sh
sudo apt update && sudo apt install -y podman openssh-client
```

`~/.local/bin` is on `PATH` only if it existed at login — log out and back in, or
run `export PATH="$HOME/.local/bin:$PATH"` (and add the same line to `~/.bashrc`).

#### Fedora family

```sh
sudo dnf install -y podman openssh-clients
```

`~/.local/bin` is already on `PATH` for login shells; if `isopod` isn't found, add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc`.

#### Fedora immutable family

The per-user steps above work unchanged, with no layering and no reboot — `$HOME`
is a symlink to the always-writable `/var/home`, and `~/.local/bin` is already on
`PATH`. Podman ships on these images; if it's somehow missing, layer it with
`rpm-ostree install podman` (that one does need a reboot). **Install isopod on the
host, not inside a Toolbx/Distrobox** — isopod orchestrates *host* containers via
the host's podman, which a toolbox can't reach. (`install.sh` detects an ostree
deployment and, if it can't find podman or docker either, prints this same
warning.) For system-wide installs, `/usr/local` and `/opt` are symlinks into the
writable `/var`, so the steps below also work without touching the immutable image.

#### Arch family

```sh
sudo pacman -S --needed podman openssh
sudo pacman -S --needed netavark aardvark-dns passt fuse-overlayfs   # rootless networking
```

Podman's rootless networking pieces are separate packages here. Arch does not give
new accounts a subuid/subgid range, so add one before the first box (see
[Rootless podman needs a subuid/subgid range](#rootless-podman-needs-a-subuidsubgid-range)).
`~/.local/bin` is on `PATH` via `/etc/profile.d` on a current install; if `isopod`
isn't found, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc`.

#### Gentoo family

```sh
sudo emerge --ask app-containers/podman net-misc/openssh \
  app-containers/netavark app-containers/aardvark-dns net-misc/passt
```

Build podman with `USE="rootless"` so the setuid `newuidmap`/`newgidmap` helpers
from `sys-apps/shadow` are installed — without them rootless containers cannot map
users. Gentoo also does not create a subuid/subgid range with the account (see
below), and a custom kernel needs `CONFIG_USER_NS` plus cgroup v2 for rootless
podman. Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` if
`~/.local/bin` isn't already on `PATH`.

On an OpenRC system everything works except two egress features: `isopod egress
allow-list` and `isopod egress persist` install systemd units, so they need
systemd; `egress lan-deny` (plain nftables) does not.

### Rootless podman needs a subuid/subgid range

Rootless podman maps the container's users through a subordinate UID/GID range
assigned to your account in `/etc/subuid` and `/etc/subgid`. Fedora and
Debian/Ubuntu create one when the account is created; **Arch and Gentoo do not**,
and podman then fails with `no subuid ranges found for user`. Add a range once:

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate     # let podman pick up the new range
```

`install.sh` and `isopod doctor` both check for this and print the same fix.

### Linux, system-wide (all users, needs sudo)

```sh
sudo cp -r ./isopod-project /usr/local/lib/isopod
sudo chmod +x /usr/local/lib/isopod/isopod
sudo ln -sf /usr/local/lib/isopod/isopod /usr/local/bin/isopod   # /usr/local/bin is on PATH by default
isopod doctor
```

### macOS

```sh
# isopod needs bash >= 4.4; macOS's stock /bin/bash is 3.2. The Homebrew
# formula pulls this in automatically — a manual install must do it itself:
brew install bash

# Homebrew's bin dirs are already on PATH. Use a Homebrew-friendly prefix:
#   Apple Silicon: /opt/homebrew    Intel: /usr/local
PREFIX="$(brew --prefix)"                    # resolves to the right one
mkdir -p "$PREFIX/lib" "$PREFIX/bin"
cp -r ./isopod-project "$PREFIX/lib/isopod"
chmod +x "$PREFIX/lib/isopod/isopod"
ln -sf "$PREFIX/lib/isopod/isopod" "$PREFIX/bin/isopod"

# Container engine (one-time machine setup for the Linux VM Podman runs in):
brew install podman
podman machine init && podman machine start
isopod doctor
```

No Homebrew? Use the per-user layout instead: `cp -r ./isopod-project ~/.local/share/isopod`, symlink into `~/.local/bin`, and add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` (macOS defaults to zsh).

### Verifying and updating

`isopod doctor` checks for podman/docker, the SSH client tools, and any installed IDEs. To update later, replace the program directory (e.g. `~/.local/share/isopod`) with the new version — the symlink keeps working untouched. To uninstall, remove that directory and the symlink; your containers' state under `~/.config/isopod` is separate and can be cleaned up with `isopod rm` first.

## Window colors

`--color` accepts a preset (`red orange amber green teal blue purple magenta gray`) or any `#rrggbb` hex. Without it, isopod derives a preset deterministically from a hash of the box's name — the same name always gets the same color, and it's unaffected by other boxes being created or deleted (with 9 presets, two names can still land on the same one). The script writes `workbench.colorCustomizations` (title bar, status bar, activity bar, plus a `[containername]` window title) into `.vscode/settings.json` *inside the container's workspace*. Because the setting lives in the container, every IDE window attached to that container is tinted, and your local windows are untouched.

## Platform notes

**Linux.** Works out of the container with rootless Podman. This is the best-supported and most-isolated configuration.

**Flatpak VSCodium.** Detected automatically — `isopod code` launches it via `flatpak run com.vscodium.codium` when no native `codium` is on PATH (a native binary wins if both exist). One Flatpak-specific requirement: the Remote-SSH extension runs *inside the Flatpak's own sandbox* on the host, so it must be allowed to read your SSH config and isopod's keys. The Flathub build ships with home access, but if you've tightened it (Flatseal, overrides), isopod will detect the missing permission and print the fix:

```sh
flatpak override --user --filesystem=$HOME/.ssh:ro \
  --filesystem=$HOME/.config/isopod:ro com.vscodium.codium
```

**macOS.** Containers run inside the `podman machine` (or Docker Desktop) Linux VM — a *real* VM boundary between the agent and your Mac. Published ports are forwarded to `127.0.0.1` on the Mac. One-time setup: `podman machine init && podman machine start`.

Because that VM — not the Mac — is where boxes actually run, the egress firewall and Tier-3 virtualization work differently on macOS: `isopod egress apply` enforces inside the VM (or on the Mac itself via pf when boxes run under Apple `container`), and the engine VM already gives plain containers a hardware boundary. See [opt-in-security.md](opt-in-security.md#macos-the-engine-vm-is-already-the-boundary) and [macos-host-egress.md](macos-host-egress.md).

## How state is laid out

The isopod install itself is laid out as:

```
isopod                       # the CLI entry point (globals + module loader + main)
lib/isopod.d/               # the CLI's function modules, sourced by isopod
lib/apply_color.py          # window-color merge, run inside the container
security/hardening.conf     # fingerprint-hardening profile (read at create time)
test/                       # bats + pexpect test suite
```

Runtime state lives separately under `~/.config/isopod`:

```
~/.config/isopod/
├── ssh_config              # generated; Include'd from ~/.ssh/config
└── boxes/<name>/
    ├── id_ed25519(.pub)    # this box's dedicated client keypair
    ├── known_hosts         # this box's pinned (trust-on-first-use) host key
    ├── config.yaml         # readable, reconfigurable settings (Compose-shaped)
    └── meta                # engine, image, base, sudo, port, color, created, memory, cpus, expose
```

Deleting a box (`isopod rm`) removes its container, its keys, its SSH config entry, and its snapshot images. Shared base images (`localhost/isopod-base:*`) and `--dockerfile` images (`localhost/isopod-user:*`) are left in place; reclaim unreferenced ones with `isopod gc`. The base image is built from [`share/Dockerfile`](../share/Dockerfile), shared across boxes, and rebuilt automatically when that Dockerfile changes.
