# shellcheck shell=bash
#
# pi-installer — where to get the Pi coding agent, and how to install it.
#
# The shared machinery (verified fetch, transfer into the box, the terminal
# session) lives in agent.sh; this file is only the part that is specific to Pi.
# See the adapter contract at the top of agent.sh.
#
# Upstream's own installer wants npm and Node 22, which a box need not have. The
# release also carries a per-platform build that brings its own runtime, so
# isopod installs that instead: no Node in the box, and the same
# verified-on-the-host path the other agents use.
#
# The Linux builds link glibc and there is no musl build, so an Alpine box is
# refused rather than handed something it cannot run.
pi_asset() { # pi_asset <arch> <libc> -> asset name
  [ "$2" = musl ] &&
    die "Pi publishes no musl build, so it cannot run on this box (an Alpine or
     other musl box). Use a glibc box for Pi."
  case "$1" in
    x86_64 | amd64) printf 'pi-linux-x64.tar.gz' ;;
    aarch64 | arm64) printf 'pi-linux-arm64.tar.gz' ;;
    *) die "Pi has no Linux build for this box's architecture: '$1'" ;;
  esac
}

# Adapter contract: version, checksum, url, artifact name. The release feed
# carries the digest and the download URL together, so one request settles both.
pi_resolve() { # pi_resolve <arch> <libc>
  local asset helper="$ISOPOD_LIB/github_asset.py" out ver sum url
  asset="$(pi_asset "$1" "$2")"
  [ -f "$helper" ] || die "missing helper: $helper (is your isopod install complete?)"
  have python3 || die "isopod needs python3 on the host to read the Pi release feed"
  out="$(agent_curl "$ISOPOD_PI_API_URL" -H 'Accept: application/vnd.github+json' |
    python3 "$helper" "$asset")" ||
    die "could not find '$asset' with a checksum in the latest Pi release"
  IFS=$'\t' read -r ver sum url <<<"$out"
  printf '%s\t%s\t%s\t%s' "$ver" "$sum" "$url" "$asset"
}

# The whole directory is installed, not just the binary: pi reads its themes and
# a wasm blob from beside itself, so a lone binary starts and then dies on the
# first theme it loads. The tree goes to ~/.local/share/pi, which is on the box
# PATH, and never to ~/.pi, which is pi's own settings directory.
pi_box_install() { # pi_box_install <artifact>
  printf 'set -e
cd "$HOME/.isopod-agent"
tar -xzf %s
[ -f pi/pi ] || { echo "archive did not contain pi/pi" >&2; exit 1; }
mkdir -p "$HOME/.local/share"
rm -rf "$HOME/.local/share/pi"
mv -f pi "$HOME/.local/share/pi"
chmod 755 "$HOME/.local/share/pi/pi"' "$(shq "$1")"
}
