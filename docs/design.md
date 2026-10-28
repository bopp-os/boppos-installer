# BoppOS net-installer: design and options

Status: **proposal, nothing built.** Written 2026-10-27. Decision needed from the maintainer: section 6.

Goal: a bootable installer image in the style of SteamOS Recovery (not a live-USB demo). The user boots it and picks
target drive, user account, desktop flavor (or "deckify" Gaming Mode), Wi-Fi/Ethernet, and basic hardware optimizations.
It then downloads the BoppOS bootc image and installs it. It hands off to the `boppos-deck --welcome` / `--oobe` wizard.

## 1. Facts that constrain the choice

| Fact | Source | Consequence |
|---|---|---|
| BoppOS is Arch/CachyOS, built from `Containerfile.base` + flavor Containerfiles. | `~/Projects/boppos/cachyos` | Anything RPM-native (Anaconda) runs on a different OS than the payload. |
| The image installs `bootc`, `ostree`, `dracut`, `btrfs-progs`, `e2fsprogs`, `dosfstools`. It installs **no** GRUB, `bootupd`, `shim`, `efibootmgr`. | `files/base/base.yaml` (grep for grub/bootupd: no hits) | `bootc install` has no bootloader tooling to call from inside the image today. **This is the open question; see section 4.** |
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

### C. Minimal custom installer around `bootc install` (recommended)

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

### Summary

| | A Anaconda | B Calamares | **C custom** | D bib |
|---|---|---|---|---|
| Fits Arch payload | poor | ok | **good** | poor |
| Effort to first working install | high | medium | **low-medium** | n/a |
| Own the UX (flavor, deckify, Wi-Fi, hw-opts) | deep patching | modules in C++/Python | **direct** | no |
| Solves bootloader question | no | no | no | no |
| Maintenance | Fedora toolchain | Qt + Calamares upgrades | our code only | Fedora tool |

Recommendation: **C**, with B's idea of a thin Python job layer, and the option to swap the GTK front end for a Qt/web one later,
because the backend does not depend on it.

## 3. How the installer image is built and booted

Two sub-questions: what the installer environment is, and how it boots.

Environment (recommended): an **archiso-style (or CachyOS live-profile) minimal image**, UEFI only first, with
`bootc`, `ostree`, `skopeo`/`podman` not needed (bootc pulls the image itself), `NetworkManager` (+ `iwd` for Wi-Fi),
`cage` (kiosk Wayland compositor) autostarting the installer, `boppos-tools` (for `hwprofiles` and artwork), `btrfs-progs`,
`dosfstools`, `cryptsetup`, `sfdisk`, firmware, and a minimal GPU stack. Boots straight into the wizard like SteamOS Recovery; no
desktop, no shell unless the user presses a hidden key (tty2). Building needs `mkarchiso`, which needs root and loop
devices, so it runs in **CI** (GitHub Actions) or on the host, not in the Litterbox.

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

## 4. The bootloader question (read this one first)

Today, `bootc install` on this image **cannot be assumed to work end to end**:
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
  happens inside the running guest. Next: `btrfs check --readonly` on the image (free-space records that wrongly
  mark these blocks free would let the guest reuse them) and identifying the two files.
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

## 5. Repo layout (`bopp-os/boppos-installer`)

```
boppos-installer/
  README.md
  docs/design.md              this file
  installer/                  python package `boppos_installer`
    plan.py                   disk probe + install plan (pure, unit-testable)
    run.py                    executes the plan: sfdisk/mkfs/bootc/useradd/marker
    answers.py                answers.json schema (also used for unattended installs)
    net.py                    NetworkManager/iwd wrapper
    hw.py                     calls boppos.hwprofiles -> --karg list
    ui_gtk/                   GTK4/libadwaita wizard (later)
    ui_tui.py                 fallback TUI/CLI (later)
  image/                      archiso profile: packages.x86_64, airootfs/, bootloader configs
  tests/
    bootloader-probe.sh       section 4 and 4b probes
    test_plan.py              unit tests, no root needed
  .github/workflows/          build ISO + QEMU smoke test (later)
```

Only `docs/`, `tests/bootloader-probe.sh` and this layout exist now.

## 6. Handoff to the first-run wizard

The installer writes the user's choices to the deployed system, then reboots:
1. `answers.json` copied to `<deploy>/var/lib/boppos/install-answers.json` (flavor, hw-opts chosen, locale, Wi-Fi profile
   if wanted). `/var` is the stateroot's persistent part, so it survives updates.
2. **User account.** Installer asks for it, so it creates the user itself with `useradd --root <deployment>` (home under `/var/home`),
   hashed password only, never plaintext. Exact ostree path and `/etc` merge behavior need a test (not verified).
3. Marker `/var/lib/boppos/first-run` with `mode=welcome` if a user was created, or `mode=oobe` (no user, e.g. bare
   `bootc install to-disk`, which creates none). A unit/autostart with
   `ConditionPathExists=/var/lib/boppos/first-run` starts `boppos-deck --welcome` or `--oobe`, then removes the marker.
4. Installer's "basic hardware optimizations" step only chooses presets; it passes the resulting kargs through
   `bootc install --karg`, and records the chosen preset names so the wizard shows them as already on. Source of truth stays in boppos-tools
   (`hwprofiles`, `kargs.d/*.conf`); the installer image ships `boppos-tools` and imports it.
5. The wizard stays dry-run per the boppos-tools decision until a deckify image exists. "Deckify" is a disabled
   entry in `flavors.json` until then.

## 7. Open decisions for the maintainer

1. Approve **C (custom installer)**, or insist on **A (Anaconda)** after seeing the costs above.
2. Run the bootloader probe on the host (needs root + podman) and share results; this decides section 4.
3. Installer environment: archiso (recommended) vs bootc-image based.
4. Repo creation on GitHub under `bopp-os` and the name `boppos-installer` (local repo exists, no remote yet).
5. v1 scope: whole-disk erase only, or also "install into an existing partition"?
