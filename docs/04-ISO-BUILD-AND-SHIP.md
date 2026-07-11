# MyOS — ISO Build & Shipping Guide (image → installer → updates → releases)

> **Goal:** turn the OS from doc 03 into a bootable, installable, signed, updatable ISO —
> and the pipeline that ships it. Covers the archiso profile, the installer, VM/hardware
> testing (QEMU + **VMware**), USB flashing, versioning, OTA A/B updates, and CI/CD.

---

## 1. Artifact overview

Every release produces:

| Artifact | What | For |
|---|---|---|
| `myos-<ver>-x86_64.iso` | hybrid BIOS+UEFI live ISO with installer | download page, USB, VMs |
| `myos-<ver>-x86_64.img.xz` + `.img.verity` + manifest | raw A/B **system image** (squashfs) | OTA updates (§7) |
| `myos-<ver>-x86_64.ova` (later) | prebuilt VMware/VirtualBox appliance | easiest demo path |
| `repo/` | pacman repository of all myos-* packages | ISO build + `pacman -Syu` on dev boxes |
| `SHA256SUMS` + `SHA256SUMS.sig` | checksums, minisign/PGP signature | verification |

Versioning: **`YY.MM.patch`** (e.g. `26.08.0`) + channel (`dev` → every merge, `beta` → weekly, `stable` → manual promote). Image version lives in `/usr/lib/os-release` (`IMAGE_VERSION=`), which `myos-updated` compares against the update server manifest.

---

## 2. Build environment

Everything builds in an Arch container — works from Windows (your machine) via WSL2+podman, and identically in CI:

```
ci/archlinux-build.Containerfile:
  FROM archlinux:latest
  RUN pacman -Syu --noconfirm archiso base-devel flutter rustup buf grub \
        squashfs-tools erofs-utils mtools dosfstools repo-add-helpers ...
```

`make iso` = `podman run --privileged -v .:/src myos-build mkarchiso -v -w /tmp/work -o /src/out /src/os/archiso`
(`--privileged` needed for loop mounts inside mkarchiso).

---

## 3. The archiso profile (`os/archiso/`)

Start from the upstream `releng` profile, then own it:

```
os/archiso/
├── profiledef.sh           # iso name/label/publisher, squashfs zstd -19, bootmodes
├── packages.x86_64         # exact package list (doc 03 §1) + myos-* pkgs
├── pacman.conf             # adds [myos] repo (file:// during build, https:// in image)
├── airootfs/               # rootfs overlay — becomes / of the live system
│   ├── etc/greetd/config.toml        # boots straight into shell (live/demo mode)
│   ├── etc/myos/live                 # flag file: shell shows "Install MyOS" button
│   ├── etc/systemd/system/...        # enable NetworkManager, myosd, greetd, etc.
│   └── usr/local/bin/...             # live-only helpers
├── efiboot/                # systemd-boot entries for the ISO (UEFI)
└── syslinux/               # BIOS boot menu for the ISO
```

Key edits vs releng:
- `profiledef.sh`: `iso_name="myos"`, `iso_label="MYOS_$ver"`, `bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito' 'uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito')`, `airootfs_image_type="squashfs"` with `-comp zstd -Xcompression-level 19`.
- `packages.x86_64`: strip releng's rescue kitchen sink (keep `gptfdisk e2fsprogs dosfstools cryptsetup` for the installer), add the MyOS set.
- Boot menu entries: default "MyOS Live", plus `copytoram`, plus "MyOS (safe graphics)" (`nomodeset` — old GPUs), plus "Boot existing system".
- Live autologin user `myos` (passwordless, `wheel`), greetd starts cage+shell exactly like an installed system — **the live demo IS the product demo**: chat works immediately if the user connects wifi + provider, no install needed.
- systemd presets in airootfs enable: `NetworkManager iwd bluetooth myosd myos-linkd greetd systemd-resolved nftables`.

Build gotcha list:
- The `[myos]` repo must be built (`make pkgs`) *before* `make iso`; Makefile encodes the dependency.
- Rebuild initramfs inside airootfs with the archiso hooks AND `kms` (doc 01 §4) or VMs black-screen.
- Keep ISO < 2.5 GB: no `-dbg`, strip locales (`NoExtract` in pacman.conf), one CJK font, whisper/piper models **not** on ISO (downloaded at onboarding; ship only wake-word fallback model ~5 MB).

