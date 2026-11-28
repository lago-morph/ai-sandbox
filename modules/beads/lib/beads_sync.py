#!/usr/bin/env python3
"""One sync run of every beads database on the shared server with DoltHub.

Run by ai-sandbox-beads-sync (which holds the lock and sets the environment). See
modules/beads/README.md, "Sync". Exit 0: synced, or a soft failure still within the grace
period. Exit 3: stopped on purpose (already, or by this run).
"""
import json
import os
import re
import subprocess
import sys
import time

HOST = os.environ.get('BEADS_HOST', '127.0.1.1')
PORT = os.environ.get('BEADS_PORT', '3307')
DOLT = os.environ.get('BEADS_DOLT', os.path.expanduser('~/.local/bin/dolt'))
LOG = os.environ.get('BEADS_LOG', os.path.expanduser('~/.local/state/ai-sandbox/beads-sync.log'))
STATE = os.environ.get('BEADS_SYNC_STATE', os.path.expanduser('~/.local/state/ai-sandbox/beads-sync.state'))
MARKER = os.environ.get('BEADS_MARKER', os.path.expanduser('~/.local/state/ai-sandbox/beads-sync-HALTED'))
BIN = os.environ.get('AI_SANDBOX_BIN', os.path.expanduser('~/.local/bin'))
# Halt after soft failures lasting WINDOW seconds AND at least RUNS failed runs in a row; a gap of
# more than GAP seconds since the previous run (the machine slept) starts the count again.
WINDOW = int(os.environ.get('BEADS_SOFT_WINDOW', 15 * 60))
RUNS = int(os.environ.get('BEADS_SOFT_RUNS', 15))
GAP = int(os.environ.get('BEADS_GAP_RESET', 3 * 60))
LOG_DAYS = 7
SYSTEM_DBS = {'information_schema', 'mysql'}

# Soft: can't connect, or lost a race; everything else is hard (halt now).
SOFT = re.compile(
    r'connection refused|connect: |dial tcp|no such host|i/o timeout|timed? ?out|deadline exceeded|'
    r'temporary failure|network is unreachable|no route to host|connection reset|broken pipe|'
    r'tls handshake|unexpected eof|\b50[0234]\b|service unavailable|bad gateway|internal server error|'
    r'uncommitted changes|local changes|non-fast-forward|target .*updated|stale|try again',
    re.I)


class DoltError(Exception):
    pass


def classify(message):
    return 'soft' if SOFT.search(message or '') else 'hard'


def next_failure_state(state, now, window=WINDOW, runs=RUNS, gap=GAP):
    """A failed run: -> (new state, halt?). state holds first_failure, failures, last_run."""
    s = dict(state)
    last = s.get('last_run')
    if not s.get('first_failure') or last is None or now - last > gap:
        s['first_failure'], s['failures'] = now, 1
    else:
        s['failures'] = s.get('failures', 0) + 1
    s['last_run'] = now
    return s, (now - s['first_failure'] >= window and s['failures'] >= runs)


def success_state(state, now):
    s = dict(state)
    s.pop('first_failure', None)
    s['failures'] = 0
    s['last_run'] = s['last_success'] = now
    return s


def load_state():
    try:
        with open(STATE) as f:
            s = json.load(f)
        if not isinstance(s, dict):
            raise ValueError
        return s
    except FileNotFoundError:
        return {}
    except (ValueError, OSError):
        # Unreadable: counts as "failing since now", never as a reset.
        return {'first_failure': time.time(), 'failures': 0, 'last_run': time.time()}


def save_state(s):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(s, f)
    os.replace(tmp, STATE)


def stamp(t=None):
    return time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t))


def log(line):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, 'a') as f:
        f.write(f'{stamp()} {line}\n')


def trim_log(now):
    cutoff = stamp(now - LOG_DAYS * 86400)
    try:
        with open(LOG) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return
    keep = [l for l in lines if l[:19] >= cutoff]
    if len(keep) != len(lines):
        with open(LOG + '.tmp', 'w') as f:
            f.writelines(keep)
        os.replace(LOG + '.tmp', LOG)


def sql(query, db=None):
    cmd = [DOLT, '--host', HOST, '--port', PORT, '--no-tls', '-u', 'root', '-p', '']
    if db:
        cmd += ['--use-db', db]
    cmd += ['sql', '-r', 'json', '-q', query]
    try:
        # From an empty directory: dolt's client also looks for databases in its working directory.
        cwd = os.path.join(os.path.dirname(STATE), 'beads-cwd')
        os.makedirs(cwd, exist_ok=True)
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300, cwd=cwd,
                           env={**os.environ, 'DOLT_DISABLE_VERSION_CHECKS': '1'})
    except subprocess.TimeoutExpired:
        raise DoltError('timed out')
    if p.returncode != 0:
        raise DoltError(' '.join((p.stderr or p.stdout).split()) or f'dolt exited {p.returncode}')
    out = p.stdout.strip()
    if not out:
        return []
    try:
        return json.loads(out).get('rows', [])
    except ValueError:
        return []


