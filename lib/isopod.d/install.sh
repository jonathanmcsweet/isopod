#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines the `install` command:
# host-mediated system-package installs into an existing box, as root, WITHOUT
# giving the in-box user sudo. This is the companion to a `--no-sudo` box: the box
# stays locked down (no in-box root path a rogue agent could abuse), yet a forgotten
# build dependency can still be added without a rebuild. Only the trusted host can
# invoke it — the privileged action never lives inside the untrusted box.

# Validate a package NAME — not a path, an option, or a version pin. Only the
# characters a Debian/apk/dnf package name can contain, and never a leading '-'
# (which the package manager would read as an option, e.g. apt's '-o ...' config
# hooks that run commands as root) or a '/' (a local .deb the caller controls).
# Defence in depth: the install runs as root in the box, so even though only the
# host invokes it, no unvalidated token ever reaches the package manager.
valid_pkg_name() { # valid_pkg_name <name>
  case "$1" in
    "" | -* | */* | *[!a-z0-9+._:-]*) return 1 ;;
  esac
  return 0
}

# The package manager available inside the box, echoed as a bare token (apt-get,
# apk, dnf, or yum), or non-zero if none is found.
box_pkg_mgr() { # box_pkg_mgr <ctr>
  "$ENGINE" exec --user root "$1" sh -c '
    for m in apt-get apk dnf yum; do
      command -v "$m" >/dev/null 2>&1 && { printf "%s" "$m"; exit 0; }
    done
    exit 1' 2>/dev/null
}

# isopod install <box> <pkg>...  — install system packages into an existing box
# from the host, as root, without in-box sudo.
cmd_install() {
  case "${1:-}" in
    -h | --help | help | "")
      render_tmpl install-help.txt
      return 0
      ;;
  esac
  local name="$1"
  shift
  [ "$#" -gt 0 ] || die "usage: isopod install <box> <pkg> [<pkg>...]  (see: isopod install --help)"

  # Reject bad package names before touching the box, so nothing partial happens.
  local p
  for p in "$@"; do
    valid_pkg_name "$p" ||
      die "invalid package name: '$p' — names only (letters, digits, and + . _ : -).
     No paths, options, or version pins; add those at build time with --dockerfile."
  done

  open_box "$name" # asserts the box exists and selects its engine (sets ENGINE)
  local ctr status
  ctr="$(ctr_name "$name")"
  status=$("$ENGINE" inspect -f '{{.State.Status}}' "$ctr" 2>/dev/null || true)
  [ "$status" = running ] ||
    die "box '$name' is not running (status: ${status:-missing}). Start it first: isopod start $name"

  # Can the host open a root shell into this box? For a container the engine execs
  # as uid 0 directly. For a microVM the engine cannot exec into the guest (box ops
  # go over the unprivileged SSH user; see lifecycle.sh), so there is no host root
  # channel — the package must be baked at build time instead.
  if ! "$ENGINE" exec --user root "$ctr" true 2>/dev/null; then
    die "cannot run a privileged install in '$name' — the engine can't exec as root here
     (a microVM runtime, or an otherwise incompatible box). Add the package at build time
     instead: recreate the box with 'isopod create ... --dockerfile <file>' (or --dev)."
  fi

  local mgr
  mgr="$(box_pkg_mgr "$ctr")" ||
    die "no supported package manager (apt-get/apk/dnf) found in '$name'"

  info "Installing into '$name' as root (via $ENGINE $mgr): $*"
  # Package names are passed as positional args to the in-box shell ("$@"), never
  # interpolated into the command string — a name can't be re-parsed as a flag or
  # shell syntax even if validation were ever loosened.
  local rc=0
  case "$mgr" in
    apt-get)
      # The base image clears /var/lib/apt/lists (share/Dockerfile), so the index
      # must be refreshed first or the install fails to locate any package.
      "$ENGINE" exec --user root "$ctr" sh -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends "$@"
      ' sh "$@" || rc=$?
      ;;
    apk) "$ENGINE" exec --user root "$ctr" apk add --no-cache "$@" || rc=$? ;;
    dnf | yum) "$ENGINE" exec --user root "$ctr" "$mgr" install -y "$@" || rc=$? ;;
  esac

  if [ "$rc" -ne 0 ]; then
    # The most common non-obvious cause in an isolated box: egress filtering is
    # blocking the distro mirror, so the index refresh / download fails.
    case "$(meta_get "$name" egress 2>/dev/null || true)" in
      lan-deny | allow-list)
        warn "this box has egress isolation on, which can block the distro mirror. Allow the
       mirror (e.g. 'isopod egress allow deb.debian.org') and retry, or bake the package with
       --dockerfile."
        ;;
    esac
    die "package install failed in '$name' (exit $rc)"
  fi

  info "Installed into '$name'. Note: this is EPHEMERAL — installed packages are lost when the
     box is recreated. For a dependency you always need, add it to a --dockerfile so it is
     baked into the image."
}
