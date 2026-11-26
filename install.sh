#!/usr/bin/env bash
# Usage: ./install.sh [--no-setup]
#
# Guided install for the user running it, once the Claude CLI is installed and logged in (see
# README.md). Asks for the host settings (hostname, session name prefix, permission mode, and
# optionally the advanced ones) and the GitHub token; writes the host config and stores the
# token; grants passwordless sudo (asks for your password once); runs ./setup.sh; and offers to reboot if a change needs one (on WSL, prints how to restart the distro).
# Safe to re-run: current values are the defaults, and stored secrets are kept.
#   --no-setup   only write the config and secrets: no sudo, no setup, no restart
set -euo pipefail
AI_SANDBOX_REPO_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
AI_SANDBOX_LIB="$AI_SANDBOX_REPO_DIR/lib"
export AI_SANDBOX_REPO_DIR AI_SANDBOX_LIB
# shellcheck source=lib/common.sh
source "$AI_SANDBOX_LIB/common.sh"
GITHUB_API=${AI_SANDBOX_GITHUB_API:-https://api.github.com}   # overridable for tests only

run_setup=1
case "${1:-}" in
  '') ;;
  --no-setup) run_setup=0 ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac
[ "$(id -u)" != 0 ] || die "run this as the user the sandbox is for, not as root (setup uses sudo itself)"
start_log install
trap 'log "full log: $AI_SANDBOX_LOG_FILE"' EXIT

# Remote Control needs a full claude.ai login, which only the user can do in a browser.
claude_logged_in || die "install the Claude CLI and log in first, then re-run $0:
    curl -fsSL https://claude.ai/install.sh | bash
    ~/.local/bin/claude auth login"
info "Claude CLI is installed and logged in"

# ------------------------------------------------------------------ prompts (stdin, prompts on stderr)

