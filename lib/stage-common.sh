#!/usr/bin/env bash
# Helpers shared by per-recipe stage.sh scripts.
#
# A stage.sh is this repository's own assembly recipe for one application.
# It receives these variables from lib/build.sh:
#   WORK      scratch dir for this build
#   SRC       directory where downloaded sources are placed (the makepkg $srcdir)
#   ROOT      FHS tree to populate (the makepkg $pkgdir / deb-rpm payload)
#   PKG_DIR   directory holding the recipe (patched scripts, icons, launchers)
#   FETCHED   associative array: source filename -> cached file path
#
# Nothing here assumes a particular app: each recipe decides how to assemble
# its own ROOT. These are just the repetitive bits (archive extraction, icon
# scaling, launcher/maintainer script emission, dependency mapping).
set -euo pipefail

MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"

# --- Archive extraction ----------------------------------------------------

# Extract a .deb's data archive into a directory without bsdtar (ar + tar).
# Handles data.tar.gz / .xz / .zst / .bz2. Usage: deb_extract <deb> <dest>
deb_extract() {
  local deb="$1" dest="$2" tmp arlist data
  mkdir -p "$dest"
  tmp="$(mktemp -d)"
  ( cd "$tmp" && ar x "$deb" ) >/dev/null 2>&1 || die "cannot ar x: $deb"
  arlist="$(find "$tmp" -maxdepth 1 -name 'data.tar*' -print)"
  [[ -n "$arlist" ]] || die "no data.tar.* in $deb"
  data="$(printf '%s\n' "$arlist" | head -1)"
  case "$data" in
    *.tar.gz|*.tgz)  tar -xzmf "$data" -C "$dest" --touch ;;
    *.tar.xz|*.txz)  tar -xJmf "$data" -C "$dest" --touch ;;
    *.tar.zst)       tar --zstd -xmf "$data" -C "$dest" --touch ;;
    *.tar.bz2)       tar -xjmf "$data" -C "$dest" --touch ;;
    *)               tar -xmf "$data" -C "$dest" --touch ;;
  esac
  clean_dir "$tmp"
}

# Extract an rpm's payload into a directory without rpm2cpio when possible.
# rpm2cpio+cpio is preferred; otherwise 7z first unwraps the rpm to its payload
# cpio and then unpacks that (7z on an .rpm alone only yields the .cpio).
# Usage: rpm_extract <rpm> <dest>
rpm_extract() {
  local rpm="$1" dest="$2" tmp cpiofile
  mkdir -p "$dest"
  if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
    rpm2cpio "$rpm" | ( cd "$dest" && cpio -idm --quiet ) 2>/dev/null || \
      die "rpm2cpio failed: $rpm"
    return 0
  fi
  tmp="$(mktemp -d -p "${CACHE_DIR:-/tmp}")"
  7z x -y -o"$tmp" "$rpm" >/dev/null 2>&1 || { clean_dir "$tmp"; die "cannot extract rpm: $rpm"; }
  cpiofile="$(find "$tmp" -maxdepth 1 -name '*.cpio' -print -quit)"
  if [[ -n "$cpiofile" ]]; then
    7z x -y -o"$dest" "$cpiofile" >/dev/null 2>&1 || { clean_dir "$tmp"; die "cannot extract rpm payload: $rpm"; }
  else
    # Already a plain tree (e.g. 7z handled it directly).
    copy_tree "$tmp" "$dest"
  fi
  clean_dir "$tmp"
}

# Extract any tarball into a directory (auto-detect compression).
tar_extract() {
  local archive="$1" dest="$2" strip="${3:-0}"
  mkdir -p "$dest"
  local flag
  case "$archive" in
    *.tar.gz|*.tgz)   flag=z ;;
    *.tar.xz|*.txz)   flag=J ;;
    *.tar.zst)        flag='--zstd' ;;
    *.tar.bz2)        flag=j ;;
    *)                flag='' ;;
  esac
  local opts=( -x -m -f "$archive" -C "$dest" --touch --no-same-owner )
  (( strip > 0 )) && opts+=( --strip-components="$strip" )
  if [[ -n "$flag" ]]; then
    tar "$flag" "${opts[@]}"
  else
    tar "${opts[@]}"
  fi
}

# --- Files -----------------------------------------------------------------

fetched() { printf '%s\n' "${FETCHED[$1]:?source not fetched: $1}"; }

# Path of the first remote (non-local) source. Most recipes have exactly one
# upstream archive (deb/rpm/exe/tgz), so this avoids hardcoding its filename.
fetched_remote() {
  local entry name url sum
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url sum <<<"$entry"
    [[ "$url" == local:* ]] && continue
    printf '%s\n' "${FETCHED[$name]}"
    return 0
  done
  printf 'no remote source for %s\n' "$APP_ID" >&2
  return 1
}

# Path of a remote source whose name matches a shell glob (e.g. '*sandbox*').
fetched_glob() {
  local pattern="$1" entry name url sum
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url sum <<<"$entry"
    [[ "$url" == local:* ]] && continue
    [[ "$name" == $pattern ]] && { printf '%s\n' "${FETCHED[$name]}"; return 0; }
  done
  printf 'no source matching %s in %s\n' "$pattern" "$APP_ID" >&2
  return 1
}

