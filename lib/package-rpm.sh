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

# rpm resolves its file-attrs config through a compiled-in path
# (/usr/lib/rpm/fileattrs). When rpm itself was unpacked under a prefix - the
# only option on hosts without root - that path does not exist and every build
# aborts with "No file attributes configured". Point rpm at its own prefix.
RPM_DEFINES=()
if [[ ! -d /usr/lib/rpm/fileattrs ]]; then
  rpm_prefix="$(cd "$(dirname "$(command -v rpmbuild)")/../.." && pwd)"
  if [[ -d "$rpm_prefix/usr/lib/rpm/fileattrs" ]]; then
    RPM_DEFINES+=(--define "_fileattrsdir $rpm_prefix/usr/lib/rpm/fileattrs")
    # rpmbuild shells out to %__check_files (a script under %_rpmconfigdir) to
    # compare buildroot against the file list; outside the real prefix it dies
    # with "failed to write all data to /usr/lib/rpm/check-files". The check is
    # redundant for repacked prebuilt payloads, so skip it here only.
    RPM_DEFINES+=(--define "__check_files %{nil}")
  fi
fi

# /tmp may be a tiny tmpfs; build in the cache partition.
BUILDTMP="${CACHE_DIR:-$MLP_ROOT/.cache}"
mkdir -p "$BUILDTMP"
BUILDROOT="$(mktemp -d -p "$BUILDTMP")"
[[ -n "${MLP_KEEP_TMP:-}" ]] || trap 'clean_dir "$BUILDROOT"' EXIT
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
  # Same rationale as CONFLICTS_DEB/REPLACES_DEB in package-deb.sh: vendor
  # packages owning the same paths must be replaced, not co-installed.
  if [[ -n "${CONFLICTS_RPM:-}" ]] && (( ${#CONFLICTS_RPM[@]} )); then
    for d in "${CONFLICTS_RPM[@]}"; do printf 'Conflicts:      %s\n' "$d"; done
  fi
  if [[ -n "${OBSOLETES_RPM:-}" ]] && (( ${#OBSOLETES_RPM[@]} )); then
    for d in "${OBSOLETES_RPM[@]}"; do printf 'Obsoletes:      %s\n' "$d"; done
  fi
  echo "AutoReqProv:    no"
  echo "%description"
  echo "$DISPLAY_NAME - $DESCRIPTION"
  echo "Non-official Linux repack built by mylinuxpackages."
  echo "%install"
  # cp -a preserves hardlinks (electron ships thousands of them), but restoring
  # timestamps fails on hosts that deny futimens() to non-root builders, which
  # aborts %install. Drop only the timestamp attribute, keep the link graph.
  echo 'cp -a --no-preserve=timestamps %{_sourcedir}/payload/. %{buildroot}/ || cp -R %{_sourcedir}/payload/. %{buildroot}/'
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

# Repacked upstream binaries are already stripped and must not be touched:
# rpm's brp-strip/brp-compress choke on paths with spaces (e.g. "/opt/Xiaomi
# MiMo AI") and on leftover Windows objects shipped inside bundled runtimes.
#
# rpm keeps a package database even for -bb; pointing it at the build dir keeps
# the build hermetic (no writes to /var/lib/rpm) and lets unprivileged builders
# run at all ("error: cannot open Packages database in /var/lib/rpm").
mkdir -p "$BUILDROOT/rpmdb"
rpm --define "_dbpath $BUILDROOT/rpmdb" --initdb >/dev/null 2>&1 || true
# rpmbuild shells out for %rmbuild / %install, so it inherits PATH. Hosts that
# wrap rm (sandbox shims, "safe delete" helpers) make %rmbuild refuse to clean
# the build tree, which only surfaces as "Bad exit status from ... (rmbuild)"
# after the payload was built. Give rpmbuild a plain system PATH instead.
RPM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
rpmbindir="$(cd "$(dirname "$(command -v rpmbuild)")" && pwd)"
case ":$RPM_PATH:" in *":$rpmbindir:"*) ;; *) RPM_PATH="$rpmbindir:$RPM_PATH" ;; esac
env PATH="$RPM_PATH" rpmbuild --define "_topdir $BUILDROOT" \
         --define "_dbpath $BUILDROOT/rpmdb" \
         --define "_build_id_links none" \
         --define "debug_package %{nil}" \
         --define "__strip /bin/true" \
         --define "__objdump /bin/true" \
         --define "__os_install_post %{nil}" \
         "${RPM_DEFINES[@]+"${RPM_DEFINES[@]}"}" \
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
