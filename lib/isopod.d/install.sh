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

# Which root channel this box supports, echoed as "engine" or "ssh"; non-zero
# when it has neither.
#
# A plain container takes `$ENGINE exec --user root` directly. A microVM box does
# NOT: the engine cannot exec into the guest, which used to make `isopod install`
# unusable on the default runtime and left a --no-sudo microVM box with no way to
# add a package at all. Such a box is reached instead over SSH with the
# administrative key the host holds for it (see create / root_ssh) — the same
# trust boundary, just the channel that works there.
box_root_channel() { # box_root_channel <name> <ctr>
  "$ENGINE" exec --user root "$2" true 2>/dev/null && {
    printf engine
    return 0
  }
  [ -f "$(box_dir "$1")/id_ed25519_root" ] && {
    printf ssh
    return 0
  }
  return 1
}

# Run a /bin/sh script as root inside the box over whichever channel it supports,
# passing stdin through. Package names are fed to the script on STDIN, never in
# argv, so on both channels no caller-supplied token is ever re-parsed as a shell
# word or an option — the same property the engine path always had, preserved for
# the SSH path where box_ssh's argv is re-split by the box's shell.
box_root_sh() { # box_root_sh <name> <ctr> <channel> <script>   (stdin -> script)
  case "$3" in
    engine) "$ENGINE" exec -i --user root "$2" sh -c "$4" ;;
    ssh) root_ssh "$1" -- "sh -c $(shq "$4")" ;;
    *) return 1 ;;
  esac
}

# The package manager available inside the box, echoed as a bare token (apt-get,
# apk, dnf, or yum), or non-zero if none is found.
box_pkg_mgr() { # box_pkg_mgr <name> <ctr> <channel>
  box_root_sh "$1" "$2" "$3" '
    for m in apt-get apk dnf yum; do
      command -v "$m" >/dev/null 2>&1 && { printf "%s" "$m"; exit 0; }
    done
    exit 1' </dev/null 2>/dev/null
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

  # Pick the root channel: engine exec for a container, the host-held
  # administrative key for a microVM box (where engine exec cannot reach the guest).
  local channel
  channel="$(box_root_channel "$name" "$ctr")" ||
    die "cannot run a privileged install in '$name' — the engine can't exec as root here
     (a microVM runtime), and the box has no administrative root key to reach it over SSH.
     Rebuild it onto the current image to get one ('isopod upgrade $name'), or bake the
     package at build time with 'isopod create ... --dockerfile <file>'."

  local mgr
  mgr="$(box_pkg_mgr "$name" "$ctr" "$channel")" ||
    die "no supported package manager (apt-get/apk/dnf) found in '$name'"

  info "Installing into '$name' as root (via $channel, $mgr): $*"
  # Package names go in on STDIN, one per line, and reach the package manager
  # through xargs — they never appear in argv on either channel, so a name cannot
  # be re-parsed as a flag or as shell syntax even if validation were loosened.
  # The list is known non-empty (checked above), so xargs always has work to do.
  local script
  case "$mgr" in
    apt-get)
      # The base image clears /var/lib/apt/lists (share/Dockerfile), so the index
      # must be refreshed first or the install fails to locate any package.
      script='set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        xargs apt-get install -y --no-install-recommends'
      ;;
    apk) script='xargs apk add --no-cache' ;;
    dnf | yum) script="xargs $mgr install -y" ;;
  esac
  local rc=0
  printf '%s\n' "$@" | box_root_sh "$name" "$ctr" "$channel" "$script" || rc=$?

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
