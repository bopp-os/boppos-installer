#!/usr/bin/env bash
# Probes for `bootc install` on the BoppOS image. Needs root and podman (run on the host or in CI, not in the
# Litterbox). Writes only to sparse loopback files in the work dir.
#
#   sudo tests/bootloader-probe.sh {bootloaders|keep-home|all} [image] [workdir]
#
# [image] defaults to the image the host is booted from (`bootc status`), so a znver4 host tests the znver4 image.
# [workdir] defaults to /var/tmp/boppos-probe: on disk, since /tmp is tmpfs on CachyOS.
# Tags are per CPU level: :v3, :v4, :znver4 (see the image repo's build-*.yml workflows).
#
# bootloaders: for each --bootloader value, install to a fresh 40G image, print the partition table and ESP contents,
#              and boot it in QEMU (if qemu + OVMF are present) looking for a login prompt.
# keep-home:   install once, plant a file in /var/home, a changed file in the deployment's /etc and a fake
#              EFI/Microsoft on the ESP, then reinstall with `to-filesystem --replace=alongside` into the same
#              stateroot and report what survived (see docs/design.md, section 4b).
#              KEEP_HOME_BOOTLOADER picks the bootloader (default systemd).
set -euo pipefail

MODE="${1:-all}"
# Default image: the one this host is booted from (e.g. ghcr.io/bopp-os/cachyos-plasma:znver4).
booted_image() {
    bootc status --format=json 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["booted"]["image"]["image"]["image"])' 2>/dev/null
}
IMAGE="${2:-$(booted_image || true)}"
if [ -z "$IMAGE" ]; then
    echo "Could not read the booted image from 'bootc status'; pass one, e.g. ghcr.io/bopp-os/cachyos-plasma:znver4"
    exit 2
fi
WORK="${3:-/var/tmp/boppos-probe}"
OVMF="${OVMF:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
KEEP_HOME_BOOTLOADER="${KEEP_HOME_BOOTLOADER:-systemd}"
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
ROOT_GUID=4f68bce3-e8cd-4db1-96e7-fbcaf984b709   # DPS root x86-64
LOOPDEV=""

case "$MODE" in bootloaders|keep-home|all) ;; *) echo "usage: $0 {bootloaders|keep-home|all} [image] [workdir]"; exit 2;; esac
mkdir -p "$WORK"
echo "mode=$MODE image=$IMAGE work=$WORK"
podman pull "$IMAGE"

