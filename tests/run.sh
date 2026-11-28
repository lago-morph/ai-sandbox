#!/usr/bin/env bash
# Usage: tests/run.sh [--host]
# Regression tests. Each test runs against a throwaway $HOME and never touches the real
# host config, secrets, systemd or network.
#   --host   also run `./setup.sh --check` against this machine's real config (read-only)
set -uo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
export AI_SANDBOX_LIB="$REPO/lib"
pass=0 fail=0 failed=()

# ------------------------------------------------------------------ harness

new_home() {
  T=$(mktemp -d)
  export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
  unset AI_SANDBOX_CONFIG AI_SANDBOX_SHARE AI_SANDBOX_BIN AI_SANDBOX_UNIT_DIR
  unset AI_SANDBOX_GIT_BASEDIR AI_SANDBOX_SECRETS_BACKEND AI_SANDBOX_SECRETS_DIR
  unset AI_SANDBOX_HOSTNAME AI_SANDBOX_NAME_PREFIX AI_SANDBOX_SPAWN_MODE AI_SANDBOX_PERMISSION_MODE AI_SANDBOX_REFRESH_INTERVAL
  unset AI_SANDBOX_MODULES AI_SANDBOX_STATE AI_SANDBOX_VERSIONS AI_SANDBOX_MODULES_DIR AI_SANDBOX_PLATFORM
  unset XDG_STATE_HOME DOLT_CREDS_JWK TEST_CRED DOLTHUB_ACCOUNT DH_TOKEN BEADS_PORT BEADS_DATA BEADS_DOLT
  mkdir -p "$HOME/.secrets" && chmod 700 "$HOME/.secrets"
  export PATH="$REPO/bin:$ORIG_PATH"
}
ORIG_PATH=$PATH ORIG_HOME=$HOME

run_test() {
  local name=$1 out status
  # Not inside `if`: set -e must stay in force so the first failing assertion fails the test.
  out=$( (new_home; trap 'rm -rf "$T"' EXIT; set -e; "$name") 2>&1 )
  status=$?
  if [ $status = 0 ]; then
    pass=$((pass + 1)); echo "ok    $name"
  else
    fail=$((fail + 1)); failed+=("$name"); echo "FAIL  $name"; sed 's/^/      /' <<<"$out"
  fi
}

assert_eq()       { [ "$1" = "$2" ] || { echo "expected [$2], got [$1]${3:+ ($3)}"; return 1; }; }
assert_contains() { grep -qF -- "$2" <<<"$1" || { echo "expected output to contain [$2]; got:"; echo "$1"; return 1; }; }
assert_fails()    { if "$@" >/dev/null 2>&1; then echo "expected failure: $*"; return 1; fi; }

# ------------------------------------------------------------------ tests

