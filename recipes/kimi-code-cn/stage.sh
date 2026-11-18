#!/usr/bin/env bash
# kimi-code-cn / kimi-code-intl — upstream ships a Linux .deb. We unpack it,
# pin the API region in app.asar (own patch tool), isolate config/scheme, and
# reassemble under a dedicated /opt prefix with its own launcher.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local cn=0
  [[ "$APP_ID" == kimi-code-cn ]] && cn=1
  local prefix appname region launcher
  if (( cn )); then
    prefix="/opt/kimi-code-cn"; appname="kimi-code-app-cn"; region="mainland-cn"
    launcher="kimi-code-cn"
  else
    prefix="/opt/kimi-code-intl"; appname="kimi-code-app-intl"; region="global"
    launcher="kimi-code"
  fi

  local deb; deb="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  deb_extract "$deb" "$unpack"

  local srcapp="$unpack/opt/Kimi Code"
  [[ -d "$srcapp" ]] || die "upstream deb lacks 'opt/Kimi Code'"

  # Patch app.asar: extract -> pin region -> repack.
  local asardir="$WORK/asar"
  clean_dir "$asardir"; mkdir -p "$asardir"
  asar extract "$srcapp/resources/app.asar" "$asardir"
  node "$MLP_ROOT/lib/patch/kimi-code-region.cjs" "$asardir" "$region" "$appname"
  local newasar="$WORK/app.asar"
  rm -f "$newasar"
  asar pack "$asardir" "$newasar"

  # Assemble ROOT under the dedicated prefix.
  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
           "$ROOT/usr/share/licenses/$PKG_NAME"
  copy_tree "$srcapp" "$ROOT$prefix"
  install -m644 "$newasar" "$ROOT$prefix/resources/app.asar"
  rm -f "$ROOT$prefix/resources/app-update.yml"
  (( cn )) && mv "$ROOT$prefix/kimi-code" "$ROOT$prefix/kimi-code-cn"
  # SUID sandbox helper (as upstream postinst did).
  chmod 4755 "$ROOT$prefix/chrome-sandbox" 2>/dev/null || true

  # Launcher.
  cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/sh
exec "$prefix/$launcher" "\$@"
EOF
  chmod 755 "$ROOT/usr/bin/$launcher"

  # Desktop entry (static resource from recipe) + icons.
  install -m644 "$PKG_DIR/${launcher}.desktop" \
    "$ROOT/usr/share/applications/${launcher}.desktop"
  install_icon_set "$PKG_DIR/${launcher}-512.png" "$launcher"

  # License: upstream app dir carries Electron/Chromium license texts.
  for lic in LICENSE.electron.txt LICENSES.chromium.html; do
    [[ -f "$ROOT$prefix/$lic" ]] && ln -s "$prefix/$lic" \
      "$ROOT/usr/share/licenses/$PKG_NAME/$lic"
  done
  write_postinst; write_postrm
}
