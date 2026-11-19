#!/usr/bin/env bash
# ClaudeMom launcher: the Tauri binary is self-contained (frontend and runtime
# assets embedded); it only needs a system Node.js for the local compat service,
# which it locates via PATH or CLAUDE_LOCAL_NODE.
exec /usr/lib/claudemom/claude-mom "$@"
