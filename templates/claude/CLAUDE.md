# Host conventions (ai-sandbox)
- This is a persistent, self-managed machine set up by the ai-sandbox repo, not an ephemeral
  container. Full test suites, parallel builds and long-running processes are fine; check
  `nproc` / `free -h` for capacity. Use systemd user units for anything that should keep running.
- Git checkouts live under @GIT_BASEDIR@.
- Use the `gh` CLI for all GitHub operations (PRs, issues, Actions, API); it's authenticated.
- `git` authenticates to github.com over HTTPS through a credential helper.
- Never print credentials or write them to logs, command output, or files.
- Never start `claude remote-control` as a Bash background task; Remote Control servers are
  managed by the ai-sandbox repo (see its CLAUDE.md).
