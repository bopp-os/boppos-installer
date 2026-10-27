#!/usr/bin/env bash
# Probe: does `bootc install to-disk` produce a bootable BoppOS disk, per --bootloader value?
# Needs root and podman (run on the host or in CI, not in the Litterbox). Writes only to a loopback file.
#
#   sudo tests/bootloader-probe.sh [image] [workdir]
#
# For each bootloader value it installs to a fresh 40G sparse image, prints the partition table and the ESP contents,
# and, if qemu + OVMF are present, boots it headless for 60s and greps the serial log for a login prompt.
set -euo pipefail

IMAGE="${1:-ghcr.io/bopp-os/cachyos-plasma:latest}"
WORK="${2:-$(mktemp -d)}"
OVMF="${OVMF:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
mkdir -p "$WORK"
echo "image=$IMAGE work=$WORK"
podman pull "$IMAGE"

for bl in systemd grub none; do
    img="$WORK/disk-$bl.img"
    log="$WORK/install-$bl.log"
    rm -f "$img"; truncate -s 40G "$img"
    echo "=== --bootloader $bl"
    loopdev=$(losetup --find --show --partscan "$img")
    trap 'losetup -d "$loopdev" 2>/dev/null || true' EXIT
    if podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
        -v /dev:/dev -v /var/lib/containers:/var/lib/containers "$IMAGE" \
        bootc install to-disk --bootloader "$bl" --wipe --generic-image --karg=console=ttyS0 \
        --source-imgref "containers-storage:$IMAGE" "$loopdev" >"$log" 2>&1; then
        echo "install: OK"
    else
        echo "install: FAILED (tail of $log)"; tail -n 15 "$log"
    fi
    sfdisk -l "$loopdev" || true
    mkdir -p "$WORK/esp"
    esp=$(lsblk -nrpo NAME,PARTTYPE "$loopdev" | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1}')
    if [ -n "$esp" ] && mount "$esp" "$WORK/esp"; then
        find "$WORK/esp" -maxdepth 4 | head -30; umount "$WORK/esp"
    else
        echo "no ESP found"
    fi
    losetup -d "$loopdev"; trap - EXIT
    if command -v qemu-system-x86_64 >/dev/null && [ -f "$OVMF" ]; then
        timeout 60 qemu-system-x86_64 -m 4096 -enable-kvm -nographic -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
            -drive file="$img",format=raw >"$WORK/boot-$bl.log" 2>&1 || true
        grep -q "login:" "$WORK/boot-$bl.log" && echo "boot: reached login" || echo "boot: NO login prompt (see $WORK/boot-$bl.log)"
    else
        echo "boot: skipped (need qemu-system-x86_64 and OVMF at \$OVMF)"
    fi
done
echo "Done. Logs in $WORK"
