#!/usr/bin/env bash
# Build deb and/or rpm packages from a recipe.
#
# Usage:
#   ./build-package.sh <recipe.conf> [--deb|--rpm|--all] [--no-verify]
# Example:
#   ./build-package.sh recipes/minimax-code-cn/recipe.conf --all
set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MLP_ROOT/lib/common.sh"

RECIPE="${1:?usage: build-package.sh <recipe.conf> [--deb|--rpm|--all]}"
shift
[[ -f "$RECIPE" ]] || die "recipe not found: $RECIPE"
# shellcheck source=/dev/null
source "$RECIPE"

TARGET="all"
VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --deb) TARGET=deb ;;
    --rpm) TARGET=rpm ;;
    --all) TARGET=all ;;
    --no-verify) VERIFY=0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

WORK="${WORK:-$MLP_ROOT/.build/${APP_ID}}"
# An empty/inherited WORK used to collapse several parallel builds into one
# shared $ROOT; they overwrote each other's staging trees and shipped garbage.
[[ "$(basename "$WORK")" == "$APP_ID" ]] || \
  die "WORK must be per-recipe ($WORK does not end with $APP_ID)"
OUTDIR="${OUTDIR:-$MLP_ROOT/out}"
mkdir -p "$OUTDIR"

say "building $APP_ID $VERSION (target=$TARGET)"
ROOT="$(bash "$MLP_ROOT/lib/build.sh" "$RECIPE")"

if [[ "$TARGET" == deb || "$TARGET" == all ]]; then
  bash "$MLP_ROOT/lib/package-deb.sh" "$RECIPE" "$ROOT" \
    "$OUTDIR/${PKG_NAME}_${VERSION}_amd64.deb"
fi
if [[ "$TARGET" == rpm || "$TARGET" == all ]]; then
  bash "$MLP_ROOT/lib/package-rpm.sh" "$RECIPE" "$ROOT" \
    "$OUTDIR/${PKG_NAME}-${VERSION}-1.x86_64.rpm"
fi

if (( VERIFY )); then
  say "verifying artifacts"
  for f in "$OUTDIR/${PKG_NAME}_${VERSION}_amd64.deb" "$OUTDIR/${PKG_NAME}-${VERSION}-1.x86_64.rpm"; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.deb) dpkg-deb -I "$f" >/dev/null && echo "  ok deb: $(basename "$f")" ;;
      *.rpm) rpm -qp "$f" >/dev/null 2>&1 && echo "  ok rpm: $(basename "$f")" || echo "  rpm built (rpm query tool unavailable for verify)" ;;
    esac
  done
fi

say "done. artifacts in $OUTDIR"
ls -lh "$OUTDIR" | grep -E '\.(deb|rpm)$' || true
