# shellcheck shell=bash
#
# opencode-installer — where to get opencode, and how to install it.
#
# The shared machinery (verified fetch, transfer into the box, the terminal
# session) lives in agent.sh; this file is only the part that is specific to
# opencode. See the adapter contract at the top of agent.sh.
#
# opencode is published as GitHub releases, and the release feed reports a sha256
# digest for every asset, so the download is verified on the host before it
# crosses into a box. The Linux artifact is a .tar.gz around a single binary,
# streamed in compressed and unpacked in the box.
#
# It publishes more Linux builds than the other agents, and which one a box needs
# depends on all three facts the box reports: architecture, libc, and whether the
# CPU has AVX2. The x64 build assumes AVX2 and dies with an illegal instruction
# without it, which is why the -baseline build exists.

# Map the box's own facts to a release asset. Both the token order
# (arch, baseline, musl) and the AVX2 rule mirror the upstream install script, so
# a box gets the build a normal install would put there.
opencode_asset() { # opencode_asset <arch> <libc> <simd> -> asset name
  local arch libc="$2" simd="$3" name
  case "$1" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "opencode has no Linux build for this box's architecture: '$1'" ;;
  esac
  name="opencode-linux-$arch"
  # arm64 has no baseline build and needs none: the split is an x86 one.
  [ "$arch" = x64 ] && [ "$simd" != avx2 ] && name="$name-baseline"
  [ "$libc" = musl ] && name="$name-musl"
  printf '%s.tar.gz' "$name"
}

# Adapter contract: version, checksum, url, artifact name. The release feed
# carries the digest and the download URL together, so one request settles both.
opencode_resolve() { # opencode_resolve <arch> <libc> <simd>
  local asset helper="$ISOPOD_LIB/github_asset.py" out ver sum url
  asset="$(opencode_asset "$1" "$2" "$3")"
  [ -f "$helper" ] || die "missing helper: $helper (is your isopod install complete?)"
  have python3 || die "isopod needs python3 on the host to read the opencode release feed"
  out="$(agent_curl "$ISOPOD_OPENCODE_API_URL" -H 'Accept: application/vnd.github+json' |
    python3 "$helper" "$asset")" ||
    die "could not find '$asset' with a checksum in the latest opencode release"
  IFS=$'\t' read -r ver sum url <<<"$out"
  printf '%s\t%s\t%s\t%s' "$ver" "$sum" "$url" "$asset"
}

# Into ~/.opencode/bin, where the upstream installer puts it, so `opencode
# upgrade` in the box replaces this file rather than shadowing it.
opencode_box_install() { # opencode_box_install <artifact>
  agent_tar_install_script "$1" opencode '$HOME/.opencode/bin' opencode
}
