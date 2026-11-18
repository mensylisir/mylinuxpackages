#!/usr/bin/env bash
# mimo-desktop / mimo-desktop-intl — official Linux .deb repack. Keeps the
# upstream Electron runtime. Derives hicolor icons from the single 1024px PNG
# and (CN build) compiles envguard.so to dodge an upstream E2BIG bug.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local cn=0
  [[ "$APP_ID" == mimo-desktop ]] && cn=1
  local appdir prefix launcher iconname desktopsrc docdir
  if (( cn )); then
    appdir="Xiaomi MiMo"; prefix="/opt/Xiaomi MiMo"
    launcher="mimo-desktop-bin"; iconname="mimo-desktop-bin"
    desktopsrc="xiaomi-mimo.desktop"; docdir="xiaomi-mimo-desktop"
  else
    appdir="Xiaomi MiMo AI"; prefix="/opt/Xiaomi MiMo AI"
    launcher="mimo-desktop-intl-bin"; iconname="mimo-desktop-intl-bin"
    desktopsrc="xiaomi-mimo-ai.desktop"; docdir="xiaomi-mimo-desktop-ai"
  fi

  local deb; deb="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  deb_extract "$deb" "$unpack"
  [[ -d "$unpack/opt/$appdir" ]] || die "missing opt/$appdir in deb"

  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/lib/$PKG_NAME" \
           "$ROOT/usr/share/applications"
  copy_tree "$unpack/opt/$appdir" "$ROOT$prefix"
  chmod 0755 "$ROOT$prefix/chrome-sandbox" 2>/dev/null || true

  # Icon: upstream ships one 1024px PNG; derive all hicolor sizes.
  local icon
  if (( cn )); then
    icon="$unpack/usr/share/icons/hicolor/1024x1024/apps/xiaomi-mimo-desktop.png"
  else
    icon="$unpack/usr/share/icons/hicolor/1024x1024/apps/xiaomi-mimo-desktop-ai.png"
  fi
  install_icon_set "$icon" "$iconname"

  # Desktop entry: keep upstream name (it is the app's declared app id), but
  # point Exec/Icon at our launcher/icons.
  install -m644 "$unpack/usr/share/applications/$desktopsrc" \
    "$ROOT/usr/share/applications/$desktopsrc"
  sed -i -e "s|^Exec=.*|Exec=/usr/bin/$launcher %U|" \
         -e "s|^Icon=.*|Icon=$iconname|" \
    "$ROOT/usr/share/applications/$desktopsrc"

  # envguard.so (CN build) — filter oversized env strings from child processes.
  if (( cn )); then
    local cc="${CC:-cc}"
    "$cc" -fPIC -shared -o "$WORK/envguard.so" "$MLP_ROOT/lib/patch/envguard.c"
    install -m755 "$WORK/envguard.so" "$ROOT/usr/lib/$PKG_NAME/envguard.so"
  fi

  # Launcher (own implementation): preload envguard (CN) and point at the app.
  cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/sh
BASE="$prefix"
export MIMOCODE_APP_DIR="\$BASE"
EOF
  if (( cn )); then
    cat >> "$ROOT/usr/bin/$launcher" <<'EOF'
if [ -f /usr/lib/mimo-desktop-bin/envguard.so ]; then
  LD_PRELOAD="/usr/lib/mimo-desktop-bin/envguard.so${LD_PRELOAD:+:$LD_PRELOAD}"
  export LD_PRELOAD
fi
EOF
  fi
  # Detect the upstream main executable inside the app dir (name differs
  # between domestic and overseas builds).
  local mainbin=""
  for cand in qianfan-desktop-app xiaomi-mimo-desktop "Xiaomi MiMo AI" mimo-desktop; do
    [[ -x "$ROOT$prefix/$cand" ]] && { mainbin="$cand"; break; }
  done
  if [[ -z "$mainbin" ]]; then
    mainbin="$(find "$ROOT$prefix" -maxdepth 1 -type f -executable -printf '%f\n' | head -1)"
  fi
  [[ -n "$mainbin" ]] || die "cannot find main executable in $prefix"
  printf 'exec "\$BASE/%s" "\$@"\n' "$mainbin" >> "$ROOT/usr/bin/$launcher"
  chmod 755 "$ROOT/usr/bin/$launcher"

  # Licenses + changelog.
  mkdir -p "$ROOT/usr/share/licenses/$PKG_NAME"
  for lic in LICENSE.electron.txt LICENSES.chromium.html; do
    [[ -f "$ROOT$prefix/$lic" ]] && ln -s "$prefix/$lic" \
      "$ROOT/usr/share/licenses/$PKG_NAME/$lic"
  done
  if [[ -f "$unpack/usr/share/doc/$docdir/changelog.gz" ]]; then
    install -Dm644 "$unpack/usr/share/doc/$docdir/changelog.gz" \
      "$ROOT/usr/share/doc/$PKG_NAME/changelog.gz"
  fi

  # AppArmor profile load + setuid sandbox (mirrors upstream postinst).
  local target="$prefix/chrome-sandbox"
  local profile="$prefix/resources/apparmor-profile"
  local aptarget
  if (( cn )); then aptarget="/etc/apparmor.d/xiaomi-mimo-desktop"; else aptarget="/etc/apparmor.d/xiaomi-mimo-desktop-ai"; fi
  cat > "$PKG_DIR/post-install.sh" <<HOOK
chmod 4755 '$target' 2>/dev/null || true
if command -v apparmor_status >/dev/null 2>&1 && apparmor_status --enabled >/dev/null 2>&1 \\
  && command -v apparmor_parser >/dev/null 2>&1 && [ -f '$profile' ] \\
  && apparmor_parser --skip-kernel-load --debug '$profile' >/dev/null 2>&1; then
  install -Dm644 '$profile' '$aptarget'
  if ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --replace --write-cache --skip-read-cache '$aptarget' || true
  fi
fi
HOOK
  cat > "$PKG_DIR/post-remove.sh" <<HOOK
if [ -f '$aptarget' ]; then
  if command -v apparmor_parser >/dev/null 2>&1 \\
    && ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --remove '$aptarget' || true
  fi
  rm -f '$aptarget' '/etc/apparmor.d/cache/'"$(basename "$aptarget")"
fi
HOOK
  write_postinst; write_postrm
}
