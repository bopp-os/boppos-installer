#!/usr/bin/env bash
# Probes for `bootc install` on the BoppOS image. Needs root and podman (run on the host or in CI, not in the
# Litterbox). Writes only to sparse loopback files in the work dir.
#
#   sudo tests/bootloader-probe.sh {bootloaders|keep-home|all} [image] [workdir]
#   tests/bootloader-probe.sh boot [disk-image]     (as your user, no sudo)
#   sudo tests/bootloader-probe.sh verify [disk-image]
#
# boot: boots a disk the other modes made (default /var/tmp/boppos-probe/disk-keephome.img) in QEMU from the
#       virt-manager flatpak's QEMU extension (FLATPAK_APP to change it), read-only via snapshot=on, for
#       BOOT_TIMEOUT seconds (default 240), and looks for a login prompt on the serial console.
#       Log: /tmp/boppos-probe-boot.log.
# verify: mounts the disk read-only, reads every composefs object and lists the ones that fail (fs-verity or I/O),
#         resolves VERIFY_INODES (default: the ones from the first boot log) and shows the first bad file's extents.
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
#              KEEP_HOME_BOOTLOADER picks the bootloader (default systemd). KEEP_HOME_REUSE=1 skips the first
#              install and reuses disk-keephome.img from an earlier run.
#
# Every mode first prints a preflight of the image: bootc version and flags, systemd-boot EFI binary, bootc dracut
# module in the initramfs.
# --bootloader systemd adds --composefs-backend: bootc's ostree backend only installs bootloaders through bootupd,
# and systemd-boot is only supported on the composefs backend. composefs keeps /var in state/os/default/var and each
# deployment's /etc in state/deploy/<id>/etc, and has no --stateroot.
# PROBE_EXTRA_ARGS is appended to every bootc install (e.g. PROBE_EXTRA_ARGS=--allow-missing-verity).
set -euo pipefail

MODE="${1:-all}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"  # seconds QEMU may run before the probe looks for a login prompt

