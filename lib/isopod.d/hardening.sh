#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines hardening profile parsing and runtime resolution.

# Translate the hardening profile into `$ENGINE run` flags, printed one per line
# for the caller to read into an array. Anti-fingerprinting (mask host-revealing
# /proc and /sys paths) + an optional sandboxed runtime like gVisor. The masks
# are a Tier 1/2 measure only: a Tier 3 microVM has its own kernel and virtual
# devices, so they are skipped there (see the tier check below).
#
# Layered: the shipped baseline (HARDENING_CONF) is read first, then the user's
# own overrides (USER_HARDENING_CONF, in their config dir) on top — so a tweak
# never silently drops the baseline, and upgrades keep delivering new masks.
# Directives: `mask <path> [file]`, `unmask <path>` (drop a baseline mask),
# `runtime <name>`, `no-runtime`.
#
# The two engines mask differently:
#   podman — a single `--security-opt mask=a:b:c` covers both files and dirs.
#   docker — no mask flag, so dirs get an empty `--tmpfs`. Docker/runc REFUSES a
#            bind mount onto an arbitrary /proc file (only a fixed allowlist is
#            permitted), so file masks (/proc/cmdline, /proc/modules) can't be
#            applied there — they are skipped and build_run_args warns once.
# Missing baseline is non-fatal: the box is still created, just without masks.

# Parsed hardening profile. Bash can't return arrays, so parse_hardening sets
# these globals for both hardening_run_args (the formatter) and build_run_args
# (which warns about masks Docker can't apply). Returns 1 if no profile exists.
HARD_RUNTIME=""
HARD_MASKS=()
HARD_FMASKS=()
parse_hardening() {
  HARD_RUNTIME=""
  HARD_MASKS=()
  HARD_FMASKS=()
  local -a conf_files=()
  [ -f "$HARDENING_CONF" ] && conf_files+=("$HARDENING_CONF")
  [ -f "$USER_HARDENING_CONF" ] && conf_files+=("$USER_HARDENING_CONF")
  [ "${#conf_files[@]}" -eq 0 ] && return 1

  local runtime="" key path kind line conf m
  local -a masks=() fmasks=() keep=()
  for conf in "${conf_files[@]}"; do
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"                       # strip comments
      read -r key path kind <<<"$line" || true # whitespace-split + trim
      [ -n "${key:-}" ] || continue
      case "$key" in
        runtime) runtime="${path:-}" ;;
        no-runtime) runtime="" ;;
        mask)
          [ -n "${path:-}" ] || continue
          if [ "${kind:-}" = "file" ]; then fmasks+=("$path"); else masks+=("$path"); fi
          ;;
        unmask) # drop a baseline mask (by path), from either dir or file masks
          [ -n "${path:-}" ] || continue
          keep=()
          for m in "${masks[@]:-}"; do [ -n "$m" ] && [ "$m" != "$path" ] && keep+=("$m"); done
          masks=("${keep[@]:-}")
          keep=()
          for m in "${fmasks[@]:-}"; do [ -n "$m" ] && [ "$m" != "$path" ] && keep+=("$m"); done
          fmasks=("${keep[@]:-}")
          ;;
        egress | no-egress) ;; # network egress isolation, resolved by active_egress
        *) warn "hardening profile: ignoring unknown directive '$key'" ;;
      esac
    done <"$conf"
  done

  # env var wins over the profile so it can be toggled per invocation.
  HARD_RUNTIME="${ISOPOD_RUNTIME:-$runtime}"
  # --container (resolve_runtime) forces a plain Tier 1 container: no runtime flag,
  # overriding ISOPOD_RUNTIME and any `runtime` directive. Keep this in step with
  # the same check in active_runtime so the run flag and the resolved tier agree.
  [ "${ISOPOD_FORCE_CONTAINER:-0}" = 1 ] && HARD_RUNTIME=""
  # Copy into the globals, dropping any empty slots an unmask left behind, so
  # callers can trust "${#HARD_FMASKS[@]}" as a real count.
  for m in "${masks[@]:-}"; do [ -n "$m" ] && HARD_MASKS+=("$m"); done
  for m in "${fmasks[@]:-}"; do [ -n "$m" ] && HARD_FMASKS+=("$m"); done
  return 0
}

