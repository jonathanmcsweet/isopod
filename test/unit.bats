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

@test "hardening_run_args keeps ALL host masks under a Tier 3 microVM" {
  # A microVM's own /proc and /sys are synthetic, but they are not the only copy
  # the guest can reach: crun's krun handler exports the CONTAINER rootfs over
  # virtio-fs, and podman mounted the host's procfs and sysfs into that rootfs.
  # So the guest reaches host boot identity (/proc/cmdline, /proc/config.gz) AND
  # host hardware identity (/sys/class/dmi, /sys/block) through the export.
  # Skipping either set on Tier 3 leaked what this profile exists to hide.
  ISOPOD_RUNTIME=krun run hardening_run_args podman
  assert_success
  assert_output --partial "--runtime"
  assert_output --partial "krun"
  assert_output --partial "mask="
  assert_output --partial "/proc/cmdline"
  assert_output --partial "/proc/config.gz"
  assert_output --partial "/sys/class/dmi"
  assert_output --partial "/sys/block"
}

@test "hardening_run_args masks the host kernel build config on every tier" {
  # /proc/config.gz is the host kernel's full build config — a precise host
  # fingerprint — and is readable in a plain container too, not just a microVM.
  run hardening_run_args podman
  assert_success
  assert_output --partial "/proc/config.gz"
}

@test "hardening_run_args keeps docker's dir masks under a microVM too" {
  # Same reasoning as podman: the /sys masks are not redundant on Tier 3. Docker
  # still can't bind-mask /proc FILES (runc rejects it), so only the dir masks
  # appear — as --tmpfs, docker's equivalent.
  ISOPOD_RUNTIME=kata-runtime run hardening_run_args docker
  assert_success
  assert_output --partial "--tmpfs"
  assert_output --partial "/sys/class/dmi"
  refute_output --partial "/proc/cmdline"
}

@test "runtime_tier resolves a runtime given as an absolute path" {
  # A runtime reaches the tier lookup as a path from `runtime /usr/bin/krun`,
  # from ISOPOD_RUNTIME/--runtime, or round-tripped through a box's meta on
  # reconfigure. Matching only the table name meant no tier — and every Tier 3
  # measure (microVM memory default, guest sysctls, mask-microvm) skipped
  # silently.
  [ "$(runtime_tier krun)" = 3 ]
  [ "$(runtime_tier /usr/bin/krun)" = 3 ]
  [ "$(runtime_tier /opt/kata/bin/kata-runtime)" = 3 ]
  [ "$(runtime_tier runsc)" = 2 ]
}

@test "runtime_tier knows crun-krun, the binary krun is registered to" {
  [ "$(runtime_tier crun-krun)" = 3 ]
  [ "$(runtime_tier /usr/bin/crun-krun)" = 3 ]
}

@test "runtime_tier still reports nothing for an unknown runtime" {
  run runtime_tier bogus
  assert_failure
  run runtime_tier /usr/bin/bogus
  assert_failure
}

@test "a path-configured microVM still gets its Tier 3 masks" {
  # The end-to-end consequence of the lookup above: configure krun by path and
  # the box must still be treated as a microVM.
  ISOPOD_RUNTIME=/usr/bin/crun-krun run hardening_run_args podman
  assert_success
  assert_output --partial "/sys/devices:"
}
@test "mask-microvm closes the device tree on Tier 3 only" {
  # The ordinary masks close the ALIAS views (/sys/bus/pci, /sys/class/nvme,
  # /sys/block); /sys/devices is the real tree behind them and still yields host
  # PCI topology and NVMe hardware serials. It can only be masked under a microVM,
  # where the box reads its guest's sysfs and nothing needs the container's copy.
  ISOPOD_RUNTIME=krun run hardening_run_args podman
  assert_success
  assert_output --partial "/sys/devices:"

  # Tier 1: the container's /sys IS the box's /sys — masking it would break tools
  # in the box that read /sys/devices/system/cpu.
  run hardening_run_args podman
  assert_success
  refute_output --partial "/sys/devices:"

  # Tier 2 shares the host kernel the same way, so it is excluded too.
  ISOPOD_RUNTIME=runsc run hardening_run_args podman
  assert_success
  refute_output --partial "/sys/devices:"
}

@test "mask-microvm reaches docker's --tmpfs list under a microVM" {
  ISOPOD_RUNTIME=kata-runtime run hardening_run_args docker
  assert_success
  assert_output --partial "/sys/devices"
}

@test "unmask drops a mask-microvm entry from the baseline" {
  mkdir -p "$ISOPOD_CONFIG_DIR"
  printf 'unmask /sys/devices\n' >"$ISOPOD_CONFIG_DIR/hardening.conf"
  ISOPOD_RUNTIME=krun run hardening_run_args podman
  assert_success
  refute_output --partial "/sys/devices:"
  # the unrelated DMI subtree mask is untouched
  assert_output --partial "/sys/devices/virtual/dmi"
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
  refute_output --partial "/dev/null" # /proc file masks are not attempted
  refute_output --partial "/proc/cmdline"
  refute_output --partial "mask=" # docker has no mask flag
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
# ---- resolver disclosure (/etc/resolv.conf) -----------------------------------
# podman copies the HOST's resolv.conf into a box by default, disclosing its
# nameserver addresses and search domain. What to do about it differs by egress
# mode, because who resolves names differs.

@test "allow-list gives the box no resolver at all" {
  # Proxied clients hand the hostname to the proxy, which resolves it — so the
  # box needs no resolver, and having one is both a disclosure and a DNS path
  # that bypasses the hostname allow-list entirely.
  ENGINE=podman
  ISOPOD_EGRESS=allow-list build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--dns=none"* ]]
  # the entrypoint needs to know, so it can explain where resolution happens
  [[ "$joined" == *"ISOPOD_DNS_VIA_PROXY=1"* ]]
  # no search line can exist when there is no resolv.conf
  [[ "$joined" != *"--dns-search"* ]]
}

@test "lan-deny keeps a pinned resolver but drops the search domain" {
  ENGINE=podman
  ISOPOD_EGRESS=lan-deny build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--dns $ISOPOD_EGRESS_DNS"* ]]
  [[ "$joined" == *"--dns-search=."* ]]
  [[ "$joined" != *"--dns=none"* ]]
}

@test "egress off keeps working resolvers but still drops the search domain" {
  # An open box needs its resolvers and can read them from its own route table
  # anyway, so hiding the addresses would be cosmetic. The search domain names
  # the user's network and is never needed to resolve a public name.
  ENGINE=podman
  ISOPOD_EGRESS=off build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"--dns-search=."* ]]
  [[ "$joined" != *"--dns=none"* ]]
  [[ "$joined" != *"ISOPOD_DNS_VIA_PROXY"* ]]
}

