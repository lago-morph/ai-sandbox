# shellcheck shell=bash
# Platform support for Ubuntu (tested: 26.04 on WSL2; intended: Ubuntu on AWS EC2).

PLATFORM_PACKAGES=(git curl ca-certificates python3 python3-tomli)

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

# ---------------------------------------------------------------- hostname
# WSL: /etc/wsl.conf [network] hostname plus generateHosts=false (WSL otherwise rewrites
# /etc/hosts with the Windows computer name); takes effect after `wsl.exe --shutdown`.
# Elsewhere (untested): hostnamectl, plus cloud-init's preserve_hostname so EC2 keeps it.
# Both: the 127.0.1.1 line in /etc/hosts, so the name resolves.

PLATFORM_CLOUD_INIT_HOSTNAME_CFG=/etc/cloud/cloud.cfg.d/99-ai-sandbox-hostname.cfg

# Prints "PATH<TAB>CONTENT_FILE" for each file that should change; content files are temp files.
_platform_hostname_plan() {
  local name=$1 t
  t=$(mktemp); hosts_render /etc/hosts "$name" > "$t"
  root_file_matches /etc/hosts "$t" && rm -f "$t" || printf '/etc/hosts\t%s\n' "$t"
  if is_wsl; then
    t=$(mktemp); ini_render /etc/wsl.conf network "hostname=$name" generateHosts=false > "$t"
    root_file_matches /etc/wsl.conf "$t" && rm -f "$t" || printf '/etc/wsl.conf\t%s\n' "$t"
  elif [ -d /etc/cloud/cloud.cfg.d ]; then
    t=$(mktemp); printf '# Installed by ai-sandbox setup (AI_SANDBOX_HOSTNAME).\npreserve_hostname: true\n' > "$t"
    root_file_matches "$PLATFORM_CLOUD_INIT_HOSTNAME_CFG" "$t" && rm -f "$t" ||
      printf '%s\t%s\n' "$PLATFORM_CLOUD_INIT_HOSTNAME_CFG" "$t"
  fi
}

# Exit 0 if the hostname is configured to persist as NAME (it may still need a restart).
platform_hostname_check() {
  local name=$1 ok=0 path t
  while IFS=$'\t' read -r path t; do info "$path not set up for hostname $name"; rm -f "$t"; ok=1; done \
    < <(_platform_hostname_plan "$name")
  if ! is_wsl && [ "$(hostnamectl --static 2>/dev/null)" != "$name" ]; then
    info "static hostname is not $name"; ok=1
  fi
  return $ok
}

platform_hostname_apply() {
  local name=$1 path t
  while IFS=$'\t' read -r path t; do
    info "updating $path (original kept as $path.bak-ai-sandbox)"
    root_file_write "$path" "$t"; rm -f "$t"
  done < <(_platform_hostname_plan "$name")
  is_wsl || [ "$(hostnamectl --static 2>/dev/null)" = "$name" ] || sudo hostnamectl set-hostname "$name"
}
