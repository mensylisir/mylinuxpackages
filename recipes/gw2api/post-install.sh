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