@test "the entrypoint explains name resolution only for an allow-list box" {
  # The one real UX cost of --dns=none is a misleading "Could not resolve host".
  # The explanation goes in resolv.conf itself, where someone debugging that
  # error looks first — comments only, so glibc still fails fast.
  run grep -c 'ISOPOD_DNS_VIA_PROXY' "$ISOPOD_ENTRYPOINT"
  assert_success
  run grep -c 'isopod egress allow' "$ISOPOD_ENTRYPOINT"
  assert_success
  # it must not clobber a resolv.conf podman did provide
  run grep -c '\[ ! -s /etc/resolv.conf \]' "$ISOPOD_ENTRYPOINT"
  assert_output "1"
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
  egress_can_enforce() { return 0; }  # pretend rootful
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
  # No pinned resolver ADDRESS in allow-list mode — the proxy resolves names.
  # `--dns=none` is the opposite of pinning one: it removes the box's resolver
  # entirely (and with it the host's, which podman would otherwise copy in).
  [[ "$joined" != *"--dns $ISOPOD_EGRESS_DNS"* ]]
  [[ "$joined" == *"--dns=none"* ]]
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
  # Per-box isolation on macOS is retargeted to Apple `container` (krunvm's TSI
  # networking gives no routable per-box IP), so the guidance names container.
  assert_output --partial "container"
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
  make_stub container 0 '{ "networks": [ { "ipv4Address": "192.168.64.5/24" } ] }'
  run box_ssh_addr vm
  assert_output "192.168.64.5 $BOX_SSHD_PORT"
}
@test "container_box_ip reads the box ipv4Address, not a DNS or gateway IP" {
  # An egress box carries --dns 1.1.1.1, so inspect lists that nameserver (and the
  # gateway) alongside the box address. The box IP must come from ipv4Address, not
  # a naive first-IP match — else SSH targets 1.1.1.1 and create fails at host-key pinning.
  make_stub container 0 '{ "dns": { "nameservers": [ "1.1.1.1" ] }, "networks": [ { "ipv4Address": "192.168.64.7/24", "gateway": "192.168.64.1" } ] }'
  run container_box_ip anybox
  assert_output "192.168.64.7"
}
@test "box_ssh targets the container vmnet IP, not 127.0.0.1" {
  mkdir -p "$ISOPOD_CONFIG_DIR/boxes/vm"
  printf 'engine=container\n' >"$ISOPOD_CONFIG_DIR/boxes/vm/meta"
  : >"$ISOPOD_CONFIG_DIR/boxes/vm/id_ed25519"
  : >"$ISOPOD_CONFIG_DIR/boxes/vm/known_hosts"
  make_stub container 0 '{ "networks": [ { "ipv4Address": "192.168.64.9/24" } ] }'
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

# Stub a kata binary whose `env` self-check fails: the runtime is installed but
# its guest kernel/image artifacts are missing (a split-package half-install).
_stub_broken_kata() { # _stub_broken_kata <name>
  cat >"$STUB_DIR/$1" <<'EOF'
#!/usr/bin/env bash
[ "$1" = env ] && { echo "file /var/cache/kata-containers/vmlinuz.container does not exist" >&2; exit 1; }
exit 0
EOF
  chmod +x "$STUB_DIR/$1"
}

@test "_runtime_healthy passes a kata whose env self-check succeeds" {
  make_stub kata-runtime 0
  run _runtime_healthy kata-runtime
  assert_success
}
@test "_runtime_healthy fails a kata whose env self-check fails" {
  _stub_broken_kata kata-runtime
  run _runtime_healthy kata-runtime
  assert_failure
}
@test "_runtime_healthy matches kata variants by basename (absolute path)" {
  _stub_broken_kata kata-runtime
  run _runtime_healthy "$STUB_DIR/kata-runtime"
  assert_failure
}
@test "_runtime_healthy passes a kata that is not on PATH (nothing to probe)" {
  run _runtime_healthy kata-runtime
  assert_success
}
@test "_runtime_healthy passes non-kata runtimes without probing" {
  # krun/runsc have no `env` self-check; probing them would be a false negative.
  make_stub krun 1
  run _runtime_healthy krun
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
@test "resolve_runtime skips a kata that cannot boot a VM and selects krun" {
  [ -e /dev/kvm ] || skip "no /dev/kvm on this host — microVM is not runnable"
  # kata-runtime is on PATH but half-installed (env self-check fails); without
  # the health probe it would win on table order and every create would fail.
  _stub_podman_runtimes crun runc krun kata-runtime
  _stub_broken_kata kata-runtime
  resolve_runtime podman 0 2>"$TEST_TMP/warn"
  run active_runtime
  assert_output "krun"
  grep -q "cannot boot a VM" "$TEST_TMP/warn"
}
@test "runtime_preflight warns when the configured runtime cannot boot a VM" {
  _stub_podman_runtimes crun runc kata-runtime
  _stub_broken_kata kata-runtime
  ISOPOD_RUNTIME=kata-runtime run runtime_preflight podman
  assert_success
  assert_output --partial "cannot boot a VM"
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

# ---- kernel hardening profile (--harden) --------------------------------------
@test "build_run_args passes the hardening env on a microVM box (default profile)" {
  ENGINE=podman
  ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"ISOPOD_HARDEN=default"* ]]
}
@test "build_run_args omits the hardening env on a plain container (shared host kernel)" {
  ENGINE=podman
  build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"ISOPOD_HARDEN"* ]]
}
@test "build_run_args omits the hardening env on a microVM box when --harden off" {
  ENGINE=podman
  BOX_HARDEN=off ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"ISOPOD_HARDEN"* ]]
}

