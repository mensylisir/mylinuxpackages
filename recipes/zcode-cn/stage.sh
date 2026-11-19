#!/usr/bin/env bash
# zcode-cn / zcode-intl — official Linux .deb repack. Keeps upstream Electron.
# CN build reorders the built-in provider catalogue to put BigModel first;
# both editions get a dedicated /opt prefix, icons and an AppArmor hook.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local cn=0
  [[ "$APP_ID" == zcode-cn ]] && cn=1
  local prefix launcher desktopname appname
  if (( cn )); then
    prefix="/opt/zcode-cn"; launcher="zcode-cn"; desktopname="zcode.desktop"; appname="zcode-cn"
  else
    prefix="/opt/zcode"; launcher="zcode"; desktopname="zcode-intl.desktop"; appname="zcode"
  fi

  local deb; deb="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  deb_extract "$deb" "$unpack"
  [[ -d "$unpack/opt/ZCode" ]] || die "missing opt/ZCode in deb"

  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications"
  copy_tree "$unpack/opt/ZCode" "$ROOT$prefix"

  if (( cn )); then
    node "$MLP_ROOT/lib/patch/zcode-cn-providers.cjs" "$ROOT$prefix"
    sed -i -e 's|/opt/ZCode|/opt/zcode-cn|g' \
           -e 's|profile "zcode"|profile "zcode-cn"|' \
           -e 's|<local/zcode>|<local/zcode-cn>|' \
      "$ROOT$prefix/resources/apparmor-profile" 2>/dev/null || true
  else
    sed -i 's|/opt/ZCode|/opt/zcode|g' \
      "$ROOT$prefix/resources/apparmor-profile" 2>/dev/null || true
  fi

  # Icons from upstream, badged per edition: both builds ship the same art.
  local src_icon=""
  for cand in "$unpack/usr/share/icons/hicolor/1024x1024/apps/zcode.png" \
              "$unpack/usr/share/icons/hicolor/512x512/apps/zcode.png"; do
    [[ -f "$cand" ]] && { src_icon="$cand"; break; }
  done
  [[ -n "$src_icon" ]] || die "no upstream zcode icon"
  if (( cn )); then
    install_icon_badged_set "$src_icon" "$appname" CN '#C8102E'
  else
    install_icon_badged_set "$src_icon" "$appname" INTL '#2C549E'
  fi

  # Desktop entry.
  install -m644 "$unpack/usr/share/applications/zcode.desktop" \
    "$ROOT/usr/share/applications/$desktopname"
  sed -i -e "s|^Exec=.*|Exec=/usr/bin/$launcher %U|" \
         -e "s|^Icon=.*|Icon=$appname|" \
         -e 's|^StartupWMClass=.*|StartupWMClass=zcode|' \
    "$ROOT/usr/share/applications/$desktopname"
  if (( cn )); then sed -i 's|^Name=.*|Name=ZCode（国内版）|' "$ROOT/usr/share/applications/$desktopname"; fi

  cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/sh
unset ELECTRON_RUN_AS_NODE
export CHROME_DESKTOP='$desktopname'
export ZCODE_APP_DIR="$prefix"
UDD="\${XDG_CONFIG_HOME:-\$HOME/.config}/$appname"
mkdir -p "\$UDD"
exec "$prefix/zcode" --user-data-dir="\$UDD" --class=zcode "\$@"
EOF
  chmod 755 "$ROOT/usr/bin/$launcher"
  chmod 4755 "$ROOT$prefix/chrome-sandbox" 2>/dev/null || true

  mkdir -p "$ROOT/usr/share/licenses/$PKG_NAME"
  for lic in LICENSE.electron.txt LICENSES.chromium.html; do
    [[ -f "$ROOT$prefix/$lic" ]] && ln -s "$prefix/$lic" \
      "$ROOT/usr/share/licenses/$PKG_NAME/$lic"
  done
  if [[ -f "$unpack/usr/share/doc/zcode/changelog.gz" ]]; then
    install -Dm644 "$unpack/usr/share/doc/zcode/changelog.gz" \
      "$ROOT/usr/share/doc/$PKG_NAME/changelog.gz"
  fi

  local profile="$prefix/resources/apparmor-profile"
  local aptarget="/etc/apparmor.d/$appname"
  cat > "$PKG_DIR/post-install.sh" <<HOOK
chmod 4755 '$prefix/chrome-sandbox' 2>/dev/null || true
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
  command -v apparmor_parser >/dev/null 2>&1 && apparmor_parser --remove '$aptarget' || true
  rm -f '$aptarget' '/etc/apparmor.d/cache/$appname'
fi
HOOK
  write_postinst; write_postrm
}
