#!/usr/bin/env bash
# CatPaw / 妙手 — official Windows-only Inno Setup app converted to a full
# Linux Electron app. Ships its own Electron 42.11.2 + Node 24 + Python 3.12
# runtimes, rebuilds native modules against Electron headers, and patches the
# bundled JS for Linux. All tools are our own implementations in lib/patch.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local cn=0
  [[ "$APP_ID" == catpaw-cn ]] && cn=1
  local APP_NAME APP_ID_VAL DISPLAY_NAME appdir desktop
  if (( cn )); then
    APP_NAME="catpaw-cn"; APP_ID_VAL="com.catx.catpaw.cn"; DISPLAY_NAME="妙手"
    appdir="catpaw-cn"; desktop="catpaw-moon.desktop"
  else
    APP_NAME="catpaw"; APP_ID_VAL="com.catx.catpaw.overseas"; DISPLAY_NAME="CatPaw"
    appdir="catpaw"; desktop="catpaw-overseas.desktop"
  fi
  local ELECTRON_VER="42.11.2" NODE_VER="24.18.0" PYTHON_VER="3.12.13"

  need node-gyp "npm install -g node-gyp"
  local exe inno ezip eheaders ntgz ptgz
  exe="$(fetched_glob 'catpaw*.exe')"
  inno="$(fetched_glob 'innoextract*')"
  ezip="$(fetched_glob 'electron-v*.zip')"
  eheaders="$(fetched_glob 'node-v*-headers.tar.gz')"
  ntgz="$(fetched_glob 'node-v*-linux-x64.tar.gz')"
  ptgz="$(fetched_glob 'cpython-*.tar.gz')"

  local W="$WORK/cp"; clean_dir "$W"; mkdir -p "$W"
  info() { printf '  -> %s\n' "$*" >&2; }
  pkg_extract() { local t="$1" d="$2"; mkdir -p "$d"
    tar -xzmf "$t" -C "$d" --strip-components=1 --no-same-owner --touch; }

  # --- 1. Inno Setup extraction --------------------------------------------
  info "extracting Windows installer (Inno Setup)"
  chmod 755 "$inno"
  mkdir -p "$W/win"
  "$inno" -d "$W/win" "$exe" >/dev/null || die "innoextract failed"
  local resdir
  # Temp list instead of <( ... ): /dev/fd is not available in every
  # build sandbox.
  find "$W/win" -type f -name app.asar -printf '%h\n' > "$WORK/app-asar-dirs"
  mapfile -t dirs < "$WORK/app-asar-dirs"
  [[ ${#dirs[@]} -eq 1 ]] || die "expected exactly one app.asar, got ${#dirs[@]}"
  resdir="${dirs[0]}"

  # --- 2. Electron headers -------------------------------------------------
  mkdir -p "$W/headers"
  tar -xzmf "$eheaders" -C "$W/headers" --no-same-owner --touch
  [[ -f "$W/headers/node_headers/include/node/config.gypi" ]] || die "unexpected headers layout"

  # --- 3. Electron shell ---------------------------------------------------
  local out="$W/out"; clean_dir "$out"; mkdir -p "$out"
  unzip -q "$ezip" -d "$out"
  [[ -x "$out/electron" ]] || die "electron binary missing"
  mv "$out/electron" "$out/$APP_NAME"
  rm -f "$out/chrome-sandbox" "$out/resources/default_app.asar"
  touch "$out/resources/.keep"

  # --- 4. Payload ----------------------------------------------------------
  info "copying application payload"
  cp "$resdir/app.asar" "$out/resources/app.asar"
  cp -a --no-preserve=timestamps "$resdir/app.asar.unpacked" "$out/resources/app.asar.unpacked"
  mkdir -p "$out/resources/app"
  if [[ -f "$resdir/app/product.json" ]]; then cp "$resdir/app/product.json" "$out/resources/app/product.json"
  elif [[ -f "$resdir/product.json" ]]; then
    cp "$resdir/product.json" "$out/resources/app/product.json"
    cp "$resdir/product.json" "$out/resources/product.json"; fi
  local d
  for d in cli cli-apps app-extensions skills wasm; do
    [[ -d "$resdir/$d" ]] && cp -a --no-preserve=timestamps "$resdir/$d" "$out/resources/$d"; done
  [[ -d "$out/resources/cli" && -f "$out/resources/cli/catpaw-cli.js" ]] || die "cli payload missing"
  for f in icon.png tray-iconTemplate.png tray-iconTemplate@2x.png; do
    [[ -f "$resdir/$f" ]] && cp "$resdir/$f" "$out/resources/$f"; done
  find "$out/resources" -name '*:com.apple.cs.*' -type f -delete 2>/dev/null || true
  find "$out/resources" -name '*.lproj' -type d -prune -exec clean_dir {} + 2>/dev/null || true
  clean_dir "$out/resources/native"; clean_dir "$out/resources/runtimes"
  rm -f "$out/resources/bin/paw" "$out/resources/bin/paw.cmd"

  # --- 5. Native modules ---------------------------------------------------
  info "rebuilding native modules for Electron ABI"
  local nm="$out/resources/app.asar.unpacked/node_modules"
  [[ -d "$nm" ]] || die "app.asar.unpacked/node_modules missing"
  rm -rf "$nm"/@img/sharp-* "$nm"/@img/sharp-libvips-* "$nm"/@napi-rs/canvas-* \
         "$nm"/@koromix/koffi-* "$nm/koffi/node_modules/@koromix" \
         "$nm"/@wecom/cli-* "$nm"/@catpaw/office-runtime-* "$nm"/@vscode/windows-* 2>/dev/null || true
  rm -f "$nm"/agent-browser/bin/agent-browser-* \
        "$nm/@catpaw/agent-sdk/bin/catpaw-cli.exe" 2>/dev/null || true
  clean_dir "$nm/node-pty/build/Release/conpty"; clean_dir "$nm/node-pty/build/Release/winpty"
  clean_dir "$nm/set-global-proxy/lib/win"
  for d in "$nm"/@ffmpeg-installer/*; do
    case "$(basename "$d")" in linux-*) ;; *) clean_dir "$d" ;; esac; done
  if [[ -d "$nm/@esbuild" ]]; then
    for d in "$nm"/@esbuild/*; do case "$(basename "$d")" in linux-x64) ;; *) clean_dir "$d" ;; esac; done
    [[ -f "$nm/@esbuild/linux-x64/bin/esbuild" ]] || die "esbuild linux-x64 missing"
    install -m755 "$nm/@esbuild/linux-x64/bin/esbuild" "$nm/esbuild/bin/esbuild"; fi
  clean_dir "$nm/node-pty/prebuilds"; clean_dir "$nm/node-pty/bin"
  clean_dir "$nm/bufferutil/prebuilds"; clean_dir "$nm/bufferutil/bin"
  clean_dir "$nm/utf-8-validate/prebuilds"; clean_dir "$nm/utf-8-validate/bin"
  find "$nm/node-pty" -name '*.node' -path '*/build/*' -delete 2>/dev/null || true

  build_gyp() {
    local t="$1" name="$2"
    local work="$W/gyp-$name"
    info "building $name"
    pkg_extract "$t" "$work"
    [[ "$name" == node-pty ]] && pkg_extract "$(fetched_glob 'node-addon-api-*.tgz')" "$work/node_modules/node-addon-api"
    (cd "$work" && node-gyp rebuild --nodedir="$W/headers/node_headers" --target_arch=x64 --release) \
      >"$W/$name.build.log" 2>&1 || { tail -40 "$W/$name.build.log" >&2; die "node-gyp failed: $name"; }
  }
  build_gyp "$(fetched_glob 'node-pty-*.tgz')" node-pty
  mkdir -p "$nm/node-pty/build/Release"
  cp "$W/gyp-node-pty/build/Release/pty.node" "$nm/node-pty/build/Release/pty.node"
  find "$nm/node-pty" -name spawn-helper -delete 2>/dev/null || true

  mkdir -p "$W/bs"; tar -xzmf "$(fetched_glob 'better-sqlite3-*.tar.gz')" -C "$W/bs" --no-same-owner --touch
  [[ -f "$W/bs/build/Release/better_sqlite3.node" ]] || die "better_sqlite3.node missing"
  mkdir -p "$nm/better-sqlite3/build/Release"
  cp "$W/bs/build/Release/better_sqlite3.node" "$nm/better-sqlite3/build/Release/"

  build_gyp "$(fetched_glob 'bufferutil-*.tgz')" bufferutil
  mkdir -p "$nm/bufferutil/build/Release"
  cp "$W/gyp-bufferutil/build/Release/bufferutil.node" "$nm/bufferutil/build/Release/"
  build_gyp "$(fetched_glob 'utf-8-validate-*.tgz')" utf-8-validate
  mkdir -p "$nm/utf-8-validate/build/Release"
  cp "$W/gyp-utf-8-validate/build/Release/validation.node" "$nm/utf-8-validate/build/Release/"

  pkg_extract "$(fetched_glob 'koffi-linux-*.tgz')" "$nm/@koromix/koffi-linux-x64"
  pkg_extract "$(fetched_glob 'koffi-linux-*.tgz')" "$nm/koffi/node_modules/@koromix/koffi-linux-x64"
  pkg_extract "$(fetched_glob 'sharp-linux-*.tgz')" "$nm/@img/sharp-linux-x64"
  pkg_extract "$(fetched_glob 'sharp-libvips-*.tgz')" "$nm/@img/sharp-libvips-linux-x64"
  pkg_extract "$(fetched_glob 'canvas-linux-*.tgz')" "$nm/@napi-rs/canvas-linux-x64-gnu"
  pkg_extract "$(fetched_glob 'wecom-cli-*.tgz')" "$nm/@wecom/cli-linux-x64"
  chmod 755 "$nm/@wecom/cli-linux-x64/bin/wecom-cli" 2>/dev/null || true
  pkg_extract "$(fetched_glob 'ffmpeg-linux-*.tgz')" "$nm/@ffmpeg-installer/linux-x64"
  chmod 755 "$nm/@ffmpeg-installer/linux-x64/ffmpeg"

  mkdir -p "$W/ab"; tar -xzmf "$(fetched_glob 'agent-browser-*.tgz')" -C "$W/ab" \
    package/bin/agent-browser-linux-x64 --no-same-owner --touch
  install -m755 "$W/ab/package/bin/agent-browser-linux-x64" \
    "$nm/agent-browser/bin/agent-browser-linux-x64"
  install -m755 "$(fetched_glob 'catpaw-cli-*')" "$nm/@catpaw/agent-sdk/bin/catpaw-cli"
  find "$nm" -type f -name '*.node' -exec chmod 755 {} +

  # --- 6. Managed runtimes manifest ----------------------------------------
  info "writing Linux runtime manifest"
  local run="$out/resources/runtimes"; mkdir -p "$run"
  local na="node-v${NODE_VER}-linux-x64.tar.gz" pa="cpython-${PYTHON_VER}-linux-x64-install_only.tar.gz"
  cp "$ntgz" "$run/$na"; cp "$ptgz" "$run/$pa"
  local nsha psha; nsha="$(sha256sum "$run/$na"|cut -d' ' -f1)"; psha="$(sha256sum "$run/$pa"|cut -d' ' -f1)"
  cat > "$run/manifest.json" <<EOF
{"schemaVersion":2,"platform":"linux","arch":"x64","assets":[
{"id":"node","version":"${NODE_VER}","archiveFile":"${na}","archiveType":"tar.gz","stripComponents":1,"sha256":"${nsha}","executableRelativePath":"bin/node","pathDirs":["bin"],"maxFiles":12000,"maxUncompressedBytes":419430400},
{"id":"python","version":"${PYTHON_VER}","archiveFile":"${pa}","archiveType":"tar.gz","stripComponents":1,"sha256":"${psha}","executableRelativePath":"bin/python3.12","pathDirs":["bin"],"maxFiles":10000,"maxUncompressedBytes":629145600}]}
EOF

  # --- 7. JS patches -------------------------------------------------------
  info "patching + registering unpacked files in asar"
  node "$MLP_ROOT/lib/patch/skill-manifests.cjs" "$out/resources/skills" 2>/dev/null || true
  node "$MLP_ROOT/lib/patch/repack-asar.cjs" "$out/resources/app.asar" "$out/resources/app.asar.unpacked"
  node "$MLP_ROOT/lib/patch/overlay-linux.cjs" "$out/resources/app.asar"

  # --- 8. paw CLI + metadata -----------------------------------------------
  mkdir -p "$out/resources/bin"
  cat > "$out/resources/bin/paw" <<'PAW'
#!/bin/sh
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
SOURCE="$0"; while [ -L "$SOURCE" ]; do
  D="$(cd "${SOURCE%/*}" && pwd)"; SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$D/$SOURCE" ;; esac; done
SD="$(cd "${SOURCE%/*}" && pwd)"; RES="${SD%/*}"; CLI="$RES/cli/catpaw-cli.js"
[ -f "$CLI" ] || { echo "CLI not found: $CLI" >&2; exit 1; }
EB="$RES/../APP_NAME"
[ -x "$EB" ] || { echo "Electron not found: $EB" >&2; exit 1; }
ELECTRON_RUN_AS_NODE=1 exec "$EB" "$CLI" "$@"
PAW
  sed -i "s|APP_NAME|$APP_NAME|g" "$out/resources/bin/paw"
  chmod 755 "$out/resources/bin/paw"
  mkdir -p "$out/.port"
  cat > "$out/.port/build-info.json" <<EOF
{"appId":"$APP_ID_VAL","displayName":"$DISPLAY_NAME","electronVersion":"$ELECTRON_VER","nodeRuntime":"$NODE_VER","pythonRuntime":"$PYTHON_VER","platform":"linux-x64"}
EOF

  # --- 9. Lay out ROOT -----------------------------------------------------
  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
           "$ROOT/usr/share/icons/hicolor" "$ROOT/usr/share/licenses/$PKG_NAME"
  copy_tree "$out" "$ROOT/opt/$appdir"

  cat > "$ROOT/usr/bin/$APP_NAME" <<EOF
#!/bin/sh
unset ELECTRON_RUN_AS_NODE
export CHROME_DESKTOP='${desktop}'
exec /opt/$appdir/$APP_NAME --no-sandbox --disable-dev-shm-usage --class=${desktop%.desktop} "\$@"
EOF
  chmod 755 "$ROOT/usr/bin/$APP_NAME"
  install -m644 "$PKG_DIR/$desktop" "$ROOT/usr/share/applications/$desktop"
  for s in 16 24 32 48 64 128 256 512; do
    [[ -f "$PKG_DIR/${desktop%.desktop}-${s}.png" ]] && install -Dm644 \
      "$PKG_DIR/${desktop%.desktop}-${s}.png" \
      "$ROOT/usr/share/icons/hicolor/${s}x${s}/apps/${desktop%.desktop}.png"
  done
  install -m644 "$ROOT/opt/$appdir/LICENSE" "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE.electron" 2>/dev/null || true
  [[ -f "$PKG_DIR/DISCLAIMER" ]] && install -m644 "$PKG_DIR/DISCLAIMER" "$ROOT/usr/share/licenses/$PKG_NAME/DISCLAIMER"
  write_postinst
}