# ---- data volumes (--disk) ----------------------------------------------------

@test "parse_disk_spec defaults the mountpoint and normalizes the spec" {
  parse_disk_spec 20g
  [ "$DISK_SIZE" = "20g" ]
  [ "$DISK_MOUNT" = "/mnt/data" ]
  [ "$DISK_SPEC" = "20g:/mnt/data" ]
}

@test "parse_disk_spec keeps an explicit mountpoint" {
  parse_disk_spec "512m:/srv/cache"
  [ "$DISK_SIZE" = "512m" ]
  [ "$DISK_MOUNT" = "/srv/cache" ]
  [ "$DISK_SPEC" = "512m:/srv/cache" ]
}

@test "parse_disk_spec clears the globals for an empty spec" {
  parse_disk_spec "20g"
  parse_disk_spec ""
  [ -z "$DISK_SIZE" ]
  [ -z "$DISK_MOUNT" ]
  [ -z "$DISK_SPEC" ]
}

@test "parse_disk_spec rejects a bad size" {
  run parse_disk_spec "twenty"
  assert_failure
  assert_output --partial "invalid --disk size"
  run parse_disk_spec "20gb"
  assert_failure
}

@test "parse_disk_spec rejects mountpoints that are not plain absolute paths" {
  # relative
  run parse_disk_spec "20g:mnt/data"
  assert_failure
  assert_output --partial "invalid --disk mountpoint"
  # shell metacharacters — the spec reaches the box as an env value
  run parse_disk_spec '20g:/mnt/$(id)'
  assert_failure
  run parse_disk_spec '20g:/mnt/a b'
  assert_failure
  # traversal and trailing slash
  run parse_disk_spec "20g:/mnt/../etc"
  assert_failure
  run parse_disk_spec "20g:/mnt/data/"
  assert_failure
}

@test "parse_disk_spec refuses to mount the volume over the box root" {
  run parse_disk_spec "20g:/"
  assert_failure
  assert_output --partial "pick a subdirectory"
}

@test "build_run_args passes the disk spec to the entrypoint" {
  ENGINE=podman
  BOX_DISK=20g:/mnt/data ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" == *"ISOPOD_DISK=20g:/mnt/data"* ]]
  # a data volume is box-local: no engine mount flag is involved
  [[ "$joined" != *"--volume"* ]]
  [[ "$joined" != *" -v "* ]]
  [[ "$joined" != *"--mount"* ]]
}

@test "build_run_args omits the disk env on a box without one" {
  ENGINE=podman
  ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  local joined="${RUN_ARGS[*]}"
  [[ "$joined" != *"ISOPOD_DISK"* ]]
}

@test "build_run_args passes the nested-containers env only when asked" {
  ENGINE=podman
  BOX_NESTED=1 ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  [[ "${RUN_ARGS[*]}" == *"ISOPOD_NESTED=1"* ]]
  ISOPOD_RUNTIME=krun build_run_args box img 127.0.0.1::2222 "" ""
  [[ "${RUN_ARGS[*]}" != *"ISOPOD_NESTED"* ]]
}

@test "image_tag_for gives the nested image its own tag" {
  local lean nested dev
  lean=$(image_tag_for debian:bookworm-slim 0 0)
  nested=$(image_tag_for debian:bookworm-slim 0 1)
  dev=$(image_tag_for debian:bookworm-slim 1 0)
  [ "$lean" != "$nested" ]
  [ "$dev" != "$nested" ]
}

# ---- box entrypoint: drop the runtime's OCI config copy -----------------------

@test "the entrypoint removes the krun OCI config copy" {
  # crun writes the container's whole config.json into the rootfs as
  # /.krun_config.json (mode 0444). On a microVM box the guest's / IS that
  # rootfs, so it is readable by every process in the box — including on a
  # --no-sudo box — and it carries the host username, home layout and uid.
  run grep -c 'rm -f /\.krun_config\.json' "$ISOPOD_ENTRYPOINT"
  assert_success
  assert_output "1"
}

