chmod 4755 '/opt/zcode/chrome-sandbox' 2>/dev/null || true
if command -v apparmor_status >/dev/null 2>&1 && apparmor_status --enabled >/dev/null 2>&1 \
  && command -v apparmor_parser >/dev/null 2>&1 && [ -f '/opt/zcode/resources/apparmor-profile' ] \
  && apparmor_parser --skip-kernel-load --debug '/opt/zcode/resources/apparmor-profile' >/dev/null 2>&1; then
  install -Dm644 '/opt/zcode/resources/apparmor-profile' '/etc/apparmor.d/zcode'
  if ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --replace --write-cache --skip-read-cache '/etc/apparmor.d/zcode' || true
  fi
fi
