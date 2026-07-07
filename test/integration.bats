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
  info)    # A realistic ociRuntimes listing so runtime_preflight and doctor see
           # the sandboxed runtimes these tests exercise as "registered".
           cat <<'INFO'
host:
  ociRuntimes:
    crun: [/usr/bin/crun]
    krun: [/usr/bin/krun]
    runc: [/usr/bin/runc]
    runsc: [/usr/bin/runsc]
    kata-runtime: [/usr/bin/kata-runtime]
INFO
           exit 0 ;;
  image)   # 'image exists' / 'image inspect' -> pretend image is missing once
           [ "$1" = exists ] && exit 1
           exit 1 ;;
  build)   exit 0 ;;
  run)     echo "deadbeefcontainerid"; exit 0 ;;
  port)    echo "127.0.0.1:45678" ;;        # maps 2222/tcp -> host 45678
  exec)    exit 0 ;;
  cp)      exit 0 ;;
  inspect) echo "running" ;;                # state status
  commit)  exit 0 ;;                        # snapshot for reconfigure
  rmi)     exit 0 ;;                         # drop old snapshot
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

  # ssh: used by wait_for_ssh (BatchMode true) and every box op — succeed.
  # Drain any piped stdin (e.g. a tar stream from copy-in) so the writer does
  # not get SIGPIPE under `set -o pipefail`; skip when stdin is a tty so
  # non-piped calls never block.
  cat >"$STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$STUB_LOG"
[ -t 0 ] || cat >/dev/null 2>&1 || true
exit 0
EOF
  chmod +x "$STUB_DIR/ssh"
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
  assert_stub_called 'podman run .*127\.0\.0\.1::2222'
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

@test "create with --copy tars into the container, not a mount" {
  mkdir -p "$TEST_TMP/src"; echo hi > "$TEST_TMP/src/file.txt"
  run "$ISOPOD_ROOT/isopod" create demo --copy "$TEST_TMP/src" --color blue
  assert_success
  # files stream in over ssh as a tar archive extracted in the workspace
  assert_stub_called "ssh .*tar -C /home/dev/workspace -xpf -"
  # crucially, no bind mount flag should ever appear in the run command
  refute_output --partial "-v "
  assert_stub_not_called 'podman run .*--volume'
  assert_stub_not_called 'podman run .* -v '
}

@test "create accepts --copy=path the same as --copy path" {
  mkdir -p "$TEST_TMP/src"; echo hi > "$TEST_TMP/src/file.txt"
  run "$ISOPOD_ROOT/isopod" create demo --copy="$TEST_TMP/src" --color blue
  assert_success
  assert_stub_called "ssh .*tar -C /home/dev/workspace -xpf -"
}

@test "create applies Tier 1 fingerprint masks from the hardening profile" {
  # --container forces Tier 1: the masks hide HOST hardware a shared-kernel box
  # can read. A microVM has its own kernel + virtual devices, so isopod skips the
  # masks there (covered by the hardening_run_args unit tests) — force Tier 1 so
  # this test is deterministic whether or not the runner can auto-select a microVM.
  run "$ISOPOD_ROOT/isopod" create demo --container --color teal
  assert_success
  # podman gets a single --security-opt mask= list covering the leaky paths
  assert_stub_called 'podman run .*--security-opt mask=.*/sys/class/dmi'
  assert_stub_called 'podman run .*mask=.*/proc/cmdline'
}

@test "create injects a Tier 2 runtime when ISOPOD_RUNTIME is set" {
  ISOPOD_RUNTIME=runsc run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*--runtime runsc'
  # Tier 2 shares the host kernel — no microVM memory default.
  assert_stub_not_called 'podman run .*--memory'
}

@test "create defaults --memory for a Tier 3 microVM runtime" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*--runtime krun'
  assert_stub_called 'podman run .*--memory 2g'
}

@test "explicit --memory overrides the microVM default" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --memory 8g --color teal
  assert_success
  assert_stub_called 'podman run .*--memory 8g'
  assert_stub_not_called 'podman run .*--memory 2g'
}

