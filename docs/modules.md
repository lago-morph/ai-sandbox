# Modules (design)

Status: **design, not implemented.** Nothing here has run on a host yet.

## Why

The base setup (`lib/steps/`) makes a machine able to serve repos over Remote Control. A
dedicated sandbox also needs software that the repos on it share: beads and Dolt, Node, kind, and
similar. Each repo shouldn't pick its own versions of these. A **module** owns one set of
logically connected software. Its versions are pinned in this repo, in one file, and it is
installed and upgraded the same way on every host.

The first module is `beads` ([beads.md](beads.md)).

## How it works

- **`versions.toml`** (repo root) lists every module and every tool ai-sandbox installs or relies
  on, with its version. It is the one place versions are decided.
- **`AI_SANDBOX_MODULES`** (host config) says which modules this host uses.
- **`./setup.sh`** copies each listed module's files onto the host and **checks** that its tools
  match `versions.toml`. It doesn't install or upgrade tools. When something doesn't match, it
  stops with the reason and the section of the module's doc to follow.
- **An agent** (the session running setup) installs and upgrades tools, and does anything that
  touches data or an outside service, by following the module's doc. Installs and upgrades are
  rare; a careful agent with written instructions is simpler and safer than scripted upgrade
  phases with their own tests.

Setup failing is the normal way it asks for work: it prints why and what to do, the session
passes that to the owner or follows the doc, and setup is run again.

## Turning modules on

```bash
AI_SANDBOX_MODULES="beads"     # space-separated; empty (default) = no modules
```

- **Listed** = setup copies its files and checks it.
- **Not listed** = setup ignores it. It is **never uninstalled**: removing a name from the list
  (on purpose or by a typo) leaves everything on the host as it is. There is no uninstall path.
  A module that was installed once stays covered by its CLAUDE.md lines, skill and status entry
  (setup records installed modules in `~/.local/state/ai-sandbox/modules-installed`), so a
  service that is still running stays explained. `ai-sandbox-status` shows it as "installed, not
  listed".
- **Unknown name** = setup stops before running any step, listing the known modules.
- **`requires`** = a module can name modules it needs. If one isn't listed, setup stops and says
  so. It's a check only: it doesn't turn the other module on or change the order of anything.

## versions.toml

One entry per module and one per tool. A tool belongs to exactly one module; TOML rejects a key
defined twice, so a tool can't be pinned in two places. `base` is the base setup itself: always
on, not listed in `AI_SANDBOX_MODULES`, and its tools are checked by the base platform step. The
Claude CLI isn't pinned (it updates itself).

```toml
[modules.beads]
description = "Shared Dolt server for beads, synced with DoltHub"
requires    = []

[tools.dolt]
module  = "beads"
version = "==1.xx.y"
source  = "github:dolthub/dolt"
asset   = "dolt-{platform}.tar.gz"
sha256.linux-amd64 = "…"

[tools.bd]
module  = "beads"
version = "==1.3.4"
source  = "github:gastownhall/beads"
asset   = "beads_{version}_{platform}.tar.gz"
platforms = { linux-amd64 = "linux_amd64", linux-arm64 = "linux_arm64" }
sha256.linux-amd64 = "…"

[tools.jq]
module  = "base"
version = ">=1.6"
source  = "system"
```

**Versions** use Python's specifier syntax (as in `pyproject.toml`), limited to `==X`, `>=X`, and
a comma meaning "and" (`>=1.6,<2`). Tools ai-sandbox installs are pinned exactly (`==`); tools the
distro provides get a minimum (`>=`), because different hosts may run different distros.

**Sources:**

| `source` | Installed how (by the agent, per the module doc) | Version | Integrity |
|---|---|---|---|
| `github:<owner>/<repo>` | release asset → `~/.local/share/ai-sandbox/opt/<tool>/<version>/`, linked as `~/.local/bin/<tool>` | `==` | `sha256.<platform>` in the file |
| `url:<template>` | same, for other downloads (e.g. Node from nodejs.org) | `==` | `sha256.<platform>` in the file |
| `npm:<package>` | `npm install -g --prefix ~/.local/share/ai-sandbox/npm <pkg>@<ver>`, binaries linked in `~/.local/bin`, no sudo | `==` | npm registry integrity |
| `pypi:<package>` | `uv tool install <pkg>==<ver>` | `==` | PyPI hashes (uv) |
| `system` | the distro package, installed by the base platform step | `>=` | the distro |

