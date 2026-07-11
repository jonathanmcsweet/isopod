#!/usr/bin/env bats
# Regression tests for the security findings in ARCHITECTURE_REVIEW.md:
#   #1 — inject_secrets no longer builds a remote shell command from an
#        interpolated path (now re-validated + base64-armored)
#   #2 — render_tmpl evals a heredoc: a $(...) in a template FILE body executes,
#        but a $(...) in an interpolated VARIABLE value does NOT (single-pass)

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  isopod_setup_env
  load_isopod
}
teardown() { isopod_teardown_env; }

# =============================================================================
# Finding #2: render_tmpl evals a heredoc of the template FILE body. Any
# $(...) appearing literally in a template file executes as bash on the host.
#
# IMPORTANT (verified, not assumed): a $(...) inside a VARIABLE VALUE that is
# interpolated into a template does NOT execute — the eval heredoc performs a
# single-pass expansion of $var to its string value; the $(...) in that value
# is treated as literal text in the heredoc output, not re-evaluated. So the
# exploitable surface is the template FILES themselves, not the values fed
# into them. The risk: any code path that lets an attacker control a template
# file's contents (ISOPOD_SHARE pointing at an attacker dir, or render_tmpl
# called with an attacker-controlled absolute path) is code execution.
# =============================================================================

@test "#2 POC: a \$(...) in a template FILE body executes via render_tmpl" {
  # A template file whose body literally contains $(...) is eval'd verbatim by
  # render_tmpl's `eval "cat <<EOF ... EOF"`. This is the core of finding #2:
  # template files are code, not data.
  local tmpl="$TEST_TMP/evil.tmpl"
  printf 'value is $(touch %s/poc2-marker)\n' "$TEST_TMP" >"$tmpl"

  [ ! -e "$TEST_TMP/poc2-marker" ]
  render_tmpl "$tmpl" >/dev/null
  [ -e "$TEST_TMP/poc2-marker" ] || {
    echo "FAIL: render_tmpl did NOT execute the \$(...) in the template body" >&2
    return 1
  }
}

@test "#2 POC (negative): a \$(...) in a VARIABLE value does NOT execute" {
  # Honest counter-test: a $(...) stored in a variable (e.g. a crafted --image
  # value reaching box-config.yaml's $image) is interpolated as a literal
  # string by the eval heredoc — it is NOT re-evaluated. So value-interpolation
  # is NOT an injection vector; only template-body control is.
  local tmpl="$TEST_TMP/safe.tmpl"
  printf 'image: $evil\n' >"$tmpl"
  local evil='$(touch '"$TEST_TMP"'/poc2-neg-marker)'
  [ ! -e "$TEST_TMP/poc2-neg-marker" ]
  render_tmpl "$tmpl" >/dev/null
  [ ! -e "$TEST_TMP/poc2-neg-marker" ] || {
    echo "FAIL: a variable-value \$(...) unexpectedly executed (it should NOT)" >&2
    return 1
  }
}

# =============================================================================
# Finding #1 (FIXED): inject_secrets used to interpolate the secret target path
# directly into the remote shell string. It now (a) re-validates the spec read
# from meta and (b) delivers the path base64-armored, reconstructing it inside
# the box so no host-controlled string is ever parsed by the box's login shell.
# These tests lock in both properties: the guard still holds, the armored form
# is used, and a backdoor meta spec is refused rather than carried to the box.
# =============================================================================

# A recording ssh stub: captures the exact remote command isopod would run, so
# we can inspect how the path was interpolated into the shell string.
_install_ssh_recorder() {
  cat >"$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
# Record the full argv, then consume stdin (the secret value) and exit 0 so
# inject_secrets believes the injection succeeded.
printf 'ssh %s\n' "\$*" >> "$TEST_TMP/ssh-calls.log"
cat >/dev/null
exit 0
EOF
  chmod +x "$STUB_DIR/ssh"
}

