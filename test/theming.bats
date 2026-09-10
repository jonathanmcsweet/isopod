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


# ---- agent session color -----------------------------------------------------
# An agent session is marked by a colored bar across the top row, in the box's
# own color, the way `isopod code` tints the IDE. These cover which color a
# session resolves to and how it reaches the process that draws the bar.

mk_box() { # mk_box <name> <meta-line...>
  mkdir -p "$BOXES_DIR/$1"
  printf '%s\n' "${@:2}" >"$BOXES_DIR/$1/meta"
}

@test "a session takes the box's own color, like the IDE tint does" {
  mk_box demo 'engine=podman' 'color=#123456'
  assert_equal "$(agent_color codex demo)" "#123456"
  assert_equal "$(agent_color pi demo)" "#123456"
}

@test "a box with no color falls back to the agent's own" {
  mk_box plain 'engine=podman'
  assert_equal "$(agent_color codex plain)" "$(preset_color "$(agent_preset codex)")"
}

@test "ISOPOD_<AGENT>_COLOR overrides the box color, for that agent only" {
  mk_box demo 'engine=podman' 'color=#123456'
  ISOPOD_PI_COLOR=magenta
  assert_equal "$(agent_color pi demo)" "$(preset_color magenta)"
  assert_equal "$(agent_color codex demo)" "#123456"
  ISOPOD_PI_COLOR="#abcdef"
  assert_equal "$(agent_color pi demo)" "#abcdef"
}

# Two agents in ONE box would otherwise share a color, which is the case the
# per-agent palette still exists for.
@test "a color of 'agent' picks the agent's own, distinct per agent" {
  mk_box demo 'engine=podman' 'color=#123456'
  local a b
  a="$(agent_color_resolve agent demo claude)"
  b="$(agent_color_resolve agent demo codex)"
  [ "$a" != "$b" ]
  assert_equal "$a" "$(preset_color "$(agent_preset claude)")"
}

@test "every agent has a color in the table, and no two share one" {
  local a hex seen=""
  for a in claude codex opencode pi; do
    hex="$(preset_color "$(agent_preset "$a")")"
    [[ "$hex" =~ ^#[0-9a-f]{6}$ ]]
    case " $seen " in *" $hex "*) return 1 ;; esac
    seen="$seen $hex"
  done
}

@test "agent_preset refuses an agent with no row" {
  run agent_preset gemini
  assert_failure
}

@test "agent_color_resolve refuses an unknown preset and reads 'off' as none" {
  mk_box demo 'engine=podman' 'color=#123456'
  run agent_color_resolve chartreuse demo codex
  assert_failure
  run agent_color_resolve off demo codex
  assert_failure
  run agent_color_resolve '' demo codex
  assert_failure
}

# ---- the window title --------------------------------------------------------

@test "the title leads with the box, and is sanitized" {
  term_can_theme() { return 0; }
  run term_set_title 'demo - Codex'
  assert_output $'\033]0;demo - Codex\a'
  # a control character in the label cannot open a second title sequence
  run term_set_title "$(printf 'demo\033]0;pwned\a')"
  refute_output --partial $'\033]0;pwned'
  [ "$(printf '%s' "$output" | grep -c $'\033]0;')" = 1 ]
}

@test "nothing is emitted when stdout is not a terminal" {
  # bats gives the test a pipe, which is exactly the case being checked.
  run term_set_title 'demo - Codex'
  assert_success
  assert_output ''
}

@test "NO_COLOR and a dumb terminal turn theming off" {
  NO_COLOR=1 run term_set_title 'demo'
  assert_output ''
  TERM=dumb run term_set_title 'demo'
  assert_output ''
}

# ---- handing the bar to the session ------------------------------------------
# The bar has to be drawn by something that owns the pty ssh runs on, so
# agent_bar_on arranges for topbar.py to wrap ssh rather than printing anything
# itself. Anything printed into the session is wiped the moment the agent
# switches to the alternate screen.

@test "agent_bar_on puts topbar in front of ssh with the label and color" {
  agent_select codex
  term_can_theme() { return 0; }
  agent_bar_on demo '#c2410c'
  assert_equal "${BOX_SSH_WRAP[0]}" "python3"
  assert_equal "${BOX_SSH_WRAP[1]}" "$ISOPOD_LIB/topbar.py"
  assert_equal "${BOX_SSH_WRAP[2]}" "demo - Codex"
  assert_equal "${BOX_SSH_WRAP[3]}" "#c2410c"
  assert_equal "${BOX_SSH_WRAP[4]}" "--"
}

@test "agent_bar_on arranges nothing when there is no color" {
  agent_select codex
  term_can_theme() { return 0; }
  agent_bar_on demo ''
  assert_equal "${#BOX_SSH_WRAP[@]}" 0
}

@test "agent_bar_on arranges nothing without a terminal or without python3" {
  agent_select codex
  term_can_theme() { return 1; }
  agent_bar_on demo '#c2410c'
  assert_equal "${#BOX_SSH_WRAP[@]}" 0
  term_can_theme() { return 0; }
  have() { [ "$1" != python3 ]; }
  agent_bar_on demo '#c2410c'
  assert_equal "${#BOX_SSH_WRAP[@]}" 0
}

# The hook is only useful if box_ssh actually honors it, and every other caller
# has to be unaffected.
@test "box_ssh runs ssh under the wrapper, and plainly without one" {
  mk_box demo 'engine=podman' 'port=2222'
  : >"$(box_dir demo)/id_ed25519"
  : >"$(box_dir demo)/known_hosts"
  make_stub ssh 0
  make_stub wrapper 0
  BOX_SSH_WRAP=(wrapper --)
  box_ssh demo -- true
  assert_stub_called "wrapper -- ssh -p 2222"
  : >"$STUB_LOG"
  BOX_SSH_WRAP=()
  box_ssh demo -- true
  assert_stub_called "ssh -p 2222"
  assert_stub_not_called "wrapper"
}

# ---- the color reaches the session that draws the bar ------------------------
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
  agent_bar_on() { printf '%s' "${2:-}" >"$TEST_TMP/barred"; }
  : >"$TEST_TMP/barred"
}

