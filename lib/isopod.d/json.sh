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

# The six shared box fields as `"key":value` pairs (no surrounding braces), so
# the list element and the info object can't drift apart. Values come from the
# same sources as the text output: box_status, meta, ctr_name, box_engine.
box_facts_json() { # box_facts_json <name>
  local name="$1" status port color
  status=$(box_status "$name" 2>/dev/null || printf 'missing')
  port=$(meta_get "$name" port 2>/dev/null || true)
  color=$(meta_get "$name" color 2>/dev/null || true)
  printf '"name":%s,"status":%s,"ssh_host":%s,"port":%s,"color":%s,"engine":%s' \
    "$(json_str "$name")" \
    "$(json_str "${status:-missing}")" \
    "$(json_str "$(ctr_name "$name")")" \
    "$(json_port_or_null "$port")" \
    "$(json_str_or_null "$color")" \
    "$(json_str "$(box_engine "$name")")"
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

