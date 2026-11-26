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

In a terminal on the machine, as the user the sandbox is for:

**1. Clone this repo**
```bash
mkdir -p ~/src && git clone https://github.com/lago-morph/ai-sandbox.git ~/src/ai-sandbox
```

**2. Install the Claude CLI**
```bash
curl -fsSL https://claude.ai/install.sh | bash
```

**3. Log in to Claude.** Remote Control needs a full claude.ai login; it rejects tokens from
`claude setup-token`. Over SSH, the login prints a URL to open in any browser and asks you to
paste back the code.
```bash
~/.local/bin/claude auth login
```

**4. Run the installer**
```bash
~/src/ai-sandbox/install.sh
```
It stops and points you back to steps 2 and 3 if Claude isn't installed and logged in yet. Then it walks you
through:
- **Passwordless sudo:** runs `sudo setup-root.sh` first, which asks for your password. This is
  the only time a password is needed. Then it installs the few packages it uses itself (`curl`,
  `python3`, `git`) if they're missing; setup installs the rest, including `gh`.
- **Host settings:** the hostname (what the environment list shows), the session name prefix
  (defaults to the hostname), the permission mode (defaults to `bypassPermissions`), and
  optionally the advanced settings. It writes `~/.config/ai-sandbox/config`.
- **GitHub token:** keeps one already in `~/.secrets/github`, offers `$GH_TOKEN`/`$GITHUB_TOKEN`
  if set, or asks you to paste one or the path of a file holding it (not echoed). It checks the token with GitHub before storing it.
- **Setup:** runs `./setup.sh` (see the table below).
- **Restart:** if the hostname or your groups changed, it offers to reboot; `rc@ai-sandbox`
  starts again at boot. On WSL it prints how to restart the distro from Windows instead
  (`wsl.exe --terminate <distro>` or `wsl.exe --shutdown`, then open the distro again).

Everything it and setup print also goes to a log, `~/.local/state/ai-sandbox/install.log`
(setup on its own: `setup.log`); each links to the latest timestamped file next to it.
It's safe to re-run: current values are the defaults and stored secrets are kept. Later changes
can also go through `./setup.sh` directly, which never prompts (except to log in to Claude, if
the login has gone).

