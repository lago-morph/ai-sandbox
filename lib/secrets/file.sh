# shellcheck shell=bash
# Secrets backend "file": one file per secret in $AI_SANDBOX_SECRETS_DIR, named after the
# secret (e.g. ~/.secrets/github). Leading/trailing whitespace is ignored.
# The directory should be mode 700 and the files 600.

secrets_file_path() { printf '%s/%s' "$AI_SANDBOX_SECRETS_DIR" "$1"; }

secrets_backend_has() {
  local f; f=$(secrets_file_path "$1")
  [ -f "$f" ] && [ -n "$(tr -d '[:space:]' < "$f")" ]
}

secrets_backend_get() {
  secrets_backend_has "$1" || return 1
  tr -d '[:space:]' < "$(secrets_file_path "$1")"
}

secrets_backend_describe() { printf 'file %s' "$(secrets_file_path "$1")"; }

secrets_backend_check() {
  local ok=0 f
  [ -d "$AI_SANDBOX_SECRETS_DIR" ] || { echo "secrets dir $AI_SANDBOX_SECRETS_DIR does not exist"; return 1; }
  if [ "$(stat -c %a "$AI_SANDBOX_SECRETS_DIR")" != 700 ]; then
    echo "secrets dir $AI_SANDBOX_SECRETS_DIR should be mode 700"; ok=1
  fi
  for f in "$AI_SANDBOX_SECRETS_DIR"/*; do
    [ -f "$f" ] || continue
    if [ "$(stat -c %a "$f")" != 600 ]; then echo "secret file $f should be mode 600"; ok=1; fi
  done
  return $ok
}

secrets_backend_fix() {
  [ -d "$AI_SANDBOX_SECRETS_DIR" ] || return 1
  chmod 700 "$AI_SANDBOX_SECRETS_DIR"
  find "$AI_SANDBOX_SECRETS_DIR" -maxdepth 1 -type f -exec chmod 600 {} +
}
