#!/usr/bin/env bats
# Unit tests for isopod's pure functions — no container engine needed.

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  isopod_setup_env
  load_isopod
}
teardown() { isopod_teardown_env; }

# ---- valid_name --------------------------------------------------------------
@test "valid_name accepts simple names" {
  run valid_name "myproj"
  assert_success
}
@test "valid_name accepts digits, dot, dash, underscore" {
  run valid_name "my-proj_2.0"
  assert_success
}
@test "valid_name rejects spaces" {
  run valid_name "bad name"
  assert_failure
}
@test "valid_name rejects leading dash" {
  run valid_name "-bad"
  assert_failure
}
@test "valid_name rejects shell metacharacters" {
  run valid_name 'pwn;rm'
  assert_failure
}
@test "valid_name rejects empty string" {
  run valid_name ""
  assert_failure
}
@test "valid_name rejects over-long names" {
  run valid_name "$(printf 'a%.0s' {1..60})"
  assert_failure
}

# ---- preset_color ------------------------------------------------------------
@test "preset_color maps teal to a hex" {
  run preset_color teal
  assert_success
  assert_output "#0f766e"
}
@test "preset_color accepts british grey spelling" {
  run preset_color grey
  assert_success
  assert_output "#374151"
}
@test "preset_color fails on unknown name" {
  run preset_color chartreuse
  assert_failure
}

# ---- image_tag_for -----------------------------------------------------------
@test "image_tag_for is deterministic for the same base" {
  a="$(image_tag_for debian:bookworm-slim)"
  b="$(image_tag_for debian:bookworm-slim)"
  assert_equal "$a" "$b"
}
@test "image_tag_for differs across base images" {
  a="$(image_tag_for debian:bookworm-slim)"
  b="$(image_tag_for ubuntu:24.04)"
  [ "$a" != "$b" ]
}
@test "image_tag_for uses the localhost/isopod-base prefix" {
  run image_tag_for debian:bookworm-slim
  assert_output --partial "localhost/isopod-base:"
}

# ---- ctr_name / box_dir ------------------------------------------------------
@test "ctr_name prefixes with isopod-" {
  run ctr_name foo
  assert_output "isopod-foo"
}
@test "box_dir lives under the config dir" {
  run box_dir foo
  assert_output "$ISOPOD_CONFIG_DIR/boxes/foo"
}

# ---- meta_get ----------------------------------------------------------------
@test "meta_get reads a key from a box meta file" {
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nport=12345\ncolor=#0f766e\n' >"$(box_dir demo)/meta"
  run meta_get demo port
  assert_output "12345"
}
@test "meta_get returns only the first match for a key" {
  mkdir -p "$(box_dir demo)"
  printf 'port=111\nport=222\n' >"$(box_dir demo)/meta"
  run meta_get demo port
  assert_output "111"
}

# ---- write_ssh_include -------------------------------------------------------
@test "write_ssh_include emits a Host block with isolation-hardening options" {
  mkdir -p "$(box_dir demo)"
  printf 'port=40000\n' >"$(box_dir demo)/meta"
  write_ssh_include
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  assert_output --partial "Host isopod-demo"
  assert_output --partial "HostName 127.0.0.1"
  assert_output --partial "Port 40000"
  assert_output --partial "ForwardAgent no"
  assert_output --partial "ForwardX11 no"
  assert_output --partial "StrictHostKeyChecking yes"
}
@test "write_ssh_include skips boxes that have no port yet" {
  mkdir -p "$(box_dir noport)"
  printf 'engine=podman\n' >"$(box_dir noport)/meta"
  write_ssh_include
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  refute_output --partial "Host isopod-noport"
}

# ---- ensure_ssh_include ------------------------------------------------------
@test "ensure_ssh_include adds an Include line to ~/.ssh/config once" {
  ensure_ssh_include
  ensure_ssh_include # idempotent
  # The path is written quoted (to tolerate spaces); match the bare path so the
  # count is robust to quoting and confirms the include appears exactly once.
  run grep -cF "$ISOPOD_CONFIG_DIR/ssh_config" "$HOME/.ssh/config"
  assert_output "1"
}

