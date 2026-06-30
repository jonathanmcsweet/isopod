# Isopod

[![CI](https://github.com/jonathanmcsweet/isopod/actions/workflows/ci.yml/badge.svg)](https://github.com/jonathanmcsweet/isopod/actions/workflows/ci.yml)

Disposable, isolated IDE containers to keep AI coding agents from touching your local machine, with hardening that limits how much they can fingerprint it.

`isopod` is a bash script that creates a Podman (or Docker) container with an SSH server inside, puts your code in it, and turns VSCodium (or Cursor, Windsurf, VS Code) into a GUI for that container — JetBrains connects too, via Gateway. The IDE's server component, your terminals, and any AI agent extensions all execute *inside* the container. Each sandbox gets its own window color to discern between environments.

## Install

### Homebrew (macOS / Linux)

```sh
brew tap jonathanmcsweet/isopod
brew install isopod          # or: brew install --HEAD isopod  (latest master)
```

The formula lives in the separate [`homebrew-isopod`](https://github.com/jonathanmcsweet/homebrew-isopod)
tap and installs `bash`/`zsh` shell completions. You still need a container engine
(`brew install podman`). See [docs/RELEASING.md](docs/RELEASING.md) for how the tap is created
and maintained.

### install.sh (any Linux/macOS, no Homebrew)

```sh
./install.sh            # per-user install, no sudo
./install.sh --system   # system-wide (/usr/local), needs sudo
./install.sh --check     # show what the installer will do
./install.sh --uninstall # remove a previous install
```

`install.sh` also drops in shell completions (best-effort) and points your editor
at the `Open Remote – SSH` extension. Tab-completion covers subcommands, options,
and your existing box names.

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

## The isolation model

The container cannot see the host filesystem at all. Files cross the boundary in five ways:

1. `--repo <url>` — a `git clone` executed *inside* the container.
2. `--copy <path>` / `isopod copy-in` — a one-time **copy** of folders you name.
3. `isopod export` to copy changes back to the host machine
4. `isopod fetch` git history copied back to your local machine
5. `git push` to your remote server

We have some mitigations for a snooping AI agent fingerprinting your host machine from the container. It sees the container's hostname, a generic Linux environment, and the container's network identity — and isopod masks the host-revealing `/proc`/`/sys` paths it would otherwise read (drive serials, board model, MACs, boot UUIDs — see [Fingerprint hardening](#fingerprint-hardening)). Additional details:

- SSH is bound to `127.0.0.1` only and uses a dedicated per-container ed25519 keypair with the container's host key pinned. Password auth and root login are disabled in the container's sshd.
- **SSH agent forwarding and X11 forwarding are explicitly disabled** in the generated config, so an agent inside the container cannot borrow your SSH agent to authenticate as you elsewhere.
- With rootless Podman (the recommended engine), even "root" inside the container is just your unprivileged user on the host, remapped.

**To create an offline container** `ISOPOD_RUN_ARGS="--network=none" isopod create ...`


### What it does NOT protect against

- **Network exfiltration of what's inside the container.** AI agents need network access (APIs, package installs), so the container has it unless youv'e created an offline container. Anything you copy into the container could be sent out by a misbehaving agent. Only put code/data in the container that you could tolerate leaking, and use narrowly-scoped credentials. 

- **A misbehaving agent inside the container.** By default the in-container user has **passwordless `sudo`** (so agents can `apt install` toolchains), which makes the agent effectively root *within the container*. Your host is still protected by the isolation model above — but anything inside the container (including data you copied in) is fully exposed to it. If you don't need in-container package installs, create the container with **`--no-sudo`** to drop that privilege. The container also intentionally keeps Linux capabilities (no `--cap-drop=ALL`), since `sshd` and `sudo` need them — see [Fingerprint hardening](#fingerprint-hardening).

- **Container escape.** Containers share the host kernel. Rootless Podman makes escapes very hard, but a container is not a VM. For "agent might be actively malicious and sophisticated," use a full VM. For "agent might do dumb destructive things or over-collect data" this is the right tool.

- **Docker's daemon model.** With Docker (non-rootless), the daemon runs as root; a compromise of the daemon is a compromise of the host. Enable Docker rootless mode to avoid this.

## Fingerprint hardening

A container shares the host's kernel and hardware, so by default a process inside can read a surprising amount about the host through `/proc` and `/sys` — far more than its own hostname. Isopod ships a hardening profile that closes the file-based leaks and supports an optional sandboxed runtime for the rest. It's all configured in one declarative file, **[`security/hardening.conf`](security/hardening.conf)** that you can edit.

### What's implemented

Every container hides the host-revealing paths below. Podman gets a single `--security-opt mask=…`; Docker (which has no mask flag) gets an empty `tmpfs` per directory and a `/dev/null` bind per file.

| Masked path | Data it obfuscates |
|---|---|
| `/proc/cmdline` | host boot args — **LUKS volume UUID, root-fs UUID, OS image / ostree hash** |
| `/proc/modules` | loaded host kernel modules (VPNs like WireGuard, DisplayLink, Bluetooth…) |
| `/sys/class/dmi`, `/sys/devices/virtual/dmi`, `/sys/firmware` | SMBIOS: **board model, vendor, BIOS version/date** |
| `/sys/bus/pci` | full host PCI topology (NVMe, Wi-Fi, USB4/Thunderbolt controllers) |
| `/sys/bus/usb` | attached peripherals **with serial numbers** (keyboard, mouse, NIC, dongles) |
| `/sys/class/net` | interface names and **MAC addresses** |
| `/sys/block`, `/sys/class/nvme` | disk models and **factory drive serial numbers** |
| `/sys/class/hwmon`, `/sys/class/thermal`, `/sys/class/drm` | sensor/thermal/GPU identity (a board signature) |

Verify from inside a container: after hardening, `cat /proc/cmdline` and `lsblk -o NAME,SERIAL` come back empty/blank.

> isopod launches containers with `podman run`/`docker run`, not Compose, so the profile above is the live source of truth. If you prefer Compose, [`security/compose.yaml`](security/compose.yaml) expresses the same masks in `podman compose`/`docker compose` form as a reference — it is not executed by the CLI.

> isopod deliberately does **not** add `--cap-drop=ALL`, `--read-only`, or `--security-opt no-new-privileges` here: the container runs `sshd` and gives agents passwordless `sudo apt install` for toolchains, all of which those flags would break. The isolation guarantees in [The isolation model](#the-isolation-model) (no mounts, loopback-only SSH, rootless userns) remain the primary boundary; the masks above are defense-in-depth against *fingerprinting* specifically.

### Opt-in Security Features
See **[docs/opt-in-security.md](docs/opt-in-security.md)** for how to enable and configure them.

### What still can't be mitigated

Even with every mask on, a **plain shared-kernel container cannot hide these** — the app reads them straight from the CPU or the shared kernel, with no file to mask:

- **CPU identity** — model, family, stepping, **microcode**, feature flags, via the `CPUID` instruction. (Masking `/proc/cpuinfo` doesn't stop `CPUID` and breaks build tools, so isopod leaves it readable.)
- **Kernel build string** — `uname -r` always returns the host kernel version.
- **Host boot epoch / boot id** — `/proc/stat`'s `btime` and `/proc/sys/kernel/random/boot_id` are a single value per host boot, identical in every container on that host. (`btime` is left unmasked because masking `/proc/stat` breaks `top`/`htop` and most monitoring.)
- **Timing side channels** — `RDTSC` and clock-skew fingerprints.

Rule of thumb: if your threat model is "a sophisticated, actively malicious agent," use a VM; isopod's container hardening targets "an agent that over-collects host data or does dumb destructive things."
## Requirements

- Linux (primary), macOS (via `podman machine` or Docker Desktop), or Windows (via WSL2 — see [docs/installation-and-platform.md](docs/installation-and-platform.md#windows))
- `podman` (recommended) or `docker`
- `ssh`, `ssh-keygen`, `ssh-keyscan` (the standard OpenSSH client tools)
- VSCodium with the **Open Remote – SSH** extension (`jeanp413.open-remote-ssh`, on Open VSX). `isopod code` installs it for you if missing. Cursor/Windsurf/VS Code ship their own Remote-SSH.

Run `isopod doctor` to check your setup.

### Manual installation

Don't use Homebrew or `install.sh`? Per-platform manual install steps (Fedora,
immutable Fedora, Debian/Ubuntu, system-wide, macOS, Windows/WSL2) and how to
verify and update an install live in
**[docs/installation-and-platform.md](docs/installation-and-platform.md)**.

Every container also becomes a plain SSH host: `ssh isopod-myproj` works from any terminal, and any SSH-aware tool can use it.

## Getting work back out: `export` vs `fetch`

Two ways out, for two situations:

- **`isopod export <name> [dest]`** copies the container's whole working tree (including its `.git`) to a fresh host directory. It will not write into an existing path so the export shape stays predictable.
- **`isopod fetch <name> [target-repo]`** brings only **committed git history** across, the clean way — no file merges, no clobbering your working tree:

  ```sh
  cd ~/code/myproj          # an existing clone on your host
  isopod fetch myproj        # target defaults to the current directory
  ```

  Under the hood it `git fetch`es straight from the container over its SSH remote (the same dedicated key and pinned host key isopod already set up) — so the container's branches appear as **remote-tracking refs named `<name>/*`** without touching your local branches. Check one out with:

  ```sh
  git switch -c fingerprint-hardening myproj/fingerprint-hardening
  ```

  `isopod fetch` finds the repo at the container's workspace automatically (or the single git subfolder inside it); pass `--path <in-container-repo>` if your layout is unusual. If the target isn't a git repo, it instead drops a `<name>.bundle` file and prints how to use it. Like `export`, it needs no network and no git remote.


  `isopod remap <name> [target-repo]` Pods don't set a git identity, so commits made inside one carry whatever was configured there (often a throwaway `dev@<container>`); this maps them to your real name/email while preserving commit messages and author/committer **dates**:

  ```sh
  isopod remap myproj --name "Ada Lovelace" --email ada@example.com
  ```

  Only commits matching the old identity are touched — pass `--old-email <e>` (and optionally `--old-name <n>`) to set it explicitly, or let it auto-detect from the still-running container. The new identity defaults to your host `git config` (override with `--name`/`--email` or `ISOPOD_GIT_NAME`/`ISOPOD_GIT_EMAIL`), so the common case is just `isopod remap myproj`. To remap several identities at once, list `old -> new` rules in `--remap-file <file>` (or `~/.config/isopod/remap`). The rewrite is scoped to the container's `<name>/*` refs, so **your own branches are never touched**, and the originals are snapshotted under `refs/remap-backup/` so you can undo. It uses [`git-filter-repo`](https://github.com/newren/git-filter-repo) when installed, otherwise a built-in `git fast-export`→`fast-import` rewrite that needs only **core git plus `python3`**. See **[docs/remap.md](docs/remap.md)** for the full details.

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
`ISOPOD_RUNTIME` — (e.g. `runsc`), overriding `security/hardening.conf`. 
`ISOPOD_HARDENING_CONF` — path to an alternate [fingerprint-hardening profile](#fingerprint-hardening).

## Customizing the container

The base image is defined by a standard Dockerfile, [`share/Dockerfile`](share/Dockerfile) — built identically by `docker build` and `podman build`. On top of whatever base you choose it adds sshd, git, common CLI tooling, the unprivileged in-container user, and passwordless sudo (drop sudo with `--no-sudo`). There are two ways to shape it:

- **`--image <ref>`** swaps the base. Any Debian/Ubuntu-based image works (`--image ubuntu:24.04`), including one you built yourself from a Dockerfile and want to reuse across boxes.
- **`--dockerfile <path>`** is the project-provisioning path: isopod builds your Dockerfile first, then layers sshd/git on top. This is how you bake in a toolchain (a JDK, Node, etc.) the industry-standard way, rather than a bespoke config format.

```dockerfile
# Dockerfile  — your project's toolchain
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends default-jdk maven
```

```sh
isopod create api --repo https://github.com/me/api --dockerfile ./Dockerfile
```

Because the image is built before the container exists (and `--repo` clones *inside* the box afterward), the Dockerfile is a host-side file you point at — not something read from the cloned repo. For quick one-offs you can still install toolchains interactively with `isopod shell`.

### Reaching a server in the box (port forwarding)

A dev server inside the box (say `pnpm run start` on `:3000`) isn't on your host by default. Publish it with **`--expose`**, which maps a container port to a `127.0.0.1` host port — the standard `podman/docker run -p`, loopback-only:

```sh
isopod create web --repo <url> --expose 3001:3000   # box :3000 -> localhost:3001
isopod create web --repo <url> --expose 8080         # same port on both sides
```

Port mappings are fixed at create time (engine port mappings can't be added to a running container) and are restored across stop/start. `isopod info <name>` lists them. In the VSCodium Remote-SSH window, ports a server opens are also auto-forwarded by the IDE.

## FAQ

**Why SSH instead of the Dev Containers extension?** The Dev Containers extension is Microsoft-proprietary and not licensed for VSCodium. The open-source `Open Remote – SSH` extension is mature, and the same container works for VSCodium, Cursor, Windsurf, JetBrains, and plain terminals simultaneously.

**Is my code safe from the AI vendor?** Whatever code is in the container is visible to agents you run in it, and they may transmit it to their APIs — that's how they work. Isopod limits the blast radius to the container's contents; it does not change what an agent does with those contents.

**Can two IDEs attach to the same container?** Yes — it's just SSH. You can have VSCodium and a terminal and JetBrains attached at once.

## Testing

isopod ships a test suite under `test/` using [bats-core](https://github.com/bats-core/bats-core) and pexpect for interactive prompts.

```sh
test/run.sh              # lint + stubbed bats + interactive (no container engine)
RUN_LIVE=1 test/run.sh   # also runs live end-to-end tests against real podman/docker
```

Contributing? Install the ShellCheck + shfmt [pre-commit hooks](docs/development.md) first (`pip install pre-commit && pre-commit install`) so linting and formatting run on every commit.

CI runs on both GitLab and GitHub, kept in lockstep with the same three jobs — a `lint` job (shellcheck + bash syntax + python), a `test` job (stubbed + interactive, runs anywhere), and a manual `live` job that needs a podman-capable runner:

- **GitLab CI/CD** (`.gitlab-ci.yml`) — should run identically under [`gitlab-ci-local`](https://github.com/firecow/gitlab-ci-local) for debugging pipelines on your own machine before pushing.

- **GitHub Actions** (`.github/workflows/ci.yml`) — run it locally with [`act`](https://github.com/nektos/act): `act -j lint`, `act -j test`, or just `act` for both. The `live-isolation` job needs container-in-container and is gated to manual dispatch, so run it the native way instead: `RUN_LIVE=1 test/run.sh`. (An `.actrc` pins a runner image with the tooling the jobs expect.)

## Documentation

More detailed docs live in [`docs/`](docs/):

- **[Development guide](docs/development.md)** — dev setup, the ShellCheck + shfmt pre-commit hooks, formatting conventions, and running the tests.
- **[Installation, platform notes & state layout](docs/installation-and-platform.md)** — manual install steps per platform, window colors, platform-specific notes, and how on-disk state is laid out.
- **[Identity remap](docs/remap.md)** — rewriting the git identity on commits made inside a container after `fetch`, and how the new identity is resolved.
- **[Opt-in security features](docs/opt-in-security.md)** — enabling the gVisor (`runsc`) syscall-virtualizing runtime.
- **[Releasing isopod](docs/RELEASING.md)** — how the version gate and Homebrew tap automation work.
- **[VSCodium host-isolation audit](docs/isopod-vscodium-host-isolation-audit.md)** — code-level audit of what (if anything) crosses from host into the container.

## License

isopod is licensed under the [Apache License 2.0](LICENSE).
