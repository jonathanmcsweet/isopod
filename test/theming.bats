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

# ---- find_ide_bin (native binaries via stubs) --------------------------------
@test "find_ide_bin finds a native codium on PATH" {
  make_stub codium 0
  find_ide_bin codium
  assert_equal "${IDE_CMD[*]}" "codium"
}

@test "find_ide_bin falls back through codium/vscodium names" {
  make_stub vscodium 0
  find_ide_bin codium
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
  find_ide_bin codium
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
  run find_ide_bin codium
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
