#!/usr/bin/env python3
"""Reads versions.toml (modules and tool versions) and checks the host against it.

Usage: versions.py FILE COMMAND [ARGS]
  validate                 check the file's structure; print problems, exit 1 if any
  modules                  print the module names
  module MODULE FIELD      print a module's field (description, doc; requires one per line)
  tools MODULE             print the tools of MODULE ("base" for the base setup)
  check MODULE             check MODULE's tools on this host; one line per tool, exit 1 unless all ok
  show MODULE...           a table of tools, pinned and installed versions, and results

Paths come from the environment: AI_SANDBOX_BIN (default ~/.local/bin), AI_SANDBOX_SHARE
(default ~/.local/share/ai-sandbox), AI_SANDBOX_PLATFORM (default from `uname -m`).
See modules/README.md.
"""
import os
import re
import shlex
import subprocess
import sys

try:
    import tomli
except ImportError:
    sys.exit("versions.py: the python3 'tomli' module is missing (setup's packages step installs python3-tomli)")

SOURCES = ('github', 'url', 'npm', 'pypi', 'system')
INSTALLED = ('github', 'url', 'npm', 'pypi')      # pinned exactly (==)
DOWNLOADS = ('github', 'url')                     # sha256-checked, live in opt/
PLATFORMS = ('linux-amd64', 'linux-arm64')
MACHINES = {'x86_64': 'linux-amd64', 'amd64': 'linux-amd64', 'aarch64': 'linux-arm64', 'arm64': 'linux-arm64'}
MODULE_KEYS = {'description', 'requires'}
TOOL_KEYS = {'module', 'version', 'source', 'asset', 'platforms', 'sha256', 'version_cmd'}
NAME = re.compile(r'^[a-z0-9][a-z0-9-]*$')
SPEC = re.compile(r'^\s*(==|>=|<=|<|>)\s*([0-9]+(?:\.[0-9]+)*)\s*$')
VERSION = re.compile(r'v?([0-9]+(?:\.[0-9]+)+)')


def load(path):
    with open(path, 'rb') as f:
        return tomli.load(f)


def vtuple(v):
    parts = [int(p) for p in v.split('.')]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def parse_spec(spec):
    """'>=1.6,<2' -> [('>=', (1,6)), ('<', (2,))]; raises ValueError."""
    out = []
    for part in spec.split(','):
        m = SPEC.match(part)
        if not m:
            raise ValueError(f'not a version constraint: {part.strip()!r}')
        out.append((m.group(1), m.group(2)))
    return out


def satisfies(version, spec):
    v = vtuple(version)
    for op, want in parse_spec(spec):
        w = vtuple(want)
        ok = {'==': v == w, '>=': v >= w, '<=': v <= w, '<': v < w, '>': v > w}[op]
        if not ok:
            return False
    return True


def source_kind(src):
    return src.split(':', 1)[0] if isinstance(src, str) else None


