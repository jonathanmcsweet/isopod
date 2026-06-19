#!/usr/bin/env python3
"""Merge isopod window-color customizations into a workspace settings.json.

Runs INSIDE an isopod container (fed over stdin by `apply_color` in the isopod
script). Reads three environment variables and rewrites
``$ISOPOD_WS/.vscode/settings.json`` so every IDE window attached to this box is
tinted, without clobbering settings the repo already ships.

Environment:
    ISOPOD_COLOR  hex color, with or without leading '#', e.g. '#0f766e'
    ISOPOD_NAME   box name, used in the window title tag
    ISOPOD_WS     absolute path to the workspace directory

Behavior:
    * Tolerates simple JSONC (``//`` and ``/* */`` comments, trailing commas).
    * Merges into any existing ``workbench.colorCustomizations`` rather than
      replacing the whole settings file.
    * If the existing file cannot be parsed, backs it up to
      ``settings.json.isopod-backup`` instead of destroying it.

Kept dependency-free (standard library only) so it runs on the stock Python 3
already present in the container image.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

# --- theming constants ------------------------------------------------------
# ITU-R BT.601 luma coefficients, used to estimate perceived brightness.
LUMA_RED = 0.299
LUMA_GREEN = 0.587
LUMA_BLUE = 0.114

# Backgrounds darker than this (luminance on a 0-255 scale) get light text;
# brighter ones get dark text, so the title/status bars stay readable.
LUMINANCE_THRESHOLD = 160

# Foreground colors picked for contrast against the tinted bars.
FOREGROUND_LIGHT = "#ffffff"
FOREGROUND_DARK = "#1a1a1a"

# Darkening factors applied to the base color for the secondary bars, so the
# inactive title bar, status bar, and activity bar read as progressively dimmer
# shades of the same hue.
SHADE_TITLEBAR_INACTIVE = 0.75
SHADE_STATUSBAR = 0.85
SHADE_ACTIVITYBAR = 0.65

# VSCode window title template; only the box name is interpolated, the
# ``${...}`` placeholders are expanded by the IDE itself.
WINDOW_TITLE_TEMPLATE = (
    "[{name}] ${{dirty}}${{activeEditorShort}}${{separator}}${{rootName}}"
)

# Marker appended to an unparseable settings file before it is replaced.
BACKUP_SUFFIX = ".isopod-backup"

# Exit code for a usage/configuration error (missing or malformed env var).
EXIT_CONFIG_ERROR = 2


def shade(r: int, g: int, b: int, factor: float) -> str:
    """Darken an (r, g, b) triple by ``factor`` and return a hex string."""
    return f"#{int(r * factor):02x}{int(g * factor):02x}{int(b * factor):02x}"


def readable_foreground(r: int, g: int, b: int) -> str:
    """Pick black or white text for contrast against an (r, g, b) background."""
    luminance = LUMA_RED * r + LUMA_GREEN * g + LUMA_BLUE * b
    return FOREGROUND_LIGHT if luminance < LUMINANCE_THRESHOLD else FOREGROUND_DARK


def color_customizations(hexv: str) -> dict[str, str]:
    """Build the workbench.colorCustomizations dict for a 6-digit hex string."""
    r, g, b = (int(hexv[i:i + 2], 16) for i in (0, 2, 4))
    fg = readable_foreground(r, g, b)
    base = f"#{hexv}"
    return {
        "titleBar.activeBackground": base,
        "titleBar.activeForeground": fg,
        "titleBar.inactiveBackground": shade(r, g, b, SHADE_TITLEBAR_INACTIVE),
        "titleBar.inactiveForeground": fg,
        "statusBar.background": shade(r, g, b, SHADE_STATUSBAR),
        "statusBar.foreground": fg,
        "statusBarItem.remoteBackground": base,
        "statusBarItem.remoteForeground": fg,
        "activityBar.background": shade(r, g, b, SHADE_ACTIVITYBAR),
        "activityBar.foreground": fg,
    }


def strip_jsonc(raw: str) -> str:
    """Remove // and /* */ comments and trailing commas so json can parse it."""
    raw = re.sub(r"//[^\n]*", "", raw)
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    raw = re.sub(r",\s*([}\]])", r"\1", raw)
    return raw


def load_existing(path: Path) -> tuple[dict, str | None]:
    """Load settings from ``path``, tolerating JSONC.

    Returns a (settings_dict, note) tuple. On unreadable or unparseable input,
    the original file is renamed to ``<path>.isopod-backup`` and an explanatory
    note string is returned (otherwise note is None).
    """
    if not path.exists():
        return {}, None
    try:
        cleaned = strip_jsonc(path.read_text(encoding="utf-8"))
        return (json.loads(cleaned) if cleaned.strip() else {}), None
    except (OSError, ValueError):
        # OSError: cannot read it; ValueError (incl. JSONDecodeError): cannot
        # parse it. Either way, preserve the original instead of clobbering it.
        backup = path.with_name(path.name + BACKUP_SUFFIX)
        path.rename(backup)
        return {}, (
            "note: existing .vscode/settings.json could not be parsed; "
            f"backed up to settings.json{BACKUP_SUFFIX}"
        )


def main() -> int:
    try:
        hexv = os.environ["ISOPOD_COLOR"].lstrip("#")
        name = os.environ["ISOPOD_NAME"]
        ws = os.environ["ISOPOD_WS"]
    except KeyError as exc:
        sys.stderr.write(f"missing required environment variable: {exc}\n")
        return EXIT_CONFIG_ERROR

    if not re.fullmatch(r"[0-9a-fA-F]{6}", hexv):
        sys.stderr.write(f"ISOPOD_COLOR must be a 6-digit hex color, got {hexv!r}\n")
        return EXIT_CONFIG_ERROR

    vsdir = Path(ws) / ".vscode"
    vsdir.mkdir(parents=True, exist_ok=True)
    path = vsdir / "settings.json"

    settings, note = load_existing(path)
    if note:
        print(note)

    settings.setdefault("workbench.colorCustomizations", {}).update(
        color_customizations(hexv)
    )
    settings["window.title"] = WINDOW_TITLE_TEMPLATE.format(name=name)

    path.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    print(f"applied color #{hexv} to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
