# shellcheck shell=bash
# Claude is logged in to claude.ai (`claude auth login`). Remote Control needs this full login;
# it rejects `claude setup-token` tokens.

check() {
  claude_logged_in || { info "Claude is not logged in"; return 1; }
}

apply() {
  # Straight to the terminal: setup's own output may be going through a log pipe.
  if (: </dev/tty >/dev/tty) 2>/dev/null; then
    info "starting interactive Claude login"
    "$AI_SANDBOX_BIN/claude" auth login </dev/tty >/dev/tty 2>&1
  else
    die "log in to Claude: run '$AI_SANDBOX_BIN/claude auth login' in a terminal, then re-run setup"
  fi
}
