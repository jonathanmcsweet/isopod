#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines engine detection, box metadata/config, validation, image build.

# ---------------------------------------------------------------------------
# engine detection
# ---------------------------------------------------------------------------
ENGINE=""
detect_engine() {
  local want="${1:-${ISOPOD_ENGINE:-}}"
  if [ -n "$want" ]; then
    have "$want" || die "requested engine '$want' not found in PATH"
    ENGINE="$want"
  elif have podman; then
    ENGINE=podman
  elif have docker; then
    ENGINE=docker
  elif have container; then
    # macOS-only fallback: Apple `container` (per-box VM + host-pf egress). Only
    # auto-selected when neither podman nor docker is installed; otherwise opt in
    # with ISOPOD_ENGINE=container or --engine container.
    ENGINE=container
  else
    die "no container engine found (podman, docker, or Apple 'container'). Install one (podman recommended on Linux; Apple 'container' on macOS)."
  fi
  # Sanity check the engine actually works (daemon up / machine / service started).
  # Apple `container` has no `info`; its liveness is `container system status`.
  if ! engine_healthcheck "$ENGINE"; then
    case "$ENGINE" in
      podman)
        # The usual Linux cause is a missing subordinate UID/GID range; name it
        # instead of the macOS advice, which does not apply there.
        if is_linux && ! subid_ranges_ok; then
          die "podman is installed but not working.
$(subid_fix_hint)"
        fi
        die "podman is installed but not working. On macOS run: podman machine init && podman machine start"
        ;;
      docker) die "docker is installed but the daemon is not reachable. Start Docker (or Docker Desktop) and retry." ;;
      container) die "Apple 'container' is installed but its service is not running. Start it: container system start" ;;
      *) die "engine '$ENGINE' is not responding." ;;
    esac
  fi
}

# Liveness probe per engine. podman/docker: `info`. Apple `container` (macOS,
# per-box VM on a vmnet subnet — see docs/macos-host-egress.md): `system status`.
# NOTE: the Apple `container` backend is EXPERIMENTAL. The box lifecycle
# (create/code/shell/start/stop/rm) is wired to its CLI and validated on macOS 26;
# `reconfigure` is unsupported (container has no image commit) and `install` needs
# further validation. Enable with ISOPOD_ENGINE=container or --engine container.
engine_healthcheck() { # engine_healthcheck <engine>
  case "$1" in
    container) container system status >/dev/null 2>&1 ;;
    *) "$1" info >/dev/null 2>&1 ;;
  esac
}

# Rootless podman maps the box's users through a subordinate UID/GID range
# assigned to the invoking user in /etc/subuid and /etc/subgid. Fedora and
# Debian/Ubuntu add one when the account is created; Arch and Gentoo leave both
# files empty, so podman fails with "no subuid ranges found for user". Returns 0
# when a range exists, or when the check does not apply (macOS, or running as
# root, where podman is rootful and needs no mapping).
subid_ranges_ok() {
  is_linux || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  local f user uid
  user="$(id -un)"
  uid="$(id -u)"
  for f in "$SUBUID_FILE" "$SUBGID_FILE"; do
    [ -r "$f" ] || return 1
    # Exact field match via awk (not a regex), so a username with regex
    # metacharacters can't match the wrong line. Either form counts: shadow
    # writes the name, some tools write the numeric uid.
    awk -F: -v u="$user" -v n="$uid" '$1 == u || $1 == n { found = 1 } END { exit !found }' "$f" ||
      return 1
  done
}

# How to add the missing range (share/rootless-subid.txt). Printed by both the
# engine error and `isopod doctor`.
subid_fix_hint() {
  # Consumed by the template via render_tmpl (invisible to the linter).
  local sub_user
  sub_user="$(id -un)"
  : "$sub_user"
  render_tmpl rootless-subid.txt
}

ctr_name() { printf 'isopod-%s' "$1"; }
box_dir() { printf '%s/%s' "$BOXES_DIR" "$1"; }