# Resolve the value handed to `--runtime` for a given engine. podman accepts a
# name registered in its containers.conf [engine.runtimes] map OR an absolute
# path to the runtime binary — it does NOT invoke a bare name from PATH. So the
# default-registered name for Kata is `kata`, and a bare `kata-runtime` fails
# with 'default OCI runtime "kata-runtime" not found' even though the binary is
# on PATH. When the name is a bare, on-PATH binary, hand podman its absolute path
# so it runs regardless of what containers.conf happens to register. A value that
# already contains a slash is a path; a name whose binary is not on PATH (e.g.
# `kata-qemu`, a containers.conf alias, not a binary) is passed through so
# podman's map can resolve it. docker only accepts registered names, so it is
# always passed through unchanged.
resolve_runtime_flag() { # resolve_runtime_flag <engine> <name>
  local engine="$1" name="$2" path
  case "$name" in '' | */*)
    printf '%s' "$name"
    return 0
    ;;
  esac
  if [ "$engine" = "podman" ] && path="$(command -v "$name" 2>/dev/null)"; then
    printf '%s' "$path"
    return 0
  fi
  printf '%s' "$name"
}

hardening_run_args() { # hardening_run_args <engine>
  local engine="$1"
  if ! parse_hardening; then
    warn "hardening profile not found ($HARDENING_CONF); creating box without fingerprint masks"
    return 0
  fi

  [ -n "$HARD_RUNTIME" ] &&
    printf '%s\n' "--runtime" "$(resolve_runtime_flag "$engine" "$HARD_RUNTIME")"

  # The masks below hide HOST hardware that a Tier 1 container reads through the
  # shared kernel's /proc and /sys. A Tier 3 microVM has its own guest kernel and
  # only virtual devices (krun's synthetic DMI, a virtio NIC/PCI bus), so those
  # same paths expose nothing about the host — the VM boundary is the isolation,
  # not the masks. Skip them there: they protect nothing, and emitting host-
  # fingerprint masks under a microVM would misrepresent what is doing the work.
  [ -n "$HARD_RUNTIME" ] && [ "$(runtime_tier "$HARD_RUNTIME" 2>/dev/null)" = 3 ] && return 0

  local p
  if [ "$engine" = "docker" ]; then
    for p in "${HARD_MASKS[@]:-}"; do [ -n "$p" ] && printf '%s\n' "--tmpfs" "$p"; done
    # File masks intentionally omitted on Docker (runc rejects /proc binds);
    # build_run_args surfaces the one-time warning.
  else
    local joined=""
    for p in "${HARD_MASKS[@]:-}" "${HARD_FMASKS[@]:-}"; do
      [ -n "$p" ] && joined="${joined:+$joined:}$p"
    done
    [ -n "$joined" ] && printf '%s\n' "--security-opt" "mask=$joined"
  fi
}

# The runtime isopod will run boxes under, resolved the same way as the box
# flags: ISOPOD_RUNTIME wins, else the last `runtime`/`no-runtime` across the
# shipped baseline and the user override. Echoes nothing when no runtime is set.
active_runtime() {
  # --container (resolve_runtime sets this): force a plain Tier 1 container,
  # overriding any configured runtime. Wins over ISOPOD_RUNTIME / directives.
  [ "${ISOPOD_FORCE_CONTAINER:-0}" = 1 ] && return 0
  if [ -n "${ISOPOD_RUNTIME:-}" ]; then
    printf '%s' "$ISOPOD_RUNTIME"
    return 0
  fi
  local f key val r=""
  for f in "$HARDENING_CONF" "$USER_HARDENING_CONF"; do
    [ -f "$f" ] || continue
    while read -r key val _; do
      case "$key" in
        runtime) r="$val" ;;
        no-runtime) r="" ;;
      esac
    done <"$f"
  done
  printf '%s' "$r"
}

# Tier of a runtime from the share/runtimes table: 2 (syscall sandbox) or 3
# (microVM). Returns 1 (no output) when the runtime is unlisted or the table is
# missing, so callers treat it as "tier unknown".
runtime_tier() { # runtime_tier <name>
  local want="$1" f="$ISOPOD_SHARE/runtimes" name tier
  [ -n "$want" ] && [ -f "$f" ] || return 1
  while read -r name tier _; do
    case "$name" in '' | '#'*) continue ;; esac
    [ "$name" = "$want" ] && {
      printf '%s' "$tier"
      return 0
    }
  done <"$f"
  return 1
}

# Guest network stack of a runtime from the share/runtimes table (column 3):
# 'virtio'/'netstack' (SSH forwarding + bulk transfers work) or 'tsi' (libkrun
# Transparent Socket Impersonation, which stalls bulk SSH transfers and so breaks
# Remote-SSH and copy/export). Echoes nothing for an unlisted runtime.
runtime_net() { # runtime_net <name>
  local want="$1" f="$ISOPOD_SHARE/runtimes" name tier net
  [ -n "$want" ] && [ -f "$f" ] || return 1
  while read -r name tier net _; do
    case "$name" in '' | '#'*) continue ;; esac
    [ "$name" = "$want" ] && {
      printf '%s' "$net"
      return 0
    }
  done <"$f"
  return 1
}

# True when the configured runtime is a Tier 3 microVM (its own guest kernel).
is_microvm_runtime() {
  [ "$(runtime_tier "$(active_runtime)" 2>/dev/null)" = 3 ]
}

# Is an OCI runtime usable by the engine? True when the binary is on PATH (for
# podman, hardening_run_args passes such a bare name as an absolute path, which
# podman accepts) OR the engine reports it among its registered runtimes. Best-
# effort: a false "unavailable" only ever downgrades to a warning at doctor time,
# and preflight double-checks before a run.
runtime_available() { # runtime_available <engine> <name>
  local engine="$1" name="$2"
  [ -n "$name" ] || return 1
  have "$name" && return 0
  # `<engine> info` lists registered runtimes (podman: the ociRuntimes map;
  # docker: the Runtimes section). Match the name as a whole token — treating '-'
  # as part of it — so a short name (kata, runsc) is not falsely found inside a
  # longer one (kata-runtime, runsc-kvm), which would auto-select a runtime the
  # engine cannot actually invoke.
  "$engine" info 2>/dev/null | grep -qE "(^|[^[:alnum:]_-])${name}([^[:alnum:]_-]|\$)"
}

# Fail-closed preflight for the configured OCI runtime, mirroring egress_preflight:
# turn a late, cryptic engine error ("runtime not found") into an early, clear one,
# and make sure a box the user asked to run under a sandboxed runtime does not
# silently start without it. No-op when no runtime is configured or the runtime is
# a custom one isopod cannot classify (unknown tier — pass it straight through).
runtime_preflight() { # runtime_preflight <engine>
  local rt
  rt="$(active_runtime)"
  [ -n "$rt" ] || return 0
  local tier
  tier="$(runtime_tier "$rt" 2>/dev/null || true)"
  [ -n "$tier" ] || return 0
  local engine="$1"
  if ! runtime_available "$engine" "$rt"; then
    die "runtime '$rt' (Tier $tier) is not on PATH or registered with '$engine', so the box
     cannot start under it. Install and register the runtime with your engine, or remove the
     'runtime' directive from hardening.conf (and unset ISOPOD_RUNTIME) to run without it."
  fi
  # A Tier 3 microVM needs hardware virtualization. On a native Linux host that is
  # /dev/kvm; a missing node means the run will almost certainly fail. Warn rather
  # than die: on macOS/Windows the engine runs in its own VM (libkrun uses HVF /
  # Hyper-V there), so a host /dev/kvm check would be a false negative.
  if [ "$tier" = 3 ] && [ "$(uname -s)" = Linux ] && [ ! -e /dev/kvm ]; then
    warn "microVM runtime '$rt' needs hardware virtualization but /dev/kvm is absent on this host.
     The box will likely fail to start. Enable KVM (or nested virt), or switch to a Tier 2
     runtime (runsc) / the Tier 1 masks. See 'isopod doctor'."
  fi
}

# True when a headline sandboxed runtime is available (binary on PATH or registered
# with a present engine). Used by the doctor detection hints below.
_runtime_present() { # _runtime_present <name>
  local name="$1" e
  have "$name" && return 0
  for e in podman docker; do
    have "$e" && runtime_available "$e" "$name" && return 0
  done
  return 1
}

# Doctor hints: which sandboxed runtimes are available to enable. A curated set of
# headline names (not the full share/runtimes table) keeps the hint short, and lists
# the strongest tier first. detect_microvm_runtimes = Tier 3 only (own kernel/DMI);
# detect_sandboxed_runtimes = Tier 3 then Tier 2 (runsc syscall sandbox).
detect_microvm_runtimes() {
  local n out=""
  for n in krun kata-runtime; do _runtime_present "$n" && out="${out:+$out }$n"; done
  printf '%s' "$out"
}
detect_sandboxed_runtimes() {
  local n out=""
  for n in krun kata-runtime runsc; do _runtime_present "$n" && out="${out:+$out }$n"; done
  printf '%s' "$out"
}

# True when a runtime can actually run a box under <engine> right now: it is
# available (on PATH / registered), and — for a Tier 3 microVM — the host has
# hardware virtualization (/dev/kvm on Linux; assumed present off-Linux, where the
# engine runs in its own VM). Used to pick the default runtime and to fall back.
_runtime_runnable() { # _runtime_runnable <engine> <name>
  local engine="$1" name="$2" tier
  runtime_available "$engine" "$name" || return 1
  tier="$(runtime_tier "$name" 2>/dev/null || true)"
  if [ "$tier" = 3 ] && [ "$(uname -s)" = Linux ] && [ ! -e /dev/kvm ]; then
    return 1 # microVM runtime present but no KVM to back it
  fi
  return 0
}

# Resolve the EFFECTIVE runtime for a create, defaulting to a microVM.
# Precedence:
#   1. --container      -> plain Tier 1 container (sets ISOPOD_FORCE_CONTAINER)
#   2. explicit runtime -> honored as-is (ISOPOD_RUNTIME / `runtime` directive)
#   3. default          -> strongest RUNNABLE sandbox: a virtio-net microVM (kata)
#      if installed and KVM is present, else gVisor (runsc), else a plain
#      container. Each step down from a microVM warns loudly.
# Sets ISOPOD_RUNTIME (or ISOPOD_FORCE_CONTAINER) in-process for the rest of the run.
resolve_runtime() { # resolve_runtime <engine> <container_opt 0|1>
  local engine="$1" container_opt="${2:-0}" explicit rt
  explicit="$(active_runtime)"
  if [ "$container_opt" = 1 ]; then
    [ -n "$explicit" ] &&
      info "--container overrides the configured runtime '$explicit' — running as a plain container"
    export ISOPOD_FORCE_CONTAINER=1
    return 0
  fi
  [ -n "$explicit" ] && return 0 # user picked a runtime; respect it
  # Default: pick the strongest RUNNABLE microVM whose guest networking carries
  # a bulk SSH port-forward into a loopback service — that is how VSCodium/Cursor/
  # JetBrains ('isopod code') reach their remote server. krun is driven with passt
  # (a real virtio-net stack; build_run_args adds krun.use_passt), so it qualifies
  # like kata. A runtime whose net is 'tsi' — libkrun's DEFAULT, which stalls that
  # forward — is never auto-selected; no shipped runtime is 'tsi' now (krun uses
  # passt), but the guard stays for any future/unlisted one. The table drives this.
  local tier net tsi_only=""
  while read -r rt tier net _; do
    case "$rt" in '' | '#'*) continue ;; esac
    [ "$tier" = 3 ] || continue
    _runtime_runnable "$engine" "$rt" || continue
    if [ "$net" = tsi ]; then
      tsi_only="${tsi_only:-$rt}" # remember it to explain the fallback below
      continue
    fi
    export ISOPOD_RUNTIME="$rt"
    info "microVM runtime '$rt' selected by default (strong isolation; opt out with --container)"
    return 0
  done <"$ISOPOD_SHARE/runtimes"
  if [ -n "$tsi_only" ]; then
    warn "the only microVM runtime available ('$tsi_only') uses libkrun TSI networking, which
   stalls bulk data over an SSH port-forward into the box — the path VSCodium/Cursor/JetBrains
   use to reach their remote server, so 'isopod code' can't connect. Not selecting it by default.
   Install kata (the supported Tier 3 microVM) for a working default, or pass
   '--runtime $tsi_only' to use it for 'isopod shell'/copy/export (exec channels, unaffected)."
  else
    warn "no usable microVM runtime found (need kata + /dev/kvm).
   isopod defaults to a microVM for isolation; falling back to a weaker sandbox. Install one for
   full isolation, or pass --container to select a plain container without this warning."
  fi
  if _runtime_runnable "$engine" runsc; then
    export ISOPOD_RUNTIME="runsc"
    warn "using gVisor (runsc, Tier 2 syscall sandbox) instead of a microVM"
    return 0
  fi
  warn "no IDE-capable sandboxed runtime available — running as a PLAIN CONTAINER (Tier 1, weakest
   isolation). Install kata (Tier 3 microVM) or gVisor (runsc) to harden.
   See: isopod doctor"
  export ISOPOD_FORCE_CONTAINER=1
  return 0
}
