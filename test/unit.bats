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

# ---- valid_ipv4 / valid_cidr (egress parameter validation) -------------------
@test "valid_ipv4 accepts a dotted quad" {
  run valid_ipv4 "10.88.7.1"
  assert_success
}
@test "valid_ipv4 rejects an out-of-range octet" {
  run valid_ipv4 "10.88.7.256"
  assert_failure
}
@test "valid_ipv4 rejects the wrong number of octets" {
  run valid_ipv4 "10.88.7"
  assert_failure
  run valid_ipv4 "10.88.7.1.1"
  assert_failure
}
@test "valid_ipv4 rejects non-numeric / metacharacters" {
  run valid_ipv4 '10.0.0.$(id)'
  assert_failure
  run valid_ipv4 ""
  assert_failure
}
@test "valid_cidr accepts an IPv4 network" {
  run valid_cidr "10.88.7.0/24"
  assert_success
}
@test "valid_cidr rejects a missing or oversized prefix length" {
  run valid_cidr "10.88.7.0"
  assert_failure
  run valid_cidr "10.88.7.0/33"
  assert_failure
}
@test "valid_cidr rejects a bad address part" {
  run valid_cidr "10.88.7.999/24"
  assert_failure
}
@test "valid_ifname accepts a short netdev name" {
  run valid_ifname "isopod-egr"
  assert_success
}
@test "valid_ifname rejects over-long names and bad characters" {
  run valid_ifname "thisnameiswaytoolong"
  assert_failure
  run valid_ifname 'br eth0'
  assert_failure
  run valid_ifname 'br/0'
  assert_failure
  run valid_ifname ""
  assert_failure
}

