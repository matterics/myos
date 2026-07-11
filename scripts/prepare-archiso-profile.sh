#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$root/work/archiso-profile"
upstream=/usr/share/archiso/configs/releng

if [[ ! -d "$upstream" ]]; then
  echo "archiso releng profile not found at $upstream" >&2
  exit 1
fi

rm -rf "$profile"
mkdir -p "$profile"
cp -a "$upstream/." "$profile/"
cp -a "$root/os/archiso/airootfs/." "$profile/airootfs/"
cp "$root/os/archiso/profiledef.sh" "$profile/profiledef.sh"

cat "$root/os/archiso/packages.extra.x86_64" >>"$profile/packages.x86_64"
sort -u -o "$profile/packages.x86_64" "$profile/packages.x86_64"

# The local package repository must be visible inside mkarchiso's chroot.
awk '
  BEGIN {
    print "[myos]"
    print "SigLevel = Optional TrustAll"
    print "Server = file:///src/out/repo"
    print ""
  }
  { print }
' "$profile/pacman.conf" >"$profile/pacman.conf.new"
mv "$profile/pacman.conf.new" "$profile/pacman.conf"
sed -i '/^\[options\]$/a DisableDownloadTimeout' "$profile/pacman.conf"

# M1 graphical session: boot into greetd -> cage -> myos-shell.
# Drop releng's root TTY autologin (greetd owns tty1 via Conflicts=getty@tty1)
# and its zsh login scripts, which are noise once the GUI owns the console.
rm -rf "$profile/airootfs/etc/systemd/system/getty@tty1.service.d"
rm -f "$profile/airootfs/root/.zlogin" \
  "$profile/airootfs/root/.automated_script.sh"

mkdir -p "$profile/airootfs/etc/systemd/system/graphical.target.wants"
ln -sf /usr/lib/systemd/system/greetd.service \
  "$profile/airootfs/etc/systemd/system/graphical.target.wants/greetd.service"
ln -sf /usr/lib/systemd/system/graphical.target \
  "$profile/airootfs/etc/systemd/system/default.target"

# Preserve upstream-compatible boot files while applying MyOS product labels.
find "$profile/efiboot" "$profile/grub" "$profile/syslinux" -type f \
  \( -name '*.conf' -o -name '*.cfg' \) -print0 |
  xargs -0 sed -i \
    -e 's/Arch Linux install medium/MyOS Live/g' \
    -e 's/Arch Linux/MyOS/g' \
    -e 's/ARCH_/MYOS_/g'

echo "$profile"
