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
  build)   # Log the staged build-context contents (last arg = context dir) so
           # tests can assert every COPY source the Dockerfile needs is present.
           for f in "${@: -1}"/*; do echo "build-ctx ${f##*/}" >> "$STUB_LOG"; done
           exit 0 ;;
  run)     echo "deadbeefcontainerid"; exit 0 ;;
  port)    echo "127.0.0.1:45678" ;;        # maps 2222/tcp -> host 45678
  exec)    exit 0 ;;
  cp)      exit 0 ;;
  inspect) echo "running" ;;                # state status
  commit)  exit 0 ;;                        # snapshot for reconfigure
  rmi)     exit 0 ;;                         # drop old snapshot
  start|stop) exit 0 ;;
  rm)      exit 0 ;;
  network) # Report only the offline network as missing, so --offline exercises
           # its create path. Every other network call keeps the old behaviour
           # (present), which is what the egress tests expect.
           # STUB_OFFLINE_NET: unset = missing (the create path). 'stale' = an
           # older network (no route, resolver on). 'current' = already correct.
           # A create records the network in a marker file, so a later exists /
           # inspect reflects it the way a real engine would. STUB_ROUTE_IGNORED
           # stands in for an engine that takes --route and drops it.
           case "$1" in
             exists)  [ "$2" = isopod-offline ] && [ -z "${STUB_OFFLINE_NET:-}" ] &&
                        [ ! -f "$STUB_LOG.offnet" ] && exit 1
                      exit 0 ;;
             inspect) if [ "$2" = isopod-offline ]; then
                        if [ -f "$STUB_LOG.offnet" ]; then
                          if [ -n "${STUB_ROUTE_IGNORED:-}" ]; then
                            echo '[{"dns_enabled": false}]'
                          else
                            echo '[{"dns_enabled": false, "routes": [{"destination": "0.0.0.0/0"}]}]'
                          fi
                          exit 0
                        fi
                        [ -z "${STUB_OFFLINE_NET:-}" ] && exit 1
                        if [ "${STUB_OFFLINE_NET:-}" = stale ]; then
                          echo '[{"dns_enabled": true}]'
                        else
                          echo '[{"dns_enabled": false, "routes": [{"destination": "0.0.0.0/0"}]}]'
                        fi
                      fi
                      exit 0 ;;
             # A box still attached makes the engine refuse the removal.
             rm)      [ -n "${STUB_NET_RM_FAIL:-}" ] && exit 1
                      rm -f "$STUB_LOG.offnet"; exit 0 ;;
             # `network create --help` probes for --route. Advertise it like
             # podman 5; STUB_NO_ROUTE hides it to stand in for docker/podman 4.
             create) case "$2" in
                       --help) [ -n "${STUB_NO_ROUTE:-}" ] ||
                                 echo '      --route stringArray  static routes'
                               exit 0 ;;
                     esac
                     touch "$STUB_LOG.offnet"
                     exit 0 ;;
             *)      exit 0 ;;
           esac ;;
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
# Bound the drain: under bats stdin is neither a tty nor closed, so a plain
# `cat` waits for an EOF that never arrives and the suite hangs. `timeout` is
# coreutils, absent on stock macOS, so fall back to the unbounded drain there.
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 cat >/dev/null 2>&1 || true
  else
    cat >/dev/null 2>&1 || true
  fi
fi
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

