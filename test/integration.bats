#!/usr/bin/env bats
# Integration tests for command flows. Engine, ssh, and IDE are all stubbed,
# so these run fast and need no container runtime. They verify orchestration:
# argument validation, which engine commands get issued, state files, and the
# isolation-relevant flags.

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  isopod_setup_env
  install_engine_stubs
}
teardown() { isopod_teardown_env; }

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
  echo "ssh-ed25519 AAAAfake isopod" > "$path.pub"
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
  run "$ISOPOD_ROOT/isopod" create "bad name"
  assert_failure
  assert_output --partial "invalid name"
}

@test "create refuses both --repo and --copy together" {
  run "$ISOPOD_ROOT/isopod" create demo --repo https://x/y --copy /tmp
  assert_failure
  assert_output --partial "either --repo or --copy"
}

@test "create rejects a --copy path that does not exist" {
  run "$ISOPOD_ROOT/isopod" create demo --copy /no/such/path
  assert_failure
  assert_output --partial "does not exist"
}

@test "create rejects an unknown color" {
  run "$ISOPOD_ROOT/isopod" create demo --color neon
  assert_failure
  assert_output --partial "unknown color"
}

# ---- full create flow --------------------------------------------------------
@test "create publishes SSH on loopback only" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  # the run command must bind to 127.0.0.1, never 0.0.0.0 or a bare port
  assert_stub_called 'podman run .*127\.0\.0\.1::22'
  refute_output --partial "0.0.0.0"
}

@test "create generates a dedicated keypair and writes meta" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  [ -f "$ISOPOD_CONFIG_DIR/boxes/demo/id_ed25519" ]
  [ -f "$ISOPOD_CONFIG_DIR/boxes/demo/meta" ]
  run grep '^color=#0f766e$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

@test "create writes the box into the managed ssh config" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  assert_output --partial "Host isopod-demo"
  assert_output --partial "ForwardAgent no"
}

@test "create with --copy issues a cp into the container, not a mount" {
  mkdir -p "$TEST_TMP/src"; echo hi > "$TEST_TMP/src/file.txt"
  run "$ISOPOD_ROOT/isopod" create demo --copy "$TEST_TMP/src" --color blue
  assert_success
  assert_stub_called "podman cp $TEST_TMP/src isopod-demo:"
  # crucially, no bind mount flag should ever appear in the run command
  refute_output --partial "-v "
  assert_stub_not_called 'podman run .*--volume'
  assert_stub_not_called 'podman run .* -v '
}

@test "create accepts --copy=path the same as --copy path" {
  mkdir -p "$TEST_TMP/src"; echo hi > "$TEST_TMP/src/file.txt"
  run "$ISOPOD_ROOT/isopod" create demo --copy="$TEST_TMP/src" --color blue
  assert_success
  assert_stub_called "podman cp $TEST_TMP/src isopod-demo:"
}

@test "create applies Tier 1 fingerprint masks from the hardening profile" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  # podman gets a single --security-opt mask= list covering the leaky paths
  assert_stub_called 'podman run .*--security-opt mask=.*/sys/class/dmi'
  assert_stub_called 'podman run .*mask=.*/proc/cmdline'
}

@test "create injects a Tier 2 runtime when ISOPOD_RUNTIME is set" {
  ISOPOD_RUNTIME=runsc run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*--runtime runsc'
}

@test "fetch requires a box name" {
  run "$ISOPOD_ROOT/isopod" fetch
  assert_failure
  assert_output --partial "usage: isopod fetch"
}

@test "fetch rejects unknown options" {
  run "$ISOPOD_ROOT/isopod" fetch demo --bogus
  assert_failure
  assert_output --partial "unknown option for fetch"
}

# ---- remap (operates purely on host git; no container needed) -----------------
# Build a host repo with the box's commits imported under refs/remotes/<name>/*,
# exactly as `isopod fetch` would leave them. The "box" commits use a distinct
# identity so we can prove only those get rewritten.
_seed_remapped_host() { # _seed_remapped_host <host-dir>
  local host="$1" box="$TEST_TMP/box"
  git init -q "$box"
  git -C "$box" config user.email dev@mybox.local; git -C "$box" config user.name dev
  echo a > "$box/a"; git -C "$box" add a
  # the body contains a line that LOOKS like an author header — the rewriter
  # must leave it byte-for-byte intact (only the real identity may change).
  printf 'box: work 1\n\nauthor Faker <dev@mybox.local> 0 +0000\n' | git -C "$box" commit -qF -
  git -C "$box" -c user.email=mate@corp -c user.name=Mate commit -q --allow-empty -m "mate: review"
  git init -q "$host"
  git -C "$host" config user.email me@home; git -C "$host" config user.name Me
  echo h > "$host/h"; git -C "$host" add h; git -C "$host" commit -qm "host: mine"
  git -C "$host" fetch --no-tags "$box" "refs/heads/*:refs/remotes/mybox/*" >/dev/null 2>&1
}

