# shellcheck shell=bash
# Host conventions block in ~/.claude/CLAUDE.md, the ai-sandbox checkout trusted, Remote
# Control's one-time "Enable Remote Control?" answered yes (remoteDialogSeen), and (for
# AI_SANDBOX_PERMISSION_MODE=bypassPermissions) the one-time bypass warning pre-accepted,
# since a Remote Control server running under systemd can't answer it. With bypassPermissions,
# also the ai-sandbox auto mode rules in ~/.claude/settings.json (templates/claude/auto-mode.json):
# the Claude app puts sessions it creates in auto mode regardless of --permission-mode, so these
# rules replace auto mode's block rules with nothing and tell its classifier the user pre-approved
# everything. Otherwise they're removed.
# With AI_SANDBOX_LEAN_TOOLS=on (default), the deny rules in templates/claude/lean-tools.json, so
# tools sessions don't use aren't loaded into their context; with off, they're removed.
# Also: each installed module's claude.md lines appended to the block and its settings.json
# entries merged in, and the SessionStart hook (templates/claude/session-start.json) that runs
# `ai-sandbox-status --brief` so every session starts with a line about anything unhealthy.

# shellcheck source=../modules.sh
source "$AI_SANDBOX_LIB/modules.sh"

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

_auto_mode_action() { [ "$AI_SANDBOX_PERMISSION_MODE" = bypassPermissions ] && echo applied || echo removed; }
_auto_mode_tpl() { echo "$AI_SANDBOX_REPO_DIR/templates/claude/auto-mode.json"; }

_lean_action() { [ "$AI_SANDBOX_LEAN_TOOLS" = on ] && echo applied || echo removed; }
_lean_tpl() { echo "$AI_SANDBOX_REPO_DIR/templates/claude/lean-tools.json"; }

_rendered() {
  local t; t=$(mktemp)
  { render "$AI_SANDBOX_REPO_DIR/templates/claude/CLAUDE.md"; modules_claude_md; } > "$t"
  echo "$t"
}
_fragments() { echo "$AI_SANDBOX_REPO_DIR/templates/claude/session-start.json"; modules_settings_fragments; }

check() {
  local ok=0 t; t=$(_rendered)
  managed_block "$HOME/.claude/CLAUDE.md" "$t" check || { info "$HOME/.claude/CLAUDE.md ai-sandbox block missing or outdated"; ok=1; }
  rm -f "$t"
  claude_dir_trusted "$AI_SANDBOX_SELF_DIR" || { info "$AI_SANDBOX_SELF_DIR not trusted by Claude Code"; ok=1; }
  claude_rc_consented || { info "Remote Control's one-time \"Enable Remote Control?\" not answered yet"; ok=1; }
  _bypass_ok || { info "bypassPermissions configured but skipDangerousModePermissionPrompt not set"; ok=1; }
  claude_auto_mode "$(_auto_mode_tpl)" "check-$(_auto_mode_action)" ||
    { info "ai-sandbox auto mode rules in ~/.claude/settings.json should be $(_auto_mode_action)"; ok=1; }
  claude_lean_tools "$(_lean_tpl)" "check-$(_lean_action)" ||
    { info "lean-tools deny rules in ~/.claude/settings.json should be $(_lean_action) (AI_SANDBOX_LEAN_TOOLS=$AI_SANDBOX_LEAN_TOOLS)"; ok=1; }
  local f
  for f in $(_fragments); do
    claude_settings_merge "$f" check || { info "$HOME/.claude/settings.json lacks the entries from $f"; ok=1; }
  done
  return $ok
}

apply() {
  local t; t=$(_rendered)
  managed_block "$HOME/.claude/CLAUDE.md" "$t"
  rm -f "$t"
  claude_trust_dir "$AI_SANDBOX_SELF_DIR"
  claude_rc_consented || { info "answering \"Enable Remote Control?\" with yes for $USER (remoteDialogSeen in ~/.claude.json)"; claude_rc_consent; }
  _bypass_fix
  if [ "$(_auto_mode_action)" = applied ]; then
    claude_auto_mode "$(_auto_mode_tpl)" apply
  else
    claude_auto_mode "$(_auto_mode_tpl)" remove
  fi
  if [ "$(_lean_action)" = applied ]; then
    claude_lean_tools "$(_lean_tpl)" apply
  else
    claude_lean_tools "$(_lean_tpl)" remove
  fi
  local f
  for f in $(_fragments); do claude_settings_merge "$f" apply; done
}
