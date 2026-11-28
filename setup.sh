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

# shellcheck source=lib/modules.sh
source "$AI_SANDBOX_LIB/modules.sh"
# Modules (docs/modules.md): stop on an unknown name before any step. The full check needs the
# TOML reader, which a fresh host only gets from the packages step; it then runs after the base steps.
modules_check_names
preflight_done=0
if [ -n "$AI_SANDBOX_MODULES" ] && tomli_available; then modules_preflight; preflight_done=1; fi

[ $mode = check ] || start_log setup
log "ai-sandbox $mode: $(git -C "$AI_SANDBOX_REPO_DIR" describe --always --dirty) from $AI_SANDBOX_REPO_DIR, config $AI_SANDBOX_CONFIG"
pending=0 applied=0

# run_step NAME FILE: check the step; in apply mode apply it if needed and check again.
run_step() {
  local name=$1 step=$2
  # shellcheck source=/dev/null
  if ( source "$step"; check ); then
    log "ok      $name"
    return 0
  fi
  if [ $mode = check ]; then
    log "PENDING $name"; pending=1; return 0
  fi
  log "apply   $name  [$(ts)]"
  # shellcheck source=/dev/null
  ( source "$step"; apply ) || die "step $name failed"
  # shellcheck source=/dev/null
  ( source "$step"; check ) || die "step $name still not satisfied after applying it"
  log "applied $name  [$(ts)]"
  applied=1
}

for step in "$AI_SANDBOX_LIB"/steps/[0-9]*.sh; do
  run_step "$(basename "$step" .sh)" "$step"
done

# Each listed module, in list order: its tools against versions.toml (installed and upgraded by
# an agent following the module's doc, never by setup), then its own steps.
if [ -n "$AI_SANDBOX_MODULES" ]; then
  if [ $preflight_done = 0 ]; then
    if tomli_available; then modules_preflight
    else log "PENDING modules: python3-tomli is needed to read versions.toml (the packages step installs it)"; pending=1; fi
  fi
  if tomli_available; then
    for m in $(modules_listed); do
      if out=$(module_tools_check "$m"); then
        log "ok      $m/tools"
      else
        bad=$(grep -v '^ok ' <<<"$out")
        if [ $mode = check ]; then
          log "PENDING $m/tools"; while read -r l; do info "$l"; done <<<"$bad"; pending=1; continue
        fi
        die "module $m: its tools need an agent (setup doesn't install them):"$'\n'"$(sed 's/^/   /' <<<"$bad")"
      fi
      for step in "$AI_SANDBOX_MODULES_DIR/$m"/steps/[0-9]*.sh; do
        [ -f "$step" ] || continue
        AI_SANDBOX_MODULE=$m AI_SANDBOX_MODULE_DIR="$AI_SANDBOX_MODULES_DIR/$m" run_step "$m/$(basename "$step" .sh)" "$step"
      done
    done
  fi
fi

if [ $mode = check ]; then
  [ $pending = 0 ] && log "host is up to date" || log "run ./setup.sh to apply pending steps"
  exit $pending
fi
if [ $applied = 1 ]; then
  running=$(systemctl --user list-units --state=active --plain --no-legend 'rc@*.service' | awk '{print $1}' | xargs)
  [ -z "$running" ] || log "note: running servers keep the previous version until restarted: $running"
fi
log "done  [$(ts)]${AI_SANDBOX_LOG_FILE:+; log: $AI_SANDBOX_LOG_FILE}"