@test "create refuses --offline with --repo (nothing to clone over)" {
  run "$ISOPOD_ROOT/isopod" create demo --offline --repo https://x/y
  assert_failure
  assert_output --partial "has nothing to clone from"
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

# ---- offline boxes -----------------------------------------------------------
@test "create --offline runs the box on an internal network, still published on loopback" {
  run "$ISOPOD_ROOT/isopod" create demo --offline --color teal
  assert_success
  assert_stub_called 'podman network create --internal --subnet 10\.201\.0\.0/24 --gateway 10\.201\.0\.1'
  # passt follows the default route to find the guest; the engine still drops
  # anything the bridge tries to forward outward.
  assert_stub_called 'podman network create .*--route 0\.0\.0\.0/0,10\.201\.0\.1'
  # An offline box resolves no names, so the engine's resolver stays off rather
  # than the boundary resting on it declining to forward queries onward.
  assert_stub_called 'podman network create .*--disable-dns'
  assert_stub_called 'podman run .*--network isopod-offline'
  # --network none would leave the box with only loopback, so the published SSH
  # port would have nothing to forward to and isopod could never reach the box.
  assert_stub_not_called 'podman run .*--network none'
  assert_stub_called 'podman run .*127\.0\.0\.1::2222'
  assert_stub_called 'podman run .*--cap-drop NET_RAW'
  run grep '^offline=1$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
  # Guest egress filters the route out, and an offline box has none.
  run grep '^guest_egress=off$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

# Found on a real krun host: the box booted, sshd listened, and nothing could
# reach it, because passt follows the default route to pick its template
# interface and an internal network installs none on its own.
@test "create --offline is refused on a microVM runtime the engine cannot route" {
  export STUB_NO_ROUTE=1
  run "$ISOPOD_ROOT/isopod" create demo --offline --runtime krun
  assert_failure
  assert_output --partial "needs a plain container"
  assert_output --partial "--container"
}

@test "create --offline is allowed on a microVM runtime once the engine can route" {
  run "$ISOPOD_ROOT/isopod" create demo --offline --runtime krun
  assert_success
  assert_stub_called 'podman network create .*--route 0\.0\.0\.0/0,10\.201\.0\.1'
  assert_stub_called 'podman run .*--network isopod-offline'
}

@test "create --offline says so in the summary" {
  run "$ISOPOD_ROOT/isopod" create demo --offline
  assert_success
  assert_output --partial "OFFLINE"
}

# ---- offline network migration ----------------------------------------------
# An older network (no default route, resolver on) is replaced with one that has
# both, so an existing install picks up the fix without being told to.
@test "create --offline recreates an offline network that predates this version" {
  export STUB_OFFLINE_NET=stale
  run "$ISOPOD_ROOT/isopod" create demo --offline
  assert_success
  assert_stub_called 'podman network rm isopod-offline'
  assert_stub_called 'podman network create .*--route 0\.0\.0\.0/0,10\.201\.0\.1'
}

@test "create --offline leaves an already-current offline network alone" {
  export STUB_OFFLINE_NET=current
  run "$ISOPOD_ROOT/isopod" create demo --offline
  assert_success
  assert_stub_not_called 'podman network rm isopod-offline'
  # `network create --help` is the --route probe, not a creation.
  assert_stub_not_called 'podman network create --internal'
}

# Boxes still on the network block the removal, and an engine keeps a stopped box
# attached, so stopping them would not help. A plain container does not need the
# newer network, so the create must still succeed.
@test "create --offline --container keeps going when the old network cannot be replaced" {
  export STUB_OFFLINE_NET=stale STUB_NET_RM_FAIL=1
  run "$ISOPOD_ROOT/isopod" create demo --offline --container
  assert_success
  assert_output --partial "boxes are still on it"
  assert_stub_called 'podman run .*--network isopod-offline'
}

# A microVM box is unreachable without the route, so the same situation has to
# fail instead, naming the way out.
@test "create --offline on a microVM fails when the old network cannot be replaced" {
  export STUB_OFFLINE_NET=stale STUB_NET_RM_FAIL=1
  run "$ISOPOD_ROOT/isopod" create demo --offline --runtime krun
  assert_failure
  assert_output --partial "isopod rm"
  assert_output --partial "--container"
}

# An engine can accept --route and drop it, which used to surface only as a box
# that boots with sshd running and nothing able to reach it.
@test "create --offline fails when the engine takes --route but drops it" {
  export STUB_ROUTE_IGNORED=1
  run "$ISOPOD_ROOT/isopod" create demo --offline --runtime krun
  assert_failure
  assert_output --partial "no default route"
  assert_output --partial "netavark 1.7"
  assert_output --partial "--container"
}

# The same network is fine for a plain container, which needs no route.
@test "create --offline --container ignores a network with no default route" {
  export STUB_ROUTE_IGNORED=1
  run "$ISOPOD_ROOT/isopod" create demo --offline --container
  assert_success
  assert_stub_called 'podman run .*--network isopod-offline'
}

# A docker stub reporting the offline network as missing, so --offline exercises
# its create path there too.
offline_docker_stub() {
  cat > "$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
cmd="$1"; shift || true
case "$cmd" in
  info)    exit 0 ;;
  image)   exit 1 ;;
  build)   exit 0 ;;
  run)     echo "deadbeefcontainerid"; exit 0 ;;
  port)    echo "127.0.0.1:45678" ;;
  inspect) echo "running" ;;
  network) case "$1" in
             inspect) [ "$2" = isopod-offline ] && exit 1; exit 0 ;;
             *)       exit 0 ;;
           esac ;;
  start|stop|rm|rmi|commit) exit 0 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/docker"
}

# docker has neither --disable-dns nor --route, so the offline network is created
# with the flags it does have.
@test "create --offline on docker uses only the flags docker has" {
  offline_docker_stub
  run "$ISOPOD_ROOT/isopod" create demo --offline --engine docker
  assert_success
  assert_stub_called 'docker network create --internal --subnet 10\.201\.0\.0/24 --gateway 10\.201\.0\.1 isopod-offline'
  assert_stub_not_called 'docker network create .*--disable-dns'
  assert_stub_not_called 'docker network create .*--route'
  assert_stub_called 'docker run .*--network isopod-offline'
}

@test "create --offline is refused under a microVM runtime on docker" {
  offline_docker_stub
  run "$ISOPOD_ROOT/isopod" create demo --offline --runtime krun --engine docker
  assert_failure
  assert_output --partial "needs a plain container on docker"
}

@test "a normal box is not put on the offline network" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_not_called 'podman run .*--network isopod-offline'
  assert_stub_not_called 'podman network create --internal'
}

@test "create states the isolation tier the box actually got" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_output --partial "Isolation:"
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

@test "create keeps the host masks on a Tier 3 microVM box" {
  # Regression: isopod used to skip ALL masks under a microVM, assuming the guest
  # kernel left no host data to hide. But crun's krun handler exports the
  # CONTAINER rootfs to the guest over virtio-fs, and podman mounted the host's
  # procfs and sysfs into that rootfs — so the guest reaches the host's boot
  # identity AND its hardware identity through the export. Both sets must survive.
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*mask=.*/proc/cmdline'
  assert_stub_called 'podman run .*mask=.*/proc/config.gz'
  assert_stub_called 'podman run .*mask=.*/sys/class/dmi'
  assert_stub_called 'podman run .*mask=.*/sys/block'
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
  # Match the tail, not an absolute prefix: on a system where /home is a symlink,
  # isopod resolves its own root differently from the test's ISOPOD_ROOT and the
  # two spellings of the same path disagree. What matters is that share/Dockerfile
  # is the file being built.
  assert_stub_called "podman build .*-f .*/share/Dockerfile"
}