@test "ISOPOD_MICROVM_MEMORY overrides the microVM memory default" {
  ISOPOD_MICROVM_MEMORY=4g ISOPOD_RUNTIME=krun \
    run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*--memory 4g'
}

@test "create --container runs a plain container and records container mode" {
  # --container forces Tier 1 even when a runtime is configured.
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --container --color teal
  assert_success
  assert_stub_not_called 'podman run .*--runtime'
  assert_stub_not_called 'podman run .*--memory 2g' # no microVM memory default
  grep -qx 'runtime=container' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
}

@test "create builds the base image from share/Dockerfile with build args" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "podman build .*--build-arg ISOPOD_BASE="
  assert_stub_called "podman build .*--build-arg ISOPOD_USER=dev"
  assert_stub_called "podman build .*-f $ISOPOD_ROOT/share/Dockerfile"
}

@test "create builds a lean base by default (no dev/test toolchain)" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "podman build .*--build-arg ISOPOD_DEV_TOOLS=0"
}

@test "create --dev requests the dev/test toolchain in the image build" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal --dev
  assert_success
  assert_stub_called "podman build .*--build-arg ISOPOD_DEV_TOOLS=1"
}

@test "create makes a degraded OPEN network unmissable" {
  # The stubbed podman reports rootless, so default-on egress cannot be enforced
  # and resolve_egress degrades to an OPEN network. The create summary must say so.
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_output --partial "Network: OPEN"
  assert_output --partial "could NOT be enforced"
  assert_output --partial "sudo isopod egress apply"
}

@test "create with egress disabled by config notes OPEN without the degrade warning" {
  ISOPOD_EGRESS=off run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_output --partial "Network: OPEN (egress disabled by config)"
  refute_output --partial "could NOT be enforced"
}

# ---- --expose ----------------------------------------------------------------
@test "create --expose publishes ports on loopback only" {
  run "$ISOPOD_ROOT/isopod" create demo --expose 3001:3000 --expose 8080 --color teal
  assert_success
  assert_stub_called 'podman run .*-p 127\.0\.0\.1:3001:3000'
  assert_stub_called 'podman run .*-p 127\.0\.0\.1:8080:8080'
  refute_output --partial "0.0.0.0"
  run grep '^expose=3001:3000,8080:8080$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

@test "create rejects an out-of-range --expose port" {
  run "$ISOPOD_ROOT/isopod" create demo --expose 70000 --color teal
  assert_failure
  assert_output --partial "invalid --expose"
}

@test "create rejects a non-numeric --expose spec" {
  run "$ISOPOD_ROOT/isopod" create demo --expose web:3000 --color teal
  assert_failure
  assert_output --partial "invalid --expose"
}

@test "create rejects an out-of-range --port" {
  run "$ISOPOD_ROOT/isopod" create demo --port 99999 --color teal
  assert_failure
  assert_output --partial "invalid --port"
}

@test "create rejects a non-numeric --port" {
  run "$ISOPOD_ROOT/isopod" create demo --port ssh --color teal
  assert_failure
  assert_output --partial "invalid --port"
}

@test "create rejects a --port already used by another box" {
  # Seed a box whose meta claims port 12345, then ask for the same port.
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/other"
  printf 'port=12345\n' > "$ISOPOD_CONFIG_DIR/boxes/other/meta"
  run "$ISOPOD_ROOT/isopod" create demo --port 12345 --color teal
  assert_failure
  assert_output --partial "already used by box 'other'"
}

@test "create on Docker warns that /proc file masks can't be applied" {
  # A docker stub (logs as 'docker'). Select it with --engine docker rather than
  # by removing the podman stub: a runner may have a real podman on PATH that the
  # stub only shadows, so unshadowing it would pick the real engine.
  cat > "$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
cmd="$1"; shift || true
case "$cmd" in
  info)    exit 0 ;;
  image)   exit 1 ;;                        # pretend the base image is missing
  build)   exit 0 ;;
  run)     echo "deadbeefcontainerid"; exit 0 ;;
  port)    echo "127.0.0.1:45678" ;;
  inspect) echo "running" ;;
  start|stop|rm|rmi|commit) exit 0 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/docker"
  run "$ISOPOD_ROOT/isopod" create demo --color teal --engine docker
  assert_success
  assert_output --partial "Docker can't mask"
  assert_output --partial "/proc/cmdline"
  # directory masks are still applied as --tmpfs, and no /proc bind is attempted
  assert_stub_called "docker run .*--tmpfs /sys/class/net"
  assert_stub_not_called "docker run .*/dev/null:/proc"
}

