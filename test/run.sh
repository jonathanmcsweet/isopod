#!/usr/bin/env bash
# Run isopod's test suites locally — the same checks CI runs.
#
#   test/run.sh              lint + stubbed bats + interactive (no engine needed)
#   RUN_LIVE=1 test/run.sh   also runs the live suite against real podman/docker
#
# This is intentionally dependency-light so it works the same on your machine,
# under gitlab-ci-local, and on GitLab's hosted runners.
set -euo pipefail

# The suite sources isopod's modules, which need bash >= 4.4 (macOS /bin/bash
# is 3.2). Fail here with one clear line instead of dozens of cryptic
# `mapfile: command not found` test failures.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
  { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  printf 'error: the test suite needs bash >= 4.4 (this is bash %s)\n' "$BASH_VERSION" >&2
  printf 'macOS: brew install bash, then run: bash test/run.sh (with /opt/homebrew/bin on PATH)\n' >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BATS="$ROOT/test/libs/bats-core/bin/bats"

c_grn=$'\033[32m'
c_red=$'\033[31m'
c_yel=$'\033[33m'
c_rst=$'\033[0m'
step() { printf '\n%s== %s ==%s\n' "$c_yel" "$1" "$c_rst"; }
fail() {
  printf '%s%s%s\n' "$c_red" "$1" "$c_rst" >&2
  exit 1
}

# --- lint -------------------------------------------------------------------
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning isopod lib/isopod.d/*.sh share/isopod-entrypoint lib/find_box_repo.sh lib/guest_egress_allow.sh install.sh test/run.sh test/packaging.sh test/egress-render.sh test/brew-formula.sh test/distro-install.sh verify-host-isolation.sh
  printf '%sshellcheck clean%s\n' "$c_grn" "$c_rst"
else
  printf '%sshellcheck not installed — skipping (install it for full coverage)%s\n' "$c_yel" "$c_rst"
fi

step "shfmt"
# Keep flags in sync with .pre-commit-config.yaml and .editorconfig (-i 2 -ci).
# Pure bash/sh only — shfmt can't parse .bats or the zsh completion.
SHFMT_FILES="isopod lib/isopod.d/*.sh share/isopod-entrypoint lib/find_box_repo.sh lib/guest_egress_allow.sh install.sh verify-host-isolation.sh test/run.sh test/packaging.sh test/egress-render.sh test/brew-formula.sh test/distro-install.sh test/helper.bash completions/isopod.bash"
if command -v shfmt >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if ! shfmt -i 2 -ci -d $SHFMT_FILES; then
    fail "shfmt: formatting differences above — run 'shfmt -i 2 -ci -w $SHFMT_FILES' (or 'pre-commit run shfmt --all-files')"
  fi
  printf '%sshfmt clean%s\n' "$c_grn" "$c_rst"
else
  printf '%sshfmt not installed — skipping (install it for full coverage)%s\n' "$c_yel" "$c_rst"
fi

# --- syntax -----------------------------------------------------------------
step "bash syntax"
bash -n isopod lib/isopod.d/*.sh install.sh verify-host-isolation.sh &&
  printf '%sshell scripts parse%s\n' "$c_grn" "$c_rst"

# --- python lib syntax ------------------------------------------------------
step "python lib"
if command -v python3 >/dev/null 2>&1; then
  for f in lib/*.py; do
    [ -e "$f" ] || continue
    python3 -m py_compile "$f"
  done
  printf '%spython lib compiles%s\n' "$c_grn" "$c_rst"
  if python3 -m pyflakes --version >/dev/null 2>&1; then
    python3 -m pyflakes lib/*.py && printf '%spyflakes clean%s\n' "$c_grn" "$c_rst"
  fi
else
  printf '%spython3 not installed — skipping lib check%s\n' "$c_yel" "$c_rst"
fi

# --- packaging --------------------------------------------------------------
step "packaging: share/ ships and templates render"
bash test/packaging.sh

# --- egress templates -------------------------------------------------------
step "egress: firewall/proxy templates render (and parse where nft is present)"
bash test/egress-render.sh

# --- stubbed bats suite -----------------------------------------------------
step "bats: unit + theming + integration + security-poc (stubbed, no engine)"
[ -x "$BATS" ] || fail "vendored bats not found at $BATS"
"$BATS" test/unit.bats test/theming.bats test/integration.bats test/security-poc.bats

# --- interactive (pexpect) --------------------------------------------------
step "pexpect: interactive prompt tests"
if python3 -c 'import pexpect' 2>/dev/null; then
  python3 test/interactive_test.py
else
  # Name the interpreter: with several python3 installs on PATH, pexpect is often
  # present for one and absent from the one the suite runs.
  printf '%spexpect not importable by %s: skipping (%s -m pip install pexpect)%s\n' \
    "$c_yel" "$(command -v python3 || printf python3)" "$(command -v python3 || printf python3)" "$c_rst"
fi

# --- live (opt-in) ----------------------------------------------------------
if [ "${RUN_LIVE:-0}" = "1" ]; then
  step "bats: LIVE end-to-end (real container engine)"
  "$BATS" test/live.bats
else
  printf '\n%slive tests skipped (set RUN_LIVE=1 to run them against real podman/docker)%s\n' \
    "$c_yel" "$c_rst"
fi

printf '\n%sAll selected suites passed.%s\n' "$c_grn" "$c_rst"
