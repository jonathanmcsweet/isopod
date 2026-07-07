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
  else
    die "neither podman nor docker found. Install one (podman recommended for rootless isolation)."
  fi
  # Sanity check the engine actually works (daemon up / machine started)
  if ! "$ENGINE" info >/dev/null 2>&1; then
    case "$ENGINE" in
      podman) die "podman is installed but not working. On macOS/Windows run: podman machine init && podman machine start" ;;
      docker) die "docker is installed but the daemon is not reachable. Start Docker (or Docker Desktop) and retry." ;;
    esac
  fi
}

ctr_name() { printf 'isopod-%s' "$1"; }
box_dir() { printf '%s/%s' "$BOXES_DIR" "$1"; }

require_box() {
  [ -d "$(box_dir "$1")" ] || die "no such sandbox: '$1' (see: isopod list)"
}

# Common command entry: assert the box exists and select the engine it was
# created with (sets ENGINE). Commands that mutate shared state call acquire_lock
# themselves afterwards, since whether/why they lock varies.
open_box() { # open_box <name>
  require_box "$1"
  detect_engine "$(meta_get "$1" engine || true)"
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

# ---------------------------------------------------------------------------
# image build (share/Dockerfile)
# ---------------------------------------------------------------------------
# The image is defined by a standard Dockerfile (share/Dockerfile), built the
# same way by docker and podman. The base image and in-box user are passed as
# build args. The cache key hashes the Dockerfile and entrypoint content + those
# args, so an edit to either forces a one-time rebuild on its own
# (IMAGE_LAYER_VERSION remains only as a manual force-rebuild override).
image_exists() { # image_exists <tag>
  "$ENGINE" image exists "$1" 2>/dev/null || "$ENGINE" image inspect "$1" >/dev/null 2>&1
}

image_tag_for() { # image_tag_for <base-image> [dev-tools 0|1]
  [ -f "$ISOPOD_DOCKERFILE" ] || die "missing Dockerfile: $ISOPOD_DOCKERFILE"
  [ -f "$ISOPOD_ENTRYPOINT" ] || die "missing entrypoint: $ISOPOD_ENTRYPOINT"
  local dev="${2:-0}" hash
  # The dev-tools flag is part of the cache key: the lean and --dev images are
  # built from the same Dockerfile but differ, so they must not share a tag.
  hash=$({
    cat "$ISOPOD_DOCKERFILE" "$ISOPOD_ENTRYPOINT"
    printf '%s\0%s\0%s\0%s' "$1" "$CONTAINER_USER" "$IMAGE_LAYER_VERSION" "$dev"
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

build_image() { # build_image <base-image> [dev-tools 0|1] -> echoes tag
  local base="$1" dev="${2:-0}" tag
  tag=$(image_tag_for "$base" "$dev")
  if image_exists "$tag"; then
    printf '%s' "$tag"
    return 0
  fi
  info "Building sandbox base image from $base (one-time$([ "$dev" = 1 ] && printf ', with --dev toolchain'))..." >&2
  local -a extra_build=()
  mapfile -t extra_build < <(engine_build_extra)
  # Minimal build context: just the entrypoint the Dockerfile COPYs in.
  local ctx
  ctx=$(mktemp -d "${TMPDIR:-/tmp}/isopod-ctx-XXXXXX")
  cp "$ISOPOD_ENTRYPOINT" "$ctx/isopod-entrypoint"
  if ! "$ENGINE" build "${extra_build[@]}" \
    --build-arg "ISOPOD_BASE=$base" --build-arg "ISOPOD_USER=$CONTAINER_USER" \
    --build-arg "ISOPOD_SSHD_PORT=$BOX_SSHD_PORT" --build-arg "ISOPOD_DEV_TOOLS=$dev" \
    -t "$tag" -f "$ISOPOD_DOCKERFILE" "$ctx" >&2; then
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
  info "Building image from $df (one-time)..." >&2
  local -a extra_build=()
  mapfile -t extra_build < <(engine_build_extra)
  if ! "$ENGINE" build "${extra_build[@]}" -t "$tag" -f "$df" "$ctx" >&2; then
    die "build of $df failed (see output above)"
  fi
  printf '%s' "$tag"
}