def validate(d):
    problems = []
    for k in d:
        if k not in ('modules', 'tools'):
            problems.append(f'unknown top-level key {k!r}')
    mods = d.get('modules', {})
    for name, m in mods.items():
        where = f'[modules.{name}]'
        if not NAME.match(name) or name == 'base':
            problems.append(f'{where}: invalid module name')
        if not isinstance(m, dict):
            problems.append(f'{where}: must be a table'); continue
        for k in m:
            if k not in MODULE_KEYS:
                problems.append(f'{where}: unknown key {k!r}')
        if not isinstance(m.get('description'), str) or not m.get('description'):
            problems.append(f'{where}: description is required')
        req = m.get('requires', [])
        if not isinstance(req, list) or not all(isinstance(r, str) for r in req):
            problems.append(f'{where}: requires must be a list of module names')
        else:
            for r in req:
                if r not in mods:
                    problems.append(f'{where}: requires unknown module {r!r}')
    tools = d.get('tools', {})
    for name, t in tools.items():
        where = f'[tools.{name}]'
        if not NAME.match(name):
            problems.append(f'{where}: invalid tool name')
        if not isinstance(t, dict):
            problems.append(f'{where}: must be a table'); continue
        for k in t:
            if k not in TOOL_KEYS:
                problems.append(f'{where}: unknown key {k!r}')
        mod = t.get('module')
        if mod != 'base' and mod not in mods:
            problems.append(f'{where}: module must be "base" or a module in [modules] (got {mod!r})')
        kind = source_kind(t.get('source'))
        if kind not in SOURCES:
            problems.append(f'{where}: source must start with one of {", ".join(SOURCES)} (got {t.get("source")!r})')
            continue
        if kind != 'system' and ':' not in t['source']:
            problems.append(f'{where}: source {kind}: needs a value (e.g. github:owner/repo)')
        spec = t.get('version')
        try:
            parsed = parse_spec(spec) if isinstance(spec, str) else None
        except ValueError as e:
            problems.append(f'{where}: {e}'); parsed = []
        if parsed is None:
            problems.append(f'{where}: version is required')
        elif parsed:
            if kind in INSTALLED and (len(parsed) != 1 or parsed[0][0] != '=='):
                problems.append(f'{where}: a {kind} tool is pinned exactly (version = "==X")')
            if kind == 'system' and any(op == '==' for op, _ in parsed):
                problems.append(f'{where}: a system tool gets a minimum (">=X"), not "=="')
        if kind in DOWNLOADS:
            if kind == 'github' and not isinstance(t.get('asset'), str):
                problems.append(f'{where}: asset (release asset name) is required')
            sha = t.get('sha256', {})
            if not isinstance(sha, dict):
                problems.append(f'{where}: sha256 must be a table of platform = digest')
            else:
                for p, v in sha.items():
                    if p not in PLATFORMS:
                        problems.append(f'{where}: sha256: unknown platform {p!r}')
                    elif not (isinstance(v, str) and re.fullmatch(r'[0-9a-f]{64}', v)):
                        problems.append(f'{where}: sha256.{p} is not a sha256 hex digest')
            plats = t.get('platforms', {})
            if not isinstance(plats, dict) or any(p not in PLATFORMS for p in plats):
                problems.append(f'{where}: platforms maps {"/".join(PLATFORMS)} to the vendor\'s names')
        else:
            for k in ('asset', 'platforms', 'sha256'):
                if k in t:
                    problems.append(f'{where}: {k} applies only to github/url tools')
            if 'version_cmd' in t and not isinstance(t['version_cmd'], str):
                problems.append(f'{where}: version_cmd must be a string')
        if kind == 'npm' and 'node' not in tools:
            problems.append(f'{where}: npm tools need a [tools.node] entry')
        if kind == 'pypi' and 'uv' not in tools:
            problems.append(f'{where}: pypi tools need a [tools.uv] entry')
    return problems


def platform():
    p = os.environ.get('AI_SANDBOX_PLATFORM')
    if p:
        return p
    m = os.uname().machine
    return MACHINES.get(m, f'linux-{m}')


def doc_of(d, module):
    if module == 'base':
        return 'README.md'
    return f'modules/{module}/README.md'


def installed_version(name, t):
    """(version or None, note). For github/url tools, the opt/<tool>/<version> the link points at."""
    kind = source_kind(t['source'])
    if kind in DOWNLOADS:
        bin_dir = os.environ.get('AI_SANDBOX_BIN', os.path.expanduser('~/.local/bin'))
        share = os.environ.get('AI_SANDBOX_SHARE', os.path.expanduser('~/.local/share/ai-sandbox'))
        link = os.path.join(bin_dir, name)
        if not os.path.lexists(link):
            return None, ''
        target = os.path.realpath(link)
        opt = os.path.realpath(os.path.join(share, 'opt', name))
        rel = os.path.relpath(target, opt)
        if rel.startswith('..') or not os.path.islink(link):
            return None, f'{link} is not managed by ai-sandbox (points at {target})'
        return rel.split(os.sep)[0].lstrip('v'), ''
    cmd = t.get('version_cmd', f'{name} --version')
    try:
        out = subprocess.run(shlex.split(cmd), capture_output=True, text=True, timeout=20)
    except FileNotFoundError:
        return None, ''
    except subprocess.TimeoutExpired:
        return None, f'{cmd!r} timed out'
    m = VERSION.search(out.stdout + out.stderr)
    if not m:
        return None, f'no version in the output of {cmd!r}'
    return m.group(1), ''


