target=/opt/DuMate/chrome-sandbox
[ -f "$target" ] || exit 0
clone=$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true)
apparmor=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true)
if [ "$clone" = 1 ] && [ "$apparmor" != 1 ]; then chmod 0755 "$target"; else chmod 4755 "$target"; fi
