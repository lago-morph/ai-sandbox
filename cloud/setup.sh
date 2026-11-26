#!/usr/bin/env bash
# Usage: cloud/setup.sh   (run by cloud/bootstrap.sh, as root, in a claude.ai/code container)
# Merges templates/claude/lean-tools.json into ~/.claude/settings.json for root and every user
# with a home under /home, so tools no session uses aren't loaded into every session's context.
# Existing settings are kept: deny rules are added (no duplicates), objects such as
# skillOverrides are merged per entry, other keys are set.
#   AI_SANDBOX_CLOUD_BASE   URL of the repo's raw files (set by bootstrap.sh)
#   AI_SANDBOX_LEAN_TOOLS   local lean-tools.json to use instead of downloading it (tests)
#   AI_SANDBOX_CLOUD_HOMES  space-separated home dirs to update (default: /root and /home/*)
set -euo pipefail

src=${AI_SANDBOX_LEAN_TOOLS:-}
if [ -z "$src" ]; then
  src=$(mktemp)
  curl -fsSL --retry 3 -o "$src" "${AI_SANDBOX_CLOUD_BASE:?}/templates/claude/lean-tools.json"
fi
command -v python3 >/dev/null || { echo "ai-sandbox cloud setup: python3 not found; skipped"; exit 1; }

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
