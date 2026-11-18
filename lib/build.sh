#!/usr/bin/env bash
# Generic Electron-app repack builder.
#
# A recipe is a shell file that sets the variables/functions described below;
# this script turns it into a clean, Linux-ready app tree at $WORK/stage.
#
# Recipe contract:
#   APP_ID            short key, e.g. minimax-code-cn
#   PKG_NAME          debian/rpm package name
#   VERSION           upstream version
#   DISPLAY_NAME      human name
#   STRING_NAME       binary name installed to /usr/bin
#   EXEC_NAME         executable name inside /opt/<APP_DIR>
#   APP_DIR           install dir name under /opt
#   URL               homepage
#   DESCRIPTION       one-line description
#   ARCH              x86_64 (default)
#   ELECTRON_VERSION  version of Electron to substitute
#   NODE_ABI          ABI for prebuilt native modules (e.g. 146)
#   DEPENDS_DEB=(...) DEPENDS_RPM=(...)
#   SOURCES=( "name|url|sha256" ... )
#   EXE_FILE          filename of upstream installer in SOURCES
#   EXE_FORMAT        nsis | inno | plain-deb
#   PAYLOAD_INNER     for nsis: path of inner archive, e.g. '$PLUGINSDIR/app-64.7z'
#   PATCHES=( "script.js|arg1 arg2" ... )   -- node scripts run on app.asar
#   NATIVE_NAPI=( "tgzfile|dest/path" ... ) -- replacement .node packages
#   NATIVE_PREBUILT=( "tgzfile|dest/path|internal.tgz" ... )
#   NATIVE_GYP=( "src.tgz|addon-api.tgz|headers.tgz|dest/path" ... )
#   recipe_prune()    optional: extra cleanup of stage tree
#   recipe_install()  optional: emit extra files into $WORK/root via install -D
#   recipe_patch_region_mode  optional: region mode for patch-region.js

set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"
source "$MLP_ROOT/lib/fetch.sh"

RECIPE_FILE="${1:?usage: build.sh <recipe.conf>}"
[[ -f "$RECIPE_FILE" ]] || die "recipe not found: $RECIPE_FILE"
# shellcheck source=/dev/null
source "$RECIPE_FILE"

for v in APP_ID PKG_NAME VERSION DISPLAY_NAME STRING_NAME EXEC_NAME APP_DIR \
         URL DESCRIPTION ELECTRON_VERSION; do require "$v"; done
ARCH="${ARCH:-x86_64}"
PKG_DIR="${MLP_ROOT}/recipes/${APP_ID}"
WORK="${WORK:-$MLP_ROOT/.build/${APP_ID}}"
STAGE="$WORK/stage"
ROOT="$WORK/root"
CACHE_DIR="${CACHE_DIR:-$MLP_ROOT/.cache}"

need curl; need sha256sum; need tar; need unzip; need node; need 7z "p7zip-full / p7zip"
need node-gyp "npm install -g node-gyp"

clean_dir "$WORK/stage"; clean_dir "$WORK/root"
clean_dir "$WORK/payload"; clean_dir "$WORK/nsis"
mkdir -p "$WORK" "$STAGE" "$ROOT"

say "[$APP_ID $VERSION] fetching sources"
mlp_fetch_all

say "[$APP_ID] unpacking upstream installer ($EXE_FORMAT)"
EXE="${FETCHED[$EXE_FILE]}"
case "$EXE_FORMAT" in
  nsis)
    7z x -y -o"$WORK/nsis" "$EXE" >/dev/null
    7z x -y -o"$WORK/payload" "$WORK/nsis/$PAYLOAD_INNER" >/dev/null
    ;;
  inno)
    INNOEXTRACT="${FETCHED[$INNOEXTRACT_FILE]}"
    chmod 755 "$INNOEXTRACT"
    "$INNOEXTRACT" "$EXE" -d "$WORK/payload" >/dev/null
    ;;
  *) die "unsupported EXE_FORMAT: $EXE_FORMAT" ;;
esac

say "[$APP_ID] assembling Linux runtime"
unzip -q "${FETCHED[electron-v${ELECTRON_VERSION}-linux-x64.zip]}" -d "$STAGE"
mv "$STAGE/electron" "$STAGE/$EXEC_NAME"
rm -f "$STAGE/chrome-sandbox" "$STAGE/resources/default_app.asar"

copy_tree "$WORK/payload/resources/app.asar.unpacked" "$STAGE/resources/app.asar.unpacked"
if [[ -d "$WORK/payload/resources/resources" ]]; then
  copy_tree "$WORK/payload/resources/resources" "$STAGE/resources/resources"
fi
cp "$WORK/payload/resources/app.asar" "$STAGE/resources/app.asar"
rm -f "$STAGE/resources/app-update.yml"