# boot mode needs neither root nor podman, so it runs before the rest of the setup.
if [ "$MODE" = boot ]; then
    disk="${2:-/var/tmp/boppos-probe/disk-keephome.img}"
    app="${FLATPAK_APP:-org.virt_manager.virt-manager}"
    log=/tmp/boppos-probe-boot.log
    [ "$(id -u)" = 0 ] && echo "warning: run boot mode as your user; flatpak apps are meant to run unprivileged"
    [ -r "$disk" ] || { echo "cannot read $disk"; exit 2; }
    echo "booting $disk with $app (${BOOT_TIMEOUT}s, log $log)"
    # Find QEMU and its UEFI firmware inside the sandbox (virt-manager's QEMU extension is at /app/lib/extensions).
    # shellcheck disable=SC2016  # expanded inside the sandbox
    flatpak run --device=all --filesystem="$(dirname "$disk")":ro --env=BOOT_TIMEOUT="$BOOT_TIMEOUT" --command=sh "$app" -c '
        q=$(command -v qemu-system-x86_64 || ls /app/lib/extensions/bin/qemu-system-x86_64 \
            /app/extensions/*/bin/qemu-system-x86_64 2>/dev/null | head -n1)
        fw=$(find "${q%/bin/*}" /app/share /usr/share \( -name "edk2-x86_64-code.fd*" -o -name "OVMF_CODE*.fd" \) \
             2>/dev/null | head -n1)
        case "$fw" in *.bz2) bunzip2 -c "$fw" >/tmp/edk2-code.fd && fw=/tmp/edk2-code.fd ;; esac
        echo "qemu=${q:-MISSING} firmware=${fw:-MISSING}"
        [ -n "$q" ] && [ -n "$fw" ] || { find "${q%/bin/*}" -iname "*edk2*" -o -iname "*ovmf*" 2>/dev/null | head -20; exit 3; }
        [ -r "$1" ] || { echo "disk not visible inside the sandbox: $1"; exit 3; }
        timeout "$BOOT_TIMEOUT" "$q" -m 4096 -enable-kvm -cpu host -nographic \
            -drive if=pflash,format=raw,readonly=on,file="$fw" -drive file="$1",format=raw,snapshot=on </dev/null
        exit 0' sh "$disk" >"$log" 2>&1 || true
    head -n3 "$log"
    if grep -q "login:" "$log"; then echo "boot: reached login"
    else echo "boot: NO login prompt"; tail -n 30 "$log"; fi
    exit 0
fi

# verify mode: read every composefs object on a probe disk (read-only) and report fs-verity failures.
if [ "$MODE" = verify ]; then
    disk="${2:-/var/tmp/boppos-probe/disk-keephome.img}"
    vmnt=$(mktemp -d /var/tmp/boppos-verify.XXXXXX)
    LOOPDEV=$(losetup -r --find --show --partscan "$disk")
    trap 'umount "$vmnt" 2>/dev/null; losetup -d "$LOOPDEV"; rmdir "$vmnt"' EXIT
    udevadm settle 2>/dev/null || true
    vroot=""
    for p in $(lsblk -nrpo NAME,TYPE "$LOOPDEV" | awk '$2=="part"{print $1}'); do
        [ "$(blkid -p -o value -s PART_ENTRY_TYPE "$p")" = 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 ] && vroot="$p"
    done
    [ -n "$vroot" ] || { echo "no root partition on $disk"; exit 2; }
    mount -o ro "$vroot" "$vmnt"
    echo "=== verify $disk ($vroot)"
    for ino in ${VERIFY_INODES:-88485 68745}; do
        echo "inode $ino: $(btrfs inspect-internal inode-resolve "$ino" "$vmnt" 2>&1 | tr '\n' ' ')"
    done
    total=$(find "$vmnt/composefs/objects" -type f | wc -l)
    echo "reading $total composefs objects (a few minutes)..."
    bad=$(find "$vmnt/composefs/objects" -type f -exec sh -c \
        'for f; do cat "$f" >/dev/null 2>&1 || echo "$f"; done' sh {} + | sed "s|^$vmnt/||")
    echo "unreadable (fs-verity or I/O error): $(printf '%s' "$bad" | grep -c . || true)"
    printf '%s\n' "$bad" | head -n 20
    # For the first bad file: does its btrfs extent map show holes (unwritten data)?
    first=$(printf '%s\n' "$bad" | head -n1)
    if [ -n "$first" ]; then
        echo "--- extent map of $first"; filefrag -v "$vmnt/$first" | head -n 25
    fi
    echo "--- image file holes: $(du -h "$disk" | cut -f1) used of $(du -h --apparent-size "$disk" | cut -f1)"
    exit 0
fi
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
XBOOTLDR_GUID=bc13c2ff-59e6-4262-a352-b275fd6f7172
ROOT_GUID=4f68bce3-e8cd-4db1-96e7-fbcaf984b709   # DPS root x86-64
LOOPDEV=""
read -ra EXTRA_ARGS <<<"${PROBE_EXTRA_ARGS:-}"

case "$MODE" in bootloaders|keep-home|all) ;; *) echo "usage: $0 {bootloaders|keep-home|all} [image] [workdir] | $0 {boot|verify} [disk-image]"; exit 2;; esac
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

# Run bootc from the image with host devices and container storage. The image ends with ENV SOURCE_DATE_EPOCH=""
# and mkfs.fat refuses an empty value, so unset it.
bootc_run() {
    podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t --unsetenv=SOURCE_DATE_EPOCH \
        -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$WORK/mnt:/target" \
        "$IMAGE" bootc "$@"
}

new_disk() {  # new_disk <file>: fresh sparse image attached as $LOOPDEV
    rm -f "$1"; truncate -s 40G "$1"
    LOOPDEV=$(losetup --find --show --partscan "$1")
}

part_by_guid() {  # part_by_guid <guid>: partition device of that type on $LOOPDEV
    # Probe the GPT with blkid -p: lsblk's PARTTYPE comes from udev and is empty right after losetup.
    udevadm settle 2>/dev/null || true
    local p
    for p in $(lsblk -nrpo NAME,TYPE "$LOOPDEV" | awk '$2=="part"{print $1}'); do
        if [ "$(blkid -p -o value -s PART_ENTRY_TYPE "$p" 2>/dev/null | tr '[:upper:]' '[:lower:]')" = "$1" ]; then
            echo "$p"; return
        fi
    done
}

boot_in_qemu() {  # boot_in_qemu <img> <log>
    if command -v qemu-system-x86_64 >/dev/null && [ -f "$OVMF" ]; then
        timeout "$BOOT_TIMEOUT" qemu-system-x86_64 -m 4096 -enable-kvm -cpu host -nographic \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF" -drive file="$1",format=raw >"$2" 2>&1 || true
        if grep -q "login:" "$2"; then echo "boot: reached login"; else echo "boot: NO login prompt (see $2)"; fi
    else
        echo "boot: skipped (need qemu-system-x86_64 and OVMF at \$OVMF)"
    fi
}

backend_args() {  # backend_args <bootloader>: bootc install flags for that bootloader
    if [ "$1" = systemd ]; then echo --composefs-backend; fi
}

preflight() {
    echo "=== preflight ($IMAGE)"
    podman run --rm --unsetenv=SOURCE_DATE_EPOCH "$IMAGE" sh -c '
        bootc --version
        echo "--- bootc install to-disk flags:"
        bootc install to-disk --help | grep -iE -- "composefs|bootloader|verity" || echo "(none matched)"
        for f in /usr/lib/systemd/boot/efi/systemd-bootx64.efi /usr/lib/bootc/initramfs-setup; do
            if [ -e "$f" ]; then echo "present: $f"; else echo "MISSING: $f"; fi
        done
        echo "--- bootc files in initramfs:"
        for i in /usr/lib/modules/*/initramfs.img; do
            echo "$i"; lsinitrd "$i" 2>/dev/null | grep -i bootc || echo "  (no bootc files, or lsinitrd missing)"
        done' || echo "preflight: container run FAILED"
}

