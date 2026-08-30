#!/usr/bin/env python3
"""Merge isopod window color customizations into a workspace settings.json.

Runs INSIDE an isopod container (fed over stdin by `apply_color` in the isopod
script). Reads three environment variables and rewrites
``$ISOPOD_WS/.vscode/settings.json`` so every IDE window attached to this box is
tinted.

Environment:
    ISOPOD_COLOR  hex color, with or without leading '#', e.g. '#0f766e'
    ISOPOD_NAME   box name, used in the window title tag
    ISOPOD_WS     absolute path to the workspace directory

Behavior:
    * Tolerates JSONC (``//`` and ``/* */`` comments, trailing commas) with a
      string-aware scanner, so a ``//`` inside a string value is not mangled.
    * Merges into any existing ``workbench.colorCustomizations`` rather than
      replacing the whole settings file.
    * If the existing file cannot be parsed, backs it up to
      ``settings.json.isopod-backup`` instead of destroying it.
    * The rewrite is plain JSON (json can't emit comments), so if the original
      had comments a copy is saved to ``settings.json.isopod-backup`` and a note
      is printed — the comments are never lost silently.
    * When the workspace is a git repo, adds ``.vscode/`` to
      ``.git/info/exclude`` so the isopod-written settings don't show up in
      ``git status`` (and can't be committed by accident).

Runs on the stock Python 3 already present in the container image.
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


def _decomment(raw: str) -> tuple[str, bool]:
    """Strip // and /* */ comments, ignoring string bodies.

    Returns (text_without_comments, had_comment). A hand-rolled scanner rather
    than a blanket regex, so a ``//`` or ``/*`` inside a JSON string value (e.g. a
    URL like ``https://…``) is left intact instead of being corrupted.
    """
    out: list[str] = []
    had = False
    i, n = 0, len(raw)
    in_str = False
    while i < n:
        c = raw[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:  # keep the escaped char verbatim
                out.append(raw[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "/" and i + 1 < n and raw[i + 1] == "/":
            had = True
            i += 2
            while i < n and raw[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and raw[i + 1] == "*":
            had = True
            i += 2
            while i + 1 < n and not (raw[i] == "*" and raw[i + 1] == "/"):
                i += 1
            i += 2  # skip the closing */
        else:
            out.append(c)
            i += 1
    return "".join(out), had


def _strip_trailing_commas(s: str) -> str:
    """Drop a comma that directly precedes a } or ], ignoring string bodies."""
    out: list[str] = []
    i, n = 0, len(s)
    in_str = False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(s[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == ",":
            j = i + 1
            while j < n and s[j] in " \t\r\n":
                j += 1
            if j < n and s[j] in "}]":  # trailing comma — drop it
                i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_jsonc(raw: str) -> str:
    """Remove // and /* */ comments and trailing commas so json can parse it."""
    cleaned, _ = _decomment(raw)
    return _strip_trailing_commas(cleaned)


def _backup(path: Path) -> None:
    """Rename ``path`` aside to its .isopod-backup name (best effort)."""
    try:
        path.rename(path.with_name(path.name + BACKUP_SUFFIX))
    except OSError:
        pass


def load_existing(path: Path) -> tuple[dict, str | None]:
    """Load settings from ``path``, tolerating JSONC.

    Returns a (settings_dict, note) tuple. On unreadable or unparseable input the
    original is renamed to ``<path>.isopod-backup`` and a note is returned. If the
    file parsed but contained comments, we still rewrite it as plain JSON (json
    can't emit comments), so a COPY of the original is saved to the same backup
    name and a note returned — the user's comments are preserved and the loss is
    never silent. Otherwise note is None.
    """
    if not path.exists():
        return {}, None
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        _backup(path)
        return {}, (
            "note: existing .vscode/settings.json could not be read; "
            f"backed up to settings.json{BACKUP_SUFFIX}"
        )
    cleaned, had_comments = _decomment(raw)
    cleaned = _strip_trailing_commas(cleaned)
    try:
        settings = json.loads(cleaned) if cleaned.strip() else {}
    except ValueError:
        _backup(path)
        return {}, (
            "note: existing .vscode/settings.json could not be parsed; "
            f"backed up to settings.json{BACKUP_SUFFIX}"
        )
    # Valid JSON that is not an object (a list, a string, a number) parses fine
    # and then fails on the first dict operation. Treat it like unparseable input
    # so it is backed up rather than overwritten.
    if not isinstance(settings, dict):
        _backup(path)
        return {}, (
            "note: existing .vscode/settings.json was not a JSON object; "
            f"backed up to settings.json{BACKUP_SUFFIX}"
        )
    if had_comments:
        backup = path.with_name(path.name + BACKUP_SUFFIX)
        try:
            if not backup.exists():
                backup.write_text(raw, encoding="utf-8")
            return settings, (
                "note: reformatted .vscode/settings.json; JSONC comments were "
                f"dropped — original saved to settings.json{BACKUP_SUFFIX}"
            )
        except OSError:
            pass
    return settings, None


def exclude_vscode_from_git(ws: Path) -> None:
    """Add ``.vscode/`` to the repo's ``.git/info/exclude`` if ws is a git repo.

    isopod writes ``.vscode/settings.json`` for window theming; without this the
    file lands in ``git status`` and is easy to commit by accident. We use
    ``.git/info/exclude`` (a private, per-clone ignore file) rather than editing
    the tracked ``.gitignore``. No-op when the workspace isn't a standard repo,
    or when ``.git`` is a file (a worktree/submodule pointer) rather than a dir.
    """
    git_dir = ws / ".git"
    if not git_dir.is_dir():
        return
    entry = "/.vscode/"
    exclude = git_dir / "info" / "exclude"
    try:
        exclude.parent.mkdir(parents=True, exist_ok=True)
        existing = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
        if entry in existing.split():
            return
        prefix = "" if existing == "" or existing.endswith("\n") else "\n"
        with exclude.open("a", encoding="utf-8") as fh:
            fh.write(f"{prefix}{entry}\n")
    except OSError:
        # Best effort — a missing/read-only .git/info is not worth failing over.
        pass


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

    # load_existing guarantees a dict, but the nested key is whatever the file
    # held, and a non-object there would crash the update below.
    if not isinstance(settings.get("workbench.colorCustomizations"), dict):
        settings["workbench.colorCustomizations"] = {}

    settings.setdefault("workbench.colorCustomizations", {}).update(
        color_customizations(hexv)
    )
    settings["window.title"] = WINDOW_TITLE_TEMPLATE.format(name=name)

    path.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    exclude_vscode_from_git(Path(ws))
    print(f"applied color #{hexv} to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
