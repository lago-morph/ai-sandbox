# shellcheck shell=bash
# Base tools (git, curl, CA certs, python3 with tomli) and the GitHub CLI, at least the versions
# versions.toml asks for (module "base").

# shellcheck source=../modules.sh
source "$AI_SANDBOX_LIB/modules.sh"

check() {
  platform_load
  local missing out; missing=$(platform_missing_packages)
  [ -z "$missing" ] || { info "missing: $(echo $missing)"; return 1; }
  out=$(versions_py check base) || { grep -v '^ok ' <<<"$out" | while read -r l; do info "$l"; done; return 1; }
}

apply() {
  platform_load
  local out
  # shellcheck disable=SC2046
  platform_install_packages $(platform_missing_packages)
  out=$(versions_py check base) || die "base tools don't meet versions.toml:"$'\n'"$(grep -v '^ok ' <<<"$out")"
}
