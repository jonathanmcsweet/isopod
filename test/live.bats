#!/usr/bin/env bats
# LIVE end-to-end tests. These create REAL containers and exercise the true
# isolation guarantees — no stubs. They are slow and require a working podman
# (or docker), so they are skipped unless RUN_LIVE=1 is set.
#
#   RUN_LIVE=1 test/libs/bats-core/bin/bats test/live.bats
#
# Optional env:
#   AIBOX_TEST_IMAGE   base image to use (default: debian:bookworm-slim)
#   AIBOX_BUILD_ARGS   passed through to the engine build (e.g. --network=host)

setup_file() {
  if [ "${RUN_LIVE:-0}" != "1" ]; then
    skip "live tests disabled (set RUN_LIVE=1 to enable)"
  fi
}

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  if [ "${RUN_LIVE:-0}" != "1" ]; then skip "live tests disabled"; fi
  aibox_setup_env
  # real engine, real ssh — only HOME/config are sandboxed
  BOX="livetest-$$-${BATS_TEST_NUMBER}"
  export BOX
  export IMG="${AIBOX_TEST_IMAGE:-debian:bookworm-slim}"
}

teardown() {
  [ "${RUN_LIVE:-0}" = "1" ] || return 0
  "$AIBOX_ROOT/aibox" rm "$BOX" --force >/dev/null 2>&1 || true
  aibox_teardown_env
}

# Connect using the box's own key/port/known_hosts explicitly — mirrors the
# script's internal box_ssh, and avoids depending on ~/.ssh/config resolution
# (OpenSSH reads the real user's config, not $HOME's, so -F is what we use).
bssh() { # bssh <ssh-options...> -- <remote command...>   (-- optional)
  local cfg="$AIBOX_CONFIG_DIR/boxes/$BOX"
  local port; port=$(sed -n 's/^port=//p' "$cfg/meta")
  local -a opts=() rcmd=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; rcmd=("$@"); break ;;
      -o) opts+=("$1" "$2"); shift 2 ;;
      -*) opts+=("$1"); shift ;;
      *)  rcmd=("$@"); break ;;
    esac
  done
  ssh -p "$port" -i "$cfg/id_ed25519" -o IdentitiesOnly=yes \
      -o UserKnownHostsFile="$cfg/known_hosts" -o StrictHostKeyChecking=yes \
      "${opts[@]}" "dev@127.0.0.1" "${rcmd[@]}"
}

@test "live: a created box is reachable over ssh as the dev user" {
  run "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG"
  assert_success
  run bssh -- whoami
  assert_success
  assert_output "dev"
}

@test "live: the box cannot see host files (no bind mounts)" {
  marker="$TEST_TMP/HOST_SECRET_$$"
  echo "secret" > "$marker"
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG"
  # the marker path must not exist inside the container
  run bssh -- test -e "$marker"
  assert_failure
  # and there should be zero bind mounts into the workspace
  run bssh -- sh -c 'mount | grep -c "/home/dev/workspace" || true'
  assert_output "0"
}

@test "live: --copy ingests a folder as a copy, and deleting it in-box spares the host" {
  src="$TEST_TMP/proj"; mkdir -p "$src"; echo "original" > "$src/file.txt"
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG" --copy "$src"
  # file is present in the box
  run bssh -- cat /home/dev/workspace/proj/file.txt
  assert_output "original"
  # simulate a destructive agent inside the box
  bssh -- rm -rf /home/dev/workspace/proj
  # host original is untouched
  run cat "$src/file.txt"
  assert_output "original"
}

@test "live: agent forwarding is refused by the box" {
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG"
  # even if a client asks for agent forwarding, sshd config disallows it, so
  # no agent socket is set up in the box. printenv exits non-zero / empty when
  # the var is unset; we assert the box reports it as unset.
  run bssh -o ForwardAgent=yes -- printenv SSH_AUTH_SOCK
  # printenv returns failure (var absent) -> empty output, nonzero status
  assert_output ""
  assert_failure
}

@test "live: color settings are written inside the box workspace" {
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG" --color teal
  run bssh -- \
        cat /home/dev/workspace/.vscode/settings.json
  assert_success
  assert_output --partial "#0f766e"
}

@test "live: stop then start preserves the box and reconnects" {
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG"
  "$AIBOX_ROOT/aibox" stop "$BOX"
  run "$AIBOX_ROOT/aibox" start "$BOX"
  assert_success
  run bssh -o ConnectTimeout=10 -- true
  assert_success
}

@test "live: fetch pulls the box's git history into a host repo" {
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG"
  # make a commit on a branch inside the box's workspace
  bssh -- sh -c '
    cd /home/dev/workspace &&
    git init -q -b main &&
    git config user.email t@t && git config user.name t &&
    echo hi > f.txt && git add f.txt && git commit -qm "feat: seed" &&
    git switch -q -c feature/x && echo more >> f.txt && git commit -qam "feat: more"'
  # an empty host repo to receive the history
  host_repo="$TEST_TMP/host-repo"; mkdir -p "$host_repo"
  git -C "$host_repo" init -q
  run "$AIBOX_ROOT/aibox" fetch "$BOX" "$host_repo"
  assert_success
  # the box branches now exist as <BOX>/* remote-tracking refs
  run git -C "$host_repo" branch -r --list "$BOX/*"
  assert_output --partial "$BOX/feature/x"
  assert_output --partial "$BOX/main"
  # and the commits are real/checkoutable
  run git -C "$host_repo" log --oneline "$BOX/feature/x"
  assert_output --partial "feat: more"
}

@test "live: rm destroys the container" {
  "$AIBOX_ROOT/aibox" create "$BOX" --image "$IMG"
  "$AIBOX_ROOT/aibox" rm "$BOX" --force
  run bash -c "podman inspect aibox-$BOX >/dev/null 2>&1 || docker inspect aibox-$BOX >/dev/null 2>&1"
  assert_failure
}
