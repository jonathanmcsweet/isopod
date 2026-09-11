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
# Four agent windows look identical: same box, same shell, same dark TUI. Each
# session gets a colored bar across the top row instead, drawn by lib/topbar.py,
# which reserves that row before the agent starts. Nothing here paints the
# terminal background: an agent leaves most cells at the default background, so
# coloring it recolors the whole window and fights whatever palette the agent
# draws with.

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
# plus 'box' for the sandbox's own color, 'agent' for the agent's own (which
# tells two agents apart in the same box), and 'off' for none. Returns 1 when
# there is no color, which callers treat as "no bar".
agent_color_resolve() { # agent_color_resolve <preset|hex|box|agent|off> <box> <agent>
  local spec="$1" box="${2:-}" agent="${3:-}"
  case "$spec" in
    '' | off | none) return 1 ;;
    box)
      [ -n "$box" ] || return 1
      spec="$(meta_get "$box" color 2>/dev/null || true)"
      [ -n "$spec" ] || return 1
      ;;
    agent)
      [ -n "$agent" ] || return 1
      spec="$(agent_preset "$agent")" || return 1
      ;;
  esac
  resolve_color "$spec"
}

# The color a session gets: ISOPOD_<AGENT>_COLOR if set, else the box's own color
# the way `isopod code` tints the IDE, falling back to the agent's own color for
# a box that somehow has none.
agent_color() { # agent_color <agent> <box>
  local agent="$1" box="${2:-}" var="ISOPOD_${1^^}_COLOR" want
  want="${!var:-}"
  if [ -n "$want" ]; then
    agent_color_resolve "$want" "$box" "$agent"
    return
  fi
  agent_color_resolve box "$box" "$agent" ||
    agent_color_resolve agent "$box" "$agent"
}

# Only theme a real terminal: a session whose output is captured to a file or
# piped somewhere gets nothing, since escape sequences would corrupt it. NO_COLOR
# is the cross-tool convention for "never emit color" and is honored here as well
# as at the flag.
term_can_theme() {
  [ -t 1 ] || return 1
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-dumb}" != dumb ]
}

# The window and icon title: what a taskbar, a tab bar and tmux all read. Set
# even when there is no bar, since a tab called "api - Codex" earns its place on
# its own.
term_set_title() { # term_set_title <title>
  term_can_theme || return 0
  printf '\033]0;%s\007' "$(sanitize "$1")"
}