# ---- egress_validate_vars ----------------------------------------------------
@test "egress_validate_vars passes with the shipped defaults" {
  run egress_validate_vars
  assert_success
}
@test "egress_validate_vars fails closed on a malformed subnet" {
  ISOPOD_EGRESS_SUBNET="10.88.7.0/notacidr" run egress_validate_vars
  assert_failure
  assert_output --partial "ISOPOD_EGRESS_SUBNET"
}
@test "egress_validate_vars fails closed on a bad gateway or proxy port" {
  ISOPOD_EGRESS_GATEWAY="10.88.7" run egress_validate_vars
  assert_failure
  ISOPOD_EGRESS_PROXY_PORT="99999" run egress_validate_vars
  assert_failure
}
@test "egress_validate_vars fails closed on a bad bridge interface name" {
  ISOPOD_EGRESS_IFACE="way-too-long-ifname" run egress_validate_vars
  assert_failure
  assert_output --partial "ISOPOD_EGRESS_IFACE"
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
@test "image_tag_for gives the lean and --dev images distinct tags" {
  lean="$(image_tag_for debian:bookworm-slim 0)"
  dev="$(image_tag_for debian:bookworm-slim 1)"
  [ "$lean" != "$dev" ]
  # the default (no dev arg) matches the lean tag
  assert_equal "$lean" "$(image_tag_for debian:bookworm-slim)"
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

@test "hardening_run_args skips host masks under a Tier 3 microVM" {
  # A microVM has its own kernel + virtual devices, so the host-fingerprint masks
  # protect nothing there: emit the runtime flag, but none of the masks.
  ISOPOD_RUNTIME=krun run hardening_run_args podman
  assert_success
  assert_output --partial "--runtime"
  assert_output --partial "krun"
  refute_output --partial "mask="
  refute_output --partial "/proc/cmdline"
  refute_output --partial "/sys/class"
}

@test "hardening_run_args keeps host masks under a Tier 2 runtime" {
  # gVisor is not a separate-kernel VM, so the masks still apply.
  ISOPOD_RUNTIME=runsc run hardening_run_args podman
  assert_success
  assert_output --partial "--runtime"
  assert_output --partial "mask="
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

@test "resolve_runtime_flag: podman gets an on-PATH bare name as an absolute path" {
  # podman resolves --runtime against its containers.conf map or an absolute
  # path, not a bare PATH name — so a bare `kata-runtime` must become a path.
  local bin="$BATS_TEST_TMPDIR/kata-runtime"
  printf '#!/bin/sh\n' >"$bin" && chmod +x "$bin"
  PATH="$BATS_TEST_TMPDIR:$PATH" run resolve_runtime_flag podman kata-runtime
  assert_success
  assert_output "$bin"
}

@test "resolve_runtime_flag: a name with no on-PATH binary is passed through" {
  # e.g. `kata-qemu` is a containers.conf alias, not a binary — leave it for
  # podman's runtime map to resolve.
  run resolve_runtime_flag podman kata-qemu-not-on-path
  assert_success
  assert_output "kata-qemu-not-on-path"
}

@test "resolve_runtime_flag: an absolute path is passed through unchanged" {
  run resolve_runtime_flag podman /opt/kata/bin/kata-runtime
  assert_success
  assert_output "/opt/kata/bin/kata-runtime"
}

@test "resolve_runtime_flag: docker never rewrites the name to a path" {
  # docker's --runtime only accepts registered names, so leave it untouched.
  local bin="$BATS_TEST_TMPDIR/kata-runtime"
  printf '#!/bin/sh\n' >"$bin" && chmod +x "$bin"
  PATH="$BATS_TEST_TMPDIR:$PATH" run resolve_runtime_flag docker kata-runtime
  assert_success
  assert_output "kata-runtime"
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
@test "active_egress defaults to allow-list" {
  run active_egress
  assert_success
  assert_output "allow-list"
}
@test "active_egress: a bare no-egress directive overrides the default" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'no-egress\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run active_egress
  assert_output ""
}
@test "active_egress: ISOPOD_EGRESS=off overrides the default" {
  ISOPOD_EGRESS=off run active_egress
  assert_output ""
}
@test "egress_explicitly_set: false at the default, true via env or a directive" {
  run egress_explicitly_set
  assert_failure
  ISOPOD_EGRESS=off run egress_explicitly_set
  assert_success
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'no-egress\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run egress_explicitly_set
  assert_success
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
  ISOPOD_EGRESS=lan-deny build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--network isopod0"* ]]
  [[ "$joined" == *"--dns 1.1.1.1"* ]]
  [[ "$joined" == *"--cap-drop NET_RAW"* ]]
  [[ "$joined" == *"--cap-drop NET_ADMIN"* ]]
}
@test "build_run_args uses allow-list egress flags by default" {
  ENGINE=podman
  build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--network isopod0"* ]]
  [[ "$joined" == *"http_proxy=http://10.88.7.1:8118"* ]]
}
@test "build_run_args omits egress flags when egress is off" {
  ENGINE=podman
  ISOPOD_EGRESS=off build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"--network isopod0"* ]]
  [[ "$joined" != *"--cap-drop NET_RAW"* ]]
}
@test "build_run_args disables in-box IPv6 when egress is active" {
  [ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ] || skip "host kernel has no IPv6 — sysctl is skipped by design"
  ENGINE=podman
  ISOPOD_EGRESS=lan-deny build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--sysctl net.ipv6.conf.all.disable_ipv6=1"* ]]
  [[ "$joined" == *"--sysctl net.ipv6.conf.default.disable_ipv6=1"* ]]
}
@test "build_run_args leaves IPv6 alone when egress is off" {
  ENGINE=podman
  ISOPOD_EGRESS=off build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"disable_ipv6"* ]]
}

# ---- egress_start_check (re-verify enforcement at start) ----------------------
@test "egress_start_check warns when an egress box's firewall is not loaded" {
  ENGINE=podman
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nport=2222\negress=lan-deny\n' >"$(box_dir demo)/meta"
  egress_can_enforce() { return 0; } # pretend rootful
  egress_rules_loaded() { return 1; } # pretend firewall not loaded
  run egress_start_check demo
  assert_output --partial "OPEN network"
  assert_output --partial "sudo isopod egress apply"
}
@test "egress_start_check warns when the engine is now rootless" {
  ENGINE=podman
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nport=2222\negress=allow-list\n' >"$(box_dir demo)/meta"
  egress_can_enforce() { return 1; } # rootless
  run egress_start_check demo
  assert_output --partial "rootless"
  assert_output --partial "OPEN network"
}
@test "egress_start_check is silent for a box created without egress" {
  ENGINE=podman
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nport=2222\negress=\n' >"$(box_dir demo)/meta"
  run egress_start_check demo
  assert_output ""
}

