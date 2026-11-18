#!/usr/bin/env bash
# Package a staged app root into a .deb using dpkg-deb.
# Usage: package-deb.sh <recipe.conf> <root-dir> <output.deb>
set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"

RECIPE="${1:?usage: package-deb.sh <recipe.conf> <root> <out.deb>}"
ROOT_DIR="${2:?}"
OUT="${3:?}"
# shellcheck source=/dev/null
source "$RECIPE"

TMP="$(mktemp -d)"
trap 'clean_dir "$TMP"' EXIT
CTL="$TMP/DEBIAN"
mkdir -p "$CTL"

installed_kb="$(du -sk "$ROOT_DIR" | awk '{print $1}')"

{
  echo "Package: $PKG_NAME"
  echo "Version: $VERSION"
  echo "Section: utils"
  echo "Priority: optional"
  echo "Architecture: amd64"
  echo "Installed-Size: $installed_kb"
  if (( ${#DEPENDS_DEB[@]} )); then
    printf 'Depends: '
    local_first=1
    for d in "${DEPENDS_DEB[@]}"; do
      (( local_first )) || printf ', '
      printf '%s' "$d"
      local_first=0
    done
    printf '\n'
  fi
  echo "Maintainer: mensylisir <710080675@qq.com>"
  echo "Homepage: $URL"
  echo "Description: $DISPLAY_NAME"
  echo " $DESCRIPTION"
  echo " Non-official Linux repack built by mylinuxpackages."
} > "$CTL/control"

copy_tree "$ROOT_DIR" "$TMP/root"

# Ensure launcher is executable inside the package.
chmod 755 "$TMP/root/usr/bin/$STRING_NAME" 2>/dev/null || true

mkdir -p "$(dirname "$OUT")"
# /tmp may be a tiny tmpfs on some hosts; use build dir for compression scratch.
TMPDIR="${CACHE_DIR:-$MLP_ROOT/.cache}" dpkg-deb --root-owner-group --build -Zxz "$TMP" "$OUT"
echo "built: $OUT"
