#!/usr/bin/env bash
# shellcheck disable=SC2034
# BoppOS installer ISO, derived from archiso's baseline/releng profiles (archiso v91).

iso_name="boppos-installer"
iso_label="BOPPOS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="BoppOS <https://github.com/bopp-os>"
iso_application="BoppOS installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="boppos"
# UEFI only: BoppOS installs systemd-boot, which needs UEFI anyway.
bootmodes=('uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/sudoers.d/10-liveuser"]="0:0:440"
)
