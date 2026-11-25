# shellcheck shell=bash
# Copies this repo's commands to ~/.local/bin and its lib/config/templates to
# ~/.local/share/ai-sandbox. The host only changes when setup is run again.

INSTALL_DIRS=(lib config templates)

_bin_files() { find "$AI_SANDBOX_REPO_DIR/bin" -maxdepth 1 -type f -printf '%f\n' | sort; }

check() {
  local ok=0 f d
  for f in $(_bin_files); do
    cmp -s "$AI_SANDBOX_REPO_DIR/bin/$f" "$AI_SANDBOX_BIN/$f" || { info "$AI_SANDBOX_BIN/$f is missing or differs"; ok=1; }
  done
  for d in "${INSTALL_DIRS[@]}"; do
    diff -rq "$AI_SANDBOX_REPO_DIR/$d" "$AI_SANDBOX_SHARE/$d" >/dev/null 2>&1 || { info "$AI_SANDBOX_SHARE/$d is missing or differs"; ok=1; }
  done
  return $ok
}

apply() {
  local f d
  mkdir -p "$AI_SANDBOX_BIN" "$AI_SANDBOX_SHARE"
  # Remove commands a previous install put there that this version no longer has.
  if [ -f "$AI_SANDBOX_SHARE/installed-bin.txt" ]; then
    for f in $(comm -23 <(sort "$AI_SANDBOX_SHARE/installed-bin.txt") <(_bin_files)); do
      rm -f "$AI_SANDBOX_BIN/$f"
    done
  fi
  for f in $(_bin_files); do install -m 755 "$AI_SANDBOX_REPO_DIR/bin/$f" "$AI_SANDBOX_BIN/$f"; done
  _bin_files > "$AI_SANDBOX_SHARE/installed-bin.txt"
  for d in "${INSTALL_DIRS[@]}"; do
    rm -rf "${AI_SANDBOX_SHARE:?}/${d:?}"
    cp -r "$AI_SANDBOX_REPO_DIR/$d" "$AI_SANDBOX_SHARE/$d"
  done
  git -C "$AI_SANDBOX_REPO_DIR" describe --always --dirty > "$AI_SANDBOX_SHARE/VERSION" 2>/dev/null || true
}
