#!/usr/bin/env bash
# Package a staged app root into a .deb using dpkg-deb.
# Usage: package-deb.sh <recipe.conf> <root-dir> <output.deb>
#
# The entire root tree is packaged verbatim (any install layout works).
# Optional maintainer scripts: <recipe-dir>/post-install.sh and post-remove.sh
# are emitted as DEBIAN/postinst and DEBIAN/postrm by the stage phase.
set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"

RECIPE="${1:?usage: package-deb.sh <recipe.conf> <root> <out.deb>}"
ROOT_DIR="${2:?}"
OUT="${3:?}"
# shellcheck source=/dev/null
source "$RECIPE"

# /tmp may be a tiny tmpfs on some hosts; build in the cache partition.
BUILDTMP="${CACHE_DIR:-$MLP_ROOT/.cache}"
mkdir -p "$BUILDTMP"
TMP="$(mktemp -d -p "$BUILDTMP")"
trap 'clean_dir "$TMP"' EXIT
PKG="$TMP/pkg"
CTL="$PKG/DEBIAN"

installed_kb="$(du -sk "$ROOT_DIR" | awk '{print $1}')"

copy_tree "$ROOT_DIR" "$PKG"
mkdir -p "$CTL"

# Internal maintainer-script stash -> real DEBIAN scripts.
for kind in postinst postrm; do
  stash="$PKG/.mlp-$kind"
  if [[ -f "$stash" ]]; then
    cp "$stash" "$CTL/$kind"
    chmod 755 "$CTL/$kind"
    rm -f "$stash"
  fi
done
# Launcher(s) executable: every file under usr/bin.
find "$PKG/usr/bin" -type f -exec chmod 755 {} + 2>/dev/null || true

{
  echo "Package: $PKG_NAME"
  echo "Version: $VERSION"
  echo "Section: utils"
  echo "Priority: optional"
  echo "Architecture: amd64"
  echo "Installed-Size: $installed_kb"
  if (( ${#DEPENDS_DEB[@]} )); then
    printf 'Depends: '
    first=1
    for d in "${DEPENDS_DEB[@]}"; do
      (( first )) || printf ', '
      printf '%s' "$d"
      first=0
    done
    printf '\n'
  fi
  if [[ -n "${RECOMMENDS_DEB:-}" ]] && (( ${#RECOMMENDS_DEB[@]} )); then
    printf 'Recommends: '
    first=1
    for d in "${RECOMMENDS_DEB[@]}"; do
      (( first )) || printf ', '
      printf '%s' "$d"
      first=0
    done
    printf '\n'
  fi
  # Packages that own the same paths as this repack (e.g. the vendor's own
  # deb under a different name). Conflicts forbids co-install; Replaces lets
  # dpkg silently take over the overlapping files during the swap.
  if [[ -n "${CONFLICTS_DEB:-}" ]] && (( ${#CONFLICTS_DEB[@]} )); then
    printf 'Conflicts: '
    first=1
    for d in "${CONFLICTS_DEB[@]}"; do
      (( first )) || printf ', '
      printf '%s' "$d"
      first=0
    done
    printf '\n'
  fi
  if [[ -n "${REPLACES_DEB:-}" ]] && (( ${#REPLACES_DEB[@]} )); then
    printf 'Replaces: '
    first=1
    for d in "${REPLACES_DEB[@]}"; do
      (( first )) || printf ', '
      printf '%s' "$d"
      first=0
    done
    printf '\n'
  fi
  echo "Maintainer: mensylisir <710080675@qq.com>"
  echo "Homepage: $URL"
  echo "Description: $DISPLAY_NAME"
  echo " $DESCRIPTION"
  echo " Non-official Linux repack built by mylinuxpackages."
} > "$CTL/control"

# Optional conffiles (one absolute path per line in recipe's conffiles.deb)
CF="$(dirname "$RECIPE")/conffiles.deb"
[[ -f "$CF" ]] && cp "$CF" "$CTL/conffiles"

mkdir -p "$(dirname "$OUT")"
# /tmp may be a tiny tmpfs on some hosts; use build dir for compression scratch.
TMPDIR="${CACHE_DIR:-$MLP_ROOT/.cache}" dpkg-deb --root-owner-group --build -Zxz "$PKG" "$OUT"
echo "built: $OUT"
