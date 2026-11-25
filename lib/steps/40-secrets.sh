# shellcheck shell=bash
# Secrets storage is safe and the GitHub token is present.

check() {
  local ok=0 problems
  secrets_init
  problems=$(secrets_backend_check) || { while read -r l; do info "$l"; done <<<"$problems"; ok=1; }
  secret_has "$SECRET_GITHUB" || { info "GitHub token missing: expected in $(secret_describe "$SECRET_GITHUB")"; ok=1; }
  return $ok
}

apply() {
  secrets_init
  secrets_backend_fix || true
  secret_has "$SECRET_GITHUB" ||
    die "put a GitHub fine-grained PAT in $(secret_describe "$SECRET_GITHUB") and re-run setup"
}
