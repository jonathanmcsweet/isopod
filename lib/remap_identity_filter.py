#!/usr/bin/env python3
"""Rewrite author/committer/tagger identities in a git fast-export stream.

Used by `isopod remap` (the no-extra-tooling fallback when git-filter-repo is
absent): the box's refs are piped through `git fast-export`, this filter on
stdin, and back into `git fast-import`. Unlike apply_color.py this runs on the
HOST, not inside a box.

Reads the fast-export stream on stdin and writes the rewritten stream on stdout.
Only identity lines whose email equals OLD_EMAIL (and, if OLD_NAME is set, whose
name also matches) are changed; everything else is copied byte-for-byte. The
parser honours fast-export's counted `data <n>` payloads, so identity-looking
lines inside a commit message or blob are never touched.

Environment:
  OLD_EMAIL  identity to rewrite FROM (required)
  OLD_NAME   optional extra match: only rewrite when the name also equals this
  NEW_NAME   name to write           (required)
  NEW_EMAIL  email to write          (required)
"""
import os
import re
import sys

old_email = os.environ["OLD_EMAIL"].encode()
old_name = os.environ.get("OLD_NAME", "").encode()
new_name = os.environ["NEW_NAME"].encode()
new_email = os.environ["NEW_EMAIL"].encode()

buf = sys.stdin.buffer.read()
out = bytearray()
i, n = 0, len(buf)
ident = re.compile(rb'^(author|committer|tagger) (.*) <([^>]*)> (.*)$')
while i < n:
    nl = buf.find(b'\n', i)
    if nl == -1:
        out += buf[i:]
        break
    line = buf[i:nl]
    i = nl + 1
    if line.startswith(b'data '):
        cnt = int(line[5:])                        # counted payload: copy raw
        out += line + b'\n' + buf[i:i + cnt]
        i += cnt
        continue
    m = ident.match(line)
    if m and m.group(3) == old_email and (not old_name or m.group(2) == old_name):
        line = b'%s %s <%s> %s' % (m.group(1), new_name, new_email, m.group(4))
    out += line + b'\n'
sys.stdout.buffer.write(out)