def quote(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "''") + "'"


def author():
    def git(key):
        p = subprocess.run(['git', 'config', '--global', key], capture_output=True, text=True)
        return p.stdout.strip()
    name, email = git('user.name'), git('user.email')
    return f'{name} <{email}>' if name and email else None


def sync_db(db, who):
    """-> ('ok', behind, ahead) or ('error', class, message)."""
    try:
        remotes = sorted(r['name'] for r in sql('SELECT name FROM dolt_remotes', db))
        if 'dolthub' not in remotes:
            return 'error', 'hard', 'no dolthub remote (not backed up): onboard it or move the repo back to embedded mode'
        others = [r for r in remotes if r != 'dolthub']
        if others:
            return 'error', 'hard', f'remote(s) other than dolthub: {", ".join(others)}'
        args = ["'-A'", "'--skip-empty'", "'-m'", "'beads sync: commit working set'"]
        if who:
            args[2:2] = ["'--author'", quote(who)]
        sql(f'CALL DOLT_COMMIT({", ".join(args)})', db)
        sql("CALL DOLT_FETCH('dolthub', 'main')", db)
        row = sql("SELECT (SELECT COUNT(*) FROM dolt_log('main..dolthub/main')) AS behind, "
                  "(SELECT COUNT(*) FROM dolt_log('dolthub/main..main')) AS ahead", db)[0]
        behind, ahead = int(row['behind']), int(row['ahead'])
        if behind and ahead:
            return 'error', 'hard', f'diverged from DoltHub (ahead {ahead}, behind {behind})'
        if behind:
            sql("CALL DOLT_MERGE('--ff-only', 'dolthub/main')", db)
        if ahead:
            sql("CALL DOLT_PUSH('dolthub', 'main')", db)
        return 'ok', behind, ahead
    except DoltError as e:
        return 'error', classify(str(e)), str(e)


def halt(cls, reason, dbs):
    try:
        p = subprocess.run([os.path.join(BIN, 'ai-sandbox-beads-server'), 'halt', cls, reason, ' '.join(dbs)])
        if p.returncode == 0 and os.path.exists(MARKER):
            return
    except OSError:
        pass
    # The server command is missing or failed: still leave the marker, so nothing restarts it.
    if not os.path.exists(MARKER):
        with open(MARKER, 'w') as f:
            f.write(f'time: {stamp()}\nby: beads sync\nclass: {cls}\nreason: {reason}\n'
                    f'databases: {" ".join(dbs)}\nnext: see Troubleshooting in modules/beads/README.md\n')
    log(f'HALT {" ".join(dbs) or "-"} class={cls} reason={reason} (server command failed; marker written directly)')


def main():
    if os.path.exists(MARKER):
        print('beads is stopped on purpose; not syncing (ai-sandbox-beads-status)')
        return 3
    now = time.time()
    state = load_state()
    who = author()
    try:
        dbs = [r['Database'] for r in sql('SHOW DATABASES') if r['Database'] not in SYSTEM_DBS]
        results = {db: sync_db(db, who) for db in dbs}
    except DoltError as e:
        results = {'-': ('error', classify(str(e)), f'server: {e}')}
    hard, soft = [], []
    for db, r in results.items():
        if r[0] == 'ok':
            log(f'{db} ok behind={r[1]} ahead={r[2]}')
        else:
            log(f'{db} error {r[1]} {r[2]}')
            (hard if r[1] == 'hard' else soft).append((db, r[2]))
    if not results:
        log('- ok no databases')
    code = 0
    if hard:
        reason = '; '.join(f'{db}: {m}' for db, m in hard)
        halt('hard', reason, [db for db, _ in hard])
        state['last_run'] = now
        code = 3
    elif soft:
        state, stop = next_failure_state(state, now)
        if stop:
            mins = int((now - state['first_failure']) // 60)
            halt('soft', f'no successful sync for {mins} min ({state["failures"]} runs): ' +
                 '; '.join(f'{db}: {m}' for db, m in soft), [db for db, _ in soft])
            code = 3
    else:
        state = success_state(state, now)
    if now - state.get('last_trim', 0) > 3600:
        trim_log(now)
        state['last_trim'] = now
    save_state(state)
    return code


if __name__ == '__main__':
    sys.exit(main())
