# shellcheck shell=bash
#
# claude-code-installer — where to get Claude Code, and how to install it.
#
# The shared machinery (verified fetch, transfer into the box, the terminal
# session) lives in agent.sh; this file is only the part that is specific to
# Claude Code. See the adapter contract at the top of agent.sh.
#
# Upstream publishes a plain version string at <base>/latest and a per-release
# manifest.json carrying a SHA-256 for each platform, which is what lets the
# binary be verified on the host before it crosses into a box.

# Artifacts upstream publishes for Linux. Anything else is refused rather than
# guessed at, since the token becomes part of a URL and a cache path.
CLAUDE_PLATFORMS="linux-x64 linux-arm64 linux-x64-musl linux-arm64-musl"

# Map the box's own facts to an upstream platform token. Both the tokens and the
# libc split mirror the upstream bootstrap script, so a box gets the same build a
# normal install would.
claude_platform() { # claude_platform <arch> <libc> -> token
  local arch libc="$2" plat
  case "$1" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "Claude Code has no build for this box's architecture: '$1'" ;;
  esac
  plat="linux-$arch"
  [ "$libc" = musl ] && plat="$plat-musl"
  case " $CLAUDE_PLATFORMS " in
    *" $plat "*) printf '%s' "$plat" ;;
    *) die "Claude Code has no build for '$plat'" ;;
  esac
}

# The newest published version, as a bare string. Validated before use: it becomes
# both a URL segment and a cache directory name.
claude_latest_version() {
  local ver
  ver="$(agent_curl "$ISOPOD_CLAUDE_BASE_URL/latest")" ||
    die "could not reach $ISOPOD_CLAUDE_BASE_URL/latest — check your network, or a proxy that blocks it"
  ver="$(printf '%s' "$ver" | tr -d '\r\n')"
  [[ "$ver" =~ ^[0-9][0-9A-Za-z.+-]{0,63}$ ]] ||
    die "the release endpoint returned something that is not a version: '$(sanitize "$ver")'"
  printf '%s' "$ver"
}

# Adapter contract: version, checksum, url, artifact name.
claude_resolve() { # claude_resolve <arch> <libc>
  local plat ver sum helper="$ISOPOD_LIB/claude_manifest.py"
  plat="$(claude_platform "$1" "$2")"
  [ -f "$helper" ] || die "missing helper: $helper (is your isopod install complete?)"
  have python3 || die "isopod needs python3 on the host to read the Claude Code release manifest"
  ver="$(claude_latest_version)"
  sum="$(agent_curl "$ISOPOD_CLAUDE_BASE_URL/$ver/manifest.json" | python3 "$helper" "$plat")" ||
    die "could not read a checksum for $plat from the $ver manifest"
  printf '%s\t%s\t%s\t%s' "$ver" "$sum" "$ISOPOD_CLAUDE_BASE_URL/$ver/$plat/claude" "claude"
}

# The artifact is the binary itself, and it ships an `install` subcommand that
# places it. Handing off to that is what the upstream bootstrap does, and it keeps
# the built-in updater wired up, which matters because from here on updating is
# the box user's job.
claude_box_install() { # claude_box_install <artifact>
  printf 'cd "$HOME/.isopod-agent" && chmod 755 %s && ./%s install' "$1" "$1"
}