# ---- egress allow-list mode --------------------------------------------------
@test "active_egress reads allow-list from the user override" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'egress allow-list\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run active_egress
  assert_output "allow-list"
}
@test "active_egress treats an unknown mode as disabled" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'egress bogus-mode\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  run active_egress
  assert_output ""
}
@test "egress_ruleset selects the allow-list ruleset in allow-list mode" {
  ISOPOD_EGRESS=allow-list run egress_ruleset
  assert_output --partial "egress-allowlist.nft"
}
@test "build_run_args forces the proxy and drops caps in allow-list mode" {
  ENGINE=podman
  ISOPOD_EGRESS=allow-list build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--network isopod0"* ]]
  [[ "$joined" == *"http_proxy=http://10.88.7.1:8118"* ]]
  [[ "$joined" == *"https_proxy=http://10.88.7.1:8118"* ]]
  [[ "$joined" == *"--cap-drop NET_RAW"* ]]
  [[ "$joined" == *"--cap-drop NET_ADMIN"* ]]
  # No pinned resolver in allow-list mode — the proxy resolves names.
  [[ "$joined" != *"--dns"* ]]
}
@test "egress_filter_regexes anchors bare domains and wildcards" {
  ISOPOD_EGRESS_ALLOWLIST="$TEST_TMP/allow.conf"
  USER_EGRESS_ALLOWLIST="$TEST_TMP/user.conf"
  printf '# comment\nexample.com\n*.cdn.example.net\n' >"$ISOPOD_EGRESS_ALLOWLIST"
  : >"$USER_EGRESS_ALLOWLIST"
  run egress_filter_regexes
  assert_success
  assert_line '^(.*\.)?example\.com$'
  assert_line '^.+\.cdn\.example\.net$'
}
@test "egress_allow rejects a domain with regex metacharacters" {
  run egress_allow 'evil.com|.*'
  assert_failure
  assert_output --partial "invalid domain"
}
@test "egress_allow appends a valid domain to the user override" {
  ISOPOD_EGRESS_STATE_DIR="$TEST_TMP/state" # no tinyproxy.conf => no reload attempt
  run egress_allow "internal.example.org"
  assert_success
  grep -qxF "internal.example.org" "$USER_EGRESS_ALLOWLIST"
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
  ISOPOD_EGRESS=off run egress_preflight podman
  assert_success
  assert_output ""
}
@test "resolve_egress degrades default-on egress to off on a rootless engine" {
  make_stub podman 0 "true" # rootless => cannot enforce
  resolve_egress podman
  run active_egress
  assert_output ""
}
@test "resolve_egress leaves an explicitly requested egress mode untouched" {
  make_stub podman 0 "true" # rootless
  export ISOPOD_EGRESS=lan-deny
  resolve_egress podman # explicit: must NOT downgrade (preflight fails closed)
  run active_egress
  assert_output "lan-deny"
}
@test "egress_preflight refuses a rootless engine (fails closed)" {
  make_stub podman 0 "true" # rootless
  ISOPOD_EGRESS=lan-deny run egress_preflight podman
  assert_failure
  assert_output --partial "rootful engine"
}
@test "egress_preflight creates the network on a rootful engine" {
  make_stub podman 0 "false" # rootful; also stands in for network exists/create
  # Stub nft so egress_rules_loaded is deterministic regardless of the host's
  # nftables/privilege state. Without this the real nft is consulted: a root host
  # with working nftables (or an nf_tables-less container) reports the firewall as
  # "not loaded" and egress_preflight fails closed, so the test would pass only on
  # a host with no nft or an unprivileged one.
  make_stub nft 0 # firewall reads as loaded
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

# ---- platform detection (os_kind / is_macos / is_linux) ----------------------
# The `isopod` script runs on the Mac, but boxes run inside the podman machine /
# Docker Desktop Linux VM, so egress (nftables) and Tier-3 virt (/dev/kvm) live
# in that VM — several callers branch on the host OS. uname is stubbed to drive it.
@test "os_kind reports macos on Darwin" {
  make_stub uname 0 "Darwin"
  run os_kind
  assert_output "macos"
}
@test "os_kind reports linux on Linux" {
  make_stub uname 0 "Linux"
  run os_kind
  assert_output "linux"
}
@test "os_kind reports other on an unrecognized kernel" {
  make_stub uname 0 "OpenBSD"
  run os_kind
  assert_output "other"
}
@test "is_macos/is_linux agree with uname" {
  make_stub uname 0 "Darwin"
  run is_macos
  assert_success
  run is_linux
  assert_failure
}

# ---- macos_hv_support (the macOS /dev/kvm equivalent probe) -------------------
@test "macos_hv_support echoes the kern.hv_support sysctl value" {
  make_stub sysctl 0 "1"
  run macos_hv_support
  assert_output "1"
}

# ---- egress: macOS enforces inside the podman machine VM ----------------------
@test "egress_enforce_in_vm is true on macOS, false on Linux" {
  make_stub uname 0 "Darwin"
  run egress_enforce_in_vm
  assert_success
  make_stub uname 0 "Linux"
  run egress_enforce_in_vm
  assert_failure
}
@test "egress_rules_loaded is 'unknown' (2) on macOS when the VM is unreachable" {
  make_stub uname 0 "Darwin"
  make_stub podman 1 "" # `podman machine ssh -- true` fails -> VM not ready
  run egress_rules_loaded
  assert_equal "$status" 2
}
@test "egress apply on macOS steers the default allow-list to lan-deny in the VM" {
  make_stub uname 0 "Darwin"
  make_stub podman 0 "" # VM reachable; stands in for `podman machine ssh ...`
  run egress_apply enforce
  assert_success
  assert_output --partial "lan-deny"
  assert_stub_called "podman machine ssh"
}
@test "egress_preflight fails closed for an EXPLICIT allow-list on macOS" {
  make_stub uname 0 "Darwin"
  make_stub podman 0 "false"
  ISOPOD_EGRESS=allow-list run egress_preflight podman
  assert_failure
  assert_output --partial "lan-deny"
}
@test "egress persist on macOS installs the ruleset inside the podman machine VM" {
  make_stub uname 0 "Darwin"
  make_stub podman 0 "" # VM reachable; stands in for `podman machine ssh ...`
  run egress_persist
  assert_success
  assert_stub_called "podman machine ssh -- sudo systemctl enable"
  assert_stub_called "podman machine ssh -- sudo tee /etc/systemd/system/isopod-egress"
}

# ---- macOS Tier-3 capability detection (chip / version / nested virt) ---------
# The macOS "tier 3" story: the engine VM is already a hardware boundary; a NESTED
# per-box microVM needs Apple M3+ on macOS 15+. These probe that with stubs.
@test "macos_chip_generation parses the Apple M-series number" {
  make_stub sysctl 0 "Apple M3 Pro"
  run macos_chip_generation
  assert_output "3"
}
@test "macos_chip_generation is empty on Intel" {
  make_stub sysctl 0 "Intel(R) Core(TM) i7"
  run macos_chip_generation
  assert_output ""
}
@test "macos_major_version reads the macOS major version" {
  make_stub sw_vers 0 "15.5"
  run macos_major_version
  assert_output "15"
}
@test "macos_nested_virt_capable: true on M3/macOS15, false on M2" {
  make_stub sw_vers 0 "15.5"
  make_stub sysctl 0 "Apple M3 Pro"
  run macos_nested_virt_capable
  assert_success
  make_stub sysctl 0 "Apple M2"
  run macos_nested_virt_capable
  assert_failure
}
@test "doctor_virt_macos reports Hypervisor.framework and per-box microVM options" {
  make_stub uname 0 "Darwin"
  cat >"$STUB_DIR/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  kern.hv_support) echo 1 ;;
  machdep.cpu.brand_string) echo "Apple M3 Pro" ;;
  kern.osproductversion) echo "15.5" ;;