require_box() {
  # Validate before deriving any path from the name. create validates on the way
  # in, but every other command reaches box_dir/meta/rm through here, so a
  # traversal name (isopod rm '../../dir') must be refused here, not just trusted
  # to be an existing directory.
  valid_name "$1" || die "invalid sandbox name: '$1' (letters, digits, . _ - only)"
  [ -d "$(box_dir "$1")" ] || die "no such sandbox: '$1' (see: isopod list)"
}

# Whether engine invocations for the current box must run AS the sandbox account.
# An account box's container and images live only in that account's rootless
# store, so every engine op for it — run, start, inspect, rm, build, commit —
# has to run as the account or it simply would not see them. Set per box by
# open_box (from meta) and by cmd_create (from --account); 0 for every other box,
# so a normal box is completely unaffected.
ISOPOD_ENGINE_AS_ACCOUNT=0

# Run the container engine, as the sandbox account when the current box uses it.
# This is the ONE chokepoint: every "$ENGINE" invocation goes through here, so
# routing is a single decision rather than 50 scattered ones. A non-account box
# (the default) takes the direct path, byte-for-byte the old behaviour.
engine() { # engine <engine-args...>
  if [ "${ISOPOD_ENGINE_AS_ACCOUNT:-0}" != 1 ]; then
    "$ENGINE" "$@"
    return
  fi
  local uid
  uid="$(id -u "$ISOPOD_ACCOUNT" 2>/dev/null)" ||
    die "box uses the sandbox account, but it does not exist — run: sudo isopod account setup"
  [ -d "/run/user/$uid" ] ||
    die "the sandbox account has no runtime directory (/run/user/$uid) — run: sudo isopod account setup"
  # cd to / first: sudo -u inherits the caller's working directory, which is
  # normally a project dir under the user's home the account cannot enter, and
  # podman would fail with 'cannot chdir' before it even starts (spike note).
  # XDG_RUNTIME_DIR is passed via sudo's SETENV (granted in the sudoers file) so
  # rootless podman finds the account's runtime directory.
  (cd / && exec sudo -n -u "$ISOPOD_ACCOUNT" "XDG_RUNTIME_DIR=/run/user/$uid" "$ENGINE" "$@")
}

# Set the account-routing flag for a box from its meta. Called by open_box, so
# every box-context command routes correctly with no per-command wiring.
engine_ctx_for_box() { # engine_ctx_for_box <name>
  if [ "$(meta_get "$1" account 2>/dev/null || true)" = 1 ]; then
    ISOPOD_ENGINE_AS_ACCOUNT=1
  else
    ISOPOD_ENGINE_AS_ACCOUNT=0
  fi
}

# Common command entry: assert the box exists and select the engine it was
# created with (sets ENGINE). Commands that mutate shared state call acquire_lock
# themselves afterwards, since whether/why they lock varies.
open_box() { # open_box <name>
  require_box "$1"
  detect_engine "$(meta_get "$1" engine || true)"
  engine_ctx_for_box "$1"
}

meta_get() { # meta_get <name> <key>
  local f
  f="$(box_dir "$1")/meta"
  [ -f "$f" ] || return 1
  # Exact key match via awk (not a sed regex), so a key with regex
  # metacharacters can never be misinterpreted. Value may contain '='.
  awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/, ""); print; exit}' "$f"
}

meta_set() { # meta_set <name> <key> <value> — replace or append a meta line
  local f tmp
  f="$(box_dir "$1")/meta"
  tmp="$(mktemp "${TMPDIR:-/tmp}/isopod-meta-XXXXXX")"
  grep -v "^$2=" "$f" 2>/dev/null >"$tmp" || true
  printf '%s=%s\n' "$2" "$3" >>"$tmp"
  mv "$tmp" "$f"
}

