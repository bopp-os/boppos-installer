# boppos-installer

Net-installer image for [BoppOS](https://github.com/bopp-os) (SteamOS Recovery style: boot it, pick drive, user,
flavor, network and hardware options, it downloads and installs the bootc image).

Status: **working in a VM** (2026-10-29). The ISO is an archiso profile in `image/` that boots a GUI wizard
(the BoppOS fork of tuna-os/bootc-installer) and installs with fisherman on the ostree backend with grub.
Read [docs/design.md](docs/design.md): section 4d for the bootloader decision, 4e for what testing found, 6 for the first-run handoff.

- Try the installer in a window, with no VM and no disk access: `image/dev.sh run`.
- Build the ISO (root + podman): `sudo image/build.sh`; with locally built packages:
  `image/dev.sh packages && sudo LOCAL_PKGS=$PWD/.dev/pkgs image/build.sh`.
- Probe bootloaders and reinstalling over an old system (root + podman, on the host):
  `sudo tests/bootloader-probe.sh {bootloaders|keep-home|fisherman|ostree-grub|all}`; boot the result with
  `tests/bootloader-probe.sh boot <disk-image>` as your normal user.
