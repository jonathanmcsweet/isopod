#!/usr/bin/env bash
#
# install.sh — install (or uninstall) isopod using each platform's conventions.
#
# isopod is multi-file: the `isopod` script needs its `lib/` folder beside it.
# This installer copies the whole project into one program directory and puts a
# symlink to the `isopod` entry point on your PATH. isopod resolves its own
# location through that symlink, so `lib/` is always found.
#
# Usage:
#   ./install.sh                 # auto-detect best per-user location, install
#   ./install.sh --system        # system-wide (/usr/local), needs sudo/root
#   ./install.sh --prefix DIR     # install program dir under DIR/lib, link in DIR/bin
#   ./install.sh --uninstall      # remove a previous install
#   ./install.sh --check          # print what it would do, make no changes
#   ./install.sh --no-extension   # skip installing the editor's Remote-SSH extension
#   ./install.sh --help
#
# Honors $DESTDIR for packaging. Safe to re-run (idempotent).
set -euo pipefail

APP=isopod
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%swarning:%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
die()  { printf '%serror:%s %s\n'  "$c_red" "$c_rst" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

MODE=install
SCOPE=user
PREFIX=""
DRYRUN=0
WANT_EXT=1

# Editor extension isopod pairs with (lives on Open VSX).
EXT_ID="jeanp413.open-remote-ssh"

while [ $# -gt 0 ]; do
  case "$1" in
    --system)       SCOPE=system; shift ;;
    --user)         SCOPE=user; shift ;;
    --prefix)       PREFIX="$2"; SCOPE=prefix; shift 2 ;;
    --uninstall)    MODE=uninstall; shift ;;
    --check)        DRYRUN=1; shift ;;
    --no-extension) WANT_EXT=0; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'
      exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- sanity: are we sitting on a real isopod source tree? --------------------
[ -f "$SELF_DIR/$APP" ] || die "can't find the '$APP' script next to this installer ($SELF_DIR)"
[ -f "$SELF_DIR/lib/apply_color.py" ] || die "missing lib/apply_color.py — incomplete source tree"

# --- detect OS for messaging + engine hints --------------------------------
OS="$(uname -s)"
IS_IMMUTABLE=0
DISTRO=""
if [ "$OS" = "Linux" ] && [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${ID:-}"
  # Immutable Fedora variants (Silverblue/Kinoite/Sericea/atomic, Universal Blue)
  # are detectable by ostree being the deployment mechanism.
  if [ -d /run/ostree ] || [ -f /run/ostree-booted ] || have rpm-ostree; then
    IS_IMMUTABLE=1
  fi
fi

# --- choose install locations ----------------------------------------------
# Program files go in <libroot>/isopod; the entry point is symlinked into <bindir>.
case "$SCOPE" in
  prefix)
    [ -n "$PREFIX" ] || die "--prefix requires a directory"
    LIBROOT="$PREFIX/lib"; BINDIR="$PREFIX/bin" ;;
  system)
    # /usr/local is writable even on immutable Fedora (it's a symlink into /var).
    LIBROOT="/usr/local/lib"; BINDIR="/usr/local/bin" ;;
  user)
    if [ "$OS" = "Darwin" ] && have brew; then
      # Align with Homebrew so bin is already on PATH (Apple Silicon or Intel).
      _bp="$(brew --prefix)"
      LIBROOT="$_bp/lib"; BINDIR="$_bp/bin"
    else
      # XDG-style per-user layout. On immutable Fedora, $HOME is /var/home and
      # fully writable, so this is the recommended path there too.
      LIBROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
      BINDIR="$HOME/.local/bin"
    fi ;;
esac

# Apply DESTDIR (packaging staging) if set.
DEST="${DESTDIR:-}"
PROGDIR="$DEST$LIBROOT/$APP"
LINK="$DEST$BINDIR/$APP"

run() { # echo + execute, unless dry-run
  printf '   %s%s%s\n' "$c_dim" "$*" "$c_rst"
  [ "$DRYRUN" -eq 1 ] || "$@"
}

need_sudo_hint() {
  if [ "$SCOPE" = "system" ] && [ "$(id -u)" -ne 0 ] && [ -z "$DEST" ]; then
    warn "system install writes to $LIBROOT and $BINDIR — re-run with sudo if this fails."
  fi
}

# --- editor extension -------------------------------------------------------
# isopod is normally driven from VSCodium / VS Code via the Remote-SSH
# extension. Find a usable editor CLI on THIS machine (the one running the
# editor) and install the extension from Open VSX if it isn't already there.
# This is best-effort: a failure here never fails the isopod install.

# Print a command that invokes an available editor CLI, or nothing if none.
find_editor_cli() {
  local c
  for c in codium vscodium code-oss code cursor; do
    if have "$c"; then printf '%s' "$c"; return 0; fi
  done
  # Flatpak VSCodium (e.g. immutable Fedora) exposes no bare `codium` on PATH.
  if have flatpak && flatpak info com.vscodium.codium >/dev/null 2>&1; then
    printf 'flatpak run com.vscodium.codium'; return 0
  fi
  if have flatpak && flatpak info com.visualstudio.code >/dev/null 2>&1; then
    printf 'flatpak run com.visualstudio.code'; return 0
  fi
  return 1
}

