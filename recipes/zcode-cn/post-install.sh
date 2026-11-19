chmod 4755 '/opt/zcode-cn/chrome-sandbox' 2>/dev/null || true
if command -v apparmor_status >/dev/null 2>&1 && apparmor_status --enabled >/dev/null 2>&1 \
  && command -v apparmor_parser >/dev/null 2>&1 && [ -f '/opt/zcode-cn/resources/apparmor-profile' ] \
  && apparmor_parser --skip-kernel-load --debug '/opt/zcode-cn/resources/apparmor-profile' >/dev/null 2>&1; then
  install -Dm644 '/opt/zcode-cn/resources/apparmor-profile' '/etc/apparmor.d/zcode-cn'
  if ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --replace --write-cache --skip-read-cache '/etc/apparmor.d/zcode-cn' || true
  fi
fi
