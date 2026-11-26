# ai-sandbox

Turns a Linux machine you control into a personal Claude Code sandbox that you drive from
claude.ai or the Claude app (phone, iPad, browser) through
[Remote Control](https://code.claude.com/docs/en/remote-control). Unlike cloud sessions,
nothing times out, you have the machine's full CPU, memory and disk, and you decide what's
installed and what the sessions may do.

Clone this repo and run `./install.sh`, which asks a few questions and sets everything up. The
machine then shows up in your Claude environments list (under Remote Control) as
`<hostname> ai-sandbox`. Sessions there both manage the host (serve other repos, check services,
change config) and develop this repo. Each other repo you serve gets its own `<hostname> <repo>`
entry, and every session gets its own git worktree. The list always uses the machine's hostname;
set `AI_SANDBOX_HOSTNAME` to change it (on WSL it is otherwise the Windows computer name).

**Supported:** Ubuntu on WSL2 (with systemd) and Ubuntu on AWS EC2. systemd is required.
Other distros need a small platform file; see [Contributing](#contributing).

## QuickStart

**Prerequisites**
- Ubuntu with systemd as PID 1, and a user with `sudo` (you'll need its password once). On WSL2, setup turns systemd on for
  you and asks you to restart WSL. On EC2, the default `ubuntu` user is fine.
- A Claude subscription (Remote Control needs a claude.ai login).
- A GitHub [fine-grained personal access token](https://github.com/settings/personal-access-tokens)
  for the repos you'll work on. For pushing and opening PRs, give it read/write on Contents
  and Pull requests (and Actions/Workflows if you want sessions to work with CI).

**1. Clone and install**, as the user the sandbox is for, in a terminal on the machine:
```bash
mkdir -p ~/src && git clone https://github.com/lago-morph/ai-sandbox.git ~/src/ai-sandbox
~/src/ai-sandbox/install.sh
```
`install.sh` walks you through:
- **Passwordless sudo:** runs `sudo setup-root.sh` first, which asks for your password. This is
  the only time a password is needed. Then it installs the few packages it uses itself (`curl`,
  `python3`, `git`) if they're missing; setup installs the rest, including `gh` and the Claude CLI.
- **Host settings:** the hostname (what the environment list shows), the session name prefix
  (defaults to the hostname), the permission mode (defaults to `bypassPermissions`), and
  optionally the advanced settings. It writes `~/.config/ai-sandbox/config`.
- **GitHub token:** keeps one already in `~/.secrets/github`, offers `$GH_TOKEN`/`$GITHUB_TOKEN`
  if set, or asks you to paste one or the path of a file holding it (not echoed). It checks the token with GitHub before storing it.
- **Claude login:** paste a `claude setup-token` token (or the path of a file holding it), or press Enter to log in through the
  browser while setup runs (recommended; skipped if you're already logged in).
- **Setup:** runs `./setup.sh` (see the table below).
- **Restart:** if the hostname or your groups changed, it offers to reboot; `rc@ai-sandbox`
  starts again at boot. On WSL it prints how to restart the distro from Windows instead
  (`wsl.exe --terminate <distro>` or `wsl.exe --shutdown`, then open the distro again).

Everything it and setup print also goes to a log, `~/.local/state/ai-sandbox/install.log`
(setup on its own: `setup.log`); each links to the latest timestamped file next to it.
It's safe to re-run: current values are the defaults and stored secrets are kept. Later changes
can also go through `./setup.sh` directly, which never prompts except for the Claude login.

**2. Connect.** Open [claude.ai/code](https://claude.ai/code) or the Claude app, pick the
`<hostname> ai-sandbox` environment, and start a session. To work on another repo, ask that
session to serve it ("serve lago-morph/cloud-app"), then start sessions in its
`<hostname> cloud-app` environment.

### Manual install

The same steps without the prompts:
```bash
sudo ~/src/ai-sandbox/setup-root.sh                   # passwordless sudo: /etc/sudoers.d/<you>
printf '%s' "$TOKEN" | ~/src/ai-sandbox/bin/ai-sandbox-secret set github   # or: ai-sandbox-secret set github, and paste
~/src/ai-sandbox/bin/ai-sandbox-init-config \
  AI_SANDBOX_HOSTNAME=laptop AI_SANDBOX_NAME_PREFIX=laptop AI_SANDBOX_PERMISSION_MODE=bypassPermissions
cd ~/src/ai-sandbox && ./setup.sh
```
`setup-root.sh` writes `/etc/sudoers.d/<you>` (`NOPASSWD:ALL`, validated with `visudo`); setup
stops and points you to it if it's missing. If you're not logged in to Claude yet, setup starts
`claude auth login`. On WSL, a new hostname takes effect after `wsl.exe --shutdown` from Windows;
setup tells you when that's still needed.

### What setup does

| Step | What it ensures |
|---|---|
| `00-platform` | Supported distro, systemd as PID 1 with a user manager, passwordless sudo (from `setup-root.sh`). Enables systemd on WSL if needed. |
| `10-packages` | `git`, `curl`, CA certificates, `python3`, and `gh` (from GitHub's apt repo). |
| `12-groups` | The user is in the `kvm` group (created if missing), for `/dev/kvm`. Takes effect after a restart. |
| `15-hostname` | With `AI_SANDBOX_HOSTNAME`: on WSL, `[network] hostname` and `generateHosts = false` in `/etc/wsl.conf`; elsewhere, `hostnamectl` and cloud-init's `preserve_hostname`. Both: the `127.0.1.1` line in `/etc/hosts`. Originals kept as `*.bak-ai-sandbox`. |
| `20-claude-cli` | Claude Code's native build in `~/.local/bin/claude`. |
| `30-install` | This repo's `bin/` commands in `~/.local/bin`; `lib/`, `config/`, `templates/` in `~/.local/share/ai-sandbox`. |
| `40-secrets` | Secrets storage is private (700/600) and the GitHub token is present. |
| `50-github` | `git` gets the token from `ai-sandbox-git-credential` for github.com; `gh` is logged in with it; if git has no commit identity, it uses the token's GitHub account and noreply email. |
| `60-claude-auth` | Claude is logged in (or a setup-token is present; see below). |
| `70-claude-config` | A managed block of host conventions in `~/.claude/CLAUDE.md`; this repo trusted. With `bypassPermissions`: the dangerous-mode warning pre-accepted, and the ai-sandbox auto mode rules plus a `Bash` allow rule in `~/.claude/settings.json` (see [Permission modes](#permission-modes)). |
| `80-systemd` | Lingering, the `rc@` unit template, `rc-refresh.timer`, and `rc@ai-sandbox` enabled at boot and running. |

### Day to day

| Task | Command |
|---|---|
| Serve a repo (clone if needed, refresh, start) | `rc-start owner/repo` |
| Stop serving a repo | `systemctl --user stop rc@<repo>` |
| See what's served | `systemctl --user list-units 'rc@*'` |
| Server logs | `journalctl --user -u rc@<repo>` |
| Check the host matches this repo (changes nothing) | `./setup.sh --check` |
| Logs of the last install / setup run | `~/.local/state/ai-sandbox/install.log`, `setup.log` |
| Run the tests | `tests/run.sh` (add `--host` to include `./setup.sh --check`) |

Only `rc@ai-sandbox` starts at boot. Other repos are served until you stop them or the machine
restarts. Every served repo's main checkout is fast-forwarded every 10 minutes (only when it's
clean and on the default branch), so new sessions pick up merged skills, hooks and settings.

**Updating the host.** The main checkout of this repo is refreshed automatically, but the host
only changes when you run `./setup.sh` again. Running Remote Control servers keep the old version
until restarted (`systemctl --user restart rc@<repo>`); restarting drops their connected sessions.

## Configuration

The host config is a Bash file at `~/.config/ai-sandbox/config` (override with
`AI_SANDBOX_CONFIG=...` or `./setup.sh --config PATH`). Create it with `bin/ai-sandbox-init-config`
or edit it by hand, then re-run `./setup.sh`. The repo's `host-config` skill can do this for you.

| Key | Default | Meaning |
|---|---|---|
| `AI_SANDBOX_GIT_BASEDIR` | `$HOME/src` | Where checkouts live. This repo must be cloned directly inside it. |
| `AI_SANDBOX_SECRETS_BACKEND` | `file` | Where secrets come from. Only `file` exists today. |
| `AI_SANDBOX_SECRETS_DIR` | `$HOME/.secrets` | `file` backend: one file per secret. |
| `AI_SANDBOX_HOSTNAME` | empty | The machine's hostname, which the environment list shows as `<hostname> <repo>`. Empty: leave the hostname alone. |
| `AI_SANDBOX_NAME_PREFIX` | short hostname | Sessions are named `<prefix>-<repo>` (the server's `--name`), and auto-generated session names use it. It doesn't change the environment list. |
| `AI_SANDBOX_SPAWN_MODE` | `worktree` | `worktree`: each session gets its own git worktree. `same-dir`: sessions share the main checkout. |
| `AI_SANDBOX_PERMISSION_MODE` | empty | Permission mode for new sessions (`bypassPermissions`, `acceptEdits`, `auto`, `default`, `dontAsk`, `plan`). Empty: use `~/.claude/settings.json`. The Claude app can override it; see [Permission modes](#permission-modes). |
| `AI_SANDBOX_REFRESH_INTERVAL` | `10min` | How often served repos are fast-forwarded (systemd time span). |

**Secrets** (names as used by the backend; with `file`, these are file names in the secrets dir):

| Secret | Required | Used for |
|---|---|---|
| `github` | yes | git over HTTPS to github.com, and `gh`. Read at use time; after rotating it, re-run `./setup.sh` so `gh` picks it up too. |
| `claude-oauth-token` | no | A token from `claude setup-token`, passed to Remote Control servers instead of the interactive login. |

> **Untested configurations.** Only the defaults above plus `AI_SANDBOX_NAME_PREFIX`,
> `AI_SANDBOX_PERMISSION_MODE=bypassPermissions` and `AI_SANDBOX_HOSTNAME` on WSL run on a real
> host today. (`AI_SANDBOX_HOSTNAME` on WSL: the files are verified, but the environment list
> showing the new name after `wsl.exe --shutdown` is not confirmed yet.) These work in the unit
> tests but haven't been used for real: `AI_SANDBOX_HOSTNAME` outside WSL (hostnamectl,
> cloud-init), `same-dir` spawn mode, a non-default git base dir or secrets dir, a different
> refresh interval, and `claude-oauth-token` (it isn't confirmed that Remote Control accepts
> setup-tokens). `install.sh` has run on WSL with an existing setup; a fresh install, EC2 and
> its reboot step are untested, as is `wsl.exe --terminate` (rather than `--shutdown`) for
> applying the hostname. If you rely on one of them, please send a PR with a test once it works for you.

### Permission modes

`AI_SANDBOX_PERMISSION_MODE` is passed to `claude remote-control --permission-mode`, but the
Claude app (seen on iOS/iPadOS) sends its own mode when it creates a session, typically `auto`,
and that wins. The app's mode picker doesn't offer bypass for Remote Control sessions. See
[anthropics/claude-code#87829](https://github.com/anthropics/claude-code/issues/87829).

So with `bypassPermissions`, setup also writes rules for auto mode's classifier into
`~/.claude/settings.json`, from `templates/claude/auto-mode.json`: an `autoMode.environment`
entry saying this is the user's sandbox, and `autoMode.allow` entries saying the user has
pre-approved every Bash command (sudo included), host administration and Claude config edits.
Each is tagged `(ai-sandbox)`; setup keeps `"$defaults"` first in each list and leaves your own
entries alone. Auto mode still runs its classifier and its hard-block rules, so this is close to
bypass but not identical. Setup also adds a `Bash` entry to `permissions.allow`, which removes
Bash prompts in Manual and Accept edits mode (auto mode ignores such broad rules). With any other
permission mode, setup removes these entries. `claude auto-mode config` shows the effective rules.

## Security notes

- Remote Control only makes outbound HTTPS connections; no inbound ports are needed. On EC2,
  the security group can deny all inbound traffic (use SSM or a temporary SSH rule for setup).
- `setup-root.sh` gives the sandbox user passwordless sudo, so sessions effectively run as root
  whenever they choose to.
- `bypassPermissions` (and the auto mode pre-approval rules it installs) lets sessions run any
  command as your user without asking, and this user usually has sudo. That's the point of a personal sandbox, but use a machine and a GitHub token
  you're comfortable handing to an agent. A fine-grained token limited to specific repos is best.
- Secrets never go into the repo or the config. Anything running as your user can read them,
  including sessions; the sandbox is only as isolated as the user account.
- Claude Code itself keeps its login in `~/.claude/.credentials.json`.

## Contributing

- `tests/run.sh` runs the regression tests in a throwaway `$HOME`; they don't touch the real host.
  Please add a test with each change.
- **New distro:** add `lib/platform/<os-release ID>.sh` ([contract](lib/platform/README.md)).
- **New secrets backend** (environment variables, a vault, ...): add `lib/secrets/<name>.sh`
  implementing the six functions documented in `lib/common.sh`, then select it with
  `AI_SANDBOX_SECRETS_BACKEND=<name>`. Nothing else reads secrets directly.
- **New setup step:** add `lib/steps/NN-name.sh` defining `check` (report-only; exit 1 if work
  is needed) and `apply`. Steps run in file-name order.

## Layout

```
install.sh                guided first-time install: asks, writes config and secrets, runs setup
setup.sh                  entry point (--check for report-only)
setup-root.sh             run once with sudo: passwordless sudo for the sandbox user
bin/                      commands installed to ~/.local/bin
  rc-start, rc-refresh      serve a repo / fast-forward served repos
  ai-sandbox-rc             ExecStart of rc@<repo>: runs `claude remote-control` with the config
  ai-sandbox-git-credential git credential helper backed by the secrets backend
  ai-sandbox-secret         has/describe/get/set a secret
  ai-sandbox-init-config    create the host config
lib/common.sh             config, secrets interface, helpers
lib/steps/                setup steps
lib/platform/             distro support
lib/secrets/              secrets backends
templates/                systemd units and the ~/.claude/CLAUDE.md block
config/                   example host config
tests/run.sh              regression tests
.claude/skills/           skills for sessions in this repo
CLAUDE.md                 instructions for sessions in this repo
```
