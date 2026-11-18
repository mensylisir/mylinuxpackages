#!/usr/bin/env bash
# trae-ide / trae-cn-ide — official Linux tarball. Lay out under /opt, wire
# up launcher/desktop/icon/completions, then strip dead weight.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local cn=0
  [[ "$APP_ID" == trae-cn-ide ]] && cn=1
  local launcher appdir desktop wmclass
  if (( cn )); then launcher="trae-cn"; appdir="trae-cn"; desktop="trae-cn.desktop"; wmclass="Trae-cn"
  else launcher="trae"; appdir="trae"; desktop="trae.desktop"; wmclass="Trae"; fi

  local tgz; tgz="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  tar_extract "$tgz" "$unpack"

  # The tarball extracts to a single top dir holding the app; find it.
  local srcdir="$unpack"
  if [[ $(find "$unpack" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
     && [[ ! -d "$unpack/usr" ]]; then
    srcdir="$(find "$unpack" -mindepth 1 -maxdepth 1 -type d | head -1)"
  fi

  mkdir -p "$ROOT/opt/$appdir" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
           "$ROOT/usr/share/licenses/$PKG_NAME"
  copy_tree "$srcdir" "$ROOT/opt/$appdir"
  chmod 4755 "$ROOT/opt/$appdir/chrome-sandbox" 2>/dev/null || true

  # Launcher: prefer this edition's upstream launcher; fall back safely.
  local up=""
  if (( cn )); then up="$srcdir/trae-cn.sh"; else up="$srcdir/trae.sh"; fi
  if [[ -f "$up" ]] || { (( cn )) && [[ -f "$srcdir/trae.sh" ]]; }; then
    [[ -f "$up" ]] || up="$srcdir/trae.sh"
    install -m755 "$up" "$ROOT/usr/bin/$launcher"
  else
    local mainbin
    mainbin="$(find "$ROOT/opt/$appdir" -maxdepth 1 -type f -executable -printf '%f\n' | grep -iE 'trae|^code$' | head -1)"
    [[ -n "$mainbin" ]] || mainbin="$(find "$ROOT/opt/$appdir" -maxdepth 1 -type f -executable -printf '%f\n' | head -1)"
    cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/sh
exec /opt/$appdir/$mainbin --class=$wmclass "\$@"
EOF
    chmod 755 "$ROOT/usr/bin/$launcher"
  fi

  install -m644 "$PKG_DIR/$desktop" "$ROOT/usr/share/applications/$desktop"
  local icon="$ROOT/opt/$appdir/resources/app/resources/linux/code.png"
  [[ -f "$icon" ]] && install -Dm644 "$icon" \
    "$ROOT/usr/share/icons/hicolor/512x512/apps/$launcher.png"

  # Licenses + shell completions.
  local lic="$ROOT/opt/$appdir/resources/app/LICENSE.txt"
  [[ -f "$lic" ]] && install -m644 "$lic" "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE"
  if [[ -f "$ROOT/opt/$appdir/resources/app/ThirdPartyNotices.txt" ]]; then
    install -m644 "$ROOT/opt/$appdir/resources/app/ThirdPartyNotices.txt" \
      "$ROOT/usr/share/licenses/$PKG_NAME/ThirdPartyNotices"
  fi
  if [[ -f "$ROOT/opt/$appdir/LICENSES.chromium.html" ]]; then
    install -m644 "$ROOT/opt/$appdir/LICENSES.chromium.html" \
      "$ROOT/usr/share/licenses/$PKG_NAME/LICENSES.chromium.html"
  fi
  [[ -f "$ROOT/opt/$appdir/resources/completions/bash/trae" ]] && \
    install -Dm644 "$ROOT/opt/$appdir/resources/completions/bash/trae" \
      "$ROOT/usr/share/bash-completion/completions/$launcher"
  [[ -f "$ROOT/opt/$appdir/resources/completions/zsh/_trae" ]] && \
    install -Dm644 "$ROOT/opt/$appdir/resources/completions/zsh/_trae" \
      "$ROOT/usr/share/zsh/site-functions/_$launcher"

  # Strip dead weight.
  clean_dir "$ROOT/opt/$appdir/node_modules"
  find "$ROOT/opt/$appdir" -name '*.asc' -delete 2>/dev/null || true
  find "$ROOT/opt/$appdir" -name '*.bat' -delete 2>/dev/null || true
  find "$ROOT/opt/$appdir" -type d -name rush-logs -prune -exec clean_dir {} + 2>/dev/null || true
  rm -f "$ROOT/opt/$appdir/resources/app/modules/ckg/binary/libstdc++.so.6" \
        "$ROOT/opt/$appdir/resources/app/modules/ckg/binary/libgcc_s.so.1" 2>/dev/null || true
  write_postinst
}
