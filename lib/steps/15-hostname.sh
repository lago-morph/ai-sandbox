# shellcheck shell=bash
# AI_SANDBOX_HOSTNAME: the machine's hostname, which claude.ai shows in the environment list
# ("<hostname> <repo>"). Nothing to do when it's empty. Distro specifics are in lib/platform/.

check() {
  [ -n "$AI_SANDBOX_HOSTNAME" ] || return 0
  platform_load
  platform_hostname_check "$AI_SANDBOX_HOSTNAME" || return 1
  if [ "$(hostname)" != "$AI_SANDBOX_HOSTNAME" ]; then
    if is_wsl; then
      info "hostname $AI_SANDBOX_HOSTNAME is configured; run 'wsl.exe --shutdown' from Windows to switch (ends every session)"
    else
      info "hostname $AI_SANDBOX_HOSTNAME is configured but not active yet; reboot to switch"
    fi
  fi
}

apply() {
  platform_load
  platform_hostname_apply "$AI_SANDBOX_HOSTNAME"
}
