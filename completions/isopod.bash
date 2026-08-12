# bash completion for isopod
#
# Installed by Homebrew (bash_completion.install) and, best-effort, by
# install.sh. Source it manually with:  source /path/to/isopod.bash
#
# Completes subcommands, per-command options, known box names (read from the
# isopod config dir), and the enumerated values for --color / --app / --engine.

_isopod() {
  local cur prev cword words
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  cword="$COMP_CWORD"
  words=("${COMP_WORDS[@]}")

  local cmds="create list info code shell root-shell upgrade start stop config reconfigure export fetch remap copy-in rm egress host-port secret doctor help version"
  local colors="red orange amber green teal blue purple magenta gray grey"
  local apps="codium vscodium cursor windsurf code"

  local boxes_dir="${ISOPOD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/isopod}/boxes"
  _isopod_boxes() {
    [ -d "$boxes_dir" ] || return 0
    local d
    for d in "$boxes_dir"/*/; do [ -d "$d" ] && basename "$d"; done
  }

  # Position 1 is the subcommand.
  if [ "$cword" -eq 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
    return 0
  fi

  local sub="${words[1]}"

  # Values that follow a specific option.
  case "$prev" in
    --color)
      mapfile -t COMPREPLY < <(compgen -W "$colors" -- "$cur")
      return 0
      ;;
    --app)
      mapfile -t COMPREPLY < <(compgen -W "$apps" -- "$cur")
      return 0
      ;;
    --engine)
      mapfile -t COMPREPLY < <(compgen -W "podman docker" -- "$cur")
      return 0
      ;;
    --copy | --remap-file | --dockerfile)
      compopt -o default 2>/dev/null
      COMPREPLY=()
      return 0
      ;; # a path
    --repo | --branch | --image | --memory | --cpus | --port | --expose | --secret | --name | --email | --old-email | --old-name | --path)
      return 0
      ;; # free-form argument; let the shell default take over
  esac

  # Option flags, scoped per subcommand.
  if [[ "$cur" == -* ]]; then
    local opts=""
    case "$sub" in
      create) opts="--repo --branch --copy --color --image --dockerfile --expose --secret --engine --memory --cpus --port --sudo --no-sudo --no-root-key --guest-egress --container --dev --disk --nested-containers" ;;
      reconfigure) opts="--guest-egress --expose --memory --cpus --color" ;;
      code) opts="--app --reuse-window" ;;
      rm) opts="--force" ;;
      remap) opts="--name --email --old-email --old-name --remap-file --force" ;;
      fetch) opts="--path" ;;
    esac
    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
    return 0
  fi

  # First positional for most subcommands is an existing box name.
  case "$sub" in
    info | code | shell | root-shell | upgrade | start | stop | config | reconfigure | export | fetch | remap | copy-in | rm)
      mapfile -t COMPREPLY < <(compgen -W "$(_isopod_boxes)" -- "$cur")
      ;;
    egress)
      mapfile -t COMPREPLY < <(compgen -W "status apply observe persist unpersist allow log denied rules lan-allow lan-denied" -- "$cur")
      ;;
    host-port | hostport)
      if [ "$cword" -eq 2 ]; then
        mapfile -t COMPREPLY < <(compgen -W "add rm ls" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "$(_isopod_boxes)" -- "$cur")
      fi
      ;;
    secret)
      if [ "$cword" -eq 2 ]; then
        mapfile -t COMPREPLY < <(compgen -W "set ls rm" -- "$cur")
      elif [ "${words[2]}" = "rm" ]; then
        # complete stored names from the index (names only — never values)
        local index="${ISOPOD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/isopod}/secrets/index"
        [ -r "$index" ] && mapfile -t COMPREPLY < <(compgen -W "$(cat "$index")" -- "$cur")
      fi
      ;;
  esac
  return 0
}
complete -F _isopod isopod
