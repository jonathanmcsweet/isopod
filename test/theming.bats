#!/usr/bin/env bats
# Tests for color theming (the embedded JSONC merge) and IDE detection.

setup() {
  load "$(dirname "$BATS_TEST_FILENAME")/helper.bash"
  load_libs
  isopod_setup_env
  load_isopod
  # The color-merge logic is a discrete file we can exercise directly without
  # a container. (No more extracting it from a heredoc.)
  MERGE_PY="$ISOPOD_ROOT/lib/apply_color.py"
  [ -f "$MERGE_PY" ] || { echo "missing lib/apply_color.py"; return 1; }
  export MERGE_PY
  # Resolve python3 to an absolute path BEFORE any stub dir is prepended to
  # PATH, so stub manipulation in tests can never shadow the interpreter.
  PYTHON3="$(command -v python3 2>/dev/null || true)"
  if [ -z "$PYTHON3" ]; then
    for _p in /usr/bin/python3 /usr/local/bin/python3 /bin/python3 /usr/bin/python3.12 /usr/bin/python3.11; do
      [ -x "$_p" ] && { PYTHON3="$_p"; break; }
    done
  fi
  [ -n "$PYTHON3" ] || { echo "python3 not found"; return 1; }
  export PYTHON3
}
teardown() { isopod_teardown_env; }

run_merge() { # run_merge <workspace> <hex> <name>
  ISOPOD_COLOR="$2" ISOPOD_NAME="$3" ISOPOD_WS="$1" "$PYTHON3" "$MERGE_PY"
}

@test "merge creates settings.json with color customizations on a clean workspace" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"
  run run_merge "$ws" "#0f766e" demo
  assert_success
  run "$PYTHON3" -c "import json;d=json.load(open('$ws/.vscode/settings.json'));print(d['workbench.colorCustomizations']['titleBar.activeBackground'])"
  assert_output "#0f766e"
}

@test "merge sets a window.title tagged with the box name" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"
  run_merge "$ws" "#b3261e" myproj
  run "$PYTHON3" -c "import json;print(json.load(open('$ws/.vscode/settings.json'))['window.title'])"
  assert_output --partial "[myproj]"
}

@test "merge preserves existing strict-JSON settings" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws/.vscode"
  printf '{"editor.tabSize": 2, "files.eol": "\\n"}' > "$ws/.vscode/settings.json"
  run_merge "$ws" "#1d4ed8" demo
  run "$PYTHON3" -c "import json;print(json.load(open('$ws/.vscode/settings.json'))['editor.tabSize'])"
  assert_output "2"
}

@test "merge tolerates JSONC comments and trailing commas" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws/.vscode"
  cat > "$ws/.vscode/settings.json" <<'JSONC'
{
  // team settings
  "editor.tabSize": 4, /* keep this */
  "files.eol": "\n",
}
JSONC
  run run_merge "$ws" "#7e22ce" demo
  assert_success
  run "$PYTHON3" -c "import json;d=json.load(open('$ws/.vscode/settings.json'));print(d['editor.tabSize'], d['workbench.colorCustomizations']['statusBar.background'])"
  assert_output --partial "4"
}

@test "merge backs up an unparseable settings file instead of destroying it" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws/.vscode"
  printf 'this is not json at all {{{' > "$ws/.vscode/settings.json"
  run run_merge "$ws" "#15803d" demo
  assert_success
  [ -f "$ws/.vscode/settings.json.isopod-backup" ]
  # new file is valid json with our colors
  run "$PYTHON3" -c "import json;json.load(open('$ws/.vscode/settings.json'))"
  assert_success
}

@test "merge chooses light foreground on a dark color" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"
  run_merge "$ws" "#0f766e" demo   # dark teal
  run "$PYTHON3" -c "import json;print(json.load(open('$ws/.vscode/settings.json'))['workbench.colorCustomizations']['titleBar.activeForeground'])"
  assert_output "#ffffff"
}

@test "merge chooses dark foreground on a light color" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"
  run_merge "$ws" "#fde68a" demo   # light amber
  run "$PYTHON3" -c "import json;print(json.load(open('$ws/.vscode/settings.json'))['workbench.colorCustomizations']['titleBar.activeForeground'])"
  assert_output "#1a1a1a"
}