@test "create stages every share/Dockerfile COPY source into the build context" {
  # Regression: adding a COPY to share/Dockerfile without staging its source in
  # build_image fails only at build time ("copier: stat ... no such file").
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  while read -r src; do
    assert_stub_called "build-ctx $src"
  done < <(awk '$1 == "COPY" { print $2 }' "$ISOPOD_ROOT/share/Dockerfile")
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
  # --container pins a non-microVM box: without it a host that CAN run a microVM
  # (macOS CI) gets guest-egress and reports the in-box posture instead of OPEN.
  run "$ISOPOD_ROOT/isopod" create demo --container --color teal
  assert_success
  assert_output --partial "Network: OPEN"
  assert_output --partial "could NOT be enforced"
  assert_output --partial "sudo isopod egress apply"
}

# The stubbed podman is rootless, so default-on egress degrades to an OPEN network
# for an ordinary box. An offline box has no route out at all, so saying that about
# it contradicts the OFFLINE posture the same run reports a few lines later.
@test "create --offline does not warn about an OPEN network" {
  run "$ISOPOD_ROOT/isopod" create demo --offline --container
  assert_success
  assert_output --partial "Network: OFFLINE"
  refute_output --partial "with an OPEN network"
  refute_output --partial "cannot enforce it"
}

# create resolved egress before --offline was handled, so boxes already on disk
# carry egress_degraded=1. doctor and list have to read past that, or the same box
# reads OFFLINE from info and OPEN from the other two.
@test "doctor does not report an offline box as an open network" {
  "$ISOPOD_ROOT/isopod" create demo --offline --container
  printf 'egress_degraded=1\n' >>"$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" doctor
  assert_success
  refute_output --partial "demo: egress isolation was requested but is NOT in force"
}

@test "list does not flag an offline box as egress OPEN" {
  "$ISOPOD_ROOT/isopod" create demo --offline --container
  printf 'egress_degraded=1\n' >>"$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" list
  assert_success
  refute_output --partial "egress OPEN"
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
  assert_output --partial "Docker (runc) cannot mask"
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

@test "create --dockerfile names the build context it uses" {
  # The context is the Dockerfile's own directory, not the working directory,
  # so it is stated up front rather than left for a COPY to reveal.
  mkdir -p "$TEST_TMP/proj-ctx"
  printf 'FROM debian:bookworm-slim\nRUN true\n' > "$TEST_TMP/proj-ctx/Dockerfile"
  run "$ISOPOD_ROOT/isopod" create demo --dockerfile "$TEST_TMP/proj-ctx/Dockerfile"
  assert_success
  assert_output --partial "context: $TEST_TMP/proj-ctx"
}

@test "create --dockerfile reports a failed user build once, not twice" {
  printf 'FROM debian:bookworm-slim\nRUN false\n' > "$TEST_TMP/Dockerfile"
  # Fail every engine build; the user Dockerfile is the first one issued.
  cat > "$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
case "$1" in
  info)  cat <<'INFO'
host:
  ociRuntimes:
    crun: [/usr/bin/crun]
INFO
         exit 0 ;;
  image) exit 1 ;;
  build) exit 1 ;;
  *)     exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/podman"
  run "$ISOPOD_ROOT/isopod" create demo --dockerfile "$TEST_TMP/Dockerfile"
  assert_failure
  # build_user_image's message names the Dockerfile; the caller must not add a
  # second, vaguer one after it (it runs in a command substitution, so its die
  # exits only that subshell).
  assert_output --partial "build of $TEST_TMP/Dockerfile failed"
  refute_output --partial "could not build --dockerfile image"
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

# Found on a real host: reconfigure of an offline box stopped working when
# resolve_egress learned to return early for offline boxes, because the rebuild
# paths take their egress mode from it. With the mode left on, preflight tried to
# enforce something a rootless engine cannot and the rebuild died.
@test "reconfigure keeps an offline box offline and does not fail preflight" {
  "$ISOPOD_ROOT/isopod" create demo --offline --container
  run "$ISOPOD_ROOT/isopod" reconfigure demo --memory 3g
  assert_success
  assert_stub_called 'podman run .*--network isopod-offline'
  assert_stub_called "podman run .*--memory 3g"
  run grep '^offline=1$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

# The override warning means "you configured a mode and --offline replaced it".
# It must not fire when nothing was configured.
@test "create --offline does not claim to override an egress mode nobody set" {
  run "$ISOPOD_ROOT/isopod" create demo --offline --container
  assert_success
  refute_output --partial "overrides the configured egress mode"
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
  # Pin the initial branch: the assertions below reference refs/.../master, but
  # a host with init.defaultBranch=main would otherwise create 'main'.
  git init -q -b master "$box"
  git -C "$box" config user.email dev@mybox.local; git -C "$box" config user.name dev
  echo a > "$box/a"; git -C "$box" add a
  # the body contains a line that LOOKS like an author header — the rewriter
  # must leave it byte-for-byte intact (only the real identity may change).
  printf 'box: work 1\n\nauthor Faker <dev@mybox.local> 0 +0000\n' | git -C "$box" commit -qF -
  git -C "$box" -c user.email=mate@corp -c user.name=Mate commit -q --allow-empty -m "mate: review"
  git init -q -b master "$host"
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
  # Always-subfolder: a single repo lands in $WORKSPACE/<name>, not at the root.
  assert_stub_called "ssh .*git clone https://example.com/r.git .*/workspace/r"
}

@test "create with multiple --repo clones each into its own subfolder" {
  run "$ISOPOD_ROOT/isopod" create demo \
    --repo https://example.com/api.git --repo https://example.com/web.git --color blue
  assert_success
  assert_stub_called "ssh .*git clone https://example.com/api.git .*/workspace/api"
  assert_stub_called "ssh .*git clone https://example.com/web.git .*/workspace/web"
}

@test "create refuses two --repo values that map to the same folder" {
  run "$ISOPOD_ROOT/isopod" create demo \
    --repo https://example.com/api.git --repo git@other:api.git --color blue
  assert_failure
  assert_output --partial "same folder 'api'"
}

@test "create refuses to overwrite an existing box" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_failure
  assert_output --partial "already exists"
}

