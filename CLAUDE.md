# ai-sandbox

This repo sets up and manages the machine you are running on. Sessions here have two jobs:

1. **Manage this host**: serve repos over Remote Control, check services, change the host
   config, apply updates. The user drives this from claude.ai or the Claude app.
2. **Develop this repo**: the scripts, units, docs and tests that set up such a host.

Read README.md for what setup does, the config keys, and the layout.

## Managing the host
- Serve a repo: `rc-start <owner>/<repo>` (or `rc-start <repo>` if already cloned). It clones
  into the git base dir, puts the main checkout on the default branch, fast-forwards it, trusts
  it, and starts `rc@<repo>`. The user then connects to the `<hostname> <repo>` entry in the
  environment list (sessions are named `<prefix>-<repo>`).
  Other repos are not started at boot; only `rc@<this repo>` is.
- Stop: `systemctl --user stop rc@<repo>`. List: `systemctl --user list-units 'rc@*'`.
  Logs: `journalctl --user -u rc@<repo>`.
- Never run `claude remote-control` directly or as a background task; use `rc-start`/systemd.
- Only one server can serve a directory. After one is killed, a new one may be refused as
  "already served" for 1-2 minutes until the old registration expires; the unit retries itself.
- Every change to the host goes through this repo: if a task needs a host change (files in
  `/etc`, `~/.claude/settings.json`, packages, units), add or extend a step in `lib/steps/` and
  apply it with setup. Don't hand-edit the host and stop there.
- Host config: `~/.config/ai-sandbox/config` (see the `host-config` skill). Secrets: through the
  backend only (`ai-sandbox-secret has|describe NAME`). Never print a secret's value.
- Anything that needs root before passwordless sudo exists goes in `setup-root.sh`, which the
  user runs once with `sudo` (sessions can't type a password). Everything else is a setup step.
- The host only changes when `./setup.sh` runs. Run `./setup.sh --check` first and show the user
  what will change. Run setup from the main checkout once changes are merged, or from a worktree
  to try out unmerged changes (tell the user if you do).
- Restarting `rc@<repo>` drops every session connected to it. **Restarting `rc@<this repo>` ends
  your own session**: tell the user and get confirmation first.
- Files setup manages (don't hand-edit; change the repo and re-run setup): `~/.local/bin/{rc-*,ai-sandbox-*}`,
  `~/.local/share/ai-sandbox/`, `~/.config/systemd/user/{rc@.service,rc-refresh.*}`, the
  ai-sandbox block in `~/.claude/CLAUDE.md`, `remoteDialogSeen` in `~/.claude.json`, the `(ai-sandbox)` auto mode rules and the `Bash`
  allow rule in `~/.claude/settings.json`, and (with `AI_SANDBOX_HOSTNAME`) `/etc/wsl.conf`
  `[network]`, `/etc/hosts`'s `127.0.1.1` line.

## Developing
- Run `tests/run.sh` before every commit (it needs `shellcheck`; tests use a throwaway `$HOME`).
  `tests/run.sh --host` also runs `./setup.sh --check` against this machine, read-only.
- Bash with `set -euo pipefail`; keep `shellcheck -S warning` clean.
- Steps in `lib/steps/` define `check` (report only, exit 1 if work is needed) and `apply`
  (idempotent). Secrets only through `secret_get`/`secret_has`; distro specifics only in
  `lib/platform/`.
- Mark anything that hasn't run on a real host as untested in README.md.