@test "ensure_ssh_include quotes the include path" {
  ensure_ssh_include
  run grep -F "Include \"$ISOPOD_CONFIG_DIR/ssh_config\"" "$HOME/.ssh/config"
  assert_success
}

# ---- ssh config quoting ------------------------------------------------------
@test "write_ssh_include quotes IdentityFile and UserKnownHostsFile paths" {
  mkdir -p "$(box_dir spacebox)"
  printf 'engine=podman\nport=12345\n' >"$(box_dir spacebox)/meta"
  write_ssh_include
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  assert_output --partial "IdentityFile \"$ISOPOD_CONFIG_DIR/boxes/spacebox/id_ed25519\""
  assert_output --partial "UserKnownHostsFile \"$ISOPOD_CONFIG_DIR/boxes/spacebox/known_hosts\""
}

# ---- locking -----------------------------------------------------------------
@test "acquire_lock creates a lock dir and release_lock removes it" {
  acquire_lock
  [ -d "$ISOPOD_CONFIG_DIR/.lock" ]
  [ -n "$LOCK_DIR" ]
  release_lock
  [ ! -d "$ISOPOD_CONFIG_DIR/.lock" ]
  [ -z "$LOCK_DIR" ]
}

@test "acquire_lock is idempotent within one process (no self-deadlock)" {
  acquire_lock
  first="$LOCK_DIR"
  acquire_lock # second call must be a no-op, not block
  [ "$LOCK_DIR" = "$first" ]
  release_lock
}

@test "acquire_lock reclaims a stale lock whose owner is gone" {
  mkdir -p "$ISOPOD_CONFIG_DIR/.lock"
  echo 2147483647 >"$ISOPOD_CONFIG_DIR/.lock/pid" # a pid that is not running
  acquire_lock                                    # must reclaim, not hang
  [ "$LOCK_DIR" = "$ISOPOD_CONFIG_DIR/.lock" ]
  release_lock
}

# ---- hardening_run_args (baseline + user override layering) -------------------
@test "hardening_run_args uses the shipped baseline when there is no override" {
  run hardening_run_args podman
  assert_success
  assert_output --partial "/proc/cmdline"
  assert_output --partial "/sys/class/net"
  refute_output --partial "--runtime"
}

@test "hardening_run_args layers a user override: unmask drops a baseline mask" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'unmask /sys/class/net\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  refute_output --partial "/sys/class/net" # dropped by the override
  assert_output --partial "/proc/cmdline"  # other baseline masks remain
}

@test "hardening_run_args layers a user override: runtime turns on Tier 2" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'runtime runsc\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  assert_output --partial "--runtime"
  assert_output --partial "runsc"
}

@test "hardening_run_args: a user mask: directive adds to the baseline" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'mask /sys/class/power_supply\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  assert_output --partial "/sys/class/power_supply"
  assert_output --partial "/proc/cmdline"
}

@test "hardening_run_args baseline masks the /sys/class/block device-tree alias" {
  run hardening_run_args podman
  assert_success
  assert_output --partial "/sys/class/block"
}

@test "hardening_run_args docker uses --tmpfs for dirs and skips /proc file masks" {
  # Docker/runc rejects bind mounts onto /proc files, so isopod must NOT emit a
  # /dev/null bind (it would abort the run); directory masks still use --tmpfs.
  run hardening_run_args docker
  assert_success
  assert_output --partial "--tmpfs"
  assert_output --partial "/sys/class/net"
  refute_output --partial "/dev/null"    # /proc file masks are not attempted
  refute_output --partial "/proc/cmdline"
  refute_output --partial "mask="        # docker has no mask flag
}

@test "parse_hardening records the /proc file masks in HARD_FMASKS" {
  parse_hardening
  [ "${#HARD_FMASKS[@]}" -ge 1 ]
  printf '%s\n' "${HARD_FMASKS[@]}" | grep -qx "/proc/cmdline"
}

@test "sha_hex is stable and collision-distinct" {
  local a b c
  a=$(printf 'foo' | sha_hex)
  b=$(printf 'foo' | sha_hex)
  c=$(printf 'bar' | sha_hex)
  [ -n "$a" ]
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
}

@test "hardening_run_args does not warn about the egress directive" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'egress lan-deny\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  refute_output --partial "unknown directive"
}