@test "create defaults to NO in-box sudo" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_SUDO=0"
  assert_stub_not_called "ISOPOD_SUDO=1"
}

# --no-sudo is retained as an accepted no-op so scripts written against the old
# default keep working; it must still produce a no-sudo box, not an error.
@test "create --no-sudo is accepted and is a no-op against the new default" {
  run "$ISOPOD_ROOT/isopod" create demo --no-sudo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_SUDO=0"
  assert_stub_not_called "ISOPOD_SUDO=1"
}

@test "create --sudo opts back in to passwordless sudo" {
  run "$ISOPOD_ROOT/isopod" create demo --sudo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_SUDO=1"
  assert_stub_not_called "ISOPOD_SUDO=0"
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "sudo=1"
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

@test "code opens a new window so a running IDE cannot reuse another box's window" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  cat > "$STUB_DIR/codium" <<'EOF'
#!/usr/bin/env bash
echo "codium $*" >> "$STUB_LOG"
exit 0
EOF
  chmod +x "$STUB_DIR/codium"
  run "$ISOPOD_ROOT/isopod" code demo
  assert_success
  assert_stub_called "codium --new-window --folder-uri vscode-remote://ssh-remote\+isopod-demo"
}

@test "code --reuse-window drops --new-window" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  cat > "$STUB_DIR/codium" <<'EOF'
#!/usr/bin/env bash
echo "codium $*" >> "$STUB_LOG"
exit 0
EOF
  chmod +x "$STUB_DIR/codium"
  run "$ISOPOD_ROOT/isopod" code demo --reuse-window
  assert_success
  assert_stub_not_called "codium --new-window"
  assert_stub_called "codium --folder-uri vscode-remote://ssh-remote\+isopod-demo"
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

# ---- no-new-privileges for no-sudo boxes (§4.7) ------------------------------
@test "a default box hardens with no-new-privileges" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called 'podman run .*--security-opt no-new-privileges'
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "sudo=0"
}

# The flag exists to preserve setuid escalation, so it must be dropped exactly
# when sudo is granted — otherwise `sudo` itself (setuid) cannot run.
@test "a --sudo box does not get no-new-privileges" {
  run "$ISOPOD_ROOT/isopod" create demo --sudo --color teal
  assert_success
  assert_stub_not_called 'no-new-privileges'
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "sudo=1"
}

# ---- kernel hardening profile (--harden) -------------------------------------
@test "create records the default hardening profile in meta" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "harden=default"
}

@test "create --harden off records it in meta and passes no hardening env" {
  run "$ISOPOD_ROOT/isopod" create demo --harden off --color teal
  assert_success
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "harden=off"
  assert_stub_not_called "ISOPOD_HARDEN"
}

@test "create rejects an invalid --harden level" {
  run "$ISOPOD_ROOT/isopod" create demo --harden bogus --color teal
  assert_failure
  assert_output --partial "invalid --harden"
}

@test "create rejects --harden strict as reserved" {
  run "$ISOPOD_ROOT/isopod" create demo --harden strict --color teal
  assert_failure
  assert_output --partial "not yet available"
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

@test "create --disk passes the volume to the box without any host mount" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal --disk 20g
  assert_success
  assert_stub_called 'podman run .*ISOPOD_DISK=20g:/mnt/data'
  # box-local storage: create must never reach for a host bind mount or volume
  assert_stub_not_called 'podman run .*--volume'
  assert_stub_not_called 'podman run .*--mount'
  run grep '^disk=20g:/mnt/data$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

@test "create --disk honors an explicit mountpoint" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal --disk 4g:/srv/cache
  assert_success
  assert_stub_called 'podman run .*ISOPOD_DISK=4g:/srv/cache'
}

@test "create --disk is refused on a plain container box (no loop devices)" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --container --disk 20g
  assert_failure
  assert_output --partial "--disk needs a microVM box"
  # refused before any engine work — and no half-made box remains
  assert_stub_not_called 'podman run'
  [ ! -d "$ISOPOD_CONFIG_DIR/boxes/demo" ]
}

@test "create --disk rejects a bad spec before touching the engine" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --disk 20gb
  assert_failure
  assert_output --partial "invalid --disk size"
  assert_stub_not_called 'podman run'
  [ ! -d "$ISOPOD_CONFIG_DIR/boxes/demo" ]
}

@test "create --nested-containers implies a disk at podman's graph root" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal --nested-containers
  assert_success
  assert_stub_called 'podman run .*ISOPOD_DISK=20g:/home/dev/.local/share/containers'
  assert_stub_called 'podman run .*ISOPOD_NESTED=1'
  # the nested toolchain is a distinct image build
  assert_stub_called 'podman build .*ISOPOD_NESTED=1'
  run grep '^nested=1$' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_success
}

@test "create --nested-containers takes a --disk size but not a mountpoint" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal \
    --nested-containers --disk 40g
  assert_success
  assert_stub_called 'podman run .*ISOPOD_DISK=40g:/home/dev/.local/share/containers'

  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo2 \
    --nested-containers --disk 40g:/mnt/data
  assert_failure
  assert_output --partial "sets the --disk mountpoint itself"
}