NM="$STAGE/resources/app.asar.unpacked/node_modules"

say "[$APP_ID] pruning Windows/macOS binaries"
find "$NM" -maxdepth 3 -type d \( -name '*win32*' -o -name '*darwin*' \) -prune -exec clean_dir {} + 2>/dev/null || true
clean_dir "$NM/@earendil-works/pi-tui/native"
clean_dir "$NM/node-pty/prebuilds"
clean_dir "$NM/@minimax/mcode-sandbox-runtime/vendor/srt-win"
find "$NM" -type f \( -name '*.exe' -o -name '*.dll' \) -delete 2>/dev/null || true
if [[ -d "$STAGE/resources/resources" ]]; then
  find "$STAGE/resources/resources" -type d -name 'win32-*' -prune -exec clean_dir {} + 2>/dev/null || true
fi
declare -f recipe_prune >/dev/null && recipe_prune

say "[$APP_ID] applying asar patches"
for spec in "${PATCHES[@]:-}"; do
  [[ -z "$spec" ]] && continue
  IFS='|' read -r script args <<<"$spec"
  node "$PKG_DIR/$script" "$STAGE/resources/app.asar" $args
done

say "[$APP_ID] installing Linux native modules"
for spec in "${NATIVE_NAPI[@]:-}"; do
  [[ -z "$spec" ]] && continue
  IFS='|' read -r tgz dest <<<"$spec"
  mlp_extract_tgz "${FETCHED[$tgz]}" "$NM/$dest"
done
for spec in "${NATIVE_PREBUILT[@]:-}"; do
  [[ -z "$spec" ]] && continue
  IFS='|' read -r tgz dest inner <<<"$spec"
  tmp="$(mktemp -d)"
  tar -xzmf "${FETCHED[$tgz]}" -C "$tmp" --touch
  mkdir -p "$NM/$dest"
  cp "$tmp/$inner" "$NM/$dest/"
  clean_dir "$tmp"
done
for spec in "${NATIVE_GYP[@]:-}"; do
  [[ -z "$spec" ]] && continue
  IFS='|' read -r src addon headers dest <<<"$spec"
  pty="$WORK/build-$(basename "$src" .tgz)"
  hdrs="$WORK/build-headers"
  mlp_extract_tgz "${FETCHED[$src]}" "$pty"
  mlp_extract_tgz "${FETCHED[$addon]}" "$pty/node_modules/node-addon-api"
  mkdir -p "$hdrs"
  tar -xzmf "${FETCHED[$headers]}" -C "$hdrs" --touch
  (cd "$pty" && node-gyp rebuild --nodedir="$hdrs/node_headers" --target_arch=x64 --release) \
    >"$WORK/gyp-$(basename "$src").log" 2>&1 || {
      tail -n 40 "$WORK/gyp-$(basename "$src").log" >&2; die "node-gyp failed for $src"; }
  mkdir -p "$NM/$dest"
  cp "$pty/build/Release/$(basename "$dest").node" "$NM/$dest/" 2>/dev/null || \
  cp "$pty/build/Release/pty.node" "$NM/$dest/"
done

# Rebuild asar header so newly added unpacked files are visible to Electron.
if [[ -f "$PKG_DIR/repack-asar.js" ]]; then
  node "$PKG_DIR/repack-asar.js" "$STAGE/resources/app.asar" "$STAGE/resources/app.asar.unpacked"
fi

fix_perms "$STAGE"

say "[$APP_ID] laying out package root"
mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor" \
         "$ROOT/usr/share/licenses/$PKG_NAME"
copy_tree "$STAGE" "$ROOT/opt/$APP_DIR"
install -m755 "$PKG_DIR/$STRING_NAME.sh" "$ROOT/usr/bin/$STRING_NAME"
install -m644 "$PKG_DIR/$STRING_NAME.desktop" \
  "$ROOT/usr/share/applications/$STRING_NAME.desktop"
for size in 16 24 32 48 64 128 256 512; do
  icon="$PKG_DIR/$STRING_NAME-${size}.png"
  [[ -f "$icon" ]] || continue
  install -Dm644 "$icon" \
    "$ROOT/usr/share/icons/hicolor/${size}x${size}/apps/$STRING_NAME.png"
done
[[ -f "$STAGE/LICENSE" ]] && install -m644 "$STAGE/LICENSE" \
  "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE.electron"
[[ -f "$STAGE/LICENSES.chromium.html" ]] && install -m644 "$STAGE/LICENSES.chromium.html" \
  "$ROOT/usr/share/licenses/$PKG_NAME/LICENSES.chromium.html"
declare -f recipe_install >/dev/null && recipe_install

echo "$ROOT"
say "[$APP_ID] stage ready at $STAGE"
