# On tty1 the live user gets the installer in a sway kiosk with an on-screen keyboard. Leaving it ends the session and
# getty starts it again. Output from sway and the installer goes to the journal (journalctl -t boppos-installer); tty2
# (Ctrl+Alt+F2) has a root shell for debugging.
if [ "$USER" = liveuser ] && [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    # Software cursor: with a virtual GPU (virtio) the hardware cursor plane shows the pointer upside down.
    export WLR_NO_HARDWARE_CURSORS=1
    # The keyboard page must not try to apply the layout through GNOME settings (the kiosk has none).
    export VANILLA_NO_APPLY_XKB=1
    # A private session bus for squeekboard and the installer (the keyboard button talks to squeekboard over it).
    exec systemd-cat -t boppos-installer dbus-run-session -- sway -c /etc/boppos-installer/sway.conf
fi