meta_del() { # meta_del <name> <key> — drop a meta line (no-op if absent)
  local f tmp
  f="$(box_dir "$1")/meta"
  [ -f "$f" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/isopod-meta-XXXXXX")"
  grep -v "^$2=" "$f" 2>/dev/null >"$tmp" || true
  mv "$tmp" "$f"
}

# Per-box config.yaml — a real, valid Compose service describing the box, kept as
# a readable reference (see share/box-config.yaml). isopod owns it: it is rendered
# from meta and a few fields are read back by `isopod reconfigure`. isopod does
# NOT launch boxes from it (see the file's header for why).
box_config_file() { printf '%s/config.yaml' "$(box_dir "$1")"; }

# Render the box's hardening as engine-correct Compose YAML (indented 4 spaces),
# derived from the same hardening_run_args as the live `run` flags so the two
# can't drift: podman -> security_opt mask=...; docker -> tmpfs + /dev/null binds.
render_hardening_compose() { # render_hardening_compose <engine>
  local engine="$1" i=0 x runtime=""
  local -a flags=() sopts=() tmpfs=() vols=()
  mapfile -t flags < <(hardening_run_args "$engine")
  while [ "$i" -lt "${#flags[@]}" ]; do
    case "${flags[$i]}" in
      --security-opt) sopts+=("${flags[$((i + 1))]}") && i=$((i + 2)) ;;
      --tmpfs) tmpfs+=("${flags[$((i + 1))]}") && i=$((i + 2)) ;;
      -v) vols+=("${flags[$((i + 1))]}") && i=$((i + 2)) ;;
      --runtime) runtime="${flags[$((i + 1))]}" && i=$((i + 2)) ;;
      *) i=$((i + 1)) ;;
    esac
  done
  [ -n "$runtime" ] && printf '    runtime: %s\n' "$runtime"
  if [ "${#sopts[@]}" -gt 0 ]; then
    printf '    security_opt:\n'
    for x in "${sopts[@]}"; do printf '      - %s\n' "$x"; done
  fi
  if [ "${#tmpfs[@]}" -gt 0 ]; then
    printf '    tmpfs:\n'
    for x in "${tmpfs[@]}"; do printf '      - %s\n' "$x"; done
  fi
  if [ "${#vols[@]}" -gt 0 ]; then
    printf '    volumes:\n'
    for x in "${vols[@]}"; do printf '      - %s\n' "$x"; done
  fi
}

write_box_config() { # write_box_config <name>
  local name="$1" image created color memory cpus expose engine e
  local limits_block="" ports_block="" hardening_block=""
  image=$(meta_get "$name" image || true)
  created=$(meta_get "$name" created || true)
  color=$(meta_get "$name" color || true)
  memory=$(meta_get "$name" memory || true)
  cpus=$(meta_get "$name" cpus || true)
  expose=$(meta_get "$name" expose || true)
  engine=$(meta_get "$name" engine || true)
  [ -n "$memory" ] && limits_block+="    mem_limit: $memory"$'\n'
  [ -n "$cpus" ] && limits_block+="    cpus: \"$cpus\""$'\n'
  if [ -n "$expose" ]; then
    ports_block="    ports:"$'\n'
    # split on commas without changing IFS (a leaked IFS=, would break the
    # whitespace-split read in hardening_run_args, called below).
    # shellcheck disable=SC2086
    for e in ${expose//,/ }; do ports_block+="      - \"127.0.0.1:$e\""$'\n'; done
  fi
  hardening_block=$(render_hardening_compose "$engine")
  [ -n "$hardening_block" ] && hardening_block+=$'\n'
  # Consumed by the template via render_tmpl (invisible to the linter).
  : "$image" "$created" "$color" "$limits_block" "$ports_block" "$hardening_block"
  render_tmpl box-config.yaml >"$(box_config_file "$name")"
}

# Read a scalar service field from a box's config.yaml (indentation-tolerant,
# surrounding double-quotes stripped).
config_get() { # config_get <name> <key>
  local f v
  f="$(box_config_file "$1")"
  [ -f "$f" ] || return 1
  # Exact key match on the token before the first ':' (awk, not a sed regex), so
  # a key with regex metacharacters is safe. Strips indentation, the surrounding
  # whitespace, and one layer of double-quotes — matching the old behavior.
  v=$(awk -v k="$2" '
    { l = $0; sub(/^[[:space:]]+/, "", l)
      p = index(l, ":"); if (p == 0) next
      if (substr(l, 1, p - 1) == k) {
        val = substr(l, p + 1); sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
        print val; exit
      } }' "$f")
  v="${v%\"}"
  v="${v#\"}"
  printf '%s' "$v"
}

# Read the forwarded ports from a box's config.yaml as HOSTPORT:CONTAINERPORT, one
# per line. Ports are the `- "127.0.0.1:H:C"` list items (the loopback prefix
# distinguishes them from security_opt/tmpfs/volume list items).
config_expose() { # config_expose <name>
  local f
  f="$(box_config_file "$1")"
  [ -f "$f" ] || return 0
  sed -n 's/^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:\(.*\)"[[:space:]]*$/\1/p' "$f"
}

valid_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,40}$ ]]
}