esac
EOF
  chmod +x "$STUB_DIR/sysctl"
  make_stub sw_vers 0 "15.5"
  run doctor_virt_macos
  assert_success
  assert_output --partial "Hypervisor.framework present"
  assert_output --partial "krunvm"
  assert_output --partial "nested virtualization"
}

# ---- macOS host-level egress backend: pf on the Mac (Apple container / vmnet) -
# The escape-resistant backend: pf on the macOS HOST, scoped to the box vmnet
# subnet, outside every guest VM. Stubs stand in for pfctl / container / sudo.
@test "egress_host_pf_supported: true on macOS with pfctl" {
  make_stub uname 0 "Darwin"
  make_stub pfctl 0 ""
  run egress_host_pf_supported
  assert_success
}
@test "macos_box_subnet: ISOPOD_PF_SUBNET overrides detection" {
  ISOPOD_PF_SUBNET="10.9.9.0/24" run macos_box_subnet
  assert_output "10.9.9.0/24"
}
@test "macos_box_subnet: falls back to the Apple container default" {
  run macos_box_subnet
  assert_output "192.168.64.0/24"
}
@test "macos_box_subnet: parses the subnet from container network inspect" {
  make_stub container 0 '{ "subnet": "192.168.64.0/24" }'
  run macos_box_subnet
  assert_output "192.168.64.0/24"
}
@test "egress_macos_backend: pf when pfctl + a routable subnet source" {
  make_stub uname 0 "Darwin"
  make_stub pfctl 0 ""
  ISOPOD_PF_SUBNET="192.168.64.0/24" run egress_macos_backend
  assert_output "pf"
}
@test "egress_macos_backend: falls back to vm without pfctl/container" {
  make_stub uname 0 "Darwin"
  run egress_macos_backend
  assert_output "vm"
}
@test "egress_macos_backend: ISOPOD_EGRESS_BACKEND overrides the default" {
  make_stub uname 0 "Darwin"
  make_stub pfctl 0 ""
  ISOPOD_EGRESS_BACKEND=vm ISOPOD_PF_SUBNET="192.168.64.0/24" run egress_macos_backend
  assert_output "vm"
}
@test "egress-host.pf renders with the box subnet substituted" {
  ISOPOD_PF_SUBNET="192.168.64.0/24"
  run render_tmpl "$ISOPOD_EGRESS_PF_RULESET"
  assert_success
  assert_output --partial "block drop in quick inet from 192.168.64.0/24 to <isopod_lan>"
  refute_output --partial '$ISOPOD_PF_SUBNET' # the variable is fully substituted
}
@test "egress apply on macOS host-pf loads the pf anchor via pfctl" {
  make_stub uname 0 "Darwin"
  make_stub pfctl 0 ""
  make_stub sudo 0 ""
  # matches both "pfctl -f" (as root in CI) and "sudo pfctl -f" (non-root on a Mac)
  ISOPOD_PF_SUBNET="192.168.64.0/24" run egress_apply enforce
  assert_success
  assert_stub_called "pfctl -f /etc/pf.conf"
}
@test "engine_healthcheck uses 'container system status' for Apple container" {
  make_stub container 0 ""
  run engine_healthcheck container
  assert_success
  assert_stub_called "container system status"
}

