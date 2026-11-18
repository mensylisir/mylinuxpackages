#!/usr/bin/env bash
# dumate-app — repack of the official Linux .deb. Unpack, relocate into the
# FHS tree, add the two launcher symlinks the upstream postinst created.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local deb; deb="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  deb_extract "$deb" "$unpack"

  [[ -x "$unpack/opt/DuMate/qianfan-desktop-app" ]] || \
    die "missing opt/DuMate/qianfan-desktop-app"

  copy_tree "$unpack" "$ROOT"

  install -d "$ROOT/usr/bin"
  ln -sf /opt/DuMate/qianfan-desktop-app "$ROOT/usr/bin/dumate"
  ln -sf /opt/DuMate/qianfan-desktop-app "$ROOT/usr/bin/qianfan-desktop-app"

  # License texts from the app dir.
  mkdir -p "$ROOT/usr/share/licenses/$PKG_NAME"
  for lic in LICENSE.electron.txt LICENSES.chromium.html; do
    [[ -f "$ROOT/opt/DuMate/$lic" ]] && ln -sf "/opt/DuMate/$lic" \
      "$ROOT/usr/share/licenses/$PKG_NAME/$lic"
  done

  # chrome-sandbox mode depends on the target host's unprivileged userns
  # support; decide at install time like the upstream postinst.
  cat > "$PKG_DIR/post-install.sh" <<'HOOK'
target=/opt/DuMate/chrome-sandbox
[ -f "$target" ] || exit 0
clone=$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true)
apparmor=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true)
if [ "$clone" = 1 ] && [ "$apparmor" != 1 ]; then chmod 0755 "$target"; else chmod 4755 "$target"; fi
HOOK
  write_postinst
}