@test "the entrypoint drops the OCI config before sshd accepts logins" {
  # Ordering is the whole point: once sshd is up, anything in the box could read
  # the file. The removal must come first, not somewhere after the bootstrap.
  local rm_line sshd_line
  rm_line=$(grep -n 'rm -f /\.krun_config\.json' "$ISOPOD_ENTRYPOINT" | cut -d: -f1)
  sshd_line=$(grep -n 'exec /usr/sbin/sshd' "$ISOPOD_ENTRYPOINT" | cut -d: -f1)
  [ -n "$rm_line" ] && [ -n "$sshd_line" ]
  [ "$rm_line" -lt "$sshd_line" ]
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

# ---- repo_subdir -------------------------------------------------------------
@test "repo_subdir strips .git and derives the basename" {
  run repo_subdir "https://github.com/me/proj.git"
  assert_output "proj"
}
@test "repo_subdir handles scp-style git@host:org/repo.git" {
  run repo_subdir "git@github.com:org/api.git"
  assert_output "api"
}
@test "repo_subdir handles scp-style with no path segment" {
  run repo_subdir "git@github.com:api.git"
  assert_output "api"
}
@test "repo_subdir ignores a trailing slash" {
  run repo_subdir "https://github.com/me/web/"
  assert_output "web"
}
@test "repo_subdir keeps a repo without a .git suffix" {
  run repo_subdir "https://github.com/me/web"
  assert_output "web"
}

# ---- json emission (--json output helpers) -------------------------------------
@test "json_escape escapes backslash, double-quote, and control characters" {
  run json_escape $'a\\b"c\td\ne'
  assert_output 'a\\b\"c\u0009d\u000ae'
}
@test "json_escape leaves plain strings unchanged" {
  run json_escape 'isopod-demo'
  assert_output 'isopod-demo'
}
@test "json_str_or_null quotes a value and maps empty to null" {
  run json_str_or_null 'teal'
  assert_output '"teal"'
  run json_str_or_null ''
  assert_output 'null'
}
@test "json_port_or_null emits an integer port and maps junk to null" {
  run json_port_or_null 4222
  assert_output '4222'
  run json_port_or_null '?'
  assert_output 'null'
  run json_port_or_null ''
  assert_output 'null'
}
@test "json_csv_array renders empty and populated lists" {
  run json_csv_array ''
  assert_output '[]'
  run json_csv_array '8080:8080,3001:3000'
  assert_output '["8080:8080","3001:3000"]'
}
@test "egress_status_json reports an active allow-list with a running proxy" {
  ISOPOD_EGRESS=allow-list
  egress_rules_loaded() { return 0; }
  egress_proxy_active() { return 0; }
  run egress_status_json
  assert_output '{"mode":"allow-list","firewall":"active","network":"isopod0","subnet":"10.88.7.0/24","dns":"1.1.1.1","proxy":{"running":true,"port":8118}}'
}
@test "egress_status_json maps a stopped proxy and an unloaded firewall" {
  ISOPOD_EGRESS=allow-list
  egress_rules_loaded() { return 1; }
  egress_proxy_active() { return 1; }
  run egress_status_json
  assert_output --partial '"firewall":"inactive"'
  assert_output --partial '"proxy":{"running":false,"port":8118}'
}
@test "egress_status_json emits mode off and a null proxy when egress is disabled" {
  ISOPOD_EGRESS=off
  egress_rules_loaded() { return 2; }
  run egress_status_json
  assert_output '{"mode":"off","firewall":"unknown","network":"isopod0","subnet":"10.88.7.0/24","dns":"1.1.1.1","proxy":null}'
}
@test "json_lines_array renders empty and populated input, skipping blanks" {
  run json_lines_array </dev/null
  assert_output '[]'
  run json_lines_array <<<$'a\n\nb.c'
  assert_output '["a","b.c"]'
}
@test "egress_allowlist_domains strips comments, blanks, and trailing tokens" {
  local f="$BATS_TEST_TMPDIR/base.conf"
  printf '# a comment\ngithub.com\n\n  *.anthropic.com  # inline\nexample.org extra-token\n' >"$f"
  run egress_allowlist_domains "$f"
  assert_line --index 0 'github.com'
  assert_line --index 1 '*.anthropic.com'
  assert_line --index 2 'example.org'
  assert_equal "${#lines[@]}" 3
}
@test "egress_allowlist_domains on a missing file emits nothing" {
  run egress_allowlist_domains "$BATS_TEST_TMPDIR/nope.conf"
  assert_success
  assert_output ''
}
@test "egress_allowlist_json splits baseline vs user" {
  ISOPOD_EGRESS_ALLOWLIST="$BATS_TEST_TMPDIR/base.conf"
  USER_EGRESS_ALLOWLIST="$BATS_TEST_TMPDIR/user.conf"
  printf 'github.com\n*.anthropic.com\n' >"$ISOPOD_EGRESS_ALLOWLIST"
  printf 'example.com\n' >"$USER_EGRESS_ALLOWLIST"
  run egress_allowlist_json
  assert_output '{"baseline":["github.com","*.anthropic.com"],"user":["example.com"]}'
}
@test "egress_allowlist_json emits empty arrays when no files exist" {
  ISOPOD_EGRESS_ALLOWLIST="$BATS_TEST_TMPDIR/none-base.conf"
  USER_EGRESS_ALLOWLIST="$BATS_TEST_TMPDIR/none-user.conf"
  run egress_allowlist_json
  assert_output '{"baseline":[],"user":[]}'
}
@test "egress_denied_json extracts unique refused hostnames from the proxy log" {
  ISOPOD_EGRESS_PROXY_LOG="$BATS_TEST_TMPDIR/proxy.log"
  printf 'CONNECT ok.example.com allowed\nFilter: denied tracker.evil.net\nrefused ads.evil.net\nFilter: denied tracker.evil.net\n' >"$ISOPOD_EGRESS_PROXY_LOG"
  egr_run_root() { "$@"; }
  run egress_denied_json
  assert_output '{"hostnames":["ads.evil.net","tracker.evil.net"]}'
}
@test "box_secret_names lists the NAME of each NAME:path spec" {
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nsecrets=ANTHROPIC_API_KEY:/run/secrets/ANTHROPIC_API_KEY,GH_TOKEN:/run/secrets/GH_TOKEN\n' >"$(box_dir demo)/meta"
  run box_secret_names demo
  assert_line --index 0 'ANTHROPIC_API_KEY'
  assert_line --index 1 'GH_TOKEN'
  assert_equal "${#lines[@]}" 2
}
@test "box_secret_names emits nothing when a box attaches no secrets" {
  mkdir -p "$(box_dir plain)"
  printf 'engine=podman\n' >"$(box_dir plain)/meta"
  run box_secret_names plain
  assert_output ''
}
@test "secret_ls_json reports backend, names, and per-box attribution" {
  ISOPOD_SECRET_BACKEND=file
  printf 'v1' | secret_store_set ANTHROPIC_API_KEY
  printf 'v2' | secret_store_set UNUSED_KEY
  mkdir -p "$(box_dir a)" "$(box_dir b)"
  printf 'engine=podman\nsecrets=ANTHROPIC_API_KEY:/run/secrets/ANTHROPIC_API_KEY\n' >"$(box_dir a)/meta"
  printf 'engine=podman\nsecrets=ANTHROPIC_API_KEY:/run/secrets/ANTHROPIC_API_KEY\n' >"$(box_dir b)/meta"
  run secret_ls_json
  assert_output '{"backend":"file","secrets":[{"name":"ANTHROPIC_API_KEY","boxes":["a","b"]},{"name":"UNUSED_KEY","boxes":[]}]}'
}
@test "secret_ls_json emits an empty secrets array when none are stored" {
  ISOPOD_SECRET_BACKEND=file
  run secret_ls_json
  assert_output '{"backend":"file","secrets":[]}'
}
@test "doctor_check_json emits a level/id/label/hint object" {
  run doctor_check_json warn git "git (fetch, remap)" "install git"
  assert_output '{"level":"warn","id":"git","label":"git (fetch, remap)","hint":"install git"}'
}
@test "doctor_json summarizes prerequisite checks and flags a missing engine" {
  HARDENING_CONF="$BATS_TEST_TMPDIR/hardening.conf"
  : >"$HARDENING_CONF"
  have() { case "$1" in ssh | ssh-keygen | ssh-keyscan | git) return 0 ;; *) return 1 ;; esac }
  active_egress() { printf 'lan-deny\n'; }
  run doctor_json
  assert_success
  assert_output --partial "\"version\":\"$ISOPOD_VERSION\""
  assert_output --partial '{"level":"ok","id":"ssh-tools"'
  assert_output --partial '{"level":"ok","id":"egress","label":"egress isolation","hint":"lan-deny"}'
  # No podman/docker on PATH -> a hard engine error.
  assert_output --partial '{"level":"error","id":"engine"'
}
@test "gc --json lists unreferenced isopod images without removing" {
  detect_engine() { ENGINE=podman; }
  podman() {
    [ "$1" = images ] &&
      printf 'localhost/isopod-base:v1\nlocalhost/isopod-box-abc:v1\nlocalhost/isopod-user:keep\ndocker.io/library/alpine:latest\n'
  }
  mkdir -p "$(box_dir demo)"
  printf 'engine=podman\nimage=localhost/isopod-user:keep\n' >"$(box_dir demo)/meta"
  run cmd_gc --json
  assert_output '{"images":["localhost/isopod-base:v1","localhost/isopod-box-abc:v1"]}'
}
@test "gc --json emits an empty array when nothing is unreferenced" {
  detect_engine() { ENGINE=podman; }
  podman() { [ "$1" = images ] && printf 'docker.io/library/alpine:latest\n'; }
  run cmd_gc --json
  assert_output '{"images":[]}'
}

