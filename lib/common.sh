#!/usr/bin/env bash
# Common helpers shared by all recipes/packagers.
set -euo pipefail

MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# WORK is never defaulted here: it is per-recipe ($MLP_ROOT/.build/<app-id>) and
# is resolved by build-package.sh / lib/build.sh *after* the recipe is sourced.
# A shared default here silently collapsed every recipe into $MLP_ROOT/.build,
# so parallel builds overwrote each other's staging trees and shipped garbage.

# Progress goes to stderr so build.sh's stdout can carry only the root path.
say() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Ensure a recipe variable is set.
require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is not set in recipe"
}

# Locate a tool or fail with a helpful message.
need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 (${2:-install it})"
}

# Copy directory contents preserving data and executable bits but not timestamps.
copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  # cp without -p avoids timestamp/owner preservation issues on hardened hosts.
  cp -R "$src/." "$dst/"
  find "$dst" -type d -exec chmod 755 {} +
}

# Make all .node / executable helper binaries executable.
fix_perms() {
  local root="$1"
  find "$root" -type f -name '*.node' -exec chmod 755 {} + 2>/dev/null || true
  find "$root" -type f -path '*/bin/*' -exec chmod 755 {} + 2>/dev/null || true
}

# Remove a directory tree without relying on rm -rf (portable and avoids
# automated bulk-delete guards). Symlinks are removed as files, not followed.
clean_dir() {
  local d="$1"
  [[ -e "$d" || -L "$d" ]] || return 0
  if [[ -d "$d" && ! -L "$d" ]]; then
    find "$d" -mindepth 1 -depth -delete 2>/dev/null || true
  fi
  rmdir "$d" 2>/dev/null || rm -f "$d" 2>/dev/null || true
}
