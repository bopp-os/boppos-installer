# BoppOS net-installer: design and options

Status: **proposal, nothing built.** Written 2026-10-27. Recommendation: fork tuna-os/bootc-installer (option E,
confirmed by the maintainer 2026-10-27). Bootloader path verified on a loopback disk (section 4a). Open decisions:
section 7.

Goal: a bootable installer image in the style of SteamOS Recovery (not a live-USB demo). The user boots it and picks
target drive, user account, desktop flavor (or "deckify" Gaming Mode), Wi-Fi/Ethernet, and basic hardware optimizations.
It then downloads the BoppOS bootc image and installs it. It hands off to the `boppos-deck --welcome` / `--oobe` wizard.

## 1. Facts that constrain the choice

| Fact | Source | Consequence |
|---|---|---|
| BoppOS is Arch/CachyOS, built from `Containerfile.base` + flavor Containerfiles. | `~/Projects/boppos/cachyos` | Anything RPM-native (Anaconda) runs on a different OS than the payload. |
| The image installs `bootc`, `ostree`, `dracut`, `btrfs-progs`, `e2fsprogs`, `dosfstools`. It installs **no** GRUB, `bootupd`, `shim`, `efibootmgr`. | `files/base/base.yaml` (grep for grub/bootupd: no hits) | The ostree backend can't install a bootloader. **Answered in section 4a:** `--composefs-backend --bootloader systemd` installs and boots to login. |
| Default root FS is btrfs (`00-rootfs.toml`). `/boot` is not forced to ext4. | `files/base/usr/lib/bootc/install/` | Installer must keep btrfs as the default and not assume ext4 `/boot`. |
| Image-wide kargs live in `90-boppos-optimizations.toml`; DMI-matched presets live in boppos-tools `kargs.d/*.conf` and `boppos.hwprofiles`. | image repo, boppos-tools | Hardware step reuses these, never copies them. |
| bootc `install to-disk` / `to-filesystem` options (v1.16.13): `--bootloader grub\|grub-cc\|systemd\|none`, `--filesystem`, `--karg`, `--block-setup direct\|tpm2-luks`, `--source-imgref`, `--target-imgref`, `--composefs-backend`, `--bound-images`. | [bootc man page](https://www.mankier.com/8/bootc-install-to-disk) | Flags we need (kargs, TPM2 LUKS, bootloader choice) exist. `to-disk` is whole-disk only; RAID/LVM/LUKS/partition reuse go through `to-filesystem`. |
| Upstream default bootloader path runs `bootupctl` to install GRUB. | [bootc#949](https://github.com/bootc-dev/bootc/issues/949), [bootc#1752](https://github.com/bootc-dev/bootc/pull/1752) | Without bootupd in the image the default fails or needs `--bootloader none`/`systemd`. Unverified on our image. |

## 2. Options compared

### A. Fork Anaconda (the user's lean)

Anaconda has a `bootc` kickstart command and an `ostreecontainer` one, so installing a container image is a
supported path ([Fedora Magazine](https://fedoramagazine.org/introducing-the-new-bootc-kickstart-command-in-anaconda/)).
Fedora/Universal Blue ship installers this way, and bootc-image-builder can wrap it into an ISO
([osbuild docs](https://osbuild.org/docs/developer-guide/projects/image-builder/advanced/bootc/isos/)).

Why it is a poor fit for BoppOS:
- It is an RPM/Fedora program. The installer environment would have to be Fedora (or a Fedora-based bootc image) while the
  payload is Arch. We would maintain a Fedora build of Anaconda plus our patches, in a distro we do not otherwise use.
  Packaging Anaconda for Arch is possible in principle but I found no maintained Arch package (not checked on the AUR).
- Anaconda treats the result as a Fedora install (default btrfs layout problems on CentOS Stream shown in the article).
  Expect the same kind of Fedora assumptions on an Arch payload; "handling images by their contained OS" is a future plan only.
- Documented `bootc` command gaps: no multi-disk partitioning, no arbitrary mount points, no authenticated registries.
- The new Web UI is the maintained front end; the GTK one is legacy. Forking the web UI means React/Cockpit-style JS
  plus Python backend plus kickstart. A user-account/flavor/Wi-Fi/hardware page set is a deep patch, not a theme.
- Bootloader is still `bootc`'s job underneath, so Anaconda does **not** solve the open bootloader question (section 4).
- bootc-image-builder's Anaconda ISO types are Fedora-content installers; a Jira ticket reports ELN environments even for
  non-matching payloads and GRUB incompatibility ([search result](https://issues.redhat.com/browse/HMS-3783), a ticket, not documented behavior).

Cost: highest. Value over the others: partitioning UI and localization for free, which we mostly do not need for a
single-purpose net installer.

### B. Calamares

Calamares copies a filesystem (unpackfs, squashfs/rsync) and installs a bootloader (GRUB or systemd-boot) into it.
That is the model CachyOS's own installer uses. For an ostree/bootc payload we would write a custom job module that
runs `bootc install to-filesystem` and skip unpackfs, bootloader, fstab, users modules, i.e. use only the partition and
UI shell. Qt/C++ with Python job modules; Arch has it packaged. Less Fedora baggage than A, but we would still keep
disabling most of what it does, and its user-account module writes into a normal `/etc`, which does not match a
deployed ostree root. Reasonable second choice if a Qt partition UI is wanted.

### C. Minimal custom installer around `bootc install` (earlier recommendation; now the fallback)

A small Python backend (probe disks, build a plan, run `bootc install`, create user, write first-run marker) behind two
front ends sharing one backend: a GTK4/libadwaita wizard (same stack, theme, and artwork as `boppos-deck`) and a plain
TUI/CLI for headless and fallback use. About 2-4k lines. We own every step, and the same code can drive an unattended
install from a JSON answers file (useful for CI testing without a GUI).
- Partitioning: whole-disk via `bootc install to-disk` (covers the "pick a drive" case and wipes it);
  "install to a partition / alongside another OS" via our own `sfdisk`/`mkfs` plan plus `to-filesystem`.
- Pros: no foreign OS, smallest image, reuses `boppos.hwprofiles`, Arch tooling, easy to read and test.
- Cons: we write and own partition safety UI, i18n, and edge cases (existing Windows ESP, BitLocker, RAID). Mitigation:
  v1 only offers "erase this disk" and "use the free space/an existing partition I mark"; no resizing.

### D. Fedora bootc-image-builder alone

bib produces disk images and ISOs from a bootc image. A disk image is useful for VMs and CI (`bib` can make qcow2/raw),
but it needs a Fedora-based builder container and its ISO types wrap Anaconda (so it inherits A). It also has its own
btrfs limits (no subvolumes at build time per RHEL docs). Use it, if at all, only as a test fixture, not as the installer.

### E. Fork tuna-os/bootc-installer (recommended)

[tuna-os/bootc-installer](https://github.com/tuna-os/bootc-installer) is a GTK4/libadwaita installer for bootc images,
a hard fork of the Vanilla OS installer by way of `projectbluefin/bootc-installer` (archived 2026-09). GPL-3.0, active
(last push 2026-10-26). The UI is Python; the install work is done by its Go backend
[tuna-os/fisherman](https://github.com/tuna-os/fisherman) (git submodule, GPL-3.0, 51 Go files), which reads a JSON
recipe and runs `bootc install to-filesystem`. Checked in the source (shallow clones, 2026-10-27):
- Two boot stacks: systemd-boot + composefs (`composeFsBackend`, `bootloader: systemd` in the recipe) and GRUB2.
  The composefs path is the one section 4a verified for BoppOS. A recipe rule already refuses composefs on XFS.
- LUKS2 for new installs: passphrase, TPM2, or both.
- User creation that knows the composefs layout (`internal/post/user.go`: first-boot tmpfiles for `/var/home/<user>`).
- Unattended install from a JSON recipe (`--autoinstall`), offline install from a live ISO, a phone companion.
- Several front ends (GNOME/GTK, KDE, COSMIC, niri, XFCE); we would ship only the GTK one.

What it lacks, which BoppOS adds on the fork:
1. **Reinstall keeping `/home`** (no `alongside` handling in fisherman): the section 4a steps (save other OSes'
   `EFI/<vendor>`, save `/etc` accounts and connections, move old `state/deploy/<id>` aside, install, merge, clean up).
2. **Optional in-place LUKS2 of the kept root** with `cryptsetup reencrypt` (btrfs/ext4 only, not XFS), before bootc.
3. **CPU-level image tag**: pick `:znver4` / `:v4` / `:v3` from the CPU (section 3), with an override.
4. **Dark mode by default** with a light toggle (`AdwStyleManager`), BoppOS branding, flavors from `flavors.json`,
   the hardware-presets page, and the handoff marker for `boppos-deck --welcome` / `--oobe` (section 6).
5. Defaults for BoppOS: btrfs, composefs, systemd-boot; hide Bluefin/Fedora-specific steps.

**Tested 2026-10-28** (`bootloader-probe.sh fisherman`, `boppos` branch of bopp-os/fisherman, loopback disk on the
host): fisherman installs `cachyos-plasma:znver4` end to end in about 9 minutes (OCI export ~3.5 min, bootc ~6 min)
with btrfs + composefs + systemd-boot + `genericImage`; same ESP layout and boot entry as section 4a. Three fixes
were needed on the fork, all candidates for upstream (the 4th came with the boot test):
1. `skipFlatpaks` recipe field (an empty list installs Firefox and two GNOME apps, copied from the running machine).
2. `skopeo copy --remove-signatures` for the composefs OCI export (fails when the store holds cosign signatures).
3. Hash plaintext passwords before `chpasswd -e` on composefs (the deploy root has `pam.d` but no PAM modules).
4. `kernelArgs` recipe field (one `bootc --karg` each); fisherman had no way to pass kernel arguments, needed for
   hardware presets and for `console=ttyS0` in VM tests.

The fisherman-installed disk boots in QEMU (4 GB, `-cpu host`) to `boppos-test login:` with no failed units; the
hostname and test user come from the recipe. It also shows the guest-only fs-verity errors from section 4a.

What fisherman does beyond the recipe, for BoppOS to decide on:
- Copies the running system's Wi-Fi connections and Bluetooth pairings into the target (right on the live ISO,
  where they come from the installer session; the probe hides them on the host).
- Appends `rhgb quiet` to every boot entry for Plymouth (`rhgb` is a Fedora-only argument; BoppOS already has
  `splash`).
- Enables `cups-browsed`, `avahi-daemon`, `ipp-usb`; writes friendly audio device names (WirePlumber rules);
  pre-generates wallpaper thumbnails and caches; runs `restorecon` (no-op without SELinux).
- Looks up the new EFI boot entry with `efibootmgr` for the frontend's BootNext; warns if it is missing. The ISO
  should ship `efibootmgr`.

Risks: a large, fast-moving upstream (about 1.7 MB of Python plus Go, QML and C++ front ends); Fedora/Universal Blue
assumptions to find and switch off (SELinux fields, GRUB paths, Bluefin images); packaged as a Flatpak upstream,
while our ISO needs a native build. Mitigation: keep BoppOS changes as small, separate commits on a branch that
rebases on upstream, and offer the generic ones (keep-home, CPU-level tags) upstream.

### Summary

| | A Anaconda | B Calamares | C custom | D bib | **E fork tuna-os** |
|---|---|---|---|---|---|
| Fits Arch payload | poor | ok | good | poor | **good** (verify for Fedora-isms) |
| Effort to first working install | high | medium | low-medium | n/a | **low** |
| Own the UX (flavor, deckify, Wi-Fi, hw-opts) | deep patching | modules in C++/Python | direct | no | **patches to a GTK app** |
| systemd-boot + composefs install | no | no | to write | no | **built in** |
| Keep-home reinstall | no | no | to write | no | **to add (fisherman)** |
| Maintenance | Fedora toolchain | Qt + Calamares upgrades | our code only | Fedora tool | **rebase on upstream** |

Recommendation: **E**. It already does the composefs + systemd-boot install that section 4a proved works, plus LUKS2,
user creation and unattended recipes. C remains the fallback if the fork's Fedora assumptions prove too deep.

## 3. How the installer image is built and booted

Two sub-questions: what the installer environment is, and how it boots.

Environment (recommended): an **archiso-style (or CachyOS live-profile) minimal image**, UEFI only first, with
`bootc`, `ostree`, `skopeo`/`podman` not needed (bootc pulls the image itself), `NetworkManager` (+ `iwd` for Wi-Fi),
`cage` (kiosk Wayland compositor) autostarting the installer, `boppos-tools` (for `hwprofiles` and artwork), `btrfs-progs`,
`dosfstools`, `cryptsetup`, `sfdisk`, firmware, and a minimal GPU stack. Boots straight into the wizard like SteamOS Recovery; no
desktop, no shell unless the user presses a hidden key (tty2). Building needs `mkarchiso`, which needs root and loop
devices, so it runs in **CI** (GitHub Actions) or on the host, not in the Litterbox.

With option E, the forked installer comes from the bopp-os package repo (`bopp-os/pkgbuilds`,
`packages/boppos-bootc-installer`): one split PKGBUILD builds `boppos-bootc-installer` (Python UI) and
`boppos-fisherman` (Go backend) from pinned commits of the two `boppos` branches. The `boppos-` names keep a
same-named package elsewhere from replacing them (pacman takes a package from the first repo that has its name);
`provides`/`conflicts` cover the upstream names, and the binaries keep theirs. The ISO lists them in
`packages.x86_64`, no Flatpak runtime, and `cage` launches the installer full-screen.

The profile is `image/` (archiso v91, derived from its baseline/releng profiles), built with
`sudo image/build.sh` (mkarchiso in a privileged Arch container; log in `probe-logs/iso-build.log`):
- UEFI only (`uefi.systemd-boot`), squashfs (xz), Arch `core`/`extra` plus `[bopp-os]` (key `keys/boppos.asc`,
  fingerprint checked by the build).
- tty1 autologins `liveuser` (sysusers, passwordless sudo), whose login runs `cage -s -- bootc-installer`; tty2
  has a root shell. `/etc/bootc-installer/live-iso-mode` tells fisherman it is live media, so the installer uses
  `sudo` (no polkit agent in cage).
- `/etc/bootc-installer/images.json` lists the four flavors (plasma, gnome, niri, cinnamon) with `znver4`/`v4`/`v3`
  tags to pick by hand until CPU detection exists; each sets composefs, systemd-boot, btrfs and `skip_flatpaks`.
- Memory floor (4c): `copytoram=n`, zram up to 4 GB only on machines with ≤ 8 GB, `/tmp` capped at 25%.
- Second boot entry with `console=ttyS0` for VM tests.
- Needed in the packages first: UI pass-through of `skipFlatpaks`/`kernelArgs`, and fisherman excluding
  archiso's boot medium (`/run/archiso/bootmnt`) from install targets.

Alternative: build the installer environment as a bootc/OCI image from the same CachyOS base and convert it with a
disk-image tool. More parts, same result; revisit if we want the installer itself updatable. Not for v1.

Boot: the ISO/USB boots under UEFI with systemd-boot or GRUB from archiso (this is the installer's bootloader and is
independent of the target's bootloader). Secure Boot is **off** for v1 (consistent with `bootloader-parked.md`: Secure Boot
is parked for the target). The installer ISO is hybrid so it also works on `dd` to a USB drive.

Online model: ISO is small (~1 GB); on boot it brings up the network (Ethernet automatically, Wi-Fi page otherwise),
fetches `flavors.json` from a fixed URL (flavor name, image ref, size, deckify availability), then `bootc install` pulls
`ghcr.io/bopp-os/cachyos-<flavor>:<cpu-level>` directly. Images are tagged per CPU level (`v3`, `v4`, `znver4`; see the
image repo's `build-*.yml`), so the installer detects the CPU and picks the highest level it supports (znver4 = Zen 4,
checked in CI via the `avx512_vnni` flag; v4 = x86-64-v4; else v3), and lets the user override it. Cosign verification: ship `cosign.pub` and a `policy.json`
in the installer; point `--target-imgref` at the signed registry ref.

## 4. The bootloader question

**Answered in section 4a**: composefs backend + systemd-boot. The text below is the original analysis.

Before the probe, `bootc install` on this image **could not be assumed to work end to end**:
- The image has no GRUB, `bootupd` or `shim` package (checked in `base.yaml`). bootc's default (`grub`) goes through
  `bootupctl`.
- `--bootloader systemd` exists. It uses `bootctl`/systemd-boot from inside the image; on Arch the `systemd` package
  is believed to ship the EFI binaries under `/usr/lib/systemd/boot/efi` (to verify in the image). Needs the ESP mounted and, per
  `bootloader-parked.md`, `/boot` readable by systemd-boot (FAT or ESP as XBOOTLDR); bootc's layout for this mode is unverified.
- The reference machine still runs a leftover Fedora GRUB, so no real-world evidence exists for a clean install.

Three candidate answers, cheapest test first:
1. **Probe (do this first, 30 minutes):** `tests/bootloader-probe.sh` runs `bootc install to-disk` from the image against a
   loopback disk with each `--bootloader` value and records which succeeds, the partition table, and what lands in the ESP.
   Then boot the result in QEMU with OVMF. Needs root + podman, so run on the host or CI.
2. **systemd-boot via bootc** if the probe passes: no image changes besides confirming `bootctl` is present; matches the
   `systemd-boot-update.service` idea in the parked doc. Preferred.
3. **Add `bootupd` + GRUB (+ shim) to the image** (bootupd is AUR-only, shim from Arch is not Microsoft-signed): more work, only if
   systemd-boot fails.

Whatever the result, the installer calls bootc with an explicit `--bootloader` value taken from a field in `flavors.json`,
so the installer does not need to change when the image decision lands. If the choice is "none", the installer image
can run `bootctl install` itself against the mounted target ESP as a fallback (works, but then updates are unmanaged).

### 4a. systemd-boot means bootc's composefs backend (2026-10-27)

- First probe run: `--bootloader systemd` fails with `bootupd is required for ostree-based installs` (`install.rs`
  ~2104). On the ostree backend only bootupd installs bootloaders. bootc's `bootc-bootloaders.7.md`: systemd-boot is
  only supported on the composefs backend.
- BoppOS ships `/usr/lib/ostree/prepare-root.conf` (`scripts/bootc-rootfs.sh:27` in bopp-os/cachyos), so bootc picks
  ostree by default. The installer must pass `--composefs-backend --bootloader systemd`. Plain vmlinuz + initramfs with
  BLS entries works (no UKI, not sealed). `--allow-missing-verity` is set automatically when the root filesystem lacks
  fs-verity (`install.rs` 1957-1963).
- The initramfs needs bootc's dracut module (`bootc-root-setup.service`, `/usr/lib/bootc/initramfs-setup`). The image
  already adds `bootc` to `add_dracutmodules`; the probe's preflight checks the files are really there.
- Limits: no `--stateroot` (`install.rs` 428-433, always `default`); no logically bound images; a composefs machine
  stays composefs for `bootc upgrade/switch`, and `ostree admin` and today's `bopp-kargs` don't apply to it (kargs
  live in the BLS entries).
- The image also sets `ENV SOURCE_DATE_EPOCH=""` at the end of `Containerfile.base`, which makes `mkfs.fat` fail inside
  `bootc install`. The probe unsets it; the image should switch to `ARG SOURCE_DATE_EPOCH=0`.
- Fallback if composefs fails: `--bootloader none` on ostree, then `bootctl install` and BLS entries generated from
  ostree's `/boot/loader/entries`, maintained by us on every upgrade.

Keep-home on composefs works differently from section 4b (read from source, not yet run):
- Layout: shared `/var` at `state/os/default/var`, per-deployment `/etc` at `state/deploy/<id>/etc`, where `<id>` is
  the image's composefs digest (`composefs_consts.rs` 7-19).
- Install creates the shared `/var` with `create_dir_all` and copies the image's `/var` over it with
  `cp -a --remove-destination` (`bootc_composefs/state.rs` 254-280, 138-147). `/var/home` should survive.
- There is no 3-way `/etc` merge: the new deployment gets the image's pristine `/etc` (`state.rs` 149-155). Users,
  passwords and NetworkManager connections are lost unless the installer copies them over.
- Reinstalling the *same* image reuses `state/deploy/<id>` and then creates its `var` symlink again; that likely
  fails with "File exists". The installer may have to remove the old `state/deploy/<id>` first (keeping
  `state/os/default/var`).

Probe results on the host (2026-10-27, `cachyos-plasma:znver4`, bootc 1.16.10, loopback disk, no QEMU boot yet):
- Preflight: `--composefs-backend` and `--allow-missing-verity` exist; `systemd-bootx64.efi`, `initramfs-setup` and
  `bootc-root-setup.service` (in the initramfs) are present.
- `install to-disk --composefs-backend --bootloader systemd` **succeeds**: GPT with 1M BIOS boot, 1G ESP, btrfs DPS
  root. ESP holds `EFI/systemd`, `EFI/BOOT/BOOTX64.EFI`, `EFI/Linux/bootc_composefs-<id>/` (kernel + initramfs),
  `loader/loader.conf`, `loader/entries/bootc_arch-<id>-1.conf`. No XBOOTLDR partition.
- `to-filesystem --replace=alongside` with the same image **fails** as predicted: `Writing composefs state: Failed to
  create symlink for /var: File exists`. It fails *after* wiping the ESP's `EFI/` and reinstalling systemd-boot, so
  `EFI/Microsoft` is gone even though the install failed. The old deployment stays bootable from the rewritten ESP.
- Retry after moving `state/deploy/<id>` aside (keeping `state/os/default/var`): reinstall **succeeds**.
  `/var/home` is **kept**; the old deployment's `/etc` change is **not** carried over (no merge on composefs);
  the moved-aside old deployment stays on disk.
- `loader.conf` has `timeout` commented out, so the systemd-boot menu is hidden unless Space is held.
- The BLS entry is titled "Arch Linux" (file `bootc_arch-<id>-1.conf`): bootc takes it from the image's os-release.
  Its options are `root=UUID=… rootflags=subvol=/ rw composefs=<id>` plus the `--karg`s and the image's own kargs
  (`mitigations=off`, `amd_pstate=active`, `rd.luks.options=tpm2-device=auto`, …).
- Boot of the reinstalled disk in QEMU (virt-manager flatpak, edk2 firmware, `-cpu host`): UEFI → systemd-boot →
  kernel → dracut initramfs → `bootc setup root` → switch root → systemd in the real root → **`cachyos login:` on
  ttyS0** (within 240 s). Without `-cpu host`, systemd dies with SIGILL
  in the initramfs: znver4 images need a Zen 4 CPU, so test VMs and the installer's CPU check must match.
- `dracut-crypt-generator` fails (exit 2) in the initramfs on an unencrypted root, likely from the image's
  `rd.luks.options=tpm2-device=auto` karg. Boot continues.
- **Open:** during that boot the kernel logs `fs-verity (sda3, inode 88485/68745): FILE CORRUPTED!` for several
  4 KiB blocks. Every `real_hash` is the SHA-512 of a zero block, so those blocks read back as zeros. Not yet known
  whether the data is missing on disk (e.g. bootc's `fstrim` through the loop device, or the same-image reinstall
  reusing the object store) or only in the VM. `bootloader-probe.sh verify` checks the disk on the host.
  Result: on the host all 233,538 composefs objects (including inodes 88485 and 68745) read back with valid
  fs-verity, so the data on disk is intact; the zeros come from the guest's read path (scattered/mmap reads vs. the
  host's sequential read). Cold single-block reads at the guest's failing offsets on the host return the guest's
  expected hashes, and the file is not compressed (heavily fragmented, though). So the host kernel reads the data
  correctly; the zeros arise between the image file and the guest kernel (QEMU's IDE emulation, guest memory
  pressure at 4 GiB, or a guest-side kernel path). Booting with virtio instead of IDE, or with 8 GiB, still logs
  10 errors, so neither the emulated disk nor memory is the cause. Remaining suspect: the guest reads composefs
  objects through mmap page faults (fault-around/readahead), while the host checks used `read()`. A kernel bug in
  btrfs fs-verity on that path, possibly with this file's fragmented 1-block extents, would explain it. A cold mmap
  read on the host also returns the correct data, so the host cannot reproduce it by any read path tried; it only
  happens inside the running guest. `btrfs check --readonly` on the image finds no errors. The files: inode 88485
  is a 96 MB PIE executable (the errors follow "Started Cloudflare Zero Trust Client Daemon", so likely
  `warp-svc`; unconfirmed), inode 68745 is a zstd-compressed file (likely a kernel module or firmware).
  The fisherman-installed disk (fresh `to-filesystem` install, no reinstall) shows the same pattern: 20 errors in
  3 files (inodes 108937, 147365, 89566), scattered 4 KiB blocks, boot still reaches login. So it is not caused by
  the probe's `to-disk` + reinstall path.
  **Status: parked as a VM-only finding.** The installed data is intact and boot reaches login. Before shipping,
  re-test on real hardware (check `journalctl -k | grep 'FILE CORRUPTED'` after first boot); if it shows there,
  reproduce inside the guest by reading those objects from `/sysroot/composefs/objects` and report to btrfs/fs-verity
  upstream. `--allow-missing-verity` would hide it, not fix it.
- Not yet tested: a reinstall with a *different* image digest (no collision, but the old `state/deploy/<oldid>`
  would be left with no boot entry).

Installer steps for a composefs reinstall that keeps home, from these results:
1. Copy every `EFI/<vendor>` except `systemd`, `BOOT`, `Linux` off the ESP; put them back after bootc.
2. Copy the `/etc` files to keep (`passwd`, `shadow`, `group`, `gshadow`, `subuid`/`subgid`,
   `NetworkManager/system-connections`, `hostname`, `locale.conf`, `vconsole.conf`) from the old
   `state/deploy/<oldid>/etc`.
3. Move every old `state/deploy/<id>` aside, then run `to-filesystem --replace=alongside --composefs-backend
   --bootloader systemd`.
4. Merge the saved `/etc` files into the new `state/deploy/<newid>/etc`, then delete the old deployment dirs.
5. Write `timeout 3` into `loader/loader.conf` so the rollback entry is visible.

## 4b. Reinstalling over an old bootc system and keeping home

Read from bootc source, `main` @ `d3b33bc` (2026-10-27, after v1.17.2). Line numbers are in
`crates/lib/src/install.rs` unless noted; `deploy.rs` is `crates/ostree-ext/src/container/deploy.rs`. Nothing was run.

How `--replace=alongside` works:
- `install to-existing-root` is `install to-filesystem --replace=alongside --skip-finalize` on the host `/` bind-mounted
  at `/target` (2999-3045). From our live installer we call `to-filesystem --replace=alongside` on the mounted old root.
- Only boot content is deleted (2832-2843, 2562-2637): everything in `/boot` (the `loader*` dirs survive only when the
  target is a *booted* ostree deployment, detected via `<root>/sysroot/ostree` at 2782-2790; not our case), and the
  **whole `EFI/` and `loader/` dirs on the ESP**. A TODO there says other OSes' `EFI/<vendor>` are not kept yet.
  `--replace=wipe` instead empties the whole filesystem.
- An existing `ostree/repo` is reused ("Reusing extant ostree layout", 1024-1037).
- Stateroot defaults to `default` (808-819). bootc refuses only if it equals the *booted* stateroot (1103-1107). An
  existing stateroot dir is reused (1111-1120). From live media nothing is booted, so reusing the old one is allowed.
- Deploy passes the old stateroot's latest deployment as merge deployment (`deploy.rs` 79, 120-139). Effects:
  `/var` of that stateroot is shared, so `/var/home`, Flatpaks and container storage carry over; and ostree's
  3-way `/etc` merge copies every `/etc` file the old OS changed (`passwd`, `shadow`, `group`, NetworkManager
  connections, `fstab`) over the new image's `/etc`.
- Cleanup of old deployments is skipped when the repo existed (`no_clean`, 1328): old OS files stay until
  `ostree admin cleanup`.
- `--cleanup` only enables Fedora's `bootc-destructive-cleanup` script (`rpm -e` on `/sysroot`, `podman system prune`);
  useless for BoppOS.

Installer plan, two modes:
1. **Same stateroot** (BoppOS to BoppOS reinstall, e.g. to repair the bootloader): read the name from
   `/ostree/deploy/*`, pass `--stateroot <name>`. Home, users and passwords come along with no copying.
2. **New stateroot** (from Fedora-based Bazzite/Bluefin): the `/etc` merge would copy Fedora's `passwd`/`group` over
   Arch's, which is untested and risky. Instead install into a new stateroot, move `<old>/var/home` into the new
   `/var` (same filesystem, a rename), recreate users with the same UID/GID, and reuse `bopp-migrate` for selected `/etc`.

Must-fix in either mode: before calling bootc, copy every `EFI/<vendor>` other than BoppOS's own (e.g. `EFI/Microsoft`)
off the ESP and put it back afterwards, or Windows on a shared ESP stops booting. Then run `ostree admin cleanup`
to drop the old deployment.

`tests/bootloader-probe.sh keep-home` tests mode 1 and the ESP behavior on a loopback disk.

## 4c. Memory budget: 4 GB floor, use more when present

Decided 2026-10-27. 4 GB is the floor every step must work at; above it the installer uses spare memory for speed,
never for correctness. "Usable" means `MemAvailable` when the installer starts, which already excludes the iGPU
reservation.

Using more when present (each step falls back to the floor behavior, and is decided at runtime, not at build time):
- **Automatic, nothing to do:** the kernel keeps downloaded layers and the OCI export in the page cache, so with
  more RAM bootc's re-reads come from memory instead of the disk.
- **≥ 8 GB usable: run the live system from RAM** (copy the ~1.5 GB squashfs at boot). The UI gets faster and the
  USB stick can be pulled once the installer is up. archiso's `copytoram` decides this before userspace starts, so
  this needs a boot hook that checks free memory against our threshold (archiso's own `auto` rule: to verify).
- **≥ 8 GB usable: no zram swap**, since nothing needs it; below that, zram on.
- **≥ 24 GB usable: scratch (`oci-cache`, ~8 GB of compressed layers) on tmpfs** instead of the target disk. Saves
  about 8 GB of writes and reads on the target. Small gain on NVMe, more on SATA/eMMC. Optional; a change in
  fisherman's `prepareScratchDir`.
- Not worth it: more parallel layer downloads (network-bound, not memory-bound), or holding the pulled image
  in RAM (the pull is ~2x the compressed size unpacked).

The floor rules: Handhelds with 16 GB on paper can leave the OS about 8 GB once the firmware reserves memory
for the iGPU (e.g. ROG Ally with an 8 GB reservation); older 8 GB models leave less. The installer targets **4 GB
usable** for margin. A live ISO runs from RAM and the BoppOS image is ~8 GB compressed, so:

1. **No image data in RAM** (below the 24 GB tier above). Pull, OCI export and bootc's temporary files all go on the target disk. fisherman
   already does this on a live system: when `/var` is tmpfs or overlay it puts its scratch dir at
   `<target>/.fisherman-scratch` (`cmd/fisherman/main.go` `prepareScratchDir`), which holds the composefs OCI export
   (`oci-cache`), and its tests show the pull as `podman --root <scratch>/root pull`. To verify in the 4 GB test.
2. **Partition and mount the target before downloading anything.** The download can only start once the disk exists.
3. **Live system stays small:** squashfs ≤ ~1.5 GB, read from the boot medium below 8 GB usable (copied to RAM
   only at the 8 GB tier above), zram swap enabled, `/tmp` capped.
4. **Installer UI is light:** cage + one GTK4 app, no desktop, no browser, no Flatpak runtime.
5. **Test:** the CI/QEMU smoke test boots the ISO with `-m 4096` and runs a full `--autoinstall` install; the
   install fails the test if the kernel's OOM killer fires or peak memory (from `/proc/pressure/memory` and
   `MemAvailable`) leaves under ~300 MB. A second run at `-m 32768` covers the RAM tiers (squashfs copied to RAM,
   no zram, scratch on tmpfs) and must install the same result.
6. **Target system, not just the installer:** the first boot of the installed system should also be checked at
   4 GB (the probe's `boot` mode already uses `BOOT_MEM=4096` by default; that boot reached login).

## 5. Repo layout

Three repos under `bopp-os`:
- `bopp-os/bootc-installer`: fork of tuna-os/bootc-installer. BoppOS changes on a `boppos` branch rebased on upstream:
  branding, dark-mode default, CPU-level tag picker, flavors, hardware-presets page, first-run handoff.
- `bopp-os/fisherman`: fork of tuna-os/fisherman (the installer's submodule points here). Keep-home reinstall,
  ESP vendor backup/restore, in-place `cryptsetup reencrypt`, `/etc` account merge.
- `bopp-os/boppos-installer` (this repo): the ISO and everything around the installer.
- `bopp-os/pkgbuilds`: `packages/boppos-bootc-installer` packages both forks (see section 3). Published
  2026-10-28 (bopp-os/pkgbuilds#41): `boppos-bootc-installer 3.0.0-1` (any) and `boppos-fisherman 3.0.0-1` (x86_64)
  in the signed `[bopp-os]` repo at `repo.ripps.me`.

```
boppos-installer/
  README.md
  docs/design.md              this file
  image/                      archiso profile: packages.x86_64, airootfs/, bootloader configs; builds the fork natively
  recipes/                    default fisherman recipes (BoppOS defaults; unattended CI install)
  flavors.json                flavor list served to the installer (or published from the image repo)
  tests/
    bootloader-probe.sh       sections 4, 4a, 4b: install, keep-home, boot and verify probes
  .github/workflows/          build ISO + QEMU smoke test with an --autoinstall recipe (later)
```

Only `docs/` and `tests/bootloader-probe.sh` exist now. Nothing from this work goes into boppos-tools; the installer
only reads its `hwprofiles` data.

## 6. Handoff to the first-run wizard

The installer writes the user's choices to the deployed system, then reboots:
1. `answers.json` copied to `<deploy>/var/lib/boppos/install-answers.json` (flavor, hw-opts chosen, locale, Wi-Fi profile
   if wanted). `/var` is the stateroot's persistent part, so it survives updates.
2. **User account.** Installer asks for it; fisherman's `internal/post/user.go` already creates it for the composefs
   layout (`useradd` into the deployment's `/etc`, first-boot tmpfiles create `/var/home/<user>`). Hashed password only.
   On a keep-home reinstall the account comes from the merged old `/etc` instead (section 4a).
3. Marker `/var/lib/boppos/first-run` with `mode=welcome` if a user was created, or `mode=oobe` (no user, e.g. bare
   `bootc install to-disk`, which creates none). A unit/autostart with
   `ConditionPathExists=/var/lib/boppos/first-run` starts `boppos-deck --welcome` or `--oobe`, then removes the marker.
4. Installer's "basic hardware optimizations" step only chooses presets; it passes the resulting kargs through
   `bootc install --karg`, and records the chosen preset names so the wizard shows them as already on. Source of truth stays in boppos-tools
   (`hwprofiles`, `kargs.d/*.conf`); the installer image ships `boppos-tools` and imports it.
5. The wizard stays dry-run per the boppos-tools decision until a deckify image exists. "Deckify" is a disabled
   entry in `flavors.json` until then.

## 7. Open decisions for the maintainer

Decided 2026-10-27: fork tuna-os/bootc-installer (E); composefs + systemd-boot (4a); dark mode default with a light
toggle; keep-home reinstall; optional in-place LUKS2 of the kept root (btrfs/ext4); image tag picked from the CPU.

Still open:
1. Create `bopp-os/boppos-installer` on GitHub (local repo exists, no remote yet). The forks
   `bopp-os/bootc-installer` and `bopp-os/fisherman` exist since 2026-10-27 (upstream default branch `dev`;
   Issues and Actions off until enabled). Next on the fork: a `boppos` branch whose `.gitmodules` points at
   `bopp-os/fisherman`.
2. Image repo fixes: `ARG SOURCE_DATE_EPOCH=0` instead of the trailing `ENV SOURCE_DATE_EPOCH=""`; os-release name so
   the boot entry says BoppOS instead of "Arch Linux"; a `loader.conf` timeout.
3. Installer environment: archiso (recommended) vs bootc-image based.
4. v1 scope: whole-disk erase plus keep-home reinstall, or also "install into an existing partition"?
5. Re-test the fs-verity errors (section 4a) on real hardware before release.
