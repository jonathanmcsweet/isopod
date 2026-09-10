# shellcheck shell=bash
#
# agent — the shared path for running a coding agent inside a box.
#
# Every agent is delivered the same way, and the parts worth getting right are
# the parts they share: fetch on the HOST, verify the digest before anything
# crosses the boundary, stream it in over the existing SSH channel, then open a
# session in a new terminal window. Nothing in the box downloads or runs an
# installer, so the box needs no network for the install and the bytes are checked
# before they arrive.
#
# Per-agent differences live in the adapter modules (claude-code-installer.sh,
# codex-installer.sh, opencode-installer.sh, pi-installer.sh), which each supply
# two things:
#
#   <agent>_resolve <arch> <libc> <simd>
#                                   prints: version TAB sha256 TAB url TAB artifact
#                                   (an adapter uses only the facts it needs)
#   <agent>_box_install <artifact>  prints the /bin/sh to run in the box after
#                                   transfer, which must leave $AGENT_BIN on PATH
#
# and set their constants through agent_select below. Everything else is here.

# Set by agent_select; read by the shared functions and by share/agent-egress.txt.
AGENT=""          # adapter prefix, e.g. "claude"
AGENT_LABEL=""    # what to call it in messages
AGENT_BIN=""      # the binary's name inside the box
AGENT_SECRET=""   # host secret holding its API key
AGENT_DOMAINS=""  # hostnames it needs reachable, space separated
AGENT_API_KEY=""  # filled by agent_ensure_key
AGENT_KEY_ASKED=0 # so a fallback to --attach in this process does not ask twice
AGENT_MISSING_DOMAINS=""

# Where an agent's binary may sit in the box. Each installer picks its own
# location and a non-login SSH command sources no shell rc, so every candidate
# goes on PATH rather than being assumed.
AGENT_BOX_PATH='$HOME/.local/bin:$HOME/.claude/bin:$HOME/.opencode/bin:$HOME/.local/share/pi:$HOME/bin:$PATH'

agent_select() { # agent_select <claude|codex|opencode|pi>
  case "$1" in
    claude)
      AGENT=claude
      AGENT_LABEL="Claude Code"
      AGENT_BIN=claude
      AGENT_SECRET="$ISOPOD_CLAUDE_SECRET"
      AGENT_DOMAINS="$ISOPOD_CLAUDE_DOMAINS"
      ;;
    codex)
      AGENT=codex
      AGENT_LABEL="Codex"
      AGENT_BIN=codex
      AGENT_SECRET="$ISOPOD_CODEX_SECRET"
      AGENT_DOMAINS="$ISOPOD_CODEX_DOMAINS"
      ;;
    opencode)
      AGENT=opencode
      AGENT_LABEL="opencode"
      AGENT_BIN=opencode
      AGENT_SECRET="$ISOPOD_OPENCODE_SECRET"
      AGENT_DOMAINS="$ISOPOD_OPENCODE_DOMAINS"
      ;;
    pi)
      AGENT=pi
      AGENT_LABEL="Pi"
      AGENT_BIN=pi
      AGENT_SECRET="$ISOPOD_PI_SECRET"
      AGENT_DOMAINS="$ISOPOD_PI_DOMAINS"
      ;;
    *) die "unknown agent: $1" ;;
  esac
}