# ---- network egress isolation (`egress lan-deny`) ----------------------------
@test "active_egress is off by default" {
  run active_egress
  assert_success
  assert_output ""
}
@test "active_egress reads lan-deny from the user override" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'egress lan-deny\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run active_egress
  assert_output "lan-deny"
}
@test "active_egress: ISOPOD_EGRESS env wins over the profile" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'no-egress\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  ISOPOD_EGRESS=lan-deny run active_egress
  assert_output "lan-deny"
}
@test "active_egress: no-egress override turns it back off" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'egress lan-deny\nno-egress\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run active_egress
  assert_output ""
}
@test "active_egress treats 'off' as disabled" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'egress off\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run active_egress
  assert_output ""
}

@test "build_run_args adds egress flags when lan-deny is active" {
  ENGINE=podman
  ISOPOD_EGRESS=lan-deny build_run_args box img 127.0.0.1::22 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--network isopod0"* ]]
  [[ "$joined" == *"--dns 1.1.1.1"* ]]
  [[ "$joined" == *"--cap-drop NET_RAW"* ]]
  [[ "$joined" == *"--cap-drop NET_ADMIN"* ]]
}
@test "build_run_args omits egress flags by default" {
  ENGINE=podman
  build_run_args box img 127.0.0.1::22 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"--network isopod0"* ]]
  [[ "$joined" != *"--cap-drop NET_RAW"* ]]
}

@test "egress_can_enforce: true for rootful podman, false for rootless" {
  make_stub podman 0 "false" # {{.Host.Security.Rootless}} => false
  run egress_can_enforce podman
  assert_success
  make_stub podman 0 "true"
  run egress_can_enforce podman
  assert_failure
}
@test "egress_can_enforce: docker rootless is rejected" {
  # isopod reads SecurityOptions one-per-line; a 'name=rootless' entry => rootless.
  cat >"$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=seccomp,profile=default' 'name=rootless'
EOF
  chmod +x "$STUB_DIR/docker"
  run egress_can_enforce docker
  assert_failure
  cat >"$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=seccomp,profile=default'
EOF
  chmod +x "$STUB_DIR/docker"
  run egress_can_enforce docker
  assert_success
}

@test "egress_can_enforce: docker not fooled by 'rootless' as a substring" {
  # A profile path containing 'rootless' must NOT be read as rootless mode
  # (the point of matching the exact 'name=rootless' token, not a substring).
  cat >"$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'name=seccomp,profile=/etc/rootless-profile.json'
EOF
  chmod +x "$STUB_DIR/docker"
  run egress_can_enforce docker
  assert_success
}

@test "egress_preflight is a no-op when egress is off" {
  run egress_preflight podman
  assert_success
  assert_output ""
}
@test "egress_preflight refuses a rootless engine (fails closed)" {
  make_stub podman 0 "true" # rootless
  ISOPOD_EGRESS=lan-deny run egress_preflight podman
  assert_failure
  assert_output --partial "rootful engine"
}
@test "egress_preflight creates the network on a rootful engine" {
  make_stub podman 0 "false" # rootful; also stands in for network exists/create
  ISOPOD_EGRESS=lan-deny run egress_preflight podman
  assert_success
  assert_stub_called "podman network (exists|create)"
}

@test "egress_check_subnet is quiet when the subnet matches" {
  run egress_check_subnet podman "10.88.7.0/24 "
  assert_success
  assert_output ""
}
@test "egress_check_subnet warns on a subnet mismatch" {
  run egress_check_subnet podman "192.168.9.0/24 "
  assert_success
  assert_output --partial "must match"
}
@test "egress_check_subnet stays quiet when the subnet is unreadable" {
  run egress_check_subnet podman ""
  assert_success
  assert_output ""
}

@test "egress ruleset renders with the configured subnet" {
  run render_tmpl "$ISOPOD_EGRESS_RULESET"
  assert_success
  assert_output --partial "table inet isopod"
  assert_output --partial "ip saddr != 10.88.7.0/24 accept"
  assert_output --partial "ip daddr @lan4 drop"
  refute_output --partial '$ISOPOD_EGRESS_SUBNET' # fully substituted
}
@test "isopod egress rules prints the nftables table" {
  run cmd_egress rules
  assert_success
  assert_output --partial "table inet isopod"
}
@test "isopod egress rejects an unknown action" {
  run cmd_egress bogus
  assert_failure
  assert_output --partial "unknown egress action"
}

