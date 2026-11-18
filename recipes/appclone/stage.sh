#!/usr/bin/env bash
# appclone - prebuilt Linux tarball, just lay out the FHS tree.
# Static resources used: none (all assets come from the tarball).
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local tgz; tgz="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  tar_extract "$tgz" "$unpack"

  install -Dm755 "$unpack/appclone"     "$ROOT/usr/bin/appclone"
  install -Dm755 "$unpack/appclone-gui" "$ROOT/usr/bin/appclone-gui"
  install -Dm644 "$unpack/io.github.mensylisir.Appclone.desktop" \
    "$ROOT/usr/share/applications/io.github.mensylisir.Appclone.desktop"
  install -Dm644 "$unpack/io.github.mensylisir.Appclone.svg" \
    "$ROOT/usr/share/icons/hicolor/scalable/apps/io.github.mensylisir.Appclone.svg"
  install -Dm644 "$unpack/bwrap.apparmor" \
    "$ROOT/usr/share/appclone/bwrap.apparmor"
  install -Dm644 "$unpack/LICENSE" \
    "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE"
  install -Dm644 "$unpack/THIRD_PARTY_NOTICES" \
    "$ROOT/usr/share/licenses/$PKG_NAME/THIRD_PARTY_NOTICES"

  # Install the AppArmor profile only on hosts that restrict unprivileged
  # user namespaces (bubblewrap needs it there). Runs at package install time.
  cat > "$PKG_DIR/post-install.sh" <<'HOOK'
src=/usr/share/appclone/bwrap.apparmor
dst=/etc/apparmor.d/bwrap
if [ -r "$src" ] && [ ! -e "$dst" ]; then
  restrict=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)
  if [ "$restrict" = 1 ]; then
    tmp=/etc/apparmor.d/.appclone-bwrap.new
    if cp "$src" "$tmp" 2>/dev/null && chmod 0644 "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null; then
      parser=$(command -v apparmor_parser 2>/dev/null || true)
      [ -z "$parser" ] && [ -x /usr/sbin/apparmor_parser ] && parser=/usr/sbin/apparmor_parser
      [ -n "$parser" ] && "$parser" -r "$dst" >/dev/null 2>&1 || rm -f "$dst" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
fi
HOOK
  write_postinst
}