# ---- rootless subuid/subgid ranges (Arch and Gentoo don't create one) --------
@test "subid_ranges_ok accepts a range recorded under the user name" {
  SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
  printf 'root:0:1\n%s:100000:65536\n' "$(id -un)" >"$SUBUID_FILE"
  cp "$SUBUID_FILE" "$SUBGID_FILE"
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '1000\n' ;; -un) command id -un ;; esac }
  run subid_ranges_ok
  assert_success
}
@test "subid_ranges_ok accepts a range recorded under the numeric uid" {
  SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
  printf '4242:100000:65536\n' >"$SUBUID_FILE"
  cp "$SUBUID_FILE" "$SUBGID_FILE"
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '4242\n' ;; -un) printf 'someone\n' ;; esac }
  run subid_ranges_ok
  assert_success
}
@test "subid_ranges_ok rejects a file that lists only other users" {
  SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
  printf 'someoneelse:100000:65536\n' >"$SUBUID_FILE"
  cp "$SUBUID_FILE" "$SUBGID_FILE"
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '4242\n' ;; -un) printf 'someone\n' ;; esac }
  run subid_ranges_ok
  assert_failure
}
@test "subid_ranges_ok rejects a subgid file with no entry (subuid alone is not enough)" {
  SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
  printf 'someone:100000:65536\n' >"$SUBUID_FILE"
  : >"$SUBGID_FILE"
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '4242\n' ;; -un) printf 'someone\n' ;; esac }
  run subid_ranges_ok
  assert_failure
}
@test "subid_ranges_ok rejects missing subuid/subgid files" {
  SUBUID_FILE="$BATS_TEST_TMPDIR/nope-subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/nope-subgid"
  is_linux() { return 0; }
  run subid_ranges_ok
  assert_failure
}
@test "subid_ranges_ok does not apply on macOS or as root" {
  SUBUID_FILE="$BATS_TEST_TMPDIR/nope-subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/nope-subgid"
  is_linux() { return 1; }
  run subid_ranges_ok
  assert_success
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '0\n' ;; -un) printf 'root\n' ;; esac }
  run subid_ranges_ok
  assert_success
}
@test "subid_fix_hint names the user and the usermod fix" {
  id() { case "$1" in -un) printf 'someone\n' ;; -u) printf '4242\n' ;; esac }
  run subid_fix_hint
  assert_success
  assert_output --partial "range for 'someone'"
  assert_output --partial 'usermod --add-subuids 100000-165535 --add-subgids 100000-165535 someone'
  assert_output --partial 'podman system migrate'
}
@test "doctor_json warns when rootless podman has no subuid range" {
  HARDENING_CONF="$BATS_TEST_TMPDIR/hardening.conf"
  : >"$HARDENING_CONF"
  SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
  : >"$SUBUID_FILE"
  : >"$SUBGID_FILE"
  have() { case "$1" in ssh | ssh-keygen | ssh-keyscan | git | podman) return 0 ;; *) return 1 ;; esac }
  podman() { return 1; } # installed, but `podman info` fails — the subid symptom
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '4242\n' ;; -un) printf 'someone\n' ;; esac }
  active_egress() { printf 'lan-deny\n'; }
  run doctor_json
  assert_success
  assert_output --partial '{"level":"warn","id":"subid"'
  assert_output --partial 'podman system migrate'
}
@test "doctor_json reports an ok subuid range when one exists" {
  HARDENING_CONF="$BATS_TEST_TMPDIR/hardening.conf"
  : >"$HARDENING_CONF"
  SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
  SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
  printf 'someone:100000:65536\n' >"$SUBUID_FILE"
  cp "$SUBUID_FILE" "$SUBGID_FILE"
  have() { case "$1" in ssh | ssh-keygen | ssh-keyscan | git | podman) return 0 ;; *) return 1 ;; esac }
  podman() { return 0; }
  is_linux() { return 0; }
  id() { case "$1" in -u) printf '4242\n' ;; -un) printf 'someone\n' ;; esac }
  active_egress() { printf 'lan-deny\n'; }
  run doctor_json
  assert_success
  assert_output --partial '{"level":"ok","id":"subid","label":"rootless subuid/subgid range","hint":""}'
}

