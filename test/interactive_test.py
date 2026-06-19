#!/usr/bin/env python3
"""
Interactive (pty) tests for aibox — the "Playwright for terminals" layer.

bats with `run` captures exit code and output but cannot answer a live
prompt. These tests drive aibox through a real pseudo-terminal with pexpect,
typing into prompts and asserting on what is rendered, then checking the
resulting side effects on disk.

Engine and ssh are stubbed exactly like the bats integration suite, so no
container runtime is needed.

Run directly:  python3 test/interactive_test.py
Exit code 0 = all passed.
"""
import os
import shutil
import subprocess
import sys
import tempfile

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AIBOX = os.path.join(ROOT, "aibox")

PODMAN_STUB = r"""#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
cmd="$1"; shift || true
case "$cmd" in
  info) exit 0 ;;
  image) exit 1 ;;
  build) exit 0 ;;
  run) echo deadbeef; exit 0 ;;
  port) echo "127.0.0.1:45678" ;;
  exec) exit 0 ;;
  cp) exit 0 ;;
  inspect) echo running ;;
  start|stop|rm) exit 0 ;;
  *) exit 0 ;;
esac
"""

KEYGEN_STUB = r"""#!/usr/bin/env bash
echo "ssh-keygen $*" >> "$STUB_LOG"
path=""; prev=""
for a in "$@"; do [ "$prev" = "-f" ] && path="$a"; prev="$a"; done
if [ -n "$path" ]; then echo PRIV > "$path"; echo "ssh-ed25519 AAAA x" > "$path.pub"; fi
exit 0
"""

KEYSCAN_STUB = r"""#!/usr/bin/env bash
echo "ssh-keyscan $*" >> "$STUB_LOG"
echo "[127.0.0.1]:45678 ssh-ed25519 AAAAhostkey"
exit 0
"""

SSH_STUB = """#!/usr/bin/env bash
echo "ssh $*" >> "$STUB_LOG"
exit 0
"""

FLATPAK_STUB = """#!/usr/bin/env bash
exit 1
"""


class Env:
    """A hermetic environment with stubbed engine/ssh, like the bats helper."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="aibox-itest.")
        self.home = os.path.join(self.tmp, "home")
        self.config = os.path.join(self.home, ".config", "aibox")
        self.stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(os.path.join(self.home, ".ssh"))
        os.makedirs(self.stubs)
        self.stub_log = os.path.join(self.tmp, "calls.log")
        open(self.stub_log, "w").close()
        for name, body in [
            ("podman", PODMAN_STUB), ("ssh-keygen", KEYGEN_STUB),
            ("ssh-keyscan", KEYSCAN_STUB), ("ssh", SSH_STUB),
            ("flatpak", FLATPAK_STUB),
        ]:
            p = os.path.join(self.stubs, name)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, 0o755)

    def osenv(self):
        e = os.environ.copy()
        e["HOME"] = self.home
        e["AIBOX_CONFIG_DIR"] = self.config
        e["STUB_LOG"] = self.stub_log
        e["PATH"] = self.stubs + os.pathsep + e["PATH"]
        return e

    def run(self, *args):
        return subprocess.run([AIBOX, *args], env=self.osenv(),
                              capture_output=True, text=True)

    def spawn(self, *args):
        return pexpect.spawn(AIBOX, list(args), env=self.osenv(),
                             encoding="utf-8", timeout=15)

    def box_exists(self, name):
        return os.path.isdir(os.path.join(self.config, "boxes", name))

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


PASS, FAIL = 0, 0


def check(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


def test_rm_prompt_yes_deletes():
    env = Env()
    try:
        env.run("create", "demo", "--color", "teal")
        check(env.box_exists("demo"), "box created for prompt test")
        child = env.spawn("rm", "demo")
        child.expect(r"Delete sandbox 'demo'\?")
        child.sendline("y")
        child.expect(pexpect.EOF)
        check(not env.box_exists("demo"), "answering 'y' deletes the box")
    finally:
        env.cleanup()


def test_rm_prompt_no_keeps():
    env = Env()
    try:
        env.run("create", "demo", "--color", "teal")
        child = env.spawn("rm", "demo")
        child.expect(r"Delete sandbox 'demo'\?")
        child.sendline("n")
        child.expect(pexpect.EOF)
        check(env.box_exists("demo"), "answering 'n' keeps the box")
    finally:
        env.cleanup()


def test_rm_prompt_empty_defaults_to_no():
    env = Env()
    try:
        env.run("create", "demo", "--color", "teal")
        child = env.spawn("rm", "demo")
        child.expect(r"Delete sandbox 'demo'\?")
        child.sendline("")  # just hit enter; default is N
        child.expect(pexpect.EOF)
        check(env.box_exists("demo"), "empty answer defaults to keeping the box")
    finally:
        env.cleanup()


def test_rm_force_skips_prompt():
    env = Env()
    try:
        env.run("create", "demo", "--color", "teal")
        child = env.spawn("rm", "demo", "--force")
        # should reach EOF without ever printing the prompt
        idx = child.expect([r"Delete sandbox", pexpect.EOF])
        check(idx == 1, "--force skips the confirmation prompt")
        check(not env.box_exists("demo"), "--force still deletes the box")
    finally:
        env.cleanup()


def main():
    tests = [
        test_rm_prompt_yes_deletes,
        test_rm_prompt_no_keeps,
        test_rm_prompt_empty_defaults_to_no,
        test_rm_force_skips_prompt,
    ]
    for t in tests:
        print(t.__name__)
        try:
            t()
        except Exception as exc:  # noqa: BLE001
            global FAIL
            FAIL += 1
            print(f"  FAIL {t.__name__}: {exc!r}")
    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
