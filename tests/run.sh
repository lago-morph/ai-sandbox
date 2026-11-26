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
  bash -n "$REPO/setup.sh"; bash -n "$REPO/setup-root.sh"
  for f in "$REPO"/bin/* "$REPO"/lib/*.sh "$REPO"/lib/*/*.sh "$REPO"/tests/*.sh; do bash -n "$f"; done
  if command -v shellcheck >/dev/null; then
    (cd "$REPO" && shellcheck -x -S warning setup.sh setup-root.sh bin/* lib/*.sh lib/*/*.sh tests/*.sh)
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
  : > "$HOME/.secrets/claude-oauth-token"
  ai-sandbox-secret has github
  assert_eq "$(ai-sandbox-secret get github)" tok-123
  assert_fails ai-sandbox-secret has claude-oauth-token   # empty file counts as missing
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
