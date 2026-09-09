#!/usr/bin/env python3
"""Read one platform's checksum out of a Claude Code release manifest.

The manifest is fetched by lib/isopod.d/claude-code-installer.sh and piped in on
stdin; the platform token (e.g. "linux-x64") is the only argument. Prints the
64-char SHA-256 for that platform, or exits 1 with a reason on stderr.

Kept as its own file because isopod never embeds another language inline, and
JSON is not something to parse with awk when the value is a security check.

  curl -fsSL "$base/$ver/manifest.json" | python3 claude_manifest.py linux-x64
"""

import json
import re
import sys

SHA256 = re.compile(r"\A[0-9a-f]{64}\Z")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: claude_manifest.py <platform>", file=sys.stderr)
        return 2
    platform = sys.argv[1]

    try:
        manifest = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"manifest is not valid JSON: {exc}", file=sys.stderr)
        return 1

    platforms = manifest.get("platforms")
    if not isinstance(platforms, dict):
        print("manifest has no 'platforms' object", file=sys.stderr)
        return 1

    entry = platforms.get(platform)
    if not isinstance(entry, dict):
        known = ", ".join(sorted(k for k in platforms if isinstance(k, str)))
        print(
            f"no build for '{platform}' in this release (published: {known})",
            file=sys.stderr,
        )
        return 1

    checksum = entry.get("checksum")
    # Anchored match, so nothing but a bare digest can reach the verify step.
    if not isinstance(checksum, str) or not SHA256.match(checksum):
        print(f"checksum for '{platform}' is missing or malformed", file=sys.stderr)
        return 1

    print(checksum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
