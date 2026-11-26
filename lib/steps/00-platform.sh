# shellcheck shell=bash
# Supported distro, systemd as PID 1 with a user manager, and passwordless sudo (granted by
# setup-root.sh, which a human runs once with sudo; setup itself can't grant it).

check() {
  local ok=0
  [ -f "$AI_SANDBOX_LIB/platform/$(platform_id).sh" ] || { info "distro '$(platform_id)' has no lib/platform/$(platform_id).sh"; ok=1; }
  [ "$(ps -o comm= -p 1)" = systemd ] || { info "systemd is not PID 1"; ok=1; }
  systemctl --user show-environment >/dev/null 2>&1 || { info "systemd user manager not reachable (systemctl --user)"; ok=1; }
  command -v sudo >/dev/null || { info "sudo is not installed"; ok=1; }
  sudo -n true 2>/dev/null || { info "$USER can't run sudo without a password"; ok=1; }
  return $ok
}

apply() {
  [ -f "$AI_SANDBOX_LIB/platform/$(platform_id).sh" ] ||
    die "unsupported distro '$(platform_id)': add lib/platform/$(platform_id).sh (see lib/platform/README.md)"
  if [ "$(ps -o comm= -p 1)" != systemd ]; then
    if is_wsl; then
      if ! grep -qs '^systemd=true' /etc/wsl.conf; then
        info "enabling systemd in /etc/wsl.conf"
        if grep -qs '^\[boot\]' /etc/wsl.conf; then
          sudo sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        else
          printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
        fi
      fi
      die "systemd is enabled for WSL but not running yet: run 'wsl.exe --shutdown' from Windows, reopen the distro, and re-run setup"
    fi
    die "systemd must be PID 1 (hard requirement)"
  fi
  systemctl --user show-environment >/dev/null 2>&1 ||
    die "systemd user manager not reachable; log in as $USER through a normal login session and retry"
  command -v sudo >/dev/null || die "install sudo and give $USER sudo rights"
  sudo -n true 2>/dev/null ||
    die "$USER needs passwordless sudo: run 'sudo $AI_SANDBOX_REPO_DIR/setup-root.sh' once, then re-run setup"
}