# ---- SSH addressing abstraction (podman loopback vs Apple container vmnet IP) --
# podman/docker publish the box sshd to 127.0.0.1:<port>; Apple `container` gives
# the box its own vmnet IP reached on the in-box sshd port. box_ssh_addr is the one
# place the two models diverge; the rest of the SSH transport is engine-agnostic.
@test "box_ssh_addr: podman box resolves to 127.0.0.1 + published port" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/web"
  printf 'engine=podman\nport=8022\n' >"$ISOPOD_CONFIG_DIR/boxes/web/meta"
  run box_ssh_addr web
  assert_output "127.0.0.1 8022"
}
@test "box_ssh_addr: Apple container box resolves to the vmnet IP + in-box sshd port" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/vm"
  printf 'engine=container\n' >"$ISOPOD_CONFIG_DIR/boxes/vm/meta"
  make_stub container 0 '{ "networks": [ { "address": "192.168.64.5/24" } ] }'
  run box_ssh_addr vm
  assert_output "192.168.64.5 $BOX_SSHD_PORT"
}
@test "container_box_ip parses the first IPv4 from container inspect" {
  make_stub container 0 '{ "address": "192.168.64.7" }'
  run container_box_ip anybox
  assert_output "192.168.64.7"
}
@test "box_ssh targets the container vmnet IP, not 127.0.0.1" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/vm"
  printf 'engine=container\n' >"$ISOPOD_CONFIG_DIR/boxes/vm/meta"
  : >"$ISOPOD_CONFIG_DIR/boxes/vm/id_ed25519"
  : >"$ISOPOD_CONFIG_DIR/boxes/vm/known_hosts"
  make_stub container 0 '{ "address": "192.168.64.9" }'
  make_stub ssh 0 ""
  run box_ssh vm -- true
  assert_success
  assert_stub_called "ssh .*@192.168.64.9"
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
  # These tests exercise the Linux host-firewall path (nft on the host). Pin the
  # OS so they behave the same on a macOS host, where egress_preflight would
  # otherwise branch to the in-VM path (covered by the macOS egress tests).
  make_stub uname 0 "Linux"
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
@test "runtime_available does not match a short name inside a longer one" {
  # Only kata-runtime is registered; bare 'kata' must NOT read as available, or
  # resolve_runtime would auto-select a runtime the engine cannot invoke.
  _stub_podman_runtimes crun runc kata-runtime
  run runtime_available podman kata
  assert_failure
  run runtime_available podman kata-runtime
  assert_success
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

@test "detect_microvm_runtimes reports registered Tier 3 runtimes, not crun-vm" {
  _stub_podman_runtimes crun runc krun kata-runtime crun-vm
  run detect_microvm_runtimes
  assert_success
  assert_output --partial "krun"
  assert_output --partial "kata-runtime"
  # crun-vm cannot boot isopod's OCI images, so it is never suggested.
  refute_output --partial "crun-vm"
}
@test "detect_sandboxed_runtimes lists Tier 3 before Tier 2" {
  _stub_podman_runtimes crun runc runsc krun
  run detect_sandboxed_runtimes
  assert_success
  # krun (Tier 3) must appear before runsc (Tier 2)
  [[ "$output" == krun*runsc* ]]
}

# ---- runtime network classification (share/runtimes column 3) ----------------
@test "runtime_net classifies krun and kata microVMs as virtio" {
  # krun is listed as virtio: isopod runs it with passt (krun.use_passt=1).
  run runtime_net krun
  assert_output "virtio"
  run runtime_net kata-runtime
  assert_output "virtio"
  run runtime_net kata
  assert_output "virtio"
  run runtime_net runsc
  assert_output "netstack"
  # crun-vm is deliberately unlisted (it boots VM disk images, not OCI images).
  run runtime_net crun-vm
  assert_failure
  assert_output ""
}
@test "runtime_net echoes nothing for an unlisted runtime" {
  # Mirrors runtime_tier: unlisted -> no output, nonzero status (callers treat a
  # non-'tsi' result, empty included, as "networking is fine").
  run runtime_net my-custom-runtime
  assert_failure
  assert_output ""
}

# ---- default runtime resolution (microVM by default, --container opt-out) -----
@test "resolve_runtime selects a virtio-net microVM by default when one is runnable" {
  [ -e /dev/kvm ] || skip "no /dev/kvm on this host — microVM is not runnable"
  _stub_podman_runtimes crun runc kata-runtime
  resolve_runtime podman 0
  run active_runtime
  assert_output "kata-runtime"
}
@test "resolve_runtime prefers kata over krun when both are runnable" {
  [ -e /dev/kvm ] || skip "no /dev/kvm on this host — microVM is not runnable"
  # Both are virtio now; kata comes first in the runtimes table, so it wins.
  _stub_podman_runtimes crun runc krun kata-runtime
  resolve_runtime podman 0
  run active_runtime
  assert_output "kata-runtime"
}
@test "resolve_runtime auto-selects krun (virtio via passt) when it is the only microVM" {
  [ -e /dev/kvm ] || skip "no /dev/kvm on this host — krun would not be runnable"
  # krun now runs with passt (virtio-net), so it carries Remote-SSH and IS
  # auto-selected as the default microVM ahead of the Tier 2 fallback.
  _stub_podman_runtimes crun runc krun runsc
  resolve_runtime podman 0
  run active_runtime
  assert_output "krun"
}
@test "resolve_runtime auto-selects krun ahead of falling back to a plain container" {
  [ -e /dev/kvm ] || skip "no /dev/kvm on this host — krun would not be runnable"
  _stub_podman_runtimes crun runc krun # krun only, no gVisor
  resolve_runtime podman 0
  run active_runtime
  assert_output "krun"
}
@test "resolve_runtime falls back to gVisor when no microVM is runnable" {
  # Only runsc (Tier 2, no KVM needed) is registered; no microVM available.
  _stub_podman_runtimes runc runsc
  resolve_runtime podman 0
  run active_runtime
  assert_output "runsc"
}
@test "resolve_runtime falls back to a plain container when nothing is available" {
  _stub_podman_runtimes runc
  resolve_runtime podman 0
  run active_runtime
  assert_output ""
}
@test "resolve_runtime honors an explicitly configured runtime" {
  _stub_podman_runtimes runc runsc
  export ISOPOD_RUNTIME=runsc
  resolve_runtime podman 0
  run active_runtime
  assert_output "runsc"
}
@test "resolve_runtime honors an explicit krun" {
  # An explicit choice is respected as-is (no runnable/KVM gate).
  _stub_podman_runtimes runc krun
  export ISOPOD_RUNTIME=krun
  resolve_runtime podman 0
  run active_runtime
  assert_output "krun"
}
@test "resolve_runtime with --container forces a plain container" {
  _stub_podman_runtimes runc runsc # runsc is available but must be ignored
  resolve_runtime podman 1
  run active_runtime
  assert_output ""
}
@test "resolve_runtime: --container overrides an explicitly configured runtime" {
  _stub_podman_runtimes runc krun
  export ISOPOD_RUNTIME=krun
  resolve_runtime podman 1
  run active_runtime
  assert_output ""
}

# ---- microVM OCI annotations (build_run_args) --------------------------------
@test "build_run_args passes krun annotations for a podman microVM runtime" {
  ENGINE=podman
  ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=krun \
    build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--annotation krun.nested_virt=1"* ]]
}
@test "build_run_args auto-adds krun.use_passt for a krun microVM (virtio-net for isopod code)" {
  ENGINE=podman
  ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--annotation krun.use_passt=1"* ]]
}
@test "build_run_args does not force use_passt for a non-krun microVM (kata)" {
  ENGINE=podman
  ISOPOD_RUNTIME=kata-runtime build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"use_passt"* ]]
}
@test "build_run_args lets the user override krun.use_passt" {
  ENGINE=podman
  ISOPOD_MICROVM_ANNOTATIONS="krun.use_passt=0" ISOPOD_RUNTIME=krun \
    build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--annotation krun.use_passt=0"* ]]
  [[ "$joined" != *"krun.use_passt=1"* ]]
}
@test "build_run_args omits annotations for a Tier 2 (non-microVM) runtime" {
  ENGINE=podman
  ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=runsc \
    build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"--annotation"* ]]
}
@test "build_run_args does not pass --annotation on docker (podman-only feature)" {
  ENGINE=docker
  ISOPOD_MICROVM_ANNOTATIONS="krun.nested_virt=1" ISOPOD_RUNTIME=krun \
    build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"--annotation"* ]]
}

