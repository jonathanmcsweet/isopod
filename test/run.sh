#!/usr/bin/env bash
# Run isopod's test suites locally — the same checks CI runs.
#
#   test/run.sh              lint + stubbed bats + interactive (no engine needed)
#   RUN_LIVE=1 test/run.sh   also runs the live suite against real podman/docker
#
# This is intentionally dependency-light so it works the same on your machine,
# under gitlab-ci-local, and on GitLab's hosted runners.
set -euo pipefail

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
  shellcheck -S warning isopod install.sh test/run.sh test/packaging.sh test/brew-formula.sh verify-host-isolation.sh
  printf '%sshellcheck clean%s\n' "$c_grn" "$c_rst"
else
  printf '%sshellcheck not installed — skipping (install it for full coverage)%s\n' "$c_yel" "$c_rst"
fi

step "shfmt"
# Keep flags in sync with .pre-commit-config.yaml and .editorconfig (-i 2 -ci).
# Pure bash/sh only — shfmt can't parse .bats or the zsh completion.
SHFMT_FILES="isopod install.sh verify-host-isolation.sh test/run.sh test/packaging.sh test/brew-formula.sh test/helper.bash completions/isopod.bash"
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
bash -n isopod install.sh verify-host-isolation.sh &&
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

# --- stubbed bats suite -----------------------------------------------------
step "bats: unit + theming + integration (stubbed, no engine)"
[ -x "$BATS" ] || fail "vendored bats not found at $BATS"
"$BATS" test/unit.bats test/theming.bats test/integration.bats

# --- interactive (pexpect) --------------------------------------------------
step "pexpect: interactive prompt tests"
if python3 -c 'import pexpect' 2>/dev/null; then
  python3 test/interactive_test.py
else
  printf '%spexpect not installed — skipping (pip install pexpect)%s\n' "$c_yel" "$c_rst"
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
