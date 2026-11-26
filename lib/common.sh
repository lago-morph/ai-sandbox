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

log()  { printf '%s\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# start_log NAME: from here on, copies stdout and stderr to a timestamped log file,
# ${XDG_STATE_HOME:-~/.local/state}/ai-sandbox/NAME-YYYYmmdd-HHMMSS.log, with NAME.log pointing to
# the latest. Commands this one starts (e.g. install.sh running setup.sh) log to the same file.
# Hidden prompts aren't echoed, so typed secrets don't reach the log.
start_log() {
  [ -z "${AI_SANDBOX_LOG_FILE:-}" ] || return 0
  local dir=${XDG_STATE_HOME:-$HOME/.local/state}/ai-sandbox
  mkdir -p "$dir"
  AI_SANDBOX_LOG_FILE="$dir/$1-$(date +%Y%m%d-%H%M%S).log"
  export AI_SANDBOX_LOG_FILE
  ( umask 077; : > "$AI_SANDBOX_LOG_FILE" )
  ln -sfn "$(basename "$AI_SANDBOX_LOG_FILE")" "$dir/$1.log"
  exec > >(tee -a "$AI_SANDBOX_LOG_FILE") 2>&1
  log "[$(date '+%F %T')] $1 $(git -C "${AI_SANDBOX_REPO_DIR:-.}" describe --always --dirty 2>/dev/null): logging to $AI_SANDBOX_LOG_FILE"
}
# ts: the time, for step log lines.
ts() { date +%T; }

# ---------------------------------------------------------------- config

config_defaults() {
  : "${AI_SANDBOX_GIT_BASEDIR:=$HOME/src}"
  : "${AI_SANDBOX_SECRETS_BACKEND:=file}"
  : "${AI_SANDBOX_SECRETS_DIR:=$HOME/.secrets}"
  : "${AI_SANDBOX_HOSTNAME:=}"
  : "${AI_SANDBOX_NAME_PREFIX:=$(hostname -s)}"
  : "${AI_SANDBOX_SPAWN_MODE:=worktree}"
  : "${AI_SANDBOX_PERMISSION_MODE:=}"
  : "${AI_SANDBOX_REFRESH_INTERVAL:=10min}"
  : "${AI_SANDBOX_LEAN_TOOLS:=on}"
}

config_validate() {
  case "$AI_SANDBOX_SPAWN_MODE" in
    worktree|same-dir) ;;
    *) die "AI_SANDBOX_SPAWN_MODE must be worktree or same-dir (got '$AI_SANDBOX_SPAWN_MODE')" ;;
  esac
  case "$AI_SANDBOX_LEAN_TOOLS" in
    on|off) ;;
    *) die "AI_SANDBOX_LEAN_TOOLS must be on or off (got '$AI_SANDBOX_LEAN_TOOLS')" ;;
  esac
  case "$AI_SANDBOX_PERMISSION_MODE" in
    ''|acceptEdits|auto|bypassPermissions|default|dontAsk|plan) ;;
    *) die "AI_SANDBOX_PERMISSION_MODE is not a Claude Code permission mode: '$AI_SANDBOX_PERMISSION_MODE'" ;;
  esac
  [ -f "$AI_SANDBOX_LIB/secrets/$AI_SANDBOX_SECRETS_BACKEND.sh" ] ||
    die "unknown AI_SANDBOX_SECRETS_BACKEND '$AI_SANDBOX_SECRETS_BACKEND' (no lib/secrets/$AI_SANDBOX_SECRETS_BACKEND.sh)"
  [ -z "$AI_SANDBOX_HOSTNAME" ] || [[ "$AI_SANDBOX_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "AI_SANDBOX_HOSTNAME must be a lowercase hostname label (letters, digits, '-'; got '$AI_SANDBOX_HOSTNAME')"
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
#   secrets_backend_set NAME       store the value read from stdin (replacing any old one)
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
# secret_set NAME: stores stdin as the secret. Pass the value on stdin, never as an argument.
secret_set() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "not a valid secret name: $1"
  secrets_backend_set "$1"
}

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

# Exit 0 if the Claude CLI is installed and logged in (Remote Control needs a full claude.ai
# login: it rejects `claude setup-token` tokens as inference-only).
claude_logged_in() {
  [ -x "$AI_SANDBOX_BIN/claude" ] || return 1
  "$AI_SANDBOX_BIN/claude" auth status --json 2>/dev/null |
    python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("loggedIn") else 1)' 2>/dev/null
}