# ---- secrets: names, paths, specs ---------------------------------------------

@test "valid_secret_name accepts typical env-style names" {
  run valid_secret_name "API_KEY"
  assert_success
  run valid_secret_name "_x"
  assert_success
  run valid_secret_name "Token9"
  assert_success
}

@test "valid_secret_name rejects malformed names" {
  run valid_secret_name ""
  assert_failure
  run valid_secret_name "9lead"
  assert_failure
  run valid_secret_name "a b"
  assert_failure
  run valid_secret_name "a:b"
  assert_failure
  run valid_secret_name "a,b"
  assert_failure
  run valid_secret_name "$(printf 'x%.0s' {1..65})"
  assert_failure
}

@test "parse_secret_specs defaults the target to /run/secrets/NAME" {
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'v' >"$ISOPOD_CONFIG_DIR/secrets/TOK"
  parse_secret_specs TOK
  [ "${SECRET_SPECS[0]}" = "TOK:/run/secrets/TOK" ]
}

@test "parse_secret_specs keeps an explicit path and warns outside /run/secrets" {
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'v' >"$ISOPOD_CONFIG_DIR/secrets/TOK"
  run parse_secret_specs TOK:/opt/creds/tok
  assert_success
  assert_output --partial "outside the /run/secrets tmpfs"
}