valid_port() { # valid_port <n> -> true for a 1-65535 TCP port number
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_memory() { # valid_memory <v> -> integer + optional b/k/m/g unit (engine form)
  [[ "$1" =~ ^[0-9]+[bBkKmMgG]?$ ]]
}

valid_cpus() { # valid_cpus <v> -> a positive (optionally fractional) CPU count
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$1" != 0 && "$1" != 0.0 ]]
}

valid_ipv4() { # valid_ipv4 <a.b.c.d> -> true for a dotted-quad, each octet 0-255
  local o1 o2 o3 o4 rest o IFS=.
  read -r o1 o2 o3 o4 rest <<<"$1"
  [ -z "$rest" ] || return 1
  for o in "$o1" "$o2" "$o3" "$o4"; do
    case "$o" in '' | *[!0-9]*) return 1 ;; esac
    [ "${#o}" -le 3 ] && [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
}

valid_cidr() { # valid_cidr <a.b.c.d/nn> -> true for an IPv4 network in CIDR form
  case "$1" in */*) ;; *) return 1 ;; esac
  local ip="${1%/*}" bits="${1#*/}"
  valid_ipv4 "$ip" || return 1
  case "$bits" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#bits}" -le 2 ] && [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

valid_ifname() { # valid_ifname <name> -> a Linux netdev name (<=15 chars, safe charset)
  case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

# ---------------------------------------------------------------------------
# image build (share/Dockerfile)
# ---------------------------------------------------------------------------
# The image is defined by a standard Dockerfile (share/Dockerfile), built the
# same way by docker and podman. The base image and in-box user are passed as
# build args. The cache key hashes the Dockerfile, entrypoint, and sysctl
# baseline content + those args, so an edit to any forces a one-time rebuild
# on its own
# (IMAGE_LAYER_VERSION remains only as a manual force-rebuild override).
image_exists() { # image_exists <tag>
  engine image exists "$1" 2>/dev/null || engine image inspect "$1" >/dev/null 2>&1
}

image_tag_for() { # image_tag_for <base-image> [dev-tools 0|1] [nested 0|1]
  [ -f "$ISOPOD_DOCKERFILE" ] || die "missing Dockerfile: $ISOPOD_DOCKERFILE"
  [ -f "$ISOPOD_ENTRYPOINT" ] || die "missing entrypoint: $ISOPOD_ENTRYPOINT"
  [ -f "$ISOPOD_SYSCTL_CONF" ] || die "missing sysctl baseline: $ISOPOD_SYSCTL_CONF"
  [ -f "$ISOPOD_GUEST_EGRESS_NFT" ] || die "missing guest egress ruleset: $ISOPOD_GUEST_EGRESS_NFT"
  local dev="${2:-0}" nested="${3:-0}" hash
  # The dev-tools and nested flags are part of the cache key: the lean, --dev and
  # --nested-containers images are built from the same Dockerfile but differ, so
  # they must not share a tag.
  hash=$({
    cat "$ISOPOD_DOCKERFILE" "$ISOPOD_ENTRYPOINT" "$ISOPOD_SYSCTL_CONF" "$ISOPOD_GUEST_EGRESS_NFT"
    printf '%s\0%s\0%s\0%s\0%s' "$1" "$CONTAINER_USER" "$IMAGE_LAYER_VERSION" "$dev" "$nested"
  } | sha_hex)
  printf 'localhost/isopod-base:%s' "$hash"
}

# ISOPOD_BUILD_ARGS: extra args for '$ENGINE build' (e.g. --network=host,
# --build-arg http_proxy=...) for proxied or unusual environments. Emits one
# token per line (nothing when unset) for the caller to read into an array.
engine_build_extra() {
  [ -n "${ISOPOD_BUILD_ARGS:-}" ] || return 0
  # shellcheck disable=SC2086
  printf '%s\n' $ISOPOD_BUILD_ARGS
}

# The build-args counterpart to assert_safe_run_args. Two refusals:
#   host mounts into the build context, same reasoning as the run-args check;
#   overrides of the build args isopod sets itself. image_tag_for hashes the base
#   image and the dev/nested flags into the cache tag, so overriding one builds a
#   DIFFERENT image and caches it under the legitimate image's tag, where every
#   later create reuses it. ISOPOD_SSHD_PORT must match BOX_SSHD_PORT or the box
#   comes up unreachable. Same override as the run-args check.
assert_safe_build_args() { # assert_safe_build_args <arg...>
  [ "${ISOPOD_ALLOW_UNSAFE_RUN_ARGS:-0}" = 1 ] && return 0
  local a
  for a in "$@"; do
    case "$a" in
      -v | --volume | --mount | -v=* | --volume=* | --mount=*)
        die "ISOPOD_BUILD_ARGS contains '$a', which would expose host files to the image build.
     If you genuinely need it, set ISOPOD_ALLOW_UNSAFE_RUN_ARGS=1 to confirm."
        ;;
      ISOPOD_BASE=* | ISOPOD_USER=* | ISOPOD_SSHD_PORT=* | ISOPOD_DEV_TOOLS=* | ISOPOD_NESTED=* | --build-arg=ISOPOD_*)
        die "ISOPOD_BUILD_ARGS overrides '$a', which isopod sets itself and hashes into the image
     cache tag, so the result would be cached under a different image's tag.
     Use the matching isopod flag instead (--image, --dev, --nested-containers)."
        ;;
    esac
  done
}

