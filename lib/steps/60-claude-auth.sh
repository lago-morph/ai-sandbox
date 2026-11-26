# shellcheck shell=bash
# Claude is logged in to claude.ai (`claude auth login`), and the user has said yes to Remote
# Control's one-time "Enable Remote Control?" question. Remote Control needs the full login (it
# rejects `claude setup-token` tokens), and a server under systemd can't answer the question.

check() {
  local ok=0
  claude_logged_in || { info "Claude is not logged in"; ok=1; }
  claude_rc_consented || { info "Remote Control hasn't been enabled yet (its one-time \"Enable Remote Control?\" question)"; ok=1; }
  return $ok
}

apply() {
  if ! claude_logged_in; then
    # Straight to the terminal: setup's own output may be going through a log pipe.
    if (: </dev/tty >/dev/tty) 2>/dev/null; then
      info "starting interactive Claude login"
      "$AI_SANDBOX_BIN/claude" auth login </dev/tty >/dev/tty 2>&1
    else
      die "log in to Claude: run '$AI_SANDBOX_BIN/claude auth login' in a terminal, then re-run setup"
    fi
  fi
  claude_rc_consented || die "enable Remote Control once, in a terminal: run '$AI_SANDBOX_BIN/claude remote-control', answer y, and press Ctrl+C when it shows Ready; then re-run setup"
}
