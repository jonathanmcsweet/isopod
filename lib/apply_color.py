#!/usr/bin/env python3
"""Merge aibox window-color customizations into a workspace settings.json.

Runs INSIDE an aibox container (fed over stdin by `apply_color` in the aibox
script). Reads three environment variables and rewrites
``$AIBOX_WS/.vscode/settings.json`` so every IDE window attached to this box is
tinted, without clobbering settings the repo already ships.

Environment:
    AIBOX_COLOR  hex color, with or without leading '#', e.g. '#0f766e'
    AIBOX_NAME   box name, used in the window title tag
    AIBOX_WS     absolute path to the workspace directory

Behavior:
    * Tolerates simple JSONC (``//`` and ``/* */`` comments, trailing commas).
    * Merges into any existing ``workbench.colorCustomizations`` rather than
      replacing the whole settings file.
    * If the existing file cannot be parsed, backs it up to
      ``settings.json.aibox-backup`` instead of destroying it.

Kept dependency-free (standard library only) so it runs on the stock Python 3
already present in the container image.
"""
import json
import os
import re
import sys


def shade(r, g, b, factor):
    """Darken an (r, g, b) triple by ``factor`` and return a hex string."""
    return "#%02x%02x%02x" % (int(r * factor), int(g * factor), int(b * factor))


def readable_foreground(r, g, b):
    """Pick black or white text for contrast against an (r, g, b) background."""
    luminance = 0.299 * r + 0.587 * g + 0.114 * b
    return "#ffffff" if luminance < 160 else "#1a1a1a"


def color_customizations(hexv):
    """Build the workbench.colorCustomizations dict for a 6-digit hex string."""
    r, g, b = (int(hexv[i:i + 2], 16) for i in (0, 2, 4))
    fg = readable_foreground(r, g, b)
    main = "#" + hexv
    return {
        "titleBar.activeBackground": main,
        "titleBar.activeForeground": fg,
        "titleBar.inactiveBackground": shade(r, g, b, 0.75),
        "titleBar.inactiveForeground": fg,
        "statusBar.background": shade(r, g, b, 0.85),
        "statusBar.foreground": fg,
        "statusBarItem.remoteBackground": main,
        "statusBarItem.remoteForeground": fg,
        "activityBar.background": shade(r, g, b, 0.65),
        "activityBar.foreground": fg,
    }


def strip_jsonc(raw):
    """Remove // and /* */ comments and trailing commas so json can parse it."""
    raw = re.sub(r"//[^\n]*", "", raw)
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r",\s*([}\]])", r"\1", raw)
    return raw


def load_existing(path):
    """Load settings from ``path``, tolerating JSONC.

    Returns a (settings_dict, note) tuple. On unparseable input, the original
    file is renamed to ``<path>.aibox-backup`` and an explanatory note string
    is returned (otherwise note is None).
    """
    if not os.path.exists(path):
        return {}, None
    try:
        raw = open(path).read()
        cleaned = strip_jsonc(raw)
        return (json.loads(cleaned) if cleaned.strip() else {}), None
    except Exception:
        backup = path + ".aibox-backup"
        os.rename(path, backup)
        return {}, (
            "note: existing .vscode/settings.json could not be parsed; "
            "backed up to settings.json.aibox-backup"
        )


def main():
    try:
        hexv = os.environ["AIBOX_COLOR"].lstrip("#")
        name = os.environ["AIBOX_NAME"]
        ws = os.environ["AIBOX_WS"]
    except KeyError as exc:
        sys.stderr.write("missing required environment variable: %s\n" % exc)
        return 2

    if not re.fullmatch(r"[0-9a-fA-F]{6}", hexv):
        sys.stderr.write("AIBOX_COLOR must be a 6-digit hex color, got %r\n" % hexv)
        return 2

    vsdir = os.path.join(ws, ".vscode")
    os.makedirs(vsdir, exist_ok=True)
    path = os.path.join(vsdir, "settings.json")

    settings, note = load_existing(path)
    if note:
        print(note)

    settings.setdefault("workbench.colorCustomizations", {}).update(
        color_customizations(hexv)
    )
    settings["window.title"] = (
        "[%s] ${dirty}${activeEditorShort}${separator}${rootName}" % name
    )

    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
    print("applied color #%s to %s" % (hexv, path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
