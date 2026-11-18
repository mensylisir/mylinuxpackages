#!/usr/bin/env bash
# WorkBuddy (domestic / international) — the hardest port in this repo.
#
# Key invariant (do NOT "simplify"): the Electron runtime is NOT stock. The
# login flow depends on a proprietary `workbuddyStorage` native binding that
# only exists in the official Linux deb. We extract that deb for the runtime,
# Node/Python session helpers and Linux CLI binaries, and take only the
# platform-neutral JS payload from the Windows archive. We verify the binding
# before shipping; swapping in upstream Electron breaks sign-in.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local intl=0
  [[ "$APP_ID" == workbuddy-intl ]] && intl=1
  local machine=x64
  local EXPECTED_ELECTRON="37.10.3"
  local EXPECTED_SANDBOX="5.11.4"
  local EXPECTED_HARNESS="0.2.0-beta.16"
  local prefix desktop iconname launcher
  if (( intl )); then
    prefix="/opt/workbuddy-international"; desktop="workbuddy-international.desktop"
    iconname="workbuddy-international"; launcher="workbuddy-international"
  else
    prefix="/opt/WorkBuddy"; desktop="WorkBuddy.desktop"
    iconname="workbuddy"; launcher="workbuddy"
  fi

  local winzip hostdeb sandbox_tgz harness_tgz
  winzip="$(fetched_glob 'WorkBuddy-win32-*.zip')"
  hostdeb="$(fetched_glob 'WorkBuddy-linux-x64-deb-*.deb')"
  sandbox_tgz="$(fetched_glob 'sandbox-cli-linux-*.tgz')"
  harness_tgz="$(fetched_glob 'agent-harness-linux-*.tgz')"

  local W="$WORK/wb"; clean_dir "$W"; mkdir -p "$W"
  info() { printf '  -> %s\n' "$*" >&2; }
  pkg_version() { node -e 'process.stdout.write(require(process.argv[1]+"/package.json").version)' "$1"; }
  require_same() { local a b; a="$(pkg_version "$1")"; b="$(pkg_version "$2")"
    [[ "$a" == "$b" ]] || die "version drift ($3): payload=$a donor=$b"; }

  # --- 1. Donor runtime from official Linux deb (custom Electron) -----------
  info "extracting official Linux donor (custom Electron)"
  mkdir -p "$W/deb"
  deb_extract "$hostdeb" "$W/deb"
  mkdir -p "$W/donor"
  tar -xmf "$(find "$W/deb" -maxdepth 1 -name 'data.tar*' | head -1)" -C "$W/donor" \
    --no-same-owner --touch
  local host="$W/donor/opt/WorkBuddy"
  [[ -x "$host/workbuddy" ]] || die "donor deb lacks workbuddy Electron"
  local ever; ever="$(cat "$host/version")"
  [[ "$ever" == "${EXPECTED_ELECTRON}-"* ]] || die "unexpected donor Electron $ever"
  grep -aq workbuddyStorage "$host/workbuddy" || \
    die "donor Electron lacks workbuddyStorage binding — sign-in would break"
  info "donor Electron $ever carries workbuddyStorage (verified)"

  # --- 2. Electron shell from donor ----------------------------------------
  local app="$W/app"; mkdir -p "$app/resources"
  local e
  for e in "$host"/*; do
    [[ "$(basename "$e")" == resources ]] && continue
    cp -a "$e" "$app/"
  done
  chmod 4755 "$app/chrome-sandbox" 2>/dev/null || true
  local hr="$host/resources" res="$app/resources"
  cp -a "$hr/runtime" "$res/runtime"
  for asset in tray-linux.png tray-linux@2x.png apparmor-profile wb-guest-sdk; do
    [[ -e "$hr/$asset" ]] && cp -a "$hr/$asset" "$res/$asset"
  done

  # --- 3. Windows JS payload -----------------------------------------------
  info "extracting Windows app payload"
  mkdir -p "$W/win"
  unzip -q "$winzip" -d "$W/win" 'resources/app.asar' 'resources/app.asar.unpacked/*' || \
    die "missing app.asar in Windows archive"
  local payload="$res/app.asar.unpacked" stock="$hr/app.asar.unpacked"
  node "$MLP_ROOT/lib/patch/asar-tool.cjs" unpack "$W/win/resources/app.asar" "$payload"
  # Report pages (plain assets).
  unzip -q "$winzip" -d "$W/win" 'resources/conversation-report.html' \
    'resources/startup-report.html' 2>/dev/null || true
  for page in conversation-report.html startup-report.html; do
    [[ -f "$W/win/resources/$page" ]] && cp -a "$W/win/resources/$page" "$res/"
  done

  # --- 4. Linux native modules from donor ----------------------------------
  info "installing Linux native modules"
  local koffi_platform="linux_${machine}" base
  for base in "$payload" "$payload/cli"; do
    [[ -d "$base/node_modules/koffi" ]] || continue
    require_same "$base/node_modules/koffi" "$stock/node_modules/koffi" koffi
    mkdir -p "$base/node_modules/koffi/build/koffi/$koffi_platform"
    cp -a "$stock/node_modules/koffi/build/koffi/$koffi_platform/." \
      "$base/node_modules/koffi/build/koffi/$koffi_platform/"
  done
  if [[ -d "$payload/node_modules/node-pty" ]]; then
    require_same "$payload/node_modules/node-pty" "$stock/node_modules/node-pty" node-pty
    clean_dir "$payload/node_modules/node-pty/build"
    cp -a "$stock/node_modules/node-pty/build" "$payload/node_modules/node-pty/build"
  fi
  if [[ -d "$payload/node_modules/@tencent/qimei-node" ]]; then
    require_same "$payload/node_modules/@tencent/qimei-node" "$stock/node_modules/@tencent/qimei-node" qimei-node
    clean_dir "$payload/node_modules/@tencent/qimei-node/build"
    cp -a "$stock/node_modules/@tencent/qimei-node/build" "$payload/node_modules/@tencent/qimei-node/build"
  fi
  if [[ -d "$payload/node_modules/@tencent/tencent-docs-ai-engine" ]]; then
    local dd="$stock/node_modules/@tencent/tencent-docs-ai-engine/bin/linux-${machine}"
    [[ -d "$dd" ]] && cp -a "$dd" "$payload/node_modules/@tencent/tencent-docs-ai-engine/bin/"
  fi
  if [[ -d "$payload/node_modules/@lydell/node-pty-linux-${machine}" ]] \
     && [[ -d "$payload/cli/node_modules/@lydell/node-pty" ]] \
     && [[ ! -d "$payload/cli/node_modules/@lydell/node-pty-linux-${machine}" ]]; then
    cp -a "$payload/node_modules/@lydell/node-pty-linux-${machine}" "$payload/cli/node_modules/@lydell/"
  fi

  # --- 5. Linux CLI helpers ------------------------------------------------
  info "installing Linux CLI helpers"
  clean_dir "$payload/cli/vendor/sandbox"
  mkdir -p "$W/sandbox"; tar -xzf "$sandbox_tgz" -C "$W/sandbox" --no-same-owner --touch
  local sv; sv="$(pkg_version "$W/sandbox/package")"
  [[ "$sv" == "$EXPECTED_SANDBOX" ]] || die "sandbox-cli drift: $sv"
  mkdir -p "$payload/cli/vendor/sandbox/$sv"
  cp -a "$W/sandbox/package/bin/." "$payload/cli/vendor/sandbox/$sv/"
  find "$payload/cli/vendor/sandbox/$sv" -type f -exec chmod 755 {} +
  # Restore executable bits on shebang scripts (Windows zip drops them).
  grep -rlI -m1 '^#!' "$payload" 2>/dev/null | while IFS= read -r f; do chmod 755 "$f"; done || true
  clean_dir "$payload/cli/vendor/genie-trash"
  mkdir -p "$payload/cli/vendor/genie-trash"
  cp -a "$stock/cli/vendor/genie-trash/linux-${machine}" \
    "$payload/cli/vendor/genie-trash/linux-${machine}"
  chmod 755 "$payload/cli/vendor/genie-trash/linux-${machine}"
  if [[ -d "$stock/cli/vendor/ripgrep/${machine}-linux" ]]; then
    clean_dir "$payload/cli/vendor/ripgrep"; mkdir -p "$payload/cli/vendor/ripgrep"
    cp -a "$stock/cli/vendor/ripgrep/${machine}-linux" "$payload/cli/vendor/ripgrep/${machine}-linux"
    find "$payload/cli/vendor/ripgrep" -type f -exec chmod 755 {} +
  fi
  mkdir -p "$W/harness"; tar -xzf "$harness_tgz" -C "$W/harness" --no-same-owner --touch
  local hv; hv="$(pkg_version "$W/harness/package")"
  [[ "$hv" == "$EXPECTED_HARNESS" ]] || die "agent-harness drift: $hv"
  mkdir -p "$payload/node_modules/@tencent-ai"
  cp -a "$W/harness/package" "$payload/node_modules/@tencent-ai/agent-harness-linux-${machine}"
  find "$payload/node_modules/@tencent-ai/agent-harness-linux-${machine}/bin" -type f -exec chmod 755 {} +

  # --- 6. Drop foreign-platform artifacts ----------------------------------
  info "removing Windows/macOS binaries"
  clean_dir "$payload/native"/*/build 2>/dev/null || true
  clean_dir "$payload/resources/plugins/workbuddy-builtin/builtin-plugins/weixinpay/prebuilds"
  find "$payload" -depth -type d \( -name 'win32-*' -o -name '*-win32' -o -name 'darwin-*' \
    -o -name 'macos-*' -o -name '*-macos' \) -exec clean_dir {} + 2>/dev/null || true
  find "$app" -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.sys' -o -name '*.dylib' \
    -o -name '*.pdb' -o -name '*.lib' \) -delete 2>/dev/null || true
  while IFS= read -r -d '' b; do
    local desc; desc="$(file -b "$b")"
    case "$desc" in
      ELF*) [[ "$desc" == *'x86-64'* ]] || rm -f "$b" ;;
      *) rm -f "$b" ;;
    esac
  done < <(find "$app" -type f -name '*.node' -print0)
  prune_keep() { local p="$1"; shift; [[ -d "$p" ]] || return 0
    local c n k; for c in "$p"/*; do [[ -e "$c" ]] || continue; n="$(basename "$c")"
      local keep=0; for k in "$@"; do [[ "$n" == "$k" ]] && keep=1; done
      (( keep )) || clean_dir "$c"; done; }
  for base in "$payload" "$payload/cli"; do
    prune_keep "$base/node_modules/@lydell" node-pty "node-pty-linux-${machine}"
    [[ -d "$base/node_modules/koffi/build/koffi" ]] && prune_keep "$base/node_modules/koffi/build/koffi" "$koffi_platform"
    prune_keep "$base/node_modules/@ban-dal" os-bridge "os-bridge-linux-${machine}-gnu"
    clean_dir "$base/node_modules/node-pty/prebuilds"
  done
  clean_dir "$payload/node_modules/@tencent/wwapi-electron"

  # --- 7. Patch + index + verify runtimes ----------------------------------
  info "patching + indexing"
  node "$MLP_ROOT/lib/patch/workbuddy-linux.cjs" "$payload"
  node "$MLP_ROOT/lib/patch/asar-tool.cjs" shadow "$payload" "$res/app.asar"
  local need_node need_python have_node have_python
  read -r need_node need_python <<<"$(node -e '
    const fs=require("fs"),s=fs.readFileSync(process.argv[1],"utf8");
    const pick=n=>{const m=s.match(new RegExp("\\{name:`"+n+"`[^}]*?version:`([^`]+)`[^}]*?platforms:\\[`linux`\\]"));return m?m[1]:""};
    process.stdout.write(pick("node")+" "+pick("python"));' "$payload/main/shell-env-async.js")"
  have_node="$("$res/runtime/node/bin/node" --version)"; have_node="${have_node#v}"
  have_python="$("$res/runtime/python/bin/python3" --version 2>&1 | awk '{print $2}')"
  [[ "$have_node" == "$need_node" ]] || die "node runtime drift: want $need_node have $have_node"
  [[ "$have_python" == "$need_python" ]] || die "python runtime drift: want $need_python have $have_python"
  info "runtimes ok: node $have_node, python $have_python"
  chmod 755 "$app/workbuddy"

  # --- 8. Lay out ROOT -----------------------------------------------------
  mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications"
  copy_tree "$app" "$ROOT$prefix"

  if (( intl )); then
    # International launcher: run the app's own start.sh.
    cat > "$ROOT$prefix/start.sh" <<'EOF'
#!/bin/sh
unset ELECTRON_RUN_AS_NODE
export CHROME_DESKTOP='workbuddy-international.desktop'
export ELECTRON_FORCE_IS_PACKAGED=1
DATA_DIR="${WORKBUDDY_USER_DATA_DIR:-${WORKBUDDY_INTL_CONFIG_DIR:-$HOME/.workbuddy-international}}"
STATE_DIR="$DATA_DIR/app"
STATE_FILE="$STATE_DIR/shortcut-state.json"
if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  if [ ! -f "$STATE_FILE" ]; then
    mkdir -p "$STATE_DIR" && printf '%s\n' '{"version":1,"toggleWindowAccelerator":""}' >"$STATE_FILE" || true
  fi
fi
exec "$(dirname "$0")/workbuddy" --no-sandbox --disable-dev-shm-usage \
  --disable-gpu-sandbox --in-process-gpu --ozone-platform-hint=auto \
  --enable-wayland-ime --user-data-dir="$DATA_DIR" --class=workbuddy-international "$@"
EOF
    chmod 755 "$ROOT$prefix/start.sh"
    cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/sh
exec $prefix/start.sh "\$@"
EOF
    install -Dm644 "$PKG_DIR/workbuddy-intl-256.png" \
      "$ROOT/usr/share/icons/hicolor/256x256/apps/$iconname.png"
    install -Dm644 "$PKG_DIR/workbuddy-intl-256.png" \
      "$ROOT/usr/share/pixmaps/$iconname.png"
  else
    # Domestic launcher: pin WM_CLASS, disable Wayland shortcut popup.
    cat > "$ROOT/usr/bin/$launcher" <<'EOF'
#!/bin/sh
unset ELECTRON_RUN_AS_NODE
export CHROME_DESKTOP='WorkBuddy.desktop'
export ELECTRON_FORCE_IS_PACKAGED=1
if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  STATE_DIR="${WORKBUDDY_USER_DATA_DIR:-${WORKBUDDY_CONFIG_DIR:-${CODEBUDDY_CONFIG_DIR:-$HOME/.workbuddy}}/app}"
  STATE_FILE="$STATE_DIR/shortcut-state.json"
  if [ ! -f "$STATE_FILE" ]; then
    mkdir -p "$STATE_DIR" && printf '%s\n' '{"version":1,"toggleWindowAccelerator":""}' >"$STATE_FILE" || true
  fi
fi
exec /opt/WorkBuddy/workbuddy --no-sandbox --disable-dev-shm-usage \
  --disable-gpu-sandbox --in-process-gpu --ozone-platform-hint=auto \
  --enable-wayland-ime --class=workbuddy "$@"
EOF
    for s in 16 24 32 48 64 96 128 256 512; do
      [[ -f "$PKG_DIR/workbuddy-cn-${s}.png" ]] && install -Dm644 \
        "$PKG_DIR/workbuddy-cn-${s}.png" \
        "$ROOT/usr/share/icons/hicolor/${s}x${s}/apps/workbuddy.png"
    done
    install -Dm644 "$PKG_DIR/workbuddy-cn-256.png" "$ROOT/usr/share/pixmaps/workbuddy.png"
  fi
  chmod 755 "$ROOT/usr/bin/$launcher"
  install -m644 "$PKG_DIR/$desktop" "$ROOT/usr/share/applications/$desktop"
  install -Dm644 "$PKG_DIR/DISCLAIMER" \
    "$ROOT/usr/share/licenses/$PKG_NAME/DISCLAIMER"
  write_postinst
}
