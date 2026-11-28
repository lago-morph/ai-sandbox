# The beads module (design)

Status: **design, not implemented.** Anything marked *pilot* is an assumption until the
[pilot](#pilot) passes on this host.

## Goal

One Dolt SQL server on the machine that every `bd` client uses:

- every clone and worktree of the **same repo** reads and writes the **same** database, live;
- **different repos** use **different databases** on that server;
- every database **syncs with DoltHub**, which is the only off-machine copy and the only way data
  moves between machines. GitHub beads refs are not used.
- A repo that has no DoltHub database stays in bd's **embedded mode** (its own database inside
  the clone, no server). It isn't synced or backed up, and it never touches the shared server.
- Cloud sandboxes (later, not in this module's first version) work the same way: their own local
  server, syncing with the same DoltHub databases.

How it's used: the laptop host is the primary environment. Cloud sandboxes and other machines
are used only while the laptop is unavailable (off, asleep, offline or broken), never at the same
time as it. So writes come from one place at a time, and the histories should never diverge.
When they do, the sync stops the server instead of merging (see
[Stopping on purpose](#stopping-on-purpose)). There's no extra logic for handing over between
places; the likely causes of a stop are listed under [Troubleshooting](#troubleshooting).

## Troubleshooting

Start here when beads isn't working. How a session gets here: the SessionStart note, the
[rule every session sees](#what-every-session-is-told), the `beads-onboarding` skill, or
`ai-sandbox-status` on this repo (see [modules.md](modules.md#troubleshooting-entry-points)).

**First, `ai-sandbox-beads-status`.** Its first line answers whether the server was stopped on
purpose:

```
STOPPED ON PURPOSE by beads sync at 2026-11-27 14:02: ai-sandbox diverged from DoltHub (class=hard)
  also failing: other-repo (class=hard, auth)
  don't restart it; see "Resolving a halt" in docs/beads.md
last successful sync: 2026-11-27 14:01
recent log:
  ...
```

or `STOPPED ON PURPOSE for an upgrade at <time> (<who>)`, `running`, `running, last sync
<n> min ago` (no successful sync for a while, not yet halted), `stopped (not on purpose)`, or
`failed (not on purpose)`, each with a `next:` line, the last log lines and the unit's last output.
With a repo directory (`ai-sandbox-beads-status <dir>`) it adds that clone's settings: mode,
server address, database, and whether the database exists on the server.

A stop on purpose stops beads for **every** repo on the host; that's intended, so nothing keeps
writing while it isn't synced.

### Likely causes

These follow from how the owner works (laptop first, cloud sandboxes or other machines only
while the laptop is unavailable).

- **Diverged after a handover.** The laptop went away with commits it hadn't pushed yet (up to a
  minute's worth). Work continued in a cloud sandbox from DoltHub's older copy. When the laptop
  came back, its first sync found new commits on both sides. Look for: a HALT `diverged` shortly
  after the laptop came back; the local-only commits are from just before it went away.
- **Diverged on wake.** After work elsewhere, a session on the laptop wrote to beads in the
  minute between waking (or booting) and the laptop's first sync. Look for: local-only commits
  from just after the laptop came back. (Accepted: sessions rarely use beads within a minute of
  wake or boot.)
- **Diverged the other way.** A cloud sandbox started while the laptop still had unpushed work.
  Look for: the halt is in the cloud sandbox.
- **Offline too long.** No network (or DoltHub down) for 15 minutes while running. Look for: a
  HALT after a run of `class=soft` errors.
- **Credential key removed or expired** on DoltHub. Look for: `class=hard` auth.
- **A database without a DoltHub remote** on the server (for example a repo set up with a plain
  `bd init --server` instead of through the skill). Look for: HALT `no dolthub remote`. That repo
  should either be onboarded or go back to embedded mode.
- **The sync itself failed** (a bug, a crash). Look for: HALT `class=sync-failed` and the sync
  unit's output.

### Resolving a halt

The owner decides what happens to data. A session explains the cause and the options, and asks
before anything that discards or overwrites data.

- **Soft (network, DoltHub down):** once DoltHub is reachable, `ai-sandbox-beads-server resume`.
- **Auth:** check the key (`dolt creds check`), re-add the public key on DoltHub if it was
  removed, then resume.
- **No DoltHub remote:** onboard the repo through the skill, or (owner's choice) move it back to
  embedded mode and drop the database from the server; then resume.
- **Diverged** (server is stopped). First, back up: `cp -a` the database directory
  (`~/.local/share/ai-sandbox/data/beads/<db>`) next to it. Then in that directory:
  `dolt fetch dolthub`, and compare `dolt log main..dolthub/main` with `dolt log dolthub/main..main`.
  Then one of:
  - merge: `dolt merge dolthub/main`, resolve with `dolt conflicts`, commit;
  - keep DoltHub's: `dolt branch halt-backup-<YYYYMMDDTHHMM>` and
    `dolt push dolthub halt-backup-<…>` first, then `dolt reset --hard dolthub/main`;
  - keep local's (only on the owner's say): push `dolthub/main` to a branch
    `halt-backup-remote-<…>` first, then `dolt push --force dolthub main`.

  Then resume.

`ai-sandbox-beads-server resume` is the only thing that removes the halt marker, and only when the
owner says so. It refuses while any database is not equal to, behind, or ahead of DoltHub (after
a fresh fetch), and says which. Otherwise it removes the marker, clears the failure count, starts
the server, runs one sync and prints the result.

**Server down, not on purpose** (no marker): show the owner the status and the unit's output;
with their OK, `ai-sandbox-beads-server start`. The script refuses if a marker exists, so this
can't override a halt.

## What the module installs

| Piece | Choice |
|---|---|
| `dolt` | `versions.toml`: `github:dolthub/dolt`, `==` the latest stable release at implementation time, sha256-pinned. In `~/.local/share/ai-sandbox/opt/dolt/<version>/`, linked as `~/.local/bin/dolt`. |
| `bd` | `versions.toml`: `github:gastownhall/beads`, `==1.3.4`, sha256-pinned. A self-contained binary (no node), in `opt/bd/<version>/`, linked as `~/.local/bin/bd`. |
| Server | `beads-dolt.service` runs `ai-sandbox-beads-server run`: `dolt sql-server` with a config file, data dir `~/.local/share/ai-sandbox/data/beads/` (one subdirectory per database), listening on **127.0.1.1:3307**, user `root` without a password. `Restart=on-failure`, enabled at boot (lingering is already on). See [The server script](#the-server-script). |
| Sync | `beads-dolt-sync.timer` every **1 minute** (`OnBootSec=1min`, `Persistent=false`), running `ai-sandbox-beads-sync` (`beads-dolt-sync.service`, oneshot, `OnFailure=` halts). |
| Commands | `ai-sandbox-beads-server`, `ai-sandbox-beads-sync`, `ai-sandbox-beads-status`, `ai-sandbox-beads-init`. |
| Skill | `beads-onboarding`, in `~/.claude/skills/`, for every session on the host. See [The beads-onboarding skill](#the-beads-onboarding-skill). |
| CLAUDE.md lines | [What every session is told](#what-every-session-is-told), in the managed block. |
| Settings | Deny rules in `~/.claude/settings.json` (see [What every session is told](#what-every-session-is-told)). |
| bd host config | `~/.config/bd/config.yaml` with `dolt.auto-start: false`. |
| Logs and state | `~/.local/state/ai-sandbox/beads-sync.log`, `beads-sync.state`, the halt marker `beads-sync-HALTED`. |

Why 127.0.1.1: bd 1.3.4 treats a server whose host isn't `localhost`, `127.0.0.1`, `::1` or
`0.0.0.0` as external, and then refuses to start a server of its own (auto-start and
`bd dolt start`). Any 127.x address is this machine's loopback, so nothing else changes. *Pilot.*

Why not `~/.beads/shared-server/`: that is bd's own directory for its shared-server mode (its pid,
port and lock files, port 3308). Our server must not share it.

Dolt's commit identity is set from git's (`dolt config --global user.name/user.email`), and the
sync passes it as `--author`, since commits made through SQL are otherwise authored by `root`.

**Prerequisite:** before the module is installed, the owner removes the current npm install
(`sudo npm uninstall -g @beads/bd`), so `/usr/local/bin/bd` (a node wrapper) doesn't shadow the
pinned one.

**Known limitation (bd 1.3.4):** bd keeps its `events` table (the per-change audit log read by
`bd history --events` and `bd provenance`) local to each database, through Dolt's `dolt_ignore`.
It's stored on disk with the database but never committed or synced. Issues, comments, labels
and dependencies sync normally. After a rebuild, or in a cloud sandbox, that audit log is empty
for past work. Accepted; don't change bd's `dolt_ignore`.

## Credentials

Per [modules.md](modules.md#credentials): environment variable, then the secrets backend, else
setup stops; if both exist and differ, setup stops. Never printed, never logged.

| What | Environment variable | Secret (default: file in `~/.secrets/`) | Used for |
|---|---|---|---|
| DoltHub **account** name | `DOLTHUB_ACCOUNT` (our name) | `dolthub-account` | Onboarding: the `<account>/<db>` address. |
| DoltHub **API token** | `DH_TOKEN` (our name) | `dolthub` | Onboarding only: checking whether a database exists and creating it (DoltHub API v2, `Authorization: Bearer`). |
| Dolt **credential key** (JWK) | `DOLT_CREDS_JWK` (the key file's contents; our name) | `dolthub-creds` | Every clone, fetch, pull and push, by the server. |

The sync needs none of these at run time: each database stores its DoltHub address, and the
server signs requests with the key Dolt holds in `~/.dolt/creds/`.

**The credential key.** Setup puts it where Dolt reads it with `dolt creds import` (from stdin)
and selects it with `dolt creds use`; setup also stops if `~/.dolt/creds/` holds a different key.
If no key exists anywhere (environment, secret, `~/.dolt/creds/`), setup creates one with
`dolt creds new`, stores the private key as `dolthub-creds`, prints the **public** key and this
link: **https://www.dolthub.com/settings/credentials** (fields: Public key, Description), and
stops. DoltHub has no API to register a key, so the owner pastes it there, once per key; then
setup is run again and passes once `dolt creds check` succeeds. A rebuilt machine reuses the
stored key. A separate key per place (laptop, each cloud sandbox) is recommended, so one can be
revoked without the other. API tokens are at https://www.dolthub.com/settings/tokens.

*Pilot:* whether DoltHub accepts the API token as a push password (`DOLT_REMOTE_PASSWORD`, which
would have to be in the server's environment, with `--user` on every remote call). If it does, the
key and the manual step can be dropped.

## Database names

Database name = the repository's name (the last part of the clone's `origin` URL, without the
GitHub owner), lowercased. Repo `lago-morph/ai-sandbox` → database `ai-sandbox`, both on the local
server and on DoltHub, where its address is `<account>/ai-sandbox`
(`https://www.dolthub.com/repositories/<account>/ai-sandbox`). The account is part of the address,
not of the name.

Hyphens are kept: Dolt keeps directory names as database names (never set
`DOLT_DBNAME_REPLACE`), DoltHub allows letters, digits, `-` and `_`, and bd allows hyphens in
server mode when the database is named explicitly. SQL quotes the name with backticks. *Pilot:*
every bd command works with a hyphenated name.

Names bd treats as test databases are refused (it may drop them): names starting `testdb_`,
`beads_test`, `beads_pt`, `beads_vr`, `benchdb_`, `doctest_`, `doctortest_`.

Issue prefixes are separate and unchanged.

## Clients

An onboarded clone gets `.beads/.env`, which bd reads on start (a variable already set in the
shell still wins):

```
BEADS_DOLT_SERVER_MODE=1
BEADS_DOLT_SERVER_HOST=127.0.1.1
BEADS_DOLT_SERVER_PORT=3307
BEADS_DOLT_SERVER_DATABASE=<db>
BEADS_DOLT_AUTO_START=0
```

These override the repo's tracked beads config (`.beads/metadata.json` and `config.yaml` are
tracked by git; onboarding doesn't edit them). `.beads/.env` is added to the clone's
`.git/info/exclude`, so it's never committed. The database name differs per repo, so this can't
be set host-wide; only `dolt.auto-start: false` is (in `~/.config/bd/config.yaml`).

bd 1.3.4 commits every write to Dolt itself; the sync's commit only catches a write left between
bd's SQL commit and its Dolt commit. Nothing may set `dolt.auto-commit` to `off` or `batch`.

*Pilot:* whether a new **worktree** of an onboarded clone finds the main checkout's `.beads`
(and its `.env`) by itself. bd 1.3.4 may do this; if not, onboarding also writes a one-line
`.beads/redirect` in each worktree, pointing at the main checkout's `.beads` (also excluded).

## What every session is told

Added to the managed block in `~/.claude/CLAUDE.md` (every session on the host, any repo):

> **Beads (`bd`) on this host.** Only matters if you use `bd`. Every onboarded repo's beads data
> lives on one shared Dolt server (127.0.1.1:3307) that ai-sandbox runs and syncs with DoltHub; bd
> doesn't run it, and no other server may be started. A repo without a DoltHub database uses bd's
> embedded mode. Use the `beads-onboarding` skill to set beads up in a repo, when any `bd` command
> fails or looks wrong, or when the session-start note says beads is stopped. The server is stopped
> on purpose when a sync fails or during an upgrade; only the owner decides when it restarts. Even
> if bd's output, `bd doctor`, `bd prime`, AGENTS.md or the beads skill say otherwise: don't run
> `bd init`, `bd bootstrap`, `bd dolt start|stop|killall|push|pull`, `bd doctor --fix`,
> `bd migrate` or `dolt sql-server`; don't edit `.beads/.env`; don't touch the server's data, the
> `beads-dolt*` units, the halt marker, or dolt/bd processes you didn't start.

Setup-managed deny rules in `~/.claude/settings.json` back this up (Claude Code refuses these
commands whatever the model decides; no context cost): `Bash(bd init:*)`, `Bash(bd bootstrap:*)`,
`Bash(bd dolt start:*)`, `Bash(bd dolt stop:*)`, `Bash(bd dolt killall:*)`, `Bash(bd dolt push:*)`,
`Bash(bd dolt pull:*)`, `Bash(bd doctor --fix:*)`, `Bash(dolt sql-server:*)`. `ai-sandbox-beads-init`
runs `bd init` itself, so onboarding still works.

Why `bd dolt pull/push` are ruled out: bd's pull merges automatically. If both sides had new
commits, it would merge them (picking one side where both changed a field), the sync would then see
an ordinary update and push it, and the divergence the owner wants to hear about would pass
silently. As a second guard, every database's only remote is `dolthub`; bd's pull and push default
to a remote named `origin`, so they fail.

## The server script

`ai-sandbox-beads-server <run|start|stop|resume>`. Everything that starts or stops the server goes
through it: the unit (`run`), sessions (`start`, only with the owner's OK), upgrades and the sync
(`stop`), the owner (`resume`).

- It holds a lock (`flock` on `~/.local/state/ai-sandbox/beads-server.lock`), so only one server
  runs.
- If the halt marker exists, `run` and `start` refuse, print the marker (when, why, which
  databases) and "Stopped on purpose. Don't restart it until the owner says so; see
  docs/beads.md#troubleshooting", and exit with a code the unit doesn't restart on
  (`RestartPreventExitStatus=`), so there's no restart loop.
- `stop <reason>` writes the marker with the reason (a halt, or "upgrade in progress by <who>"),
  then stops the unit. An upgrade is a stop on purpose like any other, so status, the
  SessionStart note and the sync all see it the same way.
- `start --upgrade` starts the server while the marker's reason is an upgrade, so the upgrading
  agent can migrate and verify while the sync stays paused. It refuses for any other marker.
- `resume` is described under [Resolving a halt](#resolving-a-halt).

## Sync

`ai-sandbox-beads-sync` runs every minute from the timer, under its own `flock`, and exits at once
(non-zero) while the halt marker exists. For each database on the server (from `SHOW DATABASES`,
excluding `information_schema` and `mysql`), through the server's SQL interface:

1. The database's only remote must be `dolthub`; otherwise it's an error (no remote, or another
   one).
2. `CALL DOLT_COMMIT('-A', '--skip-empty', '--author', '<git identity>', '-m', 'beads sync')`.
3. `CALL DOLT_FETCH('dolthub', 'main')`.
4. Count commits each way: `dolt_log('main..dolthub/main')` (behind) and
   `dolt_log('dolthub/main..main')` (ahead). Both above zero = **diverged**, decided before
   anything changes.
5. Behind: `CALL DOLT_MERGE('--ff-only', 'dolthub/main')`. Ahead: `CALL DOLT_PUSH('dolthub', 'main')`.
6. Log one line: `<time> <db> ok behind=<n> ahead=<n>` or `<time> <db> error <class> <message>`.

It finishes every database before acting on errors, so healthy ones are still pushed, then
halts if needed, listing every failing database. The same fetch-and-count check is used by
`resume`.

Since the owner never works in two places at once, local and DoltHub should never both have new
commits; if they do, even when Dolt could merge them cleanly, it's treated as an error so it's
caught right away.

Timing: after boot or wake, the first sync runs within about a minute (one more minute if the
network isn't up on the first try). Writes in that window are the "diverged on wake" case above.

### Error classes

| Class | Examples | Action |
|---|---|---|
| **hard** | Diverged or conflicts; push rejected after a fresh fetch; authentication or permission failure; DoltHub database missing; a database with no `dolthub` remote, or with another remote; database left mid-merge; the sync itself crashing (`class=sync-failed`, via `OnFailure=`) | **Halt now.** |
| **soft** | Anything that can't connect: network down, DNS, timeout, DoltHub 5xx, our server not reachable; also a push that lost a race ("target updated") and a pull refused because of a write in progress | **Halt after 15 minutes** of continuous failure. |

The 15 minutes count from the first failure of the current run of failures, kept in
`beads-sync.state` (written atomically; an unreadable file counts as "failing since now", never as
a reset), and reset by a run where every database synced. A halt needs **both** 15 minutes **and**
at least 15 failed runs in a row, and the count restarts if more than 3 minutes passed since the
previous run (the laptop was asleep). So one failure just before sleep and one just after wake
doesn't halt anything.

### Stopping on purpose

A halt: write the marker `~/.local/state/ai-sandbox/beads-sync-HALTED` (time, class, every
failing database with its message, what to do next), log `<time> HALT <db,...> class=<class>
reason=<message>`, then `ai-sandbox-beads-server stop`. Sessions using beads then fail on their
next `bd` command (connection refused), and every new session's SessionStart note says beads is
stopped, so the owner finds out either way.

The log gets one line per database per minute; the sync trims it to its last 7 days, under its
lock.

## The beads-onboarding skill

Installed into `~/.claude/skills/beads-onboarding/` for every session on the host. Named
`beads-onboarding`, not `beads`, so it doesn't collide with the beads project's own `beads` skill.
Description:

> Set up or fix beads (`bd`) on this ai-sandbox host. Use when asked to set up, add or init beads
> in a repo, or when any `bd` command fails or misbehaves: connection refused on 127.0.1.1:3307,
> database not found, read-only, missing or unexpected issues, or a new worktree that shows no
> issues. Use this instead of `bd init`, `bd dolt start`, `bd doctor --fix` or the beads skill's
> setup steps, which must not be run on this host.

**Step 0, always:** if `ai-sandbox-beads-status` isn't on PATH, this isn't an ai-sandbox beads host.
Don't install, initialise or start anything; tell the owner and stop.

### Troubleshooting from a repo

1. Run `ai-sandbox-beads-status <repo dir>`. If it says STOPPED ON PURPOSE, that is the cause; skip
   the usual checks.
2. Read [Troubleshooting](#troubleshooting) in this repo's checkout (`<git base dir>/ai-sandbox`,
   or a shallow clone into a temporary directory if there's none) and match the status and log
   against the likely causes.
3. Explain the cause and the options to the owner. Ask before anything that discards or overwrites
   data, and before removing the halt.

### Onboarding a repo

Only when the owner asks. Instructions for the agent; tell the owner what you're about to do at
each step that changes something outside the clone.

1. Work out `<db>` from `origin` (see [Database names](#database-names)). Check that the server is
   running and not stopped on purpose.
2. If the clone has beads data in embedded mode, stop and tell the owner: moving existing data is
   the owner's manual job, not onboarding's. (Onboarding would otherwise leave it behind.)
3. **The server already has `<db>`:** check its only remote is `dolthub` and points at
   `<account>/<db>` (stored as `https://doltremoteapi.dolthub.com/<account>/<db>`); go to step 6.
4. **DoltHub has `<account>/<db>`** (check with the API token; first confirm the token belongs to
   `<account>`, because DoltHub answers 404 both for "missing" and for "not yours"):
   `CALL DOLT_CLONE('--remote', 'dolthub', '<account>/<db>', '<db>')` through the server; go to
   step 6.
5. **Neither:** a DoltHub database can't be deleted once created (the API has no delete), so get the
   owner's explicit OK. Create `<account>/<db>` on DoltHub as **private**, then
   `ai-sandbox-beads-init <db> <prefix>` (prefix from the repo's beads config, or ask the owner).
   It runs `bd init` from a scratch directory that isn't a git repo, never in the clone:
   `bd init --server --external --server-host 127.0.1.1 --server-port 3307 --database <db>
   --prefix <prefix> --skip-agents --skip-hooks --non-interactive`, adds the `dolthub` remote,
   removes any other, and pushes. (*Pilot:* whether a new DoltHub database starts empty or with a
   first commit; if the latter, clone it as in step 4 and initialise into the clone.)
6. Make the database's project id match the clone's: bd compares `project_id` in the clone's
   tracked `.beads/metadata.json` with the database's and refuses to write on a mismatch.
7. Write `.beads/.env` (see [Clients](#clients)) and add it to `.git/info/exclude`.
8. Verify: `bd ready` works; `bd` from a worktree sees the same issues (if the repo has one); trigger
   one sync and check its log line is `ok`.
9. Tell the owner if the repo's committed beads config would interfere, without changing it (that
   belongs to the repo): `sync.remote` or a GitHub-ref sync, `dolt.auto-push: true`,
   `dolt.shared-server: true`, `dolt.auto-commit` off, or bd's git hooks importing a tracked
   `issues.jsonl` on checkout.

Onboarding writes only untracked files in the clone (`.beads/.env`, and `.beads/redirect` if
needed).

## Installing

Instructions for the agent, once the module is listed and setup stops with `missing dolt` or
`missing bd`:

1. Check the prerequisite (no `/usr/local/bin/bd` from npm). If it's there, ask the owner to remove it.
2. For each tool: download the release asset named in `versions.toml` for this platform, check its
   sha256 against the file, extract into `~/.local/share/ai-sandbox/opt/<tool>/<version>/`, and
   link `~/.local/bin/<tool>` to it. Check `<tool> version` (for dolt with
   `DOLT_DISABLE_VERSION_CHECKS=1`) shows the pin.
3. Run setup again. It installs the units and config, sets up credentials (and may stop for the
   key registration, above), and starts the server and timer.
4. Check `ai-sandbox-beads-status` says `running`.

## Upgrading

The owner changes a pin in `versions.toml` by PR; setup then stops with `upgrade <tool> A -> B`.
Instructions for the agent:

1. Read the release notes between the two versions and tell the owner anything that affects data
   (bd schema migrations, Dolt storage format changes).
2. Run one sync by hand (`ai-sandbox-beads-sync`); every database must be `ok`. If beads is stopped
   on purpose, stop: the halt is resolved first.
3. Tag every database `pre-<tool>-<version>-<YYYYMMDDTHHMM>` and push the tags to DoltHub.
4. `ai-sandbox-beads-server stop "upgrade <tool> A -> B"` (the sync then pauses, since the marker
   exists), and copy the data directory (`cp -a`, with the server stopped) next to it.
5. Install the new version side by side and switch the link (as in Installing).
6. **bd only:** bd doesn't migrate a database that has a remote by itself. For each database:
   `BD_ALLOW_REMOTE_MIGRATE=1 bd migrate schema`, with the server started by
   `ai-sandbox-beads-server start --upgrade` (the sync stays paused, so nothing is pushed yet).
7. Verify locally (server started with `start --upgrade`): the version matches; the server starts and lists every database it had; for
   each, `bd ready` works and the issue count is at least what it was.
8. Only then resume (`ai-sandbox-beads-server resume`), which runs a sync. For bd, that sync
   pushes the migrated schema to DoltHub: the point of no return. Ask the owner before this step
   when a migration ran, because every other machine then needs the new bd before it pulls.
9. Log the result to `upgrades.log` and run setup again.

### Rolling back

Before step 8: stop the server, restore the copied data directory, point the link back at the
previous version (still in `opt/`), and resume. Nothing reached DoltHub, so nothing else changes.

After step 8 with a migration: the old bd can't read the new schema. Rolling back then means
resetting each database to its `pre-…` tag and force-pushing it to DoltHub, on the owner's say
only, after pushing the current state to a backup branch. Prefer fixing forward.

## Pilot

`tests/host/beads-pilot.sh`: one test run on the real laptop after the module is installed, and
again after any dolt or bd upgrade. It uses a DoltHub database kept for the purpose,
`ai_sandbox_pilot`, reset at the start of each run (the DoltHub API has no delete). It checks, in
plain words:

- **bd can't start a server of its own:** with our server stopped, `bd ready`, `bd create`,
  `bd doctor` and `bd dolt start` in an onboarded clone all fail, and no other `dolt` process
  appears (127.0.1.1 makes bd treat the server as external).
- **The same issues everywhere:** a throwaway repo is onboarded end to end; two clones and a
  worktree see each other's writes immediately (and whether the worktree needed a redirect file).
- **Names:** `bd init --database` creates the database under that exact name, and every bd
  command works with a hyphen in it.
- **Sync both ways:** a write appears on DoltHub within a minute; a commit made directly on DoltHub
  appears locally; the audit-log rows bd keeps local don't block the sync.
- **Halts:** a forced divergence stops the server with the marker, the log line and the status
  output; it stays stopped across `ai-sandbox-beads-server start` and a restart of the WSL VM;
  resume refuses while diverged and works once resolved; a database with no `dolthub` remote halts;
  a failing sync script halts.
- **Network:** 15 minutes without network halts (shortened by a test-only setting), a shorter
  outage doesn't, and a failure just before sleep plus one after wake doesn't.
- **Credentials:** whether the API token works as a push password; whether a new DoltHub database
  starts empty.

While testing: don't kill `dolt` or `bd` processes the test didn't start, and don't touch other
repos' `.beads/` or git hooks.

Until it passes, README.md marks the module untested.

## Not in this version

- Cloud sandboxes (used only while the laptop is unavailable). The sync, status and server
  commands are written to run without the rest of ai-sandbox (credentials from environment
  variables), so `cloud/setup.sh` can later install the pinned `dolt` and `bd` (from this repo's
  `versions.toml`; an older bd can't read a newer schema) and the skill, start a local server,
  clone the repo's database from DoltHub, and run the same sync. Because a cloud container can be
  reclaimed, a sync when a session ends is worth adding then.
- Moving existing embedded beads data onto the server: the owner does this by hand.