# ---- per-box config.yaml (Compose-shaped, isopod-parsed) ---------------------
@test "config.yaml round-trips through the parsers" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/web"
  printf 'engine=podman\nimage=img:1\ncolor=#0f766e\ncreated=t\nmemory=4g\ncpus=2\nexpose=3001:3000,8080:8080\n' \
    >"$ISOPOD_CONFIG_DIR/boxes/web/meta"
  write_box_config web
  assert_equal "$(config_get web mem_limit)" "4g"
  assert_equal "$(config_get web cpus)" "2"
  assert_equal "$(config_get web x-isopod-color)" "#0f766e"
  assert_equal "$(config_expose web | paste -sd, -)" "3001:3000,8080:8080"
}

@test "config.yaml is a Compose service with engine-correct masks; empties omitted" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/web"
  printf 'engine=podman\nimage=img:1\ncolor=#0f766e\ncreated=t\nmemory=\ncpus=\nexpose=\n' \
    >"$ISOPOD_CONFIG_DIR/boxes/web/meta"
  write_box_config web
  run cat "$ISOPOD_CONFIG_DIR/boxes/web/config.yaml"
  assert_output --partial "services:"
  assert_output --partial "security_opt:"
  assert_output --partial "mask=/sys/class/dmi"
  refute_output --partial "mem_limit:" # blank limit omitted, not rendered empty
  refute_output --partial "ports:"     # no forwards -> no ports block
}

@test "config.yaml renders docker masks as tmpfs dirs only (no /proc binds)" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/web"
  printf 'engine=docker\nimage=img:1\ncolor=#0f766e\ncreated=t\nmemory=\ncpus=\nexpose=\n' \
    >"$ISOPOD_CONFIG_DIR/boxes/web/meta"
  write_box_config web
  run cat "$ISOPOD_CONFIG_DIR/boxes/web/config.yaml"
  assert_output --partial "tmpfs:"
  assert_output --partial "- /sys/class/block"
  # Docker/runc can't bind-mask /proc files, so the reference config must not
  # claim to (it would abort `docker run`).
  refute_output --partial "/dev/null:/proc/cmdline"
  refute_output --partial "security_opt:" # docker has no mask flag
}

# ---- meta_get / config_get exact-key match (no regex injection) ---------------
@test "meta_get returns the exact key's value and tolerates '=' in values" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/b"
  printf 'engine=podman\nimage=localhost/x:1=2\nport=45678\n' \
    >"$ISOPOD_CONFIG_DIR/boxes/b/meta"
  run meta_get b image
  assert_output 'localhost/x:1=2'
  run meta_get b port
  assert_output '45678'
  # A regex-metacharacter key must match literally (nothing), not every line.
  run meta_get b '.*'
  assert_output ''
}

@test "config_get matches the exact key, not a regex" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/b"
  cat >"$ISOPOD_CONFIG_DIR/boxes/b/config.yaml" <<'YAML'
services:
  b:
    mem_limit: 2g
    cpus: "1.5"
YAML
  run config_get b mem_limit
  assert_output '2g'
  run config_get b cpus
  assert_output '1.5'
  run config_get b '.*'
  assert_output ''
}

# ---- auto_color (name-based, stable) -----------------------------------------
@test "auto_color derives a stable color from the box name" {
  run auto_color myproj
  assert_success
  local c1="$output"
  [[ "$c1" =~ ^#[0-9a-fA-F]{6}$ ]]
  run auto_color myproj
  assert_output "$c1" # same name -> same color, regardless of other boxes
}

# ---- egress_preflight fails closed (§3.4) ------------------------------------
_egress_stub_rootful_unloaded() {
  # podman: rootful (Rootless=false); the egress network already exists.
  cat >"$STUB_DIR/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
case "$1" in
  info) echo false ;;                 # {{.Host.Security.Rootless}} -> false
  network) case "$2" in exists) exit 0 ;; inspect) exit 0 ;; esac ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/podman"
  # nft: 'list table inet isopod' fails -> firewall definitively NOT loaded.
  cat >"$STUB_DIR/nft" <<'EOF'