# Remote Control asks "Enable Remote Control?" once per account, in a terminal; a server under
# systemd can't answer and exits. The answer is remoteDialogSeen in ~/.claude.json. Setup sets it
# on the user's behalf: running Remote Control is what this host is for.
# claude_rc_consented: exit 0 if it's answered.
claude_rc_consented() {
  python3 - <<'PY2'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p)) if os.path.exists(p) else {}
sys.exit(0 if d.get('remoteDialogSeen') is True else 1)
PY2
}

# claude_rc_consent: answers it with yes, atomically.
claude_rc_consent() {
  python3 - <<'PY2'
import json, os
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p)) if os.path.exists(p) else {}
d['remoteDialogSeen'] = True
tmp = p + '.ai-sandbox.tmp'
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY2
}

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

# claude_auto_mode TEMPLATE apply|remove|check-applied|check-removed
# Manages the ai-sandbox rules in ~/.claude/settings.json: the autoMode environment/allow
# entries (each tagged "(ai-sandbox)") and the permissions.allow entries from TEMPLATE (JSON).
# Keeps "$defaults" first in each autoMode list so the built-in rules stay. Other keys and the
# user's own entries are left alone. check-* exits 1 if apply/remove would change the file.
claude_auto_mode() {
  python3 - "$@" <<'PY'
import json, os, sys
tpl_path, action = sys.argv[1], sys.argv[2]
tpl = json.load(open(tpl_path))
tag = '(ai-sandbox)'
p = os.path.expanduser('~/.claude/settings.json')
cur = json.load(open(p)) if os.path.exists(p) else {}
d = json.loads(json.dumps(cur))
install = action in ('apply', 'check-applied')

am = d.get('autoMode', {})
for key, ours in tpl['autoMode'].items():
    lst = [e for e in am.get(key, []) if tag not in e]
    if install:
        lst = ['$defaults'] + [e for e in lst if e != '$defaults'] + ours
    elif lst == ['$defaults']:
        lst = []
    if lst: am[key] = lst
    else: am.pop(key, None)
if am: d['autoMode'] = am
else: d.pop('autoMode', None)

perms = d.get('permissions', {})
allow = [e for e in perms.get('allow', []) if e not in tpl['permissions_allow']]
if install: allow += tpl['permissions_allow']
if allow: perms['allow'] = allow
else: perms.pop('allow', None)
if perms: d['permissions'] = perms
else: d.pop('permissions', None)

if action.startswith('check'):
    sys.exit(0 if d == cur else 1)
if d != cur:
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + '.ai-sandbox.tmp'
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2); f.write('\n')
    os.replace(tmp, p)
PY
}

# claude_lean_tools TEMPLATE apply|remove|check-applied|check-removed
# Manages the lean-tools settings in ~/.claude/settings.json: TEMPLATE's permissions.deny rules
# (tools sessions don't use, removed from every session's context) and its other top-level keys
# (enableArtifact). Other keys and the user's own deny rules are left alone; remove drops a
# top-level key only if it still has TEMPLATE's value. check-* exits 1 if apply/remove would
# change the file. cloud/setup.sh merges the same template in cloud containers.
claude_lean_tools() {
  python3 - "$@" <<'PY'
import json, os, sys
tpl_path, action = sys.argv[1], sys.argv[2]
tpl = json.load(open(tpl_path))
p = os.path.expanduser('~/.claude/settings.json')
cur = json.load(open(p)) if os.path.exists(p) else {}
d = json.loads(json.dumps(cur))
install = action in ('apply', 'check-applied')

ours = tpl['permissions']['deny']
perms = d.get('permissions', {})
deny = [e for e in perms.get('deny', []) if e not in ours]
if install: deny += ours
if deny: perms['deny'] = deny
else: perms.pop('deny', None)
if perms: d['permissions'] = perms
else: d.pop('permissions', None)

for k, v in tpl.items():
    if k == 'permissions': continue
    if install: d[k] = v
    elif d.get(k) == v: d.pop(k)

if action.startswith('check'):
    sys.exit(0 if d == cur else 1)
if d != cur:
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + '.ai-sandbox.tmp'
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2); f.write('\n')
    os.replace(tmp, p)
