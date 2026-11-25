# shellcheck shell=bash
# git uses the ai-sandbox credential helper for github.com; gh is logged in with the same token;
# git has a commit identity (if unset: the token's GitHub account with its noreply email).

HELPER_KEY=credential.https://github.com.helper

check() {
  local ok=0
  secrets_init
  [ "$(git config --global --get-all "$HELPER_KEY" 2>/dev/null)" = "$AI_SANDBOX_BIN/ai-sandbox-git-credential" ] ||
    { info "git credential helper for github.com not set to ai-sandbox-git-credential"; ok=1; }
  # Compare tokens without printing either.
  if ! command -v gh >/dev/null || [ "$(gh auth token -h github.com 2>/dev/null)" != "$(secret_get "$SECRET_GITHUB")" ]; then
    info "gh is not logged in with the current GitHub token"; ok=1
  fi
  { git config --global user.name && git config --global user.email; } >/dev/null ||
    { info "git user.name/user.email not set"; ok=1; }
  return $ok
}

apply() {
  secrets_init
  git config --global --unset-all "$HELPER_KEY" 2>/dev/null || true
  git config --global "$HELPER_KEY" "$AI_SANDBOX_BIN/ai-sandbox-git-credential"
  git config --global credential.https://github.com.useHttpPath false
  secret_get "$SECRET_GITHUB" | gh auth login --hostname github.com --git-protocol https --with-token
  chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/gh/hosts.yml" 2>/dev/null || true
  if ! git config --global user.name >/dev/null || ! git config --global user.email >/dev/null; then
    local login id name
    login=$(gh api user --jq .login) && id=$(gh api user --jq .id) || die "could not read GitHub user"
    name=$(gh api user --jq '.name // empty'); name=${name:-$login}
    git config --global user.name >/dev/null || git config --global user.name "$name"
    git config --global user.email >/dev/null || git config --global user.email "$id+$login@users.noreply.github.com"
    info "git identity: $(git config --global user.name) <$(git config --global user.email)>"
  fi
}