@test "a plain box gets neither the disk nor the nested env" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_not_called 'podman run .*ISOPOD_DISK'
  assert_stub_not_called 'podman run .*ISOPOD_NESTED'
  assert_stub_called 'podman build .*ISOPOD_NESTED=0'
}

@test "reconfigure refuses a --disk box rather than snapshot the volume" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal --disk 20g
  assert_success
  run "$ISOPOD_ROOT/isopod" reconfigure demo --memory 4g
  assert_failure
  assert_output --partial "not supported on a box with a --disk data volume"
  # the box must be left alone — no snapshot, no recreate
  assert_stub_not_called 'podman commit'
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

@test "start warns when an egress box's firewall protection is gone" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  # Mark the box as created under egress (create degrades to '' on the rootless
  # stub). The rootless engine cannot enforce it, so start must flag it as OPEN
  # rather than start it silently unprotected.
  sed_i 's/^egress=.*/egress=lan-deny/' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" start demo
  assert_success
  assert_output --partial "OPEN network"
}

@test "start fails closed when the box's SSH host key changed" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  # Simulate a taken-over loopback port: the pinned key no longer matches the one
  # ssh-keyscan now reports (the stub always reports AAAAfakehostkey).
  printf '[127.0.0.1]:45678 ssh-ed25519 AAAAdifferenthostkey\n' >"$ISOPOD_CONFIG_DIR/boxes/demo/known_hosts"
  run "$ISOPOD_ROOT/isopod" start demo
  assert_failure
  assert_output --partial "host key for box 'demo' CHANGED"
  assert_output --partial "Refusing to connect"
}

@test "start adopts a changed host key only with ISOPOD_ACCEPT_NEW_HOSTKEY=1" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  printf '[127.0.0.1]:45678 ssh-ed25519 AAAAdifferenthostkey\n' >"$ISOPOD_CONFIG_DIR/boxes/demo/known_hosts"
  ISOPOD_ACCEPT_NEW_HOSTKEY=1 run "$ISOPOD_ROOT/isopod" start demo
  assert_success
  assert_output --partial "adopting it"
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

# ---- machine-readable output (--json) ----------------------------------------
# The field names and shapes are a published contract consumed by external
# tooling (the Podman Desktop dashboard extension). Each test parses the output
# with python3 -m json.tool, so anything that is not a valid JSON document fails.

@test "list --json emits a valid JSON array with the contract fields" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run bash -c "'$ISOPOD_ROOT/isopod' list --json 2>/dev/null | python3 -m json.tool"
  assert_success
  assert_output --partial '"name": "demo"'
  assert_output --partial '"status": "running"'
  assert_output --partial '"ssh_host": "isopod-demo"'
  assert_output --partial '"port": 45678'
  assert_output --partial '"color": "#0f766e"'
  assert_output --partial '"engine": "podman"'
}

@test "list --json prints only the JSON document on stdout" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run bash -c "'$ISOPOD_ROOT/isopod' list --json 2>/dev/null"
  assert_success
  assert_output --regexp '^\['
  refute_output --partial 'NAME'
}

@test "list --json with no boxes is an empty array" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run bash -c "'$ISOPOD_ROOT/isopod' list --json 2>/dev/null | python3 -m json.tool"
  assert_success
  assert_output '[]'
}

@test "list --json escapes quotes, backslashes, and control characters" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  # Hand-written meta: create validates colors, but list must survive (and
  # correctly escape) whatever is on disk. The value has a quote, a backslash,
  # and a tab; the box name itself carries a quote.
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/we\"ird"
  printf 'engine=podman\nport=4222\ncolor=te"al\\pain\tted\n' \
    >"$ISOPOD_CONFIG_DIR/boxes/we\"ird/meta"
  run bash -c "'$ISOPOD_ROOT/isopod' list --json 2>/dev/null | python3 -m json.tool"
  assert_success
  assert_output --partial '"name": "we\"ird"'
  assert_output --partial '"color": "te\"al\\pain\tted"'
}

@test "info --json emits the contract object with forwards and secrets arrays" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  "$ISOPOD_ROOT/isopod" create demo --color teal --expose 3001:3000 --expose 8080
  # Secret NAMES only must appear — never paths or values. Replace the meta
  # line create wrote (meta_get reads the first match, so appending is ignored).
  sed_i 's|^secrets=.*|secrets=API_KEY:/run/secrets/API_KEY,TOKEN:/run/secrets/TOKEN|' \
    "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run bash -c "'$ISOPOD_ROOT/isopod' info demo --json 2>/dev/null | python3 -m json.tool"
  assert_success
  assert_output --partial '"name": "demo"'
  assert_output --partial '"port": 45678'
  assert_output --partial '"3001:3000"'
  assert_output --partial '"8080:8080"'
  assert_output --partial '"API_KEY"'
  assert_output --partial '"TOKEN"'
  refute_output --partial '/run/secrets'
  assert_output --partial '"workspace": "/home/dev/workspace"'
}

@test "info --json renders empty forwards and secrets as empty arrays" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run bash -c "'$ISOPOD_ROOT/isopod' info demo --json 2>/dev/null"
  assert_success
  assert_output --partial '"forwards":[]'
  assert_output --partial '"secrets":[]'
  refute_output --partial '(none'
}

@test "info without --json is unchanged by the json path" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" info demo
  assert_success
  assert_output --partial 'name      : demo'
  refute_output --partial '"name"'
}

# Confirming a box's isolation tier used to mean grepping its meta file: info
# reported the egress posture but never which boundary the box actually got.
@test "info reports the isolation tier a box was built with" {
  "$ISOPOD_ROOT/isopod" create demo --color teal --runtime krun
  run "$ISOPOD_ROOT/isopod" info demo
  assert_success
  assert_output --partial 'isolation : microVM (krun)'
}