# ---- export: a live workspace changing under tar -----------------------------
# tar runs inside the running box, so a file can change size/mtime mid-read
# (node_modules, a build dir, a lockfile). GNU tar then exits 1 with 'file
# changed as we read it' — a warning, not a corrupt archive. box_tar_out is
# mocked to emit a complete stream and return the exit code under test.
@test "export keeps the archive when the box tar warns (exit 1)" {
  seed="$TEST_TMP/seed"
  mkdir -p "$seed"
  echo micro >"$seed/f.txt"
  WORKSPACE=/home/dev/workspace
  open_box() { :; }
  box_tar_out() {
    tar -C "$seed" -cf - .
    return 1
  }
  run cmd_export demo "$TEST_TMP/out"
  assert_success
  assert_output --partial "point-in-time snapshot"
  assert [ -f "$TEST_TMP/out/f.txt" ]
}

# A real box-side failure (exit >= 2) must still fail loudly and leave no
# half-written export behind.
@test "export fails and removes the dest on a fatal box tar error (exit 2)" {
  seed="$TEST_TMP/seed"
  mkdir -p "$seed"
  echo x >"$seed/f.txt"
  WORKSPACE=/home/dev/workspace
  open_box() { :; }
  box_tar_out() {
    tar -C "$seed" -cf - .
    return 2
  }
  run cmd_export demo "$TEST_TMP/out"
  assert_failure
  assert_output --partial "export failed"
  assert [ ! -e "$TEST_TMP/out" ]
}

# --exclude / --gitignore are applied by the box-side tar. Capture the options
# box_tar_out is handed and confirm both reach it, with globs single-quoted so
# the box shell can't expand them before tar does.
@test "export forwards --exclude and --gitignore to the box tar" {
  seed="$TEST_TMP/seed"
  mkdir -p "$seed"
  echo x >"$seed/f.txt"
  WORKSPACE=/home/dev/workspace
  open_box() { :; }
  box_tar_out() {
    printf '%s\n' "$*" >"$TEST_TMP/opts"
    tar -C "$seed" -cf - .
  }
  run cmd_export demo "$TEST_TMP/out" --gitignore --exclude '*.log' --exclude=node_modules
  assert_success
  run cat "$TEST_TMP/opts"
  assert_output --partial "--exclude-vcs-ignores"
  assert_output --partial "--exclude='*.log'"
  assert_output --partial "--exclude='node_modules'"
}

@test "shq single-quotes a value so the box shell keeps globs literal" {
  run shq '*.log'
  assert_output "'*.log'"
  # re-parsing the quoted form in a fresh shell (as the box shell does) must
  # yield the original, embedded single quote and all
  local q
  q="$(shq "a'b*.log")"
  run bash -c "printf %s $q"
  assert_output "a'b*.log"
}

# ---- assert_safe_run_args (F-6) ----------------------------------------------
# ISOPOD_RUN_ARGS is word-split straight into the engine command line, so anything
# that can set it in the user's shell could turn a sandbox into a passthrough with
# no trace in the box or in `isopod info`. These assert the deny list holds for
# BOTH spelling forms — `--opt=value` and `--opt value` — because the space form
# needs lookahead state and is the form that silently slipped through first.

@test "assert_safe_run_args allows ordinary resource and publish flags" {
  run assert_safe_run_args --memory 4g --cpus 2 -p 127.0.0.1::2222 --dns 1.1.1.1
  assert_success
}

@test "assert_safe_run_args allows an empty argument list" {
  run assert_safe_run_args
  assert_success
}

@test "assert_safe_run_args refuses host filesystem exposure" {
  run assert_safe_run_args -v /:/host
  assert_failure
  run assert_safe_run_args --volume=/etc:/etc
  assert_failure
  run assert_safe_run_args --mount type=bind,src=/,dst=/host
  assert_failure
}

@test "assert_safe_run_args refuses restored privileges" {
  run assert_safe_run_args --privileged
  assert_failure
  run assert_safe_run_args --cap-add SYS_ADMIN
  assert_failure
  run assert_safe_run_args --security-opt seccomp=unconfined
  assert_failure
  run assert_safe_run_args --device /dev/kvm
  assert_failure
  run assert_safe_run_args --systemd always
  assert_failure
}

@test "assert_safe_run_args refuses shared host namespaces" {
  run assert_safe_run_args --userns=host
  assert_failure
  run assert_safe_run_args --pid host
  assert_failure
  run assert_safe_run_args --ipc=host
  assert_failure
  run assert_safe_run_args --uts host
  assert_failure
}

# --net/--network is the one pair whose safety depends on the VALUE, so it needs
# lookahead: the space form was accepted while the = form was refused.
@test "assert_safe_run_args refuses --network host in both spellings" {
  run assert_safe_run_args --network=host
  assert_failure
  run assert_safe_run_args --network host
  assert_failure
  run assert_safe_run_args --net=host
  assert_failure
  run assert_safe_run_args --net host
  assert_failure
}

@test "assert_safe_run_args refuses joining another container's netns" {
  run assert_safe_run_args --network container:victim
  assert_failure
  run assert_safe_run_args --net=container:victim
  assert_failure
}

# isopod picks the box's own network, so any OTHER value is a deliberate choice.
@test "assert_safe_run_args allows a named network" {
  run assert_safe_run_args --network isopod0
  assert_success
  run assert_safe_run_args --network=isopod0
  assert_success
}

# The scanner is positional: 'host' is only dangerous as a --net/--network value.
@test "assert_safe_run_args does not refuse a bare 'host' token elsewhere" {
  run assert_safe_run_args --dns host
  assert_success
}

