# Handoff: modules framework + beads module

Updated: 2026-11-28
Branch: beads-module (from main at 893854b)
Phase: design (merged, PR #26) → review the design, then implement
PR: https://github.com/lago-morph/ai-sandbox/pull/26 (merged)

## Goal and why
- Goal: "additional modules that I set up on a dedicated sandbox. Each module will control configuration for one set of software" — pinned "in one place, so the individual repositories don't have to decide on the versions". First module: beads ("setting up a shared server and connecting to Dolt Hub").
- Decided: no GitHub beads refs — "We will only use local beads servers that are syncing their local Dolt database from Dolt Hub."
- Decided: dolt lives in the beads module, not a tools module — "The reason we would install Dolt is for beads". Go "straight to beads".
- Decided: pin bd at its current version (1.2.2) — "I will coordinate the update."
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
- `docs/modules.md` and `docs/beads.md` are merged to main (PR #26, 893854b). Design only; nothing implemented.
- Owner has reviewed the docs; the sub-agent gap review has not run.
- Host: `dolt` not installed; `bd` 1.2.2 at `/usr/local/bin/bd` (`sudo npm -g @beads/bd`, Node from apt); `~/.secrets/dolthub` holds the DoltHub **API token**; no `dolthub-creds` key yet.
- DoltHub credentials page confirmed by the owner: https://www.dolthub.com/settings/credentials.

## Next steps
1. `sed -n '1,400p' docs/modules.md docs/beads.md`, then launch 2–3 review sub-agents in parallel (fresh eyes, given the docs and repo, not our conclusions): gaps, contradictions, things that won't work with Dolt/bd 1.2.2. Report findings to the owner; fix agreed ones in a PR. (serves: design is complete)
2. Implement the module framework (`lib/modules.sh`, `module.conf` parser, setup.sh integration, pin check, upgrade phases, `ai-sandbox-status`, `ai-sandbox-versions`, tests in `tests/run.sh`). One PR. (serves: modules)
3. Implement `modules/beads/` per docs/beads.md: dolt pin (latest stable release, sha256), bd pin 1.2.2 (check only), server unit, sync timer + halt marker, status/resume/onboard commands, `beads-onboarding` skill, claude.md rule, repo CLAUDE.md "Troubleshooting the host" entry, managed-files list in CLAUDE.md, README (mark untested). (serves: beads)
4. Run `./setup.sh --check` and show the owner; apply. Owner registers the printed public key. Then the pilot (`tests/host/beads-pilot.sh`) and resolve every "verify in pilot" item in docs/beads.md. (serves: beads works)

## What carried forward
- Config keys: `AI_SANDBOX_MODULES="beads"`, `AI_SANDBOX_BEADS_DOLTHUB_ACCOUNT` (value: ask the owner).
- Server: `beads-dolt.service`, 127.0.0.1:3307, root/no password, data dir `~/.beads/shared-server/`.
- Sync: `beads-dolt-sync.timer` every 1 min; `--ff-only` pull; halt marker `~/.local/state/ai-sandbox/beads-sync-HALTED`; log `~/.local/state/ai-sandbox/beads-sync.log`.
- Credentials: `DH_TOKEN` / secret `dolthub` (API token); `DOLT_CREDS_JWK` / secret `dolthub-creds` (JWK, copied into `~/.dolt/creds/`).
- Pilot DoltHub database: `ai_sandbox_pilot` (DoltHub API has no delete; reuse it).
- DoltHub names allow letters, digits, `-`, `_`; hyphens are kept unless the pilot shows Dolt/bd can't handle them.
- Pick the dolt version: latest stable release at implementation time (memory: beads-use-latest-stable).

## Verify state
```bash
git fetch -q && git log --oneline -1 origin/main   # 893854b or later
ls docs/modules.md docs/beads.md; command -v dolt || echo "dolt not installed"; bd version
```

## Reading list
| Path | Section | Why |
|---|---|---|
| docs/modules.md | whole | the framework spec |
| docs/beads.md | whole | the beads module spec |
| CLAUDE.md | whole | repo rules: steps, tests, setup --check first, managed files |

## Open questions
- Q1: Should the original brief's safety rules go in docs/beads.md: don't kill `dolt`/`bd` processes this work didn't start; don't touch other repos' `.beads/` or hooks while testing? (owner; serves: beads, safely)
- Q2: DoltHub account name for `AI_SANDBOX_BEADS_DOLTHUB_ACCOUNT`. (owner; serves: beads)
- Q3: Does DoltHub accept the API token as a push password (`DOLT_REMOTE_PASSWORD`)? If yes, drop the JWK key. (pilot; serves: simpler credentials)

## Environment
| Field | Value |
|---|---|
| Repo | lago-morph/ai-sandbox, main checkout `/home/claude/src/ai-sandbox` |
| Credentials | secrets backend `~/.secrets/` (`github`, `dolthub`); `gh` and git already authenticated. Never print them. |
| Host | WSL2 laptop VM, single user, systemd user units, lingering on |