cleanup() {
    for m in "$WORK/mnt/boot/efi" "$WORK/mnt/boot" "$WORK/mnt" "$WORK/esp"; do
        mountpoint -q "$m" && umount "$m"
    done
    [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null
    LOOPDEV=""
}
trap cleanup EXIT

# Run bootc from the image with host devices and container storage.
bootc_run() {
    podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
        -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$WORK/mnt:/target" \
        "$IMAGE" bootc "$@"
}

new_disk() {  # new_disk <file>: fresh sparse image attached as $LOOPDEV
    rm -f "$1"; truncate -s 40G "$1"
    LOOPDEV=$(losetup --find --show --partscan "$1")
}

part_by_guid() {  # part_by_guid <guid>: partition device of that type on $LOOPDEV
    lsblk -nrpo NAME,PARTTYPE "$LOOPDEV" | awk -v g="$1" 'tolower($2)==g{print $1; exit}'
}

boot_in_qemu() {  # boot_in_qemu <img> <log>
    if command -v qemu-system-x86_64 >/dev/null && [ -f "$OVMF" ]; then
        timeout 90 qemu-system-x86_64 -m 4096 -enable-kvm -nographic \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF" -drive file="$1",format=raw >"$2" 2>&1 || true
        if grep -q "login:" "$2"; then echo "boot: reached login"; else echo "boot: NO login prompt (see $2)"; fi
    else
        echo "boot: skipped (need qemu-system-x86_64 and OVMF at \$OVMF)"
    fi
}

install_to_disk() {  # install_to_disk <bootloader> <log>
    mkdir -p "$WORK/mnt"
    bootc_run install to-disk --bootloader "$1" --wipe --generic-image --karg=console=ttyS0 \
        --source-imgref "containers-storage:$IMAGE" "$LOOPDEV" >"$2" 2>&1
}

probe_bootloaders() {
    for bl in systemd grub none; do
        local img="$WORK/disk-$bl.img" log="$WORK/install-$bl.log" esp
        echo "=== --bootloader $bl"
        new_disk "$img"
        if install_to_disk "$bl" "$log"; then echo "install: OK"; else echo "install: FAILED"; tail -n 15 "$log"; fi
        sfdisk -l "$LOOPDEV" || true
        mkdir -p "$WORK/esp"
        esp=$(part_by_guid "$ESP_GUID")
        if [ -n "$esp" ] && mount "$esp" "$WORK/esp"; then
            find "$WORK/esp" -maxdepth 4 | head -30; umount "$WORK/esp"
        else
            echo "no ESP found"
        fi
        cleanup
        boot_in_qemu "$img" "$WORK/boot-$bl.log"
    done
}

probe_keep_home() {
    local img="$WORK/disk-keephome.img" mnt="$WORK/mnt" esp root boot dep stateroot
    echo "=== keep-home (bootloader $KEEP_HOME_BOOTLOADER)"
    new_disk "$img"
    if ! install_to_disk "$KEEP_HOME_BOOTLOADER" "$WORK/keephome-install1.log"; then
        echo "first install FAILED"; tail -n 15 "$WORK/keephome-install1.log"; cleanup; return
    fi
    sfdisk -l "$LOOPDEV"
    esp=$(part_by_guid "$ESP_GUID")
    root=$(part_by_guid "$ROOT_GUID")
    # A /boot partition, if any, is the one that is neither ESP nor root.
    boot=$(lsblk -nrpo NAME,TYPE "$LOOPDEV" | awk '$2=="part"{print $1}' | grep -vxF -e "$esp" -e "$root" | head -n1 || true)
    echo "esp=$esp root=$root boot=${boot:-none}"
    [ -n "$root" ] || { echo "no DPS root partition found; cannot continue"; cleanup; return; }

    # Plant markers in the "old" system.
    mkdir -p "$mnt"; mount "$root" "$mnt"
    stateroot=$(basename "$(find "$mnt/ostree/deploy" -mindepth 1 -maxdepth 1 -type d | head -n1)")
    dep=$(find "$mnt/ostree/deploy/$stateroot/deploy" -mindepth 1 -maxdepth 1 -type d -name '*.0' | head -n1)
    echo "stateroot=$stateroot old deployment=$(basename "$dep")"
    mkdir -p "$mnt/ostree/deploy/$stateroot/var/home/probeuser"
    echo keep-me >"$mnt/ostree/deploy/$stateroot/var/home/probeuser/marker"
    echo etc-merged >"$dep/etc/boppos-probe-marker"
    [ -n "$boot" ] && mount "$boot" "$mnt/boot"
    mkdir -p "$mnt/boot/efi"; mount "$esp" "$mnt/boot/efi"
    mkdir -p "$mnt/boot/efi/EFI/Microsoft/Boot"
    echo fake >"$mnt/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi"
    echo "--- ESP before reinstall"; find "$mnt/boot/efi" -maxdepth 3

    # Reinstall alongside into the same stateroot, with the partitions mounted at /target.
    if bootc_run install to-filesystem --replace=alongside --acknowledge-destructive \
        --stateroot "$stateroot" --bootloader "$KEEP_HOME_BOOTLOADER" --karg=console=ttyS0 \
        --source-imgref "containers-storage:$IMAGE" /target >"$WORK/keephome-install2.log" 2>&1; then
        echo "reinstall: OK"
    else
        echo "reinstall: FAILED"; tail -n 20 "$WORK/keephome-install2.log"
    fi

    # Report. Remount in case bootc left things read-only or unmounted.
    mountpoint -q "$mnt" || mount "$root" "$mnt"
    mountpoint -q "$mnt/boot/efi" || mount "$esp" "$mnt/boot/efi"
    echo "--- deployments now:"; find "$mnt/ostree/deploy/$stateroot/deploy" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
    if [ -f "$mnt/ostree/deploy/$stateroot/var/home/probeuser/marker" ]; then
        echo "home: KEPT"; else echo "home: LOST"; fi
    local newest
    newest=$(find "$mnt/ostree/deploy/$stateroot/deploy" -mindepth 1 -maxdepth 1 -type d -name '*.0' \
        -newer "$dep" | head -n1)
    if [ -z "$newest" ]; then echo "/etc merge: no new deployment found"
    elif [ -f "$newest/etc/boppos-probe-marker" ]; then echo "/etc merge: old /etc change CARRIED OVER"
    else echo "/etc merge: old /etc change NOT carried over"; fi
    if [ -f "$mnt/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        echo "ESP: EFI/Microsoft KEPT"; else echo "ESP: EFI/Microsoft DELETED"; fi
    echo "--- ESP after reinstall"; find "$mnt/boot/efi" -maxdepth 3
    cleanup
    boot_in_qemu "$img" "$WORK/boot-keephome.log"
}

case "$MODE" in
    bootloaders) probe_bootloaders ;;
    keep-home) probe_keep_home ;;
    all) probe_bootloaders; probe_keep_home ;;
esac
echo "Done. Logs in $WORK"