PY
}

# hosts_render FILE NAME -> stdout: FILE with its 127.0.1.1 line set to "NAME.localdomain NAME"
# (added after the 127.0.0.1 line if missing) and WSL's "generated file" header dropped.
hosts_render() {
  python3 - "$@" <<'PY'
import os, re, sys
path, name = sys.argv[1:]
lines = open(path).read().splitlines() if os.path.exists(path) else ['127.0.0.1\tlocalhost']
# WSL's header: "This file was automatically generated..." through "# generateHosts = false".
if lines and lines[0].startswith('# This file was automatically generated by WSL'):
    end = next((i for i, l in enumerate(lines) if l.strip() == '# generateHosts = false'), 0)
    lines = lines[end + 1:]
want = f'127.0.1.1\t{name}.localdomain\t{name}'
idx = [i for i, l in enumerate(lines) if re.match(r'127\.0\.1\.1\s', l)]
if idx:
    lines[idx[0]] = want
    lines = [l for i, l in enumerate(lines) if i not in idx[1:]]
else:
    at = next((i + 1 for i, l in enumerate(lines) if re.match(r'127\.0\.0\.1\s', l)), 0)
    lines.insert(at, want)
print('\n'.join(lines))
PY
}

# ini_render FILE SECTION KEY=VALUE... -> stdout: FILE with each KEY set in [SECTION]
# (section appended if missing); everything else kept as is. For /etc/wsl.conf.
ini_render() {
  python3 - "$@" <<'PY'
import os, re, sys
path, section, *kvs = sys.argv[1:]
want = dict(kv.split('=', 1) for kv in kvs)
lines = open(path).read().splitlines() if os.path.exists(path) else []
out, cur, done = [], None, set()
def flush():
    if cur == section:
        out[insert_at:insert_at] = [f'{k} = {v}' for k, v in want.items() if k not in done]
        done.update(want)
insert_at = 0
for l in lines:
    m = re.match(r'\s*\[(.+)\]\s*$', l)
    if m:
        flush(); cur = m.group(1); out.append(l); insert_at = len(out); continue
    km = re.match(r'\s*([A-Za-z0-9_.]+)\s*=', l)
    if cur == section and km and km.group(1) in want:
        if km.group(1) not in done:
            out.append(f'{km.group(1)} = {want[km.group(1)]}'); done.add(km.group(1))
        insert_at = len(out); continue
    out.append(l)
    if l.strip(): insert_at = len(out)
flush()
if not done:
    if out and out[-1].strip(): out.append('')
    out.append(f'[{section}]'); out += [f'{k} = {v}' for k, v in want.items()]
print('\n'.join(out))
PY
}

# root_file_matches PATH CONTENT_FILE: exit 0 if PATH already has exactly that content.
root_file_matches() { [ -f "$1" ] && cmp -s "$1" "$2"; }

# root_file_write PATH CONTENT_FILE: replaces PATH with CONTENT_FILE via sudo, keeping a one-time
# backup at PATH.bak-ai-sandbox and the file's mode.
root_file_write() {
  root_file_matches "$1" "$2" && return 0
  [ ! -e "$1" ] || [ -e "$1.bak-ai-sandbox" ] || sudo cp -p "$1" "$1.bak-ai-sandbox"
  sudo tee "$1" < "$2" >/dev/null
}

# render TEMPLATE  -> stdout, substituting @VARS@ from the loaded config
render() {
  sed -e "s|@REFRESH_INTERVAL@|$AI_SANDBOX_REFRESH_INTERVAL|g" -e "s|@GIT_BASEDIR@|$AI_SANDBOX_GIT_BASEDIR|g" "$1"
}