# Ask the BOX what it is, never the host: isopod runs on macOS and Linux, a box is
# always Linux, and both sides come in amd64 and arm64. Prints
# "<arch> <libc> <simd>", e.g. "x86_64 glibc avx2". The libc markers are the ones
# upstream installers use; the AVX2 answer is the one opencode's does, because
# its x64 build needs that instruction set and dies without it. An adapter reads
# only the facts its own downloads depend on.
agent_box_facts() { # agent_box_facts <name> -> "<arch> <libc> <simd>"
  local facts
  facts="$(box_ssh "$1" -- 'sh -c '"$(shq '
    a="$(uname -m)"
    if [ -e "/lib/libc.musl-x86_64.so.1" ] || [ -e "/lib/libc.musl-aarch64.so.1" ] ||
       ldd /bin/ls 2>&1 | grep -q musl; then
      l=musl
    else
      l=glibc
    fi
    if grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
      s=avx2
    else
      s=noavx2
    fi
    printf "%s %s %s" "$a" "$l" "$s"')" 2>/dev/null)" ||
    die "could not read the architecture of box '$1' (is it running?)"
  # This becomes a URL and a cache path, so only plain tokens pass.
  [[ "$facts" =~ ^[A-Za-z0-9_]+\ (glibc|musl)\ (avx2|noavx2)$ ]] ||
    die "box '$1' reported an architecture isopod does not recognize: '$(sanitize "$facts")'"
  printf '%s' "$facts"
}

# One place for the fetch flags, so every request is HTTPS-only with a bounded
# wait rather than hanging a launch on a stalled endpoint.
agent_curl() { # agent_curl <url> [curl-args...]
  local url="$1"
  shift
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 900 "$@" "$url"
}

# Download and verify, or reuse an already-verified copy. Prints the cached path.
# Nothing reaches its final name until the digest matches, so a failed or
# interrupted download can never be picked up as a cache hit later.
agent_fetch_verified() { # agent_fetch_verified <version> <platform> <url> <sha256> <artifact>
  local ver="$1" plat="$2" url="$3" want="$4" artifact="$5" dir cached tmp got
  dir="$CACHE_DIR/$AGENT/$ver/$plat"
  cached="$dir/$artifact"
  [ -f "$cached" ] && {
    printf '%s' "$cached"
    return 0
  }
  have curl || die "isopod needs curl on the host to download $AGENT_LABEL"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.dl-XXXXXX")"
  # This function's stdout IS the path the caller reads, so progress goes to
  # stderr or it would be captured as part of that path.
  info "Downloading $AGENT_LABEL $ver ($plat)..." >&2
  if ! agent_curl "$url" -o "$tmp"; then
    rm -f "$tmp"
    die "download failed: $url"
  fi
  got="$(sha256_full <"$tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    die "checksum mismatch for $AGENT_LABEL $ver ($plat).
     expected $want
     got      $got
     Nothing was installed. Retry, and if it persists do not install this build."
  fi
  chmod 644 "$tmp"
  mv "$tmp" "$cached"
  printf '%s' "$cached"
}

# Three of the four agents ship as a .tar.gz around one binary, and installing it
# is the same three steps every time. The script runs as `sh -c <script>` with no
# positional arguments, so every name is substituted in here. The destination
# directory is isopod's own text and keeps $HOME for the box shell to expand; the
# archive names come from upstream and are quoted.
agent_tar_install_script() { # agent_tar_install_script <artifact> <inner> <dir> <name>
  printf 'set -e
cd "$HOME/.isopod-agent"
tar -xzf %s
[ -f %s ] || { echo "archive did not contain %s" >&2; exit 1; }
mkdir -p "%s"
chmod 755 %s
mv -f %s "%s/%s"' \
    "$(shq "$1")" "$(shq "$2")" "$2" "$3" "$(shq "$2")" "$(shq "$2")" "$3" "$4"
}

# Is the agent already in the box? The check is presence, never currency:
# upgrades belong to the person using the box.
agent_in_box() { # agent_in_box <name>
  box_ssh "$1" -- "PATH=$AGENT_BOX_PATH command -v $AGENT_BIN >/dev/null 2>&1" 2>/dev/null
}

# Fetch, verify, stream in, verify again, then let the adapter install it.
agent_ensure_installed() { # agent_ensure_installed <name>
  local name="$1" facts arch libc simd resolved ver want url artifact cached script
  agent_in_box "$name" && return 0
  facts="$(agent_box_facts "$name")"
  read -r arch libc simd <<<"$facts"
  resolved="$("${AGENT}_resolve" "$arch" "$libc" "$simd")" ||
    die "could not work out which $AGENT_LABEL build this box needs"
  IFS=$'\t' read -r ver want url artifact <<<"$resolved"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "refusing a $AGENT_LABEL download with no usable checksum"
  cached="$(agent_fetch_verified "$ver" "$arch-$libc" "$url" "$want" "$artifact")"

  info "Installing $AGENT_LABEL $ver into '$name'..."
  box_ssh "$name" -- 'mkdir -p "$HOME/.isopod-agent"' ||
    die "could not create the staging directory in '$name'"
  tar -C "$(dirname "$cached")" -cf - "$artifact" |
    box_tar_in "$name" '$HOME/.isopod-agent' ||
    die "could not copy $AGENT_LABEL into '$name'"
  # Re-hash on the far side: a truncated stream is a corrupt binary, and saying so
  # here beats an unexplained failure at launch.
  box_ssh "$name" -- "cd \"\$HOME/.isopod-agent\" && printf '%s  %s\n' $(shq "$want") $(shq "$artifact") | sha256sum -c --status" ||
    die "$AGENT_LABEL arrived in '$name' corrupted (checksum mismatch after transfer)"
  script="$("${AGENT}_box_install" "$artifact")"
  box_ssh "$name" -- "sh -c $(shq "$script")" ||
    die "installing $AGENT_LABEL inside '$name' failed"
  box_ssh "$name" -- 'rm -rf "$HOME/.isopod-agent"' || true
  agent_in_box "$name" ||
    die "$AGENT_LABEL installed in '$name' but is not on PATH there — report this with the output above"
  info "$AGENT_LABEL $ver installed in '$name'"
}

# Offer to store an API key when there is none. Declining is fine: every agent
# runs its own sign-in, and a subscription login needs no key at all. Asked at
# most once per run: with no terminal to open, agent_run falls back to --attach
# in this same process, and a second prompt there looks like the first one failed.
#
# An agent with no secret of its own is never asked about one. opencode and Pi
# sign themselves in, so prompting for a key they did not ask for would name a
# provider isopod picked rather than the user, and put a key in a box that has no
# use for it. Setting ISOPOD_OPENCODE_SECRET or ISOPOD_PI_SECRET opts back in.
agent_ensure_key() {
  [ -n "$AGENT_SECRET" ] || return 0
  [ "$AGENT_KEY_ASKED" = 1 ] && return 0
  AGENT_KEY_ASKED=1
  AGENT_API_KEY=""
  local val
  if val="$(secret_store_get "$AGENT_SECRET" 2>/dev/null)" && [ -n "$val" ]; then
    AGENT_API_KEY="$val"
    return 0
  fi
  [ -t 0 ] || return 0 # non-interactive: let the agent handle sign-in itself
  info "No $AGENT_SECRET is stored. Paste one to use it in this box, or press enter
       to skip and let $AGENT_LABEL sign you in its own way."
  printf 'value for %s (input hidden, enter to skip): ' "$AGENT_SECRET" >&2
  local reply
  IFS= read -rs reply
  printf '\n' >&2
  [ -n "$reply" ] || return 0
  printf '%s' "$reply" | secret_store_set "$AGENT_SECRET"
  info "stored secret '$AGENT_SECRET' ($(secret_backend) backend) — reused for every box"
  AGENT_API_KEY="$reply"
}

# Hand the key to the box out of band. It goes to /dev/shm, a tmpfs the engine
# mounts for every box, so the value is memory-backed, invisible to reconfigure
# snapshots and to export, and gone when the box stops. The session reads it once
# and unlinks it. The value travels SSH stdin only, never argv or env on either
# side.
agent_stage_key() { # agent_stage_key <name> -> prints the staged path
  local path
  path="/dev/shm/.isopod-agent-$$-$RANDOM"
  printf '%s' "$AGENT_API_KEY" |
    box_ssh "$1" -- "umask 077 && cat > $(shq "$path")" ||
    die "could not hand the API key to '$1'"
  printf '%s' "$path"
}

# Name the hostnames an allow-list box is missing, and change nothing. The
# allow-list is one filter file for the whole host, so widening it silently would
# affect every allow-list box rather than only this one.
agent_egress_note() { # agent_egress_note <name>
  [ "$(meta_get "$1" offline 2>/dev/null || true)" = 1 ] && return 0
  [ "$(active_egress)" = "allow-list" ] || return 0
  local name="$1" allowed missing="" d
  allowed="$(
    egress_allowlist_domains "$ISOPOD_EGRESS_ALLOWLIST"
    egress_allowlist_domains "$USER_EGRESS_ALLOWLIST"
  )"
  # Space-separated constant; the split is the point.
  # shellcheck disable=SC2086
  for d in $AGENT_DOMAINS; do
    printf '%s\n' "$allowed" | grep -qxF "$d" || missing="$missing $d"
  done
  [ -n "$missing" ] || return 0
  # Read by share/agent-egress.txt at render time, which shellcheck cannot see.
  # shellcheck disable=SC2034
  AGENT_MISSING_DOMAINS="${missing# }"
  # $name and $AGENT_* reach the template through bash dynamic scope.
  render_tmpl agent-egress.txt >&2
}

