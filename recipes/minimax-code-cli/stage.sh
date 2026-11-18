#!/usr/bin/env bash
# minimax-code-cli — terminal AI agent distributed as npm tarballs. No Electron:
# assemble a node_modules tree from pinned npm sources plus a matching
# prebuilt better-sqlite3 binding and a private Node 26 runtime (ABI 147).
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local nm="$WORK/node_modules"
  clean_dir "$nm"; mkdir -p "$nm/@minimax-ai" "$nm/@vscode" \
    "$nm/@mariozechner" "$nm/@trycua" "$nm/@ubjs"

  unpack_npm() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    tar -xzmf "$(fetched "$src")" -C "$dest" --strip-components=1 --no-same-owner --touch
  }

  unpack_npm "code-${VERSION}.tgz"                       "$nm/@minimax-ai/code"
  unpack_npm "ripgrep-1.18.0.tgz"                        "$nm/@vscode/ripgrep"
  unpack_npm "ripgrep-linux-x64-1.18.0.tgz"              "$nm/@vscode/ripgrep-linux-x64"
  unpack_npm "clipboard-0.3.9.tgz"                       "$nm/@mariozechner/clipboard"
  unpack_npm "clipboard-linux-x64-gnu-0.3.9.tgz"         "$nm/@mariozechner/clipboard-linux-x64-gnu"
  unpack_npm "cua-driver-0.34.1.tgz"                     "$nm/@trycua/cua-driver"
  unpack_npm "cua-driver-linux-x64-gnu-0.34.1.tgz"       "$nm/@trycua/cua-driver-linux-x64-gnu"
  unpack_npm "ubjs-core-0.31.0-3.tgz"                    "$nm/@ubjs/core"
  unpack_npm "ubjs-node-0.31.0-3.tgz"                    "$nm/@ubjs/node"
  unpack_npm "ubjs-node-linux-x64-gnu-0.31.0-3.tgz"      "$nm/@ubjs/node-linux-x64-gnu"
  unpack_npm "better-sqlite3-12.11.1.tgz"                "$nm/better-sqlite3"
  unpack_npm "bindings-1.5.0.tgz"                        "$nm/bindings"
  unpack_npm "file-uri-to-path-1.0.0.tgz"                "$nm/file-uri-to-path"

  # Drop the prebuilt node-v147 native binding into better-sqlite3.
  tar -xzmf "$(fetched "better-sqlite3-node-12.11.1-linux-x64.tar.gz")" \
    -C "$nm/better-sqlite3" --no-same-owner --touch
  clean_dir "$nm/better-sqlite3/deps"
  clean_dir "$nm/better-sqlite3/src"
  rm -f "$nm/better-sqlite3/binding.gyp"

  # Foreign-platform payloads are dead weight on x86_64 Linux.
  clean_dir "$nm/@minimax-ai/code/native/darwin"
  clean_dir "$nm/@minimax-ai/code/native/win32"
  for d in win32-x64 win32-arm64 darwin-x64 darwin-arm64; do
    clean_dir "$nm/@minimax-ai/code/embedded/computer-use/0.34.1/$d"
  done
  rm -f "$nm/@minimax-ai/code/internal-bin/mcode-tools.cmd"
  chmod 755 "$nm/@minimax-ai/code/internal-bin/mcode-tools" 2>/dev/null || true

  local prefix="/opt/$PKG_NAME"
  mkdir -p "$ROOT$prefix"
  copy_tree "$nm" "$ROOT$prefix/node_modules"

  # Bundle the exact Node ABI the prebuilt better-sqlite3 binding needs.
  local nodedist="$WORK/node-dist"
  clean_dir "$nodedist"; mkdir -p "$nodedist"
  tar -xJf "$(fetched "node-v26.13.1-linux-x64.tar.xz")" -C "$nodedist" \
    --strip-components=1 --no-same-owner --touch
  copy_tree "$nodedist" "$ROOT$prefix/runtime/node"
  find "$ROOT$prefix" -type d -exec chmod 755 {} +

  cat > "$ROOT/usr/bin/mcode" <<EOF
#!/bin/sh
exec $prefix/runtime/node/bin/node $prefix/node_modules/@minimax-ai/code/cli.js "\$@"
EOF
  cat > "$ROOT/usr/bin/mcode-tools" <<EOF
#!/bin/sh
exec $prefix/runtime/node/bin/node $prefix/node_modules/@minimax-ai/code/mcode-tools.js "\$@"
EOF
  chmod 755 "$ROOT/usr/bin/mcode" "$ROOT/usr/bin/mcode-tools"
  install -Dm644 "$(fetched LICENSE)" \
    "$ROOT/usr/share/licenses/$PKG_NAME/LICENSE"
}