# ---- --dockerfile ------------------------------------------------------------
@test "create --dockerfile builds the user image and layers the base on it" {
  printf 'FROM debian:bookworm-slim\nRUN true\n' > "$TEST_TMP/Dockerfile"
  run "$ISOPOD_ROOT/isopod" create demo --dockerfile "$TEST_TMP/Dockerfile" --color teal
  assert_success
  # the project's Dockerfile is built into an isopod-user image...
  assert_stub_called "podman build .*-f $TEST_TMP/Dockerfile"
  assert_stub_called "podman build .*-t localhost/isopod-user:"
  # ...which then becomes the base passed to the sandbox image build
  assert_stub_called "podman build .*--build-arg ISOPOD_BASE=localhost/isopod-user:"
}

@test "create refuses both --image and --dockerfile" {
  printf 'FROM debian\n' > "$TEST_TMP/Dockerfile"
  run "$ISOPOD_ROOT/isopod" create demo --image ubuntu:24.04 --dockerfile "$TEST_TMP/Dockerfile"
  assert_failure
  assert_output --partial "either --image or --dockerfile"
}

@test "create rejects a --dockerfile that does not exist" {
  run "$ISOPOD_ROOT/isopod" create demo --dockerfile /no/such/Dockerfile
  assert_failure
  assert_output --partial "--dockerfile not found"
}

# ---- config / reconfigure ----------------------------------------------------
@test "create writes a per-box config.yaml shaped like a Compose service" {
  # --container (Tier 1) so the fingerprint masks render into the reference; a
  # microVM box correctly omits them (its guest kernel has nothing to mask).
  run "$ISOPOD_ROOT/isopod" create demo --container --expose 3001:3000 --memory 4g --color teal
  assert_success
  cfg="$ISOPOD_CONFIG_DIR/boxes/demo/config.yaml"
  [ -f "$cfg" ]
  run cat "$cfg"
  assert_output --partial "REFERENCE Compose file"
  assert_output --partial "services:"
  assert_output --partial "container_name: isopod-demo"
  assert_output --partial "mem_limit: 4g"
  assert_output --partial '- "127.0.0.1:3001:3000"'
  assert_output --partial "security_opt:"   # masks rendered into the reference
}

@test "config prints the box's config.yaml" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" config demo
  assert_success
  assert_output --partial "isopod reconfigure demo"
  assert_output --partial "x-isopod-color:"
}

@test "reconfigure snapshots the box and recreates it with new settings" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" reconfigure demo --memory 8g --expose 5173
  assert_success
  # snapshot to a per-box image, then recreate from it with the new flags
  assert_stub_called "podman commit isopod-demo localhost/isopod-box-demo:"
  assert_stub_called "podman run .*--memory 8g"
  assert_stub_called 'podman run .*-p 127\.0\.0\.1:5173:5173'
  # records updated in both meta and config.yaml
  run grep '^memory=8g$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/config.yaml"
  assert_output --partial "mem_limit: 8g"
  assert_output --partial '- "127.0.0.1:5173:5173"'
}

