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
  printf 'engine=podman\nport=12345\ncolor=#0f766e\n' > "$(box_dir demo)/meta"
  run meta_get demo port
  assert_output "12345"
}
@test "meta_get returns only the first match for a key" {
  mkdir -p "$(box_dir demo)"
  printf 'port=111\nport=222\n' > "$(box_dir demo)/meta"
  run meta_get demo port
  assert_output "111"
}

# ---- write_ssh_include -------------------------------------------------------
@test "write_ssh_include emits a Host block with isolation-hardening options" {
  mkdir -p "$(box_dir demo)"
  printf 'port=40000\n' > "$(box_dir demo)/meta"
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
  printf 'engine=podman\n' > "$(box_dir noport)/meta"
  write_ssh_include
  run cat "$ISOPOD_CONFIG_DIR/ssh_config"
  refute_output --partial "Host isopod-noport"
}

# ---- ensure_ssh_include ------------------------------------------------------
@test "ensure_ssh_include adds an Include line to ~/.ssh/config once" {
  ensure_ssh_include
  ensure_ssh_include   # idempotent
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
  printf 'engine=podman\nport=12345\n' > "$(box_dir spacebox)/meta"
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
  acquire_lock            # second call must be a no-op, not block
  [ "$LOCK_DIR" = "$first" ]
  release_lock
}

@test "acquire_lock reclaims a stale lock whose owner is gone" {
  mkdir -p "$ISOPOD_CONFIG_DIR/.lock"
  echo 2147483647 > "$ISOPOD_CONFIG_DIR/.lock/pid"   # a pid that is not running
  acquire_lock                                        # must reclaim, not hang
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
  printf 'unmask /sys/class/net\n' > "$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  refute_output --partial "/sys/class/net"   # dropped by the override
  assert_output --partial "/proc/cmdline"     # other baseline masks remain
}

@test "hardening_run_args layers a user override: runtime turns on Tier 2" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'runtime runsc\n' > "$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  assert_output --partial "--runtime"
  assert_output --partial "runsc"
}

@test "hardening_run_args: a user mask: directive adds to the baseline" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'mask /sys/class/power_supply\n' > "$ISOPOD_CONFIG_DIR/hardening.conf"
  run hardening_run_args podman
  assert_success
  assert_output --partial "/sys/class/power_supply"
  assert_output --partial "/proc/cmdline"
}
