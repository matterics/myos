#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$(bash "$root/scripts/prepare-archiso-profile.sh")"

test -f "$profile/profiledef.sh"
test -f "$profile/efiboot/loader/loader.conf"
test -f "$profile/syslinux/syslinux.cfg"
grep -qx 'myos-settings' "$profile/packages.x86_64"
grep -q '^\[myos\]$' "$profile/pacman.conf"
grep -Rqs 'MyOS' "$profile/efiboot" "$profile/grub" "$profile/syslinux"

echo 'ARCHISO-PROFILE-OK'
