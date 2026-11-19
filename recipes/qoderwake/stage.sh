#!/usr/bin/env bash
# qoderwake / qoderwake-cn - Linux runtime tarball with a writable-runtime
# wrapper. The daemon needs a writable install dir, so /usr/lib holds a
# read-only master and /usr/bin/<name> stages a private copy per user.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local cn=0
  [[ "$APP_ID" == *-cn ]] && cn=1
  local tgz name libdir upver
  if (( cn )); then
    name="qoderwake-cn"; libdir="qoderwake-cn"; upver="1.2.20-cn"
  else
    name="qoderwake"; libdir="qoderwake"; upver="1.2.20"
  fi
  tgz="$(fetched_remote)"

  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  tar_extract "$tgz" "$unpack"   # tarball is flat (no top-level dir)

  install -dm755 "$ROOT/usr/lib/$libdir/qodercli" "$ROOT/usr/bin" \
    "$ROOT/usr/share/applications"
  install -m755 "$unpack/$name" "$ROOT/usr/lib/$libdir/$name"
  install -m755 "$unpack/qodercli/qodercli-wake" \
    "$ROOT/usr/lib/$libdir/qodercli/qodercli-wake" 2>/dev/null || \
  install -m755 "$unpack/qodercli/qodercli-cn-wake" \
    "$ROOT/usr/lib/$libdir/qodercli/qodercli-cn-wake"
  copy_tree "$unpack/resources" "$ROOT/usr/lib/$libdir/resources"
  find "$ROOT/usr/lib/$libdir" -type d -name __pycache__ -prune -exec clean_dir {} + 2>/dev/null || true

  local cli="qodercli-wake"
  (( cn )) && cli="qodercli-cn-wake"
  ln -sf "../lib/$libdir/qodercli/$cli" "$ROOT/usr/bin/$cli"

  # Wrapper: stage a writable copy of the executable in the user's data dir.
  cat > "$ROOT/usr/bin/$name" <<WRAPPER
#!/bin/sh
set -u
_src='/usr/lib/$libdir'
_ver='$upver'
_root="\${XDG_DATA_HOME:-\${HOME}/.local/share}/$name"
_runtime="\${_root}/runtime"
if [ ! -f "\${_runtime}/.version" ] || [ "\$(cat "\${_runtime}/.version" 2>/dev/null)" != "\${_ver}" ]; then
  mkdir -p "\${_root}" || exit 1
  _tmp="\${_root}/runtime.new.\$\$"
  rm -rf "\${_tmp}"; mkdir -p "\${_tmp}" || exit 1
  install -m755 "\${_src}/$name" "\${_tmp}/$name" || exit 1
  ln -s "\${_src}/resources" "\${_tmp}/resources"
  ln -s "\${_src}/qodercli" "\${_tmp}/qodercli"
  printf '%s\n' "\${_ver}" > "\${_tmp}/.version" || exit 1
  rm -rf "\${_runtime}"; mv "\${_tmp}" "\${_runtime}" || exit 1
fi
exec "\${_runtime}/$name" "\$@"
WRAPPER
  chmod 755 "$ROOT/usr/bin/$name"

  # Console launcher + desktop entry (upstream ships none).
  cat > "$ROOT/usr/lib/$libdir/$name-console" <<CONSOLE
#!/bin/sh
/usr/bin/$name start
exec /usr/bin/$name portal
CONSOLE
  chmod 755 "$ROOT/usr/lib/$libdir/$name-console"

  # Upstream ships no desktop art for the two editions; badge the bundled logo.
  local logo="$unpack/resources/browser-connector/chrome-extension/qwork-logo-light.png"
  local icon="$unpack/resources/browser-connector/chrome-extension/icons/icon-128.png"
  local label="INTL" bg="#2C549E"
  if (( cn )); then label="CN"; bg="#C8102E"; fi
  [[ -f "$logo" ]] && badge_icon "$logo" \
    "$ROOT/usr/share/icons/hicolor/512x512/apps/$name.png" 512 "$label" "$bg"
  [[ -f "$icon" ]] && badge_icon "$icon" \
    "$ROOT/usr/share/icons/hicolor/128x128/apps/$name.png" 128 "$label" "$bg"

  if (( cn )); then
    cat > "$ROOT/usr/share/applications/$name.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=QoderWake 国内版
Comment=打开 QoderWake 国内版本地控制台
Exec=/usr/lib/qoderwake-cn/qoderwake-cn-console
Icon=qoderwake-cn
Terminal=false
Categories=Development;
DESKTOP
  else
    cat > "$ROOT/usr/share/applications/$name.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=QoderWake
Comment=Open the local QoderWake console
Exec=/usr/lib/qoderwake/qoderwake-console
Icon=qoderwake
Terminal=false
Categories=Development;
DESKTOP
  fi
}
