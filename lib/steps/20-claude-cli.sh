# shellcheck shell=bash
# Claude Code native build in ~/.local/bin/claude.

check() {
  [ -x "$AI_SANDBOX_BIN/claude" ] || { info "claude not installed at $AI_SANDBOX_BIN/claude"; return 1; }
}

apply() {
  curl -fsSL https://claude.ai/install.sh | bash
}