@test "#1: inject_secrets delivers the path base64-armored, not as a raw shell token" {
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'secret-value' >"$ISOPOD_CONFIG_DIR/secrets/TOK"

  # A box with a secret spec in its meta. The path is valid (passes the guard).
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nport=2222\nsecrets=TOK:/run/secrets/TOK\n' \
    >"$(box_dir demo)/meta"

  _install_ssh_recorder
  : >"$TEST_TMP/ssh-calls.log"

  inject_secrets demo

  # The raw path must NOT appear as an interpolated shell token any more.
  ! grep -q "cat >'/run/secrets/TOK'" "$TEST_TMP/ssh-calls.log" || {
    echo "FAIL: raw path was still interpolated into the remote shell string:" >&2
    cat "$TEST_TMP/ssh-calls.log" >&2
    return 1
  }
  # It is carried as base64 and reconstructed in the box (base64 -d), so nothing
  # host-controlled is parsed by the box's login shell.
  local b64
  b64=$(printf '%s' "/run/secrets/TOK" | base64 | tr -d '\n')
  grep -q "$b64" "$TEST_TMP/ssh-calls.log" &&
    grep -q "base64 -d" "$TEST_TMP/ssh-calls.log" || {
    echo "FAIL: path was not delivered base64-armored:" >&2
    cat "$TEST_TMP/ssh-calls.log" >&2
    return 1
  }
}

@test "#1: inject_secrets keeps the box SSH port under its IFS=, scope" {
  # Regression: inject_secrets sets IFS=, to parse the secret spec list, then
  # streams the value over box_ssh. box_ssh reads box_ssh_addr's "host port" with
  # `read`, which used to inherit that IFS=, and drop the port — so it ran
  # `ssh -p ''` and `create --secret` aborted with "failed to inject secret".
  # Confirm the published port reaches the ssh call.
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'secret-value' >"$ISOPOD_CONFIG_DIR/secrets/TOK"
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nport=2222\nsecrets=TOK:/run/secrets/TOK\n' \
    >"$(box_dir demo)/meta"

  _install_ssh_recorder
  : >"$TEST_TMP/ssh-calls.log"

  inject_secrets demo

  grep -q -- '-p 2222' "$TEST_TMP/ssh-calls.log" || {
    echo "FAIL: the published port did not reach ssh (IFS leak?):" >&2
    cat "$TEST_TMP/ssh-calls.log" >&2
    return 1
  }
}

@test "#1 POC: valid_secret_path currently blocks quote-breakout (the only guard)" {
  # Demonstrate that the charset guard is the SOLE barrier: a path containing a
  # single quote (which would break out of the single-quoted interpolation) is
  # rejected. If this guard were ever relaxed, finding #1 becomes RCE.
  run valid_secret_path "/run/secrets/a'b"
  assert_failure
  run valid_secret_path '/run/secrets/$(id)'
  assert_failure
  run valid_secret_path '/run/secrets/a;id'
  assert_failure
}

@test "#1: a backdoor meta spec is re-validated and refused, not carried to the box" {
  # valid_secret_path guards the CREATE path, but inject_secrets also runs on
  # start/reconfigure straight from the stored meta. A meta written by any other
  # means (a second tool, a hand-edit, a future path that skips validation) must
  # not carry an unvalidated spec onward. Craft a spec whose path would break out
  # of a shell quote and confirm inject_secrets refuses it before any SSH call.
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'secret-value' >"$ISOPOD_CONFIG_DIR/secrets/TOK"

  mkdir -p "$(box_dir pwn)"
  printf 'engine=podman\nport=2222\n' >"$(box_dir pwn)/meta"
  # A spec with a single-quote breakout in the path. inject_secrets splits on the
  # first ':' so sname=TOK, spath=<the rest>.
  printf 'secrets=TOK:/run/secrets/x'"'"';touch %s/poc1-marker;'"'"'/y\n' "$TEST_TMP" \
    >>"$(box_dir pwn)/meta"

  _install_ssh_recorder
  : >"$TEST_TMP/ssh-calls.log"

  [ ! -e "$TEST_TMP/poc1-marker" ]

  # inject_secrets now re-validates the spec from meta and dies on the bad path.
  run inject_secrets pwn
  assert_failure

  # The breakout must reach neither the SSH transport nor the filesystem: nothing
  # was recorded, and even the armored form would carry the path as inert base64.
  ! grep -q "touch $TEST_TMP/poc1-marker" "$TEST_TMP/ssh-calls.log" || {
    echo "FAIL: the injected command reached the remote command string:" >&2
    cat "$TEST_TMP/ssh-calls.log" >&2
    return 1
  }
  [ ! -e "$TEST_TMP/poc1-marker" ]
}