@test "reconfigure errors on an unknown box" {
  run "$ISOPOD_ROOT/isopod" reconfigure ghost --memory 4g
  assert_failure
  assert_output --partial "no such sandbox"
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

@test "remap defaults the new identity from host git config" {
  # _seed_remapped_host sets the host repo's user to Me <me@home>; with no
  # --name/--email the rewrite should fall back to exactly that.
  _seed_remapped_host "$TEST_TMP/host"
  run "$ISOPOD_ROOT/isopod" remap mybox "$TEST_TMP/host" --old-email dev@mybox.local --force
  assert_success
  run git -C "$TEST_TMP/host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Me <me@home>"
}

@test "remap honors ISOPOD_GIT_NAME/EMAIL over host git config" {
  _seed_remapped_host "$TEST_TMP/host"
  run env ISOPOD_GIT_NAME="Env Name" ISOPOD_GIT_EMAIL=env@me.com \
    "$ISOPOD_ROOT/isopod" remap mybox "$TEST_TMP/host" --old-email dev@mybox.local --force
  assert_success
  run git -C "$TEST_TMP/host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Env Name <env@me.com>"
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

@test "remap accepts --opt=value, including a name with spaces" {
  _seed_remapped_host "$TEST_TMP/host"
  local host="$TEST_TMP/host"
  # the exact form that used to fail: --name="John Doe" plus other =value opts
  run "$ISOPOD_ROOT/isopod" remap mybox "$host" \
    --old-email=dev@mybox.local --name="Real Name" --email=real@me.com --force
  assert_success
  refute_output --partial "unknown option"
  run git -C "$host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Real Name <real@me.com>"
}

@test "remap --remap-file works without a host git identity" {
  # A remap file supplies every identity, so the run must not require the host
  # repo (or any git config) to carry a user.name/user.email.
  _seed_remapped_host "$TEST_TMP/host"
  local host="$TEST_TMP/host"
  git -C "$host" config --unset user.name
  git -C "$host" config --unset user.email
  printf 'dev@mybox.local -> Real Name <real@me.com>\n' > "$TEST_TMP/remap.txt"
  run env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    "$ISOPOD_ROOT/isopod" remap mybox "$host" --remap-file "$TEST_TMP/remap.txt" --force
  assert_success
  refute_output --partial "no new author"
  run git -C "$host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Real Name <real@me.com>"
}

@test "create with --repo clones inside the box over ssh" {
  run "$ISOPOD_ROOT/isopod" create demo --repo https://example.com/r.git --color blue
  assert_success
  assert_stub_called "ssh .*git clone"
}

@test "create refuses to overwrite an existing box" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_failure
  assert_output --partial "already exists"
}

@test "create with --no-sudo tells the box entrypoint to drop sudo" {
  run "$ISOPOD_ROOT/isopod" create demo --no-sudo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_SUDO=0"
  assert_stub_not_called "ISOPOD_SUDO=1"
}

@test "create defaults to giving passwordless sudo" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_SUDO=1"
}

@test "create passes the box public key to the entrypoint (no exec inject)" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_AUTHORIZED_KEY=ssh-ed25519"
  assert_stub_not_called "exec .*authorized_keys"
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

# ---- shell -------------------------------------------------------------------
@test "shell starts a stopped box before connecting" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  # Make the engine report the box as stopped, so shell must start it (like code).
  cat > "$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
cmd="$1"; shift || true
case "$cmd" in
  info) exit 0 ;;
  inspect) echo "exited" ;;
  port) echo "127.0.0.1:45678" ;;
  start|stop|rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/podman"
  run "$ISOPOD_ROOT/isopod" shell demo
  assert_success
  assert_stub_called "podman start isopod-demo"
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

# ---- create rollback ---------------------------------------------------------
@test "a failed create rolls back the partial sandbox" {
  # Engine stub that builds fine but fails when starting the container, so the
  # box dir + keys already exist on disk when create dies. The EXIT trap must
  # then remove them and attempt to delete the container.
  cat > "$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
cmd="$1"; shift || true
case "$cmd" in
  info)  exit 0 ;;
  image) exit 1 ;;                       # image missing -> triggers build
  build) exit 0 ;;
  run)   echo "boom: cannot start container" >&2; exit 1 ;;
  rm)    exit 0 ;;
  *)     exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/podman"

  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_failure
  assert_output --partial "rolling back"
  # nothing left behind on disk
  [ ! -d "$ISOPOD_CONFIG_DIR/boxes/demo" ]
  # container cleanup was attempted
  assert_stub_called "podman rm -f isopod-demo"
  # and the box never made it into the managed ssh config
  if [ -f "$ISOPOD_CONFIG_DIR/ssh_config" ]; then
    run cat "$ISOPOD_CONFIG_DIR/ssh_config"
    refute_output --partial "Host isopod-demo"
  fi
}

