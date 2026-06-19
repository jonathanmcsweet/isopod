#!/usr/bin/env bash
# Shared setup for all aibox bats tests.
#
# Strategy:
#   * Source aibox with AIBOX_SOURCED=1 so main() does not run; we get all
#     functions in scope and call them directly.
#   * Put a stubs/ dir first on PATH so podman/docker/ssh/flatpak/etc. are
#     replaced by recording fakes. This lets us test create/code/etc. with
#     no real container engine.
#   * Point AIBOX_CONFIG_DIR and HOME at a per-test tmp dir so nothing
#     touches the real machine and tests are hermetic.

AIBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AIBOX_ROOT

load_libs() {
  load "$AIBOX_ROOT/test/libs/bats-support/load.bash"
  load "$AIBOX_ROOT/test/libs/bats-assert/load.bash"
}

# Create a sandboxed environment for a single test.
aibox_setup_env() {
  TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/aibox-test.XXXXXX")"
  export TEST_TMP
  export HOME="$TEST_TMP/home"
  export AIBOX_CONFIG_DIR="$TEST_TMP/home/.config/aibox"
  mkdir -p "$HOME/.ssh"

  # Stub directory takes precedence on PATH.
  export STUB_DIR="$TEST_TMP/stubs"
  mkdir -p "$STUB_DIR"
  export STUB_LOG="$TEST_TMP/stub-calls.log"
  : > "$STUB_LOG"
  export PATH="$STUB_DIR:$PATH"
}

aibox_teardown_env() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Source the aibox script's functions without executing main.
load_aibox() {
  AIBOX_SOURCED=1
  # aibox runs `set -euo pipefail` at the top; sourcing it would leak those
  # options into the bats test shell and change error semantics. Save and
  # restore the relevant shell options around the source.
  local _saved_e _saved_u _saved_pipefail
  [[ $- == *e* ]] && _saved_e=1 || _saved_e=0
  [[ $- == *u* ]] && _saved_u=1 || _saved_u=0
  _saved_pipefail="$(set -o | awk '/pipefail/{print $2}')"
  # shellcheck disable=SC1090
  source "$AIBOX_ROOT/aibox"
  [ "$_saved_e" = 1 ] || set +e
  [ "$_saved_u" = 1 ] || set +u
  [ "$_saved_pipefail" = on ] || set +o pipefail
}

# Install a stub command that logs its invocation and optionally emits output.
# Usage: make_stub <name> [exit_code] [stdout_text]
# For richer behavior, write the file yourself in STUB_DIR.
make_stub() {
  local name="$1" code="${2:-0}" out="${3:-}"
  cat > "$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$STUB_LOG"
$( [ -n "$out" ] && printf 'printf "%%s\\n" %q\n' "$out" )
exit $code
EOF
  chmod +x "$STUB_DIR/$name"
}

# Assert that the stub log contains a line matching a regex.
assert_stub_called() {
  local pattern="$1"
  if ! grep -Eq "$pattern" "$STUB_LOG"; then
    echo "expected a stub call matching: $pattern" >&2
    echo "--- actual calls ---" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}

assert_stub_not_called() {
  local pattern="$1"
  if grep -Eq "$pattern" "$STUB_LOG"; then
    echo "did NOT expect a stub call matching: $pattern" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}
