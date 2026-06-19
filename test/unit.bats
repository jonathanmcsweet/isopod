#!/usr/bin/env bats
# Unit tests for aibox's pure functions — no container engine needed.

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  aibox_setup_env
  load_aibox
}
teardown() { aibox_teardown_env; }

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
@test "image_tag_for uses the localhost/aibox-base prefix" {
  run image_tag_for debian:bookworm-slim
  assert_output --partial "localhost/aibox-base:"
}

# ---- ctr_name / box_dir ------------------------------------------------------
@test "ctr_name prefixes with aibox-" {
  run ctr_name foo
  assert_output "aibox-foo"
}
@test "box_dir lives under the config dir" {
  run box_dir foo
  assert_output "$AIBOX_CONFIG_DIR/boxes/foo"
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
  run cat "$AIBOX_CONFIG_DIR/ssh_config"
  assert_output --partial "Host aibox-demo"
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
  run cat "$AIBOX_CONFIG_DIR/ssh_config"
  refute_output --partial "Host aibox-noport"
}

# ---- ensure_ssh_include ------------------------------------------------------
@test "ensure_ssh_include adds an Include line to ~/.ssh/config once" {
  ensure_ssh_include
  ensure_ssh_include   # idempotent
  run grep -c "Include $AIBOX_CONFIG_DIR/ssh_config" "$HOME/.ssh/config"
  assert_output "1"
}
