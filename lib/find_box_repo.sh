#!/bin/sh
# find_box_repo.sh — locate the git repo inside an isopod box.
#
# Streamed into the box over SSH (`sh -s`) by `isopod fetch`, so it runs in the
# box, not on the host. Reads the box workspace path from $WORKSPACE and prints
# the repo's top-level path:
#   - $WORKSPACE itself, if it is a git work tree; else
#   - the single git subfolder directly under it (e.g. a repo cloned into a
#     named directory).
# Exits non-zero with no output when there is no repo, or when the choice is
# ambiguous (more than one subfolder repo), so the caller asks for --path.

ws="$WORKSPACE"

if git -C "$ws" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$ws" rev-parse --show-toplevel
  exit 0
fi

n=0
hit=""
for d in "$ws"/*/; do
  if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1; then
    n=$((n + 1))
    hit="$d"
  fi
done
[ "$n" = 1 ] && {
  git -C "$hit" rev-parse --show-toplevel
  exit 0
}
exit 1