@test "info reports a plain container as sharing the host kernel" {
  "$ISOPOD_ROOT/isopod" create demo --color teal --container
  run "$ISOPOD_ROOT/isopod" info demo
  assert_success
  assert_output --partial 'isolation : plain container'
}

# The tier follows the runtime RECORDED for the box, so a config change after the
# fact cannot make info claim a boundary this box never got.
@test "info reads the isolation tier from the box, not the active runtime" {
  "$ISOPOD_ROOT/isopod" create demo --color teal --container
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" info demo
  assert_success
  assert_output --partial 'isolation : plain container'
}

@test "egress status --json emits a valid JSON object with the contract fields" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run bash -c "'$ISOPOD_ROOT/isopod' egress status --json 2>/dev/null | python3 -m json.tool"
  assert_success
  assert_output --partial '"mode":'
  assert_output --partial '"firewall":'
  assert_output --partial '"network": "isopod0"'
  assert_output --partial '"subnet": "10.88.7.0/24"'
  assert_output --partial '"dns": "1.1.1.1"'
  assert_output --partial '"proxy":'
}

# ---- administrative root key (F-4) -------------------------------------------
# The box user has no sudo by default, so root is reached over SSH with a key
# that lives only on the host. Nothing inside the box can escalate to it: there
# is no password to capture and no setuid path to abuse.

@test "create generates a second, administrative root keypair" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  [ -f "$ISOPOD_CONFIG_DIR/boxes/demo/id_ed25519_root" ]
  [ -f "$ISOPOD_CONFIG_DIR/boxes/demo/id_ed25519_root.pub" ]
  assert_stub_called "ssh-keygen .*-C isopod-demo-root"
  # only the PUBLIC half reaches the box
  assert_stub_called "run .*ISOPOD_ROOT_AUTHORIZED_KEY=ssh-ed25519"
  assert_stub_not_called "run .*PRIVKEY"
}

# The managed ssh_config include must NOT gain a root entry: a root editor window
# opened on the workspace runs workspace-controlled code as root (tasks.json
# "runOn": folderOpen, extension activation) — a direct agent-to-root path.
@test "the managed ssh_config include gets no root entry" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  assert_output --partial "Host isopod-demo"
  refute_output --partial "isopod-demo-root"
  refute_output --partial "User root"
}

@test "create --no-root-key leaves the box with no root path at all" {
  run "$ISOPOD_ROOT/isopod" create demo --no-root-key --color teal
  assert_success
  assert_output --partial "NO root access path"
  [ ! -f "$ISOPOD_CONFIG_DIR/boxes/demo/id_ed25519_root" ]
  assert_stub_not_called "ISOPOD_ROOT_AUTHORIZED_KEY"
}

@test "root-shell runs a command as root over the host-held key" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" root-shell demo -- id
  assert_success
  assert_stub_called "ssh .*id_ed25519_root .*root@127\.0\.0\.1 id"
}

@test "root-shell fails on a box created with --no-root-key" {
  "$ISOPOD_ROOT/isopod" create demo --no-root-key --color teal
  run "$ISOPOD_ROOT/isopod" root-shell demo -- id
  assert_failure
  assert_output --partial "no administrative root key"
}

@test "root-shell --print-ssh-config emits a root entry and warns about it" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" root-shell demo --print-ssh-config
  assert_success
  assert_output --partial "Host isopod-demo-root"
  assert_output --partial "User root"
  assert_output --partial "id_ed25519_root"
  assert_output --partial "runs workspace-controlled code as root"
}

@test "root-shell --print-ssh-config refuses a box with no root key" {
  "$ISOPOD_ROOT/isopod" create demo --no-root-key --color teal
  run "$ISOPOD_ROOT/isopod" root-shell demo --print-ssh-config
  assert_failure
  assert_output --partial "no administrative root key"
}

# An interactive root shell lands in /root, never the workspace: the workspace is
# the one directory an agent fully controls, and a root shell sitting in it is one
# `make` or `npm install` away from running agent-authored code as root.
@test "an interactive root-shell lands in /root, not the workspace" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" root-shell demo
  assert_success
  assert_stub_called "ssh .*root@127\.0\.0\.1 cd /root; exec bash"
  assert_output --partial "This is a root shell"
}

# ---- guest egress isolation (F-3) --------------------------------------------
@test "a microVM box gets the in-guest egress ruleset by default" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "run .*ISOPOD_GUEST_EGRESS=1"
  assert_stub_called "run .*ISOPOD_GUEST_EGRESS_DNS="
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "guest_egress=on"
}

@test "create --guest-egress off records it and passes no ruleset env" {
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" create demo --guest-egress off --color teal
  assert_success
  assert_stub_not_called "ISOPOD_GUEST_EGRESS"
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "guest_egress=off"
}

@test "create rejects an invalid --guest-egress value" {
  run "$ISOPOD_ROOT/isopod" create demo --guest-egress maybe --color teal
  assert_failure
  assert_output --partial "invalid --guest-egress"
}

# The ruleset is a build input, so editing it must invalidate the image tag —
# otherwise a box would keep an old ruleset under a tag that claims to be current.
@test "the guest egress ruleset is staged into the build context" {
  run "$ISOPOD_ROOT/isopod" create demo --color teal
  assert_success
  assert_stub_called "build-ctx egress-guest.nft"
}

