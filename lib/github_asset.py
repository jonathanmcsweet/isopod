#!/usr/bin/env python3
"""Pick one asset out of a GitHub "latest release" API response.

The JSON is fetched by lib/isopod.d/codex-installer.sh and piped in on stdin;
the asset filename is the only argument. Prints three tab-separated fields:

    <release name or tag>\t<sha256>\t<download url>

GitHub reports each asset's digest as "sha256:<64 hex>", which is what lets an
agent binary be verified on the host before it is streamed into a box.

Kept as its own file because isopod never embeds another language inline, and a
digest is not a value to pull out of JSON with a regex.

  curl -fsSL "$api/releases/latest" | python3 github_asset.py codex-x86_64-....tar.gz
"""

import json
import re
import sys

SHA256 = re.compile(r"\Asha256:([0-9a-f]{64})\Z")
# The download URL is used verbatim, so keep it to the host that served the API.
URL_OK = re.compile(r"\Ahttps://[A-Za-z0-9.-]*github(usercontent)?\.com/[^\s]+\Z")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: github_asset.py <asset-name>", file=sys.stderr)
        return 2
    wanted = sys.argv[1]

    try:
        release = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"release feed is not valid JSON: {exc}", file=sys.stderr)
        return 1

    assets = release.get("assets")
    if not isinstance(assets, list):
        print("release feed has no 'assets' list", file=sys.stderr)
        return 1

    for asset in assets:
        if not isinstance(asset, dict) or asset.get("name") != wanted:
            continue

        digest = asset.get("digest")
        match = SHA256.match(digest) if isinstance(digest, str) else None
        if not match:
            print(
                f"'{wanted}' has no usable sha256 digest in the release feed",
                file=sys.stderr,
            )
            return 1

        url = asset.get("browser_download_url")
        if not isinstance(url, str) or not URL_OK.match(url):
            print(f"'{wanted}' has no usable download URL", file=sys.stderr)
            return 1

        # Prefer the human release name ("0.153.4") over the tag ("rust-v0.153.4");
        # it is what the tool reports as its own version.
        version = release.get("name") or release.get("tag_name") or ""
        if not isinstance(version, str) or not version:
            print("release feed has neither a name nor a tag", file=sys.stderr)
            return 1

        print(f"{version}\t{match.group(1)}\t{url}")
        return 0

    print(f"no asset named '{wanted}' in the latest release", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
