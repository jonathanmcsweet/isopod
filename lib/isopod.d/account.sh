#!/usr/bin/env bash
# sourced by isopod — not executable on its own; defines the sandbox account.
#
# The account is the opt-in hard egress boundary (docs/spike-sandbox-account.md):
# boxes run under a dedicated unprivileged account, and host nftables rules keyed
# on that account's uid (meta skuid, output hook) drop its traffic to private
# address space. The rules live in the HOST kernel, so guest root cannot remove
# them and they still bind a process that escaped the box. The engine stays
# rootless; root is used once here, to install static state.
#
# This module owns the account's lifecycle (setup/status/teardown) and nothing
# else. Running boxes under the account is create's concern (--account).

account_uid() { id -u "$ISOPOD_ACCOUNT" 2>/dev/null; }

account_exists() { id -u "$ISOPOD_ACCOUNT" >/dev/null 2>&1; }

account_has_subids() {
  grep -q "^$ISOPOD_ACCOUNT:" "$SUBUID_FILE" 2>/dev/null &&
    grep -q "^$ISOPOD_ACCOUNT:" "$SUBGID_FILE" 2>/dev/null
}

# Next free subordinate-id range: one past the highest end in either file, at
# least 300000 (clear of the 65536-plus-100000 range distros hand the first
# user), always 65536 wide. Reading both files means a range never collides
# with an existing uid OR gid allocation.
account_next_subid_start() {
  local max=300000 f start count rest
  for f in "$SUBUID_FILE" "$SUBGID_FILE"; do
    [ -f "$f" ] || continue
    while IFS=: read -r _ start count rest; do
      : "$rest"
      case "$start$count" in "" | *[!0-9]*) continue ;; esac
      [ $((start + count)) -gt "$max" ] && max=$((start + count))
    done <"$f"
  done
  printf '%s' "$max"
}

account_rules_loaded() { nft list table inet isopod_account >/dev/null 2>&1; }

# Substitute the uid into the shipped ruleset. Refuses a non-numeric uid rather
# than substituting it: this text is about to become firewall rules.
account_render_rules() { # account_render_rules <uid>
  case "${1:-}" in "" | *[!0-9]*) return 1 ;; esac
  local src="$ISOPOD_SHARE/egress-account.nft"
  [ -f "$src" ] || die "missing ruleset: $src (is your isopod install complete?)"
  sed "s/@ACCOUNT_UID@/$1/g" "$src"
}

account_require_root() {
  [ "$(id -u)" = 0 ] || die "this needs root — run: sudo isopod account $1"
}