# Install an icon at every hicolor size, generating missing sizes from the
# largest source PNG with ImageMagick when available.
# Usage: fix_desktop_entry <desktop-file> <exec-name>
#
# Vendor .desktop files point at the unpacked rpm layout (/opt/<Vendor>/...,
# /usr/share/<vendor>/...). Rewrite them so they launch our installed wrapper
# and reference icons by name, which is case- and path-independent.
fix_desktop_entry() {
  local d="$1" exe="$2" tmp
  [[ -f "$d" ]] || return 0
  tmp="$d.mlp-tmp"
  awk -v exe="$exe" '
    /^Exec=/    { print "Exec=" exe " %U"; next }
    /^TryExec=/ { print "TryExec=" exe; next }
    /^Icon=/    {
                  v = $0; sub(/^Icon=/, "", v)
                  if (v ~ /\//) {
                    n = split(v, a, "/"); v = a[n]
                    sub(/\.(png|svg|xpm)$/, "", v)
                  }
                  print "Icon=" v; next
                }
    { print }
  ' "$d" > "$tmp" && mv "$tmp" "$d"
}

# --- Edition badges --------------------------------------------------------
# Upstream ships one identical icon for both the domestic and the overseas
# build of some apps, so the launcher cannot tell them apart. Mirrors the
# myaur convention: a circular badge (white ring + disc + label) in the
# bottom-right corner, 30% of the icon diameter, default CN crimson C8102E,
# INTL navy 2C549E.
# Usage: badge_icon <src-png> <dst-png> <size> [label] [bg]
badge_icon() {
  local src="$1" dst="$2" size="$3" label="${4:-CN}" bg="${5:-#C8102E}"
  [[ -f "$src" ]] || die "icon not found: $src"
  local tool; tool="$(command -v magick || command -v convert)" || \
    die "ImageMagick required for edition badges"
  local bw pad ring pointsize tmp font
  bw=$(( size * 30 / 100 )); (( bw < 7 )) && bw=7
  pad=$(( size * 5 / 100 ));  (( pad < 1 )) && pad=1
  ring=$(( bw / 12 ));        (( ring < 1 )) && ring=1
  pointsize=$(( bw * 45 / 100 )); (( ${#label} >= 4 )) && pointsize=$(( bw * 27 / 100 ))
  (( pointsize < 4 )) && pointsize=4
  font="DejaVu-Sans-Bold"
  "$tool" -list font 2>/dev/null | grep -q "Font: $font" || font="$( \
    "$tool" -list font 2>/dev/null | sed -n 's/^ *Font: //p' | head -1)"
  tmp="$(mktemp -d)"
  "$tool" -size "${bw}x${bw}" xc:none \
      -fill white -draw "circle $(( bw / 2 )),$(( bw / 2 )) $(( bw / 2 )),0" \
      -fill "$bg" -draw "circle $(( bw / 2 )),$(( bw / 2 )) $(( bw / 2 )),${ring}" \
      ${font:+-font "$font"} -gravity center -pointsize "$pointsize" \
      -fill white -annotate +0+0 "$label" "$tmp/badge.png"
  install -d "$(dirname "$dst")"
  "$tool" "$src" -resize "${size}x${size}" "$tmp/badge.png" \
      -gravity southeast -geometry "+${pad}+${pad}" -composite "$dst"
  clean_dir "$tmp"
}

# Badge every hicolor size of an icon. Usage:
#   install_icon_badged_set <src-png> <dest-name> [label] [bg]
install_icon_badged_set() {
  local src="$1" name="$2" label="${3:-CN}" bg="${4:-#2C549E}" size
  for size in 16 24 32 48 64 96 128 256 512; do
    badge_icon "$src" "$ROOT/usr/share/icons/hicolor/${size}x${size}/apps/${name}.png" \
      "$size" "$label" "$bg"
  done
}

# Usage: install_icon_set <src-png> <dest-name>
install_icon_set() {
  local src="$1" name="$2" size
  [[ -f "$src" ]] || die "icon not found: $src"
  if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
    local tool; tool="$(command -v magick || command -v convert)"
    local tmp; tmp="$(mktemp -d)"
    for size in 16 24 32 48 64 96 128 256 512; do
      "$tool" "$src" -strip -resize "${size}x${size}" "$tmp/${size}.png" 2>/dev/null || \
        cp "$src" "$tmp/${size}.png"
      install -Dm644 "$tmp/${size}.png" \
        "$ROOT/usr/share/icons/hicolor/${size}x${size}/apps/${name}.png"
    done
    clean_dir "$tmp"
  else
    install -Dm644 "$src" "$ROOT/usr/share/icons/hicolor/512x512/apps/${name}.png"
  fi
}

# --- Maintainer scripts ----------------------------------------------------

# Emit a Debian postinst that runs the recipe's post-install hook (if any)
# and refreshes desktop/icon caches. Passed through package-deb.sh.
write_postinst() {
  local recipe_hook="$PKG_DIR/post-install.sh"
  local out="$ROOT/.mlp-postinst"
  {
    echo '#!/bin/sh'
    echo 'set -e'
    echo '[ -x /usr/bin/update-desktop-database ] && update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true'
    echo '[ -x /usr/bin/gtk-update-icon-cache ] && gtk-update-icon-cache -q -f /usr/share/icons/hicolor >/dev/null 2>&1 || true'
    if [[ -f "$recipe_hook" ]]; then
      echo '# --- recipe post-install ---'
      cat "$recipe_hook"
    fi
    echo 'exit 0'
  } > "$out"
  chmod 755 "$out"
}

write_postrm() {
  local recipe_hook="$PKG_DIR/post-remove.sh"
  local out="$ROOT/.mlp-postrm"
  {
    echo '#!/bin/sh'
    echo 'set -e'
    if [[ -f "$recipe_hook" ]]; then
      echo '# --- recipe post-remove ---'
      cat "$recipe_hook"
    fi
    echo 'exit 0'
  } > "$out"
  chmod 755 "$out"
}