@test "a session gets the box color by default" {
  agent_color_harness codex
  agent_run demo >/dev/null
  assert_equal "$(cat "$TEST_TMP/barred")" "#123456"
}

@test "--color overrides it for one run, in both spellings" {
  agent_color_harness codex
  agent_run demo --color magenta >/dev/null
  assert_equal "$(cat "$TEST_TMP/barred")" "$(preset_color magenta)"
  agent_run demo --color=agent >/dev/null
  assert_equal "$(cat "$TEST_TMP/barred")" "$(preset_color "$(agent_preset codex)")"
}

@test "--no-color leaves the session with no bar" {
  agent_color_harness pi
  agent_run demo --no-color >/dev/null
  assert_equal "$(cat "$TEST_TMP/barred")" ""
}

@test "an unknown --color is refused before the box is touched" {
  agent_color_harness claude
  run agent_run demo --color chartreuse
  assert_failure
  assert_output --partial "unknown color 'chartreuse'"
  assert_equal "$(cat "$TEST_TMP/barred")" ""
}

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
  assert_output --partial "--attach --color #123456"
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

# ---- topbar.py: reserving the row --------------------------------------------
# The helper keeps a full-screen TUI off the top row by lying about the terminal
# size and letting the terminal do the offset (scroll region plus origin mode),
# so it never has to understand what the command draws. ptyrun.py gives it the
# terminal of a known size it needs; a fake TUI stands in for the agent.

TOPBAR() { printf '%s' "$ISOPOD_ROOT/lib/topbar.py"; }

fake_tui() { # fake_tui -> path to a program that behaves like an agent TUI
  local f="$TEST_TMP/faketui.py"
  cat >"$f" <<'PY'
import os, sys
cols, rows = os.get_terminal_size(1)
sys.stdout.write("\x1b[?1049h")   # alternate screen, as every agent TUI does
sys.stdout.write("\x1b[2J")       # erase all: ignores margins, takes the bar
sys.stdout.write("\x1b[1;1HSIZE rows=%d cols=%d" % (rows, cols))
sys.stdout.write("\x1b[?1049l")
sys.stdout.flush()
PY
  printf '%s' "$f"
}