test_lint() {
  bash -n "$REPO/setup.sh"; bash -n "$REPO/setup-root.sh"; bash -n "$REPO/install.sh"
  local files
  files=$(cd "$REPO" && shopt -s nullglob && echo bin/* lib/*.sh lib/*/*.sh tests/*.sh tests/host/*.sh cloud/*.sh \
    modules/*/bin/* modules/*/steps/*.sh tests/fixtures/modules/*/bin/* tests/fixtures/modules/*/steps/*.sh)
  for f in $files; do bash -n "$REPO/$f"; done
  for f in "$REPO"/lib/*.py; do python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f"; done
  if command -v shellcheck >/dev/null; then
    # shellcheck disable=SC2086
    (cd "$REPO" && shellcheck -x -S warning setup.sh setup-root.sh install.sh $files)
  else
    echo "(shellcheck not installed; syntax only)"
  fi
}

test_config_defaults() {
  ai-sandbox-init-config >/dev/null
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  assert_eq "$AI_SANDBOX_GIT_BASEDIR" "$HOME/src"
  assert_eq "$AI_SANDBOX_SECRETS_BACKEND" file
  assert_eq "$AI_SANDBOX_SECRETS_DIR" "$HOME/.secrets"
  assert_eq "$AI_SANDBOX_SPAWN_MODE" worktree
  assert_eq "$AI_SANDBOX_NAME_PREFIX" "$(hostname -s)"
  assert_eq "$AI_SANDBOX_PERMISSION_MODE" ""
  assert_eq "$AI_SANDBOX_HOSTNAME" ""
  assert_eq "$(stat -c %a "$AI_SANDBOX_CONFIG")" 600
}

test_init_config_overrides() {
  ai-sandbox-init-config AI_SANDBOX_NAME_PREFIX=laptop AI_SANDBOX_PERMISSION_MODE=bypassPermissions \
    "AI_SANDBOX_GIT_BASEDIR=$HOME/code" >/dev/null
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  assert_eq "$AI_SANDBOX_NAME_PREFIX" laptop
  assert_eq "$AI_SANDBOX_PERMISSION_MODE" bypassPermissions
  assert_eq "$AI_SANDBOX_GIT_BASEDIR" "$HOME/code"
  assert_eq "$(rc_display_name ai-sandbox)" laptop-ai-sandbox
}

test_init_config_refuses_overwrite_and_bad_input() {
  ai-sandbox-init-config >/dev/null
  assert_fails ai-sandbox-init-config
  ai-sandbox-init-config --force AI_SANDBOX_SPAWN_MODE=same-dir >/dev/null
  assert_fails ai-sandbox-init-config --force AI_SANDBOX_SPAWN_MODE=bogus
  assert_fails ai-sandbox-init-config --force AI_SANDBOX_NOT_A_KEY=1
  assert_fails ai-sandbox-init-config --force AI_SANDBOX_SECRETS_BACKEND=nope
  assert_fails ai-sandbox-init-config --force AI_SANDBOX_HOSTNAME=Bad_Name
  assert_fails ai-sandbox-init-config --force AI_SANDBOX_HOSTNAME=-x
  # The failed attempts left the previous valid config in place.
  assert_contains "$(cat "$XDG_CONFIG_HOME/ai-sandbox/config")" "AI_SANDBOX_SPAWN_MODE=same-dir"
}

test_secret_file_backend() {
  ai-sandbox-init-config >/dev/null
  printf '  tok-123 \n' > "$HOME/.secrets/github"; chmod 600 "$HOME/.secrets/github"
  : > "$HOME/.secrets/other"
  ai-sandbox-secret has github
  assert_eq "$(ai-sandbox-secret get github)" tok-123
  assert_fails ai-sandbox-secret has other   # empty file counts as missing
  assert_fails ai-sandbox-secret get missing
  assert_eq "$(ai-sandbox-secret describe github)" "file $HOME/.secrets/github"
}

test_secret_file_permissions() {
  ai-sandbox-init-config >/dev/null
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load; secrets_init
  echo x > "$HOME/.secrets/github"; chmod 644 "$HOME/.secrets/github"; chmod 755 "$HOME/.secrets"
  local out; out=$(secrets_backend_check) && { echo "check should fail"; return 1; }
  assert_contains "$out" "should be mode 700"
  assert_contains "$out" "should be mode 600"
  secrets_backend_fix
  secrets_backend_check
}

test_secret_set() {
  ai-sandbox-init-config >/dev/null
  rmdir "$HOME/.secrets"
  printf 'tok-new' | ai-sandbox-secret set github
  assert_eq "$(ai-sandbox-secret get github)" tok-new
  assert_eq "$(stat -c %a "$HOME/.secrets")" 700
  assert_eq "$(stat -c %a "$HOME/.secrets/github")" 600
  printf 'tok-2\n' | ai-sandbox-secret set github
  assert_eq "$(ai-sandbox-secret get github)" tok-2
  assert_eq "$(find "$HOME/.secrets" -name '.*' -type f | wc -l)" 0 "no temp files left"
  assert_fails sh -c 'echo x | ai-sandbox-secret set ../evil'
}

# A fake GitHub API (file://) that knows one account; tokens aren't checked by it.
fake_github() { mkdir -p "$T/api"; echo '{"login":"octo"}' > "$T/api/user"; export AI_SANDBOX_GITHUB_API="file://$T/api"; }
# A fake Claude CLI whose `auth status` reports logged in (true) or not (false).
fake_claude() {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && echo %s\n' "'{\"loggedIn\": ${1:-true}}'" > "$HOME/.local/bin/claude"
  chmod +x "$HOME/.local/bin/claude"
}

test_rc_consent() {
  # setup answers "Enable Remote Control?" (70-claude-config), keeping the rest of ~/.claude.json.
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  echo '{"projects": {"/x": {"hasTrustDialogAccepted": true}}}' > "$HOME/.claude.json"
  assert_fails claude_rc_consented
  claude_rc_consent
  claude_rc_consented
  claude_dir_trusted /x
  assert_eq "$(stat -c %a "$HOME/.claude.json")" 600
}

test_install_requires_claude_login() {
  fake_github
  local out
  out=$(printf 'box1\n\n\n\ny\ntok-1\n' | "$REPO/install.sh" --no-setup 2>&1) && { echo "should fail"; return 1; }
  assert_contains "$out" "curl -fsSL https://claude.ai/install.sh | bash"
  assert_contains "$out" "claude auth login"
  fake_claude false
  assert_fails sh -c "printf 'box1\n\n\n\ny\ntok-1\n' | '$REPO/install.sh' --no-setup"
  [ ! -e "$XDG_CONFIG_HOME/ai-sandbox/config" ]
  fake_claude true
  printf 'box1\n\n\n\ny\ntok-1\n' | env -u GH_TOKEN -u GITHUB_TOKEN "$REPO/install.sh" --no-setup >/dev/null 2>&1
  [ -e "$XDG_CONFIG_HOME/ai-sandbox/config" ]
}

test_install_fresh() {
  fake_github; fake_claude
  # hostname, prefix (default), mode (default), advanced? n, write? y, GitHub token
  local out
  out=$(printf 'box1\n\n\n\ny\ntok-1\n' | env -u GH_TOKEN -u GITHUB_TOKEN \
    "$REPO/install.sh" --no-setup 2>&1)
  assert_contains "$out" "stored the token for GitHub user octo"
  assert_contains "$out" "Claude CLI is installed and logged in"
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  assert_eq "$AI_SANDBOX_HOSTNAME" box1
  assert_eq "$AI_SANDBOX_NAME_PREFIX" box1
  assert_eq "$AI_SANDBOX_PERMISSION_MODE" bypassPermissions
  assert_eq "$AI_SANDBOX_GIT_BASEDIR" "$(dirname "$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")")"
  assert_eq "$(ai-sandbox-secret get github)" tok-1
  if grep -q tok-1 <<<"$out"; then echo "token echoed"; return 1; fi
  # Everything went to a private log as well, without the token.
  local logf; logf=$(readlink -f "$HOME/.local/state/ai-sandbox/install.log")
  assert_contains "$out" "full log: $logf"
  assert_contains "$(cat "$logf")" "stored the token for GitHub user octo"
  assert_eq "$(stat -c %a "$logf")" 600
  if grep -q tok-1 "$logf"; then echo "token in log"; return 1; fi
}

test_install_tokens_from_files() {
  fake_github; fake_claude
  printf 'tok-file\n' > "$HOME/gh-token"
  # Empty hostname answer: the current hostname is the default. The token is given as ~/path.
  printf '\n\n\n\ny\n~/gh-token\n' | env -u GH_TOKEN -u GITHUB_TOKEN "$REPO/install.sh" --no-setup >/dev/null 2>&1
  assert_eq "$(ai-sandbox-secret get github)" tok-file
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  assert_eq "$AI_SANDBOX_HOSTNAME" "$(hostname -s | tr '[:upper:]' '[:lower:]')"
  # A path that doesn't exist aborts instead of being stored as the token.
  rm "$HOME/.secrets/github"
  assert_fails sh -c "printf '\n\n\n\ny\n/no/such/file\n' | env -u GH_TOKEN -u GITHUB_TOKEN '$REPO/install.sh' --no-setup"
  assert_fails ai-sandbox-secret has github
}

test_install_rerun_keeps_values() {
  fake_github; fake_claude
  printf 'box1\npfx\nauto\n\ny\ntok-1\n' | env -u GH_TOKEN -u GITHUB_TOKEN "$REPO/install.sh" --no-setup >/dev/null 2>&1
  # All defaults: the existing config and token are kept.
  local out
  out=$(printf '\n\n\n\ny\n' | env -u GH_TOKEN -u GITHUB_TOKEN "$REPO/install.sh" --no-setup 2>&1)
  assert_contains "$out" "using the stored token for GitHub user octo"
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  assert_eq "$AI_SANDBOX_HOSTNAME" box1
  assert_eq "$AI_SANDBOX_NAME_PREFIX" pfx
  assert_eq "$AI_SANDBOX_PERMISSION_MODE" auto
  assert_eq "$(ai-sandbox-secret get github)" tok-1
}

test_install_token_from_env_and_rejected() {
  # GitHub unreachable/rejecting: a token from GH_TOKEN is refused, then an empty paste aborts.
  export AI_SANDBOX_GITHUB_API="file://$T/nowhere"; fake_claude
  local out
  out=$(printf 'box1\n\n\n\ny\ny\n\n' | GH_TOKEN=tok-env env -u GITHUB_TOKEN "$REPO/install.sh" --no-setup 2>&1) &&
    { echo "should fail"; return 1; }
  assert_contains "$out" "GitHub rejected that token"
  assert_contains "$out" "a GitHub token is required"
  assert_fails ai-sandbox-secret has github
  # Accepted from the environment.
  fake_github
  out=$(printf 'box1\n\n\n\ny\ny\n' | GH_TOKEN=tok-env env -u GITHUB_TOKEN "$REPO/install.sh" --no-setup 2>&1)
  assert_eq "$(ai-sandbox-secret get github)" tok-env
}

test_install_validates_answers() {
  fake_github; fake_claude
  # A bad hostname and bad mode are re-asked; a checkout dir that doesn't hold the repo aborts.
  local out
  out=$(printf 'Bad_Name\nbox2\n\nnope\n\ny\n/elsewhere\n\n\n\n' | "$REPO/install.sh" --no-setup 2>&1) &&
    { echo "should fail"; return 1; }
  assert_contains "$out" "use lowercase letters"
  assert_contains "$out" "not a permission mode: nope"
  assert_contains "$out" "must be cloned directly in /elsewhere"
  [ ! -e "$XDG_CONFIG_HOME/ai-sandbox/config" ]
}

test_git_credential_helper() {
  ai-sandbox-init-config >/dev/null
  echo tok-abc > "$HOME/.secrets/github"; chmod 600 "$HOME/.secrets/github"
  local out
  out=$(printf 'protocol=https\nhost=github.com\n\n' | ai-sandbox-git-credential get)
  assert_eq "$out" "$(printf 'username=x-access-token\npassword=tok-abc')"
  out=$(printf 'protocol=https\nhost=example.com\n\n' | ai-sandbox-git-credential get)
  assert_eq "$out" "" "other hosts get nothing"
  out=$(printf 'protocol=https\nhost=github.com\npassword=x\n\n' | ai-sandbox-git-credential store)
  assert_eq "$out" "" "store is ignored"
}

test_git_credential_helper_without_secret() {
  ai-sandbox-init-config >/dev/null
  local out; out=$(printf 'protocol=https\nhost=github.com\n\n' | ai-sandbox-git-credential get)
  assert_eq "$out" "" "no token: let git fall through to other helpers"
}

test_rc_start_rejects_bad_args() {
  ai-sandbox-init-config >/dev/null
  assert_fails rc-start '../etc'
  assert_fails rc-start '/tmp/x'
  assert_fails rc-start 'a/b/c'
  assert_fails rc-start 'not-cloned-yet'   # bare name that doesn't exist: needs owner/repo
}

test_managed_block() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local f="$HOME/.claude/CLAUDE.md" src; src=$(mktemp)
  mkdir -p "$HOME/.claude"; printf '# Mine\nkeep me\n' > "$f"
  echo "v1" > "$src"
  assert_fails managed_block "$f" "$src" check
  managed_block "$f" "$src"
  managed_block "$f" "$src" check
  echo "v2" > "$src"; managed_block "$f" "$src"
  local body; body=$(cat "$f")
  assert_contains "$body" "keep me"
  assert_contains "$body" "v2"
  if grep -q v1 "$f"; then echo "old block content left behind"; return 1; fi
  assert_eq "$(grep -c 'ai-sandbox:begin' "$f")" 1
}

test_claude_trust() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  echo '{"projects":{"/x":{"other":1}},"keep":true}' > "$HOME/.claude.json"
  assert_fails claude_dir_trusted /x
  claude_trust_dir /x
  claude_dir_trusted /x
  python3 -c 'import json,os; d=json.load(open(os.path.expanduser("~/.claude.json"))); assert d["keep"] and d["projects"]["/x"]["other"]==1'
  assert_eq "$(stat -c %a "$HOME/.claude.json")" 600
}

test_hosts_render() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local f="$HOME/hosts" out
  printf '%s\n' '# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:' \
    '# [network]' '# generateHosts = false' '127.0.0.1	localhost' '127.0.1.1	OLD.localdomain	OLD' '' '::1     ip6-localhost' > "$f"
  out=$(hosts_render "$f" laptop)
  assert_eq "$out" "$(printf '127.0.0.1\tlocalhost\n127.0.1.1\tlaptop.localdomain\tlaptop\n\n::1     ip6-localhost')"
  # Idempotent, and adds the line after localhost when missing.
  printf '%s\n' "$out" > "$f"; assert_eq "$(hosts_render "$f" laptop)" "$out"
  printf '127.0.0.1\tlocalhost\n::1 x\n' > "$f"
  assert_eq "$(hosts_render "$f" box)" "$(printf '127.0.0.1\tlocalhost\n127.0.1.1\tbox.localdomain\tbox\n::1 x')"
}

test_ini_render() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local f="$HOME/wsl.conf" out
  printf '[boot]\nsystemd=true\n\n[user]\ndefault=me\n' > "$f"
  out=$(ini_render "$f" network hostname=laptop generateHosts=false)
  assert_eq "$out" "$(printf '[boot]\nsystemd=true\n\n[user]\ndefault=me\n\n[network]\nhostname = laptop\ngenerateHosts = false')"
  printf '%s\n' "$out" > "$f"
  assert_eq "$(ini_render "$f" network hostname=laptop generateHosts=false)" "$out" "idempotent"
  # Existing section: keys replaced in place, missing ones added to it, other sections kept.
  printf '[network]\nhostname=old\n\n[boot]\nsystemd=true\n' > "$f"
  assert_eq "$(ini_render "$f" network hostname=new generateHosts=false)" \
    "$(printf '[network]\nhostname = new\ngenerateHosts = false\n\n[boot]\nsystemd=true')"
}

test_claude_auto_mode() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local tpl="$REPO/templates/claude/auto-mode.json" s="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  # Fake `claude auto-mode defaults`: one built-in rule per "$builtin:" label, plus one not kept.
  export AI_SANDBOX_AUTO_MODE_DEFAULTS="$T/auto-mode-defaults.json"
  python3 - "$tpl" "$AI_SANDBOX_AUTO_MODE_DEFAULTS" <<'PY'
import json, sys
tpl = json.load(open(sys.argv[1]))
labels = [e[9:] for e in tpl['autoMode_replace']['soft_deny'] if e.startswith('$builtin:')]
rules = [f'{l} [named+specifics]: built-in text for {l}.' for l in labels] + ['Git Destructive: not kept.']
json.dump({'soft_deny': rules, 'hard_deny': ['Data Exfiltration: x'], 'allow': [], 'environment': []}, open(sys.argv[2], 'w'))
PY
  echo '{"theme":"auto","permissions":{"allow":["Read"]},"autoMode":{"allow":["Mine: keep"],"soft_deny":["$defaults","Mine: block"],"hard_deny":["Old placeholder (ai-sandbox): stale"]}}' > "$s"
  assert_fails claude_auto_mode "$tpl" check-applied
  assert_fails claude_auto_mode "$tpl" check-removed   # the stale tagged entry needs removing too
  claude_auto_mode "$tpl" apply
  claude_auto_mode "$tpl" check-applied
  python3 - "$s" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['theme'] == 'auto'
assert d['permissions']['allow'] == ['Read', 'Bash'], d
a = d['autoMode']['allow']
assert a[0] == '$defaults' and a[1] == 'Mine: keep' and any('User Pre-Approval (ai-sandbox)' in e for e in a), a
assert d['autoMode']['environment'][0] == '$defaults'
sd = d['autoMode']['soft_deny']
assert '$defaults' not in sd and sd[0] == 'Mine: block' and len(sd) == 6, sd
assert all(e.startswith(l) and 'built-in text for' in e and e.endswith('(ai-sandbox): built-in rule kept by ai-sandbox.')
           for e, l in zip(sd[1:], ['Credential Materialization', 'Credential Exploration'])), sd
assert not any('Git Destructive' in e or '$builtin' in e for e in sd), sd
assert 'hard_deny' not in d['autoMode'], d   # stale placeholder gone: built-in hard block applies
PY
  local before; before=$(cat "$s"); claude_auto_mode "$tpl" apply
  assert_eq "$(cat "$s")" "$before" "apply is idempotent"
  claude_auto_mode "$tpl" remove
  claude_auto_mode "$tpl" check-removed
  python3 - "$s" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {'theme': 'auto', 'permissions': {'allow': ['Read']}, 'autoMode': {'allow': ['$defaults', 'Mine: keep'], 'soft_deny': ['$defaults', 'Mine: block']}}, d
PY
  # A kept label missing from the CLI's built-ins: check reports work, apply fails, file untouched.
  echo '{"soft_deny": ["Credential Exploration: only this one"]}' > "$AI_SANDBOX_AUTO_MODE_DEFAULTS"
  before=$(cat "$s")
  assert_fails claude_auto_mode "$tpl" check-applied
  assert_fails claude_auto_mode "$tpl" apply 2>/dev/null
  assert_eq "$(cat "$s")" "$before" "failed apply leaves settings alone"
  unset AI_SANDBOX_AUTO_MODE_DEFAULTS
}

test_setup_root_sudoers() {
  export AI_SANDBOX_SUDOERS_DIR="$T/sudoers.d"; mkdir -p "$AI_SANDBOX_SUDOERS_DIR"
  local me; me=$(id -un)
  assert_fails "$REPO/setup-root.sh" --check "$me"
  assert_fails "$REPO/setup-root.sh" root
  assert_fails "$REPO/setup-root.sh" 'bad name'
  assert_fails "$REPO/setup-root.sh" no-such-user-xyz
  if ! command -v visudo >/dev/null; then echo "(visudo not installed; skipping apply)"; return 0; fi
  echo "$me ALL=(ALL) NOPASSWD:ALL" > "$AI_SANDBOX_SUDOERS_DIR/$me"   # a hand-made one gets adopted
  "$REPO/setup-root.sh" "$me" >/dev/null
  "$REPO/setup-root.sh" --check "$me" >/dev/null
  assert_eq "$(stat -c %a "$AI_SANDBOX_SUDOERS_DIR/$me")" 440
  assert_contains "$(cat "$AI_SANDBOX_SUDOERS_DIR/$me")" "$me ALL=(ALL) NOPASSWD:ALL"
  [ -f "$AI_SANDBOX_SUDOERS_DIR/$me.bak-ai-sandbox" ]
}

test_rendered_units() {
  ai-sandbox-init-config AI_SANDBOX_REFRESH_INTERVAL=7min >/dev/null
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  local t; t=$(render "$REPO/templates/systemd/rc-refresh.timer")
  assert_contains "$t" "OnUnitActiveSec=7min"
  if grep -q @ <<<"$t"; then echo "unrendered placeholder"; return 1; fi
  assert_contains "$(render "$REPO/templates/claude/CLAUDE.md")" "live under $HOME/src."
  if command -v systemd-analyze >/dev/null; then
    local d; d=$(mktemp -d)
    for u in rc@.service rc-refresh.service; do cp "$REPO/templates/systemd/$u" "$d/"; done
    render "$REPO/templates/systemd/rc-refresh.timer" > "$d/rc-refresh.timer"
    cp "$d/rc@.service" "$d/rc@test.service"
    (cd "$d" && systemd-analyze --user verify rc@test.service rc-refresh.service rc-refresh.timer 2>&1 |
      grep -v 'ai-sandbox-rc\|rc-refresh is not executable\|Command .* is not executable' || true) | tee "$d/out"
    [ ! -s "$d/out" ] || return 1
  fi
}

test_setup_install_step() {
  # The install step copies commands and lib into a fake HOME and is idempotent.
  export AI_SANDBOX_REPO_DIR=$REPO
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  # shellcheck source=../lib/steps/30-install.sh
  ( source "$REPO/lib/steps/30-install.sh"; ! check >/dev/null 2>&1; apply; check )
  [ -x "$HOME/.local/bin/rc-start" ]
  [ -f "$HOME/.local/share/ai-sandbox/lib/common.sh" ]
  [ -f "$HOME/.local/share/ai-sandbox/config/ai-sandbox.conf.example" ]
  # Installed commands find the installed lib.
  (unset AI_SANDBOX_LIB; export PATH="$HOME/.local/bin:$ORIG_PATH"; ai-sandbox-init-config >/dev/null)
  # A command dropped from the repo is removed on the next install.
  echo stale >> "$HOME/.local/share/ai-sandbox/installed-bin.txt"; touch "$HOME/.local/bin/stale"
  ( source "$REPO/lib/steps/30-install.sh"; apply )
  [ ! -e "$HOME/.local/bin/stale" ]
}

test_setup_requires_config() {
  local out; out=$("$REPO/setup.sh" --check 2>&1) && { echo "should fail without config"; return 1; }
  assert_contains "$out" "ai-sandbox-init-config"
}

test_cloud_setup_merges_lean_tools() {
  # cloud/setup.sh adds the lean deny rules to existing settings, keeps the rest, and is idempotent.
  mkdir -p "$HOME/.claude"
  echo '{"model": "opus", "permissions": {"deny": ["Artifact", "Bash(rm *)"], "allow": ["Read"]}, "skillOverrides": {"mine": "name-only"}, "deniedMcpServers": [{"serverName": "mine"}]}' > "$HOME/.claude/settings.json"
  export AI_SANDBOX_LEAN_TOOLS=$REPO/templates/claude/lean-tools.json AI_SANDBOX_CLOUD_HOMES=$HOME
  bash < "$REPO/cloud/setup.sh" >/dev/null
  bash < "$REPO/cloud/setup.sh" >/dev/null
  python3 - "$HOME/.claude/settings.json" "$AI_SANDBOX_LEAN_TOOLS" <<'PY2'
import json, sys
d, lean = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
deny = d['permissions']['deny']
assert d['model'] == 'opus' and d['permissions']['allow'] == ['Read'], d
assert d['enableArtifact'] is False, d
assert 'Bash(rm *)' in deny and 'mcp__claude-code-remote__*' in deny, deny
assert len(deny) == len(set(deny)), deny
assert set(lean['permissions']['deny']) <= set(deny), deny
assert d['skillOverrides'] == {'mine': 'name-only', **lean['skillOverrides']}, d
assert d['deniedMcpServers'] == [{'serverName': 'mine'}] + lean['deniedMcpServers'], d
PY2
}

test_cloud_setup_new_home() {
  # A home without ~/.claude gets a settings file with just the lean settings.
  AI_SANDBOX_LEAN_TOOLS=$REPO/templates/claude/lean-tools.json AI_SANDBOX_CLOUD_HOMES=$HOME "$REPO/cloud/setup.sh" >/dev/null
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); assert a==b, (a,b)' \
    "$HOME/.claude/settings.json" "$REPO/templates/claude/lean-tools.json"
}

test_cloud_setup_never_fails() {
  # A failing setup script stops the cloud session from starting, so cloud/setup.sh exits 0
  # when the download fails and when its run takes longer than AI_SANDBOX_CLOUD_TIMEOUT.
  local d; d=$(mktemp -d)
  printf '#!/bin/sh\nexit 22\n' > "$d/curl"; chmod +x "$d/curl"
  # Run the way an environment does: piped into bash.
  local out; out=$(PATH="$d:$PATH" AI_SANDBOX_CLOUD_HOMES=$HOME bash < "$REPO/cloud/setup.sh" 2>&1)
  assert_contains "$out" "failed (22); continuing"
  printf '#!/bin/sh\nsleep 10\n' > "$d/curl"
  local t0=$SECONDS
  out=$(PATH="$d:$PATH" AI_SANDBOX_CLOUD_HOMES=$HOME AI_SANDBOX_CLOUD_TIMEOUT=1 bash < "$REPO/cloud/setup.sh" 2>&1)
  assert_contains "$out" "timed out after 1s; continuing"
  [ $((SECONDS - t0)) -lt 5 ] || { echo "timeout did not stop the run"; return 1; }
  # After a successful run, the watchdog's sleep is gone too.
  AI_SANDBOX_LEAN_TOOLS=$REPO/templates/claude/lean-tools.json AI_SANDBOX_CLOUD_HOMES=$HOME \
    AI_SANDBOX_CLOUD_TIMEOUT=7171 bash < "$REPO/cloud/setup.sh" >/dev/null
  sleep 0.5
  if pgrep -f '^sleep 7171$' >/dev/null; then pkill -f '^sleep 7171$'; echo "watchdog sleep left running"; return 1; fi
}

test_claude_lean_tools() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local tpl="$REPO/templates/claude/lean-tools.json" s="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  echo '{"theme":"auto","permissions":{"allow":["Read"],"deny":["Bash(rm *)"]},"skillOverrides":{"mine":"name-only"},"deniedMcpServers":[{"serverName":"mine"}]}' > "$s"
  assert_fails claude_lean_tools "$tpl" check-applied
  claude_lean_tools "$tpl" check-removed
  claude_lean_tools "$tpl" apply
  claude_lean_tools "$tpl" check-applied
  python3 - "$s" "$tpl" <<'PY2'
import json, sys
d, t = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert d['theme'] == 'auto' and d['permissions']['allow'] == ['Read'], d
assert d['enableArtifact'] is False, d
assert d['permissions']['deny'] == ['Bash(rm *)'] + t['permissions']['deny'], d
assert d['skillOverrides'] == {'mine': 'name-only', **t['skillOverrides']}, d
assert d['deniedMcpServers'] == [{'serverName': 'mine'}] + t['deniedMcpServers'], d
PY2
  local before; before=$(cat "$s"); claude_lean_tools "$tpl" apply
  assert_eq "$(cat "$s")" "$before" "apply is idempotent"
  claude_lean_tools "$tpl" remove
  claude_lean_tools "$tpl" check-removed
  python3 - "$s" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {'theme': 'auto', 'permissions': {'allow': ['Read'], 'deny': ['Bash(rm *)']}, 'skillOverrides': {'mine': 'name-only'}, 'deniedMcpServers': [{'serverName': 'mine'}]}, d
PY2
}

test_config_lean_tools() {
  ai-sandbox-init-config >/dev/null
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  assert_eq "$AI_SANDBOX_LEAN_TOOLS" on
  ai-sandbox-init-config --force AI_SANDBOX_LEAN_TOOLS=off >/dev/null
  (config_load; assert_eq "$AI_SANDBOX_LEAN_TOOLS" off)
  assert_fails ai-sandbox-init-config --force AI_SANDBOX_LEAN_TOOLS=maybe
}

# ------------------------------------------------------------------ modules

FIX="$REPO/tests/fixtures"
use_fixture_modules() {
  export AI_SANDBOX_VERSIONS="$FIX/versions.toml" AI_SANDBOX_MODULES_DIR="$FIX/modules"
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  # shellcheck source=../lib/modules.sh
  source "$AI_SANDBOX_LIB/modules.sh"
}
toml() { local f="$T/v.toml"; cat > "$f"; echo "$f"; }

test_versions_repo_file_valid() {
  python3 "$REPO/lib/versions.py" "$REPO/versions.toml" validate
  python3 "$REPO/lib/versions.py" "$FIX/versions.toml" validate
}

test_versions_validate_rejects() {
  local v out
  v=$(toml <<'X'
[modules.m]
[tools.a]
module = "nope"
version = "1.2"
source = "github:o/r"
[tools.b]
module = "base"
version = "==1.0"
source = "system"
[tools.c]
module = "base"
version = ">=1.0"
source = "npm:c"
extra = 1
X
)
  out=$(python3 "$REPO/lib/versions.py" "$v" validate) && { echo "should be invalid"; return 1; }
  assert_contains "$out" "[modules.m]: description is required"
  assert_contains "$out" '[tools.a]: module must be "base"'
  assert_contains "$out" "[tools.a]: not a version constraint: '1.2'"
  assert_contains "$out" "[tools.a]: asset (release asset name) is required"
  assert_contains "$out" '[tools.b]: a system tool gets a minimum (">=X"), not "=="'
  assert_contains "$out" '[tools.c]: a npm tool is pinned exactly (version = "==X")'
  assert_contains "$out" "[tools.c]: unknown key 'extra'"
  assert_contains "$out" "[tools.c]: npm tools need a [tools.node] entry"
  # A tool defined twice is a TOML error.
  v=$(printf '[tools.a]\nmodule="base"\n[tools.a]\nmodule="base"\n' | toml)
  assert_fails python3 "$REPO/lib/versions.py" "$v" validate
}

test_versions_check_results() {
  use_fixture_modules
  export AI_SANDBOX_PLATFORM=linux-amd64
  mkdir -p "$T/fakebin"; export PATH="$T/fakebin:$PATH"
  printf '#!/bin/sh\necho "fakesys version $FAKESYS_VERSION"\n' > "$T/fakebin/fakesys"; chmod +x "$T/fakebin/fakesys"
  local out
  export FAKESYS_VERSION=1.7.0
  out=$(versions_py check alpha) && { echo "fakedl missing: should fail"; return 1; }
  assert_contains "$out" "missing fakedl (pin 1.2.3): follow modules/alpha/README.md#installing"
  assert_contains "$out" "ok fakesys 1.7.0"
  for v in 1.2.2 1.2.3 1.3.0; do mkdir -p "$AI_SANDBOX_SHARE/opt/fakedl/$v"; touch "$AI_SANDBOX_SHARE/opt/fakedl/$v/fakedl"; done
  mkdir -p "$AI_SANDBOX_BIN"
  ln -sfn "$AI_SANDBOX_SHARE/opt/fakedl/1.2.3/fakedl" "$AI_SANDBOX_BIN/fakedl"
  versions_py check alpha
  ln -sfn "$AI_SANDBOX_SHARE/opt/fakedl/1.2.2/fakedl" "$AI_SANDBOX_BIN/fakedl"
  assert_contains "$(versions_py check alpha)" "upgrade fakedl 1.2.2 -> 1.2.3: follow modules/alpha/README.md#upgrading"
  ln -sfn "$AI_SANDBOX_SHARE/opt/fakedl/1.3.0/fakedl" "$AI_SANDBOX_BIN/fakedl"
  assert_contains "$(versions_py check alpha)" "newer-than-pin fakedl 1.3.0 > 1.2.3"
  rm "$AI_SANDBOX_BIN/fakedl"; touch "$AI_SANDBOX_BIN/fakedl"
  assert_contains "$(versions_py check alpha)" "unmanaged fakedl"
  assert_contains "$(AI_SANDBOX_PLATFORM=linux-arm64 versions_py check alpha)" "no-checksum fakedl linux-arm64"
  assert_contains "$(FAKESYS_VERSION=1.5 versions_py check alpha)" "too-old fakesys 1.5 (needs >=1.6,<2)"
  assert_contains "$(FAKESYS_VERSION=2.1 versions_py check alpha)" "unsupported fakesys 2.1 (needs >=1.6,<2)"
  rm "$T/fakebin/fakesys"
  assert_contains "$(versions_py check alpha)" "missing fakesys (needs >=1.6,<2)"
}

test_modules_preflight() {
  use_fixture_modules
  local out
  AI_SANDBOX_MODULES="alpha nope"
  out=$( (modules_preflight) 2>&1) && { echo "unknown module should fail"; return 1; }
  assert_contains "$out" "unknown module 'nope' in AI_SANDBOX_MODULES; known modules: alpha beta"
  AI_SANDBOX_MODULES="beta"
  out=$( (modules_preflight) 2>&1) && { echo "missing requires should fail"; return 1; }
  assert_contains "$out" "module 'beta' requires module 'alpha'"
  AI_SANDBOX_MODULES="beta alpha beta"
  modules_preflight
  assert_eq "$(modules_listed | xargs)" "beta alpha"
  cp -r "$FIX/modules" "$T/mods"; mkdir "$T/mods/gamma"; AI_SANDBOX_MODULES_DIR="$T/mods" AI_SANDBOX_MODULES=gamma
  out=$( (modules_preflight) 2>&1) && { echo "module without toml entry should fail"; return 1; }
  assert_contains "$out" "no [modules.gamma] in versions.toml"
}

test_module_files_install() {
  use_fixture_modules
  ai-sandbox-init-config >/dev/null; config_load
  export AI_SANDBOX_MODULES=alpha
  ! ( source "$REPO/lib/steps/35-modules.sh"; check ) 2>/dev/null
  ( source "$REPO/lib/steps/35-modules.sh"; apply; check )
  [ -x "$AI_SANDBOX_BIN/ai-sandbox-alpha-status" ]
  [ -f "$HOME/.claude/skills/alpha-skill/SKILL.md" ]
  assert_contains "$(cat "$AI_SANDBOX_UNIT_DIR/alpha.service")" "ExecStart=$AI_SANDBOX_BIN/ai-sandbox-alpha-status"
  [ -f "$AI_SANDBOX_SHARE/modules/alpha/claude.md" ] && [ -f "$AI_SANDBOX_SHARE/modules/alpha/README.md" ]
  assert_eq "$(modules_installed)" alpha
  assert_contains "$(modules_claude_md)" "Data lives in $AI_SANDBOX_SHARE/data/alpha."
  # De-listed: nothing is removed, and it stays installed (so its lines and status remain).
  AI_SANDBOX_MODULES=""
  ( source "$REPO/lib/steps/35-modules.sh"; apply; check )
  [ -x "$AI_SANDBOX_BIN/ai-sandbox-alpha-status" ] && [ -f "$HOME/.claude/skills/alpha-skill/SKILL.md" ]
  assert_eq "$(modules_installed)" alpha
  assert_eq "$(modules_settings_fragments)" "$AI_SANDBOX_SHARE/modules/alpha/settings.json"
}

test_status_command() {
  use_fixture_modules
  ai-sandbox-init-config AI_SANDBOX_MODULES=alpha >/dev/null; config_load
  # No modules installed: nothing to say.
  assert_eq "$(ai-sandbox-status --brief)" ""
  ( source "$REPO/lib/steps/35-modules.sh"; apply )
  export PATH="$AI_SANDBOX_BIN:$PATH"
  assert_eq "$(ai-sandbox-status --brief)" ""
  assert_contains "$(ai-sandbox-status)" "alpha: ok, running"
  local out
  out=$(ALPHA_STATUS_RC=2 ALPHA_STATUS_LINE="STOPPED ON PURPOSE by sync" ai-sandbox-status --brief)
  assert_contains "$out" "ai-sandbox: alpha: STOPPED ON PURPOSE: STOPPED ON PURPOSE by sync"
  assert_contains "$out" "run ai-sandbox-status for details"
  out=$(ALPHA_STATUS_RC=1 ALPHA_STATUS_LINE="failed" ai-sandbox-status) && { echo "should exit non-zero"; return 1; }
  assert_contains "$out" "alpha: UNHEALTHY: failed"
  assert_contains "$out" "see Troubleshooting in $AI_SANDBOX_SHARE/modules/alpha/README.md"
  ai-sandbox-init-config --force >/dev/null
  assert_contains "$(ai-sandbox-status)" "alpha: ok, running (installed, not listed)"
}

test_claude_settings_merge() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  mkdir -p "$HOME/.claude"
  printf '{"permissions": {"deny": ["Bash(mine)"]}, "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "mine"}]}]}}\n' \
    > "$HOME/.claude/settings.json"
  local f="$REPO/templates/claude/session-start.json" a="$FIX/modules/alpha/settings.json"
  assert_fails claude_settings_merge "$f" check
  claude_settings_merge "$f" apply; claude_settings_merge "$a" apply
  claude_settings_merge "$f" check; claude_settings_merge "$a" check
  claude_settings_merge "$f" apply   # idempotent
  python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['permissions']['deny'] == ['Bash(mine)', 'Bash(alpha start:*)'], d
cmds = [h['command'] for g in d['hooks']['SessionStart'] for h in g['hooks']]
assert cmds[0] == 'mine' and len(cmds) == 2 and 'ai-sandbox-status --brief' in cmds[1], cmds
PY
}

test_lean_tools_and_module_denies_coexist() {
  # Both write permissions.deny; applying one must not make the other's check fail.
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local lean="$REPO/templates/claude/lean-tools.json" mod="$REPO/modules/beads/settings.json"
  claude_lean_tools "$lean" apply; claude_settings_merge "$mod" apply
  claude_lean_tools "$lean" check-applied; claude_settings_merge "$mod" check
  claude_lean_tools "$lean" apply
  claude_lean_tools "$lean" check-applied; claude_settings_merge "$mod" check
  claude_lean_tools "$lean" remove; claude_lean_tools "$lean" check-removed; claude_settings_merge "$mod" check
}

test_cred_source() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  ai-sandbox-init-config >/dev/null; config_load; secrets_init
  assert_fails cred_source TEST_CRED testcred
  printf 'from-file' | secret_set testcred
  assert_eq "$(cred_source TEST_CRED testcred)" "secret file $HOME/.secrets/testcred"
  assert_eq "$(cred_get TEST_CRED testcred)" from-file
  export TEST_CRED=from-file
  assert_eq "$(cred_source TEST_CRED testcred)" "env TEST_CRED"
  rm "$HOME/.secrets/testcred"; TEST_CRED=from-env
  assert_eq "$(cred_get TEST_CRED testcred)" from-env
  printf 'other' | secret_set testcred
  local out; out=$( (cred_get TEST_CRED testcred) 2>&1) && { echo "differing values should fail"; return 1; }
  assert_contains "$out" "credential testcred differs between \$TEST_CRED and file $HOME/.secrets/testcred"
  ! grep -q 'from-env\|other' <<<"$out" || { echo "a value was printed"; return 1; }
}

test_setup_stops_on_unknown_module() {
  local base; base=$(dirname "$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")")
  ai-sandbox-init-config "AI_SANDBOX_GIT_BASEDIR=$base" AI_SANDBOX_MODULES=nope >/dev/null
  local out; out=$("$REPO/setup.sh" --check 2>&1) && { echo "should fail"; return 1; }
  assert_contains "$out" "unknown module 'nope' in AI_SANDBOX_MODULES"
  ! grep -q '^ok \|^PENDING' <<<"$out" || { echo "ran steps before stopping"; return 1; }
}

# ------------------------------------------------------------------ beads module

BEADS_MOD="$REPO/modules/beads"

test_beads_sync_logic() {
  python3 - "$BEADS_MOD/lib" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import beads_sync as b
assert b.classify('dial tcp 127.0.1.1:3307: connect: connection refused') == 'soft'
assert b.classify('rpc error: code = Unavailable desc = 503 Service Unavailable') == 'soft'
assert b.classify('Error 1105: ! [rejected] main -> main (non-fast-forward)') == 'soft'
assert b.classify('permission denied: unauthenticated') == 'hard'
assert b.classify('repository not found') == 'hard'
assert b.classify('something nobody expected') == 'hard'
s, stop = {}, False
for i in range(14):                      # 14 runs, a minute apart: not yet
    s, stop = b.next_failure_state(s, 1000 + 60 * i, window=900, runs=15, gap=180)
    assert not stop, i
s, stop = b.next_failure_state(s, 1000 + 60 * 15, window=900, runs=15, gap=180)
assert stop and s['failures'] == 15
# One failure before sleep, one after waking 8 h later: the count starts again.
s, _ = b.next_failure_state({}, 0, window=900, runs=15, gap=180)
s, stop = b.next_failure_state(s, 8 * 3600, window=900, runs=15, gap=180)
assert not stop and s['failures'] == 1 and s['first_failure'] == 8 * 3600
s = b.success_state(s, 9 * 3600)
assert s['failures'] == 0 and 'first_failure' not in s and s['last_success'] == 9 * 3600
PY
}

test_beads_commands_respect_halt() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  mkdir -p "$AI_SANDBOX_STATE"
  printf 'time: 2026-11-27 14:02:00\nby: beads sync\nclass: hard\nreason: ai-sandbox: diverged from DoltHub (ahead 1, behind 2)\ndatabases: ai-sandbox\nnext: see Troubleshooting\n' \
    > "$AI_SANDBOX_STATE/beads-sync-HALTED"
  local out rc
  rc=0; out=$("$BEADS_MOD/bin/ai-sandbox-beads-status") || rc=$?
  assert_eq "$rc" 2
  assert_contains "$out" "last successful sync: never"
  printf '{"last_success": 1795842590}' > "$AI_SANDBOX_STATE/beads-sync.state"
  assert_contains "$("$BEADS_MOD/bin/ai-sandbox-beads-status")" "last successful sync: $(date -d @1795842590 '+%F %T')"$'\n'
  assert_eq "$(head -n1 <<<"$out")" "STOPPED ON PURPOSE by beads sync at 2026-11-27 14:02:00: ai-sandbox: diverged from DoltHub (ahead 1, behind 2) (class=hard)"
  rc=0; out=$("$BEADS_MOD/bin/ai-sandbox-beads-server" start 2>&1) || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "Don't restart it until the owner says so"
  rc=0; out=$("$BEADS_MOD/bin/ai-sandbox-beads-server" run 2>&1) || rc=$?
  assert_eq "$rc" 3
  rc=0; out=$("$BEADS_MOD/bin/ai-sandbox-beads-server" start --upgrade 2>&1) || rc=$?
  assert_eq "$rc" 3
  rc=0; out=$(BEADS_DOLT=/bin/false "$BEADS_MOD/bin/ai-sandbox-beads-sync") || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "stopped on purpose; not syncing"
  # An upgrade stop allows start --upgrade's run (the flag file), nothing else.
  printf 'time: x\nby: me\nclass: upgrade\nreason: upgrade dolt 1 -> 2\n' > "$AI_SANDBOX_STATE/beads-sync-HALTED"
  assert_contains "$("$BEADS_MOD/bin/ai-sandbox-beads-status")" "STOPPED ON PURPOSE for an upgrade at x (me): upgrade dolt 1 -> 2"
}

test_beads_init_rejects_names() {
  local n out
  for n in Bad-Name -x x- testdb_one beads_test2 doctortest_a; do
    out=$("$BEADS_MOD/bin/ai-sandbox-beads-init" "$n" p 2>&1) && { echo "accepted $n"; return 1; }
    assert_contains "$out" "database name '$n'"
  done
}

test_beads_module_installs() {
  # The real module's files go where the framework puts them, and its lines and rules apply.
  ai-sandbox-init-config AI_SANDBOX_MODULES=beads >/dev/null
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"; config_load
  # shellcheck source=../lib/modules.sh
  source "$AI_SANDBOX_LIB/modules.sh"
  export AI_SANDBOX_MODULES_DIR="$REPO/modules" AI_SANDBOX_VERSIONS="$REPO/versions.toml"
  modules_preflight
  ( source "$REPO/lib/steps/35-modules.sh"; apply; check )
  for c in server sync status init; do [ -x "$AI_SANDBOX_BIN/ai-sandbox-beads-$c" ]; done
  [ -f "$HOME/.claude/skills/beads-onboarding/SKILL.md" ]
  assert_contains "$(cat "$AI_SANDBOX_UNIT_DIR/beads-dolt.service")" "ExecStart=$AI_SANDBOX_BIN/ai-sandbox-beads-server run"
  assert_contains "$(modules_claude_md)" "**Beads (\`bd\`) on this host.**"
  claude_settings_merge "$AI_SANDBOX_SHARE/modules/beads/settings.json" apply
  assert_contains "$(cat "$HOME/.claude/settings.json")" '"Bash(bd dolt start:*)"'
  if command -v systemd-analyze >/dev/null; then
    (cd "$AI_SANDBOX_UNIT_DIR" && systemd-analyze --user verify beads-dolt.service beads-dolt-sync.service \
      beads-dolt-sync.timer beads-dolt-halt.service 2>&1 | grep -v 'is not executable\|ai-sandbox-beads' || true) | tee "$T/verify"
    [ ! -s "$T/verify" ]
  fi
}

test_beads_bd_config() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  export AI_SANDBOX_MODULE_DIR=$BEADS_MOD
  local cfg="$XDG_CONFIG_HOME/bd/config.yaml"
  mkdir -p "$XDG_CONFIG_HOME/bd" "$T/fakebin"
  printf '#!/bin/sh\n[ "$3" = --get ] && git config --global "$4"; exit 0\n' > "$T/fakebin/dolt"; chmod +x "$T/fakebin/dolt"
  export BEADS_DOLT="$T/fakebin/dolt"
  git config --global user.name t; git config --global user.email t@x
  # bd's own file: metrics on, 4-space indent, no newline at the end.
  printf 'metrics:\n    disabled: false\n    endpoint: https://example.invalid/collect' > "$cfg"
  ( source "$BEADS_MOD/steps/10-config.sh"; ! check >/dev/null 2>&1; apply; check )
  python3 - "$cfg" <<'PY'
import sys
t = open(sys.argv[1]).read()
assert 'metrics:\n    disabled: true\n    endpoint: http://127.0.0.1:9/ai-sandbox-metrics-disabled\n' in t, t
assert 'dolt:\n  auto-start: false\n  host: 127.0.1.1\n  port: 3307\n' in t, t
PY
  cp "$cfg" "$T/before"; ( source "$BEADS_MOD/steps/10-config.sh"; apply ); cmp "$cfg" "$T/before"   # idempotent
  # An existing dolt: section gets the key added under it, with its indentation.
  printf 'dolt:\n    other: 1\n' > "$cfg"
  ( source "$BEADS_MOD/steps/10-config.sh"; apply; check )
  assert_contains "$(cat "$cfg")" $'dolt:\n    other: 1\n    auto-start: false\n    host: 127.0.1.1\n    port: 3307'
  # No file at all.
  rm "$cfg"; ( source "$BEADS_MOD/steps/10-config.sh"; apply; check )
  assert_eq "$(stat -c %a "$cfg")" 600
}

# Needs a dolt binary (BEADS_TEST_DOLT=/path/to/dolt, or dolt on PATH); skipped otherwise. Runs a
# throwaway dolt sql-server on 127.0.1.1:3398 with file:// remotes: no network, no systemd.
test_beads_sync_end_to_end() {
  local dolt=${BEADS_TEST_DOLT:-$(command -v dolt || true)}
  [ -n "$dolt" ] || { echo "(no dolt binary; skipped)"; return 0; }
  export BEADS_DOLT=$dolt BEADS_PORT=3398 BEADS_DATA="$T/data" DOLT_ROOT_PATH="$T/doltroot" DOLT_DISABLE_VERSION_CHECKS=1
  export AI_SANDBOX_BIN="$T/fakebin" AI_SANDBOX_STATE="$T/state"
  mkdir -p "$BEADS_DATA" "$T/remote" "$AI_SANDBOX_BIN" "$AI_SANDBOX_STATE"
  # The halt goes to a fake server command: never the real systemd.
  printf '#!/bin/sh\necho "$@" >> "%s/halts"\nprintf "class: %%s\\nreason: %%s\\n" "$2" "$3" > "%s/beads-sync-HALTED"\n' "$T" "$AI_SANDBOX_STATE" \
    > "$AI_SANDBOX_BIN/ai-sandbox-beads-server"
  chmod +x "$AI_SANDBOX_BIN/ai-sandbox-beads-server"
  "$dolt" config --global --add user.name t >/dev/null; "$dolt" config --global --add user.email t@x >/dev/null
  "$dolt" sql-server -H 127.0.1.1 -P 3398 --data-dir "$BEADS_DATA" -l warning > "$T/server.log" 2>&1 &
  BEADS_TEST_PID=$!
  trap 'kill $BEADS_TEST_PID 2>/dev/null || true; wait $BEADS_TEST_PID 2>/dev/null || true; rm -rf "$T"' EXIT
  for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.1.1/3398) 2>/dev/null && break; sleep 0.5; done
  q() { "$dolt" --host 127.0.1.1 --port 3398 --no-tls -u root -p "" ${2:+--use-db "$2"} sql -r csv -q "$1" >/dev/null; }
  local sync="$BEADS_MOD/bin/ai-sandbox-beads-sync" log="$AI_SANDBOX_STATE/beads-sync.log"
  q 'CREATE DATABASE `my-db`'
  q "CREATE TABLE t (id int primary key); INSERT INTO t VALUES (1)" my-db
  q "CALL DOLT_REMOTE('add', 'dolthub', 'file://$T/remote/my-db')" my-db
  q "CALL DOLT_COMMIT('-A', '-m', 'init'); CALL DOLT_PUSH('dolthub', 'main')" my-db   # what ai-sandbox-beads-init does
  q "INSERT INTO t VALUES (10)" my-db
  "$sync"; assert_contains "$(tail -n1 "$log")" "my-db ok behind=0 ahead=1"
  "$sync"; assert_contains "$(tail -n1 "$log")" "my-db ok behind=0 ahead=0"
  # A commit on the other side is pulled (fast-forward).
  q "CALL DOLT_CLONE('--remote', 'dolthub', 'file://$T/remote/my-db', 'other')"
  q "INSERT INTO t VALUES (2); CALL DOLT_COMMIT('-A', '-m', 'elsewhere'); CALL DOLT_PUSH('dolthub', 'main')" other
  q "INSERT INTO t VALUES (3)" my-db     # an uncommitted local write rides along
  "$sync" || true; assert_contains "$(grep ' my-db ' "$log" | tail -n1)" "my-db error hard diverged"
  assert_contains "$(cat "$T/halts")" "hard my-db: diverged from DoltHub (ahead 1, behind 1) my-db"
  local rc=0; "$sync" || rc=$?; assert_eq "$rc" 3   # halted: does nothing
  # A database without a dolthub remote halts at once.
  rm -f "$AI_SANDBOX_STATE/beads-sync-HALTED" "$T/halts"
  q "CALL DOLT_REMOTE('remove', 'dolthub')" my-db
  q "CALL DOLT_REMOTE('remove', 'dolthub')" other
  q 'DROP DATABASE `other`'
  "$sync" || true; assert_contains "$(cat "$T/halts")" "no dolthub remote"
  # Server unreachable: soft, no halt until the window and the run count are both reached.
  rm -f "$AI_SANDBOX_STATE/beads-sync-HALTED" "$T/halts"
  kill $BEADS_TEST_PID; wait $BEADS_TEST_PID 2>/dev/null || true
  BEADS_SOFT_WINDOW=0 BEADS_SOFT_RUNS=2 "$sync"; [ ! -f "$T/halts" ]
  assert_contains "$(tail -n1 "$log")" "error soft server:"
  BEADS_SOFT_WINDOW=0 BEADS_SOFT_RUNS=2 "$sync" || true
  assert_contains "$(cat "$T/halts")" "soft no successful sync for 0 min (2 runs)"
}

# ------------------------------------------------------------------ main

tests=$(declare -F | awk '{print $3}' | grep '^test_')
for t in $tests; do run_test "$t"; done

if [ "${1:-}" = --host ]; then
  export HOME=$ORIG_HOME PATH=$ORIG_PATH; unset XDG_CONFIG_HOME AI_SANDBOX_LIB
  echo "--- host check (read-only): ./setup.sh --check"
  if "$REPO/setup.sh" --check; then pass=$((pass + 1)); else fail=$((fail + 1)); failed+=(host-check); fi
fi

echo "--- $pass passed, $fail failed${failed[*]:+: ${failed[*]}}"
[ "$fail" = 0 ]
