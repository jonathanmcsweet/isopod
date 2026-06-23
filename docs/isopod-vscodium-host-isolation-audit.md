# VSCodium Remote-SSH Host-Information Isolation Audit

**Project:** isopod (disposable AI-coding sandboxes, VSCodium → Podman container over SSH)
**Question:** Can an AI agent extension running in the container see information about the host machine?
**Verdict:** No — under the isopod configuration, no host-derived information crosses into the container at runtime. The isolation is structural, not behavioral.

## Scope

Sources audited (all at the versions isopod tracks):

| Component | Repo | Version |
|---|---|---|
| VSCodium build/patches | `VSCodium/vscodium` | tracks upstream 1.121.0 |
| Upstream editor + remote server | `microsoft/vscode` | tag `1.121.0`, commit `987c9597516278c9fcf10d963a0592ce1384ab93` |
| Remote-SSH extension | `jeanp413/open-remote-ssh` | latest `main` |

"Host info" was treated broadly: host filesystem paths and file contents, host environment variables, hostname, host network/machine identity, and telemetry that could carry any of these.

## Architecture in one sentence

In the Remote-SSH model the editor splits in two: a thin **client** on your host that does UI and SSH transport, and a **server** (the "REH" — remote extension host) that runs *inside the container*. AI agent extensions (Cline, Continue, Roo, etc.), the integrated terminal, and all of their tool/shell execution run in the **server** process — inside the container — so the environment they observe is the container's, not the host's.

The audit reduces to one question: **what data, if any, crosses from host → container?** There are only three candidate channels, and all three are clean under isopod.

---

## Finding 1 — The remote extension host's environment is the container's own `process.env`

This is the decisive evidence. When the in-container server spawns the extension host process (where agent code executes), it builds that process's environment in `buildUserEnvironment()`.

**`microsoft/vscode` → `src/vs/server/node/extensionHostConnection.ts`, lines 26–70:**

```ts
const processEnv = process.env;            // line 38 — the SERVER's env = the CONTAINER's env

const env: IProcessEnvironment = {
    ...processEnv,                         // container env
    ...userShellEnv,                       // container login shell env (also container-side)
    ...{ VSCODE_ESM_ENTRYPOINT, ... },     // constants
    ...startParamsEnv                      // <-- the ONLY host-originated input (see Finding 3)
};
```

Because this code executes inside the container, `process.env` is the container's environment. `userShellEnv` (line 32, `getResolvedShellEnv(... process.env)`) is the container user's login-shell environment — also container-side. The only externally supplied piece is `startParamsEnv`, analyzed in Finding 3.

An agent that reads `process.env`, runs `env`, `hostname`, `whoami`, or inspects `/proc` therefore sees the container and nothing else.

## Finding 2 — The integrated terminal's base environment is also the container's `process.env`

Agents most often act by running shell commands in the integrated terminal. That terminal is spawned server-side, and its base environment comes from the same source.

**`microsoft/vscode` → `src/vs/server/node/remoteTerminalChannel.ts`, lines 333–335:**

```ts
private _getEnvironment(): platform.IProcessEnvironment {
    return { ...process.env };              // container-side process.env
}
```

This base env is merged with workspace config in `terminalEnvironment.ts` (`createTerminalEnvironment`, ~line 250+), but the root is always the container process. No host env is mixed in.

## Finding 3 — The single host → container channel carries nothing host-identifying (and is empty under isopod)

The only way host data can reach the server is the resolver's `extensionHostEnv`, set by the Remote-SSH extension.

**`jeanp413/open-remote-ssh` → `src/authResolver.ts`, lines 247–309:**

```ts
const envVariables: Record<string, string | null> = {};   // line 247 — starts EMPTY
if (agentForward) {
    envVariables['SSH_AUTH_SOCK'] = null;                  // line 249 — only key, only if agent forwarding
}
// ... installCodeServer reads these names INSIDE the container ...
resolvedResult.extensionHostEnv = envVariables;            // line 309 — handed to the server
```