@test "assert_safe_run_args scans every position, not just the first" {
  run assert_safe_run_args --memory 4g --cpus 2 -v /:/host
  assert_failure
}

@test "ISOPOD_ALLOW_UNSAFE_RUN_ARGS=1 is the deliberate override" {
  ISOPOD_ALLOW_UNSAFE_RUN_ARGS=1 run assert_safe_run_args --privileged -v /:/host
  assert_success
}

@test "the refusal names the offending flag and the override" {
  run assert_safe_run_args --privileged
  assert_failure
  assert_output --partial "--privileged"
  assert_output --partial "ISOPOD_ALLOW_UNSAFE_RUN_ARGS=1"
}

# ---- sanitize (F-5) ----------------------------------------------------------
# Box-controlled strings reach the host terminal (branch names, repo lists). The
# job is to strip terminal control sequences WITHOUT mangling legitimate text.

@test "sanitize strips escape sequences and DEL" {
  run sanitize "$(printf 'a\033[31mred\177b')"
  assert_output "a[31mredb"
}

@test "sanitize strips carriage returns (line-overwrite spoofing)" {
  run sanitize "$(printf 'real\rfake')"
  assert_output "realfake"
}

# 0x80-0x9F are UTF-8 continuation bytes, NOT C1 controls, in a UTF-8 locale.
# Stripping them would corrupt every non-ASCII branch name.
@test "sanitize leaves UTF-8 text intact" {
  run sanitize 'héllo — ✓ 日本語'
  assert_output 'héllo — ✓ 日本語'
}

@test "sanitize leaves ordinary text untouched" {
  run sanitize 'feature/add-thing_2'
  assert_output 'feature/add-thing_2'
}

# ---- valid_ident_email / valid_ident_name (F-5) ------------------------------
# The box supplies old_email to `isopod remap`, which builds a git filter. A
# newline or angle bracket there is a mailmap/argument injection.

@test "valid_ident_email accepts an ordinary address" {
  run valid_ident_email 'me@example.com'
  assert_success
}

@test "valid_ident_email rejects empty, space, and no-@ values" {
  run valid_ident_email ''
  assert_failure
  run valid_ident_email 'a b@example.com'
  assert_failure
  run valid_ident_email 'notanaddress'
  assert_failure
}

@test "valid_ident_email rejects newline and angle brackets" {
  run valid_ident_email "$(printf 'a@b.com\nx@y.com')"
  assert_failure
  run valid_ident_email "$(printf 'a@b.com\rx')"
  assert_failure
  run valid_ident_email 'a<b>@c.com'
  assert_failure
}

@test "valid_ident_name allows spaces but not newlines or brackets" {
  run valid_ident_name 'Real Name'
  assert_success
  run valid_ident_name ''
  assert_success
  run valid_ident_name 'Bad <injected@x>'
  assert_failure
  run valid_ident_name "$(printf 'a\nb')"
  assert_failure
}

# ---- box_is_stale / box_egress_posture (F-2, F-3) ----------------------------
# A minimal box on disk: just the meta file these readers consult.
mk_meta() { # mk_meta <name> <meta-line...>
  mkdir -p "$BOXES_DIR/$1"
  printf '%s\n' "${@:2}" >"$BOXES_DIR/$1/meta"
}

@test "box_is_stale reports current when the recorded image is what isopod builds today" {
  mk_meta demo 'base=docker.io/library/debian:bookworm-slim' 'dev=0' 'nested=0'
  local want
  want="$(box_wanted_base_tag demo)"
  mk_meta demo 'base=docker.io/library/debian:bookworm-slim' 'dev=0' 'nested=0' "base_image=$want"
  run box_is_stale demo
  assert_failure # rc 1 == up to date
}

@test "box_is_stale reports stale when the recorded image differs" {
  mk_meta demo 'base=docker.io/library/debian:bookworm-slim' 'dev=0' 'nested=0' \
    'base_image=localhost/isopod-base:deadbeefdeadbeef'
  run box_is_stale demo
  assert_success
}

# A box created before provenance was recorded has no base_image line. It
# predates every fix since, so absent must mean stale — never "assume current".
@test "box_is_stale treats a box with no recorded image as stale" {
  mk_meta demo 'base=docker.io/library/debian:bookworm-slim'
  run box_is_stale demo
  assert_success
}

# Staleness is only meaningful if the wanted tag tracks the build inputs: the
# lean, --dev and --nested images come from one Dockerfile but are not the same.
@test "box_wanted_base_tag separates the lean, dev and nested images" {
  mk_meta lean 'base=debian:bookworm-slim' 'dev=0' 'nested=0'
  mk_meta devbox 'base=debian:bookworm-slim' 'dev=1' 'nested=0'
  mk_meta nestbox 'base=debian:bookworm-slim' 'dev=0' 'nested=1'
  [ "$(box_wanted_base_tag lean)" != "$(box_wanted_base_tag devbox)" ]
  [ "$(box_wanted_base_tag lean)" != "$(box_wanted_base_tag nestbox)" ]
  [ "$(box_wanted_base_tag devbox)" != "$(box_wanted_base_tag nestbox)" ]
}

# The posture line reports what is IN FORCE, not what was asked for — a box whose
# egress degraded at create was previously indistinguishable from an isolated one
# once the create output scrolled away.
@test "box_egress_posture reports OPEN when host enforcement degraded" {
  mk_meta demo 'egress=allow-list' 'egress_degraded=1' 'guest_egress=on'
  run box_egress_posture demo
  assert_output --partial 'OPEN'
  assert_output --partial 'could not be applied'
}

@test "box_egress_posture names the host-enforced mode when it is in force" {
  mk_meta demo 'egress=allow-list' 'egress_degraded=0'
  run box_egress_posture demo
  assert_output 'allow-list (host-enforced)'
}

@test "box_egress_posture names the in-guest layer and its limits" {
  mk_meta demo 'guest_egress=on'
  run box_egress_posture demo
  assert_output --partial 'guest lan-deny'
  assert_output --partial 'not a hard boundary'
}

