# shellcheck shell=bash
# Each listed module's files (modules/<name>/: commands, skills, units, its claude.md and
# settings.json) copied onto the host, and the module recorded as installed. A module that is
# no longer listed is left exactly as it is (modules are never uninstalled). The module's tools
# and its own steps are checked after the base steps; see docs/modules.md.

# shellcheck source=../modules.sh
source "$AI_SANDBOX_LIB/modules.sh"

check() {
  local ok=0 m
  for m in $(modules_listed); do module_files_check "$m" || ok=1; done
  return $ok
}

apply() {
  local m
  for m in $(modules_listed); do module_files_apply "$m"; done
}
