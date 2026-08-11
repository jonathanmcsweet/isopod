#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines machine-readable --json output
# for `list`, `info <name>`, and `egress status`. The field names and shapes are a
# published contract consumed by external tooling (the Podman Desktop dashboard
# extension): fields may be ADDED, but existing ones must not be renamed or removed.
# Emitters print ONLY the JSON document on stdout — no headers or prose.

# Escape a string for use inside a JSON double-quoted string (quotes not added).
# Pure bash so `--json` adds no host dependency: backslash and double-quote get a
# backslash escape; control characters (0x01-0x1f) become \u00XX. NUL cannot occur
# in a bash string, so 0x00 needs no case.
json_escape() { # json_escape <string>
  local s="$1" i c u
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  for ((i = 1; i < 32; i++)); do
    printf -v c "\\$(printf '%03o' "$i")"
    [[ "$s" == *"$c"* ]] || continue
    printf -v u '\\u%04x' "$i"
    s="${s//$c/$u}"
  done
  printf '%s' "$s"
}

json_str() { # json_str <string> -> a quoted JSON string
  printf '"%s"' "$(json_escape "$1")"
}

json_str_or_null() { # json_str_or_null <string> -> quoted string, or null when empty
  if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi
}

json_port_or_null() { # json_port_or_null <value> -> bare integer port, or null
  if valid_port "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi
}

# Emit a comma-separated list (a meta value like "a,b,c") as a JSON array of
# strings. Empty input -> [] (never placeholder prose).
json_csv_array() { # json_csv_array <csv>
  local item first=1
  local -a items=()
  [ -n "${1:-}" ] && IFS=',' read -ra items <<<"$1"
  printf '['
  for item in "${items[@]:-}"; do
    [ -n "$item" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    json_str "$item"
  done
  printf ']'
}

# The box's effective runtime and its isolation class. `runtime` is the meta
# value recorded at create ("container" for a plain Tier 1 container, else the
# runtime name). `isolation` classifies that via the share/runtimes tier table:
# container (Tier 1, shared kernel) | sandbox (Tier 2) | microvm (Tier 3, own
# kernel) | unknown (a configured runtime not in the table). An Apple `container`
# box is always its own VM, so it reports microvm regardless of runtime.
box_isolation() { # box_isolation <name> -> prints the isolation class
  local name="$1" rt tier
  [ "$(box_engine "$name")" = container ] && {
    printf microvm
    return
  }
  rt=$(meta_get "$name" runtime 2>/dev/null || true)
  case "$rt" in
    '' | container)
      printf container
      return
      ;;
  esac
  tier=$(runtime_tier "$rt" 2>/dev/null || true)
  case "$tier" in
    3) printf microvm ;;
    2) printf sandbox ;;
    *) printf unknown ;;
  esac
}

# The six shared box fields as `"key":value` pairs (no surrounding braces), so
# the list element and the info object can't drift apart. Values come from the
# same sources as the text output: box_status, meta, ctr_name, box_engine.
box_facts_json() { # box_facts_json <name>
  local name="$1" status port color runtime
  status=$(box_status "$name" 2>/dev/null || printf 'missing')
  port=$(meta_get "$name" port 2>/dev/null || true)
  color=$(meta_get "$name" color 2>/dev/null || true)
  runtime=$(meta_get "$name" runtime 2>/dev/null || true)
  printf '"name":%s,"status":%s,"ssh_host":%s,"port":%s,"color":%s,"engine":%s,"runtime":%s,"isolation":%s' \
    "$(json_str "$name")" \
    "$(json_str "${status:-missing}")" \
    "$(json_str "$(ctr_name "$name")")" \
    "$(json_port_or_null "$port")" \
    "$(json_str_or_null "$color")" \
    "$(json_str "$(box_engine "$name")")" \
    "$(json_str "${runtime:-container}")" \
    "$(json_str "$(box_isolation "$name")")"
}