@test "parse_secret_specs dies on a workspace target (export would leak it)" {
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'v' >"$ISOPOD_CONFIG_DIR/secrets/TOK"
  run parse_secret_specs "TOK:$WORKSPACE/tok"
  assert_failure
  assert_output --partial "isopod export"
}

@test "parse_secret_specs dies on relative or metachar paths" {
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'v' >"$ISOPOD_CONFIG_DIR/secrets/TOK"
  run parse_secret_specs "TOK:etc/tok"
  assert_failure
  run parse_secret_specs "TOK:/run/secrets/a b"
  assert_failure
  run parse_secret_specs 'TOK:/run/secrets/$(x)'
  assert_failure
}

@test "parse_secret_specs dies on duplicate names and duplicate targets" {
  export ISOPOD_SECRET_BACKEND=file
  mkdir -p "$ISOPOD_CONFIG_DIR/secrets"
  printf 'v' >"$ISOPOD_CONFIG_DIR/secrets/TOK"
  printf 'v' >"$ISOPOD_CONFIG_DIR/secrets/TOK2"
  run parse_secret_specs TOK TOK
  assert_failure
  assert_output --partial "duplicate secret"
  run parse_secret_specs TOK:/run/secrets/same TOK2:/run/secrets/same
  assert_failure
  assert_output --partial "same path"
}

