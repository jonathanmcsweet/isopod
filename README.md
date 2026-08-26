# Isopod

[![CI](https://github.com/jonathanmcsweet/isopod/actions/workflows/ci.yml/badge.svg)](https://github.com/jonathanmcsweet/isopod/actions/workflows/ci.yml)

`isopod` creates a sandbox with your code in it to safely develop with LLMs using an IDE of your choice ([VSCodium](https://vscodium.com/) is recommended).

<img width="1920" height="1080" alt="Screenshot From 2026-07-09 16-44-49" src="https://github.com/user-attachments/assets/5925e432-1f9c-4347-b289-54049c6be2f1" />

## Key Features 
- [VSCodium](https://vscodium.com/)'s server component and extensions are limited to the container
- Hardening options to prevent hardware fingerprinting and security exploits
- Copying and exporting to your local host instead of binding to your personal folders
- MicroVMs and allow-lists when extra hardening is needed
- Completely offline boxes, which need no host setup at all
- Box-local data volumes, and optional nested containers, without mounting anything from your host

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

Don't use Homebrew? Manual install steps by distro family: Debian (Ubuntu,
Mint, Pop!_OS, Zorin, MX), Fedora, Fedora immutable (Silverblue, Kinoite,
Bazzite), Arch (Manjaro, EndeavourOS, CachyOS), Gentoo,
and macOS. How to verify and update an install, live in
**[docs/installation-and-platform.md](docs/installation-and-platform.md)**.

## Quick start

```sh
# Sandbox around a git repo, teal-tinted windows
isopod create myproj --repo https://github.com/me/myproj --color teal
isopod code myproj          # opens VSCodium connected to the container

# Sandbox from an explicit allowlist of host folders to copy
isopod create scratch --copy ~/src/lib-a --copy ~/notes/specs --color '#b3261e'

# Sandbox with no route off your machine at all (needs no host setup)
isopod create review --offline --copy ~/src/thing
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
  - VSCodium is recommended with the [Open Remote – SSH extension](https://open-vsx.org/extension/jeanp413/open-remote-ssh) on Open VSX.
  - Cursor/Windsurf/VS Code ship their own Remote-SSH but may have telemetry that reveals information
    about your host system


## Getting work back out: `export` vs `fetch`

1. `isopod export <name> [dest]` copies the whole working tree including its `.git` to a fresh host directory
2. `isopod fetch <name> [target]` brings only the committed git history across as remote-tracking refs. which is the one to prefer when the agent is untrusted since commit objects carry no hooks or editor task files. 

After a `fetch`, `isopod remap <name>` rewrites throwaway container commit identities to your real name and email. The full mechanics, the `--path` and bundle options, and identity remap are in **[docs/getting-work-out.md](docs/getting-work-out.md)** and **[docs/remap.md](docs/remap.md)**.

## FAQ

### Why so much emphasis on VSCodium?
Because I can reasonably evaluate VSCodium's code and extension security boundaries: it doesn't scan your host device for telemetry or fingerprinting data, and it doesn't expose host information to extensions when connected to a container. Proprietary IDEs on the other hand, may still collect host telemetry even while your code and AI agent are sandboxed in an isopod container.

### Will you be explicitly supporting other open-source IDEs?
Yes, provided I can reasonably verify they don't take telemetry from the host device and enforce boundaries that keep extensions from doing so also.

### Why SSH instead of the Dev Containers extension?
The Dev Containers extension is Microsoft-proprietary and not licensed for VSCodium. The open-source [Open Remote – SSH extension](https://open-vsx.org/extension/jeanp413/open-remote-ssh) is mature, and the same isopod container works for VSCodium, Cursor, Windsurf, JetBrains, and plain terminals simultaneously.

### Is my code safe from the AI vendor?
Whatever code is in the container is visible to agents you run in it, and they may transmit it to their APIs, that's a standard risk with AI vendors but can be mitigated in various ways. Isopod limits the blast radius to the container's contents to varying degrees; it does not change what an agent does with those contents.

### Can two IDEs attach to the same container?
Yes, it's just SSH. You can have VSCodium and a terminal and JetBrains attached at once.

## Security model

An isopod box puts your code and the agent behind several layers you can dial up as your threat model demands. The container cannot see your host filesystem: files only cross when you copy them in, clone a repo, or pull work back out, so a misbehaving agent has no live mount. 

Isopod also masks the host-revealing `/proc` and `/sys` paths that fingerprinting tools read, runs each box under a microVM with its own kernel when one is available, and can force all network egress through a host-side allow-list.

A microVM runtime can hide things like CPU identity, the kernel build string, and host RAM, all of which can't be done with your standard podman or docker container. The full picture (the isolation model, the fingerprint masks, what still leaks, the runtime tiers, the egress modes, and the kernel-hardening profile) lives in **[docs/security-model.md](docs/security-model.md)**.

### What you actually get on your machine

Isopod aims each box at the strongest setup your host can run and steps down when it can't, warning each time: microVM to gVisor to a plain container, and egress allow-list to lan-deny to an open network. The two strong tiers have host requirements, a microVM needs `/dev/kvm` with kata or krun registered with your engine, and host-enforced egress needs a rootful podman or docker, so on a stock rootless podman with no microVM runtime you get a plain shared-kernel container on an open network.

That box still copies rather than mounts, still reaches you over key-only loopback SSH, and still has the fingerprint masks, which is the layer most people want and the reason the defaults degrade instead of refusing to start. It is the deliberate trade: a box you can run today beats isolation you never finish installing. To see where your machine stands and what to install to move up a tier, run `isopod doctor`; `isopod list` and `isopod info` mark any box whose isolation was stepped down, so a degraded box stays visible long after the warning at create scrolls past.

For a strong boundary with no host setup at all, create the box offline: `isopod create review --offline --copy ~/src/thing`. It goes on a dedicated internal engine network, so `isopod code`, `shell`, `copy-in` and `export` all work as usual while nothing in the box can reach your LAN or the internet. Because the engine enforces it, in-box root cannot undo it, and because it needs no firewall, no root and no `/dev/kvm`, it is available on exactly the stock rootless setup where the other network modes degrade. It suits review, refactoring and analysis; an agent that needs to install packages or call an API needs a network, and `isopod host-port` can hand an offline box one specific service from your machine.

## Secrets

Store a value once on the host with `isopod secret set NAME`, then hand it to a box at create time with `--secret NAME`, and it arrives at `/run/secrets/NAME` in a memory-backed tmpfs streamed over SSH. Values live in your OS keychain, and as long as the target stays under `/run/secrets`. They never land in image layers, container env, `inspect` output, export tarballs, or `reconfigure` snapshots. Managing them and the custom-path caveat are covered in **[docs/security-model.md#secrets](docs/security-model.md#secrets)**.

## Connecting each IDE

**VSCodium** `isopod code <name>` checks for `jeanp413.open-remote-ssh`, installs it from Open VSX if needed, and launches `codium --new-window --folder-uri vscode-remote://ssh-remote+isopod-<name>/home/dev/workspace`. The first connection downloads the VSCodium server *into the container*. Extensions you install in that window install and run in the container.

Each box gets its own window; pass `--reuse-window` to open it in the current one instead.

**Cursor / Windsurf / VS Code.** `isopod code <name> --app cursor` (or `windsurf`, `code`). They use the same SSH host entry; their bundled Remote-SSH handles the rest. Note that Cursor's own cloud AI features run wherever Cursor sends them, but the agent's tool execution (shell commands, file edits) happens in the container.

**JetBrains.** Open JetBrains Gateway → SSH connection → pick host `isopod-<name>` (it reads your `~/.ssh/config`) → project directory `/home/dev/workspace`. The JetBrains backend IDE runs inside the container. Note the default image is slim; JetBrains backends want more: create with `--memory 6g` and run `isopod shell <name>` then `sudo apt install -y libxext6 libxrender1 libxtst6 libxi6 fontconfig` if the backend complains.

## Environment variables

isopod reads a set of `ISOPOD_*` variables to override the engine, config location, build and run args, the sandboxed runtime, microVM sizing, and every egress parameter. The full table, including the egress and microVM overrides, is in **[docs/managing-boxes.md#environment-variables](docs/managing-boxes.md#environment-variables)**.

## Customizing and managing a box

Shape the base image with `--image` to swap in any Debian/Ubuntu base or `--dockerfile` to build your own toolchain in first. Add a forgotten system package to a running box from the host with `isopod install`, publish an in-box server to your host loopback with `--expose`, and change a box's ports, memory, or cpus after the fact with `isopod reconfigure`. 

A box can also carry its own scratch storage with `--disk` and run rootless containers inside itself with `--nested-containers`, both kept box-local rather than mounted from your host. See **[docs/managing-boxes.md](docs/managing-boxes.md)** for the image, install, port, and reconfigure detail, and the [data volumes and nested containers](docs/security-model.md#data-volumes---disk-and-nested-containers---nested-containers) section of the security model for how box-local storage stays off your host.

## Machine-readable output

`isopod list`, `isopod info <name>`, and `isopod egress status` each take `--json` and print one JSON document on stdout, for scripts and dashboards that drive isopod such as the Podman Desktop dashboard extension. The field-by-field schema is in **[docs/managing-boxes.md#machine-readable-output](docs/managing-boxes.md#machine-readable-output)**.

## Testing

`test/run.sh` runs lint, formatting, and the stubbed and interactive suites with no container engine, and `RUN_LIVE=1 test/run.sh` adds the live end-to-end tests against real podman/docker. Contributor setup, the pre-commit hooks, and the full CI layout are in **[docs/development.md](docs/development.md)**.

## Documentation

More detailed docs live in [`docs/`](docs/):

- **[Security model](docs/security-model.md)** — the isolation model, fingerprint masks, what still leaks, the sandboxed runtimes (gVisor, Kata, krun), the egress modes, data volumes, and secrets.
- **[Managing and customizing a box](docs/managing-boxes.md)** — base image and `--dockerfile`, `isopod install`, port forwarding, `reconfigure`, JSON output, and environment variables.
- **[Getting work back out](docs/getting-work-out.md)** — `export` vs `fetch`, and pulling git history onto the host.
- **[Identity remap](docs/remap.md)** — rewriting the git identity on commits made inside a container after `fetch`, and how the new identity is resolved.
- **[Installation, platform notes & state layout](docs/installation-and-platform.md)** — manual install steps per platform, window colors, platform-specific notes, and how on-disk state is laid out.
- **[Development guide](docs/development.md)** — dev setup, the ShellCheck + shfmt pre-commit hooks, formatting conventions, and running the tests.
- **[macOS host-level egress](docs/macos-host-egress.md)** — why egress enforcement needs a different design on macOS, and how the host-`pf` backend works.
- **[Releasing isopod](docs/RELEASING.md)** — how the version gate and Homebrew tap automation work.
- **[VSCodium host-isolation audit](docs/isopod-vscodium-host-isolation-audit.md)** — code-level audit of what (if anything) crosses from host into the container.

## License

isopod is licensed under the [Apache License 2.0](LICENSE).
