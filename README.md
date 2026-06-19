# aibox

Disposable, isolated sandboxes for letting AI coding agents run wild — without letting them touch your machine.

`aibox` is a single bash script that creates a Podman (or Docker) container with an SSH server inside, puts your code in it, and turns VSCodium (or Cursor, Windsurf, JetBrains) into a GUI for that container. The IDE's server component, your terminals, and any AI agent extensions all execute *inside* the container. Each sandbox gets its own window color so you can always tell, at a glance, which window is sandboxed and which is your real machine.

## The isolation model

The whole design reduces to one rule: **nothing is ever mounted.** The container cannot see the host filesystem at all. Files cross the boundary in exactly three ways, all explicit:

1. `--repo <url>` — a `git clone` executed *inside* the box.
2. `--copy <path>` / `aibox copy-in` — a one-time **copy** of folders you name. This is your allowlist; nothing you don't list ever enters the box.
3. `aibox export` (whole working tree), `aibox fetch` (git history only), or `git push` from inside — how work gets back out.

So when an agent runs `rm -rf ~`, it deletes a copy. When it fingerprints the machine, it sees the container's hostname, a generic Linux environment, and the container's network identity — and aibox masks the host-revealing `/proc`/`/sys` paths it would otherwise read (drive serials, board model, MACs, boot UUIDs — see [Fingerprint hardening](#fingerprint-hardening)). Additional details:

- SSH is bound to `127.0.0.1` only and uses a dedicated per-box ed25519 keypair with the box's host key pinned. Password auth and root login are disabled in the box's sshd.
- **SSH agent forwarding and X11 forwarding are explicitly disabled** in the generated config, so an agent inside the box cannot borrow your SSH agent to authenticate as you elsewhere.
- With rootless Podman (the recommended engine), even "root" inside the container is just your unprivileged user on the host, remapped.

### What it does NOT protect against — read this

- **Network exfiltration of what's inside the box.** AI agents need network access (APIs, package installs), so the box has it. Anything you copy into the box could be sent out by a misbehaving agent. Only put code/data in the box that you could tolerate leaking, and use narrowly-scoped credentials (e.g., a fine-grained GitHub token for one repo, not your account password or a global SSH key). To create an offline box: `AIBOX_RUN_ARGS="--network=none" aibox create ...`
- **Container escape.** Containers share the host kernel. Rootless Podman makes escapes very hard, but a container is not a VM. For "agent might be actively malicious and sophisticated," use a full VM. For "agent might do dumb destructive things or over-collect data" — the stated goal — this is the right tool.
- **Docker's daemon model.** With Docker (non-rootless), the daemon runs as root; a compromise of the daemon is a compromise of the host. Prefer Podman, or enable Docker rootless mode.

## Fingerprint hardening

A container shares the host's kernel and hardware, so by default a process inside can read a surprising amount about the host through `/proc` and `/sys` — far more than its own hostname. aibox ships a hardening profile that closes the file-based leaks and supports an optional sandboxed runtime for the rest. It's all configured in one declarative file, **[`security/hardening.conf`](security/hardening.conf)** — edit that, not the script.

### What's implemented (Tier 1, on by default)

Every box hides the host-revealing paths below. aibox translates the profile into the right flag for your engine automatically — Podman gets a single `--security-opt mask=…`; Docker (which has no mask flag) gets an empty `tmpfs` per directory and a `/dev/null` bind per file.

| Masked path | Leak it closes |
|---|---|
| `/proc/cmdline` | host boot args — **LUKS volume UUID, root-fs UUID, OS image / ostree hash** |
| `/proc/modules` | loaded host kernel modules (VPNs like WireGuard, DisplayLink, Bluetooth…) |
| `/sys/class/dmi`, `/sys/devices/virtual/dmi`, `/sys/firmware` | SMBIOS: **board model, vendor, BIOS version/date** |
| `/sys/bus/pci` | full host PCI topology (NVMe, Wi-Fi, USB4/Thunderbolt controllers) |
| `/sys/bus/usb` | attached peripherals **with serial numbers** (keyboard, mouse, NIC, dongles) |
| `/sys/class/net` | interface names and **MAC addresses** |
| `/sys/block`, `/sys/class/nvme` | disk models and **factory drive serial numbers** |
| `/sys/class/hwmon`, `/sys/class/thermal`, `/sys/class/drm` | sensor/thermal/GPU identity (a board signature) |

Tier 1 needs **no host setup** — it works on any shared-kernel container, rootless included. Verify from inside a box: after hardening, `cat /proc/cmdline` and `lsblk -o NAME,SERIAL` come back empty/blank.

> aibox launches boxes with `podman run`/`docker run`, not Compose, so the profile above is the live source of truth. If you prefer Compose, [`security/compose.yaml`](security/compose.yaml) expresses the same masks in `podman compose`/`docker compose` form as a reference — it is not executed by the CLI.

> aibox deliberately does **not** add `--cap-drop=ALL`, `--read-only`, or `--security-opt no-new-privileges` here: the box runs `sshd` and gives agents passwordless `sudo apt install` for toolchains, all of which those flags would break. The isolation guarantees in [The isolation model](#the-isolation-model) (no mounts, loopback-only SSH, rootless userns) remain the primary boundary; the masks above are defense-in-depth against *fingerprinting* specifically.

### Tier 2 — sandboxed runtime (opt-in)

For the leaks Tier 1 can't reach (below), aibox can run boxes under a syscall-virtualizing runtime — **gVisor (`runsc`)** — which presents a synthetic `/proc`, `/sys`, `uname`, and CPU to the container instead of the host's. It's **off by default** because it requires host-side setup. Enable it by uncommenting `runtime runsc` in `security/hardening.conf`, or per-box with `AIBOX_RUNTIME=runsc aibox create …`.

**What you must do on the host to use Tier 2** (aibox can pass `--runtime`, but cannot install a runtime for you):

- **Podman:** install gVisor's `runsc`, then register it under `[engine.runtimes]` in `containers.conf` (e.g. `runsc = ["/usr/local/bin/runsc"]`).
- **Docker:** add it to `/etc/docker/daemon.json` (`"runtimes": {"runsc": {"path": "/usr/local/bin/runsc"}}`) and restart the daemon.
- `aibox doctor` warns if a configured runtime isn't found on the host.

Caveats: gVisor is Linux-only (under `podman machine` / Docker Desktop on macOS it runs inside that VM); some syscall-heavy or low-level workloads run slower or are unsupported under it. **Tier 1 only** is the safe default for most users.

### What still can't be mitigated

Even with every mask on, a **plain shared-kernel container cannot hide these** — the app reads them straight from the CPU or the shared kernel, with no file to mask:

- **CPU identity** — model, family, stepping, **microcode**, feature flags, via the `CPUID` instruction. (Masking `/proc/cpuinfo` doesn't stop `CPUID` and breaks build tools, so aibox leaves it readable.)
- **Kernel build string** — `uname -r` always returns the host kernel version.
- **Host boot epoch / boot id** — `/proc/stat`'s `btime` and `/proc/sys/kernel/random/boot_id` are a single value per host boot, identical in every container on that host. (`btime` is left unmasked because masking `/proc/stat` breaks `top`/`htop` and most monitoring.)
- **Timing side channels** — `RDTSC` and clock-skew fingerprints.

**Enabling Tier 2 (gVisor) hides the first three** by virtualizing the syscall layer. Only a true VM boundary closes the timing channels too — use Kata Containers / a microVM, or run aibox on macOS/Windows where Podman already runs inside a VM. Rule of thumb: if your threat model is "a sophisticated, actively malicious agent," use a VM; aibox's container hardening targets "an agent that over-collects host data or does dumb destructive things," which is the stated goal.

## Requirements

- Linux (primary), macOS (via `podman machine` or Docker Desktop), or Windows (via WSL2 — see below)
- `podman` (recommended) or `docker`
- `ssh`, `ssh-keygen`, `ssh-keyscan` (the standard OpenSSH client tools)
- VSCodium with the **Open Remote – SSH** extension (`jeanp413.open-remote-ssh`, on Open VSX). `aibox code` installs it for you if missing. Cursor/Windsurf/VS Code ship their own Remote-SSH and need nothing extra.

Run `aibox doctor` to check your setup.

## Install

The fastest path on any platform is the bundled installer, which detects your
system (including immutable Fedora) and uses the right convention automatically:

```sh
./install.sh            # per-user install, no sudo
./install.sh --system   # system-wide (/usr/local), needs sudo
./install.sh --check     # show what it would do, change nothing
./install.sh --uninstall # remove a previous install
```

It copies the project into a single program directory and symlinks the `aibox`
entry point onto your `PATH`, then tells you if anything (PATH, a container
engine) still needs attention. The manual steps below explain what it does and
cover cases where you'd rather place files yourself.

### Why it's not a one-line curl

aibox is **not a single file** — the `aibox` script needs its `lib/` folder
beside it (that's where the color-merge helper lives). So the install pattern is:
put the whole project in one directory, then make the `aibox` entry point
reachable on your `PATH`. The script resolves its own location through symlinks,
so symlinking the entry point into a bin directory is the clean way to do this —
`lib/` is still found correctly.

The convention used below is the cross-distro standard: program files live in a
per-user "share" directory (`~/.local/share`, the user equivalent of
`/usr/local/share`), and a symlink goes in a "bin" directory that's on `PATH`
(`~/.local/bin`). System-wide installs use `/usr/local/lib` + `/usr/local/bin`.

In all snippets below, replace `<SOURCE>` with wherever you got the project (a
git URL or a local path). The examples assume you have the project directory
available as `./aibox-project`.

### Fedora

```sh
# Per-user (recommended; no sudo)
mkdir -p ~/.local/share ~/.local/bin
cp -r ./aibox-project ~/.local/share/aibox
chmod +x ~/.local/share/aibox/aibox
ln -sf ~/.local/share/aibox/aibox ~/.local/bin/aibox

# Fedora already includes ~/.local/bin on PATH for login shells. If `aibox`
# isn't found, add this to ~/.bashrc:  export PATH="$HOME/.local/bin:$PATH"

sudo dnf install -y podman openssh-clients   # runtime prerequisites
aibox doctor
```

### Immutable Fedora (Silverblue / Kinoite / Sericea / Universal Blue)

On the atomic/immutable Fedora desktops, `/usr` is read-only — but the places
you'd install to are still writable, so aibox installs cleanly *without* layering
anything or rebooting:

- `$HOME` is a symlink to `/var/home` and is fully writable, so the per-user
  layout (`~/.local/share` + `~/.local/bin`) is the recommended path and works
  exactly as on regular Fedora.
- `/usr/local` and `/opt` are symlinks into the always-writable `/var`, so a
  "system-wide" install there also works without touching the immutable image.

```sh
# Per-user (recommended) — identical to regular Fedora, no sudo, no reboot
mkdir -p ~/.local/share ~/.local/bin
cp -r ./aibox-project ~/.local/share/aibox
chmod +x ~/.local/share/aibox/aibox
ln -sf ~/.local/share/aibox/aibox ~/.local/bin/aibox
# (~/.local/bin is already on PATH on the Fedora atomic desktops)

aibox doctor
```

Two things specific to immutable Fedora worth knowing:

- **Podman is already on the host** on these images, which is exactly what aibox
  needs. If for some reason it's missing, layer it with
  `rpm-ostree install podman` (this one does need a reboot). Most users won't
  need to.
- **Install aibox on the host, not inside a Toolbx/Distrobox.** It's tempting to
  put CLI tools in a toolbox on these systems, but aibox orchestrates *host*
  containers via the host's podman — from inside a toolbox it can't reach that
  podman, and your sandboxes would be nested containers. The commands above
  install to the host's `~/.local`, which is correct. (The `install.sh` script
  detects immutable Fedora and prints this same warning.)

```sh
# Per-user (recommended; no sudo)
mkdir -p ~/.local/share ~/.local/bin
cp -r ./aibox-project ~/.local/share/aibox
chmod +x ~/.local/share/aibox/aibox
ln -sf ~/.local/share/aibox/aibox ~/.local/bin/aibox

# On Debian/Ubuntu, ~/.local/bin is on PATH only if it existed at login.
# If `aibox` isn't found after install, either log out and back in, or run:
export PATH="$HOME/.local/bin:$PATH"        # and add the same line to ~/.bashrc

sudo apt update && sudo apt install -y podman openssh-client
aibox doctor
```

System-wide on any of the above (all users, needs sudo):

```sh
sudo cp -r ./aibox-project /usr/local/lib/aibox
sudo chmod +x /usr/local/lib/aibox/aibox
sudo ln -sf /usr/local/lib/aibox/aibox /usr/local/bin/aibox   # /usr/local/bin is on PATH by default
aibox doctor
```

### macOS

```sh
# Homebrew's bin dirs are already on PATH. Use a Homebrew-friendly prefix:
#   Apple Silicon: /opt/homebrew    Intel: /usr/local
PREFIX="$(brew --prefix)"                    # resolves to the right one
mkdir -p "$PREFIX/lib" "$PREFIX/bin"
cp -r ./aibox-project "$PREFIX/lib/aibox"
chmod +x "$PREFIX/lib/aibox/aibox"
ln -sf "$PREFIX/lib/aibox/aibox" "$PREFIX/bin/aibox"

# Container engine (one-time machine setup for the Linux VM Podman runs in):
brew install podman
podman machine init && podman machine start
aibox doctor
```

No Homebrew? Use the per-user layout instead: `cp -r ./aibox-project ~/.local/share/aibox`, symlink into `~/.local/bin`, and add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` (macOS defaults to zsh).

### Windows

Run aibox **inside WSL2** — it's a bash tool and Podman/Docker live in the Linux side. From a WSL2 Ubuntu shell, follow the Ubuntu/Debian instructions above. Then, to drive it from VSCodium:

- **Simplest:** run VSCodium *inside* WSL via WSLg, and everything stays in one world.
- **VSCodium on Windows:** WSL2 forwards `127.0.0.1` ports to Windows, so copy the generated `Host aibox-<name>` block from `~/.config/aibox/ssh_config` (in WSL) into `C:\Users\<you>\.ssh\config`, adjusting the `IdentityFile` / `UserKnownHostsFile` paths to a Windows-accessible copy of those files.

(There's no native PowerShell port; WSL2 is the supported path.)

### Verifying and updating

`aibox doctor` checks for podman/docker, the SSH client tools, and any installed IDEs. To update later, replace the program directory (e.g. `~/.local/share/aibox`) with the new version — the symlink keeps working untouched. To uninstall, remove that directory and the symlink; your boxes' state under `~/.config/aibox` is separate and can be cleaned up with `aibox rm` first.

## Quick start

```sh
# Sandbox around a git repo, teal-tinted windows
aibox create myproj --repo https://github.com/me/myproj --color teal
aibox code myproj          # opens VSCodium connected to the box

# Sandbox from an explicit allowlist of host folders (copied, never mounted)
aibox create scratch --copy ~/src/lib-a --copy ~/notes/specs --color '#b3261e'
aibox code scratch --app cursor

# Day-to-day
aibox list
aibox shell myproj                 # terminal inside the box
aibox copy-in myproj ~/datasets/x  # add more host folders later (still a copy)
aibox export myproj ./out          # pull the whole workspace back out (files)
aibox fetch myproj                 # pull the box's git history into a host clone
aibox stop myproj
aibox rm myproj                    # destroy box + its keys + ssh config entry
```

Every box also becomes a plain SSH host: `ssh aibox-myproj` works from any terminal, and any SSH-aware tool can use it.

### Getting work back out: `export` vs `fetch`

Two ways out, for two situations:

- **`aibox export <name> [dest]`** copies the box's whole working tree (including its `.git`) to a fresh host directory. Good for grabbing everything, including uncommitted files. It refuses to write into an existing path so the export shape stays predictable.
- **`aibox fetch <name> [target-repo]`** brings only **committed git history** across, the clean way — no file merges, no clobbering your working tree. Run it from inside (or pointed at) a host git clone:

  ```sh
  cd ~/code/myproj          # an existing clone on your host
  aibox fetch myproj        # target defaults to the current directory
  ```

  Under the hood it `git bundle`s the box's repo, copies that single file out, and `git fetch`es it in — so the box's branches appear as **remote-tracking refs named `<name>/*`** without touching your local branches. Check one out with:

  ```sh
  git switch -c fingerprint-hardening myproj/fingerprint-hardening
  ```

  `aibox fetch` finds the repo at the box's workspace automatically (or the single git subfolder inside it); pass `--path <in-box-repo>` if your layout is unusual. If the target isn't a git repo, it instead drops a `<name>.bundle` file and prints how to use it. Like `export`, it needs no network and no git remote — it rides the same copy-out boundary.

## Connecting each IDE

**VSCodium (priority).** `aibox code <name>` checks for `jeanp413.open-remote-ssh`, installs it from Open VSX if needed, and launches `codium --folder-uri vscode-remote://ssh-remote+aibox-<name>/home/dev/workspace`. The first connection downloads the VSCodium server *into the container*. Extensions you install in that window (including AI agents like Cline, Continue, Roo, etc.) install and run in the container.

**Cursor / Windsurf / VS Code.** `aibox code <name> --app cursor` (or `windsurf`, `code`). They use the same SSH host entry; their bundled Remote-SSH handles the rest. Note that Cursor's own cloud AI features run wherever Cursor sends them, but the agent's *tool execution* (shell commands, file edits) happens in the container.

**JetBrains.** Open JetBrains Gateway → SSH connection → pick host `aibox-<name>` (it reads your `~/.ssh/config`) → project directory `/home/dev/workspace`. The JetBrains backend IDE runs inside the container. Note the default image is slim; JetBrains backends want more: create with `--memory 6g` and run `aibox shell <name>` then `sudo apt install -y libxext6 libxrender1 libxtst6 libxi6 fontconfig` if the backend complains.

## Window colors

`--color` accepts a preset (`red orange amber green teal blue purple magenta gray`) or any `#rrggbb` hex. Without it, colors auto-rotate so consecutive boxes differ. The script writes `workbench.colorCustomizations` (title bar, status bar, activity bar, plus a `[boxname]` window title) into `.vscode/settings.json` *inside the box's workspace* — merging with, not clobbering, any settings the repo ships (JSONC comments tolerated; unparseable files are backed up first). Because the setting lives in the container, every IDE window attached to that box is tinted, and your local windows are untouched.

## Platform notes

**Linux.** Works out of the box with rootless Podman. This is the best-supported and most-isolated configuration.

**Flatpak VSCodium.** Detected automatically — `aibox code` launches it via `flatpak run com.vscodium.codium` when no native `codium` is on PATH (a native binary wins if both exist). One Flatpak-specific requirement: the Remote-SSH extension runs *inside the Flatpak's own sandbox* on the host, so it must be allowed to read your SSH config and aibox's keys. The Flathub build ships with home access, but if you've tightened it (Flatseal, overrides), aibox will detect the missing permission and print the fix:

```sh
flatpak override --user --filesystem=$HOME/.ssh:ro \
  --filesystem=$HOME/.config/aibox:ro com.vscodium.codium
```

Read-only is sufficient — the extension only needs to read the config and keys. Note the pleasant layering here: the Flatpak sandbox constrains the IDE on the host side, while the container constrains the agents on the workspace side.

**macOS.** Containers run inside the `podman machine` (or Docker Desktop) Linux VM — which on macOS is a bonus: it's a *real* VM boundary between the agent and your Mac. Published ports are forwarded to `127.0.0.1` on the Mac, so everything works identically. One-time setup: `podman machine init && podman machine start`.

**Windows.** Run aibox inside WSL2 (where podman/docker live). Two options for the GUI: (a) run VSCodium inside WSL via WSLg — simplest, everything stays in one world; or (b) run VSCodium on Windows natively — WSL2 forwards `127.0.0.1` ports to Windows, so copy the generated `Host aibox-<name>` block from `~/.config/aibox/ssh_config` (in WSL) into `C:\Users\you\.ssh\config`, adjusting the `IdentityFile`/`UserKnownHostsFile` paths to a Windows copy of those files. A native PowerShell port is a possible future addition; WSL2 is the supported path today.

## Environment variables

`AIBOX_ENGINE` (`podman`|`docker`) — engine override. `AIBOX_CONFIG_DIR` — state location (default `~/.config/aibox`). `AIBOX_BUILD_ARGS` — extra args for `build` (e.g. `--network=host`, `--build-arg http_proxy=...` behind corporate proxies). `AIBOX_RUN_ARGS` — extra args for `run` (e.g. `--network=none` for an offline box, `--userns=keep-id`, custom DNS). `AIBOX_RUNTIME` — enable a Tier 2 sandboxed runtime for the box (e.g. `runsc`), overriding `security/hardening.conf`. `AIBOX_HARDENING_CONF` — path to an alternate [fingerprint-hardening profile](#fingerprint-hardening).

## How state is laid out

The aibox install itself is laid out as:

```
aibox                       # the CLI (bash)
lib/apply_color.py          # window-color merge, run inside the box
security/hardening.conf     # fingerprint-hardening profile (read at create time)
test/                       # bats + pexpect test suite
```

Runtime state lives separately under `~/.config/aibox`:

```
~/.config/aibox/
├── ssh_config              # generated; Include'd from ~/.ssh/config
└── boxes/<name>/
    ├── id_ed25519(.pub)    # this box's dedicated client keypair
    ├── known_hosts         # this box's pinned host key
    └── meta                # engine, image, port, color, created
```

Deleting a box removes its container, its keys, and its SSH config entry. The base image (`localhost/aibox-base:*`) is shared across boxes and rebuilt automatically when the embedded Dockerfile layer changes.

## Customizing the box

The default image is `debian:bookworm-slim` plus sshd, git, curl, python3, and sudo (the in-box user has passwordless sudo by default — it's harmless under rootless Podman and lets agents `apt install` toolchains; pass `--no-sudo` to disable). Use `--image ubuntu:24.04` or any Debian/Ubuntu-based image to change the base. Install language toolchains either interactively (`aibox shell`) or bake your own base image and pass it with `--image`.

## FAQ

**Why SSH instead of the Dev Containers extension?** The Dev Containers extension is Microsoft-proprietary and not licensed for VSCodium. SSH is the lingua franca every IDE speaks, the open-source `Open Remote – SSH` extension is mature, and the same box works for VSCodium, Cursor, Windsurf, JetBrains, and plain terminals simultaneously.

**Is my code safe from the AI vendor?** Whatever code is in the box is visible to agents you run in it, and they may transmit it to their APIs — that's how they work. aibox limits the blast radius to the box's contents; it does not change what an agent does with those contents.

**Can two IDEs attach to the same box?** Yes — it's just SSH. You can have VSCodium and a terminal and JetBrains attached at once.

## Testing

aibox ships a test suite under `test/` using [bats-core](https://github.com/bats-core/bats-core) (vendored, no install needed) plus pexpect for interactive prompts.

Run everything locally:

```sh
test/run.sh              # lint + stubbed bats + interactive (no container engine)
RUN_LIVE=1 test/run.sh   # also runs live end-to-end tests against real podman/docker
```

The suite has four layers: fast unit tests for pure functions, theming/IDE-detection tests, integration tests that stub the container engine to exercise full command flows, an interactive pexpect test for the `rm` confirmation prompt, and an opt-in live suite (`RUN_LIVE=1`) that creates real containers to verify the isolation guarantees.

CI runs via GitLab CI/CD (`.gitlab-ci.yml`): a `lint` stage (shellcheck), a `test` stage (stubbed + interactive, runs anywhere), and a manual `live` stage that needs a podman-capable runner. The config runs identically under [`gitlab-ci-local`](https://github.com/firecow/gitlab-ci-local) for debugging pipelines on your own machine before pushing.
