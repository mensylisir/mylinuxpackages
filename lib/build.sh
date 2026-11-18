#!/usr/bin/env bash
# Generic build driver: download + verify sources, then let the recipe turn
# them into a clean FHS tree at $WORK/root that both packagers consume.
#
# Two build styles are supported:
#
#  1. STAGE_MODE=recipe (default when recipes/<id>/stage.sh exists)
#     The recipe owns assembly. lib/build.sh fetches every SOURCE, exports
#     WORK/SRC/ROOT/PKG_DIR/FETCHED, then runs recipes/<id>/stage.sh, which
#     owns all app-specific assembly logic in this repository.
#     This is the flexible path used for apps with their own Electron runtime,
#     custom install layouts, post-install hooks, etc.
#
#  2. STAGE_MODE=generic (legacy, minimax-code-cn/intl)
#     The shared Electron-repack pipeline in this file assembles the tree.
#
# Recipe contract (see README): APP_ID PKG_NAME VERSION DISPLAY_NAME
# STRING_NAME EXEC_NAME APP_DIR URL DESCRIPTION DEPENDS_DEB DEPENDS_RPM SOURCES.
set -euo pipefail
MLP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MLP_ROOT/lib/common.sh"
source "$MLP_ROOT/lib/fetch.sh"

RECIPE_FILE="${1:?usage: build.sh <recipe.conf>}"
[[ -f "$RECIPE_FILE" ]] || die "recipe not found: $RECIPE_FILE"
# shellcheck source=/dev/null
source "$RECIPE_FILE"

for v in APP_ID PKG_NAME VERSION DISPLAY_NAME STRING_NAME URL DESCRIPTION; do require "$v"; done
ARCH="${ARCH:-x86_64}"
PKG_DIR="$(cd "$(dirname "$RECIPE_FILE")" && pwd)"
WORK="${WORK:-$MLP_ROOT/.build/${APP_ID}}"
SRC="$WORK/src"
ROOT="$WORK/root"
STAGE="$WORK/stage"
CACHE_DIR="${CACHE_DIR:-$MLP_ROOT/.cache}"

need curl; need sha256sum; need tar; need unzip; need node

clean_dir "$WORK/src"; clean_dir "$WORK/root"; clean_dir "$WORK/stage"
clean_dir "$WORK/payload"; clean_dir "$WORK/nsis"
mkdir -p "$WORK" "$SRC" "$ROOT"

say "[$APP_ID $VERSION] fetching sources"
mlp_fetch_all

# Export context for a per-recipe stage script.
export WORK SRC ROOT STAGE PKG_DIR CACHE_DIR
export APP_ID PKG_NAME VERSION DISPLAY_NAME STRING_NAME URL DESCRIPTION ARCH

STAGE_MODE="${STAGE_MODE:-}"
if [[ -z "$STAGE_MODE" && -f "$PKG_DIR/stage.sh" ]]; then
  STAGE_MODE=recipe
fi

case "$STAGE_MODE" in
  recipe)
    say "[$APP_ID] assembling root via recipe stage.sh"
    # shellcheck source=/dev/null
    source "$PKG_DIR/stage.sh"
    declare -f recipe_stage >/dev/null || die "stage.sh must define recipe_stage()"
    recipe_stage >&2
    ;;
  generic|legacy)
    generic_stage >&2
    ;;
  *)
    die "unknown STAGE_MODE: $STAGE_MODE (need stage.sh or STAGE_MODE=generic)"
    ;;
esac

[[ -d "$ROOT" ]] || die "stage produced no root directory"
# Common finishing touches that apply to every package.
find "$ROOT" -type f -name '*.node' -exec chmod 755 {} + 2>/dev/null || true
find "$ROOT/usr/bin" -type f -exec chmod 755 {} + 2>/dev/null || true
find "$ROOT" -type f \( -name '*.desktop' -o -name '*.png' -o -name '*.svg' \) \
  -exec chmod 644 {} + 2>/dev/null || true

echo "$ROOT"
say "[$APP_ID] root ready at $ROOT"

# ---------------------------------------------------------------------------
# Legacy generic Electron-repack pipeline (minimax-code-cn / intl).
# ---------------------------------------------------------------------------
generic_stage() {
  source "$MLP_ROOT/lib/stage-common.sh"
  for v in ELECTRON_VERSION EXEC_NAME APP_DIR; do require "$v"; done
  need 7z "p7zip-full / p7zip"
  need node-gyp "npm install -g node-gyp"

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
  local ez; ez="$(fetched "electron-v${ELECTRON_VERSION}-linux-x64.zip")"
  unzip -q "$ez" -d "$STAGE"
  mv "$STAGE/electron" "$STAGE/$EXEC_NAME"
  rm -f "$STAGE/chrome-sandbox" "$STAGE/resources/default_app.asar"

  copy_tree "$WORK/payload/resources/app.asar.unpacked" "$STAGE/resources/app.asar.unpacked"
  if [[ -d "$WORK/payload/resources/resources" ]]; then
    copy_tree "$WORK/payload/resources/resources" "$STAGE/resources/resources"
  fi
  cp "$WORK/payload/resources/app.asar" "$STAGE/resources/app.asar"
  rm -f "$STAGE/resources/app-update.yml"

  local NM="$STAGE/resources/app.asar.unpacked/node_modules"

  say "[$APP_ID] pruning Windows/macOS binaries"
  find "$NM" -maxdepth 3 -type d \( -name '*win32*' -o -name '*darwin*' \) -prune -exec clean_dir {} + 2>/dev/null || true
  find "$NM" -type f \( -name '*.exe' -o -name '*.dll' \) -delete 2>/dev/null || true
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
    local tmp; tmp="$(mktemp -d)"
    tar -xzmf "${FETCHED[$tgz]}" -C "$tmp" --touch
    mkdir -p "$NM/$dest"
    cp "$tmp/$inner" "$NM/$dest/"
    clean_dir "$tmp"
  done
  for spec in "${NATIVE_GYP[@]:-}"; do
    [[ -z "$spec" ]] && continue
    IFS='|' read -r src addon headers dest <<<"$spec"
    local pty="$WORK/build-$(basename "$src" .tgz)"
    local hdrs="$WORK/build-headers"
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

  if [[ -f "$PKG_DIR/repack-asar.js" ]]; then
    node "$PKG_DIR/repack-asar.js" "$STAGE/resources/app.asar" "$STAGE/resources/app.asar.unpacked"
  fi
  fix_perms "$STAGE"

  say "[$APP_ID] laying out package root"
  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
           "$ROOT/usr/share/icons/hicolor" "$ROOT/usr/share/licenses/$PKG_NAME"
  copy_tree "$STAGE" "$ROOT/opt/$APP_DIR"
  install -m755 "$PKG_DIR/$STRING_NAME.sh" "$ROOT/usr/bin/$STRING_NAME"
  install -m644 "$PKG_DIR/$STRING_NAME.desktop" \
    "$ROOT/usr/share/applications/$STRING_NAME.desktop"
  install_icon_set "$PKG_DIR/$STRING_NAME-512.png" "$STRING_NAME"
  [[ -f "$STAGE/LICENSE" ]] && install -m644 "$STAGE/LICENSE" \
    "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE.electron"
  [[ -f "$STAGE/LICENSES.chromium.html" ]] && install -m644 "$STAGE/LICENSES.chromium.html" \
    "$ROOT/usr/share/licenses/$PKG_NAME/LICENSES.chromium.html"
  declare -f recipe_install >/dev/null && recipe_install
  write_postinst; write_postrm
}