@test "box_egress_posture says OPEN when nothing isolates the box" {
  mk_meta demo 'guest_egress=off'
  run box_egress_posture demo
  assert_output 'OPEN — no egress isolation'
}

# ---- build_run_args: root key, sudo hardening, guest egress ------------------
# These assemble the engine command line, so they decide what a box actually IS.
# Driven directly (rather than through `create`) so each input can be varied on
# its own — including the combinations only `reconfigure` produces, where the
# create-time variables are unset and the persisted meta is the only source.
setup_run_args_box() { # setup_run_args_box <name> <meta-line...>
  mk_meta "$@"
  ENGINE=podman
  # Pin the two ambient facts these tests vary deliberately.
  is_microvm_runtime() { return 0; }
  active_egress() { printf ''; }
}

@test "build_run_args passes only the PUBLIC half of the administrative root key" {
  setup_run_args_box demo 'harden=off' 'sudo=0'
  printf 'PRIVATE-ROOT-KEY-MATERIAL\n' >"$BOXES_DIR/demo/id_ed25519_root"
  printf 'ssh-ed25519 AAAArootpub isopod-demo-root\n' >"$BOXES_DIR/demo/id_ed25519_root.pub"
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " == *"ISOPOD_ROOT_AUTHORIZED_KEY=ssh-ed25519 AAAArootpub"* ]]
  [[ " ${RUN_ARGS[*]} " != *"PRIVATE-ROOT-KEY-MATERIAL"* ]]
}

@test "build_run_args omits the root key env when the box has none (--no-root-key)" {
  setup_run_args_box demo 'harden=off' 'sudo=0'
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *ISOPOD_ROOT_AUTHORIZED_KEY* ]]
}

# On reconfigure BOX_SUDO is unset, so the persisted meta is the only source. An
# ABSENT key means a box built before the flag existed: it must keep behaving as
# it did, because no-new-privileges would break the sudo it already has.
@test "no-new-privileges follows the persisted sudo meta when BOX_SUDO is unset" {
  setup_run_args_box demo 'harden=off' 'sudo=0'
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " == *"no-new-privileges"* ]]

  setup_run_args_box demo 'harden=off' 'sudo=1'
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *"no-new-privileges"* ]]

  setup_run_args_box demo 'harden=off'
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *"no-new-privileges"* ]]
}

@test "guest egress is switched on for a microVM box that asked for it" {
  setup_run_args_box demo 'harden=off' 'sudo=0' 'guest_egress=on'
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " == *"ISOPOD_GUEST_EGRESS=1"* ]]
  [[ " ${RUN_ARGS[*]} " == *"ISOPOD_GUEST_EGRESS_DNS="* ]]
}

@test "guest egress stays off when the box asked for off" {
  setup_run_args_box demo 'harden=off' 'sudo=0' 'guest_egress=off'
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *ISOPOD_GUEST_EGRESS* ]]
}

# A container box shares the host kernel and its entrypoint has no CAP_NET_ADMIN,
# so it could not load the ruleset — asking would only hit the fail-closed path.
@test "guest egress is never asked of a non-microVM box" {
  setup_run_args_box demo 'harden=off' 'sudo=0' 'guest_egress=on'
  is_microvm_runtime() { return 1; }
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *ISOPOD_GUEST_EGRESS* ]]
}

# Host-side egress routes the box through a proxy on an RFC1918 bridge address —
# exactly what the guest ruleset drops. It is also stronger (it survives guest
# root), so the in-guest layer must yield to it rather than cut the box off.
@test "guest egress yields to host-side egress enforcement" {
  setup_run_args_box demo 'harden=off' 'sudo=0' 'guest_egress=on'
  active_egress() { printf 'allow-list'; }
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *ISOPOD_GUEST_EGRESS* ]]
}

# Regression guard. A box created before this feature has neither the nft binary
# nor /etc/isopod/egress-guest.nft, so enforcement hits the entrypoint's
# fail-closed path and the box comes back with no sshd — unreachable, from a
# `reconfigure` that changed nothing else. Absent meta must therefore mean OFF.
@test "a box predating guest egress is never asked to enforce it" {
  setup_run_args_box demo 'harden=off' 'sudo=0' # no guest_egress line at all
  build_run_args demo localhost/img 127.0.0.1::2222 '' ''
  [[ " ${RUN_ARGS[*]} " != *ISOPOD_GUEST_EGRESS* ]]
}

# ---- filter_repo_usable: a broken git-filter-repo must not be selected --------
# `git-filter-repo` is a Python program that imports the git_filter_repo module.
# A split install — pip and the distro package disagreeing about which
# interpreter owns the module — leaves the command on PATH and the import broken,
# so every invocation dies with ModuleNotFoundError. Presence is not usability.

# A git-filter-repo exactly as a broken install behaves: found, then fails.
_stub_broken_filter_repo() {
  cat >"$STUB_DIR/git-filter-repo" <<'EOF'
#!/usr/bin/env bash
echo "ModuleNotFoundError: No module named 'git_filter_repo'" >&2
exit 1
EOF
  chmod +x "$STUB_DIR/git-filter-repo"
}

@test "filter_repo_usable rejects a git-filter-repo whose module is missing" {
  _stub_broken_filter_repo
  run filter_repo_usable "$TEST_TMP"
  assert_failure
}

@test "filter_repo_usable accepts a git-filter-repo that runs" {
  make_stub git-filter-repo 0
  run filter_repo_usable "$TEST_TMP"
  assert_success
}

@test "filter_repo_usable is false when git-filter-repo is not installed" {
  run filter_repo_usable "$TEST_TMP"
  assert_failure
}

# doctor calls it with no repo argument, from wherever the user happens to be.
@test "filter_repo_usable works without a repo argument" {
  make_stub git-filter-repo 0
  run filter_repo_usable
  assert_success
  _stub_broken_filter_repo
  run filter_repo_usable
  assert_failure
}
