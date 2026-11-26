# shellcheck shell=bash
# The user is in the groups sessions need: kvm, for /dev/kvm (VMs, emulators, nested containers).
# Membership is read from the group database; running processes (including the systemd user
# manager and rc@ servers) only get a new group after the user manager restarts.

USER_GROUPS=(kvm)

check() {
  local ok=0 g
  for g in "${USER_GROUPS[@]}"; do
    if ! getent group "$g" >/dev/null; then info "group $g does not exist"; ok=1
    elif ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then info "$USER is not in group $g"; ok=1
    elif ! id -nG | tr ' ' '\n' | grep -qx "$g"; then
      info "$USER is in group $g, but running processes aren't yet; restart the machine (WSL: wsl.exe --shutdown) to pick it up"
    fi
  done
  return $ok
}

apply() {
  local g
  for g in "${USER_GROUPS[@]}"; do
    getent group "$g" >/dev/null || sudo groupadd --system "$g"
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$g" || sudo usermod -aG "$g" "$USER"
  done
  info "new group memberships take effect after a restart (WSL: wsl.exe --shutdown)"
}
