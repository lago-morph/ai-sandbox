#!/usr/bin/env bash
# Usage: ./setup.sh [--check] [--config PATH]
#
# Sets up this machine as an ai-sandbox host: installs tools, wires up credentials, installs
# the ai-sandbox commands, and starts this repo's Remote Control server under systemd.
# Safe to re-run; each step checks first and only changes what's missing or out of date.
#   --check        report what would change, change nothing (exit 1 if anything would)
#   --config PATH  host config to use (default ~/.config/ai-sandbox/config)
set -euo pipefail
AI_SANDBOX_REPO_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
AI_SANDBOX_LIB="$AI_SANDBOX_REPO_DIR/lib"
export AI_SANDBOX_REPO_DIR AI_SANDBOX_LIB

mode=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --config) AI_SANDBOX_CONFIG=${2:?--config needs a path}; export AI_SANDBOX_CONFIG; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=lib/common.sh
source "$AI_SANDBOX_LIB/common.sh"
config_load || die "no host config at $AI_SANDBOX_CONFIG. Run $AI_SANDBOX_REPO_DIR/install.sh (guided), or create one with $AI_SANDBOX_REPO_DIR/bin/ai-sandbox-init-config"

# The main checkout of this repo (setup may be run from a worktree of it).
common_dir=$(git -C "$AI_SANDBOX_REPO_DIR" rev-parse --path-format=absolute --git-common-dir)
AI_SANDBOX_SELF_DIR=$(dirname "$common_dir")
AI_SANDBOX_SELF_NAME=$(basename "$AI_SANDBOX_SELF_DIR")
export AI_SANDBOX_SELF_DIR AI_SANDBOX_SELF_NAME
[ "$(dirname "$AI_SANDBOX_SELF_DIR")" = "$AI_SANDBOX_GIT_BASEDIR" ] ||
  die "the ai-sandbox repo must be cloned directly in AI_SANDBOX_GIT_BASEDIR ($AI_SANDBOX_GIT_BASEDIR), found at $AI_SANDBOX_SELF_DIR"

[ $mode = check ] || start_log setup
log "ai-sandbox $mode: $(git -C "$AI_SANDBOX_REPO_DIR" describe --always --dirty) from $AI_SANDBOX_REPO_DIR, config $AI_SANDBOX_CONFIG"
pending=0 applied=0
for step in "$AI_SANDBOX_LIB"/steps/[0-9]*.sh; do
  name=$(basename "$step" .sh)
  # shellcheck source=/dev/null
  if ( source "$step"; check ); then
    log "ok      $name"
    continue
  fi
  if [ $mode = check ]; then
    log "PENDING $name"; pending=1; continue
  fi
  log "apply   $name  [$(ts)]"
  # shellcheck source=/dev/null
  ( source "$step"; apply ) || die "step $name failed"
  # shellcheck source=/dev/null
  ( source "$step"; check ) || die "step $name still not satisfied after applying it"
  log "applied $name  [$(ts)]"
  applied=1
done

if [ $mode = check ]; then
  [ $pending = 0 ] && log "host is up to date" || log "run ./setup.sh to apply pending steps"
  exit $pending
fi
if [ $applied = 1 ]; then
  running=$(systemctl --user list-units --state=active --plain --no-legend 'rc@*.service' | awk '{print $1}' | xargs)
  [ -z "$running" ] || log "note: running servers keep the previous version until restarted: $running"
fi
log "done  [$(ts)]${AI_SANDBOX_LOG_FILE:+; log: $AI_SANDBOX_LOG_FILE}"