# ---- --dockerfile context hashing (§4.1 stale-image fix) ---------------------
@test "create --dockerfile tag reflects the build context, not just the Dockerfile" {
  mkdir -p "$TEST_TMP/proj"
  printf 'FROM debian:bookworm-slim\nCOPY data.txt /data.txt\n' > "$TEST_TMP/proj/Dockerfile"
  echo one > "$TEST_TMP/proj/data.txt"
  run "$ISOPOD_ROOT/isopod" create demo --dockerfile "$TEST_TMP/proj/Dockerfile"
  assert_success
  local tag1; tag1=$(grep -oE 'localhost/isopod-user:[0-9a-f]+' "$STUB_LOG" | head -1)
  # Change a COPY'd context file WITHOUT touching the Dockerfile.
  echo two > "$TEST_TMP/proj/data.txt"
  : > "$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" create demo2 --dockerfile "$TEST_TMP/proj/Dockerfile"
  assert_success
  local tag2; tag2=$(grep -oE 'localhost/isopod-user:[0-9a-f]+' "$STUB_LOG" | head -1)
  [ -n "$tag1" ] && [ -n "$tag2" ]
  [ "$tag1" != "$tag2" ] # context change busts the cache tag (no stale reuse)
}

# ---- no-new-privileges for --no-sudo boxes (§4.7) ----------------------------
@test "create --no-sudo hardens the box with no-new-privileges" {
  run "$ISOPOD_ROOT/isopod" create demo --no-sudo --color teal
  assert_success
  assert_stub_called 'podman run .*--security-opt no-new-privileges'
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "sudo=0"
}

@test "a default (sudo) box does not get no-new-privileges" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_not_called 'no-new-privileges'
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "sudo=1"
}

# ---- --memory / --cpus validation (§5) ---------------------------------------
@test "create rejects a malformed --memory" {
  run "$ISOPOD_ROOT/isopod" create demo --memory 2gigs --color teal
  assert_failure
  assert_output --partial "invalid --memory"
}

@test "create rejects a non-numeric --cpus" {
  run "$ISOPOD_ROOT/isopod" create demo --cpus two --color teal
  assert_failure
  assert_output --partial "invalid --cpus"
}

# ---- gc (§4.10) --------------------------------------------------------------
@test "gc removes unreferenced isopod images and keeps referenced ones" {
  # A box that still references one snapshot image and one user base image.
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/keep"
  printf 'engine=podman\nimage=localhost/isopod-box-keep:r1\nbase=localhost/isopod-user:aaa\n' \
    > "$ISOPOD_CONFIG_DIR/boxes/keep/meta"
  cat > "$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
case "$1" in
  info) exit 0 ;;
  images)
    printf '%s\n' \
      localhost/isopod-box-keep:r1 \
      localhost/isopod-user:aaa \
      localhost/isopod-base:orphan \
      localhost/isopod-user:orphan2 \
      docker.io/library/debian:bookworm-slim
    ;;
  rmi) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/podman"
  run "$ISOPOD_ROOT/isopod" gc --force
  assert_success
  assert_stub_called 'podman rmi localhost/isopod-base:orphan'
  assert_stub_called 'podman rmi localhost/isopod-user:orphan2'
  assert_stub_not_called 'podman rmi localhost/isopod-box-keep:r1'
  assert_stub_not_called 'podman rmi localhost/isopod-user:aaa'
  assert_stub_not_called 'podman rmi docker.io/library/debian'
}

@test "gc --dry-run lists but removes nothing" {
  cat > "$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
case "$1" in
  info) exit 0 ;;
  images) printf '%s\n' localhost/isopod-base:orphan ;;
  rmi) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/podman"
  run "$ISOPOD_ROOT/isopod" gc --dry-run
  assert_success
  assert_output --partial "localhost/isopod-base:orphan"
  assert_stub_not_called 'podman rmi'
}

