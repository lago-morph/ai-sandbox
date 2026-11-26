#!/usr/bin/env bash
# The setup script of a claude.ai/code cloud environment, as one line:
#   curl -fsSL --max-time 30 https://raw.githubusercontent.com/lago-morph/ai-sandbox/main/cloud/setup.sh | bash
# Runs as root before Claude starts. Merges templates/claude/lean-tools.json into
# ~/.claude/settings.json for root and every user with a home under /home, so tools and skills
# no session uses aren't loaded into every session's context. Existing settings are kept: deny
# rules and lists such as deniedMcpServers are added to (no duplicates), objects such as
# skillOverrides are merged per entry, other keys are set.
# Never fails and never hangs, because a failing setup script stops the session from starting:
# the work is stopped after AI_SANDBOX_CLOUD_TIMEOUT seconds and the script always exits 0. A
# failed download gives bash empty input, which also exits 0. Everything is inside functions so
# bash reads the whole script from the pipe before running any of it.
#   AI_SANDBOX_CLOUD_BASE     URL of the repo's raw files (default: this repo's main)
#   AI_SANDBOX_CLOUD_TIMEOUT  seconds for the whole run (default 120)
#   AI_SANDBOX_LEAN_TOOLS     local lean-tools.json to use instead of downloading it (tests)
#   AI_SANDBOX_CLOUD_HOMES    space-separated home dirs to update (default: /root and /home/*)

ai_sandbox_cloud_work() {
  set -euo pipefail
  base=${AI_SANDBOX_CLOUD_BASE:-https://raw.githubusercontent.com/lago-morph/ai-sandbox/main}

  src=${AI_SANDBOX_LEAN_TOOLS:-}
  if [ -z "$src" ]; then
    src=$(mktemp)
    curl -fsSL --retry 3 --max-time 30 -o "$src" "$base/templates/claude/lean-tools.json"
  fi
  command -v python3 >/dev/null || { echo "ai-sandbox cloud setup: python3 not found"; exit 1; }

  homes=${AI_SANDBOX_CLOUD_HOMES:-}
  if [ -z "$homes" ]; then
    homes=/root
    for h in /home/*; do [ -d "$h" ] && homes="$homes $h"; done
  fi

  echo "ai-sandbox cloud setup: running as $(id -un); homes: $homes"
  for h in $homes; do
    python3 - "$src" "$h/.claude/settings.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
lean = json.load(open(src))
cur = json.load(open(dst)) if os.path.exists(dst) else {}
for k, v in lean.items():
    if k == 'permissions':
        perms = cur.setdefault('permissions', {})
        for kind, rules in v.items():
            have = perms.setdefault(kind, [])
            have.extend(r for r in rules if r not in have)
    elif isinstance(v, dict):  # e.g. skillOverrides: merge per entry
        cur.setdefault(k, {}).update(v)
    elif isinstance(v, list):  # e.g. deniedMcpServers: add missing entries
        have = cur.setdefault(k, [])
        have.extend(e for e in v if e not in have)
    else:
        cur[k] = v
os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst + '.tmp', 'w') as f:
    json.dump(cur, f, indent=2)
    f.write('\n')
os.replace(dst + '.tmp', dst)
print(f"ai-sandbox cloud setup: wrote {dst} ({len(cur.get('permissions', {}).get('deny', []))} deny rules)")
PY
    # Keep the owner of a user's home as the owner of its .claude files.
    owner=$(stat -c %u:%g "$h")
    [ "$(id -u)" != 0 ] || chown -R "$owner" "$h/.claude"
  done
}

ai_sandbox_cloud_main() {
  local limit=${AI_SANDBOX_CLOUD_TIMEOUT:-120} pid dog rc
  # The work gets its own process group (set -m), so the watchdog can stop all of it,
  # including commands it started.
  set -m
  ( ai_sandbox_cloud_work ) </dev/null &
  pid=$!
  set +m
  ( sleep "$limit"; kill -TERM -- "-$pid" ) </dev/null >/dev/null 2>&1 &
  dog=$!
  wait "$pid"; rc=$?
  pkill -P "$dog" 2>/dev/null; kill "$dog" 2>/dev/null
  case $rc in
    0) ;;
    143) echo "ai-sandbox cloud setup: timed out after ${limit}s; continuing" ;;
    *) echo "ai-sandbox cloud setup: failed ($rc); continuing" ;;
  esac
  return 0
}

ai_sandbox_cloud_main; exit 0