topbar_run() { # topbar_run <rows> <cols> <label> <color> <command...>
  local rows="$1" cols="$2" label="$3" color="$4"
  shift 4
  python3 "$ISOPOD_ROOT/test/ptyrun.py" "$rows" "$cols" \
    python3 "$(TOPBAR)" "$label" "$color" -- "$@"
}

@test "topbar hands the command a terminal one row shorter" {
  run topbar_run 24 40 'demo - Codex' '#c2410c' python3 "$(fake_tui)"
  assert_success
  assert_output --partial "SIZE rows=23 cols=40"
}

@test "topbar paints the bar on the top row and keeps the command below it" {
  run topbar_run 24 40 'demo - Codex' '#c2410c' python3 "$(fake_tui)"
  assert_success
  # origin mode off to reach row 1, the bar, then the region and origin mode back
  assert_output --partial $'\033[?6l\033[1;1H'
  assert_output --partial $'\033[48;2;194;65;12m'
  assert_output --partial 'demo - Codex'
  assert_output --partial $'\033[2;24r'
  assert_output --partial $'\033[?6h'
}

# The command erases the whole display, which by spec ignores margins. Without a
# repaint the bar is gone for the rest of the session.
@test "topbar repaints after the command erases the screen" {
  run topbar_run 24 40 'demo - Codex' '#c2410c' python3 "$(fake_tui)"
  local painted
  painted="$(printf '%s' "$output" | grep -o 'demo - Codex' | wc -l)"
  [ "$painted" -ge 2 ]
}

@test "topbar puts the terminal back when the command exits" {
  run topbar_run 24 40 'demo - Codex' '#c2410c' true
  assert_success
  # origin mode off, scroll region reset, bar row erased
  assert_output --partial $'\033[?6l\033[r\033[1;1H\033[2K'
}

@test "topbar relays the command's own output unchanged" {
  run topbar_run 24 40 'demo - Codex' '#c2410c' printf 'hello world\n'
  assert_output --partial 'hello world'
}

@test "topbar passes the command's exit status through" {
  run topbar_run 24 40 'demo' '#c2410c' sh -c 'exit 3'
  # ptyrun reports the pty output, so check topbar's own status directly
  run python3 "$(TOPBAR)" 'demo' '#c2410c' -- sh -c 'exit 3'
  assert_failure 3
}

# Fail open: without a terminal there is no bar to draw, and the command must
# still run normally rather than the session breaking.
@test "topbar runs the command directly when there is no terminal" {
  run python3 "$(TOPBAR)" 'demo' '#c2410c' -- printf 'ran anyway\n'
  assert_success
  assert_output 'ran anyway'
  refute_output --partial $'\033['
}

@test "topbar runs the command directly when the color is malformed" {
  run topbar_run 24 40 'demo' 'not-a-color' printf 'ran anyway\n'
  assert_success
  assert_output --partial 'ran anyway'
  refute_output --partial $'\033[48;2;'
}

# ---- topbar.py: the escape sequence scanner ----------------------------------
# It exists to answer two questions: where does a sequence end (so the bar is
# never painted into the middle of one), and does this sequence undo the
# arrangement. It classifies nothing else.

