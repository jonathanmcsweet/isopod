#!/usr/bin/env bash
# Shared setup for all isopod bats tests.
#
# Strategy:
#   * Source isopod with ISOPOD_SOURCED=1 so main() does not run; we get all
#     functions in scope and call them directly.
#   * Put a stubs/ dir first on PATH so podman/docker/ssh/flatpak/etc. are
#     replaced by recording fakes. This lets us test create/code/etc. with
#     no real container engine.
#   * Point ISOPOD_CONFIG_DIR and HOME at a per-test tmp dir so nothing
#     touches the real machine and tests are hermetic.

# -P resolves symlinks, matching what the isopod script computes for itself
# (_resolve_script_dir uses `cd -P`). On an ostree distro (Silverblue, Kinoite,
# Bazzite) /home is a symlink to /var/home, so the logical path disagrees with the
# physical one and every test comparing a path against isopod's output fails.
ISOPOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ISOPOD_ROOT

load_libs() {
  load "$ISOPOD_ROOT/test/libs/bats-support/load.bash"
  load "$ISOPOD_ROOT/test/libs/bats-assert/load.bash"
}

# Commands the suite must be able to treat as ABSENT. A stub can ADD a command to
# PATH, but nothing can take one away — so on a machine that genuinely has kata,
# krun, runsc or an editor installed, every test asserting "nothing is installed"
# fails. Worse, it is not confined to those tests: resolve_runtime probes real
# binaries, so a half-installed kata on the host silently changes which runtime
# unrelated create tests select. These names are left out of the mirrored PATH
# below; a test that wants one present installs its own stub, as before.
ISOPOD_TEST_HIDDEN_BINS="kata kata-runtime kata-qemu kata-clh kata-fc krun runsc runsc-kvm crun-vm codium vscodium code cursor windsurf flatpak git-filter-repo"

# A PATH that mirrors the host's, minus ISOPOD_TEST_HIDDEN_BINS. Mirroring —
# rather than listing the tools the suite needs — means nothing can go missing:
# every command still resolves except the handful the tests control. Built once
# per bats run (BATS_RUN_TMPDIR is per-run, so it cannot go stale between runs)
# and reused, because the symlink farm is too slow to rebuild for each test.
isopod_hermetic_bin() {
  local cache="${BATS_RUN_TMPDIR:-${BATS_TMPDIR:-/tmp}}/isopod-hermetic-bin"
  if [ ! -d "$cache" ]; then
    local tmp="$cache.$$" dir f name
    local -a dirs=()
    mkdir -p "$tmp"
    IFS=: read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        name="${f##*/}"
        case " $ISOPOD_TEST_HIDDEN_BINS " in *" $name "*) continue ;; esac
        # First match wins, mirroring how PATH itself resolves a name.
        [ -e "$tmp/$name" ] || ln -s "$f" "$tmp/$name" 2>/dev/null || true
      done
    done
    # Publish atomically so a concurrent builder (bats -j) either wins or loses
    # cleanly, rather than exposing a half-populated directory.
    mv "$tmp" "$cache" 2>/dev/null || rm -rf "$tmp"
  fi
  printf '%s' "$cache"
}

# Create a sandboxed environment for a single test.
isopod_setup_env() {
  TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/isopod-test.XXXXXX")"
  export TEST_TMP
  export HOME="$TEST_TMP/home"
  export ISOPOD_CONFIG_DIR="$TEST_TMP/home/.config/isopod"
  mkdir -p "$HOME/.ssh"

  # Stub directory takes precedence on PATH, over a mirror of the host's PATH
  # with the tests' controlled commands removed (see isopod_hermetic_bin).
  export STUB_DIR="$TEST_TMP/stubs"
  mkdir -p "$STUB_DIR"
  export STUB_LOG="$TEST_TMP/stub-calls.log"
  : >"$STUB_LOG"
  export PATH="$STUB_DIR:$(isopod_hermetic_bin)"
}

isopod_teardown_env() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Source the isopod script's functions without executing main.
load_isopod() {
  ISOPOD_SOURCED=1
  # isopod runs `set -euo pipefail` at the top; sourcing it would leak those
  # options into the bats test shell and change error semantics. Save and
  # restore the relevant shell options around the source.
  local _saved_e _saved_u _saved_pipefail
  [[ $- == *e* ]] && _saved_e=1 || _saved_e=0
  [[ $- == *u* ]] && _saved_u=1 || _saved_u=0
  _saved_pipefail="$(set -o | awk '/pipefail/{print $2}')"
  # shellcheck disable=SC1090
  source "$ISOPOD_ROOT/isopod"
  [ "$_saved_e" = 1 ] || set +e
  [ "$_saved_u" = 1 ] || set +u
  [ "$_saved_pipefail" = on ] || set +o pipefail
}

# Install a stub command that logs its invocation and optionally emits output.
# Usage: make_stub <name> [exit_code] [stdout_text]
# For richer behavior, write the file yourself in STUB_DIR.
make_stub() {
  local name="$1" code="${2:-0}" out="${3:-}"
  cat >"$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$STUB_LOG"
$([ -n "$out" ] && printf 'printf "%%s\\n" %q\n' "$out")
exit $code
EOF
  chmod +x "$STUB_DIR/$name"
}

# Portable userland shims: keep tests green on both GNU (Linux) and BSD (macOS)
# coreutils, whose flags differ. Prefer these over calling stat/sed directly.

# Echo a file's permission bits in octal (e.g. 600). GNU stat uses -c '%a';
# BSD/macOS stat uses -f '%Lp'. Try GNU first, fall back to BSD.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# In-place edit of a file with a sed script. GNU sed wants `-i`, BSD sed wants
# `-i ''` — so sidestep the difference entirely with a temp file.
sed_i() {
  local script="$1" file="$2" tmp
  tmp="$(mktemp)"
  sed "$script" "$file" >"$tmp" && mv "$tmp" "$file"
}

# Look up an IDE binary (find_ide_bin) in an environment isolated from the host's
# real editors, so these tests pass whether or not the developer has codium etc.
# installed. PATH is already hermetic (isopod_hermetic_bin drops the editor names
# wherever they live, including /usr/bin — an earlier version reduced PATH to the
# base system dirs instead, which missed a distro-packaged editor sitting in one
# of them). This closes the remaining leak: the target table is copied with its
# macOS .app paths blanked, so an installed /Applications/*.app cannot satisfy
# the lookup either. Sets IDE_CMD like find_ide_bin and returns its exit status.
ide_lookup() {
  local _share="$ISOPOD_SHARE" _rc=0
  mkdir -p "$TEST_TMP/ide-share"
  awk 'NF==0 || $1 ~ /^#/ { print; next } { $3="-"; print }' \
    "$ISOPOD_ROOT/share/ide-targets" >"$TEST_TMP/ide-share/ide-targets"
  ISOPOD_SHARE="$TEST_TMP/ide-share" find_ide_bin "$@" || _rc=$?
  ISOPOD_SHARE="$_share"
  return "$_rc"
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

# Assert inject_secrets streamed a value to <path> over ssh in the base64-armored
# form: the target path is delivered as base64 and reconstructed in the box
# (base64 -d), so it never appears as a raw shell token. See inject_secrets in
# lib/isopod.d/secret.sh.
assert_secret_injected() {
  local path="$1" b64
  b64=$(printf '%s' "$path" | base64 | tr -d '\n')
  assert_stub_called "ssh .*$b64.*base64 -d.*chmod 400"
}