install_extension() {
  [ "$WANT_EXT" -eq 1 ] || { info "Skipping editor extension (--no-extension)."; return 0; }

  local cli
  if ! cli="$(find_editor_cli)"; then
    warn "No VSCodium/VS Code CLI found on this machine — skipping the $EXT_ID extension."
    printf '   Install it later from your editor, or with:\n'
    printf '       %s<editor> --install-extension %s%s\n' "$c_dim" "$EXT_ID" "$c_rst"
    return 0
  fi

  info "Editor extension"
  printf '   editor CLI      : %s\n' "$cli"
  printf '   extension       : %s\n' "$EXT_ID"

  # Already installed? Keep it idempotent like the rest of the installer.
  if [ "$DRYRUN" -eq 0 ] && $cli --list-extensions 2>/dev/null | grep -qix "$EXT_ID"; then
    printf '   %salready installed — nothing to do%s\n' "$c_dim" "$c_rst"
    return 0
  fi

  # $cli may be a multi-word command ("flatpak run ..."), so don't quote it.
  # shellcheck disable=SC2086
  run $cli --install-extension "$EXT_ID" --force || \
    warn "couldn't install $EXT_ID automatically — add it from your editor's Extensions view."
}

# --- uninstall --------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
  info "Uninstalling $APP"
  [ -L "$LINK" ] || [ -e "$LINK" ] && run rm -f "$LINK" || true
  [ -d "$PROGDIR" ] && run rm -rf "$PROGDIR" || true
  info "Removed program dir and symlink (if they existed)."
  printf '%sNote:%s your sandboxes and keys under ~/.config/isopod were left intact.\n' "$c_dim" "$c_rst"
  printf '      Run %sisopod rm <name>%s for each box first if you want them gone.\n' "$c_dim" "$c_rst"
  exit 0
fi

# --- install ----------------------------------------------------------------
info "Installing $APP"
printf '   OS              : %s%s\n' "$OS" "$([ "$IS_IMMUTABLE" = 1 ] && echo "  (immutable Fedora detected)")"
[ -n "$DISTRO" ] && printf '   distro          : %s\n' "$DISTRO"
printf '   program dir     : %s\n' "$PROGDIR"
printf '   symlink         : %s -> %s/%s\n' "$LINK" "$PROGDIR" "$APP"
need_sudo_hint

# Copy the project (excluding the test suite, .git, and pycache to keep it lean;
# remove the --exclude lines if you want the tests installed too).
run mkdir -p "$(dirname "$PROGDIR")" "$(dirname "$LINK")"
run rm -rf "$PROGDIR"
if have rsync; then
  run rsync -a --exclude '.git' --exclude '__pycache__' --exclude 'test' \
        "$SELF_DIR"/ "$PROGDIR"/
else
  run cp -r "$SELF_DIR" "$PROGDIR"
  run rm -rf "$PROGDIR/.git" "$PROGDIR/lib/__pycache__" "$PROGDIR/test"
fi
run chmod +x "$PROGDIR/$APP"
[ -f "$PROGDIR/lib/apply_color.py" ] && run chmod +x "$PROGDIR/lib/apply_color.py" || true
run ln -sf "$PROGDIR/$APP" "$LINK"

# --- PATH guidance ----------------------------------------------------------
on_path=0
case ":$PATH:" in *":$BINDIR:"*) on_path=1 ;; esac
if [ "$on_path" -eq 0 ] && [ "$DRYRUN" -eq 0 ]; then
  warn "$BINDIR is not on your PATH."
  # rc holds a literal path string shown to the user (the tilde is meant to be
  # displayed, not expanded), so SC2088 does not apply.
  if [ "$OS" = "Darwin" ]; then
    # shellcheck disable=SC2088
    rc='~/.zshrc'
  else
    # shellcheck disable=SC2088
    rc='~/.bashrc'
  fi
  printf '   Add this line to %s and restart your shell:\n' "$rc"
  printf '       %sexport PATH="%s:$PATH"%s\n' "$c_dim" "$BINDIR" "$c_rst"
fi

# --- editor extension -------------------------------------------------------
install_extension

# --- engine guidance --------------------------------------------------------
if [ "$DRYRUN" -eq 0 ] && ! have podman && ! have docker; then
  printf '\n%sNo container engine found.%s isopod needs podman (recommended) or docker:\n' "$c_yel" "$c_rst"
  if [ "$IS_IMMUTABLE" = 1 ]; then
    printf '   Immutable Fedora ships podman on the host already; if missing, layer it:\n'
    printf '       %srpm-ostree install podman%s   (then reboot)\n' "$c_dim" "$c_rst"
    printf '   %sDo NOT install isopod inside a toolbox/distrobox%s — it must reach the\n' "$c_yel" "$c_rst"
    printf '   host podman to manage your sandboxes. This installer put it on the host.\n'
  else
    case "$DISTRO" in
      fedora|rhel|centos) printf '       %ssudo dnf install -y podman openssh-clients%s\n' "$c_dim" "$c_rst" ;;
      ubuntu|debian)      printf '       %ssudo apt install -y podman openssh-client%s\n' "$c_dim" "$c_rst" ;;
      *) [ "$OS" = "Darwin" ] && printf '       %sbrew install podman && podman machine init && podman machine start%s\n' "$c_dim" "$c_rst" \
           || printf '       install podman or docker via your package manager\n' ;;
    esac
  fi
fi

if [ "$DRYRUN" -eq 1 ]; then
  printf '\n%s(--check) no changes were made.%s\n' "$c_dim" "$c_rst"
else
  printf '\n%sDone.%s Verify with: %sisopod doctor%s\n' "$c_grn" "$c_rst" "$c_dim" "$c_rst"
  [ "$on_path" -eq 1 ] && printf 'Try: %sisopod create demo --color teal%s\n' "$c_dim" "$c_rst"
fi