# `isopod list --json`: a JSON array (possibly empty) of box summaries.
cmd_list_json() {
  detect_engine
  local d first=1
  printf '['
  for d in "$BOXES_DIR"/*/; do
    [ -d "$d" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '\n  {%s}' "$(box_facts_json "$(basename "$d")")"
  done
  [ "$first" = 1 ] || printf '\n'
  printf ']\n'
}

# `isopod info <name> --json`: one object with the box's connection facts.
# The caller (cmd_info) has already validated the box and refreshed its port.
cmd_info_json() { # cmd_info_json <name>
  local name="$1" forwards secretspecs spec names=""
  forwards=$(meta_get "$name" expose 2>/dev/null || true)
  # Secret NAMES only (specs are NAME:/path) — values never leave the host store.
  secretspecs=$(meta_get "$name" secrets 2>/dev/null || true)
  if [ -n "$secretspecs" ]; then
    local IFS=,
    for spec in $secretspecs; do
      [ -n "$spec" ] || continue
      names="$names,${spec%%:*}"
    done
    names="${names#,}"
  fi
  printf '{%s,"forwards":%s,"secrets":%s,"workspace":%s}\n' \
    "$(box_facts_json "$name")" \
    "$(json_csv_array "$forwards")" \
    "$(json_csv_array "$names")" \
    "$(json_str "$WORKSPACE")"
}

# `isopod egress status --json`: the same facts the text status renders.
# firewall: active|inactive|unknown (unknown = need root, or VM/pf unreachable).
# proxy: null unless allow-list mode is configured.
egress_status_json() {
  local mode fw proxy rc=0 prc=0 running
  mode="$(active_egress)"
  egress_rules_loaded || rc=$?
  case "$rc" in
    0) fw=active ;;
    1) fw=inactive ;;
    *) fw=unknown ;;
  esac
  if [ "$mode" = allow-list ]; then
    egress_proxy_active || prc=$?
    running=false
    [ "$prc" = 0 ] && running=true
    proxy=$(printf '{"running":%s,"port":%s}' "$running" "$ISOPOD_EGRESS_PROXY_PORT")
  else
    proxy=null
  fi
  printf '{"mode":%s,"firewall":%s,"network":%s,"subnet":%s,"dns":%s,"proxy":%s}\n' \
    "$(json_str "${mode:-off}")" \
    "$(json_str "$fw")" \
    "$(json_str "$ISOPOD_EGRESS_NET")" \
    "$(json_str "$ISOPOD_EGRESS_SUBNET")" \
    "$(json_str "$ISOPOD_EGRESS_DNS")" \
    "$proxy"
}

# Emit newline-separated stdin lines as a JSON array of strings. Blank lines are
# skipped; order is preserved. Empty input -> [].
json_lines_array() {
  local line first=1
  printf '['
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    json_str "$line"
  done
  printf ']'
}

# `isopod egress allowlist --json`: the layered allow-list as two arrays, so the
# dashboard can show baseline (shipped defaults) vs user (added via `egress
# allow`) and diff them. Domains are the raw first token of each file line
# (comments stripped) — not the anchored regexes egress_filter_regexes builds.
egress_allowlist_json() {
  printf '{"baseline":%s,"user":%s}\n' \
    "$(egress_allowlist_domains "$ISOPOD_EGRESS_ALLOWLIST" | json_lines_array)" \
    "$(egress_allowlist_domains "$USER_EGRESS_ALLOWLIST" | json_lines_array)"
}

# `isopod egress denied --json`: hostnames the proxy refused, as a JSON object.
# Best-effort and needs root to read the proxy log (same source as the text
# `egress denied`); dies if the log is absent so the caller surfaces the reason.
egress_denied_json() {
  [ -f "$ISOPOD_EGRESS_PROXY_LOG" ] ||
    die "no proxy log at $ISOPOD_EGRESS_PROXY_LOG (has 'sudo isopod egress apply' run?)"
  printf '{"hostnames":%s}\n' \
    "$(egr_run_root grep -iE 'filter|refused|denied' "$ISOPOD_EGRESS_PROXY_LOG" 2>/dev/null |
      grep -oE '[A-Za-z0-9._-]+\.[A-Za-z]{2,}' | sort -u | json_lines_array)"
}

# The secret NAMES a box's meta attaches (the NAME of each NAME:path spec), one
# per line. Empty when the box attaches none. Names only — never values.
box_secret_names() { # box_secret_names <boxname>
  local specs spec
  specs=$(meta_get "$1" secrets 2>/dev/null || true)
  [ -n "$specs" ] || return 0
  local IFS=,
  for spec in $specs; do
    spec="${spec%%:*}"
    [ -n "$spec" ] && printf '%s\n' "$spec"
  done
}

# `isopod secret ls --json`: the managed secret names (never values), the active
# storage backend, and which boxes attach each name — so the dashboard can show
# a names-only index with per-box attribution in one call.
secret_ls_json() {
  local name d bname first=1 boxlist boxes_first
  printf '{"backend":%s,"secrets":[' "$(json_str "$(secret_backend)")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    boxlist=""
    boxes_first=1
    for d in "$BOXES_DIR"/*/; do
      [ -d "$d" ] || continue
      bname="$(basename "$d")"
      if box_secret_names "$bname" | grep -qxF "$name"; then
        [ "$boxes_first" = 1 ] || boxlist+=","
        boxes_first=0
        boxlist+="$(json_str "$bname")"
      fi
    done
    printf '{"name":%s,"boxes":[%s]}' "$(json_str "$name")" "$boxlist"
  done < <(secret_store_ls)
  printf ']}\n'
}

