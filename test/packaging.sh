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
c_grn=$'\033[32m'
c_red=$'\033[31m'
c_rst=$'\033[0m'
ok() { printf '%s  ok%s %s\n' "$c_grn" "$c_rst" "$1"; }
fail() {
  printf '%sFAIL%s %s\n' "$c_red" "$c_rst" "$1" >&2
  exit 1
}

# 1. Every template referenced by the script must exist in share/. Strip comments
#    first (sed) so a doc comment that merely mentions "render_tmpl <word>" isn't
#    mistaken for a call — only actual code is scanned.
while read -r tmpl; do
  [ -f "share/$tmpl" ] || fail "isopod calls render_tmpl '$tmpl' but share/$tmpl is missing"
done < <(sed 's/#.*$//' isopod lib/isopod.d/*.sh | grep -oE 'render_tmpl[[:space:]]+[A-Za-z0-9._-]+' | awk '{print $2}' | sort -u)
ok "every render_tmpl reference has a share/ file"

# 1b. The base image build reads share/Dockerfile at runtime — it must exist.
[ -f "share/Dockerfile" ] || fail "isopod builds from share/Dockerfile but it is missing"
ok "share/Dockerfile is present"

# 2. The tag tarball GitHub serves is `git archive` of the commit — make sure it
#    carries share/, or the formula has nothing to install.
archive=$(git archive --format=tar HEAD -- share | tar t 2>/dev/null)
printf '%s\n' "$archive" | grep -q 'share/usage.txt' ||
  fail "share/ is not in the git archive — the release tarball would omit it"
printf '%s\n' "$archive" | grep -q 'share/Dockerfile' ||
  fail "share/Dockerfile is not in the git archive — the base image build would break"
ok "release tarball ships share/ (incl. Dockerfile)"

# 3. Install the symlink way (lib/, share/, security/ beside the script under a
#    libexec dir, bin symlink) into a throwaway prefix, then render a template
#    through the symlink. HOME/XDG are redirected so completions don't escape.
prefix="$(mktemp -d)"
home="$(mktemp -d)"
trap 'rm -rf "$prefix" "$home"' EXIT
# Gate on the render, not on the installer's exit status: what this check proves
# is that the packaged layout resolves its templates.
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
