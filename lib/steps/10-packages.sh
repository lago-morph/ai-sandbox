# shellcheck shell=bash
# Base tools (git, curl, CA certs, python3) and the GitHub CLI.

check() {
  platform_load
  local missing; missing=$(platform_missing_packages)
  [ -z "$missing" ] || { info "missing: $(echo $missing)"; return 1; }
}

apply() {
  platform_load
  # shellcheck disable=SC2046
  platform_install_packages $(platform_missing_packages)
}