---

## 4. Testing matrix

### 4.1 QEMU (fast loop, CI-able)

```
make run-qemu:
  qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file=out/OVMF_VARS.fd \
    -device virtio-vga-gl -display gtk,gl=on \        # GPU accel for Flutter
    -device virtio-net,netdev=n0 -netdev user,id=n0 \
    -audio driver=pipewire,model=hda \
    -cdrom out/myos-*.iso -drive file=out/disk.qcow2,if=virtio
```

Also test `-machine pc` BIOS variant. Two QEMU VMs on one bridge = mesh/pairing test bed.

### 4.2 VMware Workstation (your setup — closer to real hardware)

`make run-vmware` generates `out/vm/myos.vmx` + a 40 GB vmdk (via `vmware-vdiskmanager` or qemu-img → vmdk) and launches `vmrun start`:

```
firmware = "efi"                      # doc 01 §9
guestOS = "other6xlinux-64"
memsize = "4096"  numvcpus = "4"
mks.enable3d = "TRUE"  svga.graphicsMemoryKB = "1048576"   # Flutter needs 3D
sound.virtualDev = "hdaudio"  usb.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
sata0:1.deviceType = "cdrom-image"  sata0:1.fileName = "myos.iso"
```

Image must contain `open-vm-tools` (+ enable `vmtoolsd.service`) and vmwgfx in initramfs. VMware validates: real EFI implementation quirks, vmwgfx GL path, HD-audio mic (voice testing!), and suspend/resume.

### 4.3 Real hardware smoke set

One modern laptop (USB boot via Ventoy or `dd`/Rufus in dd-mode — **not** Rufus ISO-mode, it breaks the hybrid layout), one old BIOS box (live-only), one mini-PC on a TV via HDMI (CEC + 10-foot layout). Per-release manual checklist: boot, wifi, sound, mic, brightness, sleep, install, reboot, onboard, chat, voice, terminal.

### 4.4 Automated ISO test in CI

Boot the ISO headless in QEMU (`-display none -serial stdio`), cloud-init-style test hook (`myos.autotest=1` cmdline → runs `/usr/local/bin/live-selftest`): asserts greetd started, myosd socket answers `GetDeviceProfile`, shell process alive, then `echo TESTS-PASS > /dev/ttyS0`. Gate every PR on it.

---

## 5. The installer (M3)

Flutter app (`installer/`), launched from the live shell's "Install MyOS" button. Steps:

1. **Disk pick** (list via udisks2; show size/model; "erase entire disk" only in v1 — no dual-boot resizing, say so honestly).
2. **Encryption**: LUKS2 on /home default ON; passphrase or TPM+PIN.
3. **Confirm** (red, typed "ERASE" on real hardware).
4. **Apply** — installer backend (`installer/backend`, Rust, root via polkit):
   - `sgdisk` the A/B GPT layout (doc 01 §2)
   - `mkfs.vfat` ESP; write **system image**: the same squashfs from the ISO is copied as slot A content (dd of prebuilt root image — NOT a file-copy pacstrap; image-based from day one so installs are identical to OTA slots)
   - mount ESP, `bootctl install`, write loader entries for slot A (doc 01 §3)
   - mkfs /var, /home (+LUKS), copy machine-id seed, write `/etc/myos/` firstboot flags
5. Reboot → onboarding (doc 03 §8).

Unattended install for CI/fleets: `myos.install=auto myos.install.disk=/dev/vda` kernel args + TOML answer file on a labeled USB.

---

## 6. Distribution & verification

- Static download site + `torrent` optional. Publish `SHA256SUMS` and sign with **minisign** (key published on site + GitHub). Docs show one-liners for verify on Win/macOS/Linux.
- USB instructions: Ventoy (easiest, ISO as-is), Rufus **dd mode** on Windows, `dd bs=4M oflag=direct status=progress` on Linux/macOS.
- The `.ova` appliance (later): prebuilt installed disk + firstboot reset (`machine-id` cleared, onboarding forced) — the zero-friction "try MyOS in VMware in 2 minutes" path.

