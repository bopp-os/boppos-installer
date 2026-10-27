# boppos-installer

Net-installer image for [BoppOS](https://github.com/bopp-os) (SteamOS Recovery style: boot it, pick drive, user,
flavor, network and hardware options, it downloads and installs the bootc image).

Status: design proposal only. Read [docs/design.md](docs/design.md). Nothing is implemented.
Run `sudo tests/bootloader-probe.sh all` (root + podman, on the host or CI) to answer the open bootloader question
and test reinstalling while keeping home (`bootloaders` or `keep-home` runs one of the two).