@test "merge excludes .vscode from git when the workspace is a repo" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"
  git init -q "$ws"
  run run_merge "$ws" "#0f766e" demo
  assert_success
  run cat "$ws/.git/info/exclude"
  assert_output --partial "/.vscode/"
  # the settings file the merge wrote must now be ignored by git
  run git -C "$ws" status --porcelain --ignored -- .vscode/settings.json
  assert_output --partial "!!"
}

@test "merge is a no-op on the git exclude when the workspace is not a repo" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"   # no .git
  run run_merge "$ws" "#0f766e" demo
  assert_success
  [ ! -e "$ws/.git" ]
}

@test "merge does not duplicate the .vscode exclude entry on re-run" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws"
  git init -q "$ws"
  run_merge "$ws" "#0f766e" demo
  run_merge "$ws" "#b3261e" demo
  run grep -c '^/.vscode/$' "$ws/.git/info/exclude"
  assert_output "1"
}

# ---- find_ide_bin (native binaries via stubs) --------------------------------
@test "find_ide_bin finds a native codium on PATH" {
  make_stub codium 0
  find_ide_bin codium
  assert_equal "${IDE_CMD[*]}" "codium"
}

@test "find_ide_bin falls back through codium/vscodium names" {
  make_stub vscodium 0
  # ide_lookup hides any host-installed codium so the stubbed vscodium is the
  # first name that resolves.
  ide_lookup codium
  assert_equal "${IDE_CMD[*]}" "vscodium"
}

@test "find_ide_bin detects a Flatpak codium when no native binary exists" {
  # flatpak stub: 'info <id>' succeeds for the codium id only
  cat > "$STUB_DIR/flatpak" <<'EOF'
#!/usr/bin/env bash
echo "flatpak $*" >> "$STUB_LOG"
case "$1" in
  info)
    [ "$2" = "com.vscodium.codium" ] && exit 0 || exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/flatpak"
  # ide_lookup hides a host codium binary AND a host /Applications/VSCodium.app,
  # so the Flatpak fallback is what resolves.
  ide_lookup codium
  assert_equal "${IDE_CMD[*]}" "flatpak run com.vscodium.codium"
}

@test "find_ide_bin prefers a native binary over Flatpak when both exist" {
  make_stub codium 0
  cat > "$STUB_DIR/flatpak" <<'EOF'
#!/usr/bin/env bash
[ "$1" = info ] && exit 0
EOF
  chmod +x "$STUB_DIR/flatpak"
  find_ide_bin codium
  assert_equal "${IDE_CMD[*]}" "codium"
}

@test "find_ide_bin fails cleanly when nothing is installed" {
  # Nothing is stubbed; ide_lookup hides any host codium binary or .app so the
  # lookup genuinely finds nothing.
  run ide_lookup codium
  assert_failure
}

@test "find_ide_bin resolves a native cursor from the table" {
  make_stub cursor 0
  find_ide_bin cursor
  assert_equal "${IDE_CMD[*]}" "cursor"
}

@test "find_ide_bin resolves the code flatpak id from the table" {
  cat > "$STUB_DIR/flatpak" <<'EOF'
#!/usr/bin/env bash
case "$1" in info) [ "$2" = "com.visualstudio.code" ] && exit 0 || exit 1 ;; esac
exit 0
EOF
  chmod +x "$STUB_DIR/flatpak"
  find_ide_bin code
  assert_equal "${IDE_CMD[*]}" "flatpak run com.visualstudio.code"
}

@test "find_ide_bin falls back to a bare binary for an unknown app" {
  make_stub myeditor 0
  find_ide_bin myeditor
  assert_equal "${IDE_CMD[*]}" "myeditor"
}

# ---- JSONC string-awareness (§4.5) & comment preservation (§4.6) -------------
@test "merge does not strip // inside string values (URLs survive)" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws/.vscode"
  printf '{"my.url": "https://example.com/a//b"}' > "$ws/.vscode/settings.json"
  run run_merge "$ws" "#0f766e" demo
  assert_success
  run "$PYTHON3" -c "import json;print(json.load(open('$ws/.vscode/settings.json'))['my.url'])"
  assert_output "https://example.com/a//b"
}

