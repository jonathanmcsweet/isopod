# shellcheck shell=bash
#
# codex-installer — where to get Codex, and how to install it.
#
# The shared machinery (verified fetch, transfer into the box, the terminal
# session) lives in agent.sh; this file is only the part that is specific to
# Codex. See the adapter contract at the top of agent.sh.
#
# Codex is published as GitHub releases. The release feed reports a sha256 digest
# for every asset, which is what lets the download be verified on the host before
# it crosses into a box.
#
# Two things differ from Claude Code and shape the code below:
#   * Linux builds are static musl, so one artifact per architecture serves both
#     a Debian and an Alpine box and the box's libc does not enter into it;
#   * the artifact is a .tar.gz around a single binary named for its target. It
#     is streamed in COMPRESSED and unpacked in the box, roughly a third of the
#     bytes over SSH that sending the unpacked binary would cost.

# Map the box's architecture to a Rust target triple. libc is deliberately
# ignored: the musl build is static and runs on a glibc box too.
codex_target() { # codex_target <arch> -> target triple
  case "$1" in
    x86_64 | amd64) printf 'x86_64-unknown-linux-musl' ;;
    aarch64 | arm64) printf 'aarch64-unknown-linux-musl' ;;
    *) die "Codex has no Linux build for this box's architecture: '$1'" ;;
  esac
}

# Adapter contract: version, checksum, url, artifact name. The release feed
# carries the digest and the download URL together, so one request settles both.
codex_resolve() { # codex_resolve <arch> <libc>
  local target asset helper="$ISOPOD_LIB/github_asset.py" out ver sum url
  target="$(codex_target "$1")"
  asset="codex-$target.tar.gz"
  [ -f "$helper" ] || die "missing helper: $helper (is your isopod install complete?)"
  have python3 || die "isopod needs python3 on the host to read the Codex release feed"
  out="$(agent_curl "$ISOPOD_CODEX_API_URL" -H 'Accept: application/vnd.github+json' |
    python3 "$helper" "$asset")" ||
    die "could not find '$asset' with a checksum in the latest Codex release"
  IFS=$'\t' read -r ver sum url <<<"$out"
  printf '%s\t%s\t%s\t%s' "$ver" "$sum" "$url" "$asset"
}

# Unpack in the box and put the binary on PATH under its plain name. The tarball
# holds one file, named for the target triple, so it is renamed on the way to
# ~/.local/bin. Codex updates itself from here on, so nothing else is wired up.
codex_box_install() { # codex_box_install <artifact>
  # The archive holds exactly one file, named for the target triple, which is the
  # artifact name without its .tar.gz. The script runs as `sh -c <script>` with no
  # positional arguments, so both names are substituted in here.
  local artifact="$1" inner="${1%.tar.gz}"
  printf 'set -e
cd "$HOME/.isopod-agent"
tar -xzf %s
[ -f %s ] || { echo "archive did not contain %s" >&2; exit 1; }
mkdir -p "$HOME/.local/bin"
chmod 755 %s
mv -f %s "$HOME/.local/bin/codex"' \
    "$(shq "$artifact")" "$(shq "$inner")" "$inner" "$(shq "$inner")" "$(shq "$inner")"
}
