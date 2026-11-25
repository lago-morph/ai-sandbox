# shellcheck shell=bash
# Host conventions block in ~/.claude/CLAUDE.md, the ai-sandbox checkout trusted, and (for
# AI_SANDBOX_PERMISSION_MODE=bypassPermissions) the one-time bypass warning pre-accepted,
# since a Remote Control server running under systemd can't answer it.

_bypass_ok() {
  [ "$AI_SANDBOX_PERMISSION_MODE" = bypassPermissions ] || return 0
  python3 - <<'PY2'
import json, os, sys
p = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(p)) if os.path.exists(p) else {}
sys.exit(0 if d.get('skipDangerousModePermissionPrompt') is True else 1)
PY2
}

_bypass_fix() {
  [ "$AI_SANDBOX_PERMISSION_MODE" = bypassPermissions ] || return 0
  python3 - <<'PY2'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(p)) if os.path.exists(p) else {}
d['skipDangerousModePermissionPrompt'] = True
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, 'w'), indent=2)
PY2
}

_rendered() { local t; t=$(mktemp); render "$AI_SANDBOX_REPO_DIR/templates/claude/CLAUDE.md" > "$t"; echo "$t"; }

check() {
  local ok=0 t; t=$(_rendered)
  managed_block "$HOME/.claude/CLAUDE.md" "$t" check || { info "$HOME/.claude/CLAUDE.md ai-sandbox block missing or outdated"; ok=1; }
  rm -f "$t"
  claude_dir_trusted "$AI_SANDBOX_SELF_DIR" || { info "$AI_SANDBOX_SELF_DIR not trusted by Claude Code"; ok=1; }
  _bypass_ok || { info "bypassPermissions configured but skipDangerousModePermissionPrompt not set"; ok=1; }
  return $ok
}

apply() {
  local t; t=$(_rendered)
  managed_block "$HOME/.claude/CLAUDE.md" "$t"
  rm -f "$t"
  claude_trust_dir "$AI_SANDBOX_SELF_DIR"
  _bypass_fix
}