# One `doctor --json` check object. <level> is ok|warn|error|na (na = not
# applicable / absent). <id> is a stable slug, <label> human text, <hint> a
# short fix hint ("" when none).
doctor_check_json() { # doctor_check_json <level> <id> <label> <hint>
  printf '{"level":%s,"id":%s,"label":%s,"hint":%s}' \
    "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")" "$(json_str "$4")"
}

# `isopod doctor --json`: a machine-readable health summary of the actionable
# prerequisite checks (a subset of the human `doctor` narrative), so the
# dashboard can render a checklist. Probes are the same `have`/`info` primitives
# the text doctor uses; the long platform/virt advisories stay text-only.
doctor_json() {
  local -a checks=()
  local t missing=""
  for t in ssh ssh-keygen ssh-keyscan; do have "$t" || missing+=" $t"; done
  if [ -n "$missing" ]; then
    checks+=("$(doctor_check_json error ssh-tools "SSH client tools" "missing:$missing — install openssh")")
  else
    checks+=("$(doctor_check_json ok ssh-tools "SSH client tools" "")")
  fi
  if have git; then
    checks+=("$(doctor_check_json ok git "git (fetch, remap)" "")")
  else
    checks+=("$(doctor_check_json warn git "git (fetch, remap)" "install git for isopod fetch/remap")")
  fi
  if filter_repo_usable; then
    checks+=("$(doctor_check_json ok remap "remap backend" "git-filter-repo")")
  elif have python3; then
    checks+=("$(doctor_check_json ok remap "remap backend" "python3 fallback")")
  else
    checks+=("$(doctor_check_json warn remap "remap backend" "install git-filter-repo or python3")")
  fi
  local have_engine=0
  if have podman; then
    if podman info >/dev/null 2>&1; then
      have_engine=1
      checks+=("$(doctor_check_json ok podman "podman" "working")")
    else
      checks+=("$(doctor_check_json warn podman "podman" "installed but not working (podman machine start?)")")
    fi
  else
    checks+=("$(doctor_check_json na podman "podman" "not installed")")
  fi
  # Rootless podman's subuid/subgid range (Arch and Gentoo do not create one with
  # the account). Only meaningful where rootless podman is what runs boxes.
  if have podman && is_linux && [ "$(id -u)" -ne 0 ]; then
    local sub_user
    sub_user="$(id -un)"
    if subid_ranges_ok; then
      checks+=("$(doctor_check_json ok subid "rootless subuid/subgid range" "")")
    else
      checks+=("$(doctor_check_json warn subid "rootless subuid/subgid range" \
        "none for $sub_user — sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $sub_user, then podman system migrate")")
    fi
  fi
  if have docker; then
    if docker info >/dev/null 2>&1; then
      have_engine=1
      checks+=("$(doctor_check_json ok docker "docker" "daemon reachable")")
    else
      checks+=("$(doctor_check_json warn docker "docker" "installed but daemon not reachable")")
    fi
  else
    checks+=("$(doctor_check_json na docker "docker" "not installed")")
  fi
  [ "$have_engine" = 1 ] ||
    checks+=("$(doctor_check_json error engine "container engine" "no working engine — start podman or docker")")
  if [ -f "$HARDENING_CONF" ]; then
    checks+=("$(doctor_check_json ok hardening "hardening profile" "$HARDENING_CONF")")
  else
    checks+=("$(doctor_check_json warn hardening "hardening profile" "missing — boxes start without fingerprint masks")")
  fi
  local egmode
  egmode="$(active_egress)"
  case "$egmode" in
    allow-list | lan-deny) checks+=("$(doctor_check_json ok egress "egress isolation" "$egmode")") ;;
    *) checks+=("$(doctor_check_json warn egress "egress isolation" "off — set egress lan-deny/allow-list in hardening.conf")") ;;
  esac
  local out="" c first=1
  for c in "${checks[@]}"; do
    [ "$first" = 1 ] || out+=","
    first=0
    out+="$c"
  done
  printf '{"version":%s,"checks":[%s]}\n' "$(json_str "$ISOPOD_VERSION")" "$out"
}
