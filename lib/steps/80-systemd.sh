# shellcheck shell=bash
# Lingering, the rc@ template, the refresh timer, and the ai-sandbox repo's own Remote
# Control server (the only one enabled at boot).

UNITS=(rc@.service rc-refresh.service rc-refresh.timer)

# Exit 0 if UNIT is running and stays up: a server that exits at once (and is restarted every
# 15s) is briefly "active" too, so a unit that only just started is watched for a few seconds.
_stays_up() {
  local u=$1 since now
  systemctl --user is-active -q "$u" 2>/dev/null || return 1
  since=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value "$u")
  now=$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)
  if [ $((now - since)) -lt 8000000 ]; then
    sleep 8
    systemctl --user is-active -q "$u" 2>/dev/null || return 1
    [ "$(systemctl --user show -p ActiveEnterTimestampMonotonic --value "$u")" = "$since" ] || return 1
  fi
}

check() {
  local ok=0 u self="rc@$AI_SANDBOX_SELF_NAME.service"
  [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] || { info "lingering not enabled for $USER"; ok=1; }
  for u in "${UNITS[@]}"; do
    cmp -s <(render "$AI_SANDBOX_REPO_DIR/templates/systemd/$u") "$AI_SANDBOX_UNIT_DIR/$u" || { info "$u missing or differs"; ok=1; }
  done
  systemctl --user is-enabled -q rc-refresh.timer 2>/dev/null || { info "rc-refresh.timer not enabled"; ok=1; }
  systemctl --user is-active -q rc-refresh.timer 2>/dev/null || { info "rc-refresh.timer not active"; ok=1; }
  systemctl --user is-enabled -q "$self" 2>/dev/null || { info "$self not enabled at boot"; ok=1; }
  if ! _stays_up "$self"; then
    info "$self not running; its last output:"
    journalctl --user -u "$self" -n 4 -o cat --no-pager 2>/dev/null | sed 's/^/     /' >&2 || true
    ok=1
  fi
  return $ok
}

apply() {
  local u changed=0 self="rc@$AI_SANDBOX_SELF_NAME.service"
  [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] || sudo loginctl enable-linger "$USER"
  mkdir -p "$AI_SANDBOX_UNIT_DIR"
  for u in "${UNITS[@]}"; do
    if ! cmp -s <(render "$AI_SANDBOX_REPO_DIR/templates/systemd/$u") "$AI_SANDBOX_UNIT_DIR/$u"; then
      render "$AI_SANDBOX_REPO_DIR/templates/systemd/$u" > "$AI_SANDBOX_UNIT_DIR/$u"; changed=1
    fi
  done
  systemctl --user daemon-reload
  systemctl --user enable -q rc-refresh.timer
  systemctl --user restart rc-refresh.timer
  systemctl --user enable -q "$self"
  if _stays_up "$self"; then
    # Restarting would drop connected sessions, so leave that to the user.
    if [ $changed = 1 ]; then
      warn "$self is running with the previous unit; restart it to apply: systemctl --user restart $self"
    fi
  else
    systemctl --user reset-failed "$self" 2>/dev/null || true
    systemctl --user start "$self"
  fi
}
