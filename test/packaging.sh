#!/usr/bin/env bash
# Packaging guard: prove a real install ships share/ and renders its templates.
#
# isopod loads its long strings from share/ at runtime (render_tmpl). A packager
# that copies the script but forgets share/ — as the Homebrew formula once did —
# leaves every templated command failing with "missing template: .../share/...".
# This catches that class of regression without needing a container engine.
#
#   1. every `render_tmpl <file>` in isopod has a backing share/<file>
#   2. the release tarball (git archive) actually contains share/
#   3. a symlink-style install (install.sh) renders a template THROUGH the bin
#      symlink — the exact path that broke under brew
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
ok()   { printf '%s  ok%s %s\n' "$c_grn" "$c_rst" "$1"; }
fail() { printf '%sFAIL%s %s\n' "$c_red" "$c_rst" "$1" >&2; exit 1; }

# 1. Every template referenced by the script must exist in share/.
while read -r tmpl; do
  [ -f "share/$tmpl" ] || fail "isopod calls render_tmpl '$tmpl' but share/$tmpl is missing"
done < <(grep -oE 'render_tmpl[[:space:]]+[A-Za-z0-9._-]+' isopod | awk '{print $2}' | sort -u)
ok "every render_tmpl reference has a share/ file"

# 2. The tag tarball GitHub serves is `git archive` of the commit — make sure it
#    carries share/, or the formula has nothing to install.
git archive --format=tar HEAD -- share | tar t 2>/dev/null | grep -q 'share/usage.txt' \
  || fail "share/ is not in the git archive — the release tarball would omit it"
ok "release tarball ships share/"

# 3. Install the symlink way (lib/, share/, security/ beside the script under a
#    libexec dir, bin symlink) into a throwaway prefix, then render a template
#    through the symlink. HOME/XDG are redirected so completions don't escape.
prefix="$(mktemp -d)"
home="$(mktemp -d)"
trap 'rm -rf "$prefix" "$home"' EXIT
# install.sh exits non-zero when no container engine is present (CI slim images
# have none); that is unrelated to packaging, so gate on the render, not on it.
HOME="$home" XDG_DATA_HOME="$home/.local/share" \
  ./install.sh --prefix "$prefix" --no-extension >/dev/null 2>&1 || true

bin="$prefix/bin/isopod"
[ -x "$bin" ] || fail "install.sh did not produce $bin"
out="$("$bin" help 2>&1)" || true
case "$out" in
  *"missing template"*) fail "packaged install can't find its templates: $out" ;;
esac
printf '%s' "$out" | grep -q 'Usage:' || fail "packaged 'isopod help' did not render usage.txt"
ok "packaged install renders templates through the bin symlink"

printf '%spackaging checks passed%s\n' "$c_grn" "$c_rst"
