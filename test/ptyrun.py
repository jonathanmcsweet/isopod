#!/usr/bin/env python3
"""Run a command on a pty of a given size and print everything it wrote.

    ptyrun.py <rows> <cols> [--resize ROWSxCOLS] <command> [args...]

Test fixture for lib/topbar.py, which does nothing at all unless its stdout is a
terminal of a known size. Output goes to stdout as raw bytes, so a test can
assert on the escape sequences the command actually emitted.

--resize changes the pty size and signals the command once its first output has
arrived, which is how the resize path is exercised without a real window.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios

TIMEOUT = 10


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: ptyrun.py <rows> <cols> [--resize RxC] <command> [args...]\n")
        return 2
    rows, cols, rest = int(argv[1]), int(argv[2]), argv[3:]
    later = None
    if rest and rest[0] == "--resize":
        later = tuple(int(n) for n in rest[1].split("x"))
        rest = rest[2:]
    cmd = rest
    if not cmd:
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
        os._exit(127)
    set_size(fd, rows, cols)

    out = bytearray()
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], TIMEOUT)
        except InterruptedError:
            continue
        if not ready:
            break
        try:
            data = os.read(fd, 65536)
        except OSError:  # the child closed the pty
            break
        if not data:
            break
        out += data
        if later:  # the command is up and has painted; now move the window
            set_size(fd, later[0], later[1])
            os.kill(pid, signal.SIGWINCH)
            later = None
    os.waitpid(pid, 0)
    sys.stdout.buffer.write(bytes(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