# ask PROMPT DEFAULT -> the answer, or DEFAULT on an empty line
ask() {
  local a
  printf '%s%s: ' "$1" "${2:+ [$2]}" >&2
  IFS= read -r a || die "input ended"
  printf '%s' "${a:-$2}"
}
# ask_yn PROMPT y|n -> exit 0 for yes
ask_yn() {
  local a hint=y/N; [ "$2" = y ] && hint=Y/n
  while :; do
    a=$(ask "$1 ($hint)" "")
    case "${a:-$2}" in [Yy]|[Yy]es) return 0 ;; [Nn]|[Nn]o) return 1 ;; esac
  done
}
# ask_secret PROMPT -> the answer, read without echo. An answer that names an existing file
# (/path, ~/path or ./path) is replaced by that file's contents.
ask_secret() {
  local a
  printf '%s: ' "$1" >&2
  IFS= read -rs a || die "input ended"
  echo >&2
  a=$(printf '%s' "$a" | tr -d '[:space:]')
  # shellcheck disable=SC2088  # a literal "~/" typed by the user
  case "$a" in
    /*|./*|'~/'*)
      # shellcheck disable=SC2088
      [ "${a:0:2}" != '~/' ] || a="$HOME/${a:2}"
      [ -f "$a" ] || die "no such file: $a"
      info "read it from $a"
      tr -d '[:space:]' < "$a" ;;
    *) printf '%s' "$a" ;;
  esac
}
section() { printf '\n== %s\n' "$*" >&2; }

# The value of KEY as written in the existing config (empty if unset or no config).
raw_config() {
  [ -f "$AI_SANDBOX_CONFIG" ] || return 0
  bash -c 'source "$1" >/dev/null 2>&1; printf %s "${!2:-}"' _ "$AI_SANDBOX_CONFIG" "$1"
}

# github_login: token on stdin -> its GitHub login on stdout; exit 1 if GitHub rejects it.
# The token goes to curl through a config file descriptor, never as an argument.
github_login() {
  local tok; tok=$(cat)
  curl -fsS --max-time 20 -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") \
    -H 'Accept: application/vnd.github+json' "$GITHUB_API/user" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])' 2>/dev/null
}

# ------------------------------------------------------------------ sudo and base packages
# First, so this script's own tools (curl, python3) are there on a minimal image. setup.sh then
# installs the rest (gh, the Claude CLI, ...).

if [ $run_setup = 1 ]; then
  section "Passwordless sudo"
  if sudo -n true 2>/dev/null; then
    info "$USER already has passwordless sudo"
  else
    info "setup and the sessions need sudo without a password; enter your password to allow it"
    sudo "$AI_SANDBOX_REPO_DIR/setup-root.sh"
  fi
  platform_load
  missing=$(platform_missing_packages)
  if [ -n "$missing" ]; then
    section "Packages"
    info "installing: $(echo $missing)"
    # shellcheck disable=SC2086
    platform_install_packages $missing
  fi
fi
for c in git curl python3; do
  command -v "$c" >/dev/null || die "$c is not installed (run without --no-setup to install it)"
done

# ------------------------------------------------------------------ host settings

common_dir=$(git -C "$AI_SANDBOX_REPO_DIR" rev-parse --path-format=absolute --git-common-dir)
self_dir=$(dirname "$common_dir")

section "Host settings"
if [ -f "$AI_SANDBOX_CONFIG" ]; then
  info "existing config $AI_SANDBOX_CONFIG: its values are the defaults below; it will be rewritten"
fi
info "Remote Control lists this machine as '<hostname> <repo>' in the claude.ai environment list."
cur_host=$(hostname -s | tr '[:upper:]' '[:lower:]')
while :; do
  cur=$(raw_config AI_SANDBOX_HOSTNAME)
  host=$(ask "Hostname" "${cur:-$cur_host}")
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
  info "use lowercase letters, digits and '-' (not at either end)"
done
while :; do
  cur=$(raw_config AI_SANDBOX_NAME_PREFIX)
  prefix=$(ask "Session name prefix (sessions are named <prefix>-<repo>)" "${cur:-$host}")
  [[ "$prefix" =~ ^[A-Za-z0-9_.-]+$ ]] && break
  info "use letters, digits, '.', '_' and '-'"
done
info "Permission mode for sessions: bypassPermissions (no prompts; also pre-approves everything"
info "for auto mode, which the Claude app uses), auto, acceptEdits, default, dontAsk or plan."
while :; do
  cur_mode=$(raw_config AI_SANDBOX_PERMISSION_MODE)
  mode=$(ask "Permission mode" "${cur_mode:-bypassPermissions}")
  case "$mode" in acceptEdits|auto|bypassPermissions|default|dontAsk|plan) break ;; esac
  info "not a permission mode: $mode"
done

basedir=$(raw_config AI_SANDBOX_GIT_BASEDIR); basedir=${basedir:-$(dirname "$self_dir")}
secrets_dir=$(raw_config AI_SANDBOX_SECRETS_DIR); secrets_dir=${secrets_dir:-$HOME/.secrets}
spawn=$(raw_config AI_SANDBOX_SPAWN_MODE); spawn=${spawn:-worktree}
refresh=$(raw_config AI_SANDBOX_REFRESH_INTERVAL); refresh=${refresh:-10min}
if ask_yn "Change advanced settings (git checkout dir, secrets dir, spawn mode, refresh interval)?" n; then
  basedir=$(ask "Directory for git checkouts" "$basedir")
  secrets_dir=$(ask "Secrets directory" "$secrets_dir")
  while :; do
    spawn=$(ask "Spawn mode (worktree, or same-dir: untested)" "$spawn")
    case "$spawn" in worktree|same-dir) break ;; esac
  done
  refresh=$(ask "How often to fast-forward served repos (systemd time span)" "$refresh")
fi
basedir=${basedir%/}
[ "$(dirname "$self_dir")" = "$basedir" ] ||
  die "this repo must be cloned directly in $basedir, but it is at $self_dir: move it there (or keep the checkout dir at $(dirname "$self_dir")) and re-run"

kv=("AI_SANDBOX_HOSTNAME=$host" "AI_SANDBOX_NAME_PREFIX=$prefix" "AI_SANDBOX_PERMISSION_MODE=$mode")
# Defaults stay commented out in the config.
[ "$basedir" = "$HOME/src" ] || kv+=("AI_SANDBOX_GIT_BASEDIR=$basedir")
[ "$secrets_dir" = "$HOME/.secrets" ] || kv+=("AI_SANDBOX_SECRETS_DIR=$secrets_dir")
[ "$spawn" = worktree ] || kv+=("AI_SANDBOX_SPAWN_MODE=$spawn")
[ "$refresh" = 10min ] || kv+=("AI_SANDBOX_REFRESH_INTERVAL=$refresh")
backend=$(raw_config AI_SANDBOX_SECRETS_BACKEND)
[ -z "$backend" ] || [ "$backend" = file ] || kv+=("AI_SANDBOX_SECRETS_BACKEND=$backend")

printf '\n' >&2
for x in "${kv[@]}"; do info "$x"; done
ask_yn "Write this config to $AI_SANDBOX_CONFIG?" y || die "nothing written"
"$AI_SANDBOX_REPO_DIR/bin/ai-sandbox-init-config" --force "${kv[@]}" >/dev/null
info "wrote $AI_SANDBOX_CONFIG"
config_load
secrets_init

# ------------------------------------------------------------------ GitHub token

section "GitHub token"
store_github() {   # token on stdin; validates it, stores it, reports the account
  local tok login; tok=$(cat)
  login=$(printf '%s' "$tok" | github_login) || { info "GitHub rejected that token"; return 1; }
  printf '%s' "$tok" | secret_set "$SECRET_GITHUB"
  info "stored the token for GitHub user $login in $(secret_describe "$SECRET_GITHUB")"
}
have_github=0
if secret_has "$SECRET_GITHUB"; then
  if login=$(secret_get "$SECRET_GITHUB" | github_login); then
    info "using the stored token for GitHub user $login ($(secret_describe "$SECRET_GITHUB"))"; have_github=1
  else
    info "the stored token in $(secret_describe "$SECRET_GITHUB") doesn't work (GitHub rejected it, or it can't be reached)"
    ask_yn "Keep it anyway?" n && have_github=1
  fi
fi
if [ $have_github = 0 ]; then
  for v in GH_TOKEN GITHUB_TOKEN; do
    [ -n "${!v:-}" ] || continue
    if ask_yn "Use the token in \$$v?" y && printf '%s' "${!v}" | store_github; then have_github=1; break; fi
  done
fi
if [ $have_github = 0 ]; then
  info "Paste a GitHub fine-grained personal access token (https://github.com/settings/personal-access-tokens)"
  info "for the repos you'll work on: Contents and Pull requests read/write; Actions/Workflows for CI."
  while :; do
    tok=$(ask_secret "GitHub token, or the path of a file holding it (not shown)")
    [ -n "$tok" ] || die "a GitHub token is required"
    printf '%s' "$tok" | store_github && break
  done
  unset tok
fi

if [ $run_setup = 0 ]; then
  log "config and secrets are in place; run $AI_SANDBOX_REPO_DIR/setup.sh to set up the host"
  exit 0
fi

# ------------------------------------------------------------------ setup

section "Setup"
"$AI_SANDBOX_REPO_DIR/setup.sh" || die "setup failed; fix the problem above and re-run $0 (or ./setup.sh)"

# ------------------------------------------------------------------ restart

section "Restart"
why=()
[ "$(hostname)" = "$AI_SANDBOX_HOSTNAME" ] || why+=("the hostname changes to $AI_SANDBOX_HOSTNAME")
for g in $(id -nG "$USER"); do
  id -nG | tr ' ' '\n' | grep -qx "$g" || why+=("$USER joins group $g")
done
entry="'$AI_SANDBOX_HOSTNAME $(basename "$self_dir")'"
done_msg="Open claude.ai/code or the Claude app and start a session in the $entry environment."
if [ ${#why[@]} = 0 ]; then
  info "no restart needed"
  log "done. $done_msg"
  exit 0
fi
info "a restart is needed so that: $(IFS=';'; echo "${why[*]}" | sed 's/;/; /g')"
if is_wsl; then
  distro=${WSL_DISTRO_NAME:-<distro>}
  log "restart this distro to finish. From Windows (PowerShell or cmd):"
  log "    wsl.exe --terminate $distro      (or wsl.exe --shutdown, which stops every distro)"
  log "then open the distro again (Start menu, Windows Terminal, or: wsl.exe -d $distro)."
  log "The server only runs while the distro is running. After that: $done_msg"
elif info "the $entry server starts again by itself after a reboot"; ask_yn "Reboot now?" y; then
  log "rebooting; reconnect in a minute or two. $done_msg"
  sudo systemctl reboot
else
  log "reboot when convenient (sudo reboot). After that: $done_msg"
fi
