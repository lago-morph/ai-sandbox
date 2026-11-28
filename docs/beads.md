# The beads module (design)

Status: **design, not implemented.** Anything marked *verify in pilot* is an assumption until the
[pilot](#pilot) passes on this host.

## Goal

One Dolt SQL server on the machine that every `bd` client uses:

- every clone and worktree of the **same repo** reads and writes the **same** database, live;
- **different repos** use **different databases** on that server;
- every database **syncs with DoltHub**, which is the only off-machine copy and the only way
  data moves between machines. GitHub beads refs are not used.
- Cloud sandboxes (later, not in this module's first version) work the same way: their own
  local server, syncing with the same DoltHub databases.

The owner doesn't run sessions on the same repo in two places at once, so the histories should
never diverge. When they do, sync stops the server instead of merging (see
[Stopping on purpose](#stopping-on-purpose)).

## What the module installs

| Piece | Choice |
|---|---|
| `dolt` | Pinned release from GitHub (`DOLT_VERSION`, sha256-checked), in `~/.local/share/ai-sandbox/opt/dolt/<version>/`, linked as `~/.local/bin/dolt`. Upgraded per [modules.md](modules.md#upgrades). |
| `bd` | Pinned at **1.2.2** (`BD_VERSION`), the version installed today, as the npm global package `@beads/bd` (`/usr/local/bin/bd`). Setup checks the version; it installs `@beads/bd@<pin>` with `sudo npm install -g` only if `bd` is missing or the pin changes. The owner changes the pin when it's time to upgrade. |
| Server | `beads-dolt.service`: `dolt sql-server` with a config file, bound to `127.0.0.1:3307`, user `root` without a password, data dir `~/.beads/shared-server/` (one subdirectory per database). `Restart=on-failure`, enabled at boot (lingering is already on from `80-systemd`). Won't start while the [halt marker](#stopping-on-purpose) exists. |
| Sync | `beads-dolt-sync.timer` every **1 minute**, running `ai-sandbox-beads-sync` (`beads-dolt-sync.service`, oneshot). |
| Commands | `ai-sandbox-beads-sync`, `ai-sandbox-beads-status`, `ai-sandbox-beads-resume`, `ai-sandbox-beads-onboard`. |
| Logs and state | `~/.local/state/ai-sandbox/beads-sync.log`, `beads-sync.state`, and the halt marker `beads-sync-HALTED`. |
| CLAUDE.md lines | The troubleshooting rule in [Troubleshooting](#troubleshooting), added to the managed block. |

Config: `AI_SANDBOX_BEADS_DOLTHUB_OWNER` (required): the DoltHub user that owns the databases.
The port and data dir are fixed (one user per machine).

Dolt's commit identity (`dolt config --global user.name/user.email`) is set from git's.

## Credentials

Two secrets, both through the secrets backend (never printed, never logged):

| Secret | What | Used for |
|---|---|---|
| `dolthub` | DoltHub **API token** (exists today) | DoltHub's HTTP API: checking whether a database exists and creating it, in onboarding only. |
| `dolthub-creds` | Dolt **credential key** (JWK private key) | `dolt` clone, pull and push to `doltremoteapi.dolthub.com`, by the server. |

Why two: DoltHub's docs describe the API token only for the HTTP API, and there's no API
endpoint to register a credential key. A key is registered by pasting its public part into
dolthub.com → Settings → Credentials. So:

1. If `dolthub-creds` is missing, setup runs `dolt creds new`, stores the private key with the
   secrets backend, prints the **public** key, and tells the owner to add it on DoltHub. The step
   stays unsatisfied until `dolt creds check` succeeds. This is the one manual step, once per
   key; a rebuilt machine reuses the stored key.
2. If it's present, setup writes it to `~/.dolt/creds/<key id>.jwk` (mode 600) and selects it
   with `dolt creds use`.

*Verify in pilot:* whether DoltHub accepts the API token as a password for `dolt push --user`
(`DOLT_REMOTE_PASSWORD`). If it does, the credential key and the manual step can be dropped.

Cloud sandboxes get a key with the same access through their environment. A separate key per
place is recommended, so one can be revoked without the other.

## Database names

Database name = repository name (from the clone's `origin` URL, without the owner), lowercased,
with every character outside `[a-z0-9_]` replaced by `_`. The same name is used on the local
server and on DoltHub (`<owner>/<name>`). Issue prefixes are separate and unchanged; the name is
what keeps repos apart.

*Verify in pilot:* that DoltHub and `bd` accept these names as they are.

## Clients

Each clone is switched to server mode against `127.0.0.1:3307` and its database, with
`bd dolt set ...` (stored in `.beads/metadata.json`, which is gitignored). Clients must **never
start a Dolt server of their own**: if one did when the shared server is stopped, the
[halt](#stopping-on-purpose) would be bypassed and data would split.

*Verify in pilot:*

- which `bd init` / `bd dolt set` options make a clone use an external server without ever
  starting its own (`--server --external`, `--shared-server`, or both);
- whether a **new worktree** of an onboarded clone uses the server without any setup (bd may
  follow the main checkout's `.beads/`), or needs a step (a git hook, or host-wide environment
  variables for bd if 1.2.2 has them);
- whether bd commits each write to Dolt itself, or leaves changes in the working set (the sync
  commits a dirty working set before pulling, but bd should be committing).

## Sync

`ai-sandbox-beads-sync` runs every minute, under `flock` so runs never overlap. It does nothing
while the halt marker exists. For each database on the server (system databases excluded), all
through the server's SQL interface, never the `dolt` CLI on the data dir:

1. If the working set has changes, `CALL DOLT_COMMIT('-Am', 'beads sync: commit working set')`.
2. `CALL DOLT_PULL('dolthub', 'main', '--ff-only')`
3. `CALL DOLT_PUSH('dolthub', 'main')`
4. Write one line to the log: `<time> <db> ok pulled=<n> pushed=<n>`,
   `<time> <db> ok nothing to sync`, or `<time> <db> error <class> <message>`.

Fast-forward only: since the owner never works in two places at once, local and DoltHub should
never both have new commits. If they do, even if Dolt could merge them cleanly, it's treated as
an error, so it's caught right away.

### Error classes

| Class | Examples | Action |
|---|---|---|
| **hard** | Not a fast-forward (diverged) or conflicts; push rejected; authentication or permission failure; DoltHub database missing; database left mid-merge | **Halt now.** |
| **soft** | Network down, DNS, timeout, DoltHub 5xx, server not reachable, anything not recognised | Halt if soft errors continue for **15 minutes**. |
| **soft** | A database with no `dolthub` remote (created outside onboarding) | Same: halt after 15 minutes. It isn't backed up, so it must be noticed. |

The 15 minutes count from the **first failure of the current run of failures**, kept in
`beads-sync.state`, and reset by a run where every database synced. So after the laptop sleeps
overnight, a failure in the first minute after waking (network not up yet) doesn't halt
anything; only 15 minutes of continuous failed tries do.

### Stopping on purpose

A halt, in this order:

1. Write the halt marker `~/.local/state/ai-sandbox/beads-sync-HALTED`: time, database, class,
   the error message, and what to do next.
2. Write to the log: `<time> HALT <db> class=<class> reason=<message>`.
3. `systemctl --user stop beads-dolt`.

The server unit has `ConditionPathExists=!%h/.local/state/ai-sandbox/beads-sync-HALTED`, so it
won't start (at boot, by `Restart=`, or by hand) while the marker exists. A failed condition
doesn't count as a failure, so there's no restart loop, and `systemctl --user status beads-dolt`
shows the marker's path as the reason. While halted, each sync run exits at once without
logging (the HALT line is already there).

Sessions using beads then fail on their next `bd` command (connection refused), so the owner
finds out at once.

### Log size

The log gets one line per database per minute. The sync trims it to its last 7 days.

## Troubleshooting

**Rule for every session on the host** (added to the managed block in `~/.claude/CLAUDE.md`,
because a beads failure can happen in a session on any repo):

> If `bd` can't reach its server (connection refused on 127.0.0.1:3307), run
> `ai-sandbox-beads-status` **before checking anything else**. The server is stopped on purpose
> when a DoltHub sync fails, and that command says whether that happened and why. Don't restart
> the server or edit beads data to work around it; report the reason to the owner.

`ai-sandbox-beads-status` answers the question in its first line, then gives detail:

```
STOPPED ON PURPOSE by beads sync at 2026-11-27 14:02: <db> diverged from DoltHub (class=hard)
  next: see "Resolving a halt" in docs/beads.md, then ai-sandbox-beads-resume
last successful sync: 2026-11-27 14:01
recent log:
  ...
```

or `running` / `stopped (not by sync)` / `failed (not by sync)`, with the last successful sync,
the current run of failures if any, the last log lines, and the unit's last output.

### Resolving a halt

The owner decides what happens to data; a session explains the options and asks before
discarding anything.

- **Soft (network, DoltHub down):** once DoltHub is reachable, `ai-sandbox-beads-resume`.
- **Authentication:** check the credential key (`dolt creds check`), re-add it on DoltHub if it
  was removed, then resume.
- **Diverged:** with the server stopped, in `~/.beads/shared-server/<db>`:
  `dolt fetch dolthub`, then compare `dolt log main..dolthub/main` and
  `dolt log dolthub/main..main`. Then one of:
  - merge: `dolt merge dolthub/main`, resolve with `dolt conflicts`, commit;
  - keep DoltHub's: `dolt branch halt-backup-<time>` first, then
    `dolt reset --hard dolthub/main`;
  - keep local's: push it to DoltHub with `--force` (only on the owner's say).

  Then resume.

`ai-sandbox-beads-resume` refuses to start the server while a database still isn't a
fast-forward of DoltHub (or equal to it), and says which. Otherwise it removes the marker,
clears the failure state, starts the server, runs one sync, and prints the result.

## Onboarding

`ai-sandbox-beads-onboard <clone dir> [--dry-run]`. Idempotent; prints each action or "already
done"; `--dry-run` prints what it would do and changes nothing.

1. Work out the database name from `origin`. Check that the server is running and not halted.
2. **If the local server has the database:** check that its `dolthub` remote points at
   `<owner>/<name>`; go to step 5.
3. **If DoltHub has `<owner>/<name>`** (API token): `CALL DOLT_CLONE(...)` through the server,
   which preserves history.
4. **If it doesn't:**
   - If the clone already has local beads data (an embedded database with issues), **stop**:
     creating an empty database would hide that data. The owner imports it first.
   - Otherwise create `<owner>/<name>` on DoltHub as **private** (API token), create the
     database on the server, add the `dolthub` remote, initialise beads in it (`bd init` with
     the clone's prefix, against the server), push.
5. Switch the clone to server mode for this database (see [Clients](#clients)); show
   `bd dolt show`.
6. Verify: `bd ready` works; `bd` from a second worktree sees the same issues (if the repo has
   one); trigger one sync and check its log line is `ok`.
7. Warn if the repo's committed beads config still syncs to a GitHub ref, or its hooks assume
   embedded mode. Changing those belongs to that repo, not this command.

Onboarding never touches files in the repo other than the gitignored `.beads/metadata.json`.

## Upgrades

Per [modules.md](modules.md#upgrades), with these module parts:

- **`pre_upgrade`** (both tools): one sync run must succeed for every database, then each
  database gets a tag `pre-<tool>-<new version>-<time>`, pushed to DoltHub.
- **dolt `verify`:** version matches; the server starts and lists every database it had; `bd`
  reads each; one sync succeeds.
- **bd `verify`:** version matches; for each database, issue count before and after are equal
  and `bd ready` works; one sync succeeds (this pushes any schema migration bd made).
- **bd `rollback`:** reinstall the previous npm version. If the new bd migrated a schema, the old
  bd may not read it; then setup stops and prints how to restore each database from its
  `pre-bd-...` tag. Every other machine still on the old bd is affected by such a migration once
  it pulls, so the owner times bd upgrades accordingly.

## Pilot

`tests/host/beads-pilot.sh`, run on a real host once the module is installed and again after any
dolt or bd upgrade. It uses a DoltHub database kept for the purpose (`ai_sandbox_pilot`), reset at
the start of each run, because DoltHub's API has no delete.

It checks:

- the API token as a push password (decides whether `dolthub-creds` is needed);
- a throwaway git repo onboarded end to end; two clones and a worktree see each other's writes
  immediately;
- the clients never start their own server: with `beads-dolt` stopped, `bd` fails and nothing
  listens on 3307;
- whether bd commits its writes;
- the database name rules;
- sync: a write appears on DoltHub within a minute; a commit made directly on DoltHub appears
  locally; a forced divergence halts the server with the marker, the log line and the status
  output; the server stays down across `systemctl --user start` and a reboot of the unit; resume
  refuses while diverged and works once resolved;
- 15 minutes of network failure halts (with the time shortened by a test-only setting), and a
  shorter outage doesn't.

Until it passes, README.md marks the module untested.

## Not in this version

- Cloud sandboxes. The sync, status and resume commands are written to run without the rest of
  ai-sandbox (inputs through a few environment variables, no secrets backend), so `cloud/setup.sh`
  can later start a local server there, clone the repo's database from DoltHub, and run the same
  sync. Because a cloud container can be reclaimed, a sync when a session ends is worth adding in
  each repo then.
- Importing existing beads data into DoltHub: the owner does this separately.