# ---- secrets ------------------------------------------------------------------

# Seed a secret in the hermetic file store (the test HOME's config dir).
seed_secret() { # seed_secret <name> <value>
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  chmod 700 "$ISOPOD_CONFIG_DIR/secrets"
  printf '%s' "$2" >"$ISOPOD_CONFIG_DIR/secrets/$1"
  printf '%s\n' "$1" >>"$ISOPOD_CONFIG_DIR/secrets/index"
  : >"$ISOPOD_CONFIG_DIR/secrets/.plaintext-warned"
}

@test "create --secret mounts the secrets tmpfs and streams the value over ssh only" {
  seed_secret API_KEY 's3kr1tv4lu3'
  run "$ISOPOD_ROOT/isopod" create demo --color teal --secret API_KEY
  assert_success
  # tmpfs mount on the engine command line (ownership is applied by the
  # entrypoint at boot; uid=/gid= mount options are not portable)
  assert_stub_called 'podman run .*--tmpfs /run/secrets:rw,noexec,nosuid,nodev,size=1m,mode=0700'
  # injection happens over SSH stdin into the tmpfs path (path base64-armored)
  assert_secret_injected /run/secrets/API_KEY
  # the VALUE never reaches any stubbed command's argv (engine, ssh, ...)
  assert_stub_not_called 's3kr1tv4lu3'
  # name:path pairs persist in meta for start/reconfigure re-injection
  run grep '^secrets=API_KEY:/run/secrets/API_KEY$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

@test "create --secret dies early when the secret is not stored" {
  export ISOPOD_SECRET_BACKEND=file
  run "$ISOPOD_ROOT/isopod" create demo --secret NOPE
  assert_failure
  assert_output --partial "isopod secret set NOPE"
  # validation failed before any engine work — and no half-made box remains
  assert_stub_not_called 'podman run'
  [ ! -d "$ISOPOD_CONFIG_DIR/boxes/demo" ]
}

@test "create --secret rejects a target inside the workspace" {
  seed_secret API_KEY x
  run "$ISOPOD_ROOT/isopod" create demo --secret API_KEY:/home/dev/workspace/key
  assert_failure
  assert_output --partial "isopod export"
}

@test "start re-injects secrets into the fresh tmpfs" {
  seed_secret API_KEY 's3kr1tv4lu3'
  "$ISOPOD_ROOT/isopod" create demo --color teal --secret API_KEY
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" start demo
  assert_success
  assert_secret_injected /run/secrets/API_KEY
  assert_stub_not_called 's3kr1tv4lu3'
}

@test "start of a box without secrets does not wait on ssh" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" start demo
  assert_success
  # no injection and no wait_for_ssh probe — only engine + keyscan traffic
  assert_stub_not_called '^ssh '
}

@test "reconfigure recreates the tmpfs and re-injects secrets" {
  seed_secret API_KEY 's3kr1tv4lu3'
  "$ISOPOD_ROOT/isopod" create demo --color teal --secret API_KEY
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" reconfigure demo
  assert_success
  assert_stub_called 'podman run .*--tmpfs /run/secrets:'
  assert_secret_injected /run/secrets/API_KEY
  assert_stub_not_called 's3kr1tv4lu3'
}

@test "secret set/ls/rm round-trip via the CLI (file backend)" {
  export ISOPOD_SECRET_BACKEND=file
  run bash -c "printf hunter2 | '$ISOPOD_ROOT/isopod' secret set MY_TOKEN"
  assert_success
  run "$ISOPOD_ROOT/isopod" secret ls
  assert_output --partial "MY_TOKEN"
  run "$ISOPOD_ROOT/isopod" secret rm MY_TOKEN
  assert_success
  run "$ISOPOD_ROOT/isopod" secret ls
  refute_output --partial "MY_TOKEN"
}

@test "secret set refuses a value on argv-less empty stdin" {
  export ISOPOD_SECRET_BACKEND=file
  run bash -c "printf '' | '$ISOPOD_ROOT/isopod' secret set MY_TOKEN"
  assert_failure
  assert_output --partial "empty value"
}
