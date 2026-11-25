# shellcheck shell=bash
# Lingering, the rc@ template, the refresh timer, and the ai-sandbox repo's own Remote
# Control server (the only one enabled at boot).

UNITS=(rc@.service rc-refresh.service rc-refresh.timer)

check() {
  local ok=0 u self="rc@$AI_SANDBOX_SELF_NAME.service"
  [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] || { info "lingering not enabled for $USER"; ok=1; }
  for u in "${UNITS[@]}"; do
    cmp -s <(render "$AI_SANDBOX_REPO_DIR/templates/systemd/$u") "$AI_SANDBOX_UNIT_DIR/$u" || { info "$u missing or differs"; ok=1; }
  done
  systemctl --user is-enabled -q rc-refresh.timer 2>/dev/null || { info "rc-refresh.timer not enabled"; ok=1; }
  systemctl --user is-active -q rc-refresh.timer 2>/dev/null || { info "rc-refresh.timer not active"; ok=1; }
  systemctl --user is-enabled -q "$self" 2>/dev/null || { info "$self not enabled at boot"; ok=1; }
  systemctl --user is-active -q "$self" 2>/dev/null || { info "$self not running"; ok=1; }
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
  if systemctl --user is-active -q "$self"; then
    # Restarting would drop connected sessions, so leave that to the user.
    if [ $changed = 1 ]; then
      warn "$self is running with the previous unit; restart it to apply: systemctl --user restart $self"
    fi
  else
    systemctl --user reset-failed "$self" 2>/dev/null || true
    systemctl --user start "$self"
  fi
}
