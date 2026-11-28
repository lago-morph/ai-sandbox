# shellcheck shell=bash
# Modules: optional sets of software, listed in AI_SANDBOX_MODULES and defined in versions.toml
# and modules/<name>/. See modules/README.md. Sourced after common.sh.

modules_listed() { local m; for m in $AI_SANDBOX_MODULES; do echo "$m"; done | awk '!seen[$0]++'; }
modules_known()  { find "$AI_SANDBOX_MODULES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }

# Modules setup has installed at least once (listed or not since), in first-install order.
modules_installed_file() { echo "$AI_SANDBOX_STATE/modules-installed"; }
modules_installed() { [ -f "$(modules_installed_file)" ] && cat "$(modules_installed_file)" || true; }
modules_record_installed() {
  grep -qxF "$1" "$(modules_installed_file)" 2>/dev/null && return 0
  mkdir -p "$AI_SANDBOX_STATE"; echo "$1" >> "$(modules_installed_file)"
}

tomli_available() { python3 -c 'import tomli' 2>/dev/null; }
versions_py() { python3 "$AI_SANDBOX_LIB/versions.py" "$AI_SANDBOX_VERSIONS" "$@"; }

# modules_check_names: every listed module has a modules/<name>/ directory. Needs no TOML reader,
# so it runs before any step on a fresh host too.
modules_check_names() {
  local m
  for m in $(modules_listed); do
    [ -d "$AI_SANDBOX_MODULES_DIR/$m" ] ||
      die "unknown module '$m' in AI_SANDBOX_MODULES; known modules: $(modules_known | xargs | sed 's/^$/(none)/')"
  done
}

# modules_preflight: names, versions.toml valid, each listed module defined there, its
# requirements listed. Dies with the reason.
modules_preflight() {
  local m r problems
  modules_check_names
  problems=$(versions_py validate) || die "versions.toml is invalid:"$'\n'"$problems"
  for m in $(modules_listed); do
    versions_py module "$m" description >/dev/null ||
      die "module '$m' has modules/$m/ but no [modules.$m] in versions.toml"
    for r in $(versions_py module "$m" requires); do
      modules_listed | grep -qxF "$r" || die "module '$m' requires module '$r': add it to AI_SANDBOX_MODULES"
    done
  done
}

# module_tools_check MODULE: prints one line per tool; exit 1 unless all are ok.
module_tools_check() { versions_py check "$1"; }

# Files a module installs, as "SRC<TAB>DEST" lines (paths relative to the module dir / absolute).
_module_files() {
  local m=$1 dir="$AI_SANDBOX_MODULES_DIR/$1" f s
  if [ -d "$dir/bin" ]; then
    for f in "$dir"/bin/*; do [ -f "$f" ] && printf 'bin/%s\t%s/%s\n' "${f##*/}" "$AI_SANDBOX_BIN" "${f##*/}"; done
  fi
  if [ -d "$dir/skills" ]; then
    for s in "$dir"/skills/*/; do s=${s%/}; printf 'skills/%s\t%s/.claude/skills/%s\n' "${s##*/}" "$HOME" "${s##*/}"; done
  fi
  if [ -d "$dir/templates/systemd" ]; then
    for f in "$dir"/templates/systemd/*; do [ -f "$f" ] && printf 'templates/systemd/%s\t%s/%s\n' "${f##*/}" "$AI_SANDBOX_UNIT_DIR" "${f##*/}"; done
  fi
  : "$m"
}

# module_files_check MODULE: exit 0 if the module's files on the host match the repo's.
module_files_check() {
  local m=$1 dir="$AI_SANDBOX_MODULES_DIR/$1" ok=0 src dest
  diff -rq "$dir" "$AI_SANDBOX_SHARE/modules/$m" >/dev/null 2>&1 || { info "$AI_SANDBOX_SHARE/modules/$m is missing or differs"; ok=1; }
  while IFS=$'\t' read -r src dest; do
    case "$src" in
      bin/*) cmp -s "$dir/$src" "$dest" || { info "$dest is missing or differs"; ok=1; } ;;
      skills/*) diff -rq "$dir/$src" "$dest" >/dev/null 2>&1 || { info "$dest is missing or differs"; ok=1; } ;;
      templates/systemd/*) cmp -s <(render "$dir/$src") "$dest" || { info "$dest is missing or differs"; ok=1; } ;;
    esac
  done < <(_module_files "$m")
  modules_installed | grep -qxF "$m" || { info "module $m not recorded as installed"; ok=1; }
  return $ok
}

# module_files_apply MODULE: copies the module's files onto the host and records it as installed.
module_files_apply() {
  local m=$1 dir="$AI_SANDBOX_MODULES_DIR/$1" src dest units=0
  mkdir -p "$AI_SANDBOX_SHARE/modules" "$AI_SANDBOX_BIN" "$HOME/.claude/skills" "$AI_SANDBOX_UNIT_DIR"
  rm -rf "${AI_SANDBOX_SHARE:?}/modules/${m:?}"
  cp -r "$dir" "$AI_SANDBOX_SHARE/modules/$m"
  while IFS=$'\t' read -r src dest; do
    case "$src" in
      bin/*) install -m 755 "$dir/$src" "$dest" ;;
      skills/*) rm -rf "${dest:?}"; cp -r "$dir/$src" "$dest" ;;
      templates/systemd/*) cmp -s <(render "$dir/$src") "$dest" || { render "$dir/$src" > "$dest"; units=1; } ;;
    esac
  done < <(_module_files "$m")
  [ $units = 0 ] || systemctl --user daemon-reload 2>/dev/null || true
  modules_record_installed "$m"
}

# The claude.md lines of every installed module, from the installed copies, in install order.
modules_claude_md() {
  local m f
  for m in $(modules_installed); do
    f="$AI_SANDBOX_SHARE/modules/$m/claude.md"
    [ -f "$f" ] && { echo; render "$f"; }
  done
  return 0
}

# The settings.json fragments of every installed module.
modules_settings_fragments() {
  local m f
  for m in $(modules_installed); do
    f="$AI_SANDBOX_SHARE/modules/$m/settings.json"
    [ -f "$f" ] && echo "$f"
  done
  return 0
}
