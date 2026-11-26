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
  for f in "$REPO"/bin/* "$REPO"/lib/*.sh "$REPO"/lib/*/*.sh "$REPO"/tests/*.sh "$REPO"/cloud/*.sh; do bash -n "$f"; done
  if command -v shellcheck >/dev/null; then
    (cd "$REPO" && shellcheck -x -S warning setup.sh setup-root.sh install.sh bin/* lib/*.sh lib/*/*.sh tests/*.sh cloud/*.sh)
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
  echo '{"theme":"auto","permissions":{"allow":["Read"]},"autoMode":{"allow":["Mine: keep"]}}' > "$s"
  assert_fails claude_auto_mode "$tpl" check-applied
  claude_auto_mode "$tpl" check-removed
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
PY
  local before; before=$(cat "$s"); claude_auto_mode "$tpl" apply
  assert_eq "$(cat "$s")" "$before" "apply is idempotent"
  claude_auto_mode "$tpl" remove
  claude_auto_mode "$tpl" check-removed
  python3 - "$s" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {'theme': 'auto', 'permissions': {'allow': ['Read']}, 'autoMode': {'allow': ['$defaults', 'Mine: keep']}}, d
PY
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
  echo '{"model": "opus", "permissions": {"deny": ["Artifact", "Bash(rm *)"], "allow": ["Read"]}}' > "$HOME/.claude/settings.json"
  export AI_SANDBOX_LEAN_TOOLS=$REPO/templates/claude/lean-tools.json AI_SANDBOX_CLOUD_HOMES=$HOME
  "$REPO/cloud/setup.sh" >/dev/null
  "$REPO/cloud/setup.sh" >/dev/null
  python3 - "$HOME/.claude/settings.json" "$AI_SANDBOX_LEAN_TOOLS" <<'PY2'
import json, sys
d, lean = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
deny = d['permissions']['deny']
assert d['model'] == 'opus' and d['permissions']['allow'] == ['Read'], d
assert d['enableArtifact'] is False, d
assert 'Bash(rm *)' in deny and 'mcp__claude-code-remote__*' in deny, deny
assert len(deny) == len(set(deny)), deny
assert set(lean['permissions']['deny']) <= set(deny), deny
PY2
}

test_cloud_setup_new_home() {
  # A home without ~/.claude gets a settings file with just the lean settings.
  AI_SANDBOX_LEAN_TOOLS=$REPO/templates/claude/lean-tools.json AI_SANDBOX_CLOUD_HOMES=$HOME "$REPO/cloud/setup.sh" >/dev/null
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); assert a==b, (a,b)' \
    "$HOME/.claude/settings.json" "$REPO/templates/claude/lean-tools.json"
}

test_cloud_bootstrap_never_fails() {
  # A failing setup script stops the cloud session from starting, so bootstrap must exit 0
  # even when the download fails.
  local d; d=$(mktemp -d)
  printf '#!/bin/sh\nexit 22\n' > "$d/curl"; chmod +x "$d/curl"
  local out; out=$(PATH="$d:$PATH" bash "$REPO/cloud/bootstrap.sh" 2>&1)
  assert_contains "$out" "download failed; continuing"
}

test_claude_lean_tools() {
  # shellcheck source=../lib/common.sh
  source "$AI_SANDBOX_LIB/common.sh"
  local tpl="$REPO/templates/claude/lean-tools.json" s="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  echo '{"theme":"auto","permissions":{"allow":["Read"],"deny":["Bash(rm *)"]}}' > "$s"
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
PY2
  local before; before=$(cat "$s"); claude_lean_tools "$tpl" apply
  assert_eq "$(cat "$s")" "$before" "apply is idempotent"
  claude_lean_tools "$tpl" remove
  claude_lean_tools "$tpl" check-removed
  python3 - "$s" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {'theme': 'auto', 'permissions': {'allow': ['Read'], 'deny': ['Bash(rm *)']}}, d
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