@test "merge backs up a commented settings file instead of dropping comments silently" {
  ws="$TEST_TMP/ws"; mkdir -p "$ws/.vscode"
  printf '{\n  // team setting\n  "editor.tabSize": 2\n}\n' > "$ws/.vscode/settings.json"
  run run_merge "$ws" "#0f766e" demo
  assert_success
  assert_output --partial "isopod-backup"        # the loss is announced, not silent
  [ -f "$ws/.vscode/settings.json.isopod-backup" ]
  run grep -q "// team setting" "$ws/.vscode/settings.json.isopod-backup"  # comment kept in backup
  assert_success
  # the merge still applied and preserved the user's value
  run "$PYTHON3" -c "import json;print(json.load(open('$ws/.vscode/settings.json'))['editor.tabSize'])"
  assert_output "2"
}

# ---- agent terminal theming --------------------------------------------------
# Four agents in four windows look identical, so each gets a color. It goes on
# the terminal rather than on the agent, so these cover the palette lookup, the
# background math, the guards that decide whether anything is emitted at all, and
# the wiring that carries the resolved color into the session that gets themed.

mk_box() { # mk_box <name> <meta-line...>
  mkdir -p "$BOXES_DIR/$1"
  printf '%s\n' "${@:2}" >"$BOXES_DIR/$1/meta"
}

