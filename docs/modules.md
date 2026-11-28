# Modules (design)

Status: **design, not implemented.** Nothing here has run on a host yet.

## Why

The base setup (`lib/steps/`) makes a machine able to serve repos over Remote Control. A
dedicated sandbox also needs software that the repos on it share: beads and Dolt, kind, and
similar. Each repo shouldn't pick its own versions of these. A **module** owns one set of
logically connected software, pins its versions in this repo, installs it, and upgrades it
safely.

The first module is `beads` ([beads.md](beads.md)).

## Turning modules on

One host config key:

```bash
AI_SANDBOX_MODULES="beads"     # space-separated; empty (default) = no modules
```

Rules:

- **Listed** = setup installs, checks and upgrades it.
- **Not listed** = setup ignores it. It is **never uninstalled**: removing a name from the list
  (on purpose or by a typo) leaves everything on the host as it is. There is no uninstall code
  path in any module.
- **Unknown name** = setup stops before running any step, listing the known modules. A typo
  fails loudly instead of quietly skipping a module.
- **Dependencies** = a module can declare `requires="other"`. If a required module isn't listed,
  setup stops and says so. It doesn't turn the other module on by itself.

## Layout

```
modules/<name>/
  module.sh        description, requires=..., and the module's CLAUDE.md lines (optional)
  versions.sh      the pins (see below); the only place this module's versions are set
  steps/NN-*.sh    check/apply steps, same contract as lib/steps/
  bin/             commands installed into ~/.local/bin as ai-sandbox-<name>-*
  templates/       units, config files
```

`setup.sh` runs the base steps, then each listed module's steps in order, named
`<module>/<step>` in the output and in `setup.log`. `./setup.sh --check` covers modules too.
Module commands and units are files setup manages (add them to the list in CLAUDE.md).

A module can add lines to the managed ai-sandbox block in `~/.claude/CLAUDE.md` (for example, how
to troubleshoot its services). They appear only while the module is listed.

## Troubleshooting entry points

The usual way something gets diagnosed: the owner opens a session against this repo and says
"figure out what went wrong". That session has to land on the right command and document without
being told which module failed. So every module provides:

- **`docs/<name>.md`** with a `## Troubleshooting` section: what the module stops or refuses on
  purpose, its likely causes, and how to resolve each. (This design doc becomes that document.)
- **A `status` function** (and an `ai-sandbox-<name>-status` command) whose first line says
  whether the module is healthy and, if something was stopped on purpose, that it was and why.

Three pointers lead there:

1. **`ai-sandbox-status`** (new, part of the framework): runs every listed module's `status`
   and prints a one-line summary per module, healthy ones included, then the detail for any that
   aren't, each with a pointer to `docs/<name>.md#troubleshooting`. One command to run first.
2. **This repo's CLAUDE.md** gets a "Troubleshooting the host" entry: *When asked what went
   wrong on this host, run `ai-sandbox-status` first, before reading service logs or changing
   anything; then follow the module's `docs/<name>.md` Troubleshooting section. Services can be
   stopped on purpose, and those stops are the first thing to rule out.*
3. **The managed block in `~/.claude/CLAUDE.md`** (every session on the host, any repo) carries
   each listed module's short rule, ending with the absolute path of its document in the main
   checkout (`<git base dir>/ai-sandbox/docs/<name>.md`), since sessions in other repos can't
   see this repo's relative paths.

## Pinning

`modules/<name>/versions.sh` sets exact versions and, for downloads, a sha256 per platform:

```bash
DOLT_VERSION=1.xx.y
DOLT_SHA256_LINUX_AMD64=...
BD_VERSION=1.2.2
```

- A version changes only when its pin changes in this repo (by PR). Nothing ever installs
  "latest", and no timer upgrades anything; the host changes only when `./setup.sh` runs.
- Downloads are checked against the sha256 before anything is installed.
- `ai-sandbox-versions` prints every listed module's pins next to what's installed: the one
  place to see the versions on this host.

## Upgrades

Every module that installs versioned software implements an upgrade, and setup verifies it.

`check` compares installed with pinned and reports one of:

- `ok dolt 1.xx.y`
- `upgrade dolt 1.xx.y -> 1.zz.w` (step needs work)
- `missing dolt` (step needs work)
- `newer-than-pin dolt 1.zz.w > 1.xx.y` (step needs work, and apply will refuse; see below)

`apply`, when installed differs from pinned, runs these phases. Each module supplies the
module-specific parts as functions:

1. **`pre_upgrade`**: make the upgrade safe to undo. For data-bearing software, this means a
   fresh off-machine copy and a restore point (for beads: a successful sync to DoltHub, then a
   Dolt tag). If it fails, nothing has been changed and setup stops.
2. **Install side by side**: the new version goes into
   `~/.local/share/ai-sandbox/opt/<tool>/<version>/`; the old one stays where it is.
3. **Switch**: stop the services that use it, point `~/.local/bin/<tool>` at the new version.
   (Tools installed another way, such as an npm global package, are switched by reinstalling
   the pinned version; the module's `rollback` reinstalls the previous one.)
4. **`verify`**: the version string matches the pin, **and** a functional smoke test passes
   (for beads: the server starts, it lists every database, `bd` reads a database, and one sync
   succeeds).
5. **Roll back on failure**: if switching or `verify` fails, point back at the previous version
   (or run `rollback`), restart the services, re-run `verify` for the old version, and stop
   setup with the error. If the upgrade migrated data and can't be undone in place, `rollback`
   says how to restore from the `pre_upgrade` restore point, and setup stops without trying.
6. **`post_upgrade`**: optional cleanup. Old versions in `opt/` are kept (the last 2) so a
   rollback never needs a download.

Rules:

- **No automatic downgrades.** If the installed version is newer than the pin (someone upgraded
  by hand), apply refuses and says so. Going back may be unsafe (for example, after a schema
  migration); the owner decides, then either raises the pin or downgrades by hand.
- Every upgrade attempt is logged to `~/.local/state/ai-sandbox/upgrades.log`:
  `<time> <module> <tool> <from> -> <to> ok|rolled-back|failed <reason>`.
- `./setup.sh --check` lists pending upgrades, so the owner sees them before running setup.

## Tests

`tests/run.sh` (throwaway `$HOME`, no network) covers the framework with fake tools:
an unknown module name stops setup; an unlisted module is skipped and nothing is removed; a
missing dependency stops setup; a failing `verify` rolls back and setup exits non-zero; a newer
installed version is refused; a bad sha256 is refused before anything changes.

Each module also has a host test under `tests/host/` that runs against real software (for
beads, the pilot in [beads.md](beads.md#pilot)).

## Open questions

- Pins per module (`modules/<name>/versions.sh`, proposed above) or one repo-wide
  `versions.sh`? Per module keeps modules self-contained; `ai-sandbox-versions` gives the single
  view either way.
