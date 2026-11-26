#!/usr/bin/env bash
# Usage: sudo ./setup-root.sh [--check] [USER]
#
# The one part of ai-sandbox setup that needs a human with root: gives USER (default: the user
# who ran sudo) passwordless sudo, so ./setup.sh and the agent sessions can use sudo unattended.
# Writes /etc/sudoers.d/USER (validated with visudo first). Run it once, before ./setup.sh.
# Safe to re-run.
#   --check   report whether anything would change, change nothing (exit 1 if it would)
set -euo pipefail

mode=apply
[ "${1:-}" = --check ] && { mode=check; shift; }
case "${1:-}" in -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
user=${1:-${SUDO_USER:-}}
dir=${AI_SANDBOX_SUDOERS_DIR:-/etc/sudoers.d}   # overridable for tests only

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ -n "$user" ] || die "run it with sudo from the sandbox user's account, or pass the user name"
[ "$user" != root ] || die "give the sandbox user, not root"
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "not a valid user name: $user"
id "$user" >/dev/null 2>&1 || die "no such user: $user"
[ -n "${AI_SANDBOX_SUDOERS_DIR:-}" ] || [ "$(id -u)" = 0 ] || die "run it as root: sudo $0"

file="$dir/$user"
want="# Installed by ai-sandbox setup-root.sh: the sandbox user runs sudo without a password.
$user ALL=(ALL) NOPASSWD:ALL"

if [ -f "$file" ] && [ "$(cat "$file")" = "$want" ]; then
  echo "ok      passwordless sudo for $user ($file)"; exit 0
fi
if [ $mode = check ]; then
  echo "PENDING passwordless sudo for $user ($file)"; exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$want" > "$tmp"
visudo -c -q -f "$tmp" >/dev/null || die "generated sudoers file failed visudo -c"
[ ! -e "$file" ] || cp -p "$file" "$file.bak-ai-sandbox"
install -m 0440 "$tmp" "$file"
echo "applied passwordless sudo for $user ($file)"
