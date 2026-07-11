#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$root/out/repo"
build_root="$root/work/packages"
artifacts="$root/out/build"

rm -rf "$build_root" "$artifacts"
mkdir -p "$repo" "$build_root" "$artifacts"
chown -R builder:builder "$root/out" "$build_root"

# --- 1. myosd release binary (Rust proto codegen runs in build.rs) ---
echo "==> building myosd (release)"
(cd "$root/daemon" && cargo build --release -p myosd)
install -m755 "$root/daemon/target/release/myosd" "$artifacts/myosd"

# --- 2. Flutter shell bundle ---
echo "==> building myos-shell (flutter linux release)"
chown -R builder:builder "$root/shell" "$root/proto" 2>/dev/null || true
sudo -u builder env HOME=/home/builder \
  PATH="/home/builder/flutter/bin:/home/builder/.pub-cache/bin:$PATH" \
  bash -c "
    set -euo pipefail
    cd '$root/shell'
    bash tool/gen_protos.sh
    if [[ ! -d linux ]]; then
      flutter create --platforms=linux --project-name myos_shell . >/dev/null
    fi
    flutter pub get
    flutter build linux --release
  "
tar -C "$root/shell/build/linux/x64/release" -czf "$artifacts/myos-shell-bundle.tar.gz" bundle

# --- 3. pacman packages ---
for pkgdir in "$root"/packages/*; do
  [[ -f "$pkgdir/PKGBUILD" ]] || continue
  name="$(basename "$pkgdir")"
  cp -a "$pkgdir" "$build_root/$name"
  case "$name" in
    myosd) cp "$artifacts/myosd" "$build_root/$name/" ;;
    myos-shell) cp "$artifacts/myos-shell-bundle.tar.gz" "$build_root/$name/" ;;
  esac
  chown -R builder:builder "$build_root/$name"
  # --nodeps: our packages only copy prebuilt files; runtime deps resolve at
  # ISO assembly time from the official repos.
  sudo -u builder bash -lc "cd '$build_root/$name' && makepkg --nodeps --noconfirm --clean --cleanbuild"
  find "$build_root/$name" -maxdepth 1 -type f -name '*.pkg.tar.zst' -exec cp -f {} "$repo/" \;
done

shopt -s nullglob
packages=("$repo"/*.pkg.tar.zst)
if (( ${#packages[@]} == 0 )); then
  echo "No packages were produced" >&2
  exit 1
fi

repo-add -R "$repo/myos.db.tar.zst" "${packages[@]}"
