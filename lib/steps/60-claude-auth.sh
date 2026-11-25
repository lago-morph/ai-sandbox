# shellcheck shell=bash
# Claude is authenticated: either a `claude setup-token` token in the secrets backend
# (used by the rc@ units; untested) or an interactive claude.ai login.

_logged_in() {
  "$AI_SANDBOX_BIN/claude" auth status --json 2>/dev/null |
    python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("loggedIn") else 1)' 2>/dev/null
}

check() {
  secrets_init
  if secret_has "$SECRET_CLAUDE_TOKEN"; then
    info "using setup-token from $(secret_describe "$SECRET_CLAUDE_TOKEN") (untested with Remote Control)"
    return 0
  fi
  _logged_in || { info "Claude is not logged in"; return 1; }
}

apply() {
  if [ -t 0 ] && [ -t 1 ]; then
    info "starting interactive Claude login"
    "$AI_SANDBOX_BIN/claude" auth login
  else
    secrets_init
    die "log in to Claude: run 'claude auth login' in a terminal, or put a token from 'claude setup-token' in $(secret_describe "$SECRET_CLAUDE_TOKEN"); then re-run setup"
  fi
}