# ---- upgrade: in-place (F-2) -------------------------------------------------
@test "upgrade --in-place replaces all three isopod-owned files over the root key" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" upgrade demo --in-place
  assert_success
  assert_stub_called "ssh .*id_ed25519_root .*/usr/local/bin/isopod-entrypoint"
  assert_stub_called "ssh .*id_ed25519_root .*/etc/isopod/hardening-sysctl.conf"
  assert_stub_called "ssh .*id_ed25519_root .*/etc/isopod/egress-guest.nft"
}

# Said BEFORE the box is stopped: a restart kills every process inside it, and
# when one is a long-running agent session the symptom reads as a network fault.
@test "upgrade --in-place warns that the restart terminates everything running" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" upgrade demo --in-place
  assert_success
  assert_output --partial "TERMINATES everything running inside it"
}

# built_version records which isopod BUILT the image. An in-place refresh does not
# rebuild it, so bumping it made the staleness warning contradict itself
# ("built from an older isopod (3.1.0; this is 3.1.0)").
@test "upgrade --in-place leaves the box stale and does not bump built_version" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  sed_i 's/^built_version=.*/built_version=1.0.0/' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  sed_i 's|^base_image=.*|base_image=localhost/isopod-base:0000000000000000|' \
    "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" upgrade demo --in-place
  assert_success
  assert_output --partial "still reports stale"
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "built_version=1.0.0"
  assert_output --partial "base_image=localhost/isopod-base:0000000000000000"
}

# Run flags are fixed when a container is created, so an in-place refresh cannot
# apply them. Saying so is the difference between a known limit and a silent one.
@test "upgrade --in-place says which changes it cannot apply" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" upgrade demo --in-place
  assert_success
  assert_output --partial "--guest-egress"
  assert_output --partial "no-new-privileges"
}

@test "upgrade --in-place refuses a box with neither a root key nor sudo" {
  "$ISOPOD_ROOT/isopod" create demo --no-root-key --color teal
  run "$ISOPOD_ROOT/isopod" upgrade demo --in-place
  assert_failure
  assert_output --partial "neither an administrative root key nor sudo"
}

# ---- upgrade: rebase ---------------------------------------------------------
@test "upgrade rebases onto a freshly built image and keeps the box identity" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  local port
  port=$(grep '^port=' "$ISOPOD_CONFIG_DIR/boxes/demo/meta")
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" upgrade demo --yes
  assert_success
  assert_stub_called "podman build "
  assert_stub_called "podman rm -f isopod-demo"
  assert_stub_called "podman run -d --name isopod-demo"
  # identity survives: same key, same published port
  [ -f "$ISOPOD_CONFIG_DIR/boxes/demo/id_ed25519" ]
  run grep '^port=' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output "$port"
}

# A box built before guest-egress existed has no such meta key. A rebase must
# bring it to today's default (on), not rebuild it silently LAN-open.
@test "upgrade re-applies the default guest-egress to a box that predates it" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  grep -v '^guest_egress=' "$ISOPOD_CONFIG_DIR/boxes/demo/meta" >"$ISOPOD_CONFIG_DIR/boxes/demo/meta.tmp"
  mv "$ISOPOD_CONFIG_DIR/boxes/demo/meta.tmp" "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run grep '^guest_egress=' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_failure # the key is gone: this now looks like a pre-feature box
  run "$ISOPOD_ROOT/isopod" upgrade demo --yes
  assert_success
  run grep '^guest_egress=' "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output "guest_egress=on"
}

# The workspace is streamed to a host-side archive BEFORE anything is destroyed.
@test "upgrade copies the workspace out before replacing the container" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  : >"$STUB_LOG"
  run "$ISOPOD_ROOT/isopod" upgrade demo --yes
  assert_success
  local tarline rmline
  tarline=$(grep -n 'tar -C /home/dev/workspace' "$STUB_LOG" | head -1 | cut -d: -f1)
  rmline=$(grep -n 'podman rm -f isopod-demo' "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$tarline" ] && [ -n "$rmline" ] && [ "$tarline" -lt "$rmline" ]
}

# A --disk volume lives in the container layer a rebase replaces, so there is no
# safe way to carry it across — refuse rather than silently discard it.
@test "upgrade refuses to rebase a box with a --disk data volume" {
  ISOPOD_RUNTIME=krun "$ISOPOD_ROOT/isopod" create demo --color teal --disk 20g
  run "$ISOPOD_ROOT/isopod" upgrade demo --yes
  assert_failure
  assert_output --partial "--disk data volume"
}

@test "upgrade errors on a nonexistent box" {
  run "$ISOPOD_ROOT/isopod" upgrade ghost --yes
  assert_failure
  assert_output --partial "no such sandbox"
}

# ---- reconfigure --guest-egress ----------------------------------------------
@test "reconfigure --guest-egress off turns the ruleset off on an existing box" {
  ISOPOD_RUNTIME=krun "$ISOPOD_ROOT/isopod" create demo --color teal
  : >"$STUB_LOG"
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" reconfigure demo --guest-egress off
  assert_success
  assert_stub_not_called "run .*ISOPOD_GUEST_EGRESS"
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "guest_egress=off"
}

@test "reconfigure --guest-egress on turns it back on" {
  ISOPOD_RUNTIME=krun "$ISOPOD_ROOT/isopod" create demo --guest-egress off --color teal
  : >"$STUB_LOG"
  ISOPOD_RUNTIME=krun run "$ISOPOD_ROOT/isopod" reconfigure demo --guest-egress on
  assert_success
  assert_stub_called "run .*ISOPOD_GUEST_EGRESS=1"
  run cat "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  assert_output --partial "guest_egress=on"
}

