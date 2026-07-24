#!/usr/bin/env bash
# Distro install smoke test: prove install.sh puts a working isopod on a distro
# it claims to support, and that it prints that distro's engine hint.
#
# Runs INSIDE a distro container image (see the distro-install matrix in
# .github/workflows/ci.yml). No container engine is installed in the image — the
# point is the install path and the host-side CLI, not running boxes, so the
# engine guidance block is expected and is what we assert on.
#
# Usage:  test/distro-install.sh <expected-hint>
#         <expected-hint> is a string install.sh must print in its "no container
#         engine found" guidance for this distro (e.g. pacman, emerge, dnf).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
EXPECT="${1:-}"
[ -n "$EXPECT" ] || {
  printf 'usage: %s <expected-engine-hint>\n' "$0" >&2
  exit 2
}

c_grn=$'\033[32m'
c_red=$'\033[31m'
c_rst=$'\033[0m'
ok() { printf '%s  ok%s %s\n' "$c_grn" "$c_rst" "$1"; }
fail() {
  printf '%sFAIL%s %s\n' "$c_red" "$c_rst" "$1" >&2
  exit 1
}

printf 'distro: %s (bash %s)\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')" "$BASH_VERSION"

prefix="$(mktemp -d)"
home="$(mktemp -d)"
trap 'rm -rf "$prefix" "$home"' EXIT
# Keep the installer's completions (and anything else HOME-relative) inside the
# throwaway dirs, so a local run does not touch the real account.
export HOME="$home" XDG_DATA_HOME="$home/.local/share"

# 1. --check makes no changes.
./install.sh --check --prefix "$prefix" --no-extension >/dev/null || fail "install.sh --check failed"
[ -e "$prefix/bin/isopod" ] && fail "install.sh --check created files"
ok "install.sh --check is read-only"

# 2. A real install. install.sh exits non-zero only on a genuine error; the
#    missing container engine is a printed warning, not a failure.
out="$(./install.sh --prefix "$prefix" --no-extension 2>&1)" || fail "install.sh failed:
$out"
[ -x "$prefix/bin/isopod" ] || fail "install.sh did not produce $prefix/bin/isopod"
ok "install.sh installed into $prefix"

# 3. The engine guidance names this distro's package manager (the ID/ID_LIKE
#    family detection in install.sh).
printf '%s' "$out" | grep -qF "$EXPECT" || fail "engine guidance did not mention '$EXPECT':
$out"
ok "engine guidance mentions '$EXPECT'"

# 4. The installed CLI runs through the symlink and renders its share/ templates.
"$prefix/bin/isopod" version >/dev/null || fail "isopod version failed"
help_out="$("$prefix/bin/isopod" help 2>&1)" || true
case "$help_out" in
  *"missing template"*) fail "installed isopod can't find its templates: $help_out" ;;
esac
printf '%s' "$help_out" | grep -q 'Usage:' || fail "installed 'isopod help' did not render usage.txt"
ok "installed isopod renders usage through the bin symlink"

# 5. doctor runs to completion. It exits non-zero with no engine installed (that
#    is its job here), so gate on the output, not the status.
doc="$("$prefix/bin/isopod" doctor 2>&1)" || true
printf '%s' "$doc" | grep -q 'podman' || fail "doctor did not report on podman:
$doc"
ok "isopod doctor runs"

# 6. Uninstall removes what it installed.
./install.sh --prefix "$prefix" --uninstall >/dev/null || fail "install.sh --uninstall failed"
[ -e "$prefix/bin/isopod" ] && fail "uninstall left the symlink behind"
[ -d "$prefix/lib/isopod" ] && fail "uninstall left the program dir behind"
ok "install.sh --uninstall is clean"

printf '%sdistro install checks passed%s\n' "$c_grn" "$c_rst"