@test "remap requires new --name and --email" {
  _seed_remapped_host "$TEST_TMP/host"
  run "$ISOPOD_ROOT/isopod" remap mybox "$TEST_TMP/host" --old-email dev@mybox.local --name X
  assert_failure
  assert_output --partial "--email"
}

@test "remap errors when the box has no fetched refs" {
  git init -q "$TEST_TMP/plain"
  run "$ISOPOD_ROOT/isopod" remap ghost "$TEST_TMP/plain" \
    --old-email a@b --name X --email y@z --force
  assert_failure
  assert_output --partial "no refs found under refs/remotes/ghost/"
}

@test "remap rewrites only the box identity and leaves host commits intact" {
  _seed_remapped_host "$TEST_TMP/host"
  local host="$TEST_TMP/host"
  local host_sha; host_sha=$(git -C "$host" rev-parse master)
  run "$ISOPOD_ROOT/isopod" remap mybox "$host" \
    --old-email dev@mybox.local --name "Real Name" --email real@me.com --force
  assert_success
  # the box-identity commit is rewritten...
  run git -C "$host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Real Name <real@me.com>"
  # ...the teammate commit on the same branch is NOT...
  assert_output --partial "Mate <mate@corp>"
  refute_output --partial "dev@mybox.local"
  # ...the host's own branch is byte-for-byte unchanged...
  run git -C "$host" rev-parse master
  assert_output "$host_sha"
  # ...the author-looking line in the commit BODY survives verbatim (proving
  # the rewrite is data-block aware, not a blind line replacement)...
  run git -C "$host" log --format='%B' refs/remotes/mybox/master
  assert_output --partial "author Faker <dev@mybox.local> 0 +0000"
  # ...and a restore point was left behind.
  run git -C "$host" for-each-ref refs/remap-backup/
  assert_output --partial "mybox/master"
}

@test "create with --repo clones inside the box" {
  run "$ISOPOD_ROOT/isopod" create demo --repo https://example.com/r.git --color blue
  assert_success
  assert_stub_called "podman exec .*git clone"
}

@test "create refuses to clobber an existing box" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_failure
  assert_output --partial "already exists"
}

@test "create with --no-sudo does not install a sudoers entry" {
  run "$ISOPOD_ROOT/isopod" create demo --no-sudo --color teal
  assert_success
  assert_stub_not_called "sudoers"
}

@test "create defaults to giving passwordless sudo" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "sudoers"
}

# ---- list / info -------------------------------------------------------------
@test "list shows a created box and its port" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" list
  assert_success
  assert_output --partial "demo"
  assert_output --partial "45678"
}

@test "info errors on a nonexistent box" {
  run "$ISOPOD_ROOT/isopod" info ghost
  assert_failure
  assert_output --partial "no such sandbox"
}

# ---- code flow ---------------------------------------------------------------
@test "code launches the IDE with a remote-ssh folder uri" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  # provide a codium stub that records its launch args
  cat > "$STUB_DIR/codium" <<'EOF'
#!/usr/bin/env bash
echo "codium $*" >> "$STUB_LOG"
exit 0
EOF
  chmod +x "$STUB_DIR/codium"
  run "$ISOPOD_ROOT/isopod" code demo
  assert_success
  assert_stub_called "codium .*--folder-uri vscode-remote://ssh-remote\+isopod-demo/home/dev/workspace"
}

@test "code auto-installs the open-remote-ssh extension if absent" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  cat > "$STUB_DIR/codium" <<'EOF'
#!/usr/bin/env bash
echo "codium $*" >> "$STUB_LOG"
# --list-extensions returns nothing, so isopod should install
[ "$1" = "--list-extensions" ] && exit 0
exit 0
EOF
  chmod +x "$STUB_DIR/codium"
  run "$ISOPOD_ROOT/isopod" code demo
  assert_stub_called "codium --install-extension jeanp413.open-remote-ssh"
}

@test "code errors when the requested IDE is not installed" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" code demo --app windsurf
  assert_failure
  assert_output --partial "could not find 'windsurf'"
}

# ---- rm ----------------------------------------------------------------------
@test "rm --force removes the container, keys, and ssh config entry" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  [ -d "$ISOPOD_CONFIG_DIR/boxes/demo" ]
  run "$ISOPOD_ROOT/isopod" rm demo --force
  assert_success
  [ ! -d "$ISOPOD_CONFIG_DIR/boxes/demo" ]
  assert_stub_called "podman rm -f isopod-demo"
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  refute_output --partial "Host isopod-demo"
}

@test "rm errors on a nonexistent box" {
  run "$ISOPOD_ROOT/isopod" rm ghost --force
  assert_failure
  assert_output --partial "no such sandbox"
}