# reconfigure recreates the box from a COMMIT of the current layer, which on a
# stale box has neither nft nor the ruleset. Enabling there would hit the
# entrypoint's fail-closed path and leave the box unreachable.
@test "reconfigure --guest-egress on is refused on a stale box" {
  ISOPOD_RUNTIME=krun "$ISOPOD_ROOT/isopod" create demo --guest-egress off --color teal
  sed_i 's|^base_image=.*|base_image=localhost/isopod-base:0000000000000000|' \
    "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" reconfigure demo --guest-egress on
  assert_failure
  assert_output --partial "isopod upgrade demo"
}

@test "reconfigure rejects an invalid --guest-egress value" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" reconfigure demo --guest-egress maybe
  assert_failure
  assert_output --partial "invalid --guest-egress"
}

# ---- staleness and posture surfaced in list / doctor -------------------------
@test "list flags a stale box in the NOTES column" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" list
  assert_success
  assert_output --partial "NOTES"
  refute_output --partial "stale"
  sed_i 's|^base_image=.*|base_image=localhost/isopod-base:0000000000000000|' \
    "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" list
  assert_success
  assert_output --partial "stale"
}

@test "list flags a box whose egress isolation is not in force" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  run "$ISOPOD_ROOT/isopod" list
  assert_success
  assert_output --partial "egress OPEN"
}

# Both conditions used to be reported once, at create, and then never again — a
# box set up months ago is exactly the one you would want told about.
@test "doctor lists boxes needing attention" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  sed_i 's|^base_image=.*|base_image=localhost/isopod-base:0000000000000000|' \
    "$ISOPOD_CONFIG_DIR/boxes/demo/meta"
  run "$ISOPOD_ROOT/isopod" doctor
  assert_success
  assert_output --partial "Boxes needing attention"
  assert_output --partial "demo: built from an older isopod"
  assert_output --partial "isopod upgrade demo"
}

@test "doctor says nothing about boxes that are current and enforced" {
  run "$ISOPOD_ROOT/isopod" doctor
  assert_success
  refute_output --partial "Boxes needing attention"
}

# ---- remap backend selection -------------------------------------------------
# A git-filter-repo on PATH is not proof it can run: it imports the
# git_filter_repo module, and a split install leaves the command present with the
# import broken. isopod ships a python3 rewrite that needs no extra tooling, so a
# broken install must fall through to it rather than fail the remap.
_stub_broken_filter_repo() {
  cat >"$STUB_DIR/git-filter-repo" <<'EOF'
#!/usr/bin/env bash
echo "ModuleNotFoundError: No module named 'git_filter_repo'" >&2
exit 1
EOF
  chmod +x "$STUB_DIR/git-filter-repo"
}

@test "remap falls back to python3 when git-filter-repo is installed but broken" {
  _seed_remapped_host "$TEST_TMP/host"
  _stub_broken_filter_repo
  run "$ISOPOD_ROOT/isopod" remap mybox "$TEST_TMP/host" --old-email dev@mybox.local --force
  assert_success
  refute_output --partial "git filter-repo failed"
  run git -C "$TEST_TMP/host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Me <me@home>"
}

# git-filter-repo starts fine but crashes partway on a commit its parser rejects.
# A box writes its own commit objects, and an empty author name ("author <e> ts")
# is one git accepts and filter-repo does not, which used to make remap unusable
# on any host that had filter-repo installed.
_stub_crashing_filter_repo() {
  cat >"$STUB_DIR/git-filter-repo" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --version "* | *" -h "*) exit 0 ;;   # usable: it starts
esac
echo "AttributeError: 'NoneType' object has no attribute 'groups'" >&2
exit 1
EOF
  chmod +x "$STUB_DIR/git-filter-repo"
}

@test "remap falls back to python3 when git-filter-repo crashes on the repo" {
  _seed_remapped_host "$TEST_TMP/host"
  _stub_crashing_filter_repo
  run "$ISOPOD_ROOT/isopod" remap mybox "$TEST_TMP/host" --old-email dev@mybox.local --force
  assert_success
  assert_output --partial "retrying with isopod's own rewrite"
  run git -C "$TEST_TMP/host" log --format='%an <%ae>' refs/remotes/mybox/master
  assert_output --partial "Me <me@home>"
}

@test "doctor does not report a broken git-filter-repo as the remap backend" {
  _stub_broken_filter_repo
  run "$ISOPOD_ROOT/isopod" doctor
  assert_success
  assert_output --partial "python3 (remap fallback backend)"
  refute_output --partial "git-filter-repo (remap backend)"
}

@test "doctor reports git-filter-repo when it actually runs" {
  make_stub git-filter-repo 0
  run "$ISOPOD_ROOT/isopod" doctor
  assert_success
  assert_output --partial "git-filter-repo (remap backend)"
}

# A failed install used to report only an exit code when the in-guest ruleset was
# the cause, because the hint checked host egress meta and nothing else.
@test "a failed install names guest egress as a possible cause" {
  "$ISOPOD_ROOT/isopod" create demo --color teal
  # Let the box look healthy and report apt-get, but fail the install itself —
  # the two are told apart by the script each `exec` is handed.
  cat >"$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
case "$1" in
  inspect) echo running; exit 0 ;;
  exec)
    for a in "$@"; do last="$a"; done
    case "$last" in
      *xargs*)        exit 100 ;;              # the package install
      *"command -v"*) printf 'apt-get'; exit 0 ;;  # package-manager probe
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_DIR/podman"
  run "$ISOPOD_ROOT/isopod" install demo cowsay
  assert_failure
  assert_output --partial "in-guest egress isolation"
  assert_output --partial "nft list ruleset"
  assert_output --partial "--guest-egress off"
}