def check_tool(d, name, t):
    """-> (status, line). status is 'ok' or a problem keyword."""
    kind = source_kind(t['source'])
    spec = t['version']
    pin = parse_spec(spec)[0][1] if kind in INSTALLED else None
    doc = doc_of(d, t['module'])
    plat = platform()
    if kind in DOWNLOADS and plat not in t.get('sha256', {}):
        return 'no-checksum', f'no-checksum {name} {plat}: versions.toml has no sha256.{plat} for {name}; add it (modules/README.md#versionstoml)'
    have, note = installed_version(name, t)
    if have is None:
        if note:
            return 'unmanaged', f'unmanaged {name}: {note}; follow {doc}#installing'
        if kind == 'system':
            return 'missing', f'missing {name} (needs {spec}): install the distro package, then re-run setup'
        return 'missing', f'missing {name} (pin {pin}): follow {doc}#installing'
    if kind in INSTALLED:
        if vtuple(have) == vtuple(pin):
            return 'ok', f'ok {name} {have}'
        if vtuple(have) < vtuple(pin):
            return 'upgrade', f'upgrade {name} {have} -> {pin}: follow {doc}#upgrading'
        return 'newer-than-pin', (f'newer-than-pin {name} {have} > {pin}: installed by hand or from an unmerged '
                                  f'branch; stop and ask the owner (raise the pin, or downgrade by hand)')
    if satisfies(have, spec):
        return 'ok', f'ok {name} {have}'
    mins = [w for op, w in parse_spec(spec) if op in ('>=', '>')]
    if mins and not satisfies(have, ','.join(f'{op}{w}' for op, w in parse_spec(spec) if op in ('>=', '>'))):
        return 'too-old', f'too-old {name} {have} (needs {spec}): install a newer {name}, then re-run setup'
    return 'unsupported', f'unsupported {name} {have} (needs {spec})'


def module_tools(d, module):
    return [(n, t) for n, t in d.get('tools', {}).items() if t.get('module') == module]


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    path, cmd, args = argv[1], argv[2], argv[3:]
    try:
        d = load(path)
    except (OSError, tomli.TOMLDecodeError) as e:
        sys.exit(f'{path}: {e}')
    if cmd == 'validate':
        problems = validate(d)
        for p in problems:
            print(f'{os.path.basename(path)}: {p}')
        return 1 if problems else 0
    problems = validate(d)
    if problems:
        sys.exit(f'{path} is invalid (run: versions.py {path} validate)')
    mods = d.get('modules', {})
    if cmd == 'modules':
        print('\n'.join(mods))
        return 0
    if cmd == 'module':
        name, field = args
        if name not in mods:
            return 1
        if field == 'requires':
            print('\n'.join(mods[name].get('requires', [])))
        elif field == 'doc':
            print(doc_of(d, name))
        else:
            print(mods[name].get(field, ''))
        return 0
    if cmd == 'tools':
        print('\n'.join(n for n, _ in module_tools(d, args[0])))
        return 0
    if cmd == 'check':
        bad = 0
        for n, t in module_tools(d, args[0]):
            status, line = check_tool(d, n, t)
            print(line)
            bad |= status != 'ok'
        return 1 if bad else 0
    if cmd == 'show':
        rows = [('TOOL', 'MODULE', 'SOURCE', 'WANTED', 'INSTALLED', 'RESULT')]
        for mod in args:
            for n, t in module_tools(d, mod):
                status, _ = check_tool(d, n, t)
                have, _ = installed_version(n, t)
                rows.append((n, mod, t['source'], t['version'], have or '-', status))
        widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
        for r in rows:
            print('  '.join(c.ljust(w) for c, w in zip(r, widths)).rstrip())
        return 0
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