# Resolved terminal launch command, and the row's canonical name for messages.
# TERM_MACOS_APP is set instead of TERM_CMD when the match is a macOS .app, which
# takes a script path via `open -a` rather than a command after a flag.
TERM_CMD=()
TERM_NAME=""
TERM_MACOS_APP=""

# Resolve a terminal name to a launch command via the share/terminal-targets
# table: PATH binaries, then a macOS app, then flatpak ids. With no name, walk the
# table in order and take the first one installed. Mirrors find_ide_bin; terminals
# need one extra column, the flag that introduces a command, because
# gnome-terminal, konsole and kitty all spell it differently.
find_term_bin() { # find_term_bin [app] -> sets TERM_CMD/TERM_NAME, returns 0/1
  local app="${1:-}" f="$ISOPOD_SHARE/terminal-targets"
  TERM_CMD=()
  TERM_NAME=""
  TERM_MACOS_APP=""
  [ -f "$f" ] || die "missing terminal target table: $f (is your isopod install complete?)"
  local aliases bins macapp execarg flatpaks b id canon
  local -a blist flist elist
  while read -r aliases bins macapp execarg flatpaks; do
    case "$aliases" in '' | '#'*) continue ;; esac
    if [ -n "$app" ]; then
      case ",$aliases," in *",$app,"*) ;; *) continue ;; esac
    fi
    canon="${aliases%%,*}"
    elist=()
    [ "$execarg" != "-" ] && IFS=',' read -ra elist <<<"$execarg"
    IFS=',' read -ra blist <<<"$bins"
    for b in "${blist[@]}"; do
      have "$b" && {
        TERM_CMD=("$b" ${elist[@]+"${elist[@]}"})
        TERM_NAME="$canon"
        return 0
      }
    done
    if [ "$macapp" != "-" ] && is_macos && [ -d "/Applications/$macapp.app" ]; then
      TERM_MACOS_APP="$macapp"
      TERM_NAME="$canon"
      return 0
    fi
    if [ "$flatpaks" != "-" ]; then
      IFS=',' read -ra flist <<<"$flatpaks"
      for id in "${flist[@]}"; do
        if have flatpak && flatpak info "$id" >/dev/null 2>&1; then
          TERM_CMD=(flatpak run "$id" ${elist[@]+"${elist[@]}"})
          TERM_NAME="$canon"
          return 0
        fi
      done
    fi
    # An explicit --app matched this row and nothing is installed for it; with no
    # --app, keep walking the table.
    [ -n "$app" ] && return 1
  done <"$f"
  # An explicit name that is not in the table: try it as a plain command.
  if [ -n "$app" ] && have "$app"; then
    TERM_CMD=("$app" -e)
    TERM_NAME="$app"
    return 0
  fi
  return 1
}

