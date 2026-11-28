---
name: beads-onboarding
description: Set up or fix beads (`bd`) on this ai-sandbox host. Use when asked to set up, add or init beads in a repo, or when any `bd` command fails or misbehaves - connection refused on 127.0.1.1:3307, database not found, read-only, missing or unexpected issues, or a new worktree that shows no issues. Use this instead of `bd init`, `bd dolt start`, `bd doctor --fix` or the beads skill's setup steps, which must not be run on this host.
---

# Beads on this ai-sandbox host

Every onboarded repo's beads data is on one shared Dolt server (127.0.1.1:3307) that ai-sandbox
runs and syncs with DoltHub every minute. The full reference is the module's README:
`~/.local/share/ai-sandbox/modules/beads/README.md` (sections named below). Read the section
before acting on it.

## Step 0, always

If `ai-sandbox-beads-status` isn't on PATH, this isn't an ai-sandbox beads host. Don't install,
initialise or start anything; tell the owner and stop.

## Troubleshooting

1. Run `ai-sandbox-beads-status <repo dir>`. If the first line says STOPPED ON PURPOSE, that is
   the cause; skip the usual checks. Never start the server or remove the halt marker yourself.
2. Read "Troubleshooting" in the README and match the status and log against "Likely causes".
3. Explain the cause and the options to the owner ("Resolving a halt"). Ask before anything
   that discards or overwrites data, and before `ai-sandbox-beads-server resume` or `start`.

## Setting beads up in a repo

Only when the owner asks. Follow "Onboarding a repo" in the README step by step; tell the owner
what you're about to do at each step that changes something outside the clone. In short:

1. The database name is the repo name from `origin` (lowercased, GitHub owner dropped). Check
   the server is running and not stopped on purpose.
2. If the clone already has beads data in embedded mode, stop: moving it is the owner's job.
3. Server already has the database: check its only remote is `dolthub` at `<account>/<db>`.
4. DoltHub has `<account>/<db>` (check with the API token, after confirming the token belongs to
   the account with `GET https://www.dolthub.com/api/v1alpha1/user`; DoltHub answers 404 for both
   "missing" and "not yours"): clone it through the
   server with `CALL DOLT_CLONE('--remote', 'dolthub', '<account>/<db>', '<db>')`.
5. Neither: creating a DoltHub database can't be undone. Get the owner's explicit OK, create it
   as **private**, then `ai-sandbox-beads-init <db> <prefix>` (never `bd init` yourself).
6. The clone's `.beads/metadata.json` must name the database and its project id
   (`ai-sandbox-beads-init` prints it). A repo with no `.beads/` yet: write that file and tell the
   owner to commit it. An existing one says embedded mode: tell the owner it needs changing.
7. Write `.beads/.env` (contents in the README, "Clients") and add it to `.git/info/exclude`.
8. Verify `bd ready`, a worktree sees the same issues, and `ai-sandbox-beads-sync` logs `ok`.
9. Tell the owner about committed beads settings that would interfere (README step 9); don't
   change them.

Repos without a DoltHub database stay in bd's embedded mode.
