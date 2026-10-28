#!/usr/bin/env bash
# build.sh — build the BoppOS installer ISO with mkarchiso in a privileged Arch Linux container. Needs root and podman
# (run on the host or in CI, not in the Litterbox).
#
#   sudo image/build.sh [outdir]     (default /var/tmp/boppos-iso)
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
# shellcheck disable=SC2016  # expanded inside the container
# Host networking: rootful podman's default container network did not resolve DNS on the build host.
podman run --rm --privileged --network host -v "$here:/profile:ro" -v "$out:/out" -e WANT="$want" "$image" bash -euo pipefail -c '
    pacman -Syu --noconfirm --needed archiso >/dev/null
    pacman-key --init >/dev/null 2>&1
    pacman-key --populate archlinux >/dev/null 2>&1
    fpr=$(gpg --with-colons --show-keys /profile/keys/boppos.asc | awk -F: "/^fpr/ {print \$10; exit}")
    [ "$fpr" = "$WANT" ] || { echo "keys/boppos.asc is $fpr, expected $WANT"; exit 1; }
    pacman-key --add /profile/keys/boppos.asc >/dev/null
    pacman-key --lsign-key "$WANT" >/dev/null
    mkarchiso -v -w /out/work -o /out /profile' 2>&1 | tee "$logs/iso-build.log"
rm -rf "$out/work"
if [ -n "${SUDO_UID:-}" ]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"/*.iso "$logs/iso-build.log"; fi
ls -lh "$out"/*.iso
