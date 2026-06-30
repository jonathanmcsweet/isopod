#!/usr/bin/env bats
# LIVE end-to-end tests. These create REAL containers and exercise the true
# isolation guarantees — no stubs. They are slow and require a working podman
# (or docker), so they are skipped unless RUN_LIVE=1 is set.
#
#   RUN_LIVE=1 test/libs/bats-core/bin/bats test/live.bats
#
# Optional env:
#   ISOPOD_TEST_IMAGE   base image to use (default: debian:bookworm-slim)
#   ISOPOD_BUILD_ARGS   passed through to the engine build (e.g. --network=host)

setup_file() {
  if [ "${RUN_LIVE:-0}" != "1" ]; then
    skip "live tests disabled (set RUN_LIVE=1 to enable)"
  fi
}

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  if [ "${RUN_LIVE:-0}" != "1" ]; then skip "live tests disabled"; fi
  isopod_setup_env
  # real engine, real ssh — only HOME/config are sandboxed
  BOX="livetest-$$-${BATS_TEST_NUMBER}"
  export BOX
  export IMG="${ISOPOD_TEST_IMAGE:-debian:bookworm-slim}"
}

teardown() {
  [ "${RUN_LIVE:-0}" = "1" ] || return 0
  "$ISOPOD_ROOT/isopod" rm "$BOX" --force >/dev/null 2>&1 || true
  isopod_teardown_env
}

# Connect using the box's own key/port/known_hosts explicitly — mirrors the
# script's internal box_ssh, and avoids depending on ~/.ssh/config resolution
# (OpenSSH reads the real user's config, not $HOME's, so -F is what we use).
bssh() { # bssh <ssh-options...> -- <remote command...>   (-- optional)
  local cfg="$ISOPOD_CONFIG_DIR/boxes/$BOX"
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
  run "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  assert_success
  run bssh -- whoami
  assert_success
  assert_output "dev"
}

@test "live: the box cannot see host files (no bind mounts)" {
  marker="$TEST_TMP/HOST_SECRET_$$"
  echo "secret" > "$marker"
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  # the marker path must not exist inside the container
  run bssh -- test -e "$marker"
  assert_failure
  # and there should be zero bind mounts into the workspace
  run bssh -- sh -c 'mount | grep -c "/home/dev/workspace" || true'
  assert_output "0"
}

@test "live: --copy ingests a folder as a copy, and deleting it in-box spares the host" {
  src="$TEST_TMP/proj"; mkdir -p "$src"; echo "original" > "$src/file.txt"
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG" --copy "$src"
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
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  # even if a client asks for agent forwarding, sshd config disallows it, so
  # no agent socket is set up in the box. printenv exits non-zero / empty when
  # the var is unset; we assert the box reports it as unset.
  run bssh -o ForwardAgent=yes -- printenv SSH_AUTH_SOCK
  # printenv returns failure (var absent) -> empty output, nonzero status
  assert_output ""
  assert_failure
}

@test "live: color settings are written inside the box workspace" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG" --color teal
  run bssh -- \
        cat /home/dev/workspace/.vscode/settings.json
  assert_success
  assert_output --partial "#0f766e"
}

@test "live: stop then start preserves the box and reconnects" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  "$ISOPOD_ROOT/isopod" stop "$BOX"
  run "$ISOPOD_ROOT/isopod" start "$BOX"
  assert_success
  run bssh -o ConnectTimeout=10 -- true
  assert_success
}

@test "live: fetch pulls the box's git history into a host repo" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
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
  run "$ISOPOD_ROOT/isopod" fetch "$BOX" "$host_repo"
  assert_success
  # the box branches now exist as <BOX>/* remote-tracking refs
  run git -C "$host_repo" branch -r --list "$BOX/*"
  assert_output --partial "$BOX/feature/x"
  assert_output --partial "$BOX/main"
  # and the commits are real/checkoutable
  run git -C "$host_repo" log --oneline "$BOX/feature/x"
  assert_output --partial "feat: more"
}

