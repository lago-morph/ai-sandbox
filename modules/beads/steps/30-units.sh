# shellcheck shell=bash
# The beads server and the sync timer enabled at boot and running, unless the server was
# stopped on purpose (then it stays stopped; that's reported, not repaired). Units are copied
# by the base step 35-modules. See modules/beads/README.md.

# shellcheck source=../lib/beads.sh
source "$AI_SANDBOX_MODULE_DIR/lib/beads.sh"

check() {
  local ok=0
  systemctl --user is-enabled -q beads-dolt.service 2>/dev/null || { info "beads-dolt.service not enabled at boot"; ok=1; }
  systemctl --user is-enabled -q beads-dolt-sync.timer 2>/dev/null || { info "beads-dolt-sync.timer not enabled"; ok=1; }
  systemctl --user is-active -q beads-dolt-sync.timer 2>/dev/null || { info "beads-dolt-sync.timer not active"; ok=1; }
  if beads_halted; then
    info "beads: $(beads_marker_summary) (left stopped; see ai-sandbox-beads-status)"
  else
    systemctl --user is-active -q beads-dolt.service 2>/dev/null && beads_reachable ||
      { info "beads-dolt.service not running on $BEADS_HOST:$BEADS_PORT"; ok=1; }
  fi
  return $ok
}

apply() {
  systemctl --user daemon-reload
  systemctl --user enable -q beads-dolt.service beads-dolt-sync.timer
  beads_halted || "$AI_SANDBOX_BIN/ai-sandbox-beads-server" start
  systemctl --user start beads-dolt-sync.timer
}
