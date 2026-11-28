#!/usr/bin/env bash
# Usage: tests/host/beads-pilot.sh --yes
# The beads pilot (modules/beads/README.md, "Pilot"): runs against this host's real beads server
# and the DoltHub database <account>/ai_sandbox_pilot (private, kept for the purpose; it must
# exist). Run it after installing the module and after any dolt or bd upgrade.
#
# It halts and resumes the server several times, which stops beads for EVERY repo on the host
# for a minute or two each time: hence --yes. It refuses to start if beads is already stopped
# on purpose. It touches only the pilot database, temporary directories, and (for one check, put
# back on exit) a systemd drop-in for beads-dolt-sync.service.
set -uo pipefail
[ "${1:-}" = --yes ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
export DOLT_DISABLE_VERSION_CHECKS=1
DB=ai_sandbox_pilot
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/ai-sandbox
DATA=$HOME/.local/share/ai-sandbox/data/beads
BACKUPS=$HOME/.local/share/ai-sandbox/data/beads-backups
MARKER=$STATE/beads-sync-HALTED
DROPIN=$HOME/.config/systemd/user/beads-dolt-sync.service.d/pilot-crash.conf
T=$(mktemp -d /tmp/beads-pilot.XXXX)
pass=0 fail=0

cleanup() {
  [ -f "$DROPIN" ] && { rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null; systemctl --user daemon-reload; }
  systemctl --user start beads-dolt-sync.timer 2>/dev/null
  rm -rf "${T:?}"
}
trap cleanup EXIT
ok()   { pass=$((pass + 1)); echo "PASS  $*"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $*"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
q() { (cd "$T" && dolt --host 127.0.1.1 --port 3307 --no-tls -u root -p "" ${2:+--use-db "$2"} sql -r csv -q "$1"); }
bdq() { (cd "$T/repo" && timeout 60 bd "$@" 2>/dev/null); }
dh_sql() {  # dh_sql QUERY: rows from DoltHub's copy of the pilot database, as JSON
  curl -s -G -H @<(printf 'Authorization: Bearer %s\n' "$(ai-sandbox-secret get dolthub)") \
    --data-urlencode ref=main --data-urlencode "q=$1" \
    "https://www.dolthub.com/api/v2/databases/$ACCOUNT/$DB/sql" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["rows"])'
}
resume() { ai-sandbox-beads-server resume >/dev/null 2>&1; ai-sandbox-beads-status >/dev/null; }
has() { grep -q -- "$2" <<<"$1"; }

ACCOUNT=$(ai-sandbox-secret get dolthub-account) || { echo "no dolthub-account secret"; exit 1; }
[ ! -f "$MARKER" ] || { echo "beads is stopped on purpose already; resolve that first (ai-sandbox-beads-status)"; exit 1; }
ai-sandbox-beads-status >/dev/null || { echo "beads isn't healthy; see ai-sandbox-beads-status"; exit 1; }
others=$(q "SHOW DATABASES" | tail -n +2 | grep -vx "information_schema\|mysql\|$DB" | xargs)
[ -z "$others" ] || echo "note: halting stops beads for these too while the pilot runs: $others"

echo "--- setup: $DB on the server, a throwaway repo using it"
if ! q "SHOW DATABASES" | grep -qx "$DB"; then
  if [ "$(dh_sql 'SHOW TABLES' 2>/dev/null)" = "[]" ] || [ -z "$(dh_sql 'SHOW TABLES' 2>/dev/null)" ]; then
    ai-sandbox-beads-init "$DB" pilot >/dev/null || { bad "ai-sandbox-beads-init $DB"; exit 1; }
  else
    q "CALL DOLT_CLONE('--remote', 'dolthub', '$ACCOUNT/$DB', '$DB')" >/dev/null || { bad "clone $DB through the server"; exit 1; }
  fi
fi
check "only remote is dolthub" test "$(q "SELECT name FROM dolt_remotes" "$DB" | tail -n +2 | xargs)" = dolthub
pid=$(q "SELECT value FROM metadata WHERE \`key\` = '_project_id'" "$DB" | tail -n1)
git init -q "$T/repo" && git -C "$T/repo" commit -q --allow-empty -m init
mkdir -m 700 "$T/repo/.beads"
printf '{"database":"dolt","backend":"dolt","dolt_mode":"server","dolt_database":"%s","project_id":"%s"}\n' "$DB" "$pid" > "$T/repo/.beads/metadata.json"
printf 'BEADS_DOLT_SERVER_MODE=1\nBEADS_DOLT_SERVER_DATABASE=%s\nBEADS_DOLT_AUTO_START=0\n' "$DB" > "$T/repo/.beads/.env"
echo .beads/.env >> "$T/repo/.git/info/exclude"
git -C "$T/repo" add .beads/metadata.json && git -C "$T/repo" commit -qm beads
id=$(bdq create "pilot $(date +%s)" -t task | grep -o 'pilot-[a-z0-9]*' | head -n1)
check "bd writes and reads through the server" bash -c "cd '$T/repo' && bd show '$id'"
git -C "$T/repo" worktree add -q "$T/wt"
check "a worktree sees the same issue, no extra setup" bash -c "cd '$T/wt' && timeout 60 bd show '$id'"

echo "--- sync both ways"
ai-sandbox-beads-sync >/dev/null
check "a local write reaches DoltHub" has "$(dh_sql "SELECT id FROM issues WHERE id='$id'")" "$id"
(cd "$T" && timeout 120 dolt clone "$ACCOUNT/$DB" elsewhere >/dev/null 2>&1)
(cd "$T/elsewhere" && dolt sql -q "UPDATE issues SET title='edited elsewhere' WHERE id='$id'" && dolt add -A && dolt commit -m "pilot: elsewhere" && timeout 120 dolt push origin main) >/dev/null 2>&1
ai-sandbox-beads-sync >/dev/null
check "a commit pushed elsewhere arrives locally" bash -c "cd '$T/repo' && timeout 60 bd show '$id' | grep -q 'edited elsewhere'"

echo "--- divergence halts, and nothing gets around the halt"
systemctl --user stop beads-dolt-sync.timer
bdq create "pilot local-only" -t task >/dev/null
(cd "$T/elsewhere" && timeout 120 dolt pull origin main && dolt sql -q "UPDATE issues SET priority=0 WHERE id='$id'" && dolt add -A && dolt commit -m "pilot: remote-only" && timeout 120 dolt push origin main) >/dev/null 2>&1
ai-sandbox-beads-sync >/dev/null
check "diverged: halt marker written" grep -q "diverged from DoltHub" "$MARKER"
check "diverged: server stopped" bash -c "! systemctl --user is-active -q beads-dolt"
check "status says STOPPED ON PURPOSE (exit 2)" bash -c "ai-sandbox-beads-status | head -n1 | grep -q 'STOPPED ON PURPOSE'; [ \${PIPESTATUS[0]} = 2 ]"
check "bd fails while halted" bash -c "! (cd '$T/repo' && timeout 60 bd list)"
check "bd started no dolt server of its own" bash -c "! pgrep -x dolt && [ ! -e '$T/repo/.beads/dolt' ]"
check "ai-sandbox-beads-server start refuses (exit 3)" bash -c "ai-sandbox-beads-server start; [ \$? = 3 ]"
systemctl --user start beads-dolt >/dev/null 2>&1; sleep 2
check "systemctl --user start doesn't bring it up" bash -c "! systemctl --user is-active -q beads-dolt && ! pgrep -x dolt"
check "resume refuses while diverged" bash -c "! ai-sandbox-beads-server resume"
systemctl --user start beads-dolt-sync.timer

echo "--- resolving a halt (backup, merge, resume)"
mkdir -p "$BACKUPS"; cp -a "$DATA/$DB" "$BACKUPS/$DB-pilot-$(date +%Y%m%dT%H%M%S)"
(cd "$DATA/$DB" && timeout 120 dolt fetch dolthub && dolt merge dolthub/main) >/dev/null 2>&1
resume
check "resume works once resolved" systemctl --user is-active -q beads-dolt
ai-sandbox-beads-sync >/dev/null
rows=$(dh_sql "SELECT title, priority FROM issues WHERE id='$id' OR title='pilot local-only'")
check "both sides' changes are on DoltHub" has "$rows" "edited elsewhere', '0'"
check "the local-only issue is on DoltHub" has "$rows" "pilot local-only"

echo "--- a database with no DoltHub remote halts"
q "CREATE DATABASE pilot_noremote" >/dev/null
ai-sandbox-beads-sync >/dev/null
check "no-remote database: halted" grep -q "no dolthub remote" "$MARKER"
rm -rf "$DATA/pilot_noremote"
resume

echo "--- the sync crashing halts"
mkdir -p "$(dirname "$DROPIN")"; printf '[Service]\nEnvironment=BEADS_DOLT=/nonexistent/dolt\n' > "$DROPIN"; systemctl --user daemon-reload
systemctl --user start beads-dolt-sync.service >/dev/null 2>&1; sleep 3
check "crashed sync: halted (class=sync-failed)" grep -q "class: sync-failed" "$MARKER"
rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null; systemctl --user daemon-reload
resume
check "beads running again at the end" bash -c "ai-sandbox-beads-status | head -n1 | grep -qx running"

echo "--- $pass passed, $fail failed"
echo "not covered here (see the README): 15 minutes offline, sleep/wake, a WSL VM restart, bd dolt start"
[ "$fail" = 0 ]
