# shellcheck shell=bash
# Shared helpers for setup.sh and the installed bin/ scripts.
# Callers set AI_SANDBOX_LIB to this directory before sourcing.

AI_SANDBOX_CONFIG=${AI_SANDBOX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/config}
AI_SANDBOX_SHARE=${AI_SANDBOX_SHARE:-$HOME/.local/share/ai-sandbox}
AI_SANDBOX_BIN=${AI_SANDBOX_BIN:-$HOME/.local/bin}
AI_SANDBOX_UNIT_DIR=${AI_SANDBOX_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}

# Names of secrets, as passed to secret_get / secret_has.
# shellcheck disable=SC2034  # used by scripts that source this file
SECRET_GITHUB=github                 # GitHub fine-grained PAT (required)
# shellcheck disable=SC2034
SECRET_CLAUDE_TOKEN=claude-oauth-token # token from `claude setup-token` (optional)

log()  { printf '%s\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- config

config_defaults() {
  : "${AI_SANDBOX_GIT_BASEDIR:=$HOME/src}"
  : "${AI_SANDBOX_SECRETS_BACKEND:=file}"
  : "${AI_SANDBOX_SECRETS_DIR:=$HOME/.secrets}"
  : "${AI_SANDBOX_NAME_PREFIX:=$(hostname -s)}"
  : "${AI_SANDBOX_SPAWN_MODE:=worktree}"
  : "${AI_SANDBOX_PERMISSION_MODE:=}"
  : "${AI_SANDBOX_REFRESH_INTERVAL:=10min}"
}

config_validate() {
  case "$AI_SANDBOX_SPAWN_MODE" in
    worktree|same-dir) ;;
    *) die "AI_SANDBOX_SPAWN_MODE must be worktree or same-dir (got '$AI_SANDBOX_SPAWN_MODE')" ;;
  esac
  case "$AI_SANDBOX_PERMISSION_MODE" in
    ''|acceptEdits|auto|bypassPermissions|default|dontAsk|plan) ;;
    *) die "AI_SANDBOX_PERMISSION_MODE is not a Claude Code permission mode: '$AI_SANDBOX_PERMISSION_MODE'" ;;
  esac
  [ -f "$AI_SANDBOX_LIB/secrets/$AI_SANDBOX_SECRETS_BACKEND.sh" ] ||
    die "unknown AI_SANDBOX_SECRETS_BACKEND '$AI_SANDBOX_SECRETS_BACKEND' (no lib/secrets/$AI_SANDBOX_SECRETS_BACKEND.sh)"
  [[ "$AI_SANDBOX_NAME_PREFIX" =~ ^[A-Za-z0-9_.-]*$ ]] ||
    die "AI_SANDBOX_NAME_PREFIX may only contain letters, digits, '.', '_' and '-'"
  AI_SANDBOX_GIT_BASEDIR=${AI_SANDBOX_GIT_BASEDIR%/}
}

# Loads the host config. Returns 1 if the config file doesn't exist.
config_load() {
  [ -f "$AI_SANDBOX_CONFIG" ] || return 1
  # shellcheck source=/dev/null
  source "$AI_SANDBOX_CONFIG"
  config_defaults
  config_validate
}

config_require() {
  config_load || die "no ai-sandbox config at $AI_SANDBOX_CONFIG (create it with ai-sandbox-init-config)"
}

# Remote Control server name shown in claude.ai for a repo.
rc_display_name() {
  if [ -n "$AI_SANDBOX_NAME_PREFIX" ]; then printf '%s-%s' "$AI_SANDBOX_NAME_PREFIX" "$1"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------- secrets
# Backends live in lib/secrets/<backend>.sh and implement:
#   secrets_backend_has NAME       exit 0 if the secret is set and non-empty
#   secrets_backend_get NAME       print the value (no trailing newline); exit 1 if missing
#   secrets_backend_describe NAME  print where the secret is expected (for messages; never the value)
#   secrets_backend_check          exit 0 if storage is safe (e.g. permissions); print problems
#   secrets_backend_fix            repair what secrets_backend_check reports, where possible

secrets_init() {
  # shellcheck source=/dev/null
  source "$AI_SANDBOX_LIB/secrets/$AI_SANDBOX_SECRETS_BACKEND.sh"
}
secret_has()      { secrets_backend_has "$1"; }
secret_get()      { secrets_backend_get "$1"; }
secret_describe() { secrets_backend_describe "$1"; }

# ---------------------------------------------------------------- platform
# Distro support lives in lib/platform/<os-release ID>.sh. See lib/platform/README.md.

platform_id() { ( . /etc/os-release && printf '%s' "$ID" ); }
platform_load() {
  local id; id=$(platform_id)
  [ -f "$AI_SANDBOX_LIB/platform/$id.sh" ] ||
    die "unsupported distro '$id': add lib/platform/$id.sh (see lib/platform/README.md)"
  # shellcheck source=/dev/null
  source "$AI_SANDBOX_LIB/platform/$id.sh"
}
is_wsl() { grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

# ---------------------------------------------------------------- claude files

# Marks a directory trusted in ~/.claude.json (the workspace trust dialog), atomically.
claude_trust_dir() {
  python3 - "$1" <<'PY'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p)) if os.path.exists(p) else {}
proj = d.setdefault('projects', {}).setdefault(sys.argv[1], {})
if proj.get('hasTrustDialogAccepted') is True:
    sys.exit(0)
proj['hasTrustDialogAccepted'] = True
tmp = p + '.ai-sandbox.tmp'
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
}

claude_dir_trusted() {
  python3 - "$1" <<'PY'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p)) if os.path.exists(p) else {}
sys.exit(0 if d.get('projects', {}).get(sys.argv[1], {}).get('hasTrustDialogAccepted') is True else 1)
PY
}

# managed_block FILE CONTENT_FILE [check]
# Replaces (or appends) the block between ai-sandbox markers in FILE with CONTENT_FILE,
# leaving everything else in FILE untouched. With "check", only reports whether it's current.
managed_block() {
  python3 - "$@" <<'PY'
import os, sys
path, src = sys.argv[1], sys.argv[2]
check = len(sys.argv) > 3 and sys.argv[3] == 'check'
begin, end = '<!-- ai-sandbox:begin (managed by ai-sandbox setup; edits here are overwritten) -->', '<!-- ai-sandbox:end -->'
block = begin + '\n' + open(src).read().rstrip('\n') + '\n' + end + '\n'
cur = open(path).read() if os.path.exists(path) else ''
b = cur.find('<!-- ai-sandbox:begin')
e = cur.find(end)
if b != -1 and e != -1:
    new = cur[:b] + block + cur[e + len(end):].lstrip('\n')
else:
    new = cur + ('\n' if cur and not cur.endswith('\n') else '') + ('\n' if cur else '') + block
if check:
    sys.exit(0 if new == cur else 1)
if new != cur:
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w') as f:
        f.write(new)
PY
}

# render TEMPLATE  -> stdout, substituting @VARS@ from the loaded config
render() {
  sed -e "s|@REFRESH_INTERVAL@|$AI_SANDBOX_REFRESH_INTERVAL|g" -e "s|@GIT_BASEDIR@|$AI_SANDBOX_GIT_BASEDIR|g" "$1"
}
