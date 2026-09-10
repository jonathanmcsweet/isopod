#!/usr/bin/env python3
"""Reserve the terminal's top row for a colored bar and run a command below it.

Usage: topbar.py <label> <#rrggbb> -- <command> [args...]

The command runs on a pty one row shorter than the real terminal, with the
scroll region set to rows 2..N and origin mode on, so the terminal itself maps
the command's row 1 to physical row 2. That is what keeps a full-screen TUI off
the bar without this program understanding a byte of what it draws: output is
relayed unchanged, and only three things need attention.

  1. Sequences that undo the arrangement: a new scroll region, origin mode off,
     a reset, or a switch to or from the alternate screen.
  2. Sequences that erase the whole display, which by definition ignore margins
     and take the bar with them.
  3. A resize.

After any of those the bar is repainted and the margins re-asserted. The bar is
never painted mid-sequence: a partial escape sequence or UTF-8 character at the
end of a read defers the repaint to the next one, since injecting into either
would corrupt it.

Fails open. Any problem setting this up and the command is exec'd directly, so a
bug here costs the bar rather than the session.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import tty

ESC = 0x1B
BEL = 0x07
READ = 65536


def die_open(argv):
    """Run the command with no bar at all. Every failure path lands here."""
    os.execvp(argv[0], argv)


# ---------------------------------------------------------------------------
# escape sequence scanning
# ---------------------------------------------------------------------------
# Enough of a parser to find where a sequence ends and to recognize the few that
# matter. It deliberately understands nothing else: everything unrecognized is
# relayed untouched.


def seq_end(data, i):
    """Index just past the escape sequence at data[i], or None if it is cut off."""
    n = len(data)
    j = i + 1
    if j >= n:
        return None
    b = data[j]
    if b == 0x5B:  # CSI: params, intermediates, then one final byte
        j += 1
        while j < n and 0x30 <= data[j] <= 0x3F:
            j += 1
        while j < n and 0x20 <= data[j] <= 0x2F:
            j += 1
        if j < n and 0x40 <= data[j] <= 0x7E:
            return j + 1
        return None
    if b in (0x5D, 0x50, 0x58, 0x5E, 0x5F):  # OSC/DCS/SOS/PM/APC: run to BEL or ST
        j += 1
        while j < n:
            if data[j] == BEL:
                return j + 1
            if data[j] == ESC:
                if j + 1 < n:
                    return j + 2 if data[j + 1] == 0x5C else None
                return None
            j += 1
        return None
    if 0x20 <= b <= 0x2F:  # intermediates then a final, e.g. ESC ( B
        while j < n and 0x20 <= data[j] <= 0x2F:
            j += 1
        if j < n and 0x30 <= data[j] <= 0x7E:
            return j + 1
        return None
    return j + 1  # two-byte sequence, e.g. ESC c or ESC 7


def damaging(seq):
    """Does this sequence move the command onto the bar row, or erase it?"""
    if seq == b"\x1bc":  # RIS, a full reset
        return True
    if not seq.startswith(b"\x1b["):
        return False
    params, final = seq[2:-1], seq[-1:]
    if final == b"r":  # a scroll region of the command's own
        return True
    if final == b"p" and params.endswith(b"!"):  # DECSTR, a soft reset
        return True
    if final == b"J" and params.lstrip(b"?") in (b"2", b"3"):  # erase all
        return True
    if final in (b"h", b"l") and params.startswith(b"?"):
        # 6 is origin mode; 47/1047/1049 switch screens, which re-homes things.
        modes = params[1:].split(b";")
        return any(m in (b"6", b"47", b"1047", b"1049") for m in modes)
    return False


def utf8_cut(data):
    """Does the buffer end part-way through a UTF-8 character?"""
    for back in range(1, min(4, len(data)) + 1):
        b = data[-back]
        if b < 0x80:
            return False
        if b >= 0xC0:  # a lead byte this near the end wants more continuations
            need = 2 if b < 0xE0 else 3 if b < 0xF0 else 4
            return back < need
    return False


class Scanner:
    """Tracks whether the stream is currently mid-sequence, and flags damage."""

    def __init__(self):
        self.tail = b""

    def feed(self, data):
        """Returns (damaged, safe_to_inject) for everything fed so far."""
        buf = self.tail + data
        damaged = False
        i = 0
        while i < len(buf):
            if buf[i] != ESC:
                i += 1
                continue
            end = seq_end(buf, i)
            if end is None:  # cut off: hold it and wait for the rest
                self.tail = buf[i:]
                return damaged, False
            if damaging(bytes(buf[i:end])):
                damaged = True
            i = end
        self.tail = b""
        return damaged, not utf8_cut(buf)


# ---------------------------------------------------------------------------
# mouse reports on the way in
# ---------------------------------------------------------------------------
# Origin mode offsets what the command DRAWS, but a mouse report carries physical
# screen coordinates and is not offset by anything. Left alone, a click on the
# command's first row arrives as row 2 and it acts on the wrong line, which for a
# menu means selecting the wrong entry. Every report on the way in therefore has
# its row decremented, in the two encodings a terminal actually sends.


def shift_mouse(data):
    """Move mouse rows up one, to match the row the command believes it is on."""
    if b"\x1b[" not in data:
        return data
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        if data[i] != ESC or i + 2 >= n or data[i + 1] != 0x5B:
            out.append(data[i])
            i += 1
            continue
        if data[i + 2] == 0x3C:  # SGR: ESC [ < b ; x ; y (M|m), mode 1006
            end = seq_end(data, i)
            if end is None:
                out += data[i:]
                return bytes(out)
            body = bytes(data[i + 3 : end - 1])
            final = data[end - 1 : end]
            parts = body.split(b";")
            if len(parts) == 3 and all(p.isdigit() for p in parts):
                row = max(1, int(parts[2]) - 1)
                out += b"\x1b[<%s;%s;%d" % (parts[0], parts[1], row)
                out += final
                i = end
                continue
            out += data[i:end]
            i = end
            continue
        if data[i + 2] == 0x4D:  # X10: ESC [ M then three bytes of value + 32
            if i + 6 > n:  # cut off mid-report
                out += data[i:]
                return bytes(out)
            btn, col, row = data[i + 3], data[i + 4], data[i + 5]
            out += b"\x1b[M" + bytes([btn, col, max(33, row - 1)])
            i += 6
            continue
        out.append(data[i])
        i += 1
    return bytes(out)


# ---------------------------------------------------------------------------
# the bar
# ---------------------------------------------------------------------------


def bar_line(label, rgb, cols):
    r, g, b = rgb
    # Relative luminance decides the text color, so a pale box color stays
    # readable instead of turning into white on white.
    lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    fg = (0, 0, 0) if lum > 0.55 else (255, 255, 255)
    text = (" " + label).ljust(cols)[:cols]
    return ("\x1b[48;2;%d;%d;%dm\x1b[38;2;%d;%d;%dm\x1b[1m%s\x1b[0m" % (r, g, b, fg[0], fg[1], fg[2], text)).encode()


def paint(out, label, rgb, rows, cols):
    """Re-assert the arrangement and redraw the bar.

    Origin mode has to come off to reach physical row 1 at all, and changing it
    homes the cursor by definition, so this leaves the cursor at the top of the
    region rather than where the command had it. Saving and restoring around it
    does not help: DECRC restores the origin mode saved with the position, which
    is exactly the setting being changed, and it would also overwrite the
    command's own saved cursor, since a terminal keeps only one slot.

    That is affordable because a repaint only ever follows damage: a full erase,
    a screen switch, a reset, or a resize. A command doing any of those redraws
    from scratch straight afterwards and positions absolutely as it goes.
    """
    seq = b"".join(
        [
            b"\x1b[?6l",  # origin mode off: row 1 means physical row 1
            b"\x1b[1;1H",
            bar_line(label, rgb, cols),
            b"\x1b[2;%dr" % rows,  # scroll region: everything below the bar
            b"\x1b[?6h",  # origin mode on: the command's row 1 is row 2
        ]
    )
    os.write(out, seq)


def teardown(out):
    """Origin mode off, margins back to the whole screen, and erase the bar."""
    os.write(out, b"\x1b[?6l\x1b[r\x1b[1;1H\x1b[2K")


# ---------------------------------------------------------------------------


def term_size(fd):
    rows, cols = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    return rows, cols


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def relay(fd, label, rgb, out):
    scanner = Scanner()
    pending_paint = False
    resized = [False]

    def on_winch(_sig, _frm):
        resized[0] = True

    signal.signal(signal.SIGWINCH, on_winch)

    rows, cols = term_size(out)
    set_size(fd, max(rows - 1, 1), cols)
    paint(out, label, rgb, rows, cols)

    while True:
        if resized[0]:
            resized[0] = False
            rows, cols = term_size(out)
            set_size(fd, max(rows - 1, 1), cols)
            paint(out, label, rgb, rows, cols)
        try:
            ready, _, _ = select.select([fd, 0], [], [])
        except InterruptedError:
            continue
        if 0 in ready:
            data = os.read(0, READ)
            if not data:
                break
            os.write(fd, shift_mouse(data))
        if fd in ready:
            try:
                data = os.read(fd, READ)
            except OSError:
                break
            if not data:
                break
            os.write(out, data)
            damaged, safe = scanner.feed(data)
            pending_paint = pending_paint or damaged
            if pending_paint and safe:
                pending_paint = False
                paint(out, label, rgb, rows, cols)


def main(argv):
    if len(argv) < 4 or "--" not in argv:
        sys.stderr.write("usage: topbar.py <label> <#rrggbb> -- <command> [args...]\n")
        return 2
    split = argv.index("--")
    label, color = argv[1], argv[2]
    cmd = argv[split + 1 :]
    if not cmd:
        return 2

    color = color.lstrip("#")
    try:
        if len(color) != 6:
            raise ValueError(color)
        rgb = tuple(int(color[i : i + 2], 16) for i in (0, 2, 4))
        if not os.isatty(0) or not os.isatty(1):
            raise OSError("not a terminal")
        rows, _cols = term_size(1)
        if rows < 4:  # nothing to spare
            raise OSError("terminal too short")
    except Exception:
        die_open(cmd)

    try:
        pid, fd = pty.fork()
    except Exception:
        die_open(cmd)
    if pid == 0:
        os.execvp(cmd[0], cmd)
        os._exit(127)

    saved = None
    try:
        saved = termios.tcgetattr(0)
        tty.setraw(0)
    except termios.error:
        saved = None
    try:
        relay(fd, label, rgb, 1)
    except (OSError, KeyboardInterrupt):
        pass
    finally:
        try:
            teardown(1)
        except OSError:
            pass
        if saved is not None:
            try:
                termios.tcsetattr(0, termios.TCSADRAIN, saved)
            except termios.error:
                pass
        os.close(fd)

    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
