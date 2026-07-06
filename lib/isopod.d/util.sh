#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines logging, locking, exit cleanup, template rendering.

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
c_red=$'\033[31m'
c_grn=$'\033[32m'
c_yel=$'\033[33m'
c_rst=$'\033[0m'
# c_dim is referenced only from share/ templates, which shellcheck can't see.
# shellcheck disable=SC2034
c_dim=$'\033[2m'
info() { printf '%s\n' "${c_grn}==>${c_rst} $*"; }
warn() { printf '%s\n' "${c_yel}warning:${c_rst} $*" >&2; }
die() {
  printf '%s\n' "${c_red}error:${c_rst} $*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# Read stdin and echo a short, stable hex digest. Used for image cache tags,
# where a collision would reuse a stale image. sha256 (truncated) instead of
# cksum/CRC-32 so unrelated inputs can't share a tag. Portable: sha256sum on
# Linux, `shasum -a 256` on macOS.
sha_hex() {
  if have sha256sum; then sha256sum; else shasum -a 256; fi | awk '{print substr($1, 1, 16)}'
}

# Render a text template from share/ $vars and $(...) inside it resolve against
# the caller's locals/globals (bash dynamic
# scope). A sentinel byte protects trailing newlines (command substitution
# strips them) so separators like the blank line between ssh_config hosts survive.
#
# SECURITY INVARIANT: the template body is evaluated as a bash heredoc, so any
# $var or $(...) in a template executes. Templates may therefore interpolate
# ONLY values that are validated or isopod-controlled — a box name (checked by
# valid_name, no shell metacharacters), engine/meta-derived fields, or fixed
# strings. NEVER route an unvalidated user value (a raw repo URL, arbitrary file
# path, or free-form string) into a template, or it becomes a code-injection
# vector. Keep new template variables within this invariant.
render_tmpl() { # render_tmpl <file-under-share | /abs/path>
  # A relative name resolves under share/; an absolute path is used as-is (so
  # templates elsewhere, e.g. security/egress-host.nft, can be rendered too).
  local f="$1" body
  [ "${f#/}" = "$f" ] && f="$ISOPOD_SHARE/$f"
  [ -f "$f" ] || die "missing template: $f (is your isopod install complete?)"
  body=$(
    cat "$f"
    printf x
  )
  body="${body%x}"
  eval "cat <<EOF
${body}EOF"
}

# ---------------------------------------------------------------------------
# portable locking + exit cleanup
# ---------------------------------------------------------------------------
# A single advisory lock serializes the commands that rewrite shared state (the
# generated ssh_config and per-box meta files), so two concurrent invocations
# can't corrupt them or pick colliding ports/colors. We use an atomic `mkdir`
# rather than flock(1) because mkdir is atomic on every platform isopod runs on
# (Linux, macOS, Windows/WSL). A lock left behind by a crashed process is
# reclaimed via a POSIX `kill -0` liveness check.
LOCK_DIR=""
acquire_lock() {
  [ -n "$LOCK_DIR" ] && return 0 # already held by this process
  mkdir -p "$CONFIG_DIR"
  local lock="$CONFIG_DIR/.lock" tries=0 owner
  while ! mkdir "$lock" 2>/dev/null; do
    # A racer that reads pid in the brief window after the owner's mkdir but
    # before it writes pid (below) sees an empty owner: it does NOT reclaim
    # (the [ -n "$owner" ] guard), it just spins and retries — benign.
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock"
      continue # previous owner is gone — reclaim it
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 100 ] && die "another isopod command holds the lock ($lock).
    If no isopod is running it is stale; remove it:  rm -rf '$lock'"
    sleep 0.1
  done
  LOCK_DIR="$lock"
  printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
}
release_lock() {
  [ -n "$LOCK_DIR" ] || return 0
  rm -rf "$LOCK_DIR"
  LOCK_DIR=""
}

# One exit handler for the whole script: roll back a half-built box (only while
# CREATE_ROLLBACK_NAME is set by cmd_create mid-create) and always release the
# lock. Installed by main(), so sourcing the script for tests stays side-free.
CREATE_ROLLBACK_NAME=""
on_exit() {
  local rc=$?
  if [ -n "$CREATE_ROLLBACK_NAME" ]; then
    warn "create failed — rolling back partial sandbox '$CREATE_ROLLBACK_NAME'"
    if [ -n "${ENGINE:-}" ]; then
      "$ENGINE" rm -f "$(ctr_name "$CREATE_ROLLBACK_NAME")" >/dev/null 2>&1 || true
    fi
    rm -rf "$(box_dir "$CREATE_ROLLBACK_NAME")"
    write_ssh_include 2>/dev/null || true
  fi
  release_lock
  return "$rc"
}

usage() {
  render_tmpl usage.txt
}
