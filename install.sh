#!/usr/bin/env bash
#
# install.sh — install (or uninstall) aibox using each platform's conventions.
#
# aibox is multi-file: the `aibox` script needs its `lib/` folder beside it.
# This installer copies the whole project into one program directory and puts a
# symlink to the `aibox` entry point on your PATH. aibox resolves its own
# location through that symlink, so `lib/` is always found.
#
# Usage:
#   ./install.sh                 # auto-detect best per-user location, install
#   ./install.sh --system        # system-wide (/usr/local), needs sudo/root
#   ./install.sh --prefix DIR     # install program dir under DIR/lib, link in DIR/bin
#   ./install.sh --uninstall      # remove a previous install
#   ./install.sh --check          # print what it would do, make no changes
#   ./install.sh --help
#
# Honors $DESTDIR for packaging. Safe to re-run (idempotent).
set -euo pipefail

APP=aibox
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

while [ $# -gt 0 ]; do
  case "$1" in
    --system)     SCOPE=system; shift ;;
    --user)       SCOPE=user; shift ;;
    --prefix)     PREFIX="$2"; SCOPE=prefix; shift 2 ;;
    --uninstall)  MODE=uninstall; shift ;;
    --check)      DRYRUN=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'
      exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- sanity: are we sitting on a real aibox source tree? --------------------
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
# Program files go in <libroot>/aibox; the entry point is symlinked into <bindir>.
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

# --- uninstall --------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
  info "Uninstalling $APP"
  [ -L "$LINK" ] || [ -e "$LINK" ] && run rm -f "$LINK" || true
  [ -d "$PROGDIR" ] && run rm -rf "$PROGDIR" || true
  info "Removed program dir and symlink (if they existed)."
  printf '%sNote:%s your sandboxes and keys under ~/.config/aibox were left intact.\n' "$c_dim" "$c_rst"
  printf '      Run %saibox rm <name>%s for each box first if you want them gone.\n' "$c_dim" "$c_rst"
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

# --- engine guidance --------------------------------------------------------
if [ "$DRYRUN" -eq 0 ] && ! have podman && ! have docker; then
  printf '\n%sNo container engine found.%s aibox needs podman (recommended) or docker:\n' "$c_yel" "$c_rst"
  if [ "$IS_IMMUTABLE" = 1 ]; then
    printf '   Immutable Fedora ships podman on the host already; if missing, layer it:\n'
    printf '       %srpm-ostree install podman%s   (then reboot)\n' "$c_dim" "$c_rst"
    printf '   %sDo NOT install aibox inside a toolbox/distrobox%s — it must reach the\n' "$c_yel" "$c_rst"
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
  printf '\n%sDone.%s Verify with: %saibox doctor%s\n' "$c_grn" "$c_rst" "$c_dim" "$c_rst"
  [ "$on_path" -eq 1 ] && printf 'Try: %saibox create demo --color teal%s\n' "$c_dim" "$c_rst"
fi
