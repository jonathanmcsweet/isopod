#!/usr/bin/env python3
"""Rewrite author/committer/tagger identities in a git fast-export stream.

Used by `isopod remap` (the no-extra-tooling fallback when git-filter-repo is
absent): the box's refs are piped through `git fast-export`, this filter on
stdin, and back into `git fast-import`. Unlike apply_color.py this runs on the
HOST, not inside a box.

Reads the fast-export stream on stdin and writes the rewritten stream on stdout.
Identities are matched and replaced according to a git mailmap (gitmailmap(5)),
so a single invocation can remap many identities at once. The parser honours
fast-export's counted `data <n>` payloads, so identity-looking lines inside a
commit message or blob are never touched.

Environment:
  MAILMAP_FILE  path to a mailmap file (required). Each non-comment line maps a
                commit identity to a proper one, in any of the four forms:
                    Proper Name <commit-email>
                    <proper-email> <commit-email>
                    Proper Name <proper-email> <commit-email>
                    Proper Name <proper-email> Commit Name <commit-email>
                The last <…> is the commit (old) email matched against; a name
                before it is an extra match on the commit name. Email matching is
                case-insensitive; name matching is exact.
"""
import os
import re
import sys

ANGLE = re.compile(rb"<([^>]*)>")
IDENT = re.compile(rb"^(author|committer|tagger) (.*) <([^>]*)> (.*)$")


def parse_mailmap(data):
    """Return {commit_email_lower: [(commit_name|None, new_name|None, new_email|None)]}."""
    entries = {}
    for raw in data.split(b"\n"):
        line = raw.strip()
        if not line or line.startswith(b"#"):
            continue
        emails = list(ANGLE.finditer(line))
        if not emails:
            continue
        if len(emails) == 1:
            e = emails[0]
            new_name = line[: e.start()].strip() or None
            new_email = None
            commit_name = None
            commit_email = e.group(1)
        else:
            e1, e2 = emails[0], emails[1]
            new_name = line[: e1.start()].strip() or None
            new_email = e1.group(1) or None
            commit_name = line[e1.end() : e2.start()].strip() or None
            commit_email = e2.group(1)
        entries.setdefault(commit_email.lower(), []).append(
            (commit_name, new_name, new_email)
        )
    return entries


def resolve(entries, name, email):
    """Return (new_name, new_email) for an identity, or None if unmapped."""
    cands = entries.get(email.lower())
    if not cands:
        return None
    generic = None
    for commit_name, new_name, new_email in cands:
        if commit_name is None:
            if generic is None:  # first email-only entry wins
                generic = (new_name, new_email)
        elif commit_name == name:  # name-specific entry takes precedence
            return (new_name, new_email)
    return generic


def copy_exact(src, dst, count):
    """Copy exactly ``count`` bytes from src to dst in bounded chunks."""
    remaining = count
    while remaining > 0:
        chunk = src.read(min(remaining, 1 << 16))
        if not chunk:  # truncated stream — nothing more to copy
            break
        dst.write(chunk)
        remaining -= len(chunk)


def main():
    path = os.environ["MAILMAP_FILE"]
    with open(path, "rb") as fh:
        entries = parse_mailmap(fh.read())

    inp = sys.stdin.buffer
    out = sys.stdout.buffer
    # Stream line-by-line rather than reading the whole fast-export into memory,
    # so a repo with a very large history doesn't inflate the process. A
    # `data <n>` line introduces a counted binary payload copied through verbatim
    # (this is why identity-looking text inside a commit message is never
    # rewritten). readline() and read() share one buffer, so mixing them is safe.
    while True:
        raw = inp.readline()
        if not raw:
            break
        if raw.endswith(b"\n"):
            line, nl = raw[:-1], b"\n"
        else:
            line, nl = raw, b""
        if line.startswith(b"data "):
            body = line[5:]
            if body.isdigit():  # counted payload: emit header, copy bytes raw
                out.write(raw)
                copy_exact(inp, out, int(body))
                continue
        else:
            m = IDENT.match(line)
            if m:
                hit = resolve(entries, m.group(2), m.group(3))
                if hit is not None:
                    new_name, new_email = hit
                    line = b"%s %s <%s> %s" % (
                        m.group(1),
                        new_name if new_name is not None else m.group(2),
                        new_email if new_email is not None else m.group(3),
                        m.group(4),
                    )
        out.write(line + nl)


if __name__ == "__main__":
    main()
