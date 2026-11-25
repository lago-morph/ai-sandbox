# shellcheck shell=bash
# Platform support for Ubuntu (tested: 26.04 on WSL2; intended: Ubuntu on AWS EC2).

PLATFORM_PACKAGES=(git curl ca-certificates python3)

# Prints the packages from PLATFORM_PACKAGES (plus gh) that aren't installed.
platform_missing_packages() {
  local p
  for p in "${PLATFORM_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || echo "$p"
  done
  command -v gh >/dev/null || echo gh
}

platform_install_packages() {
  local missing=() p
  for p in "$@"; do [ "$p" = gh ] || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  fi
  if printf '%s\n' "$@" | grep -qx gh; then platform_install_gh; fi
}

# GitHub CLI from GitHub's official apt repository (https://cli.github.com).
platform_install_gh() {
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
}