cmd_account_setup() {
  account_require_root setup
  is_macos && die "the sandbox account is Linux-only (it needs subordinate ids, systemd linger, and nftables)"
  have nft || die "nft not found — install nftables first"
  have loginctl || die "loginctl not found — the account needs a systemd host"
  # The grant goes to whoever invoked sudo; without that there is nobody to let
  # run the engine as the account, and setup would install a boundary no one can
  # use. Root-shell users can pass the name explicitly via SUDO_USER.
  local grantee="${SUDO_USER:-}"
  [ -n "$grantee" ] && [ "$grantee" != root ] ||
    die "could not tell which user to grant engine access to (run via sudo from your own account)"
  local enginebin
  enginebin="$(command -v podman)" ||
    die "podman not found — the sandbox account requires podman (rootless docker is not supported)"

  # 1. The account. --create-home is required: rootless podman keeps the image
  # store under the account's home. A real shell rather than nologin because
  # some sudo configurations route through it; the account has no password, so
  # it still cannot be logged into.
  if account_exists; then
    printf '  [ok]      account %s exists (uid %s)\n' "$ISOPOD_ACCOUNT" "$(account_uid)"
  else
    useradd --system --create-home --shell /bin/bash "$ISOPOD_ACCOUNT" ||
      die "could not create the account '$ISOPOD_ACCOUNT'"
    printf '  [created] account %s (uid %s)\n' "$ISOPOD_ACCOUNT" "$(account_uid)"
  fi
  local uid
  uid="$(account_uid)" || die "the account exists but has no resolvable uid"

  # 2. Subordinate ids — what makes rootless podman work AS the account.
  if account_has_subids; then
    printf '  [ok]      subordinate ids: %s\n' "$(grep "^$ISOPOD_ACCOUNT:" "$SUBUID_FILE" | head -1)"
  else
    local start
    start="$(account_next_subid_start)"
    usermod --add-subuids "$start-$((start + 65535))" \
      --add-subgids "$start-$((start + 65535))" "$ISOPOD_ACCOUNT" ||
      die "could not allocate subordinate ids for '$ISOPOD_ACCOUNT'"
    printf '  [created] subordinate ids %s-%s\n' "$start" "$((start + 65535))"
  fi

  # 3. Linger keeps a systemd user manager for the account, which is what
  # creates /run/user/<uid>. Writing the linger marker does NOT necessarily
  # start the manager (spike gotcha) — start it explicitly; after a reboot
  # linger starts it on its own.
  loginctl enable-linger "$ISOPOD_ACCOUNT" || die "could not enable linger for '$ISOPOD_ACCOUNT'"
  systemctl start "user@$uid.service" 2>/dev/null || true
  if [ -d "/run/user/$uid" ]; then
    printf '  [ok]      runtime directory /run/user/%s\n' "$uid"
  else
    warn "linger is enabled but /run/user/$uid did not appear — a reboot creates it"
  fi

  # 4. The firewall rules, applied now and persisted for boot. The rendered copy
  # lives under ISOPOD_ACCOUNT_STATE_DIR so the boot unit has a stable path.
  mkdir -p "$ISOPOD_ACCOUNT_STATE_DIR"
  account_render_rules "$uid" >"$ISOPOD_ACCOUNT_STATE_DIR/egress-account.nft" ||
    die "could not render the account ruleset"
  # Idempotent reload: replace the table rather than appending duplicate rules.
  nft delete table inet isopod_account 2>/dev/null || true
  nft -f "$ISOPOD_ACCOUNT_STATE_DIR/egress-account.nft" ||
    die "nft rejected the account ruleset (see above)"
  account_rules_loaded || die "the account ruleset did not load into the kernel"
  printf '  [ok]      firewall: account traffic to private ranges now drops\n'

  local ISOPOD_NFT_BIN
  # Read by the unit template via render_tmpl's dynamic scope.
  # shellcheck disable=SC2034
  ISOPOD_NFT_BIN="$(command -v nft)"
  render_tmpl isopod-account-nft.service.tmpl \
    >"/etc/systemd/system/$ISOPOD_ACCOUNT_NFT_UNIT" ||
    die "could not write the persistence unit"
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "$ISOPOD_ACCOUNT_NFT_UNIT" >/dev/null 2>&1 ||
    warn "could not enable $ISOPOD_ACCOUNT_NFT_UNIT — rules will not survive a reboot"
  printf '  [ok]      persistence: %s\n' "$ISOPOD_ACCOUNT_NFT_UNIT"

  # 5. The sudoers grant — one binary, as the account, for the invoking user.
  # visudo -c validates the candidate before it can break sudo for the machine.
  # Read by the sudoers template via render_tmpl's dynamic scope.
  # shellcheck disable=SC2034
  local ISOPOD_ACCOUNT_GRANTEE="$grantee" ISOPOD_ACCOUNT_ENGINE_BIN="$enginebin" tmp
  tmp="$(mktemp)" || die "mktemp failed"
  render_tmpl isopod-account-sudoers.tmpl >"$tmp" || {
    rm -f "$tmp"
    die "could not render the sudoers grant"
  }
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 0440 "$tmp" /etc/sudoers.d/isopod-account
    rm -f "$tmp"
    printf '  [ok]      sudoers: %s may run %s as %s\n' "$grantee" "$enginebin" "$ISOPOD_ACCOUNT"
  else
    rm -f "$tmp"
    die "the rendered sudoers grant failed visudo validation — not installed"
  fi

  printf '\n'
  info "sandbox account ready. Verify with: isopod account status"
}