build_image() { # build_image <base-image> [dev-tools 0|1] [nested 0|1] -> echoes tag
  local base="$1" dev="${2:-0}" nested="${3:-0}" tag
  tag=$(image_tag_for "$base" "$dev" "$nested")
  if image_exists "$tag"; then
    printf '%s' "$tag"
    return 0
  fi
  info "Building sandbox base image from $base (one-time$([ "$dev" = 1 ] && printf ', with --dev toolchain')$([ "$nested" = 1 ] && printf ', with nested podman'))..." >&2
  local -a extra_build=()
  mapfile -t extra_build < <(engine_build_extra)
  [ "${#extra_build[@]}" -gt 0 ] && assert_safe_build_args "${extra_build[@]}"
  # Minimal build context: only the files the Dockerfile COPYs in. Apple
  # `container build` requires the Dockerfile to live INSIDE the context directory
  # (it rejects a -f path outside it, and trips on a '//' in the path), so for that
  # engine copy the Dockerfile in and point -f at it; podman/docker read it from
  # share/ directly. Strip any trailing slash on TMPDIR to avoid the '//'.
  local ctx tmpbase="${TMPDIR:-/tmp}" dockerfile="$ISOPOD_DOCKERFILE"
  # An --account build runs AS the sandbox account, which must traverse to and
  # read the context. A TMPDIR under a 0700 home is not traversable by another
  # user, so opening the context alone (chmod below) is not enough — the account
  # cannot even reach it. For account builds base the context on world-traversable
  # /tmp (sticky) instead; the context is three package files, so /tmp space is a
  # non-issue. Non-account builds honour TMPDIR unchanged.
  [ "${ISOPOD_ENGINE_AS_ACCOUNT:-0}" = 1 ] && tmpbase=/tmp
  ctx=$(mktemp -d "${tmpbase%/}/isopod-ctx-XXXXXX")
  cp "$ISOPOD_ENTRYPOINT" "$ctx/isopod-entrypoint"
  cp "$ISOPOD_SYSCTL_CONF" "$ctx/hardening-sysctl.conf"
  cp "$ISOPOD_GUEST_EGRESS_NFT" "$ctx/egress-guest.nft"
  if [ "$ENGINE" = container ]; then
    cp "$ISOPOD_DOCKERFILE" "$ctx/Dockerfile"
    dockerfile="$ctx/Dockerfile"
  fi
  # For an account box the build runs AS the sandbox account, which cannot read a
  # mktemp dir left at its default 0700 owned by the invoking user — podman would
  # fail resolving the context before it starts. Open the dir and its files to
  # read/traverse; the contents (Dockerfile, entrypoint, sysctl/nft baselines)
  # ship in the package and hold nothing secret. Non-account builds are untouched.
  [ "${ISOPOD_ENGINE_AS_ACCOUNT:-0}" = 1 ] && chmod -R a+rX "$ctx"
  if ! engine build "${extra_build[@]}" \
    --build-arg "ISOPOD_BASE=$base" --build-arg "ISOPOD_USER=$CONTAINER_USER" \
    --build-arg "ISOPOD_SSHD_PORT=$BOX_SSHD_PORT" --build-arg "ISOPOD_DEV_TOOLS=$dev" \
    --build-arg "ISOPOD_NESTED=$nested" \
    -t "$tag" -f "$dockerfile" "$ctx" >&2; then
    rm -rf "$ctx"
    die "image build failed (see output above)"
  fi
  rm -rf "$ctx"
  printf '%s' "$tag"
}

