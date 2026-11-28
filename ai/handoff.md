# Handoff: modules framework + beads module

Updated: 2026-11-27
Branch: design-review-fixes (from main at 7dd9191)
Phase: design reviewed and revised → implement
PR: https://github.com/lago-morph/ai-sandbox/pull/26 (merged)

## Goal and why
- Goal: "additional modules that I set up on a dedicated sandbox. Each module will control configuration for one set of software" — pinned "in one place, so the individual repositories don't have to decide on the versions". First module: beads ("setting up a shared server and connecting to Dolt Hub").
- Decided: no GitHub beads refs — "We will only use local beads servers that are syncing their local Dolt database from Dolt Hub."
- Decided: dolt lives in the beads module, not a tools module — "The reason we would install Dolt is for beads". Go "straight to beads".
- Decided: pin bd (was 1.2.2; changed to 1.3.4 in review) — "I will coordinate the update."
- Decided: on a sync conflict, stop the beads server — "I'm very concerned that there'll be an error and the syncing will stop and I won't know about it … my sessions using beads will tell me." Soft errors halt after "15 minutes without a successful sync".
- Decided: modules are switched on by a config list; switching off "does not mean to uninstall it … I don't want to accidentally uninstall things because of a typo."
- Decided: "every module should have logic to safely upgrade its versions and to check that the upgrades were successful."
- Decided: config files separate from scripts — "I'm not comfortable with having the configurations mixed in with the shell script." Pins per module; a tool pinned in more than one **listed** module stops setup ("only read through the modules that are activated").
- Decided: credentials have a default file location, overridable by "environment variables that are whatever the convention is that the providing service uses" — for cloud sandboxes "the secrets will always be through environment variables".
- Decided: onboarding connects to the DoltHub database named after the repo, and creates it if missing. Database = repo name; DoltHub's `<account>/` is only its address format.
- Decided: a skill named `beads-onboarding` (not `beads`: the beads project has its own skill) for setup and for troubleshooting "from that repo rather than having to switch over to the AI Sandbox repo"; it clones ai-sandbox if missing.
- Decided: troubleshooting must first check whether the server was stopped on purpose — "it might even be good for there to be a log and for it to check the log". Handover scenarios are listed as likely causes only — "Don't try to make a lot of logic for it."
- Rejected: a general tools module for dolt/jq/yq (now); GitHub refs; worrying about other users ("I'm the only one using it"); creating DoltHub keys from the API token (it can't: registering a key is manual).
- Working rules: laptop is primary; "cloud sandboxes or other CLIs will only be happening when the laptop is not doing anything". Owner wants to review docs, then "have some sub-agents review them after I do to see if there are any gaps." Don't refer to beads tasks planned by other sessions. Give clickable links for docs to review.

## Where we are
- Design reviewed by an 8-agent board (2 rounds) on 2026-11-27; the owner decided every finding. Both
  docs rewritten on branch `design-review-fixes` (PR to follow this handoff). Design only; nothing
  implemented.
- Decided in review (2026-11-27):
  - One central `versions.toml` (repo root) for modules and tool pins; Python specifier syntax
    limited to `==`, `>=`, comma; installed tools `==`, distro tools `>=`. Sources github/url/npm/
    pypi/system. Read with `tomli` always. Platforms linux-amd64 now, linux-arm64 later (Pi).
    Rejected: per-module module.conf; mise (no `>=`, essentially one maintainer).
  - Setup copies module files and **checks**; an **agent** installs and upgrades by following the
    module doc. No scripted upgrade phases/hooks/journals. Setup failing with reason + fix is the
    normal flow.
  - bd pinned at **1.3.4** from its GitHub release (no node). Owner uninstalls the npm bd before
    the install phase (not now). Accepted: 1.3.4 keeps the `events` audit table local (not synced).
  - Server: data dir `~/.local/share/ai-sandbox/data/beads/`, listen 127.0.1.1:3307 (bd 1.3.4 then
    refuses to start its own server), all starts/stops via `ai-sandbox-beads-server` with a halt
    lock. `ai-sandbox-beads-init` is the only script that runs `bd init`.
  - Halts: 15-minute grace (and 15 failed runs) for anything that can't connect; immediate for
    everything else, including a served db with no `dolthub` remote and the sync crashing.
  - DoltHub account moves to credentials (`DOLTHUB_ACCOUNT` / `dolthub-account`); env, then file,
    else stop; stop if both differ. Setup generates the Dolt key; owner registers it by hand.
  - SessionStart hook (`ai-sandbox-status --brief`) and deny rules for bd commands that bypass the
    halt. Handoff Q1 safety rules are in the pilot section.

## Next steps
1. ~~Framework~~ (PR #29) and ~~module READMEs~~ (PR #30): merged; setup applied on the laptop.
2. ~~Beads module~~: branch `beads-module-impl` (PR follows): dolt 2.7.7 and bd 1.3.4 pinned with
   sha256 (amd64 + arm64); server/sync/status/init commands, units, steps (config, credentials,
   units), skill, claude.md, deny rules; tests incl. an end-to-end sync against real dolt
   (`BEADS_TEST_DOLT=...`). Not installed on the laptop yet.
3. ~~Install on the laptop~~: done 2026-11-27; `tests/host/beads-pilot.sh --yes` passed 19/19.
   Remaining gaps are listed in modules/beads/README.md#pilot.
4. Moving any repo onto the server is the owner's job; don't touch other repos for it.

## Open questions
- DoltHub account name (owner, at install time).

## Verify state
```bash
git fetch -q && git log --oneline -1 origin/main
ls modules/README.md modules/beads/README.md; command -v dolt || echo "dolt not installed"
```

## Reading list
| Path | Section | Why |
|---|---|---|
| modules/README.md | whole | the framework spec |
| modules/beads/README.md | whole | the beads module spec |
| CLAUDE.md | whole | repo rules: steps, tests, setup --check first, managed files |

## Environment
| Field | Value |
|---|---|
| Repo | lago-morph/ai-sandbox, main checkout `/home/claude/src/ai-sandbox` |
| Credentials | secrets backend `~/.secrets/` (`github`, `dolthub`); `gh` and git already authenticated. Never print them. |
| Host | WSL2 laptop VM, single user, systemd user units, lingering on |