# Can this host open a window at all? A box reached over SSH, or a headless
# server, has nowhere to put one, and running in place there is correct rather
# than an error.
can_open_window() {
  is_macos && return 0
  [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

# The whole command: start the box, install the agent if it is missing, then open
# a session. Shared by isopod claude-code and isopod codex; the caller has already
# run agent_select.
agent_run() { # agent_run <argv...>
  local name="" app="${ISOPOD_TERMINAL:-}" attach=0 color="" nocolor=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
      -h | --help | help)
        render_tmpl "$AGENT-help.txt"
        return 0
        ;;
      --app)
        app="$2"
        shift 2
        ;;
      --attach)
        attach=1
        shift
        ;;
      --color)
        color="$2"
        shift 2
        ;;
      --no-color)
        nocolor=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*) die "unknown option for $AGENT: $1" ;;
      *)
        [ -z "$name" ] && name="$1" && shift || break
        ;;
    esac
  done
  local -a rcmd=("$@")
  [ -n "$name" ] || die "usage: isopod $AGENT <name> [--app TERMINAL] [--attach] [--color C] [-- args...]"
  open_box "$name"
  [ "$(meta_get "$name" offline 2>/dev/null || true)" = 1 ] &&
    die "'$name' is offline, so $AGENT_LABEL could not reach its API from it.
     Copying the binary in would work, but it would have nothing to talk to."

  # Resolved once, here, and passed to the window opened below as a hex, so the
  # session that gets themed is the one the user is looking at and both halves
  # agree on the color even if the environment differs between them.
  local hex=""
  if [ "$nocolor" = 0 ]; then
    if [ -n "$color" ]; then
      hex="$(agent_color_resolve "$color" "$name")" ||
        die "unknown color '$color' (use a preset name, '#rrggbb', 'box', or --no-color)"
    else
      hex="$(agent_color "$AGENT" "$name" || true)"
    fi
  fi
  local -a colorargs=(--no-color)
  [ -n "$hex" ] && colorargs=(--color "$hex")

  # The window opened below re-runs this command with --attach, which is this
  # branch: no install, no prompts, just the session. Keeping setup in the calling
  # terminal is deliberate, since a hidden key prompt in a window that just
  # appeared is easy to miss.
  if [ "$attach" = 1 ]; then
    agent_start_box "$name"
    agent_ensure_key
    local keypath="" pre=""
    if [ -n "$AGENT_API_KEY" ]; then
      keypath="$(agent_stage_key "$name")"
      # Read once, unlink immediately, so the value lives in this session's
      # environment and nowhere else.
      pre="$AGENT_SECRET=\$(cat $(shq "$keypath")); rm -f $(shq "$keypath"); export $AGENT_SECRET; "
    fi
    agent_theme "$name" "$hex"
    box_ssh "$name" -t -- "${pre}cd '$WORKSPACE' 2>/dev/null; PATH=$AGENT_BOX_PATH exec $AGENT_BIN ${rcmd[*]:-}"
    return
  fi

  agent_start_box "$name"
  agent_ensure_installed "$name"
  agent_ensure_key
  agent_egress_note "$name"

  local -a pass=()
  [ "${#rcmd[@]}" -gt 0 ] && pass=(-- "${rcmd[@]}")
  if ! can_open_window || ! find_term_bin "$app"; then
    if [ -n "$app" ] && can_open_window; then
      die "could not find the terminal '$app' (checked PATH, /Applications, and Flatpak).
     Run 'isopod $AGENT $name --attach' to use this window instead."
    fi
    info "Opening $AGENT_LABEL in this window (no terminal to open one in)."
    agent_run "$name" --attach "${colorargs[@]}" ${pass[@]+"${pass[@]}"}
    return
  fi

  local log
  log="$(box_dir "$name")/$AGENT-launch.log"
  if [ -n "$TERM_MACOS_APP" ]; then
    # macOS has no -e convention: `open -a App <script>` runs a script in a new
    # window, which beats quoting a command through AppleScript.
    local launcher a
    launcher="$(box_dir "$name")/$AGENT-launch.command"
    {
      printf '#!/bin/sh\n'
      printf 'exec %s %s %s --attach' "$(shq "$ISOPOD_BIN")" "$AGENT" "$(shq "$name")"
      for a in "${colorargs[@]}"; do printf ' %s' "$(shq "$a")"; done
      printf '\n'
    } >"$launcher"
    chmod 755 "$launcher"
    open -a "$TERM_MACOS_APP" "$launcher" >"$log" 2>&1 ||
      die "could not open $TERM_NAME — see $log"
  else
    "${TERM_CMD[@]}" "$ISOPOD_BIN" "$AGENT" "$name" --attach "${colorargs[@]}" \
      ${pass[@]+"${pass[@]}"} >"$log" 2>&1 &
    disown || true
  fi
  info "$AGENT_LABEL opened in a new $TERM_NAME window for '$name'
       (if no window appears, check $log, or use --attach to run here)"
}

# Title, tint and banner for the window this session owns. The box comes first in
# the title because the color already says which agent this is, and a tab bar
# truncates the end; the title is set even with no color, since a tab called
# "api - Codex" is worth having on its own.
agent_theme() { # agent_theme <name> <hex|''>
  local label="$1 - $AGENT_LABEL"
  term_theme_on "$2" "$label"
  [ -n "$2" ] && term_theme_banner "$2" "$label"
  return 0
}

# Start a stopped box and refresh its port, the way shell and code do.
agent_start_box() { # agent_start_box <name>
  acquire_lock
  local status
  status=$(box_status "$1" 2>/dev/null || true)
  [ "$status" = "running" ] || cmd_start "$1"
  refresh_port "$1"
  release_lock
}
