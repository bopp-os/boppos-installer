# On tty1 the live user gets the installer full-screen in cage. Leaving it ends the session and getty starts it
# again. Output from cage and the installer goes to the journal (journalctl -t boppos-installer); tty2
# (Ctrl+Alt+F2) has a root shell for debugging.
if [ "$USER" = liveuser ] && [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    # Software cursor: with a virtual GPU (virtio) the hardware cursor plane shows the pointer upside down.
    export WLR_NO_HARDWARE_CURSORS=1
    exec systemd-cat -t boppos-installer cage -s -- bootc-installer
fi
