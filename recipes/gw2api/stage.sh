#!/usr/bin/env bash
# gw2api - single Go binary with a systemd service.
set -euo pipefail
source "$MLP_ROOT/lib/stage-common.sh"

recipe_stage() {
  local bin; bin="$(fetched_remote)"
  install -Dm755 "$bin" "$ROOT/usr/bin/gw2api"
  install -Dm644 "$PKG_DIR/gw2api.service" "$ROOT/usr/lib/systemd/system/gw2api.service"
  install -Dm644 "$PKG_DIR/gw2api.conf" "$ROOT/etc/gw2api/gw2api.conf"
  install -Dm644 "$PKG_DIR/gw2api.sysusers" "$ROOT/usr/lib/sysusers.d/gw2api.conf"

  cat > "$PKG_DIR/post-install.sh" <<'HOOK'
if command -v systemd-sysusers >/dev/null 2>&1; then
  systemd-sysusers /usr/lib/sysusers.d/gw2api.conf >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
cat <<'EOF'
gw2api installed.
1) Edit /etc/gw2api/gw2api.conf and set GW2API_ADMIN_TOKEN.
2) systemctl daemon-reload && systemctl enable --now gw2api.service
EOF
HOOK
  write_postinst
}