- `npm:` tools need a `node` entry and `pypi:` tools a `uv` entry, both pinned. pip isn't used
  directly.
- Nothing managed runs bare `npx <pkg>`: install the package with `npm:` and call its command, or
  run `npx <pkg>@<pinned version>`.
- The sha256 is the digest of the downloaded asset, taken from the release's published digest or
  checksum file **when the pin is written**, and committed. It's never fetched at install time.
- Old versions stay in `opt/<tool>/` (the current and previous one at least), so going back
  doesn't need a download.

**Platforms** come from `uname -m`: `x86_64` → `linux-amd64`, `aarch64` → `linux-arm64`.
`{platform}` in `asset` is replaced by the tool's own name for it (`platforms` table, default
the same name). Only `linux-amd64` checksums are recorded today; adding arm64 (a Raspberry Pi, a
Graviton instance) is one more `sha256.linux-arm64` line per tool. A host whose platform has no
checksum fails the check with that reason. 32-bit ARM isn't supported.

**Scope:** only what ai-sandbox and its modules install or need. A repo's own dependencies
(`package.json`, `pyproject.toml`) are that repo's business.

The file is read with python3 and `tomli` (the platform step installs the distro's
`python3-tomli`), on every Python version.

## Layout

```
versions.toml            modules and tool versions (data)
modules/<name>/
  claude.md              lines for the managed block in ~/.claude/CLAUDE.md
  settings.json          entries merged into ~/.claude/settings.json (e.g. deny rules), optional
  bin/                   commands installed into ~/.local/bin as ai-sandbox-<name>-*
  steps/NN-*.sh          the module's own setup steps (same check/apply contract as lib/steps/)
  skills/<skill>/        Claude skills installed for every session on the host, optional
  templates/             units, config files
docs/<name>.md           the module's doc: what it is, and the agent's instructions
```

Configuration and code are kept apart: `versions.toml`, `claude.md` and `settings.json` are data,
never run. Everything executable is under `bin/` and `steps/`. Steps do only what is safe to
repeat without an agent (install a config file, enable a unit, set up a credential); installing
or upgrading tools, and anything touching data, stays in the module doc.

Setup copies these from **whichever checkout runs it** (as the base setup does), into
`~/.local/share/ai-sandbox/modules/<name>/`, `~/.local/bin`, `~/.claude/skills/` and
`~/.config/systemd/user/`. Running setup from a branch on purpose installs that branch's files;
deleting the worktree afterwards doesn't break anything.

Files that the base setup owns are written by the base step that owns them, which merges in each
installed module's part: step 70 appends each module's `claude.md` to the managed block and merges
its `settings.json` entries (tagged `(ai-sandbox:<name>)`, like the existing rules). Modules never
edit those files themselves. All module files are files setup manages (add them to the list in
CLAUDE.md).

## What setup does

Before any step, an unknown module name stops setup. Then `versions.toml` is validated, every
listed module must have its `[modules.<name>]` entry, and its `requires` must be listed (on a fresh
host, where the packages step hasn't installed `python3-tomli` yet, this part runs after the base
steps).

1. Base step `35-modules` copies each listed module's files (above) and records it as installed.
   Step `70-claude-config` then adds every installed module's `claude.md` and `settings.json`.

For each listed module, in list order, after the base steps:

2. Check every tool of the module against `versions.toml`. Results, one per tool:
   - `ok dolt 1.xx.y`
   - `missing dolt` / `upgrade dolt 1.xx.y -> 1.zz.w` / `newer-than-pin dolt 1.zz.w > 1.xx.y` /
     `too-old jq 1.5 (needs >=1.6)` / `no-checksum dolt linux-arm64`

   Anything but `ok` stops setup with the reason and the doc section to follow, e.g.
   `dolt 1.xx.y installed, pin is 1.zz.w: follow docs/beads.md#upgrading`. The installed version
   of an `opt/` tool is the version directory `~/.local/bin/<tool>` points at.
