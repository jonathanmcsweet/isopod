# Managing and customizing a box

This covers shaping a box beyond `isopod create`: choosing or building its base
image, adding a system package to a running box, forwarding a port to a server
inside it, changing its settings after the fact, reading its state as JSON, and
the environment variables that tune all of it.

## Customizing the container

The base image is defined by a standard Dockerfile, [`share/Dockerfile`](../share/Dockerfile) — built identically by `docker build` and `podman build`. On top of whatever base you choose it adds sshd, git, common CLI tooling, the unprivileged in-container user, and an administrative root key (add in-box passwordless sudo with `--sudo`). There are two ways to shape it:

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

Your Dockerfile must use a Debian/Ubuntu (`apt`) base, since isopod's layer installs sshd with `apt-get`. A trailing `USER` in your Dockerfile doesn't change the box's privilege model — isopod's layer resets to root (sshd must be PID 1 as root) and you log in as the unprivileged in-box user. **Privilege inside the box is limited by default** (the in-box user has no sudo; use `--sudo` to opt in), and that is set by isopod, not the base image's `USER` — isopod's SSH model supersedes it. (isopod's real boundary is host isolation + rootless userns, not in-container rootlessness; see [The isolation model](security-model.md#the-isolation-model).)

Because the image is built before the container exists (and `--repo` clones *inside* the box afterward), the Dockerfile is a host-side file you point at — not something read from the cloned repo. For quick one-offs you can still install toolchains interactively with `isopod shell`.

isopod runs box operations (clone, copy-in, export, fetch) over a non-interactive SSH command, which uses the system `PATH`, not the one your `~/.bashrc` builds. Install tools system-wide (in the Dockerfile, or with `sudo` in the box) so these operations can find them; a tool only on a shell-rc `PATH` is still available in `isopod shell`, just not to box operations.

## Adding a system package (`isopod install`)

Most dependencies don't need root: install language packages (`pip install --user`, `npm`, `cargo`) into your home directory from `isopod shell`. For the system packages that *do* need root — a `-dev` header, a CLI tool like `jq` — how you add them depends on the box's privilege posture:

- **Default (no-sudo) box:** the in-box user has no root, so the install comes from the host instead — either `isopod install` below, or `isopod root-shell <name> -- 'apt-get update && apt-get install -y jq'`.
- **`--sudo` box:** the in-box user has passwordless sudo, so `isopod shell <name> -- 'sudo apt-get update && sudo apt-get install -y jq'` works in-box.

```sh
isopod install <name> jq ripgrep    # runs the box's package manager as root, from the host
```

`isopod install` runs the box's package manager (`apt-get`/`apk`/`dnf`) as root **through the container engine from the host** — the same trust boundary as [egress](security-model.md#network-egress-isolation-egress-lan-deny) and [secrets](security-model.md#secrets). Because it enters through the engine rather than sshd, the boxed (unprivileged) agent can't reach it: the box stays locked down, but you can still add a forgotten dependency without recreating it.

**Why a host-mediated *named-package* install, rather than giving the agent sudo (or a root shell)?** In isopod's model the untrusted party is the agent running inside the box. Passwordless sudo hands *the agent* root for the whole session, not just you. And a root shell in the box — however you get it — can still be tricked into running agent-controlled code as root the moment you execute the project (a build, `npm install`, a `Makefile`) in the workspace the agent controls. Installing a *named package* through a host channel avoids both: the agent never gets root, and you're running the distro's package manager on a name **you** chose, not the box's code. It is the smaller, safer capability — so on a locked-down box, prefer `isopod install jq` over dropping into a root shell and building.

Two caveats. Installs are **ephemeral** — a fresh `create` starts without them (`reconfigure` snapshots the box, so they survive *that*). For a dependency you always need, bake it into a [`--dockerfile`](#customizing-the-container) instead. And `isopod install` needs a **container** box: the engine can't exec into a microVM guest, so on a microVM runtime add the package with `--dockerfile` and recreate.

## Reaching a server in the box (port forwarding)

A dev server inside the box (say `pnpm run start` on `:3000`) isn't on your host by default. Publish it with **`--expose`**, which maps a container port to a `127.0.0.1` host port — the standard `podman/docker run -p`, loopback-only:

```sh
isopod create web --repo <url> --expose 3001:3000   # box :3000 -> localhost:3001
isopod create web --repo <url> --expose 8080         # same port on both sides
```

Port mappings are set at create time (engine port mappings can't be added to a *running* container) and restored across stop/start. `isopod info <name>` lists them. To add or change ports later without starting over, use `isopod reconfigure` (below). In the VSCodium Remote-SSH window, ports a server opens are also auto-forwarded by the IDE.

## Changing a box after create (`reconfigure`)

A container's run settings — ports, memory, cpus, fingerprint masks — can't be edited in place; the engine bakes them in at creation. So every box has a readable config you can change, and isopod re-applies it for you:

```sh
isopod config web                       # view the box's config.yaml
isopod reconfigure web --expose 5173 --memory 8g   # or edit config.yaml, then:
isopod reconfigure web
```

The config lives at `~/.config/isopod/boxes/<name>/config.yaml` — and it's written as a **real, valid Compose service** (engine-correct: podman gets `security_opt: mask=…`, docker gets `tmpfs` directory masks — it can't mask `/proc` files), so you can read, copy, or adapt it elsewhere. But **isopod owns and parses it; it does not launch boxes from it** — a working box also needs the per-box SSH key, pinned host key, and cloned workspace that Compose can't set up, so `docker compose up` on it gives a bare container. isopod reads a few fields back on `reconfigure` (`ports`, `mem_limit`, `cpus`, `x-isopod-color`); the rest is a managed reference.

On `reconfigure`, isopod **snapshots the container to an image** (so your workspace *and* anything you `apt install`ed are preserved), then recreates it with the new settings, keeping the box's SSH key, host key, color, and ssh_config entry. The base image itself is that managed snapshot; to change the base, create a new box. (The Apple `container` engine has no image-commit primitive, so `reconfigure` isn't supported there — recreate the box instead. A box with a [`--disk` volume](security-model.md#data-volumes---disk-and-nested-containers---nested-containers) is also excluded, because its backing image sits in the layer being snapshotted.)

## Machine-readable output

Three commands accept `--json` and print a single JSON document on stdout (no other text), for scripts and tools that drive isopod — such as the Podman Desktop dashboard extension:

| Command | Output |
| --- | --- |
| `isopod list --json` | Array of box summaries: `name`, `status`, `ssh_host`, `port`, `color`, `engine` |
| `isopod info <name> --json` | One box object: the summary fields plus `forwards`, `secrets` (names only), `workspace` |
| `isopod egress status --json` | Egress state: `mode`, `firewall`, `network`, `subnet`, `dns`, `proxy` |

`port` and `color` are `null` when unknown; `forwards` and `secrets` are empty arrays when unset. Fields may be added over time but are not renamed or removed; errors still exit non-zero with a message on stderr.

## Environment variables

`ISOPOD_ENGINE` (`podman`|`docker`) — engine override.
`ISOPOD_CONFIG_DIR` — state location (default `~/.config/isopod`).
`ISOPOD_BUILD_ARGS` — extra args for `build` (e.g. `--network=host`,
`--build-arg http_proxy=...` behind corporate proxies). Host mounts into the
build, and overrides of the build args isopod sets itself (`ISOPOD_BASE`,
`ISOPOD_DEV_TOOLS`, `ISOPOD_NESTED`, …), are refused: those are hashed into the
image cache tag, so overriding one caches a different image under the legitimate
image's tag. Use `--image`, `--dev` or `--nested-containers` instead.
`ISOPOD_RUN_ARGS` — extra args for `run` (e.g. custom DNS). For an offline box
use `isopod create --offline`: `--network none` here is always refused, since it
takes the box off the loopback publish isopod reaches sshd through, and any
`--network` is refused when isopod already chose the box's network for an egress
mode or `--offline`. A custom network is yours to set where isopod chose none. Args that would undo the sandbox
(`-v`, `--mount`, `--privileged`, `--userns`, `--pid`, `--cap-add`,
`--security-opt`, `--network host`), restore in-box privilege (`--user`,
`--group-add`), or replace what runs the box (`--entrypoint`, `--runtime`) are
refused. So is any `-e ISOPOD_*` (and `--env-file`): isopod passes the box's
security policy in those variables and these args land after them, where a
duplicate key wins, so `-e ISOPOD_SUDO=1` would re-arm sudo on a `--no-sudo` box
while `isopod info` still reported it as one. Other env vars are fine.
`ISOPOD_ALLOW_UNSAFE_RUN_ARGS` — set to `1` to confirm you mean one of the
refused args above, for the rare environment that genuinely needs it.
`ISOPOD_RUNTIME` — sandboxed runtime overriding the hardening profile: Tier 2 (`runsc`) or a Tier 3 microVM (`kata` or `krun`; needs `/dev/kvm`). A configured runtime that isn't registered with the engine fails `create` closed with a clear error. Setup, krun networking, and the `crun-vm` exclusion: [docs/security-model.md](security-model.md).
`ISOPOD_MICROVM_MEMORY` — default guest memory when a Tier 3 microVM runtime is active and no `--memory` is given (default `2g`).
`ISOPOD_MICROVM_ANNOTATIONS` — space-separated `krun.*` OCI annotations passed to a microVM guest (e.g. `krun.nested_virt=1`); Podman only.
`ISOPOD_HARDENING_CONF` — path to an alternate baseline [fingerprint-hardening profile](security-model.md#fingerprint-hardening) (advanced; for per-user tweaks layer an override at `~/.config/isopod/hardening.conf` instead).

`ISOPOD_SSH_WAIT_TRIES` — how many 1s attempts `create`/`start` make waiting for sshd before giving up (default `30`).

[Network egress isolation](security-model.md#network-egress-isolation-egress-lan-deny) has its own overrides: `ISOPOD_EGRESS` (`lan-deny`|`allow-list`|off), `ISOPOD_EGRESS_NET`, `ISOPOD_EGRESS_SUBNET`, `ISOPOD_EGRESS_GATEWAY`, `ISOPOD_EGRESS_DNS`, `ISOPOD_EGRESS_RULESET` (the network/firewall parameters), and `ISOPOD_EGRESS_ALLOW_UNLOADED=1` to start a box even when the host firewall isn't loaded yet (otherwise `create` fails closed). The [`allow-list`](security-model.md#network-egress-allow-list-egress-allow-list) mode adds `ISOPOD_EGRESS_PROXY_PORT`, `ISOPOD_EGRESS_PROXY_BIN`, `ISOPOD_EGRESS_ALLOWLIST` (allow-list file), and `ISOPOD_EGRESS_ALLOWLIST_RULESET`. macOS adds a further set (`ISOPOD_EGRESS_BACKEND`, `ISOPOD_PF_SUBNET`, and the pf/LaunchDaemon paths) — see [docs/macos-host-egress.md](macos-host-egress.md).
