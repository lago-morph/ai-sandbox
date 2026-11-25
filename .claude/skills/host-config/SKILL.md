---
name: host-config
description: Create, show or change this machine's ai-sandbox host config (~/.config/ai-sandbox/config) and apply it. Use when the user asks to set up or change the sandbox's name prefix, permission mode, git base dir, secrets location/backend, spawn mode, or refresh interval, or asks what the host config is.
---

# ai-sandbox host config

The host config is a Bash file, by default `~/.config/ai-sandbox/config` (`$AI_SANDBOX_CONFIG`
overrides it). It lives outside the repo. Keys and defaults are documented in
`config/ai-sandbox.conf.example` and README.md ("Configuration").

## Show
`cat ~/.config/ai-sandbox/config`. It holds no secrets, only where to find them. Point out
any keys left at their defaults.

## Create
```bash
bin/ai-sandbox-init-config AI_SANDBOX_NAME_PREFIX=<prefix> [AI_SANDBOX_KEY=value ...]
```
It refuses to overwrite an existing config; add `--force` only after showing the user the
current one and confirming. It validates the result before writing it.

## Change
1. Edit the key in place (or `bin/ai-sandbox-init-config --force` with every key the user wants
   kept, not just the new one).
2. Run `./setup.sh --check` and show the user what is pending.
3. Run `./setup.sh` to apply.
4. Settings read by Remote Control servers (`AI_SANDBOX_NAME_PREFIX`, `AI_SANDBOX_SPAWN_MODE`,
   `AI_SANDBOX_PERMISSION_MODE`, the secrets keys) only take effect when a server restarts:
   `systemctl --user restart rc@<repo>`. That drops its connected sessions, and restarting the
   ai-sandbox repo's own server ends this session. Ask first.

## Cautions
- `AI_SANDBOX_SPAWN_MODE=same-dir`, non-default `AI_SANDBOX_GIT_BASEDIR` / `AI_SANDBOX_SECRETS_DIR`,
  and `claude-oauth-token` are untested on a real host. Say so when the user picks one.
- Changing `AI_SANDBOX_GIT_BASEDIR` doesn't move existing checkouts, and this repo must be
  cloned directly inside the new dir, or setup refuses to run.
- Changing `AI_SANDBOX_NAME_PREFIX` renames the environments in claude.ai after restart; old
  names may linger in the list for a while.
- Never print secret values. Use `ai-sandbox-secret has NAME` / `describe NAME`.
