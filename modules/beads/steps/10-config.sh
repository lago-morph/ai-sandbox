# shellcheck shell=bash
# Dolt's commit identity from git's; bd told never to start a Dolt server of its own
# (~/.config/bd/config.yaml); the server's data directory. See modules/beads/README.md.

# shellcheck source=../lib/beads.sh
source "$AI_SANDBOX_MODULE_DIR/lib/beads.sh"
BD_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/bd/config.yaml

_ident_ok() {
  local k
  for k in user.name user.email; do
    [ -n "$(git config --global "$k")" ] || return 1
    [ "$("$BEADS_DOLT" config --global --get "$k" 2>/dev/null)" = "$(git config --global "$k")" ] || return 1
  done
}

check() {
  local ok=0
  _ident_ok || { info "dolt's user.name/user.email don't match git's"; ok=1; }
  grep -qs '^  auto-start: false' "$BD_CONFIG" || { info "$BD_CONFIG doesn't set dolt.auto-start: false"; ok=1; }
  [ -d "$BEADS_DATA" ] || { info "$BEADS_DATA missing"; ok=1; }
  return $ok
}

apply() {
  local k v
  for k in user.name user.email; do
    v=$(git config --global "$k") || die "git has no $k; set it (git config --global $k ...) and re-run setup"
    "$BEADS_DOLT" config --global --unset "$k" >/dev/null 2>&1 || true
    "$BEADS_DOLT" config --global --add "$k" "$v" >/dev/null
  done
  if [ -e "$BD_CONFIG" ] && ! grep -qs '^  auto-start: false' "$BD_CONFIG"; then
    die "$BD_CONFIG exists but doesn't turn off bd's server auto-start; add 'dolt:' / '  auto-start: false' to it and re-run setup"
  fi
  if [ ! -e "$BD_CONFIG" ]; then
    mkdir -p "$(dirname "$BD_CONFIG")"
    printf '# Written by ai-sandbox (modules/beads): bd never starts a Dolt server of its own here.\ndolt:\n  auto-start: false\n' > "$BD_CONFIG"
  fi
  mkdir -p "$BEADS_DATA"
}