install_to_disk() {  # install_to_disk <bootloader> <log>
    mkdir -p "$WORK/mnt"
    # shellcheck disable=SC2046  # backend_args is zero or one flag
    bootc_run install to-disk --bootloader "$1" $(backend_args "$1") --wipe --generic-image --karg=console=ttyS0 \
        "${EXTRA_ARGS[@]}" --source-imgref "containers-storage:$IMAGE" "$LOOPDEV" >"$2" 2>&1
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
    local img="$WORK/disk-keephome.img" mnt="$WORK/mnt" bl="$KEEP_HOME_BOOTLOADER"
    local esp root boot layout stateroot var deploydir olddep newdep
    local -a target_args=()
    echo "=== keep-home (bootloader $bl)"
    if [ "${KEEP_HOME_REUSE:-0}" = 1 ] && [ -f "$img" ]; then
        echo "reusing the first install in $img (KEEP_HOME_REUSE=1)"
        LOOPDEV=$(losetup --find --show --partscan "$img")
    else
        new_disk "$img"
        if ! install_to_disk "$bl" "$WORK/keephome-install1.log"; then
            echo "first install FAILED"; tail -n 15 "$WORK/keephome-install1.log"; cleanup; return
        fi
    fi
    sfdisk -l "$LOOPDEV"
    esp=$(part_by_guid "$ESP_GUID")
    root=$(part_by_guid "$ROOT_GUID")
    # A separate /boot, if any, is an XBOOTLDR partition (not the 1M BIOS boot one bootc also creates).
    boot=$(part_by_guid "$XBOOTLDR_GUID")
    echo "esp=$esp root=$root boot=${boot:-none}"
    [ -n "$root" ] || { echo "no DPS root partition found; cannot continue"; cleanup; return; }

    # Find /var and the deployment for either backend.
    mkdir -p "$mnt"; mount "$root" "$mnt"
    if [ -d "$mnt/state/deploy" ]; then
        layout=composefs
        var="$mnt/state/os/default/var"
        deploydir="$mnt/state/deploy"
    else
        layout=ostree
        stateroot=$(basename "$(find "$mnt/ostree/deploy" -mindepth 1 -maxdepth 1 -type d | head -n1)")
        var="$mnt/ostree/deploy/$stateroot/var"
        deploydir="$mnt/ostree/deploy/$stateroot/deploy"
        target_args=(--stateroot "$stateroot")
    fi
    olddep=$(find "$deploydir" -mindepth 1 -maxdepth 1 -type d ! -name '*.probe-old' | head -n1)
    echo "layout=$layout old deployment=$(basename "$olddep")"
    [ -n "$olddep" ] || { echo "no deployment found; cannot continue"; cleanup; return; }

    # Plant markers in the "old" system.
    mkdir -p "$var/home/probeuser"
    echo keep-me >"$var/home/probeuser/marker"
    echo etc-merged >"$olddep/etc/boppos-probe-marker"
    [ -n "$boot" ] && mount "$boot" "$mnt/boot"
    mkdir -p "$mnt/boot/efi"; mount "$esp" "$mnt/boot/efi"
    mkdir -p "$mnt/boot/efi/EFI/Microsoft/Boot"
    echo fake >"$mnt/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi"
    echo "--- ESP before reinstall"; find "$mnt/boot/efi" -maxdepth 3

    # Reinstall alongside (same stateroot on ostree), with the partitions mounted at /target.
    reinstall() {  # reinstall <log>
        # shellcheck disable=SC2046  # backend_args is zero or one flag
        bootc_run install to-filesystem --replace=alongside --acknowledge-destructive "${target_args[@]}" \
            --bootloader "$bl" $(backend_args "$bl") --karg=console=ttyS0 "${EXTRA_ARGS[@]}" \
            --source-imgref "containers-storage:$IMAGE" /target >"$1" 2>&1
    }
    if reinstall "$WORK/keephome-install2.log"; then
        echo "reinstall: OK"
    else
        echo "reinstall: FAILED"; tail -n 20 "$WORK/keephome-install2.log"
        # composefs names the deployment dir by image digest, so the same image collides with the old one.
        # Retry the way the installer would: move the old deployment aside, keep state/os/default/var.
        if [ "$layout" = composefs ] && grep -q 'symlink for /var: File exists' "$WORK/keephome-install2.log"; then
            echo "retry: moving $(basename "$olddep") aside to *.probe-old, keeping state/os/default/var"
            rm -rf "$olddep.probe-old"; mv "$olddep" "$olddep.probe-old"; olddep="$olddep.probe-old"
            if reinstall "$WORK/keephome-install3.log"; then echo "retry reinstall: OK"
            else echo "retry reinstall: FAILED"; tail -n 20 "$WORK/keephome-install3.log"; fi
        fi
    fi

    # Report. Remount in case bootc left things read-only or unmounted.
    mountpoint -q "$mnt" || mount "$root" "$mnt"
    mountpoint -q "$mnt/boot/efi" || mount "$esp" "$mnt/boot/efi"
    echo "--- deployments now:"; find "$deploydir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
    if [ -f "$var/home/probeuser/marker" ]; then echo "home: KEPT"; else echo "home: LOST"; fi
    newdep=$(find "$deploydir" -mindepth 1 -maxdepth 1 -type d ! -path "$olddep" | head -n1)
    if [ -z "$newdep" ] && [ "$layout" = composefs ]; then
        # composefs names deployments by image digest, so the same image reuses the old one.
        echo "/etc merge: no new deployment id (same image reuses the old one); checking it"
        newdep="$olddep"
    fi
    if [ -z "$newdep" ]; then echo "/etc merge: no new deployment found"
    elif [ -f "$newdep/etc/boppos-probe-marker" ]; then echo "/etc merge: old /etc change CARRIED OVER"
    else echo "/etc merge: old /etc change NOT carried over"; fi
    if [ -f "$mnt/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        echo "ESP: EFI/Microsoft KEPT"; else echo "ESP: EFI/Microsoft DELETED"; fi
    echo "--- ESP after reinstall"; find "$mnt/boot/efi" -maxdepth 3
    local f
    for f in "$mnt/boot/efi/loader/loader.conf" "$mnt"/boot/efi/loader/entries/*.conf; do
        [ -f "$f" ] && { echo "--- ${f#"$mnt"/boot/efi/}"; cat "$f"; }
    done
    cleanup
    boot_in_qemu "$img" "$WORK/boot-keephome.log"
}

preflight
case "$MODE" in
    bootloaders) probe_bootloaders ;;
    keep-home) probe_keep_home ;;
    all) probe_bootloaders; probe_keep_home ;;
esac
echo "Done. Logs in $WORK"
