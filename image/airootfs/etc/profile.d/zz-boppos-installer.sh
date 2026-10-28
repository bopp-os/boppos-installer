# On tty1 the live user gets the installer full-screen in cage. Leaving it ends the session and getty starts it
# again; tty2 (Ctrl+Alt+F2) has a root shell for debugging.
if [ "$USER" = liveuser ] && [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    exec cage -s -- bootc-installer
fi
