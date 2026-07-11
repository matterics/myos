#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-uefi}"
iso="$(find "$root/out" -maxdepth 1 -type f -name 'myos-*.iso' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"

if [[ -z "$iso" ]]; then
  echo "No MyOS ISO found; run make iso first" >&2
  exit 1
fi

args=(
  -m 4096
  -smp 4
  -device virtio-vga
  -device virtio-net-pci,netdev=n0
  -netdev user,id=n0
  -serial stdio
  -cdrom "$iso"
)

if [[ "$mode" == "uefi" ]]; then
  ovmf="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
  [[ -f "$ovmf" ]] || { echo "OVMF firmware not found: $ovmf" >&2; exit 1; }
  args=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf" "${args[@]}")
fi

exec qemu-system-x86_64 "${args[@]}"

