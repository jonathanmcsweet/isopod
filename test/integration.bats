#!/usr/bin/env bats
# Integration tests for command flows. Engine, ssh, and IDE are all stubbed,
# so these run fast and need no container runtime. They verify orchestration:
# argument validation, which engine commands get issued, state files, and the
# isolation-relevant flags.

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  aibox_setup_env
  install_engine_stubs
}
teardown() { aibox_teardown_env; }

# A podman stub rich enough for create/list/info/rm to traverse their paths.
install_engine_stubs() {
  cat > "$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
cmd="$1"; shift || true
case "$cmd" in
  info)    exit 0 ;;
  image)   # 'image exists' / 'image inspect' -> pretend image is missing once
           [ "$1" = exists ] && exit 1
           exit 1 ;;
  build)   exit 0 ;;
  run)     echo "deadbeefcontainerid"; exit 0 ;;
  port)    echo "127.0.0.1:45678" ;;        # maps 22/tcp -> host 45678
  exec)    exit 0 ;;
  cp)      exit 0 ;;
  inspect) echo "running" ;;                # state status
  start|stop) exit 0 ;;
  rm)      exit 0 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/podman"

  # ssh-keygen: actually produce key files so downstream steps find them.
  cat > "$STUB_DIR/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
echo "ssh-keygen $*" >> "$STUB_LOG"
# parse -f <path>
path=""; prev=""
for a in "$@"; do [ "$prev" = "-f" ] && path="$a"; prev="$a"; done
if [ -n "$path" ]; then
  echo "PRIVKEY" > "$path"
  echo "ssh-ed25519 AAAAfake aibox" > "$path.pub"
fi
exit 0
EOF
  chmod +x "$STUB_DIR/ssh-keygen"

  # ssh-keyscan: emit a fake host key so scan_host_key succeeds.
  cat > "$STUB_DIR/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
echo "ssh-keyscan $*" >> "$STUB_LOG"
echo "[127.0.0.1]:45678 ssh-ed25519 AAAAfakehostkey"
exit 0
EOF
  chmod +x "$STUB_DIR/ssh-keyscan"

  # ssh: used by wait_for_ssh (BatchMode true) — succeed immediately.
  make_stub ssh 0
  make_stub flatpak 1   # no flatpak by default
}

# ---- argument validation (no engine work should happen) ----------------------
@test "create rejects an invalid box name" {
  run "$AIBOX_ROOT/aibox" create "bad name"
  assert_failure
  assert_output --partial "invalid name"
}

@test "create refuses both --repo and --copy together" {
  run "$AIBOX_ROOT/aibox" create demo --repo https://x/y --copy /tmp
  assert_failure
  assert_output --partial "either --repo or --copy"
}

@test "create rejects a --copy path that does not exist" {
  run "$AIBOX_ROOT/aibox" create demo --copy /no/such/path
  assert_failure
  assert_output --partial "does not exist"
}

@test "create rejects an unknown color" {
  run "$AIBOX_ROOT/aibox" create demo --color neon
  assert_failure
  assert_output --partial "unknown color"
}

# ---- full create flow --------------------------------------------------------
@test "create publishes SSH on loopback only" {
  run "$AIBOX_ROOT/aibox" create demo --color teal
  assert_success
  # the run command must bind to 127.0.0.1, never 0.0.0.0 or a bare port
  assert_stub_called 'podman run .*127\.0\.0\.1::22'
  refute_output --partial "0.0.0.0"
}

@test "create generates a dedicated keypair and writes meta" {
  run "$AIBOX_ROOT/aibox" create demo --color teal
  assert_success
  [ -f "$AIBOX_CONFIG_DIR/boxes/demo/id_ed25519" ]
  [ -f "$AIBOX_CONFIG_DIR/boxes/demo/meta" ]
  run grep '^color=#0f766e$' "$AIBOX_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

@test "create writes the box into the managed ssh config" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  run cat "$AIBOX_CONFIG_DIR/ssh_config"
  assert_output --partial "Host aibox-demo"
  assert_output --partial "ForwardAgent no"
}

@test "create with --copy issues a cp into the container, not a mount" {
  mkdir -p "$TEST_TMP/src"; echo hi > "$TEST_TMP/src/file.txt"
  run "$AIBOX_ROOT/aibox" create demo --copy "$TEST_TMP/src" --color blue
  assert_success
  assert_stub_called "podman cp $TEST_TMP/src aibox-demo:"
  # crucially, no bind mount flag should ever appear in the run command
  refute_output --partial "-v "
  assert_stub_not_called 'podman run .*--volume'
  assert_stub_not_called 'podman run .* -v '
}