3. Run the module's own steps (`modules/<name>/steps/`, shown as `<name>/<step>`), which also stop
   with a reason when they can't do their part.

`./setup.sh --check` reports all of this without changing anything. `ai-sandbox-versions` prints
every listed module's tools with pinned and installed versions.

## Module docs

`docs/<name>.md` is written for the owner and for an agent. It has at least these sections:

- **Installing** and **Upgrading**: the exact steps, which commands to run, what to check before and
  after each, and where to stop and ask the owner (anything that discards data, or that can't be
  undone, like a schema migration that will be pushed).
- **Rolling back**: how to get back to the previous version, and when that is no longer possible.
- **Credentials**: each one's variable, file and where to get or register it.
- **Troubleshooting**: what the module stops on purpose, likely causes, how to resolve each.

Rules for every install and upgrade:

- A version changes only when `versions.toml` changes (by PR). Nothing installs "latest", and no
  timer upgrades anything.
- Check the sha256 before installing anything.
- Install side by side in `opt/<tool>/<version>/`, then switch the link; keep the previous version.
- If the installed version is newer than the pin, stop and ask the owner. Don't downgrade.
- Verify with local checks first (version, the service runs, it reads its data). Steps that need
  the network come after.
- Append one line to `~/.local/state/ai-sandbox/upgrades.log`:
  `<time> <module> <tool> <from> -> <to> ok|rolled-back|failed <reason> <checkout> <commit>`.

## Troubleshooting entry points

The usual way something gets diagnosed: the owner opens a session (on this repo, or on the repo
where something broke) and says "figure out what went wrong". So every module provides:

- **`docs/<name>.md`** with a `## Troubleshooting` section, near the top.
- **`ai-sandbox-<name>-status`**: its first line says whether the module is healthy and, if
  something was stopped on purpose, that it was and why. Exit 0 healthy, 1 unhealthy, 2 stopped
  on purpose.
- **A skill**, if sessions on other repos set up or use the module's software, covering setup in a
  repo and troubleshooting from there. It reads `docs/<name>.md` from this repo's checkout
  (`<git base dir>/ai-sandbox`), or clones it shallowly into a temporary directory to read, if
  there's none.

Pointers that lead there:

1. **`ai-sandbox-status`**: runs every installed module's status and prints one line per module,
   then the detail for any that aren't healthy, with a pointer to the doc. `--brief` prints only
   problems, and nothing when all is well.
2. **A SessionStart hook** in `~/.claude/settings.json` (setup-managed) runs
   `ai-sandbox-status --brief`, so every session starts with a line about any problem, even
   sessions that don't use the module. It reads only local files (no network, no SQL), takes well
   under a second and never fails the session.
3. **This repo's CLAUDE.md** gets a "Troubleshooting the host" entry: *When asked what went
   wrong on this host, run `ai-sandbox-status` first, before reading service logs or changing
   anything; then follow the module's `docs/<name>.md` Troubleshooting section. Services can be
   stopped on purpose, and those stops are the first thing to rule out.*
4. **The managed block in `~/.claude/CLAUDE.md`** carries each installed module's lines.

## Credentials

A module that needs a credential (or an account name that goes with one) reads it from, in order:

1. **An environment variable**, named by the providing service's convention where it has one;
   otherwise the module documents the name it uses. Cloud sandboxes provide credentials this way.
2. **The secrets backend** (default: a file in `~/.secrets/`), through `secret_get`.
3. Neither: setup stops and says what to provide and where to get it; a running service halts.

If both exist and differ, setup stops and names both places (it compares them without printing
either). It logs which source it used. Credentials are never printed or logged. Services run by
systemd don't see a session's environment variables, so on a host they use what setup stored.

## Tests

`tests/run.sh` (throwaway `$HOME`, no network) covers the framework: reading `versions.toml`;
`==`, `>=` and comma constraints; an unknown module name stops setup; a missing `requires` stops
setup; a de-listed module's files are left alone and it stays in status; each check result above
(missing, upgrade, newer-than-pin, too-old, no-checksum) stops setup with its message; platform
mapping; credentials from env, file, neither, and both-differ.

Each module also has a pilot under `tests/host/` that runs against real software on a real host
(for beads, see [beads.md](beads.md#pilot)).
