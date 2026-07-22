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

Then install the runtime prerequisites and check the result with `isopod doctor`:

- **Fedora:** `sudo dnf install -y podman openssh-clients`. `~/.local/bin` is
  already on `PATH` for login shells; if `isopod` isn't found, add
  `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc`.
- **Debian / Ubuntu:** `sudo apt update && sudo apt install -y podman openssh-client`.
  `~/.local/bin` is on `PATH` only if it existed at login — log out and back in,
  or run `export PATH="$HOME/.local/bin:$PATH"` (and add the same line to `~/.bashrc`).
- **Immutable Fedora (Silverblue / Kinoite / Universal Blue / Bazzite):** the
  per-user steps above work unchanged, with no layering and no reboot — `$HOME`
  is a symlink to the always-writable `/var/home`, and `~/.local/bin` is already
  on `PATH`. Podman ships on these images; if it's somehow missing, layer it with
  `rpm-ostree install podman` (that one does need a reboot). **Install isopod on
  the host, not inside a Toolbx/Distrobox** — isopod orchestrates *host*
  containers via the host's podman, which a toolbox can't reach. (`install.sh`
  detects immutable Fedora and, if it can't find podman or docker either, prints
  this same warning.) For system-wide installs, `/usr/local` and `/opt` are
  symlinks into the writable `/var`, so the steps below also work without
  touching the immutable image.

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
