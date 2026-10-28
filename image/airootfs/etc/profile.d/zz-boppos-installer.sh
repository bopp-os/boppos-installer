# On tty1 the live user gets the installer full-screen in cage. Leaving it ends the session and getty starts it
# again. Output from cage and the installer goes to the journal (journalctl -t boppos-installer); tty2
# (Ctrl+Alt+F2) has a root shell for debugging.
if [ "$USER" = liveuser ] && [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    exec systemd-cat -t boppos-installer cage -s -- bootc-installer
fi
