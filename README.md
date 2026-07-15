# Isopod

[![CI](https://github.com/jonathanmcsweet/isopod/actions/workflows/ci.yml/badge.svg)](https://github.com/jonathanmcsweet/isopod/actions/workflows/ci.yml)

`isopod` creates a sandbox with your code in it to safely develop with LLMs using an IDE of your choice ([VSCodium](https://vscodium.com/) is recommended).

<img width="1920" height="1080" alt="Screenshot From 2026-07-09 16-44-49" src="https://github.com/user-attachments/assets/5925e432-1f9c-4347-b289-54049c6be2f1" />

## Key Features 
- [VSCodium](https://vscodium.com/)'s server component and extensions are limited to the container
- Hardening options to prevent hardware fingerprinting and security exploits
- Copying and exporting to your local host instead of binding to your personal folders
- MicroVMs and allow-lists when extra hardening is needed
- Completely offline containers if desired

## Install

### Homebrew (macOS / Linux)

```sh
brew tap jonathanmcsweet/isopod
brew install isopod          # or: brew install --HEAD isopod  (latest master)
```

### install.sh (any Linux/macOS)

```sh
./install.sh            # per-user install, no sudo
./install.sh --system   # system-wide (/usr/local), needs sudo
./install.sh --check     # show what the installer will do
./install.sh --uninstall # remove a previous install
```

`install.sh` also drops in shell completions (best-effort) and points your editor
at the `Open Remote – SSH` extension. Tab-completion covers subcommands, options,
and your existing box names.

### Manual installation

Don't use Homebrew? Per-platform manual install steps (Fedora,
immutable Fedora, Debian/Ubuntu, system-wide, macOS) and how to
verify and update an install live in
**[docs/installation-and-platform.md](docs/installation-and-platform.md)**.

## Quick start

```sh
# Sandbox around a git repo, teal-tinted windows
isopod create myproj --repo https://github.com/me/myproj --color teal
isopod code myproj          # opens VSCodium connected to the container

# Sandbox from an explicit allowlist of host folders to copy
isopod create scratch --copy ~/src/lib-a --copy ~/notes/specs --color '#b3261e'
isopod code scratch --app cursor

# Day-to-day
isopod list
isopod shell myproj                 # terminal inside the container
isopod copy-in myproj ~/datasets/x  # add more host folders later (still a copy)
isopod export myproj ./out          # pull the whole workspace back out (files)
isopod fetch myproj                 # pull the container's git history into a host clone
isopod remap myproj --name "Me" --email me@x.com  # fix container commit identity after fetch
isopod stop myproj
isopod rm myproj                    # destroy container + its keys + ssh config entry
```

## Requirements

- Linux (primary) or macOS (via `podman machine` or Docker Desktop)
- `bash` >= 4.4.
- `podman` or `docker`
- `ssh`, `ssh-keygen`, `ssh-keyscan` (the standard OpenSSH client tools)
- An IDE
  - VSCodium is recommended with the [Open Remote – SSH extension](https://open-vsx.org/extension/jeanp413/open-remote-ssh), on Open VSX).
  - Cursor/Windsurf/VS Code ship their own Remote-SSH but have or may have telemetry that reveals information
    about your host system


## Getting work back out: `export` vs `fetch`

Two ways out, for two situations: Both run over the box's SSH connection, so the box *must be running* as files are moved as a tar stream over SSH.

- `isopod export <name> [dest]` copies the container's whole working tree (including its `.git`) to a fresh host directory. It will not write into an existing path so the export shape stays predictable.
- `isopod fetch <name> [target-repo]` brings *only the committed git history* across (no file merges, no overwriting your working tree).

  ```sh
  cd ~/code/myproj          # an existing clone on your host
  isopod fetch myproj        # target defaults to the current directory
  ```

  Under the hood it `git fetch`es straight from the container over its SSH remote. The container's branches appear as remote-tracking refs named `<name>/*` without touching your local branches. Check one out with:

  ```sh
  git switch -c fingerprint-hardening myproj/my-branch-name
  ```

  - `isopod fetch` finds the repo at the container's workspace automatically (or the single git subfolder inside it)
  - pass `--path <in-container-repo>` if your layout is unusual.
  - If the target isn't a git repo, it instead drops a `<name>.bundle` file and prints how to use it. Like `export`, it needs no network and no git remote.

### Rewriting git logs
  - `isopod remap <name> [target-repo]` helps for sandboxes that don't set a git identity, so commits made inside one carry whatever was configured there (often a throwaway `dev@<container>`)
  - this maps them to your real name / email while preserving commit messages and author / committer dates:

  ```sh
  isopod remap myproj --name "Ada Lovelace" --email ada@example.com
  ```

  - Only commits matching the old identity are touched — pass `--old-email <e>` (and optionally `--old-name <n>`)
  - Set it explicitly, or let it auto-detect from the still-running container
  - The new identity defaults to your host `git config` (override with `--name`/`--email` or `ISOPOD_GIT_NAME`/`ISOPOD_GIT_EMAIL`)
  - To remap several identities at once, list `old -> new` rules in `--remap-file <file>` (or `~/.config/isopod/remap`)
  - The rewrite is scoped to the container's `<name>/*` refs, so *your own branches are never touched*
  - The originals are snapshotted under `refs/remap-backup/` so you can undo.
  - It uses [`git-filter-repo`](https://github.com/newren/git-filter-repo) when installed, otherwise a built-in `git fast-export`→`fast-import` rewrite that needs only core git plus `python3`.
  - See **[docs/remap.md](docs/remap.md)** for the full details.

## FAQ

- Why so much emphasis on VSCodium? Because we can easily evaluate the code and extension security boundaries and verify that VSCodium does not scan your host device to pass of for telemetry or fingerprinting. Proprietary IDEs may be taking telemetry from your host device even though your code and AI agent are in the sandbox.
- Will you be explicitly supporting other Open Source IDEs? Yes permitted I can reasonably verify they don't take telemetry and have boundaries around extensions that prevent them from taking telemetry off of your host device.
- Why SSH instead of the Dev Containers extension? The Dev Containers extension is Microsoft-proprietary and not licensed for VSCodium. The open-source `Open Remote – SSH` extension is mature, and the same container works for VSCodium, Cursor, Windsurf, JetBrains, and plain terminals simultaneously.
- Is my code safe from the AI vendor? Whatever code is in the container is visible to agents you run in it, and they may transmit it to their APIs — that's how they work. Isopod limits the blast radius to the container's contents; it does not change what an agent does with those contents.
Can two IDEs attach to the same container? Yes — it's just SSH. You can have VSCodium and a terminal and JetBrains attached at once.

## The isolation model

The container cannot see the host filesystem. Files cross the boundary in five ways:

1. `--repo <url>` — a `git clone` executed *inside* the container.
2. `--copy <path>` / `isopod copy-in` — a one-time **copy** of folders you name.
3. `isopod export` to copy changes back to the host machine
4. `isopod fetch` git history copied back to your local machine
5. `git push` to your remote server

We have some mitigations for a snooping AI agent fingerprinting your host machine from the container. It sees the container's hostname, a generic Linux environment, and the container's network identity — and isopod masks the host-revealing `/proc`/`/sys` paths that common tools read (boot UUIDs, board model, and the `lsblk`/`lspci`/`ip` views — see [Fingerprint hardening](#fingerprint-hardening)). Additional details:

- SSH is bound to `127.0.0.1` only and uses a dedicated per-container ed25519 keypair. The container's host key is pinned on first use (trust-on-first-use); if an already-pinned box ever presents a different key, isopod flags it. Password auth and root login are disabled in the container's sshd.
- SSH agent forwarding and X11 forwarding are explicitly disabled in the generated config, so an agent inside the container cannot borrow your SSH agent to authenticate as you elsewhere.
- With rootless Podman (the recommended engine), even "root" inside the container is just your unprivileged user on the host, remapped.

### What it does NOT protect against

- **Network exfiltration of what's inside the container.** AI agents need network access (APIs, package installs), so the container has it unless you've created an offline container. Anything you copy into the container could be sent out by a misbehaving agent. Only put code/data in the container that you could tolerate leaking, and use narrowly-scoped credentials. To narrow this, [`egress allow-list`](docs/opt-in-security.md#network-egress-allow-list-egress-allow-list) forces the box through a host-side filtering proxy that permits only allow-listed hostnames — it limits, but does not eliminate, exfiltration (a secret can still be sent *into* an allowed host). Reconnaissance in the *other* direction — a rogue agent scanning your **local network**, the host, or cloud metadata — can be blocked with host-enforced [network egress isolation](docs/opt-in-security.md#network-egress-isolation-egress-lan-deny), while keeping published ports and public internet working.

- **A misbehaving agent inside the container.** By default the in-container user has **passwordless `sudo`** (so agents can `apt install` toolchains), which makes the agent effectively root *within the container*. Your host is still protected by the isolation model above — but anything inside the container (including data you copied in) is fully exposed to it. If you don't need the agent to have root, create the container with **`--no-sudo`** to drop that privilege — you can still add system packages from the host with [`isopod install`](#adding-a-system-package-without-a-rebuild-isopod-install), so lockdown isn't a dead end for dependencies. The container also intentionally keeps Linux capabilities (no `--cap-drop=ALL`), since `sshd` and `sudo` need them — see [Fingerprint hardening](#fingerprint-hardening).

- **Container escape.** Containers share the host kernel. Rootless Podman makes escapes very hard, but a container is not a VM. For "agent might be actively malicious and sophisticated," use a full VM. For "agent might do dumb destructive things or over-collect data" this is the right tool.

- **Docker's daemon model.** With Docker (non-rootless), the daemon runs as root; a compromise of the daemon is a compromise of the host. Enable Docker rootless mode to avoid this.

## Fingerprint hardening

A container shares the host's kernel and hardware, so by default a process inside can read a surprising amount about the host through `/proc` and `/sys` — far more than its own hostname. Isopod ships a hardening profile that closes the file-based leaks and supports an optional sandboxed runtime for the rest. The shipped defaults live in **[`security/hardening.conf`](security/hardening.conf)** — a read-only baseline you don't edit (package upgrades replace it). To customize, drop an override file at **`~/.config/isopod/hardening.conf`** that *layers* on top of the baseline with `mask` / `unmask` / `runtime` / `no-runtime` directives (so you keep getting new masks on upgrade), or toggle the runtime per-run with `ISOPOD_RUNTIME=runsc`.

### What's implemented

Every container masks the host-revealing paths below — the ones common discovery tools (`lsblk`, `lspci`, `ip`, DMI readers) actually read. Podman gets a single `--security-opt mask=…` covering files and directories. Docker gets an empty `tmpfs` per directory; it **cannot** mask `/proc` files — runc rejects bind mounts onto arbitrary `/proc` paths — so `/proc/cmdline` and `/proc/modules` stay readable on Docker (isopod warns at create). Use rootless podman or a Tier 2/3 runtime to close those on Docker.

| Masked path | Data it obfuscates |
|---|---|
| `/proc/cmdline` *(podman)* | host boot args — **LUKS volume UUID, root-fs UUID, OS image / ostree hash** |
| `/proc/modules` *(podman)* | loaded host kernel modules (VPNs like WireGuard, DisplayLink, Bluetooth…) |
| `/sys/class/dmi`, `/sys/devices/virtual/dmi`, `/sys/firmware` | SMBIOS: **board model, vendor, BIOS version/date** |
| `/sys/bus/pci` | the `lspci` view of host PCI topology (NVMe, Wi-Fi, USB4/Thunderbolt controllers) |
| `/sys/bus/usb` | the tool-visible list of attached peripherals (keyboard, mouse, NIC, dongles) |
| `/sys/class/net` | the box's own interface name/MAC (host NICs are already hidden by the box's netns) |
| `/sys/block`, `/sys/class/block`, `/sys/class/nvme` | the `lsblk` view of disk models and factory serial numbers |
| `/sys/class/hwmon`, `/sys/class/thermal`, `/sys/class/drm` | sensor/thermal/GPU identity (a board signature) |

Verify from inside a container: after hardening, `cat /proc/cmdline` (podman) and `lsblk -o NAME,SERIAL` come back empty/blank.

> **These masks close the *alias* directories, not the whole device tree.** `/sys/devices/` is not namespaced, and only its DMI subtree is masked — so a reader walking `/sys/devices/.../serial` or `/sys/devices/pci*/*/vendor` directly can still recover PCI/USB/disk identity (`grep -r . /sys/devices` disproves any "serials are hidden" reading). Masking the whole tree is impractical (dynamic paths; it also holds CPU/cgroup data tools need). To actually close it, run the box under a **Tier 2/3 runtime** (`runsc`/`kata`/`krun`), which presents a synthetic `/sys`. `verify-host-isolation.sh` probes the device tree directly so it can't be fooled by masking only the aliases.

> **Under a Tier 3 microVM, isopod skips these masks entirely.** The guest has its own kernel and only virtual devices (synthetic DMI, a virtio NIC/PCI bus), so there is no host `/proc`/`/sys` data to mask — the VM is the boundary, and the masks would protect nothing there. The masks are a container-tier (Tier 1/2) measure.

> isopod launches containers with `podman run`/`docker run`, not Compose, so the profile above is the live source of truth. If you prefer Compose, [`security/compose.yaml`](security/compose.yaml) expresses the same masks in `podman compose`/`docker compose` form as a reference — it is not executed by the CLI.

> isopod deliberately does **not** add `--cap-drop=ALL`, `--read-only`, or `--security-opt no-new-privileges` here: the container runs `sshd` and gives agents passwordless `sudo apt install` for toolchains, all of which those flags would break. The isolation guarantees in [The isolation model](#the-isolation-model) (no mounts, loopback-only SSH, rootless userns) remain the primary boundary; the masks above are defense-in-depth against *fingerprinting* specifically.

### Security defaults and how to adjust them
See **[docs/opt-in-security.md](docs/opt-in-security.md)** for details and tuning:

- **microVM by default** — `isopod create` runs the box in a per-box guest kernel behind a KVM boundary (Kata) when a virtio-net microVM runtime and `/dev/kvm` are available. If not, it falls back to gVisor (`runsc`), then a plain container, with a warning. Pass **`--container`** to force a plain shared-kernel container. (`krun` is another microVM option; isopod runs it with **passt** (`krun.use_passt=1`) for a real virtio-net stack so `isopod code` works — libkrun's *default* TSI networking stalls the SSH port-forward the IDE uses, which is why isopod forces passt. Kata is preferred when present; krun is auto-selected when it is the only microVM available.)
- **Network egress allow-list by default (`egress allow-list`)** — a host-side filtering proxy is the box's only route out and permits only allow-listed hostnames, to limit data exfiltration. When it can't be enforced (rootless engine, firewall/proxy not loaded) a default-on box degrades with a warning (allow-list → lan-deny → open). Turn it off with `ISOPOD_EGRESS=off` or `no-egress`.
- **gVisor (`runsc`)** — the Tier 2 fallback / an explicit `runtime runsc`: a syscall-virtualizing runtime that hides CPU/kernel/boot identity while sharing the host kernel.
- **Network egress isolation (`egress lan-deny`)** — the lighter mode / degrade target: a host firewall that stops a rogue agent from mapping your LAN, the host, cloud metadata, or internal DNS, while keeping published ports and public internet working.

### What still can't be mitigated

Even with every mask on, a **plain shared-kernel container cannot hide these** — the app reads them straight from the CPU or the shared kernel, with no file to mask:

- **CPU identity** — model, family, stepping, **microcode**, feature flags, via the `CPUID` instruction. (Masking `/proc/cpuinfo` doesn't stop `CPUID` and breaks build tools, so isopod leaves it readable.)
- **Kernel build string** — `uname -r` (a syscall, no file to mask) always returns the host kernel version; `/proc/version` adds the build host/toolchain string.
- **Host RAM size** — `/proc/meminfo` (masking it breaks build tools and most memory-aware programs, so it's left readable).
- **The `/sys` device tree** — PCI/USB/NVMe/disk identity under `/sys/devices/` (only its DMI subtree is masked; see the note above). Not namespaced, so a plain container can read it directly.
- **Host boot epoch / boot id** — `/proc/stat`'s `btime` and `/proc/sys/kernel/random/boot_id` are a single value per host boot, identical in every container on that host. (`btime` is left unmasked because masking `/proc/stat` breaks `top`/`htop` and most monitoring.)
- **Timing side channels** — `RDTSC` and clock-skew fingerprints.

A **Tier 2 runtime** (gVisor `runsc`) already presents a synthetic `/proc`/`/sys`, closing the device tree, `/proc/version`, and boot id. A **Tier 3 microVM runtime** (Kata or krun) also closes `uname`, RAM/CPU identity, and the timing channels — the box runs on its own guest kernel behind a hardware boundary. See [docs/opt-in-security.md](docs/opt-in-security.md#microvm-runtimes-kata-krun--tier-3).

Rule of thumb: if your threat model is "a sophisticated, actively malicious agent," use a Tier 3 microVM runtime (or a full VM); isopod's container hardening targets "an agent that over-collects host data or does dumb destructive things."

### Kernel attack-surface hardening (`--harden`)

Beyond the fingerprint masks, isopod applies a small **kernel-hardening profile to every box by default** — a set of low-impact guest sysctls that shrink kernel attack surface without changing how development feels. Because these are guest-*kernel* settings, they take effect on **microVM boxes** (which have their own kernel). A plain container shares the host kernel, so isopod never sets sysctls there — that would change the host — and it keeps the engine's default seccomp/isolation instead.

The default profile sets `kernel.kptr_restrict=2` (hide kernel pointers), `kernel.dmesg_restrict=1` (root-only `dmesg`), `net.core.bpf_jit_harden=2` (harden the eBPF JIT), and `kernel.kexec_load_disabled=1` (block loading a new kernel). These are deliberately conservative: they don't break nested containers, profiling, or normal builds. The heavier toggles that *would* affect those workflows — disabling unprivileged eBPF, io_uring, and user namespaces, or `lockdown` — are reserved for a future opt-in **`--harden strict`** profile.

Turn the profile off with **`--harden off`**. The applied set lives in [`share/hardening-sysctl.conf`](share/hardening-sysctl.conf); the box entrypoint applies it best-effort at boot, skipping any key the guest kernel doesn't expose.

## Secrets

Store a value once on the host, then hand it to specific boxes at create time:

```sh
isopod secret set NPM_TOKEN          # value from stdin or a hidden prompt — never argv
isopod create myproj --secret NPM_TOKEN            # appears at /run/secrets/NPM_TOKEN
isopod create other --secret NPM_TOKEN:/run/secrets/npmrc-token   # custom path
```

Values live in the OS keychain (`security` on macOS, `secret-tool` on Linux; 0600-file fallback) and are streamed over the box's SSH channel into a memory-backed tmpfs. They never appear in image layers, container env, `inspect` output, `isopod export` tarballs, or `reconfigure` snapshots, and a stopped box holds no secrets (they're re-injected on `start`). Manage them with `isopod secret set|ls|rm`.


## Connecting each IDE

**VSCodium (priority).** `isopod code <name>` checks for `jeanp413.open-remote-ssh`, installs it from Open VSX if needed, and launches `codium --folder-uri vscode-remote://ssh-remote+isopod-<name>/home/dev/workspace`. The first connection downloads the VSCodium server *into the container*. Extensions you install in that window (including AI agents like Cline, Continue, Roo, etc.) install and run in the container.

**Cursor / Windsurf / VS Code.** `isopod code <name> --app cursor` (or `windsurf`, `code`). They use the same SSH host entry; their bundled Remote-SSH handles the rest. Note that Cursor's own cloud AI features run wherever Cursor sends them, but the agent's *tool execution* (shell commands, file edits) happens in the container.

**JetBrains.** Open JetBrains Gateway → SSH connection → pick host `isopod-<name>` (it reads your `~/.ssh/config`) → project directory `/home/dev/workspace`. The JetBrains backend IDE runs inside the container. Note the default image is slim; JetBrains backends want more: create with `--memory 6g` and run `isopod shell <name>` then `sudo apt install -y libxext6 libxrender1 libxtst6 libxi6 fontconfig` if the backend complains.

## Environment variables

`ISOPOD_ENGINE` (`podman`|`docker`) — engine override. 
`ISOPOD_CONFIG_DIR` — state location (default `~/.config/isopod`). 
`ISOPOD_BUILD_ARGS` — extra args for `build` (e.g. `--network=host`, 
`--build-arg http_proxy=...` behind corporate proxies). 
`ISOPOD_RUN_ARGS` — extra args for `run` (e.g. `--network=none` for an offline container, `--userns=keep-id`, custom DNS).
`ISOPOD_RUNTIME` — sandboxed runtime overriding the hardening profile: Tier 2 (`runsc`) or a Tier 3 microVM (`kata` or `krun`; needs `/dev/kvm`). isopod runs `krun` with passt (virtio-net) so `isopod code` works, and auto-selects it when kata isn't available. `crun-vm` is unsupported (it boots VM disk images, not isopod's OCI images). A configured runtime that isn't registered with the engine fails `create` closed with a clear error.
`ISOPOD_MICROVM_MEMORY` — default guest memory when a Tier 3 microVM runtime is active and no `--memory` is given (default `2g`). 
`ISOPOD_MICROVM_ANNOTATIONS` — space-separated `krun.*` OCI annotations passed to a microVM guest (e.g. `krun.nested_virt=1`); Podman only. 
`ISOPOD_HARDENING_CONF` — path to an alternate baseline [fingerprint-hardening profile](#fingerprint-hardening) (advanced; for per-user tweaks layer an override at `~/.config/isopod/hardening.conf` instead).

`ISOPOD_SSH_WAIT_TRIES` — how many 1s attempts `create`/`start` make waiting for sshd before giving up (default `30`).

[Network egress isolation](docs/opt-in-security.md#network-egress-isolation-egress-lan-deny) has its own overrides: `ISOPOD_EGRESS` (`lan-deny`|`allow-list`|off), `ISOPOD_EGRESS_NET`, `ISOPOD_EGRESS_SUBNET`, `ISOPOD_EGRESS_GATEWAY`, `ISOPOD_EGRESS_DNS`, `ISOPOD_EGRESS_RULESET` (the network/firewall parameters), and `ISOPOD_EGRESS_ALLOW_UNLOADED=1` to start a box even when the host firewall isn't loaded yet (otherwise `create` fails closed). The [`allow-list`](docs/opt-in-security.md#network-egress-allow-list-egress-allow-list) mode adds `ISOPOD_EGRESS_PROXY_PORT`, `ISOPOD_EGRESS_PROXY_BIN`, `ISOPOD_EGRESS_ALLOWLIST` (allow-list file), and `ISOPOD_EGRESS_ALLOWLIST_RULESET`.

## Customizing the container

The base image is defined by a standard Dockerfile, [`share/Dockerfile`](share/Dockerfile) — built identically by `docker build` and `podman build`. On top of whatever base you choose it adds sshd, git, common CLI tooling, the unprivileged in-container user, and passwordless sudo (drop sudo with `--no-sudo`). There are two ways to shape it:

- **`--image <ref>`** swaps the base. Any Debian/Ubuntu-based image works (`--image ubuntu:24.04`), including one you built yourself from a Dockerfile and want to reuse across boxes.
- **`--dockerfile <path>`** is the project-provisioning path: isopod builds your Dockerfile first, then layers sshd/git on top (i.e. your image becomes the base via `FROM`). This is how you bake in a toolchain (a JDK, Node, etc.) the industry-standard way, rather than a bespoke config format.

```dockerfile
# Dockerfile  — your project's toolchain
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends default-jdk maven
```

```sh
isopod create api --repo https://github.com/me/api --dockerfile ./Dockerfile
```

Your Dockerfile must use a Debian/Ubuntu (`apt`) base, since isopod's layer installs sshd with `apt-get`. A trailing `USER` in your Dockerfile doesn't change the box's privilege model — isopod's layer resets to root (sshd must be PID 1 as root) and you log in as the unprivileged in-box user. **To limit privilege inside the box, use `--no-sudo`** (drops the in-box user's passwordless sudo), not the base image's `USER` — isopod's SSH model supersedes it. (isopod's real boundary is host isolation + rootless userns, not in-container rootlessness; see [The isolation model](#the-isolation-model).)

Because the image is built before the container exists (and `--repo` clones *inside* the box afterward), the Dockerfile is a host-side file you point at — not something read from the cloned repo. For quick one-offs you can still install toolchains interactively with `isopod shell`.

isopod runs box operations (clone, copy-in, export, fetch) over a non-interactive SSH command, which uses the system `PATH`, not the one your `~/.bashrc` builds. Install tools system-wide (in the Dockerfile, or with `sudo` in the box) so these operations can find them; a tool only on a shell-rc `PATH` is still available in `isopod shell`, just not to box operations.

### Adding a system package without a rebuild (`isopod install`)

Most dependencies don't need root: install language packages (`pip install --user`, `npm`, `cargo`) into your home directory from `isopod shell`. For the system packages that *do* need root — a `-dev` header, a CLI tool like `jq` — how you add them depends on the box's privilege posture:

- **Default (sudo) box:** the in-box user has passwordless sudo, so `isopod shell <name> -- 'sudo apt-get update && sudo apt-get install -y jq'` just works.
- **`--no-sudo` box:** the in-box user has no root, so the install comes from the host instead:

```sh
isopod install <name> jq ripgrep    # runs the box's package manager as root, from the host
```

`isopod install` runs the box's package manager (`apt-get`/`apk`/`dnf`) as root **through the container engine from the host** — the same trust boundary as [egress](#network-egress-isolation-egress-lan-deny) and [secrets](#secrets). Because it enters through the engine rather than sshd, the boxed (unprivileged) agent can't reach it: the box stays locked down, but you can still add a forgotten dependency without recreating it.

**Why a host-mediated *named-package* install, rather than giving the agent sudo (or a root shell)?** In isopod's model the untrusted party is the agent running inside the box. Passwordless sudo hands *the agent* root for the whole session, not just you. And a root shell in the box — however you get it — can still be tricked into running agent-controlled code as root the moment you execute the project (a build, `npm install`, a `Makefile`) in the workspace the agent controls. Installing a *named package* through a host channel avoids both: the agent never gets root, and you're running the distro's package manager on a name **you** chose, not the box's code. It is the smaller, safer capability — so on a locked-down box, prefer `isopod install jq` over dropping into a root shell and building.

Two caveats. Installs are **ephemeral** — a fresh `create` starts without them (`reconfigure` snapshots the box, so they survive *that*). For a dependency you always need, bake it into a [`--dockerfile`](#customizing-the-container) instead. And `isopod install` needs a **container** box: the engine can't exec into a microVM guest, so on a microVM runtime add the package with `--dockerfile` and recreate.

### Reaching a server in the box (port forwarding)

A dev server inside the box (say `pnpm run start` on `:3000`) isn't on your host by default. Publish it with **`--expose`**, which maps a container port to a `127.0.0.1` host port — the standard `podman/docker run -p`, loopback-only:

```sh
isopod create web --repo <url> --expose 3001:3000   # box :3000 -> localhost:3001
isopod create web --repo <url> --expose 8080         # same port on both sides
```

Port mappings are set at create time (engine port mappings can't be added to a *running* container) and restored across stop/start. `isopod info <name>` lists them. To add or change ports later without starting over, use `isopod reconfigure` (below). In the VSCodium Remote-SSH window, ports a server opens are also auto-forwarded by the IDE.

### Changing a box after create (`reconfigure`)

A container's run settings — ports, memory, cpus, fingerprint masks — can't be edited in place; the engine bakes them in at creation. So every box has a readable config you can change, and isopod re-applies it for you:

```sh
isopod config web                       # view the box's config.yaml
isopod reconfigure web --expose 5173 --memory 8g   # or edit config.yaml, then:
isopod reconfigure web
```

The config lives at `~/.config/isopod/boxes/<name>/config.yaml` — and it's written as a **real, valid Compose service** (engine-correct: podman gets `security_opt: mask=…`, docker gets `tmpfs` directory masks — it can't mask `/proc` files), so you can read, copy, or adapt it elsewhere. But **isopod owns and parses it; it does not launch boxes from it** — a working box also needs the per-box SSH key, pinned host key, and cloned workspace that Compose can't set up, so `docker compose up` on it gives a bare container. isopod reads a few fields back on `reconfigure` (`ports`, `mem_limit`, `cpus`, `x-isopod-color`); the rest is a managed reference.

On `reconfigure`, isopod **snapshots the container to an image** (so your workspace *and* anything you `apt install`ed are preserved), then recreates it with the new settings, keeping the box's SSH key, host key, color, and ssh_config entry. The base image itself is that managed snapshot; to change the base, create a new box.



## Testing

isopod ships a test suite under `test/` using [bats-core](https://github.com/bats-core/bats-core) and pexpect for interactive prompts.

```sh
test/run.sh              # lint + stubbed bats + interactive (no container engine)
RUN_LIVE=1 test/run.sh   # also runs live end-to-end tests against real podman/docker
```

Contributing? Install the ShellCheck + shfmt [pre-commit hooks](docs/development.md) first (`pip install pre-commit && pre-commit install`) so linting and formatting run on every commit.

CI runs on both GitLab and GitHub with the same core jobs — a `lint` job (shellcheck + bash syntax + python), a `test` job (stubbed + interactive, runs anywhere), and a manual `live` job that needs a podman-capable runner. GitHub additionally runs a `brew-formula` job that installs isopod through the Homebrew tap formula built from the checkout:

- **GitLab CI/CD** (`.gitlab-ci.yml`) — should run identically under [`gitlab-ci-local`](https://github.com/firecow/gitlab-ci-local) for debugging pipelines on your own machine before pushing.

- **GitHub Actions** (`.github/workflows/ci.yml`) — run it locally with [`act`](https://github.com/nektos/act): `act -j lint`, `act -j test`, or just `act` for both. The `live-isolation` job needs container-in-container and is gated to manual dispatch, so run it the native way instead: `RUN_LIVE=1 test/run.sh`. (An `.actrc` pins a runner image with the tooling the jobs expect.)

## Documentation

More detailed docs live in [`docs/`](docs/):

- **[Development guide](docs/development.md)** — dev setup, the ShellCheck + shfmt pre-commit hooks, formatting conventions, and running the tests.
- **[Installation, platform notes & state layout](docs/installation-and-platform.md)** — manual install steps per platform, window colors, platform-specific notes, and how on-disk state is laid out.
- **[Identity remap](docs/remap.md)** — rewriting the git identity on commits made inside a container after `fetch`, and how the new identity is resolved.
- **[Opt-in security features](docs/opt-in-security.md)** — enabling the gVisor (`runsc`) syscall-virtualizing runtime, or a Tier 3 microVM runtime (Kata, krun).
- **[Releasing isopod](docs/RELEASING.md)** — how the version gate and Homebrew tap automation work.
- **[VSCodium host-isolation audit](docs/isopod-vscodium-host-isolation-audit.md)** — code-level audit of what (if anything) crosses from host into the container.

## License

isopod is licensed under the [Apache License 2.0](LICENSE).