@test "parse_secret_specs dies when the secret is not in the store" {
  export ISOPOD_SECRET_BACKEND=file
  run parse_secret_specs NOPE
  assert_failure
  assert_output --partial "isopod secret set NOPE"
}

# ---- secrets: backend selection and stores --------------------------------------

@test "secret_backend honors the env override" {
  ISOPOD_SECRET_BACKEND=file run secret_backend
  assert_output "file"
}

@test "secret_backend prefers secret-tool on Linux, else falls back to file" {
  if [ "$(uname -s)" = Darwin ]; then skip "Linux backend order"; fi
  make_stub secret-tool
  run secret_backend
  assert_output "keychain-linux"
  rm -f "$STUB_DIR/secret-tool"
  # no keychain tool anywhere -> file (ignore any host secret-tool; keep a
  # self-contained uname so the platform check works on the narrowed PATH)
  printf '#!/bin/sh\necho Linux\n' >"$STUB_DIR/uname"
  chmod +x "$STUB_DIR/uname"
  PATH="$STUB_DIR" run secret_backend
  assert_output "file"
}

@test "file backend: set stores 0600, get round-trips, rm removes" {
  export ISOPOD_SECRET_BACKEND=file
  printf 'hunter2' | secret_store_set TOK
  [ "$(file_mode "$ISOPOD_CONFIG_DIR/secrets/TOK")" = "600" ]
  run secret_store_get TOK
  assert_output "hunter2"
  run secret_store_ls
  assert_output "TOK"
  secret_store_rm TOK
  [ ! -f "$ISOPOD_CONFIG_DIR/secrets/TOK" ]
  run secret_store_get TOK
  assert_failure
  run secret_store_ls
  refute_output --partial "TOK"
}

@test "file backend warns about plaintext exactly once" {
  export ISOPOD_SECRET_BACKEND=file
  run bash -c 'ISOPOD_SOURCED=1 source "$ISOPOD_ROOT/isopod"; printf a | secret_store_set A'
  assert_output --partial "plaintext"
  run bash -c 'ISOPOD_SOURCED=1 source "$ISOPOD_ROOT/isopod"; printf b | secret_store_set B'
  refute_output --partial "plaintext"
}

@test "keychain-linux backend passes the value on stdin, never argv" {
  make_stub secret-tool
  export ISOPOD_SECRET_BACKEND=keychain-linux
  printf 's3kr1tv4lu3' | secret_store_set TOK
  assert_stub_called 'secret-tool store .*service isopod name TOK'
  assert_stub_not_called 's3kr1tv4lu3'
}
