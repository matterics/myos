#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iso="$(find "$root/out" -maxdepth 1 -type f -name 'myos-*.iso' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
vm_dir="$root/out/vm"
vmx="$vm_dir/myos.vmx"

[[ -n "$iso" ]] || { echo "No MyOS ISO found; run make iso first" >&2; exit 1; }
mkdir -p "$vm_dir"

sed "s|@ISO@|$iso|g" "$root/ci/myos.vmx.in" >"$vmx"
echo "Generated $vmx"

if command -v vmrun >/dev/null 2>&1; then
  vmrun start "$vmx"
else
  echo "vmrun is not installed; open the VMX manually in VMware Workstation."
fi

