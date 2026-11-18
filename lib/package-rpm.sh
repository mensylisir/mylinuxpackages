#!/usr/bin/env bash
# Package a staged app root into a .rpm using rpmbuild (native, no nfpm).
# Usage: package-rpm.sh <recipe.conf> <root-dir> <output.rpm>
#
# The %files list is generated from whatever is actually in the root, so this
# works for any install layout (/opt prefixes, /usr/lib, symlinks, icon sets,
# systemd units, ...). Maintainer scripts from the stage phase become %post/%postun.
set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"

RECIPE="${1:?usage: package-rpm.sh <recipe.conf> <root> <out.rpm>}"
ROOT_DIR="${2:?}"
OUT="${3:?}"
# shellcheck source=/dev/null
source "$RECIPE"

need rpmbuild "apt-get install rpm"

# /tmp may be a tiny tmpfs; build in the cache partition.
BUILDTMP="${CACHE_DIR:-$MLP_ROOT/.cache}"
mkdir -p "$BUILDTMP"
BUILDROOT="$(mktemp -d -p "$BUILDTMP")"
trap 'clean_dir "$BUILDROOT"' EXIT
mkdir -p "$BUILDROOT"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}

copy_tree "$ROOT_DIR" "$BUILDROOT/SOURCES/payload"

# Pull maintainer scripts out of the payload before generating the file list.
post=""
postun=""
for kind in postinst postrm; do
  stash="$BUILDROOT/SOURCES/payload/.mlp-$kind"
  if [[ -f "$stash" ]]; then
    if [[ "$kind" == postinst ]]; then post="$(cat "$stash")"; else postun="$(cat "$stash")"; fi
    rm -f "$stash"
  fi
done

# Build %files from the staged tree. Each top-level entry covers its subtree;
# symlinks and files at any depth are included. Paths with spaces are escaped.
FILELIST="$BUILDROOT/SPECS/files.list"
: > "$FILELIST"
(
  cd "$BUILDROOT/SOURCES/payload"
  find . -mindepth 1 -print0 | sed -z 's|^\./|/|' | sort -z
) | while IFS= read -r -d '' p; do
  # Escape spaces and other spec-significant characters for rpm %files.
  esc="${p//\\/\\\\}"; esc="${esc//%/%%}"; esc="${esc// /\\ }"
  esc="${esc//\(/\\(}"; esc="${esc//\)/\\)}"
  printf '%s\n' "$esc" >> "$FILELIST"
done

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
  # %files -f resolves relative paths against %_builddir, not %_specdir,
  # so hand it the absolute path of the generated list.
  echo "%files -f $FILELIST"
  echo "%defattr(-,root,root,-)"
  # Directory ownership is covered by -f; no explicit dirs needed.
  if [[ -n "$post" ]]; then
    echo "%post"
    printf '%s\n' "$post"
  fi
  if [[ -n "$postun" ]]; then
    echo "%postun"
    printf '%s\n' "$postun"
  fi
} > "$SPEC"

rpmbuild --define "_topdir $BUILDROOT" \
         --define "_build_id_links none" \
         -bb "$SPEC" >"$BUILDROOT/rpmbuild.log" 2>&1 || {
  tail -n 80 "$BUILDROOT/rpmbuild.log" >&2
  echo "--- spec ---" >&2
  cat "$SPEC" >&2
  die "rpmbuild failed"
}

mkdir -p "$(dirname "$OUT")"
built="$(find "$BUILDROOT/RPMS" -type f -name '*.rpm' -print -quit)"
[[ -n "$built" ]] || die "rpmbuild produced no rpm"
cp "$built" "$OUT"
echo "built: $OUT"
