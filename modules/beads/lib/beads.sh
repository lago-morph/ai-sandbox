# shellcheck shell=bash
# Shared by the ai-sandbox-beads-* commands. See modules/beads/README.md.
# Callers have sourced lib/common.sh.
# shellcheck disable=SC2034  # the variables are used by the scripts that source this file

BEADS_HOST=127.0.1.1
BEADS_PORT=${BEADS_PORT:-3307}   # override only for tests
BEADS_DATA=${BEADS_DATA:-$AI_SANDBOX_SHARE/data/beads}
BEADS_MARKER=$AI_SANDBOX_STATE/beads-sync-HALTED
BEADS_UPGRADE_OK=$AI_SANDBOX_STATE/beads-server-upgrade-ok
BEADS_LOG=$AI_SANDBOX_STATE/beads-sync.log
BEADS_SYNC_STATE=$AI_SANDBOX_STATE/beads-sync.state
BEADS_SERVER_LOCK=$AI_SANDBOX_STATE/beads-server.lock
BEADS_SYNC_LOCK=$AI_SANDBOX_STATE/beads-sync.lock
BEADS_DOLT=${BEADS_DOLT:-$AI_SANDBOX_BIN/dolt}
BEADS_README=$AI_SANDBOX_SHARE/modules/beads/README.md
BEADS_UNIT=beads-dolt.service
export DOLT_DISABLE_VERSION_CHECKS=1
export BEADS_HOST BEADS_PORT BEADS_DATA BEADS_MARKER BEADS_LOG BEADS_SYNC_STATE BEADS_DOLT BEADS_README

beads_halted() { [ -f "$BEADS_MARKER" ]; }

# beads_marker_get KEY: a field of the halt marker ("key: value" lines).
beads_marker_get() { sed -n "s/^$1: //p" "$BEADS_MARKER" 2>/dev/null | head -n1; }

beads_log() { mkdir -p "$AI_SANDBOX_STATE"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$BEADS_LOG"; }

# beads_reachable: exit 0 if something listens on the server's address.
beads_reachable() { (exec 3<>"/dev/tcp/$BEADS_HOST/$BEADS_PORT") 2>/dev/null; }

# beads_sql [DB] QUERY: runs QUERY on the server, CSV out.
beads_sql() {
  local db=
  [ $# -gt 1 ] && { db=$1; shift; }
  "$BEADS_DOLT" --host "$BEADS_HOST" --port "$BEADS_PORT" --no-tls -u root -p "" ${db:+--use-db "$db"} sql -r csv -q "$1"
}

# beads_databases: the beads databases on the server (system databases excluded).
beads_databases() { beads_sql "SHOW DATABASES" | tail -n +2 | grep -vx 'information_schema\|mysql' || true; }

# beads_write_marker BY CLASS REASON [DATABASES]: writes the halt marker unless one exists.
beads_write_marker() {
  beads_halted && return 0
  mkdir -p "$AI_SANDBOX_STATE"
  local next="see Troubleshooting in $BEADS_README; only the owner decides when it restarts (ai-sandbox-beads-server resume)"
  case "$2" in upgrade) next="an upgrade is in progress; wait for it, don't start the server" ;; esac
  {
    printf 'time: %s\n' "$(date '+%F %T')"
    printf 'by: %s\n' "$1"
    printf 'class: %s\n' "$2"
    printf 'reason: %s\n' "$3"
    printf 'databases: %s\n' "${4:-}"
    printf 'next: %s\n' "$next"
  } > "$BEADS_MARKER.tmp"
  mv "$BEADS_MARKER.tmp" "$BEADS_MARKER"
}

# beads_marker_summary: one line describing the halt.
beads_marker_summary() {
  local by class reason dbs
  by=$(beads_marker_get by); class=$(beads_marker_get class); reason=$(beads_marker_get reason); dbs=$(beads_marker_get databases)
  if [ "$class" = upgrade ]; then
    printf 'STOPPED ON PURPOSE for an upgrade at %s (%s): %s\n' "$(beads_marker_get time)" "$by" "$reason"
  else
    printf 'STOPPED ON PURPOSE by %s at %s: %s%s (class=%s)\n' "$by" "$(beads_marker_get time)" "${dbs:+$dbs: }" "$reason" "$class"
  fi
}
