if [ -f '/etc/apparmor.d/zcode' ]; then
  command -v apparmor_parser >/dev/null 2>&1 && apparmor_parser --remove '/etc/apparmor.d/zcode' || true
  rm -f '/etc/apparmor.d/zcode' '/etc/apparmor.d/cache/zcode'
fi