cmd_account_status() {
  local ok=1 uid
  if account_exists; then
    uid="$(account_uid)"
    printf '  [ok]      account %s (uid %s)\n' "$ISOPOD_ACCOUNT" "$uid"
  else
    printf '  [MISSING] account %s — run: sudo isopod account setup\n' "$ISOPOD_ACCOUNT"
    ok=0
  fi
  if account_has_subids; then
    printf '  [ok]      subordinate ids\n'
  else
    printf '  [MISSING] subordinate ids for %s\n' "$ISOPOD_ACCOUNT"
    ok=0
  fi
  if [ -n "${uid:-}" ] && [ -d "/run/user/$uid" ]; then
    printf '  [ok]      runtime directory /run/user/%s\n' "$uid"
  else
    printf '  [MISSING] runtime directory (linger not active, or never set up)\n'
    ok=0
  fi
  # Reading the ruleset needs root; degrade to "unknown" rather than lying.
  if account_rules_loaded; then
    printf '  [ok]      firewall rules loaded\n'
    nft list table inet isopod_account 2>/dev/null | grep 'counter' |
      sed 's/^[[:space:]]*/            /'
  elif sudo -n nft list table inet isopod_account >/dev/null 2>&1; then
    printf '  [ok]      firewall rules loaded\n'
  elif [ "$(id -u)" != 0 ]; then
    printf '  [?]       firewall rules: cannot read without root (sudo isopod account status)\n'
  else
    printf '  [MISSING] firewall rules not loaded — run: sudo isopod account setup\n'
    ok=0
  fi
  if [ -f /etc/sudoers.d/isopod-account ]; then
    printf '  [ok]      sudoers grant installed\n'
  else
    printf '  [MISSING] sudoers grant — run: sudo isopod account setup\n'
    ok=0
  fi
  if systemctl is-enabled "$ISOPOD_ACCOUNT_NFT_UNIT" >/dev/null 2>&1; then
    printf '  [ok]      boot persistence enabled\n'
  else
    printf '  [MISSING] boot persistence (%s)\n' "$ISOPOD_ACCOUNT_NFT_UNIT"
    ok=0
  fi
  [ "$ok" = 1 ]
}

cmd_account_teardown() {
  account_require_root teardown
  local purge=0
  [ "${1:-}" = "--purge" ] && purge=1
  # Future account boxes must block this; today the check is vacuous but cheap.
  local d n
  for d in "$BOXES_DIR"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ "$(meta_get "$n" account 2>/dev/null || true)" = 1 ] &&
      die "box '$n' runs under the account — remove or migrate it first"
  done
  nft delete table inet isopod_account 2>/dev/null && printf '  removed firewall rules\n'
  systemctl disable "$ISOPOD_ACCOUNT_NFT_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$ISOPOD_ACCOUNT_NFT_UNIT" \
    "$ISOPOD_ACCOUNT_STATE_DIR/egress-account.nft" /etc/sudoers.d/isopod-account
  systemctl daemon-reload 2>/dev/null || true
  printf '  removed persistence unit and sudoers grant\n'
  if [ "$purge" = 1 ] && account_exists; then
    loginctl disable-linger "$ISOPOD_ACCOUNT" 2>/dev/null || true
    userdel -r "$ISOPOD_ACCOUNT" 2>/dev/null &&
      printf '  removed account %s and its image store\n' "$ISOPOD_ACCOUNT" ||
      warn "could not remove the account (processes still running as it?)"
  elif account_exists; then
    printf '  account %s kept (it owns nothing; --purge removes it)\n' "$ISOPOD_ACCOUNT"
  fi
}

cmd_account() {
  local action="${1:-status}"
  shift 2>/dev/null || true
  case "$action" in
    setup) cmd_account_setup "$@" ;;
    status | "") cmd_account_status "$@" ;;
    teardown) cmd_account_teardown "$@" ;;
    rules)
      # Render with the real uid when the account exists, else a placeholder
      # value, so the output is always loadable for inspection.
      account_render_rules "$(account_uid || printf 65534)"
      ;;
    -h | --help | help) render_tmpl account-help.txt ;;
    *) die "unknown account action: $action (try: isopod account setup|status|teardown|rules)" ;;
  esac
}
