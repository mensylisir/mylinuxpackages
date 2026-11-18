#!/usr/bin/env bash
# Kimi Work — official Windows NSIS client repackaged for Linux.
#   kimi-work       upstream default region, no region pin
#   kimi-work-cn    region pinned to china
#   kimi-work-intl  region pinned to overseas
# The app carries platform-neutral JS + a "daimon" tool bundle. We keep the
# Linux parts, drop win32 toolchains, (for cn/intl) pin the region, and run it
# on a bundled Electron 43 instead of a distro package.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local region="" appname="" prefix launcher desktopname
  case "$APP_ID" in
    kimi-work-cn)    region="china";    appname="kimi-desktop-cn"; prefix="/opt/kimi-work-cn"; launcher="kimi-work-cn"; desktopname="kimi-work-cn.desktop" ;;
    kimi-work-intl)  region="overseas"; appname="kimi-desktop-intl"; prefix="/opt/kimi-work-intl"; launcher="kimi-work"; desktopname="kimi-work-intl.desktop" ;;
    *)               prefix="/opt/kimi-work"; launcher="kimi-work"; desktopname="kimi-work.desktop" ;;
  esac

  need 7z "p7zip-full"
  local exe; exe="$(fetched_remote)"
  local nsis="$WORK/nsis" payload="$WORK/payload"
  clean_dir "$nsis"; clean_dir "$payload"
  7z x -y -o"$nsis" "$exe" >/dev/null
  7z x -y -o"$payload" "$nsis/\$PLUGINSDIR/app-64.7z" >/dev/null

  local res="$payload/resources/resources"
  local daimon="$res/daimon-bundle"
  # Unpack the four daimon component archives in place.
  mkdir -p "$daimon"
  local a
  for a in core git python uv; do
    tar -xzmf "$res/daimon-${a}.tar.gz" -C "$daimon" --no-same-owner --touch
  done

  # Extract app.asar for patching.
  local asardir="$WORK/asar"
  clean_dir "$asardir"; mkdir -p "$asardir"
  asar extract "$payload/resources/app.asar" "$asardir"

  # Strip Windows/macOS binaries + TypeScript sources from both trees.
  for base in "$asardir" "$daimon"; do
    find "$base" -type f -iname '*.exe' -delete 2>/dev/null || true
    find "$base" -type f \( -iname '*.ts' -o -iname '*.mts' -o -iname '*.cts' -o -iname '*.tsx' \) -delete 2>/dev/null || true
  done
  find "$res" -maxdepth 1 -type f -iname '*.exe' -delete 2>/dev/null || true
  rm -f "$res"/daimon-*.tar.gz
  find "$res/runtime" -maxdepth 1 -type f -iname '*.cmd' -delete 2>/dev/null || true
  find "$daimon/runtime" -type f \( -iname '*.dll' -o -iname '*.cmd' -o -iname '*.ps1' -o -iname '*.bat' \) -delete 2>/dev/null || true
  find "$daimon/runtime" -type d -empty -delete 2>/dev/null || true

  # Drop build-time devDependencies from daimon's manifest.
  local dpkg="$daimon/app/daimon/package.json"
  if [[ -f "$dpkg" ]]; then
    sed -i '/^  "devDependencies": {$/,/^  },$/d' "$dpkg"
    grep -q '"devDependencies"' "$dpkg" && die "devDependencies still present in daimon manifest"
  fi

  # Offline wrappers for the Windows-only launchers: run the bundled Node
  # (Electron in Node mode) instead of downloading Node at runtime.
  install -Dm755 /dev/stdin "$daimon/bin/daimon" <<'DAIMON'
#!/bin/sh
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
exec "${DIR}/../runtime/node" "${DIR}/../app/daimon/dist/src/runner/cli.js" "$@"
DAIMON
  install -Dm755 /dev/stdin "$daimon/runtime/node" <<'NODE'
#!/bin/sh
exec env ELECTRON_RUN_AS_NODE=1 "$KIMI_ELECTRON" "$@"
NODE

  # Region pin (cn/intl only); base edition keeps upstream behaviour.
  if [[ -n "$region" ]]; then
    node "$MLP_ROOT/lib/patch/kimi-work-region.cjs" "$asardir" "$region" "$appname"
  fi

  local newasar="$WORK/app.asar"
  rm -f "$newasar"
  asar pack "$asardir" "$newasar"

  # Assemble ROOT.
  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
           "$ROOT/usr/share/licenses/$PKG_NAME"
  mkdir -p "$ROOT$prefix"
  install -m644 "$newasar" "$ROOT$prefix/app.asar"
  copy_tree "$res" "$ROOT$prefix/resources"

  # Bundled Electron 43.
  local edir="$ROOT$prefix/electron"
  mkdir -p "$edir"
  unzip -q "$(fetched "electron-v${ELECTRON_VERSION}-linux-x64.zip")" -d "$edir"
  rm -f "$edir/resources/default_app.asar"

  # Launcher (own implementation) — point resource env vars at our prefix.
  cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/sh
BASE="$prefix"
export KIMI_ELECTRON="\$BASE/electron/electron"
export DAIMON_BUNDLE_DIR="\$BASE/resources/daimon-bundle"
export KIMI_BUILTIN_SKILLS_DIR="\$BASE/resources/builtin-skills"
export KIMI_WORK_RESOURCES="\$BASE"
EOF
  if [[ -n "$region" ]]; then
    local rk="cn"; [[ "$region" == overseas ]] && rk="sg"
    printf 'export KIMI_AGENT_REGION=%s\n' "$rk" >> "$ROOT/usr/bin/$launcher"
  fi
  cat >> "$ROOT/usr/bin/$launcher" <<'EOF'
exec "$KIMI_ELECTRON" "$BASE/app.asar" "$@"
EOF
  chmod 755 "$ROOT/usr/bin/$launcher"

  # Desktop + icons.
  if [[ -f "$PKG_DIR/$desktopname" ]]; then
    install -m644 "$PKG_DIR/$desktopname" "$ROOT/usr/share/applications/$desktopname"
  fi
  local icon="$asardir/assets/tray-icon@2x.png"
  if [[ -n "$region" && -f "$PKG_DIR/$launcher-512.png" ]]; then
    install_icon_set "$PKG_DIR/$launcher-512.png" "$launcher"
  elif [[ -f "$icon" ]]; then
    install -Dm644 "$icon" "$ROOT/usr/share/icons/hicolor/64x64/apps/$launcher.png"
  fi
  if [[ -f "$PKG_DIR/LICENSE" ]]; then
    install -m644 "$PKG_DIR/LICENSE" "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE"
  fi
  write_postinst
}
