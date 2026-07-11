#!/usr/bin/env bash
set -euo pipefail

missing=0

check() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf '%-18s %s\n' "$name" "ok"
  else
    printf '%-18s %s\n' "$name" "missing"
    missing=1
  fi
}

check git
check make
if command -v podman >/dev/null 2>&1; then
  engine=podman
elif command -v docker >/dev/null 2>&1; then
  engine=docker
else
  engine=""
  printf '%-18s %s\n' "container engine" "missing (Podman or Docker required)"
  missing=1
fi

if [[ -n "$engine" ]]; then
  printf '%-18s %s\n' "container engine" "$engine"
  if "$engine" info >/dev/null 2>&1; then
    printf '%-18s %s\n' "engine daemon" "ok"
  else
    printf '%-18s %s\n' "engine daemon" "not running"
    missing=1
  fi
fi

if (( missing )); then
  echo
  echo "MyOS source is ready, but the full build toolchain is not yet available."
  exit 1
fi

