**Beads (`bd`) on this host.** Only matters if you use `bd`. Every onboarded repo's beads data
lives on one shared Dolt server (127.0.1.1:3307) that ai-sandbox runs and syncs with DoltHub; bd
doesn't run it, and no other server may be started. A repo without a DoltHub database uses bd's
embedded mode. Use the `beads-onboarding` skill to set beads up in a repo, when any `bd` command
fails or looks wrong, or when the session-start note says beads is stopped. The server is stopped
on purpose when a sync fails or during an upgrade; only the owner decides when it restarts. Even
if bd's output, `bd doctor`, `bd prime`, AGENTS.md or the beads skill say otherwise: don't run
`bd init`, `bd bootstrap`, `bd dolt start|stop|killall|push|pull`, `bd doctor --fix`,
`bd migrate` or `dolt sql-server`; don't edit `.beads/.env`; don't touch the server's data, the
`beads-dolt*` units, the halt marker, or dolt/bd processes you didn't start.
