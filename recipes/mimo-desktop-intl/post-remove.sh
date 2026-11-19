if [ -f '/etc/apparmor.d/xiaomi-mimo-desktop-ai' ]; then
  if command -v apparmor_parser >/dev/null 2>&1 \
    && ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --remove '/etc/apparmor.d/xiaomi-mimo-desktop-ai' || true
  fi
  rm -f '/etc/apparmor.d/xiaomi-mimo-desktop-ai' '/etc/apparmor.d/cache/'"xiaomi-mimo-desktop-ai"
fi
