#!/bin/sh
# find_box_repo.sh — locate the git repo(s) inside an isopod box.
#
# Streamed into the box over SSH (`sh -s`) by `isopod fetch`, so it runs in the
# box, not on the host. Reads the box workspace path from $WORKSPACE.
#
# Default (single) mode prints the one repo's top-level path:
#   - $WORKSPACE itself, if it is a git work tree; else
#   - the single git subfolder directly under it (e.g. a repo cloned into a
#     named directory).
# Exits non-zero with no output when there is no repo, or when the choice is
# ambiguous (more than one subfolder repo), so the caller asks for --path.
#
# With LIST_ALL set, prints every repo top-level (one per line) instead, so the
# caller can show the choices. Exits non-zero only when none are found.

ws="$WORKSPACE"

# LIST_ALL: enumerate every repo under the workspace, one top-level per line.
if [ -n "${LIST_ALL:-}" ]; then
  # A workspace that is itself a work tree owns everything under it — report it
  # once and don't descend (subfolders would resolve to the same top-level).
  if git -C "$ws" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$ws" rev-parse --show-toplevel
    exit 0
  fi
  found=0
  for d in "$ws"/*/; do
    if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "$d" rev-parse --show-toplevel
      found=1
    fi
  done
  [ "$found" = 1 ] && exit 0
  exit 1
fi

# Single mode: one unambiguous repo, or a failure the caller turns into --path.
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