# Build a user-provided Dockerfile (from --dockerfile) into an image, then echo
# its tag so it can be used as the base the sandbox layers sshd/git onto — the
# same role as --image, but you hand over a Dockerfile and isopod builds it.
build_user_image() { # build_user_image <dockerfile-path> -> echoes tag
  local df="$1" ctx tag
  [ -f "$df" ] || die "--dockerfile not found: $df"
  ctx=$(dirname "$df")
  # Tag from the Dockerfile AND its build context, so a changed COPY/ADD source
  # (with the Dockerfile itself unchanged) busts the cache instead of silently
  # reusing a stale image. Hash each context file's path + contents in a stable
  # order, excluding .git. Bounded by context size (the engine tars it anyway).
  tag="localhost/isopod-user:$(
    {
      cat "$df"
      (
        cd "$ctx" || exit
        find . -path ./.git -prune -o -type f -print0 |
          LC_ALL=C sort -z |
          while IFS= read -r -d '' f; do
            printf '%s\0' "$f"
            cat "$f"
          done
      )
    } | sha_hex
  )"
  if image_exists "$tag"; then
    printf '%s' "$tag"
    return 0
  fi
  # Name the context: it is the Dockerfile's own directory, not the working
  # directory, so a COPY resolves against a path the user did not choose.
  info "Building image from $df (context: $ctx, one-time)..." >&2
  local -a extra_build=()
  mapfile -t extra_build < <(engine_build_extra)
  [ "${#extra_build[@]}" -gt 0 ] && assert_safe_build_args "${extra_build[@]}"
  if ! engine build "${extra_build[@]}" -t "$tag" -f "$df" "$ctx" >&2; then
    die "build of $df failed (see output above)"
  fi
  printf '%s' "$tag"
}