Key points:

- `envVariables` is initialized empty (line 247).
- The **only** key it can ever contain is `SSH_AUTH_SOCK`, and **only when SSH agent forwarding is enabled** (line 249).
- Even then, the resolved value is a *container-side* socket path produced by the install script, not host data.
- This object becomes `startParamsEnv` in Finding 1 — so when it's empty, the host contributes literally nothing to the extension host environment.

**isopod relevance:** isopod disables agent forwarding (`ForwardAgent no`; agent + X11 forwarding are explicitly off in the design). With forwarding off, the `if (agentForward)` branch never runs, `extensionHostEnv` is `{}`, and the host → container env channel is closed entirely.

## Finding 4 — The connection handshake carries no host identifiers

The remaining theoretical channel is the client→server handshake. It carries no hostname, username, machine ID, or host path.

**`microsoft/vscode` → `src/vs/platform/remote/common/remoteAgentConnection.ts`, lines 55–61:**

```ts
export interface ConnectionTypeRequest {
    type: 'connectionType';
    commit?: string;          // build commit only
    signedData: string;       // auth challenge response
    desiredConnectionType?: ConnectionType;
    args?: any;
}
```

Only a build `commit`, an auth token, and connection/reconnection tokens are sent. In a VSCodium build the `commit` check is additionally bypassed by VSCodium's `00-remote-disable-client-validation.patch`, so it isn't even compared.

---

## Threat-model assessment

| Threat | Outcome | Why |
|---|---|---|
| **Honest extension, accidental leak** | Safe | There is no host data in the extension-host process to leak. |
| **Curious / actively malicious extension** | Safe (for host info) | The boundary is enforced by *where the code runs* (a process inside the container), not by extension good behavior. It can freely read container env/fs/network and still learn nothing about the host. |
| **Compromised / supply-chain extension** | Host stays invisible, but see caveat | It cannot see the host, but the extension host has full network egress *from inside the container* and can transmit whatever it learns about the container. Containing that is a container-network-policy matter (egress firewalling on the Podman network), not a VSCodium code issue — and is exactly as strong as the container boundary itself (the Podman-vs-KVM tradeoff). |

## Telemetry note

VSCodium's `00-telemetry-disable.patch` flips every telemetry, crash-reporting, experiment, and online-search default to off. The VSCodium client also runs host-side and never sees container internals. So the editor itself is not a leak vector. Independent **extension** telemetry, however, runs in the container and is governed by the container's network policy (see supply-chain row above).

## Residual caveats (configuration, not code)

These do not leak host info into the container's runtime, but they are where the guarantee could erode in practice, so keep them clean:

1. **Agent forwarding** — re-enabling it reopens the one env channel (Finding 3). Keep `ForwardAgent no`.
2. **`remote.SSH.defaultExtensions`** — auto-installs the listed extensions into *every* box. Anything malicious here lands in all sandboxes by default.
3. **Host paths in `~/.ssh/config`** (`ProxyCommand`, `IdentityFile`) — read host-side; could surface host paths in client-side logs. They don't enter the container, but keep them tidy.

## Bottom line

Under the isopod configuration (no agent forwarding, no bind mounts, files entering only via in-container `git clone`/explicit copy), an AI agent extension cannot see host environment variables, hostname, host filesystem, or host network identity. The protection comes from the architecture — the extension host is a process inside the container, and every environment-construction path roots in that container's own `process.env` — not from trusting the extension. The one thing the architecture does *not* constrain is what a compromised extension can transmit outward over the container's network; that is governed by your container egress policy.

## How to verify empirically

A companion script, `verify-host-isolation.sh`, connects to a running box and dumps what the extension host and terminal actually see (env, hostname, identity, mounts, key host-path probes), so you can confirm on each VSCodium build rather than relying solely on this code read.