@test "live: fetch to a non-repo writes a bundle a clone checks out on the box's branch" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  # commit on main, then leave the box checked out on a feature branch
  bssh -- sh -c '
    cd /home/dev/workspace &&
    git init -q -b main &&
    git config user.email t@t && git config user.name t &&
    echo hi > f.txt && git add f.txt && git commit -qm "feat: seed" &&
    git switch -q -c feature/x && echo more >> f.txt && git commit -qam "feat: more"'
  # target is NOT a git repo, so fetch should drop a .bundle file
  out_dir="$TEST_TMP/plain"; mkdir -p "$out_dir"
  run "$ISOPOD_ROOT/isopod" fetch "$BOX" "$out_dir"
  assert_success
  bundle="$out_dir/isopod-$BOX.bundle"
  [ -f "$bundle" ]
  # cloning the bundle must check out the box's CURRENT branch (feature/x),
  # not guess main — this is what including HEAD in the bundle guarantees
  git clone -q "$bundle" "$TEST_TMP/cloned"
  run git -C "$TEST_TMP/cloned" rev-parse --abbrev-ref HEAD
  assert_output "feature/x"
  # and other branches remain checkoutable by bare name (origin is configured)
  run git -C "$TEST_TMP/cloned" checkout main
  assert_success
}

@test "live: re-fetch after the box rewrites history force-updates tracking refs" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  bssh -- sh -c '
    cd /home/dev/workspace &&
    git init -q -b main &&
    git config user.email t@t && git config user.name t &&
    echo hi > f.txt && git add f.txt && git commit -qm "feat: seed"'
  host_repo="$TEST_TMP/host-repo"; mkdir -p "$host_repo"
  git -C "$host_repo" init -q

  run "$ISOPOD_ROOT/isopod" fetch "$BOX" "$host_repo"
  assert_success
  orig="$(git -C "$host_repo" rev-parse "$BOX/main")"

  # Rewrite main in the box so its tip is no longer a descendant of what we
  # already fetched — mirrors what 'isopod remap' does (new commit SHAs).
  bssh -- sh -c '
    cd /home/dev/workspace &&
    git commit -q --amend --no-edit --reset-author -m "feat: seed (rewritten)"'

  # The second fetch must force-update isopod/main, not reject it.
  run "$ISOPOD_ROOT/isopod" fetch "$BOX" "$host_repo"
  assert_success
  refute_output --partial "non-fast-forward"
  new="$(git -C "$host_repo" rev-parse "$BOX/main")"
  [ "$new" != "$orig" ]
  run git -C "$host_repo" log --oneline "$BOX/main"
  assert_output --partial "rewritten"
}

@test "live: --expose publishes a box server to the host" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG" --expose 18081:8080
  # serve a known string from :8080 inside the box
  bssh -- sh -c 'cd /home/dev/workspace && echo expose-ok > index.html &&
                 setsid python3 -m http.server 8080 >/dev/null 2>&1 < /dev/null &
                 sleep 1'
  run bash -c 'for i in $(seq 1 10); do
                 curl -fsS http://127.0.0.1:18081/ && exit 0; sleep 0.5; done; exit 1'
  assert_success
  assert_output --partial "expose-ok"
}

@test "live: --dockerfile bakes a tool into the image before the box starts" {
  df="$TEST_TMP/Dockerfile"
  printf 'FROM %s\nRUN touch /opt/isopod-dockerfile-marker\n' "$IMG" > "$df"
  "$ISOPOD_ROOT/isopod" create "$BOX" --dockerfile "$df"
  run bssh -- test -f /opt/isopod-dockerfile-marker
  assert_success
}

@test "live: --dockerfile base ending in a non-root USER still yields a working box" {
  # isopod's layer resets to root, so sshd (PID 1) and the sudoers/key injection
  # still work even though the base image ends as a non-root user.
  df="$TEST_TMP/Dockerfile"
  printf 'FROM %s\nUSER nobody\n' "$IMG" > "$df"
  "$ISOPOD_ROOT/isopod" create "$BOX" --dockerfile "$df"
  run bssh -- whoami
  assert_success
  assert_output "dev"
}

@test "live: rm destroys the container" {
  "$ISOPOD_ROOT/isopod" create "$BOX" --image "$IMG"
  "$ISOPOD_ROOT/isopod" rm "$BOX" --force
  run bash -c "podman inspect isopod-$BOX >/dev/null 2>&1 || docker inspect isopod-$BOX >/dev/null 2>&1"
  assert_failure
}
