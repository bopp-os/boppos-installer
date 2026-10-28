#!/usr/bin/env bash
# build.sh — build the BoppOS installer ISO with mkarchiso in a privileged Arch Linux container. Needs root and podman
# (run on the host or in CI, not in the Litterbox).
#
#   sudo image/build.sh [outdir]     (default /var/tmp/boppos-iso)
#   sudo LOCAL_PKGS=$PWD/.dev/pkgs image/build.sh   (use packages built by image/dev.sh packages instead of the repo's)
#
# The ISO lands in outdir; the build log goes to probe-logs/iso-build.log in this repo. The bopp-os signing key comes
# from keys/boppos.asc and must match the pinned fingerprint before it is trusted.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
out="${1:-/var/tmp/boppos-iso}"
logs="$repo/probe-logs"
image="${BUILD_IMAGE:-docker.io/library/archlinux:latest}"
want=3806768589376830FEA123D6CF30985CE903D47C   # also pinned in bopp-os/pkgbuilds CI

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0"; exit 2; }
mkdir -p "$out" "$logs"
rm -rf "$out/work"

# LOCAL_PKGS=<dir of .pkg.tar.zst files> (from image/dev.sh packages) puts those packages in the ISO ahead of the
# [bopp-os] repository, so a change can be tried in an ISO before anything is pushed or released.
local_mount=()
if [ -n "${LOCAL_PKGS:-}" ]; then
    compgen -G "$LOCAL_PKGS/*.pkg.tar.zst" >/dev/null || { echo "no packages in $LOCAL_PKGS"; exit 2; }
    local_mount=(-v "$LOCAL_PKGS:/localpkgs:ro")
fi

# The boot splash theme is the BoppOS one from the boppos-tools checkout (read-only; nothing is written there).
tools_src="${BOPPOS_TOOLS_SRC:-$(dirname "$repo")/boppos-tools}"
theme_mount=()
if [ -f "$tools_src/boot/plymouth/boppos/boppos.plymouth" ]; then
    theme_mount=(-v "$tools_src/boot/plymouth/boppos:/plymouth-theme:ro")
else
    echo "note: no BoppOS plymouth theme at $tools_src/boot/plymouth/boppos; the ISO boots with the default splash"
fi

# shellcheck disable=SC2016  # expanded inside the container
# Host networking: rootful podman's default container network did not resolve DNS on the build host.
podman run --rm --privileged --network host -v "$here:/profile:ro" "${local_mount[@]}" "${theme_mount[@]}" -v "$out:/out" \
    -e WANT="$want" "$image" bash -euo pipefail -c '
    pacman -Syu --noconfirm --needed archiso >/dev/null
    pacman-key --init >/dev/null 2>&1
    pacman-key --populate archlinux >/dev/null 2>&1
    fpr=$(gpg --with-colons --show-keys /profile/keys/boppos.asc | awk -F: "/^fpr/ {print \$10; exit}")
    [ "$fpr" = "$WANT" ] || { echo "keys/boppos.asc is $fpr, expected $WANT"; exit 1; }
    pacman-key --add /profile/keys/boppos.asc >/dev/null
    pacman-key --lsign-key "$WANT" >/dev/null
    cp -a /profile /tmp/profile
    if [ -d /plymouth-theme ]; then
        mkdir -p /tmp/profile/airootfs/usr/share/plymouth/themes
        cp -a /plymouth-theme /tmp/profile/airootfs/usr/share/plymouth/themes/boppos
    fi
    if [ -d /localpkgs ]; then
        mkdir /tmp/localrepo && cp /localpkgs/*.pkg.tar.zst /tmp/localrepo/
        repo-add -q /tmp/localrepo/boppos-local.db.tar.zst /tmp/localrepo/*.pkg.tar.zst
        sed -i "/^\[bopp-os\]/i [boppos-local]\nSigLevel = Optional TrustAll\nServer = file:///tmp/localrepo\n" /tmp/profile/pacman.conf
        echo "using local packages: $(ls /tmp/localrepo | grep pkg.tar | tr "\n" " ")"
    fi
    mkarchiso -v -w /out/work -o /out /tmp/profile' 2>&1 | tee "$logs/iso-build.log"
rm -rf "$out/work"
if [ -n "${SUDO_UID:-}" ]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"/*.iso "$logs/iso-build.log"; fi
ls -lh "$out"/*.iso