#!/usr/bin/env bash
echo "nft $*" >> "$STUB_LOG"
exit 1
EOF
  chmod +x "$STUB_DIR/nft"
}

@test "egress_preflight refuses when the firewall is not loaded" {
  _egress_stub_rootful_unloaded
  ISOPOD_EGRESS=lan-deny run egress_preflight podman
  assert_failure
  assert_output --partial "host firewall is NOT loaded"
}

@test "egress_preflight allows an unloaded firewall with the override env" {
  _egress_stub_rootful_unloaded
  ISOPOD_EGRESS=lan-deny ISOPOD_EGRESS_ALLOW_UNLOADED=1 run egress_preflight podman
  assert_success
  assert_output --partial "WITHOUT the LAN block"
}

# ---- sandboxed runtime detection + preflight (Tier 2/3) ----------------------
# A podman stub whose `info` lists a set of registered OCI runtimes.
_stub_podman_runtimes() { # _stub_podman_runtimes <name...>
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "podman $*" >> "$STUB_LOG"'
    echo '[ "$1" = info ] || exit 0'
    printf 'cat <<'\''INFO'\''\nhost:\n  ociRuntimes:\n'
    local n
    for n in "$@"; do printf '    %s: [/usr/bin/%s]\n' "$n" "$n"; done
    printf 'INFO\n'
  } >"$STUB_DIR/podman"
  chmod +x "$STUB_DIR/podman"
}

@test "runtime_available: true for a runtime on PATH" {
  make_stub krun 0
  run runtime_available podman krun
  assert_success
}
@test "runtime_available: true for a runtime the engine reports as registered" {
  _stub_podman_runtimes crun runc krun
  run runtime_available podman krun
  assert_success
}
@test "runtime_available: false for an absent, unregistered runtime" {
  _stub_podman_runtimes crun runc
  run runtime_available podman krun
  assert_failure
}

@test "runtime_preflight is a no-op when no runtime is configured" {
  run runtime_preflight podman
  assert_success
  assert_output ""
}
@test "runtime_preflight is a no-op for an unclassified custom runtime" {
  # Unknown tier (not in share/runtimes) -> pass straight through, no availability check.
  ISOPOD_RUNTIME=my-custom-runtime run runtime_preflight podman
  assert_success
  assert_output ""
}
@test "runtime_preflight fails closed when the configured runtime is unavailable" {
  _stub_podman_runtimes crun runc
  ISOPOD_RUNTIME=krun run runtime_preflight podman
  assert_failure
  assert_output --partial "not on PATH or registered"
}
@test "runtime_preflight passes when the configured runtime is registered" {
  _stub_podman_runtimes crun runc krun
  # /dev/kvm may be absent here; that path only warns (success), never fails.
  ISOPOD_RUNTIME=krun run runtime_preflight podman
  assert_success
}

@test "detect_microvm_runtimes reports a registered Tier 3 runtime" {
  _stub_podman_runtimes crun runc krun crun-vm
  run detect_microvm_runtimes
  assert_success
  assert_output --partial "krun"
  assert_output --partial "crun-vm"
}
@test "detect_sandboxed_runtimes lists Tier 3 before Tier 2" {
  _stub_podman_runtimes crun runc runsc krun
  run detect_sandboxed_runtimes
  assert_success
  # krun (Tier 3) must appear before runsc (Tier 2)
  [[ "$output" == krun*runsc* ]]
}

# ---- microVM OCI annotations (build_run_args) --------------------------------
@test "build_run_args passes krun annotations for a podman microVM runtime" {
  ENGINE=podman
  ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=krun \
    build_run_args box img 127.0.0.1::22 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--annotation krun.nested_virt=1"* ]]
}
@test "build_run_args omits annotations for a Tier 2 (non-microVM) runtime" {
  ENGINE=podman
  ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=runsc \
    build_run_args box img 127.0.0.1::22 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"--annotation"* ]]
}
@test "build_run_args does not pass --annotation on docker (podman-only feature)" {
  ENGINE=docker
  ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=krun \
    build_run_args box img 127.0.0.1::22 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"--annotation"* ]]
}
