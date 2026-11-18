#!/usr/bin/env bash
# Qoder agent / IDE — upstream rpm carries the app resources but relies on a
# distro electron package. We ship a matching Electron (43 for agent, 42 for
# IDE) from the mirror and launch through a resourcesPath-override preload.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local is_ide=0 cn=0
  [[ "$APP_ID" == *ide ]] && is_ide=1
  [[ "$APP_ID" == *cn* ]] && cn=1

  local appname libdir launcher
  if (( is_ide )); then
    if (( cn )); then appname="qoder-cn-ide"; else appname="qoder-ide"; fi
  else
    if (( cn )); then appname="qoder-cn"; else appname="qoder"; fi
  fi
  launcher="$appname"; libdir="$appname"

  local rpm; rpm="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  rpm_extract "$rpm" "$unpack"

  # Locate the app dir: the directory holding resources.pak with a resources/
  # subdir (mirrors the upstream _get_app_dir()).
  local appdir
  appdir="$(find "$unpack" -type f -name resources.pak -printf '%h\n' 2>/dev/null \
    | while read -r d; do [[ -d "$d/resources" ]] && { echo "$d"; break; }; done)"
  [[ -n "$appdir" ]] || die "cannot locate app dir (resources.pak + resources/) in rpm"
  local resdir="$appdir/resources"

  mkdir -p "$ROOT/usr/lib/$libdir" "$ROOT/usr/bin" "$ROOT/usr/share/applications"
  copy_tree "$resdir" "$ROOT/usr/lib/$libdir/"

  # Drop foreign-platform resources.
  find "$ROOT/usr/lib/$libdir" -type d \( -name '*win32*' -o -name '*darwin*' -o -name '*arm64*' \) \
    -prune -exec clean_dir {} + 2>/dev/null || true

  # Ship our own Electron under /usr/lib/<app>-electron.
  local elec_zip="electron-v${ELECTRON_VERSION}-linux-x64.zip"
  local edir="$ROOT/usr/lib/${libdir}-electron"
  mkdir -p "$edir"
  unzip -q "$(fetched "$elec_zip")" -d "$edir"
  # Electron's default_app.asar is not needed; keep LICENSE files.
  rm -f "$edir/resources/default_app.asar"
  local electron_bin="$edir/electron"

  # Install resourcesPath override preload.
  install -m644 "$MLP_ROOT/lib/patch/qoder-resources.cjs" \
    "$ROOT/usr/lib/$libdir/$launcher.js"

  # Determine the app entry (app.asar / app / app.asar.unpacked).
  local runname
  if [[ -f "$ROOT/usr/lib/$libdir/app.asar" ]]; then runname="app.asar"
  elif [[ -d "$ROOT/usr/lib/$libdir/app" ]]; then runname="app"
  else die "no Electron app entry under /usr/lib/$libdir"; fi

  # sharp's libvips is referenced via a relative path from /usr/lib/<app>/lib.
  if [[ -e "$ROOT/usr/lib/$libdir/app.asar.unpacked/node_modules/@img/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.17.3" ]]; then
    mkdir -p "$ROOT/usr/lib/$libdir/lib"
    ln -sf "../app.asar.unpacked/node_modules/@img/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.17.3" \
      "$ROOT/usr/lib/$libdir/lib/libvips-cpp.so.8.17.3"
  fi

  # Desktop entry + icons from the rpm.
  find "$unpack" -path '*/share/applications/*' -type f \( -name '*.desktop' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        install -m644 "$f" "$ROOT/usr/share/applications/$(basename "$f")"
        local d="$ROOT/usr/share/applications/$(basename "$f")"
        fix_desktop_entry "$d" "$launcher"
        if grep -qE '^(Exec|TryExec|Icon)=/(opt|usr/share)/' "$d"; then
          die "desktop entry still has absolute source paths: $d"
        fi
      done
  find "$unpack" -path '*/share/icons/*' -type f \( -name '*.png' -o -name '*.svg' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        rel="${f#*/share/icons/}"; install -Dm644 "$f" "$ROOT/usr/share/icons/$rel"
      done

  # Pick the desktop id actually shipped by this rpm variant.
  local desktop_id="$launcher.desktop"
  if [[ ! -f "$ROOT/usr/share/applications/$desktop_id" ]]; then
    desktop_id="$(find "$ROOT/usr/share/applications" -maxdepth 1 -type f -name '*.desktop' -printf '%f\n' | head -1)"
    [[ -n "$desktop_id" ]] || die "no desktop entry shipped in rpm"
  fi

  # Launcher: use bundled Electron with the override preload.
  cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/bash
set -e
export _APPDIR="/usr/lib/$libdir"
export CHROME_DESKTOP="$desktop_id"
export LD_LIBRARY_PATH="\${_APPDIR}/lib:\${LD_LIBRARY_PATH:-}"
unset ELECTRON_RUN_AS_NODE
exec "$electron_bin" --no-sandbox --require "\${_APPDIR}/$launcher.js" \
  --app "\${_APPDIR}/$runname" "\$@"
EOF
  chmod 755 "$ROOT/usr/bin/$launcher"

  # License from rpm.
  if [[ -f "$unpack/usr/share/licenses/LICENSE.html" ]]; then
    install -Dm644 "$unpack/usr/share/licenses/LICENSE.html" \
      "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE.html"
  fi
  write_postinst
}
