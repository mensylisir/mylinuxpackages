if [ -f '/etc/apparmor.d/zcode-cn' ]; then
  command -v apparmor_parser >/dev/null 2>&1 && apparmor_parser --remove '/etc/apparmor.d/zcode-cn' || true
  rm -f '/etc/apparmor.d/zcode-cn' '/etc/apparmor.d/cache/zcode-cn'
fi