@test "create applies Tier 1 fingerprint masks from the hardening profile" {
  run "$AIBOX_ROOT/aibox" create demo --color teal
  assert_success
  # podman gets a single --security-opt mask= list covering the leaky paths
  assert_stub_called 'podman run .*--security-opt mask=.*/sys/class/dmi'
  assert_stub_called 'podman run .*mask=.*/proc/cmdline'
}

@test "create injects a Tier 2 runtime when AIBOX_RUNTIME is set" {
  AIBOX_RUNTIME=runsc run "$AIBOX_ROOT/aibox" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*--runtime runsc'
}

@test "fetch requires a box name" {
  run "$AIBOX_ROOT/aibox" fetch
  assert_failure
  assert_output --partial "usage: aibox fetch"
}

@test "fetch rejects unknown options" {
  run "$AIBOX_ROOT/aibox" fetch demo --bogus
  assert_failure
  assert_output --partial "unknown option for fetch"
}

@test "create with --repo clones inside the box" {
  run "$AIBOX_ROOT/aibox" create demo --repo https://example.com/r.git --color blue
  assert_success
  assert_stub_called "podman exec .*git clone"
}

@test "create refuses to clobber an existing box" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  run "$AIBOX_ROOT/aibox" create demo --color teal
  assert_failure
  assert_output --partial "already exists"
}

@test "create with --no-sudo does not install a sudoers entry" {
  run "$AIBOX_ROOT/aibox" create demo --no-sudo --color teal
  assert_success
  assert_stub_not_called "sudoers"
}

@test "create defaults to giving passwordless sudo" {
  run "$AIBOX_ROOT/aibox" create demo --color teal
  assert_success
  assert_stub_called "sudoers"
}

# ---- list / info -------------------------------------------------------------
@test "list shows a created box and its port" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  run "$AIBOX_ROOT/aibox" list
  assert_success
  assert_output --partial "demo"
  assert_output --partial "45678"
}

@test "info errors on a nonexistent box" {
  run "$AIBOX_ROOT/aibox" info ghost
  assert_failure
  assert_output --partial "no such sandbox"
}

# ---- code flow ---------------------------------------------------------------
@test "code launches the IDE with a remote-ssh folder uri" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  # provide a codium stub that records its launch args
  cat > "$STUB_DIR/codium" <<'EOF'
#!/usr/bin/env bash
echo "codium $*" >> "$STUB_LOG"
exit 0
EOF
  chmod +x "$STUB_DIR/codium"
  run "$AIBOX_ROOT/aibox" code demo
  assert_success
  assert_stub_called "codium .*--folder-uri vscode-remote://ssh-remote\+aibox-demo/home/dev/workspace"
}

@test "code auto-installs the open-remote-ssh extension if absent" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  cat > "$STUB_DIR/codium" <<'EOF'
#!/usr/bin/env bash
echo "codium $*" >> "$STUB_LOG"
# --list-extensions returns nothing, so aibox should install
[ "$1" = "--list-extensions" ] && exit 0
exit 0
EOF
  chmod +x "$STUB_DIR/codium"
  run "$AIBOX_ROOT/aibox" code demo
  assert_stub_called "codium --install-extension jeanp413.open-remote-ssh"
}

@test "code errors when the requested IDE is not installed" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  run "$AIBOX_ROOT/aibox" code demo --app windsurf
  assert_failure
  assert_output --partial "could not find 'windsurf'"
}

# ---- rm ----------------------------------------------------------------------
@test "rm --force removes the container, keys, and ssh config entry" {
  "$AIBOX_ROOT/aibox" create demo --color teal
  [ -d "$AIBOX_CONFIG_DIR/boxes/demo" ]
  run "$AIBOX_ROOT/aibox" rm demo --force
  assert_success
  [ ! -d "$AIBOX_CONFIG_DIR/boxes/demo" ]
  assert_stub_called "podman rm -f aibox-demo"
  run cat "$AIBOX_CONFIG_DIR/ssh_config"
  refute_output --partial "Host aibox-demo"
}

@test "rm errors on a nonexistent box" {
  run "$AIBOX_ROOT/aibox" rm ghost --force
  assert_failure
  assert_output --partial "no such sandbox"
}
