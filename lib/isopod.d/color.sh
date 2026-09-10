#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines box color theming.

# ---------------------------------------------------------------------------
# color theming
# ---------------------------------------------------------------------------
# Look up a preset name in the share/colors palette. 'grey' is an alias for
# 'gray'; an unknown name returns 1 (callers treat that as "not a preset").
preset_color() {
  local want="$1"
  [ "$want" = grey ] && want=gray
  local f="$ISOPOD_SHARE/colors" name hex
  [ -f "$f" ] || die "missing palette: $f (is your isopod install complete?)"
  while read -r name hex; do
    case "$name" in '' | '#'*) continue ;; esac # skip blanks and comments
    [ "$name" = "$want" ] && {
      printf '%s' "$hex"
      return 0
    }
  done <"$f"
  return 1
}

auto_color() { # auto_color <name> -> a preset derived from the name (stable)
  local name="$1"
  local presets=(teal blue purple magenta orange green amber red gray)
  # Derive the color from a hash of the name, not a live box count: a given name
  # always gets the same color, and creating/deleting other boxes never shifts
  # it (a count-based index could collide with a still-existing box).
  local h idx
  h=$(printf '%s' "$name" | sha_hex | cut -c1-6)
  idx=$((16#$h % ${#presets[@]}))
  preset_color "${presets[$idx]}"
}

# Resolve a color to a #rrggbb hex: a 6-hex value (with/without '#') passes
# through; anything else is a preset name. Prints the hex, or returns 1 for an
# unknown preset so the caller dies with its own message.
resolve_color() { # resolve_color <preset|hex>
  local c="$1"
  if [[ "$c" =~ ^#?[0-9a-fA-F]{6}$ ]]; then
    printf '%s' "#${c#\#}"
  else
    preset_color "$c"
  fi
}

# Write/merge .vscode/settings.json inside the box so every IDE window
# attached to this box is tinted. Lives in the container, not on the host.
# The merge logic lives in lib/apply_color.py; we stream it into the box over
# SSH stdin so nothing is left behind on the container filesystem, and so it
# reaches the workload under any runtime (a microVM included). sshd does not
# import the client environment, so the box-specific values are passed inline
# with `env` on the remote command.
apply_color() { # apply_color <name> <hexcolor>
  local name="$1" hex="$2" script="$ISOPOD_LIB/apply_color.py"
  [ -f "$script" ] || die "missing helper: $script (is your isopod install complete?)"
  # The box picks which python3 runs here, so both streams are box-controlled and
  # get the same control-character stripping as every other box output the host
  # prints. This runs on start/restart too, i.e. exactly when the user is
  # re-attaching to a box that may already be compromised.
  #
  # Captured, NOT piped through `> >(sanitize_stream)`: bash does not wait for a
  # process substitution, and ssh can leave the pipe's write end open in a child,
  # so the reader never sees EOF and create hangs. Deadlocked a create for hours.
  local out="" err="" errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/isopod-color.XXXXXX")" || die "could not create a temp file"
  out="$(box_ssh "$name" -- \
    env "ISOPOD_COLOR=$hex" "ISOPOD_NAME=$name" "ISOPOD_WS=$WORKSPACE" \
    python3 - <"$script" 2>"$errf")" || rc=$?
  err="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  [ -n "$out" ] && printf '%s\n' "$out" | sanitize_stream
  [ -n "$err" ] && printf '%s\n' "$err" | sanitize_stream >&2
  return "$rc"
}

# ---------------------------------------------------------------------------
# agent terminal theming
# ---------------------------------------------------------------------------
# Four coding agents in four windows look identical: same box, same shell, same
# dark TUI. These give each agent a color and put it on the TERMINAL rather than
# on the agent, because none of the four takes an accent color from the command
# line, and the OSC sequences below are understood by every terminal in
# share/terminal-targets. So the window says which agent it is from across the
# room, and keeps saying it after the first screen has scrolled away.

agent_preset() { # agent_preset <agent> -> its preset name from share/agent-colors
  local want="$1" f="$ISOPOD_SHARE/agent-colors" name preset
  [ -f "$f" ] || die "missing palette: $f (is your isopod install complete?)"
  while read -r name preset; do
    case "$name" in '' | '#'*) continue ;; esac # skip blanks and comments
    [ "$name" = "$want" ] && {
      printf '%s' "$preset"
      return 0
    }
  done <"$f"
  return 1
}

# Resolve one color spec to a hex: a preset or '#rrggbb' as everywhere else,
# plus 'box' for the sandbox's own color (for anyone who would rather code by
# sandbox than by tool) and 'off' for none. Returns 1 when there is no color,
# which every caller treats as "leave the terminal alone".
agent_color_resolve() { # agent_color_resolve <preset|hex|box|off> [box]
  local spec="$1" box="${2:-}"
  case "$spec" in
    '' | off | none) return 1 ;;
    box)
      [ -n "$box" ] || return 1
      spec="$(meta_get "$box" color 2>/dev/null || true)"
      [ -n "$spec" ] || return 1
      ;;
  esac
  resolve_color "$spec"
}

# The color an agent gets: ISOPOD_<AGENT>_COLOR wins, else the table.
agent_color() { # agent_color <agent> [box]
  local agent="$1" box="${2:-}" var="ISOPOD_${1^^}_COLOR" want
  want="${!var:-}"
  [ -n "$want" ] || want="$(agent_preset "$agent")" || return 1
  agent_color_resolve "$want" "$box"
}

# Mix two #rrggbb colors: <pct> percent of the first, the rest of the second.
hex_blend() { # hex_blend <hex> <hex> <pct>
  local a="${1#\#}" b="${2#\#}" p="$3" out="#" i v
  for i in 0 2 4; do
    v=$(((16#${a:i:2} * p + 16#${b:i:2} * (100 - p)) / 100))
    out+="$(printf '%02x' "$v")"
  done
  printf '%s' "$out"
}

# Scale a color to a fixed peak channel, keeping its hue. The palette entries are
# not equally bright (teal peaks at 0x76, blue at 0xd8), so taking the same
# percentage of each would leave some windows obviously tinted and others barely
# changed. Scaling every one to the same peak gives backgrounds of equal depth
# that are still unmistakably different from each other.
hex_peak() { # hex_peak <hex> <peak 0-255>
  local h="${1#\#}" t="$2" r g b m out="#" v
  r=$((16#${h:0:2})) g=$((16#${h:2:2})) b=$((16#${h:4:2}))
  m=$r
  [ "$g" -gt "$m" ] && m=$g
  [ "$b" -gt "$m" ] && m=$b
  [ "$m" -gt 0 ] || {
    printf '#000000'
    return 0
  }
  for v in "$r" "$g" "$b"; do out+="$(printf '%02x' $((v * t / m)))"; done
  printf '%s' "$out"
}

# The background a tinted window gets: a very dark version of the agent's color,
# never the color itself. It reads as "this is the orange one" from across the
# room and leaves every foreground the agent draws with legible.
# ISOPOD_AGENT_TINT=light gives a pale version instead, for a light-themed
# terminal, and =off keeps the title and the banner while leaving the background
# to whoever set it.
term_tint_bg() { # term_tint_bg <hex>
  case "${ISOPOD_AGENT_TINT:-dark}" in
    dark) hex_peak "$1" 42 ;;
    light) hex_blend "$(hex_peak "$1" 255)" "#ffffff" 12 ;;
    *) return 1 ;;
  esac
}

# Only paint a real terminal: theming output that is being captured to a file or
# piped to another program would corrupt it and color nothing. NO_COLOR is the
# cross-tool convention for "never emit color", and is honored here as well as
# at the flag.
term_can_theme() {
  [ -t 1 ] || return 1
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-dumb}" != dumb ]
}

# Inside tmux or screen the background and the cursor belong to the OUTER
# terminal, so setting them would tint every pane of the session rather than
# this one. Those two are skipped there; the title and the banner still carry
# the agent, and tmux takes its window name from the title.
term_multiplexed() { [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ]; }

# Set by term_theme_on so on_exit puts the terminal back however isopod ends: a
# clean exit, a failed ssh, or Ctrl-C. Only a SIGKILL can leave a tint behind.
TERM_THEMED=0

term_theme_on() { # term_theme_on <hex|''> <title>
  term_can_theme || return 0
  # OSC 0 sets the window and icon title: what a taskbar, a tab bar and tmux
  # all read.
  printf '\033]0;%s\007' "$(sanitize "$2")"
  [ -n "$1" ] || return 0
  term_multiplexed && return 0
  local bg
  bg="$(term_tint_bg "$1")" || return 0
  # OSC 11 background, OSC 12 cursor.
  printf '\033]11;%s\007\033]12;%s\007' "$bg" "$1"
  TERM_THEMED=1
  return 0
}

term_theme_off() {
  [ "$TERM_THEMED" = 1 ] || return 0
  TERM_THEMED=0
  # OSC 111/112 reset each to the terminal's own configured value, which is what
  # the user wants back, and is something isopod never learned.
  printf '\033]111\007\033]112\007'
}

# A bar in the agent's color. It covers the terminals that ignore OSC 11, and it
# stays in the scrollback as a marker of where this session began.
term_theme_banner() { # term_theme_banner <hex> <text>
  term_can_theme || return 0
  local h="${1#\#}"
  printf '\033[1;48;2;%d;%d;%d;38;2;255;255;255m %s \033[0m\n' \
    "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))" "$(sanitize "$2")"
}
