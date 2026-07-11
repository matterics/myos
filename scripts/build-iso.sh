#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$root/scripts/build-packages.sh"
profile="$(bash "$root/scripts/prepare-archiso-profile.sh")"
mkdir -p "$root/out"

mkarchiso -v -r -w /tmp/myos-mkarchiso -o "$root/out" "$profile"