@test "every agent has a color, and no two share one" {
  local a hex seen=""
  for a in claude codex opencode pi; do
    hex="$(agent_color "$a")"
    [[ "$hex" =~ ^#[0-9a-f]{6}$ ]]
    case " $seen " in *" $hex "*) return 1 ;; esac
    seen="$seen $hex"
  done
}

@test "agent_preset names a preset the shipped palette actually has" {
  local a
  for a in claude codex opencode pi; do
    run preset_color "$(agent_preset "$a")"
    assert_success
  done
}

@test "agent_preset refuses an agent with no row" {
  run agent_preset gemini
  assert_failure
}

@test "ISOPOD_<AGENT>_COLOR overrides the table" {
  ISOPOD_PI_COLOR=magenta
  assert_equal "$(agent_color pi)" "$(preset_color magenta)"
  ISOPOD_PI_COLOR="#abcdef"
  assert_equal "$(agent_color pi)" "#abcdef"
  # and only that agent's
  assert_equal "$(agent_color codex)" "$(preset_color teal)"
}

@test "a color of 'box' takes the sandbox's own color" {
  mk_box demo 'engine=podman' 'color=#123456'
  assert_equal "$(agent_color_resolve box demo)" "#123456"
  ISOPOD_CLAUDE_COLOR=box
  assert_equal "$(agent_color claude demo)" "#123456"
}

@test "a color of 'box' is no color when the box has none" {
  mk_box plain 'engine=podman'
  run agent_color_resolve box plain
  assert_failure
  run agent_color_resolve box
  assert_failure
}

@test "agent_color_resolve refuses an unknown preset and reads 'off' as none" {
  run agent_color_resolve chartreuse
  assert_failure
  run agent_color_resolve off
  assert_failure
  run agent_color_resolve ''
  assert_failure
}

# The palette entries are not equally bright, so a flat percentage of each would
# tint some windows obviously and others barely. Every background is scaled to
# the same peak channel instead.
@test "hex_peak scales a color to a fixed peak, keeping its hue" {
  assert_equal "$(hex_peak '#c2410c' 42)" "#2a0e02"
  assert_equal "$(hex_peak '#0f766e' 42)" "#052a27"
  # the brightest channel lands on the target for every palette entry
  local a hex peak
  for a in claude codex opencode pi; do
    hex="$(hex_peak "$(agent_color "$a")" 42)"
    peak=$((16#${hex:1:2}))
    [ $((16#${hex:3:2})) -gt "$peak" ] && peak=$((16#${hex:3:2}))
    [ $((16#${hex:5:2})) -gt "$peak" ] && peak=$((16#${hex:5:2}))
    assert_equal "$peak" 42
  done
}

@test "hex_peak leaves black alone rather than dividing by zero" {
  run hex_peak '#000000' 42
  assert_success
  assert_output '#000000'
}

@test "hex_blend mixes two colors by percentage" {
  assert_equal "$(hex_blend '#ffffff' '#000000' 50)" "#7f7f7f"
  assert_equal "$(hex_blend '#ffffff' '#000000' 100)" "#ffffff"
  assert_equal "$(hex_blend '#ffffff' '#000000' 0)" "#000000"
}

@test "the tinted background is a dark version of the color, not the color" {
  local hex bg
  hex="$(agent_color claude)"
  bg="$(term_tint_bg "$hex")"
  [ "$bg" != "$hex" ]
  [ $((16#${bg:1:2} + 16#${bg:3:2} + 16#${bg:5:2})) -lt $((16#${hex:1:2} + 16#${hex:3:2} + 16#${hex:5:2})) ]
  # light mode is the pale counterpart, for a light-themed terminal
  bg="$(ISOPOD_AGENT_TINT=light term_tint_bg "$hex")"
  [ $((16#${bg:1:2})) -gt 200 ]
}

@test "ISOPOD_AGENT_TINT=off leaves the background to whoever set it" {
  ISOPOD_AGENT_TINT=off run term_tint_bg '#c2410c'
  assert_failure
}

# Writing escape sequences into a pipe or a file would corrupt it and color
# nothing, so nothing is emitted unless stdout is a terminal. bats gives the test
# a pipe, which is exactly that case.
@test "nothing is emitted when stdout is not a terminal" {
  run term_theme_on '#c2410c' 'demo - Claude Code'
  assert_success
  assert_output ''
  run term_theme_banner '#c2410c' 'demo - Claude Code'
  assert_output ''
}

@test "a themed window gets a title, a background and a cursor" {
  term_can_theme() { return 0; }
  term_theme_on '#c2410c' 'demo - Claude Code' >"$TEST_TMP/seq"
  run cat "$TEST_TMP/seq"
  assert_output --partial $'\033]0;demo - Claude Code\a'
  assert_output --partial $'\033]11;#2a0e02\a'
  assert_output --partial $'\033]12;#c2410c\a'
  assert_equal "$TERM_THEMED" 1
}

@test "the terminal is put back the way it was" {
  term_can_theme() { return 0; }
  term_theme_on '#c2410c' 'demo' >/dev/null
  term_theme_off >"$TEST_TMP/seq"
  run cat "$TEST_TMP/seq"
  assert_output --partial $'\033]111\a'
  assert_output --partial $'\033]112\a'
  assert_equal "$TERM_THEMED" 0
  # and a second call has nothing to undo
  term_theme_off >"$TEST_TMP/seq2"
  run cat "$TEST_TMP/seq2"
  assert_output ''
}

# The restore has to survive a failed ssh and a Ctrl-C, so it hangs off the one
# exit handler rather than off the happy path.
@test "the exit handler restores a tinted terminal" {
  term_can_theme() { return 0; }
  term_theme_on '#c2410c' 'demo' >/dev/null
  assert_equal "$TERM_THEMED" 1
  on_exit >"$TEST_TMP/seq" 2>/dev/null || true
  run cat "$TEST_TMP/seq"
  assert_output --partial $'\033]111\a'
}

@test "NO_COLOR and a dumb terminal turn the whole thing off" {
  NO_COLOR=1 run term_theme_on '#c2410c' 'demo'
  assert_output ''
  TERM=dumb run term_theme_on '#c2410c' 'demo'
  assert_output ''
}

# Under tmux the background belongs to the OUTER terminal, so setting it would
# tint every pane of the session instead of this one.
@test "under tmux only the title and the banner carry the color" {
  term_can_theme() { return 0; }
  TMUX=/tmp/tmux-x term_theme_on '#c2410c' 'demo - Codex' >"$TEST_TMP/seq"
  run cat "$TEST_TMP/seq"
  assert_output --partial $'\033]0;demo - Codex\a'
  refute_output --partial $'\033]11;'
  refute_output --partial $'\033]12;'
  assert_equal "$TERM_THEMED" 0
}

@test "ISOPOD_AGENT_TINT=off keeps the title without repainting the background" {
  term_can_theme() { return 0; }
  ISOPOD_AGENT_TINT=off term_theme_on '#c2410c' 'demo - Codex' >"$TEST_TMP/seq"
  run cat "$TEST_TMP/seq"
  assert_output --partial $'\033]0;demo - Codex\a'
  refute_output --partial $'\033]11;'
  assert_equal "$TERM_THEMED" 0
}

# The banner covers the terminals that ignore OSC 11, and stays in the scrollback
# as a marker of where the session began.
@test "the banner is drawn in the agent's own color" {
  term_can_theme() { return 0; }
  run term_theme_banner '#c2410c' 'demo - Claude Code'
  assert_success
  assert_output --partial $'\033[1;48;2;194;65;12;38;2;255;255;255m'
  assert_output --partial 'demo - Claude Code'
}

@test "a box name cannot smuggle control characters into the title" {
  term_can_theme() { return 0; }
  run term_theme_on '' "$(printf 'demo\033]0;pwned\a')"
  assert_success
  refute_output --partial $'\033]0;pwned'
  # one title sequence, isopod's, not two
  [ "$(printf '%s' "$output" | grep -c $'\033]0;')" = 1 ]
}

@test "the window title leads with the box, since the color says which agent" {
  agent_select codex
  term_can_theme() { return 0; }
  agent_theme demo '' >"$TEST_TMP/seq"
  run cat "$TEST_TMP/seq"
  assert_output --partial $'\033]0;demo - Codex\a'
}

# ---- the color reaches the session that gets themed --------------------------
# agent_run resolves the color once and hands it to the window it opens, so the
# session the user is looking at is the one that gets painted. With no window to
# open it re-enters itself with --attach, which is the same handoff and can be
# driven here without a terminal.
agent_color_harness() { # agent_color_harness <agent>
  agent_select "$1"
  mk_box demo 'engine=podman' 'port=2222' 'color=#123456'
  open_box() { :; }
  agent_start_box() { :; }
  agent_ensure_installed() { :; }
  agent_ensure_key() { :; }
  agent_egress_note() { :; }
  can_open_window() { return 1; }
  box_ssh() { :; }
  agent_theme() { printf '%s' "${2:-}" >"$TEST_TMP/themed"; }
  : >"$TEST_TMP/themed"
}

@test "an agent session is themed with that agent's color by default" {
  agent_color_harness codex
  agent_run demo >/dev/null
  assert_equal "$(cat "$TEST_TMP/themed")" "$(agent_color codex)"
}

@test "--color overrides it for one run, in both spellings" {
  agent_color_harness codex
  agent_run demo --color magenta >/dev/null
  assert_equal "$(cat "$TEST_TMP/themed")" "$(preset_color magenta)"
  agent_run demo --color=box >/dev/null
  assert_equal "$(cat "$TEST_TMP/themed")" "#123456"
}

@test "--no-color leaves the session unthemed" {
  agent_color_harness pi
  agent_run demo --no-color >/dev/null
  assert_equal "$(cat "$TEST_TMP/themed")" ""
}

@test "an unknown --color is refused before the box is touched" {
  agent_color_harness claude
  run agent_run demo --color chartreuse
  assert_failure
  assert_output --partial "unknown color 'chartreuse'"
  assert_equal "$(cat "$TEST_TMP/themed")" ""
}

# The window isopod opens re-runs isopod with --attach, so the color has to
# travel on that command line or the new window would resolve it again from an
# environment that may differ.
@test "the terminal isopod opens is told which color to use" {
  agent_color_harness codex
  can_open_window() { return 0; }
  find_term_bin() {
    TERM_CMD=(recorder)
    TERM_NAME=recorder
    TERM_MACOS_APP=""
    return 0
  }
  make_stub recorder 0
  agent_run demo >/dev/null
  # The launch is backgrounded and disowned, so wait for the stub to record it.
  local i
  for i in $(seq 1 100); do
    grep -q recorder "$STUB_LOG" 2>/dev/null && break
    sleep 0.02
  done
  run cat "$STUB_LOG"
  assert_output --partial "--attach --color $(agent_color codex)"
}

@test "the macOS launcher script carries the color too" {
  agent_color_harness claude
  can_open_window() { return 0; }
  find_term_bin() {
    TERM_CMD=()
    TERM_NAME=Ghostty
    TERM_MACOS_APP=Ghostty
    return 0
  }
  make_stub open 0
  agent_run demo --color magenta >/dev/null
  run cat "$(box_dir demo)/claude-launch.command"
  assert_output --partial "--attach"
  assert_output --partial "--color"
  assert_output --partial "$(preset_color magenta)"
}
