#!/usr/bin/env bash
# Package a staged app root into a .rpm using rpmbuild (native, no nfpm).
# Usage: package-rpm.sh <recipe.conf> <root-dir> <output.rpm>
# Requires: rpmbuild (Ubuntu: apt-get install rpm)
set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"

RECIPE="${1:?usage: package-rpm.sh <recipe.conf> <root> <out.rpm>}"
ROOT_DIR="${2:?}"
OUT="${3:?}"
# shellcheck source=/dev/null
source "$RECIPE"

need rpmbuild "apt-get install rpm"

BUILDROOT="$(mktemp -d)"
trap 'clean_dir "$BUILDROOT"' EXIT
mkdir -p "$BUILDROOT"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}

# Copy staged root into BUILDROOT so rpmbuild installs it like a normal payload.
copy_tree "$ROOT_DIR" "$BUILDROOT/SOURCES/payload"

SPEC="$BUILDROOT/SPECS/$PKG_NAME.spec"
{
  echo "Name:           $PKG_NAME"
  echo "Version:        $VERSION"
  echo "Release:        1%{?dist}"
  echo "Summary:        $DESCRIPTION"
  echo "License:        Proprietary"
  echo "URL:            $URL"
  echo "BuildArch:      x86_64"
  if (( ${#DEPENDS_RPM[@]} )); then
    printf 'Requires:       %s\n' "${DEPENDS_RPM[0]}"
    for d in "${DEPENDS_RPM[@]:1}"; do printf 'Requires:       %s\n' "$d"; done
  fi
  echo "AutoReqProv:    no"
  echo "%description"
  echo "$DISPLAY_NAME - $DESCRIPTION"
  echo "Non-official Linux repack built by mylinuxpackages."
  echo "%install"
  echo "cp -a %{_sourcedir}/payload/. %{buildroot}/"
  echo "%files"
  echo "%defattr(-,root,root,-)"
  echo "/opt/$APP_DIR"
  echo "/usr/bin/$STRING_NAME"
  echo "/usr/share/applications/$STRING_NAME.desktop"
  echo "/usr/share/icons/hicolor/*/apps/$STRING_NAME.png"
  echo "/usr/share/licenses/$PKG_NAME"
} > "$SPEC"

rpmbuild --define "_topdir $BUILDROOT" \
         --define "_build_id_links none" \
         -bb "$SPEC" >"$BUILDROOT/rpmbuild.log" 2>&1 || {
  tail -n 60 "$BUILDROOT/rpmbuild.log" >&2
  die "rpmbuild failed"
}

mkdir -p "$(dirname "$OUT")"
cp "$BUILDROOT/RPMS/noarch/"*.rpm "$OUT" 2>/dev/null || \
cp "$BUILDROOT/RPMS/x86_64/"*.rpm "$OUT"
echo "built: $OUT"
