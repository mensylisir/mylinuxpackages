chmod 4755 '/opt/Xiaomi MiMo/chrome-sandbox' 2>/dev/null || true
if command -v apparmor_status >/dev/null 2>&1 && apparmor_status --enabled >/dev/null 2>&1 \
  && command -v apparmor_parser >/dev/null 2>&1 && [ -f '/opt/Xiaomi MiMo/resources/apparmor-profile' ] \
  && apparmor_parser --skip-kernel-load --debug '/opt/Xiaomi MiMo/resources/apparmor-profile' >/dev/null 2>&1; then
  install -Dm644 '/opt/Xiaomi MiMo/resources/apparmor-profile' '/etc/apparmor.d/xiaomi-mimo-desktop'
  if ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --replace --write-cache --skip-read-cache '/etc/apparmor.d/xiaomi-mimo-desktop' || true
  fi
fi