**5. Connect.** Open [claude.ai/code](https://claude.ai/code) or the Claude app, pick the
`<hostname> ai-sandbox` environment, and start a session. To work on another repo, ask that
session to serve it ("serve lago-morph/cloud-app"), then start sessions in its
`<hostname> cloud-app` environment.

### Manual install

The same steps without the prompts, after steps 1 to 3:
```bash
sudo ~/src/ai-sandbox/setup-root.sh                   # passwordless sudo: /etc/sudoers.d/<you>
printf '%s' "$TOKEN" | ~/src/ai-sandbox/bin/ai-sandbox-secret set github   # or: ai-sandbox-secret set github, and paste
~/src/ai-sandbox/bin/ai-sandbox-init-config \
  AI_SANDBOX_HOSTNAME=laptop AI_SANDBOX_NAME_PREFIX=laptop AI_SANDBOX_PERMISSION_MODE=bypassPermissions
cd ~/src/ai-sandbox && ./setup.sh
```
`setup-root.sh` writes `/etc/sudoers.d/<you>` (`NOPASSWD:ALL`, validated with `visudo`); setup
stops and points you to it if it's missing. If you're not logged in to Claude, setup starts
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
| `60-claude-auth` | Claude is logged in to claude.ai; if not, it runs `claude auth login` (in a terminal). |
| `70-claude-config` | A managed block of host conventions in `~/.claude/CLAUDE.md`; this repo trusted; Remote Control's one-time "Enable Remote Control?" answered yes for you (`remoteDialogSeen` in `~/.claude.json`), since a server under systemd can't answer it and exits. With `bypassPermissions`: the dangerous-mode warning pre-accepted, and the ai-sandbox auto mode rules plus a `Bash` allow rule in `~/.claude/settings.json` (see [Permission modes](#permission-modes)). With `AI_SANDBOX_LEAN_TOOLS=on`: the lean-tools deny rules and `enableArtifact: false` in `~/.claude/settings.json`. |
| `80-systemd` | Lingering, the `rc@` unit template, `rc-refresh.timer`, and `rc@ai-sandbox` enabled at boot and running (it must stay up for a few seconds; otherwise setup shows its last output). |

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
| `AI_SANDBOX_LEAN_TOOLS` | `on` | `on`: the deny rules in `templates/claude/lean-tools.json` go into `~/.claude/settings.json`, so tools sessions don't use aren't loaded into their context (see [Fewer unused tools](#cloud-sessions-fewer-unused-tools)). `off`: those rules are removed. |

**Secrets** (names as used by the backend; with `file`, these are file names in the secrets dir):

| Secret | Required | Used for |
|---|---|---|
| `github` | yes | git over HTTPS to github.com, and `gh`. Read at use time; after rotating it, re-run `./setup.sh` so `gh` picks it up too. |

> **Untested configurations.** Run on a real host: the defaults above plus
> `AI_SANDBOX_NAME_PREFIX` and `AI_SANDBOX_PERMISSION_MODE=bypassPermissions`; `AI_SANDBOX_HOSTNAME`
> on WSL (the files are verified, but the environment list showing the new name after
> `wsl.exe --shutdown` is not confirmed yet) and on EC2 (hostnamectl and cloud-init; the name
> survives a reboot); `AI_SANDBOX_GIT_BASEDIR=~/code`; and `install.sh` on a fresh EC2 Ubuntu
> 26.04 instance, including its reboot. These work in the unit tests but haven't been used for
> real: `same-dir` spawn mode, a non-default secrets dir, a different refresh interval, and
> `wsl.exe --terminate` (rather than `--shutdown`) for applying the hostname on WSL. If you rely on
> one of them, please send a PR with a test once it works for you.

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

## Cloud sessions: fewer unused tools

Every Claude Code session loads full definitions for tools it rarely or never calls; in
archived cloud sessions, the `claude-code-remote` MCP server alone was about 20K tokens and
Artifact about 9K. `templates/claude/lean-tools.json` denies them by bare name, which the
permissions docs say removes a tool from context. It also turns off skills no session
here uses (office documents, browsers, computer use, dataviz, claude-api) with `skillOverrides: "off"` plus a
`Skill(...)` deny rule each; a local test showed they leave the skill listing, without
isolating which of the two does it. Skills from a plugin ignore both, so `enabledPlugins` turns off the
claude.ai-synced `cowork-plugin-management@synced` plugin instead. `deniedMcpServers` blocks the claude.ai Claude Docs
connector, whose tools are denied anyway but whose server instructions would still load. It's kept here so every cloud environment uses one list:

- Set each claude.ai/code environment's setup script to this one line:
  ```bash
  curl -fsSL --max-time 30 https://raw.githubusercontent.com/lago-morph/ai-sandbox/main/cloud/setup.sh | bash
  ```
  `cloud/setup.sh` downloads `lean-tools.json` from `main` and merges it into
  `~/.claude/settings.json` for root and each user under `/home`, keeping existing settings.
  It stops its work after 120 seconds and always exits 0, and a failed download gives bash
  empty input (exit 0), so it never stops a session from starting.
- The environment must reach `raw.githubusercontent.com`.
- To change the list, edit `lean-tools.json` and merge. New containers pick it up; resumed
  sessions keep what they started with.
- For a session that needs a denied tool, use an environment without the setup script.
- On a sandbox host, setup applies the same file to `~/.claude/settings.json` (step
  `70-claude-config`, `AI_SANDBOX_LEAN_TOOLS`), so it covers Remote Control and local CLI
  sessions. New sessions get it; running sessions keep their tools until they restart. A deny
  rule in user settings can't be lifted for one session: set `AI_SANDBOX_LEAN_TOOLS=off` and
  re-run setup, or start a local session with `claude --setting-sources project,local` (which
  skips all user settings).
- Whatever is on `main` runs as root in every new cloud container, so keep these files free
  of secrets and review changes to them.

Tested on 2026-11-26 with one cloud session (lago-morph/ai-logs archive, session
`session_014mWQ6hFXik7peBYqR6c6ci`). The setup script wrote the settings and Claude Code used
them. Tools loaded in full went from 58 (43.5K tokens) to 14 (9.7K), and the context at the
first step from 76.6K to 31.8K. The denied MCP servers disappeared entirely, not even deferred.
Which of the four rule forms per server does it wasn't isolated; they're all kept.
Claude Docs' server instructions (about 0.5K tokens) are still added even though its tools are
denied. ScheduleWakeup (only used by `/loop`) was added to the list after that test.

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
templates/                systemd units, the ~/.claude/CLAUDE.md block, lean-tools.json
cloud/setup.sh            setup script for claude.ai/code environments
config/                   example host config
tests/run.sh              regression tests
.claude/skills/           skills for sessions in this repo
CLAUDE.md                 instructions for sessions in this repo
```
