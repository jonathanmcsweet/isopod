# Installation, platform notes & state layout

This document collects the longer-form installation, platform, and layout
reference for isopod. For the quick install paths (Homebrew and `install.sh`) and
the project overview, see the [README](../README.md).

## Manual installation

### Fedora

```sh
# Per-user (recommended; no sudo)
mkdir -p ~/.local/share ~/.local/bin
cp -r ./isopod-project ~/.local/share/isopod
chmod +x ~/.local/share/isopod/isopod
ln -sf ~/.local/share/isopod/isopod ~/.local/bin/isopod

# Fedora already includes ~/.local/bin on PATH for login shells. If `isopod`
# isn't found, add this to ~/.bashrc:  export PATH="$HOME/.local/bin:$PATH"

sudo dnf install -y podman openssh-clients   # runtime prerequisites
isopod doctor
```

### Immutable Fedora (Silverblue / Kinoite / Universal Blue / Bazzite)

On the atomic/immutable Fedora desktops, `/usr` is read-only — but the places
you'd install to are still writable, so isopod installs cleanly *without* layering
anything or rebooting:

- `$HOME` is a symlink to `/var/home` and is fully writable, so the per-user
  layout (`~/.local/share` + `~/.local/bin`) is the recommended path and works
  exactly as on regular Fedora.
- `/usr/local` and `/opt` are symlinks into the always-writable `/var`, so a
  "system-wide" install there also works without touching the immutable image.

```sh
# Per-user (recommended) — identical to regular Fedora, no sudo, no reboot
mkdir -p ~/.local/share ~/.local/bin
cp -r ./isopod-project ~/.local/share/isopod
chmod +x ~/.local/share/isopod/isopod
ln -sf ~/.local/share/isopod/isopod ~/.local/bin/isopod
# (~/.local/bin is already on PATH on the Fedora atomic desktops)

isopod doctor
```

Two things specific to immutable Fedora worth knowing:

- **Podman is already on the host** on these images, which is exactly what isopod
  needs. If for some reason it's missing, layer it with
  `rpm-ostree install podman` (this one does need a reboot). 

- **Install isopod on the host, not inside a Toolbx/Distrobox.** It's tempting to
  put CLI tools in a toolbox on these systems, but isopod orchestrates *host*
  containers via the host's podman — from inside a toolbox it can't reach that
  podman, and your sandboxes would be nested containers. The commands above
  install to the host's `~/.local`, which is correct. (The `install.sh` script
  detects immutable Fedora and prints this same warning.)

### Debian / Ubuntu

```sh
# Per-user (recommended; no sudo)
mkdir -p ~/.local/share ~/.local/bin
cp -r ./isopod-project ~/.local/share/isopod
chmod +x ~/.local/share/isopod/isopod
ln -sf ~/.local/share/isopod/isopod ~/.local/bin/isopod

# On Debian/Ubuntu, ~/.local/bin is on PATH only if it existed at login.
# If `isopod` isn't found after install, either log out and back in, or run:
export PATH="$HOME/.local/bin:$PATH"        # and add the same line to ~/.bashrc

sudo apt update && sudo apt install -y podman openssh-client
isopod doctor
```

System-wide on any of the above (all users, needs sudo):

```sh
sudo cp -r ./isopod-project /usr/local/lib/isopod
sudo chmod +x /usr/local/lib/isopod/isopod
sudo ln -sf /usr/local/lib/isopod/isopod /usr/local/bin/isopod   # /usr/local/bin is on PATH by default
isopod doctor
```

### macOS

```sh
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

### Windows

Run isopod **inside WSL2** — it's a bash tool and Podman/Docker live in the Linux side. From a WSL2 Ubuntu shell, follow the Ubuntu/Debian instructions above. Then, to drive it from VSCodium:

- **Simplest:** run VSCodium *inside* WSL via WSLg.
- **VSCodium on Windows:** WSL2 forwards `127.0.0.1` ports to Windows, so copy the generated `Host isopod-<name>` block from `~/.config/isopod/ssh_config` (in WSL) into `C:\Users\<you>\.ssh\config`, adjusting the `IdentityFile` / `UserKnownHostsFile` paths to a Windows-accessible copy of those files.

(There's no native PowerShell port; WSL2 is the supported path.)

### Verifying and updating

`isopod doctor` checks for podman/docker, the SSH client tools, and any installed IDEs. To update later, replace the program directory (e.g. `~/.local/share/isopod`) with the new version — the symlink keeps working untouched. To uninstall, remove that directory and the symlink; your containers' state under `~/.config/isopod` is separate and can be cleaned up with `isopod rm` first.

## Window colors

`--color` accepts a preset (`red orange amber green teal blue purple magenta gray`) or any `#rrggbb` hex. Without it, colors auto-rotate so consecutive containers differ. The script writes `workbench.colorCustomizations` (title bar, status bar, activity bar, plus a `[containername]` window title) into `.vscode/settings.json` *inside the container's workspace*. Because the setting lives in the container, every IDE window attached to that container is tinted, and your local windows are untouched.

## Platform notes

**Linux.** Works out of the container with rootless Podman. This is the best-supported and most-isolated configuration.

**Flatpak VSCodium.** Detected automatically — `isopod code` launches it via `flatpak run com.vscodium.codium` when no native `codium` is on PATH (a native binary wins if both exist). One Flatpak-specific requirement: the Remote-SSH extension runs *inside the Flatpak's own sandbox* on the host, so it must be allowed to read your SSH config and isopod's keys. The Flathub build ships with home access, but if you've tightened it (Flatseal, overrides), isopod will detect the missing permission and print the fix:

```sh
flatpak override --user --filesystem=$HOME/.ssh:ro \
  --filesystem=$HOME/.config/isopod:ro com.vscodium.codium
```

**macOS.** Containers run inside the `podman machine` (or Docker Desktop) Linux VM — which is a *real* VM boundary between the agent and your Mac. Published ports are forwarded to `127.0.0.1` on the Mac. One-time setup: `podman machine init && podman machine start`.

**Windows.** Run isopod inside WSL2 (where podman/docker live). Two options for the GUI: (a) run VSCodium inside WSL via WSLg or (b) run VSCodium on Windows natively — WSL2 forwards `127.0.0.1` ports to Windows, so copy the generated `Host isopod-<name>` block from `~/.config/isopod/ssh_config` (in WSL) into `C:\Users\you\.ssh\config`, adjusting the `IdentityFile`/`UserKnownHostsFile` paths to a Windows copy of those files.

## How state is laid out

The isopod install itself is laid out as:

```
isopod                       # the CLI (bash)
lib/apply_color.py          # window-color merge, run inside the container
security/hardening.conf     # fingerprint-hardening profile (read at create time)
test/                       # bats + pexpect test suite
```

Runtime state lives separately under `~/.config/isopod`:

```
~/.config/isopod/
├── ssh_config              # generated; Include'd from ~/.ssh/config
└── containers/<name>/
    ├── id_ed25519(.pub)    # this container's dedicated client keypair
    ├── known_hosts         # this container's pinned host key
    └── meta                # engine, image, port, color, created
```

Deleting a container removes its container, its keys, and its SSH config entry. The base image (`localhost/isopod-base:*`) is built from [`share/Dockerfile`](../share/Dockerfile), shared across containers, and rebuilt automatically when that Dockerfile changes.
