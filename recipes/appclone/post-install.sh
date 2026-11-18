src=/usr/share/appclone/bwrap.apparmor
dst=/etc/apparmor.d/bwrap
if [ -r "$src" ] && [ ! -e "$dst" ]; then
  restrict=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)
  if [ "$restrict" = 1 ]; then
    tmp=/etc/apparmor.d/.appclone-bwrap.new
    if cp "$src" "$tmp" 2>/dev/null && chmod 0644 "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null; then
      parser=$(command -v apparmor_parser 2>/dev/null || true)
      [ -z "$parser" ] && [ -x /usr/sbin/apparmor_parser ] && parser=/usr/sbin/apparmor_parser
      [ -n "$parser" ] && "$parser" -r "$dst" >/dev/null 2>&1 || rm -f "$dst" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
fi
