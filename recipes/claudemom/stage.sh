#!/usr/bin/env bash
# ClaudeMom: upstream publishes only macOS (dmg) and Windows (exe) installers,
# so this recipe builds the Tauri 2 desktop app from the source tarball.
#
# What ends up on disk is deliberately tiny: the vite frontend is embedded into
# the binary via tauri's generate_context!, and crates/claude-local embeds the
# Node runtime scripts, i18n catalogs and mock templates via include_bytes!.
# The app only needs a system Node.js at runtime (found via PATH or
# CLAUDE_LOCAL_NODE) and system webkit2gtk (Tauri's webview).
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  need npm "install Node.js 22+ (provides npm)"
  need cargo "install the Rust toolchain (rustup) to build the Tauri app"
  need cmake "needed by the bundled sherpa-onnx dictation engine"

  local tree="$WORK/source"
  clean_dir "$tree"
  tar_extract "$(fetched_remote)" "$tree" 1

  say "[claudemom] building frontend (vite)"
  ( cd "$tree/apps/claude-mom" && npm ci --no-audit --no-fund )
  ( cd "$tree/apps/claude-mom" && npm run vite:build )

  say "[claudemom] compiling Tauri binary (cargo, release)"
  # Rust bakes source paths into panic messages and debug info, so a plain
  # release build leaks the builder's home directory into the shipped binary
  # (521 hits of /home/<builder> in the first build). Remap them to neutral
  # paths and strip symbols: the app has no use for either.
  ( cd "$tree" && CARGO_TARGET_DIR="$WORK/cargo-target" \
      CARGO_PROFILE_RELEASE_STRIP=symbols \
      RUSTFLAGS="--remap-path-prefix=$tree=/usr/src/claudemom --remap-path-prefix=${HOME:-/root}=/build" \
      cargo build --release --bin claude-mom )

  say "[claudemom] laying out package root"
  mkdir -p "$ROOT/usr/lib/claudemom" "$ROOT/usr/bin" \
           "$ROOT/usr/share/applications" "$ROOT/usr/share/licenses/claudemom"
  install -m755 "$WORK/cargo-target/release/claude-mom" "$ROOT/usr/lib/claudemom/claude-mom"
  install -m755 "$PKG_DIR/claudemom.sh" "$ROOT/usr/bin/claudemom"
  install -m644 "$PKG_DIR/claudemom.desktop" "$ROOT/usr/share/applications/claudemom.desktop"
  install -m644 "$tree/LICENSE" "$ROOT/usr/share/licenses/claudemom/LICENSE"
  install_icon_set "$PKG_DIR/claudemom-512.png" "claudemom"
  write_postinst; write_postrm
}
