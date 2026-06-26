#!/usr/bin/env bash
# Install isopod through the REAL Homebrew formula in the jonathanmcsweet/isopod
# tap — but built from the CURRENT checkout — then run `brew test`. This proves
# the tap formula's install method ships everything the checked-out code needs
# at runtime (notably share/), which the in-repo install.sh path can't verify.
#
# Needs Homebrew (macOS runners or Linuxbrew); no container engine required.
set -euo pipefail

command -v brew >/dev/null 2>&1 || {
  echo "Homebrew not found — this check needs brew" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TAP="jonathanmcsweet/isopod"

# Don't let an auto-update `git pull` the tap and overwrite our local formula edit.
# (Leave the API on: deps like bash/openssh resolve from it, while our
# third-party tap formula is always read from its local clone — edits included.)
export HOMEBREW_NO_AUTO_UPDATE=1

brew tap "$TAP"
formula="$(brew --repository "$TAP")/Formula/isopod.rb"
[ -f "$formula" ] || {
  echo "formula not found in tap: $formula" >&2
  exit 1
}

# Build a source tarball from this commit and repoint the formula's stable source
# at it, so we exercise the formula against the code under review rather than the
# the formula version from the tarball BASENAME — so name it isopod-<version>
# (matching the checkout's ISOPOD_VERSION), or the formula has a nil version.
ver="$(sed -n 's/^ISOPOD_VERSION="\(.*\)"/\1/p' isopod)"
[ -n "$ver" ] || ver="0.0.0-ci"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tarball="$work/isopod-$ver.tar.gz"
git archive --format=tar.gz --prefix="isopod-$ver/" HEAD -o "$tarball"
if command -v sha256sum >/dev/null 2>&1; then
  sha="$(sha256sum "$tarball" | awk '{print $1}')"
else
  sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
fi

# CI-only, in-place rewrite of the tapped formula's url + sha256 (| delimiter so
# the file:// path's slashes don't clash). -i.bak is portable across GNU/BSD sed.
sed -i.bak -E \
  -e "s|^  url .*|  url \"file://$tarball\"|" \
  -e "s|^  sha256 .*|  sha256 \"$sha\"|" \
  "$formula"

echo "== installing isopod from the tap formula (built from this checkout) =="
brew install --build-from-source "$TAP/isopod"
echo "== brew test (renders a template via 'isopod help') =="
brew test "$TAP/isopod"
echo "brew formula install + test passed"
