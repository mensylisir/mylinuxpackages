#!/usr/bin/env bash
# Qoder agent / IDE — the upstream rpm is self-contained: its app dir carries
# the vendor's own Electron (a patched build, not the stock release), the chrome
# libs and resources/. Ship that tree verbatim at its upstream path and exec the
# vendor binary, exactly like the rpm's own desktop entry does.
#
# Never swap the vendor Electron for a mirror build. It carries private patches
# — on a Wayland session it re-execs itself with --ozone-platform=x11 — and a
# stock Electron has no such fallback: it exits 1 without ever showing a window.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local is_ide=0 cn=0
  [[ "$APP_ID" == *ide ]] && is_ide=1
  [[ "$APP_ID" == *cn* ]] && cn=1

  # Upstream names the binary after the app dir, so one name drives both.
  local appname
  if (( is_ide )); then
    if (( cn )); then appname="qoder-cn-ide"; else appname="qoder-ide"; fi
  else
    if (( cn )); then appname="qoder-cn"; else appname="qoder"; fi
  fi
  local launcher="$appname"

  local rpm; rpm="$(fetched_remote)"
  local unpack="$WORK/unpack"
  clean_dir "$unpack"; mkdir -p "$unpack"
  rpm_extract "$rpm" "$unpack"

  # Locate the vendor app dir: the directory holding resources.pak plus a
  # resources/ subdir (mirrors the upstream _get_app_dir()).
  local appdir
  appdir="$(find "$unpack" -type f -name resources.pak -printf '%h\n' 2>/dev/null \
    | while read -r d; do [[ -d "$d/resources" ]] && { echo "$d"; break; }; done)"
  [[ -n "$appdir" ]] || die "cannot locate app dir (resources.pak + resources/) in rpm"

  # Keep the upstream absolute path (/opt/Qoder, /opt/Qoder-CN, ...): the vendor
  # binary and its resources stay in the layout they were built for, and the
  # agent/IDE packages never share a directory.
  local apprel="${appdir#"$unpack"}"
  [[ "$apprel" == /* && "$apprel" != *..* ]] || die "unexpected app dir in rpm: $appdir"
  local dest="$ROOT$apprel"

  mkdir -p "$dest" "$ROOT/usr/bin" "$ROOT/usr/share/applications"
  copy_tree "$appdir" "$dest/"

  # Drop foreign-platform payload.
  find "$dest/resources" -type d \( -name '*win32*' -o -name '*darwin*' -o -name '*arm64*' \) \
    -prune -exec clean_dir {} + 2>/dev/null || true

  # The vendor Electron is the whole point of this layout. If a future rpm stops
  # shipping it (and falls back to a distro electron like the AUR recipe does),
  # fail here instead of producing a package that cannot start.
  local vbin="$dest/$appname"
  [[ -f "$vbin" && -x "$vbin" ]] || die "vendor electron missing: $apprel/$appname"
  grep -qa 'Electron/' "$vbin" || die "not an Electron build: $apprel/$appname"
  local e_major
  e_major="$(strings -a "$vbin" | grep -oE 'Electron/[0-9]+' | head -1 | cut -d/ -f2)"
  say "vendor electron ${e_major:-unknown} → $apprel/$appname"

  # Desktop entry + icons from the rpm; Exec/TryExec/Icon point at our launcher
  # while every other argument of the upstream command line is preserved.
  find "$unpack" -path '*/share/applications/*' -type f -name '*.desktop' -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        local d="$ROOT/usr/share/applications/$(basename "$f")"
        install -m644 "$f" "$d"
        fix_desktop_entry_keep_args "$d" "$launcher"
        if grep -qE "^(Exec|TryExec)=/" "$d"; then
          die "desktop entry still references an absolute binary: $d"
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

  # Thin launcher: exec the vendor binary in place. --no-sandbox because a deb
  # cannot ship chrome-sandbox setuid, and unprivileged user namespaces are
  # restricted on current Ubuntu releases.
  cat > "$ROOT/usr/bin/$launcher" <<EOF
#!/bin/bash
set -e
unset ELECTRON_RUN_AS_NODE
export CHROME_DESKTOP="$desktop_id"
exec "$apprel/$appname" --no-sandbox "\$@"
EOF
  chmod 755 "$ROOT/usr/bin/$launcher"

  # IDE build: upstream ships a single 512px pixmaps icon and relies on the
  # desktop file for the rest. Generate the hicolor set the other recipes have
  # so docks/alt-tab pick a correctly sized asset, and carry appdata / mime /
  # shell completions over from the rpm.
  install -Dm644 "$PKG_DIR/$appname-512.png" "$ROOT/usr/share/pixmaps/$appname.png"
  install_icon_set "$PKG_DIR/$appname-512.png" "$launcher"
  find "$unpack" -path '*/share/appdata/*' -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do install -Dm644 "$f" "$ROOT/usr/share/appdata/$(basename "$f")"; done
  find "$unpack" -path '*/share/mime/packages/*' -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do install -Dm644 "$f" "$ROOT/usr/share/mime/packages/$(basename "$f")"; done
  find "$unpack" -path '*/bash-completion/*' -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do install -Dm644 "$f" "$ROOT/usr/share/bash-completion/completions/$launcher"; done
  find "$unpack" -path '*/zsh/site-functions/*' -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do install -Dm644 "$f" "$ROOT/usr/share/zsh/site-functions/_$launcher"; done

  # License from rpm.
  if [[ -f "$unpack/usr/share/licenses/LICENSE.html" ]]; then
    install -Dm644 "$unpack/usr/share/licenses/LICENSE.html" \
      "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE.html"
  fi
  write_postinst
}