topbar_py() { # topbar_py <python-expression-body>
  python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('topbar', '$ISOPOD_ROOT/lib/topbar.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
$1"
}

@test "the scanner finds the end of each kind of escape sequence" {
  run topbar_py "
print(m.seq_end(b'\x1b[2J', 0))          # CSI
print(m.seq_end(b'\x1b]0;title\x07', 0)) # OSC ended by BEL
print(m.seq_end(b'\x1b]0;t\x1b\\\\', 0)) # OSC ended by ST
print(m.seq_end(b'\x1bc', 0))            # two-byte
print(m.seq_end(b'\x1b(B', 0))           # intermediate then final
"
  assert_line --index 0 '4'
  assert_line --index 1 '10'
  assert_line --index 2 '7'
  assert_line --index 3 '2'
  assert_line --index 4 '3'
}

@test "the scanner reports a cut-off sequence rather than guessing its end" {
  run topbar_py "
print(m.seq_end(b'\x1b[2', 0))
print(m.seq_end(b'\x1b]0;unterminated', 0))
print(m.seq_end(b'\x1b', 0))
"
  assert_output $'None\nNone\nNone'
}

@test "a sequence split across reads is never painted into" {
  run topbar_py "
s = m.Scanner()
print(s.feed(b'text\x1b[2'))   # ends mid-sequence: not safe to inject
print(s.feed(b'J'))            # completes it: damaging, and now safe
"
  assert_line --index 0 '(False, False)'
  assert_line --index 1 '(True, True)'
}

@test "a UTF-8 character split across reads is never painted into" {
  run topbar_py "
s = m.Scanner()
print(s.feed('日'.encode()[:2]))
print(s.feed('日'.encode()[2:]))
"
  assert_line --index 0 '(False, False)'
  assert_line --index 1 '(False, True)'
}

@test "the scanner recognizes what undoes the reserved row" {
  run topbar_py "
for seq in (b'\x1bc', b'\x1b[r', b'\x1b[2;24r', b'\x1b[!p', b'\x1b[2J', b'\x1b[3J',
            b'\x1b[?1049h', b'\x1b[?1049l', b'\x1b[?47h', b'\x1b[?6l',
            b'\x1b[?25l;6h'):
    print(m.damaging(seq))
"
  refute_output --partial 'False'
}

@test "the scanner leaves ordinary sequences alone" {
  run topbar_py "
for seq in (b'\x1b[0m', b'\x1b[1;1H', b'\x1b[K', b'\x1b[?25l', b'\x1b[38;2;1;2;3m',
            b'\x1b]0;title\x07', b'\x1b7'):
    print(m.damaging(seq))
"
  refute_output --partial 'True'
}

# The width matters: a bar short of the terminal leaves a gap, and one over it
# wraps onto the row the session is using.
@test "the bar fills the width exactly and picks readable text for its color" {
  run topbar_py "
import re
plain = lambda s: re.sub(rb'\x1b\\[[0-9;]*m', b'', s)
print(b'38;2;255;255;255' in m.bar_line('demo', (194, 65, 12), 20))  # white on dark
print(b'38;2;0;0;0' in m.bar_line('demo', (240, 240, 200), 20))      # black on pale
print(len(plain(m.bar_line('demo', (1, 2, 3), 20))))
print(len(plain(m.bar_line('a-very-long-box-name - Claude Code', (1, 2, 3), 12))))
"
  assert_line --index 0 'True'
  assert_line --index 1 'True'
  assert_line --index 2 '20'
  assert_line --index 3 '12'
}

# ---- topbar.py: mouse reports ------------------------------------------------
# Origin mode offsets what the agent DRAWS, but a mouse report carries physical
# coordinates and is offset by nothing, so a click on the agent's first row would
# arrive as row 2 and act on the wrong line. In a menu that means selecting the
# wrong entry, which is why every report is shifted on the way in.

@test "a mouse click is reported on the row the agent thinks it is on" {
  run topbar_py "
print(m.shift_mouse(b'\x1b[<0;10;5M'))     # SGR press, mode 1006
print(m.shift_mouse(b'\x1b[<0;10;5m'))     # SGR release
print(m.shift_mouse(b'\x1b[M' + bytes([32, 42, 37])))  # X10 encoding
"
  assert_line --index 0 "b'\x1b[<0;10;4M'"
  assert_line --index 1 "b'\x1b[<0;10;4m'"
  assert_line --index 2 "b'\x1b[M *\$'"
}

@test "a click on the bar row itself does not shift off the screen" {
  run topbar_py "print(m.shift_mouse(b'\x1b[<0;10;1M'))"
  assert_output "b'\x1b[<0;10;1M'"
}

@test "ordinary keys and other sequences reach the agent untouched" {
  run topbar_py "
for data in (b'hello', b'\x1b[A', b'\x1b', b'\x1b[200~paste\x1b[201~', b'\x03'):
    print(m.shift_mouse(data) == data)
"
  refute_output --partial 'False'
}

@test "a mouse report split across reads is not mangled" {
  # The tail is passed through whole rather than half-rewritten; the terminal
  # sends a report in one write, so this is the safe fallback, not the norm.
  run topbar_py "
out = m.shift_mouse(b'\x1b[<0;10')
print(out == b'\x1b[<0;10')
"
  assert_output 'True'
}
