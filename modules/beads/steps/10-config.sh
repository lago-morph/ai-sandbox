# shellcheck shell=bash
# Dolt's commit identity from git's; bd told never to start a Dolt server of its own and to send
# no usage metrics (~/.config/bd/config.yaml); the server's data directory. See modules/beads/README.md.

# shellcheck source=../lib/beads.sh
source "$AI_SANDBOX_MODULE_DIR/lib/beads.sh"
BD_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/bd/config.yaml

# _bd_config check|apply: the user-level bd config (which bd also writes itself) sets
# dolt.auto-start: false (bd never starts a Dolt server of its own), metrics.disabled: true (no
# usage telemetry; a repo's config can't turn it back on) and metrics.endpoint pointing nowhere.
# Other keys are left as they are.
_bd_config() {
  python3 - "$BD_CONFIG" "$1" <<'PY'
import os, re, sys
path, action = sys.argv[1], sys.argv[2]
want = [('dolt', 'auto-start', 'false'), ('metrics', 'disabled', 'true'),
        # Belt and braces: if the switch were ever ignored, metrics go to a local port nothing
        # listens on (bd uses its built-in endpoint only when this is empty).
        ('metrics', 'endpoint', 'http://127.0.0.1:9/ai-sandbox-metrics-disabled')]
lines = open(path).read().splitlines() if os.path.exists(path) else []
def section(name):
    start = next((i for i, l in enumerate(lines) if re.match(rf'{re.escape(name)}:\s*(#.*)?$', l)), None)
    if start is None:
        return None, None
    end = next((i for i in range(start + 1, len(lines)) if lines[i] and not lines[i][0].isspace()), len(lines))
    return start, end
changed = False
for sec, key, val in want:
    start, end = section(sec)
    if start is None:
        if lines and lines[-1].strip():
            lines.append('')
        lines += [f'# Set by ai-sandbox (modules/beads).', f'{sec}:', f'  {key}: {val}']
        changed = True
        continue
    for i in range(start + 1, end):
        m = re.match(rf'(\s+){re.escape(key)}:\s*([^#]*?)\s*(#.*)?$', lines[i])
        if m:
            if m.group(2) != val:
                lines[i] = f'{m.group(1)}{key}: {val}'; changed = True
            break
    else:
        indent = next((re.match(r'\s+', lines[i]).group(0) for i in range(start + 1, end) if lines[i].strip()), '  ')
        lines.insert(start + 1, f'{indent}{key}: {val}'); changed = True
if action == 'check':
    sys.exit(1 if changed else 0)
if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + '.tmp', 'w') as f:
        f.write('\n'.join(lines) + '\n')
    os.chmod(path + '.tmp', 0o600)
    os.replace(path + '.tmp', path)
PY
}

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
  _bd_config check || { info "$BD_CONFIG doesn't turn off bd's server auto-start and metrics"; ok=1; }
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
  _bd_config apply
  mkdir -p "$BEADS_DATA"
}
