# shellcheck shell=bash
# Host conventions block in ~/.claude/CLAUDE.md, the ai-sandbox checkout trusted, Remote
# Control's one-time "Enable Remote Control?" answered yes (remoteDialogSeen), and (for
# AI_SANDBOX_PERMISSION_MODE=bypassPermissions) the one-time bypass warning pre-accepted,
# since a Remote Control server running under systemd can't answer it. With bypassPermissions,
# also the ai-sandbox auto mode rules in ~/.claude/settings.json (templates/claude/auto-mode.json):
# the Claude app puts sessions it creates in auto mode regardless of --permission-mode, so these
# rules tell auto mode's classifier that the user pre-approved everything. Otherwise they're removed.
# With AI_SANDBOX_LEAN_TOOLS=on (default), the deny rules in templates/claude/lean-tools.json, so
# tools sessions don't use aren't loaded into their context; with off, they're removed.

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

_rendered() { local t; t=$(mktemp); render "$AI_SANDBOX_REPO_DIR/templates/claude/CLAUDE.md" > "$t"; echo "$t"; }

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
}