---

## 7. OTA updates (M6) — A/B image updates

Uses the slot layout from doc 01 §2 and boot counting from doc 01 §3.3. Tool: **`systemd-sysupdate`** (fits image-based A/B exactly, no custom updater to write).

`/usr/lib/sysupdate.d/50-myos.transfer` (conceptually):

```ini
[Source]  Type=url-file  Path=https://updates.myos.dev/x86_64/
          MatchPattern=myos_@v.root.xz
[Target]  Type=partition Path=auto MatchPartitionType=root MatchPattern=myos_@v
          InstancesMax=2         # ← the A/B: writes the slot NOT currently booted
```
plus a second transfer for the kernel/UKI → ESP `/EFI/Linux/myos_@v+3.efi` (the `+3` arms boot counting; rollback is automatic per doc 01).

Flow: `myos-updated.timer` → `systemd-sysupdate update` → verify (images are signed; verity hash in manifest) → write inactive slot → next reboot boots new slot with 3 tries → `myos-shell-ready` blesses or loader falls back. Shell Settings shows channel picker, "update available" toast (agent can announce it), and a Rollback button (`bootctl set-default` to old slot).

Server side = any static file host (S3/CDN/GitHub Releases): `SHA256SUMS` manifest per channel directory is the entire "update server". CI promotes by copying artifacts between channel dirs.

`/etc` handling: system slots are immutable; machine config lives in the `/etc` overlay (doc 01 §2) and survives updates; schema migrations run via `myos-migrate.service` (versioned scripts, `ConditionNeedsUpdate=/etc`).

---

## 8. Signing chain (M6)

| Thing | Signed with | Verified by |
|---|---|---|
| pacman packages | repo GPG key | pacman on build |
| ISO / SHA256SUMS | minisign release key | user, docs |
| UKI (kernel+initrd+cmdline) | Secure Boot MOK key (doc 01 §6) | shim/firmware |
| OTA root images | verity root hash in signed manifest | systemd-sysupdate + kernel dm-verity (full verity enforcement v2) |

All private keys in CI secret store; release signing behind a manual-approval GitHub environment. Never in repo, never on dev machines.

---

## 9. CI/CD pipeline (GitHub Actions, `ci/`)

```
PR:      lint+test (cargo test, flutter test, policy table tests)
      →  make pkgs  →  make iso  →  QEMU autotest (§4.4)  →  artifact (7-day retention)
main:    same + push repo & ISO to dev channel + tag myos-dev-<date>
weekly:  promote dev→beta (manual approval) — full release job: sign ISO, sysupdate images,
         upload to updates.myos.dev + GitHub Release, publish checksums
stable:  manual promote from beta, changelog from conventional commits
```

Runner needs: nested-KVM Linux runner (or self-hosted box) for the QEMU boot test; plain runners for builds (mkarchiso in privileged podman). Cache: pacman pkg cache + cargo + flutter pub between runs (ISO build drops from ~25 min to ~8 min).

Release checklist automation: job fails if — ISO >2.6 GB, autotest fails, `SHA256SUMS.sig` missing, `IMAGE_VERSION` ≠ tag, or docs/CHANGELOG missing the version.

---

## 10. Acceptance checklist (shipping done when…)

- [ ] `make iso` on a clean clone (WSL2 or CI) produces a booting ISO with zero manual steps.
- [ ] ISO boots: QEMU UEFI, QEMU BIOS, VMware EFI (3D accel on), one real laptop, one TV-attached mini-PC.
- [ ] Live session reaches chat bar with no install; "Install MyOS" completes < 6 min on SSD; reboot lands in onboarding.
- [ ] Fresh install → onboarding → provider connect → "open a terminal and show me disk usage" works, end to end, on VMware.
- [ ] `sha256sum -c` + minisign verify documented and passing on all artifacts.
- [ ] OTA: device on slot A receives 26.08.1, reboots to B; deliberately broken 26.08.2 rolls back to B automatically; Settings shows history.
- [ ] CI produces all §1 artifacts from a tag with one manual approval; no human touches a build machine.
