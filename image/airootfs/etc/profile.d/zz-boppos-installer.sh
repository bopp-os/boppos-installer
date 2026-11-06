# On tty1 the live user gets the installer in a sway kiosk with an on-screen keyboard. Leaving it ends the session and
# getty starts it again. Output from sway and the installer goes to the journal (journalctl -t boppos-installer); tty2
# (Ctrl+Alt+F2) has a root shell for debugging.
if [ "$USER" = liveuser ] && [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    # Software cursor in a VM only: with a virtual GPU (virtio) the hardware cursor plane shows the pointer upside
    # down. On real GPUs (the Legion Go's, with its rotated screen) the software cursor was invisible.
    if systemd-detect-virt --quiet --vm; then
        export WLR_NO_HARDWARE_CURSORS=1
    fi
    # One cursor theme for sway and the installer (GTK); unset, sway asks for a "default" theme the ISO lacks.
    export XCURSOR_THEME=Adwaita XCURSOR_SIZE=32
    # The keyboard page must not try to apply the layout through GNOME settings (the kiosk has none).
    export VANILLA_NO_APPLY_XKB=1
    # A smaller on-screen keyboard: squeekboard sizes its panel from the screen (a third to half of its height) and
    # scales that by this setting. Only squeekboard reads the keyfile (see sway.conf).
    mkdir -p "$HOME/.config/glib-2.0/settings"
    printf '[sm/puri/Squeekboard]\nscale-in-horizontal-screen-orientation=0.7\n' >"$HOME/.config/glib-2.0/settings/keyfile"
    # A private session bus for squeekboard and the installer (the keyboard button talks to squeekboard over it).
    exec systemd-cat -t boppos-installer dbus-run-session -- sway -c /etc/boppos-installer/sway.conf
fi
