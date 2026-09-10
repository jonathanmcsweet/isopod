#!/usr/bin/env python3
"""Run a command on a pty of a given size and print everything it wrote.

    ptyrun.py <rows> <cols> <command> [args...]

Test fixture for lib/topbar.py, which does nothing at all unless its stdout is a
terminal of a known size. Output goes to stdout as raw bytes, so a test can
assert on the escape sequences the command actually emitted.
"""

import fcntl
import os
import pty
import select
import struct
import sys
import termios

TIMEOUT = 10


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: ptyrun.py <rows> <cols> <command> [args...]\n")
        return 2
    rows, cols, cmd = int(argv[1]), int(argv[2]), argv[3:]

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

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
    os.waitpid(pid, 0)
    sys.stdout.buffer.write(bytes(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
