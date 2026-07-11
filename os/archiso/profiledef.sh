#!/usr/bin/env bash

iso_name="myos"
iso_label="MYOS_$(date +%Y%m)"
iso_publisher="MyOS Project <https://myos.dev>"
iso_application="MyOS Live"
iso_version="$(date +%y.%m.%d)-v3"
install_dir="myos"
buildmodes=('iso')
bootmodes=(
  'bios.syslinux'
  'uefi.systemd-boot'
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19')
bootstrap_tarball_compression=(zstd -c -T0 --auto-threads=logical --long -19)
file_permissions=(
  ["/etc/shadow"]="0:0:0400"
  ["/etc/gshadow"]="0:0:0400"
)
