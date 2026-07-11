# MyOS — Bootloader Guide (power-on → kernel)

> **Goal:** everything needed to get from firmware to the Linux kernel on every MyOS target,
> with branded splash, A/B update slots, automatic rollback, and (optionally) Secure Boot.
> Implementation lives in `os/` (partition layout, loader configs) and is consumed by the
> ISO build (doc 04) and the updater.

---

## 1. Mental model of boot

```
Power on
 → Firmware (UEFI on modern PCs/VMs; legacy BIOS on old PCs; U-Boot/vendor loader on ARM)
 → Bootloader (systemd-boot / GRUB / U-Boot+extlinux)
 → Linux kernel + initramfs (early userspace: find & unlock root, mount, splash)
 → pivot to real root → systemd (PID 1) → MyOS session
```

Two distinct worlds we must support on x86:

| | UEFI (primary) | Legacy BIOS (fallback) |
|---|---|---|
| Firmware reads | FAT32 **EFI System Partition (ESP)**, runs `\EFI\BOOT\BOOTX64.EFI` | first 440 bytes of disk (MBR) → stage1.5 → stage2 |
| Our loader | **systemd-boot** | **GRUB** (i386-pc target) |
| Partition table | GPT | GPT with BIOS-boot partition (or MBR) |
| VMware | default for new VMs (`firmware = "efi"`) | select "BIOS" in VM settings |
| QEMU | needs OVMF: `-drive if=pflash,...OVMF_CODE.fd` | default |

**Decision: systemd-boot for installed systems (UEFI), GRUB only on the live ISO** (because the ISO must boot on both UEFI *and* BIOS machines — archiso wires this up for us, see doc 04). Do not maintain two loaders on installed systems; refuse legacy-BIOS *installs* in v1 (still bootable live for demo). This halves the boot maintenance surface.

---

## 2. Disk layout (installed system)

GPT, designed around **A/B image updates** (doc 04 §7 depends on this exact layout):

```
GPT disk
├── p1  ESP         1 GiB   FAT32   /efi            (loader + kernels for BOTH slots)
├── p2  root-A     12 GiB   erofs/squashfs or ext4  (slot A — read-only system image)
├── p3  root-B     12 GiB   (slot B — empty until first update)
├── p4  var         4 GiB   ext4    /var            (logs, models cache, flatpaks)
└── p5  home       rest     ext4 (LUKS2)  /home     (user data, vault)
```

- System slots are **read-only images** (squashfs in v1 — archiso already produces one; erofs later). `/etc` is writable via overlayfs (`/var/lib/myos/etc-overlay`). This is what makes updates atomic and rollback trivial.
- Partition type GUIDs: use the [Discoverable Partitions Spec] GUIDs so systemd-gpt-auto can find root without fstab (`4f68bce3-...` for root x86-64, etc.). Label slots `myos-root-a` / `myos-root-b`.
- LUKS2 on `/home` only in v1 (system image has no secrets). TPM2 enrollment: `systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/myos-home`.
- **Simplification for M0–M2:** a plain single ext4 root is fine while bootstrapping; move to A/B at M3 (installer) since the installer creates the layout. Don't retrofit later than that.

---

## 3. systemd-boot setup (installed system)

Install once from the installer: `bootctl install --esp-path=/efi` (copies `systemd-bootx64.efi` to `\EFI\systemd\` and `\EFI\BOOT\BOOTX64.EFI`).

### 3.1 Loader config — `/efi/loader/loader.conf`

```ini
default  myos-a.conf
timeout  0          # boot instantly; hold SPACE to show menu
console-mode max
editor   no         # SECURITY: never allow cmdline editing in the field
```

`timeout 0` + `editor no` = appliance feel. Menu still reachable (hold Space) for recovery.

### 3.2 Boot entries — one per slot

`/efi/loader/entries/myos-a.conf`:

```ini
title    MyOS (slot A)
sort-key 10
linux    /myos/a/vmlinuz
initrd   /myos/a/intel-ucode.img     # or amd-ucode.img; ship both, loader skips missing
initrd   /myos/a/initramfs.img
options  root=PARTLABEL=myos-root-a rootflags=ro quiet splash \
         plymouth.ignore-serial-consoles loglevel=3 rd.udev.log_level=3 \
         myos.slot=a
```

`myos-b.conf` identical with `a→b`. Kernels live *on the ESP* (`/efi/myos/<slot>/`) because systemd-boot can only read the ESP — the updater copies the new kernel there when writing a slot.

### 3.3 Boot counting + automatic rollback (free with systemd-boot)

This is why we chose systemd-boot. Enable **boot-assessment**:

1. Updater names the new entry `myos-b+3.conf` (3 tries remaining).
2. Each failed boot, systemd-boot renames `+3` → `+2-1` → `+1-2`; after `+0-3` the entry is *bad* and the loader falls back to the other slot automatically.
3. A successful boot (reaching `boot-complete.target`) runs `systemd-bless-boot.service`, which renames the entry to plain "good".

Wire-up in the image:
```
systemctl enable systemd-boot-update.service   # keeps loader binary fresh
systemctl enable systemd-bless-boot.service
# Make "boot succeeded" mean "MyOS shell actually started":
#   /usr/lib/systemd/system/myos-shell-ready.service  (Type=oneshot, started by the
#   shell over sd_notify when the chat bar renders)  WantedBy=boot-complete.target
```

**Definition of a good boot for MyOS = the shell rendered.** Not "kernel didn't panic." This catches broken GPU/Flutter updates, not just kernel bugs.

### 3.4 Unified Kernel Images (UKI) — adopt at M6

Instead of separate kernel/initrd/cmdline: one signed `.efi` blob built by `ukify` (kernel + initrd + cmdline + splash bitmap stitched into a PE binary). Benefits: single file to sign for Secure Boot, cmdline can't be tampered with, measured boot (TPM PCR 11) works out of the box. Entries become type-2 (drop the `.efi` in `/efi/EFI/Linux/myos-a+3.efi`, no `.conf` needed — systemd-boot auto-discovers, boot counting via the same `+N` filename convention). Do simple entries first; switch to UKIs when signing lands.

---

## 4. Initramfs

Use **mkinitcpio** (Arch native; dracut is the alternative if we move to mkosi later).

`os/rootfs-overlay/etc/mkinitcpio.conf.d/myos.conf`:

```ini
MODULES=(simpledrm)             # earliest possible display for splash
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole
       block plymouth filesystems fsck)
COMPRESSION=zstd
```

Notes:
- `systemd` hook (not `udev`) — we want systemd-in-initrd: it handles `root=PARTLABEL=`, TPM unlock, and boot counting semantics consistently.
- `kms` pulls in the right GPU driver (i915/amdgpu/nouveau/**vmwgfx for VMware**/virtio-gpu for QEMU) so Plymouth gets a framebuffer *before* root mounts. Without vmwgfx/virtio entries the VM boots to a black screen until late — test this specifically.
- Keep the initramfs generic (`autodetect` off for the *shipped image*: build with `mkinitcpio -k <kver> -g ... --no-autodetect`… in practice: remove `autodetect` from the image build so one initramfs boots all hardware; the installer may rebuild with autodetect for speed on the installed machine).
- LUKS: add `sd-encrypt` hook after `block` once encrypted /home auto-unlock is in (it's /home not root, so actually handled post-initrd by `systemd-cryptsetup` — hook only needed if we later encrypt root).

---

## 5. Boot splash (Plymouth)

Brand from the first frame. Theme lives in `os/branding/plymouth/myos/`:

```
myos.plymouth            # theme descriptor
myos.script              # logo fade-in, progress spinner, password prompt styling
logo.png, spinner/*.png
```

- Install theme, set `plymouth-set-default-theme myos`, ensure `plymouth` hook in initramfs (above) and `splash` on cmdline (already in entries).
- Handoff: greetd/cage must start fast enough that Plymouth → shell transition is seamless; run `plymouth deactivate` from a greetd pre-start hook and `plymouth quit --retain-splash` so the last splash frame stays until the shell's first frame (no flash of console).
- Kernel is `quiet loglevel=3`; also set `vt.global_cursor_default=0` to kill the blinking cursor flash.

---

## 6. Secure Boot (ship at M6+, design now)

Two viable paths:

| Path | How | Trade-off |
|---|---|---|
| **shim + MOK** | Use Fedora's signed `shim`, enroll MyOS's MOK cert on first boot (one-time blue MokManager screen), shim loads our signed systemd-boot/UKI | Works on all Secure-Boot PCs without touching firmware; ugly first-boot enrollment step |
| **Custom keys (sbctl)** | Enroll our own PK/KEK/db keys into firmware (needs setup-mode) | Clean, full control; impossible on some locked firmware; wipes vendor keys (careful with OPROMs) |

**Decision: shim + MOK for shipped ISOs; sbctl documented for enthusiasts.** Signing flow (in CI, doc 04 §8): sign UKI with `sbsign --key MOK.key --cert MOK.crt`; the same key signs both slots' UKIs. Private key in CI secrets/HSM, never in repo.

With UKIs + measured boot, later: seal the /home LUKS key to PCR 11 so disk auto-unlocks only under a signed MyOS.

---

## 7. Live ISO boot (differs from installed boot)

The ISO (doc 04) uses archiso's stack — know what it gives us:

- **UEFI:** systemd-boot on the ISO's ESP (El Torito + hybrid GPT so the same `.iso` file works burned to DVD, dd'd to USB, or attached to a VM).
- **BIOS:** syslinux/GRUB path, archiso wires it.
- Root is a **squashfs** loop-mounted with a tmpfs overlay (`archiso` hooks in initramfs handle `archisobasedir`/`archisolabel` cmdline args).
- Add `copytoram` menu entry ("MyOS (load to RAM)") — frees the USB stick, much faster on slow media.
- The live session boots straight into the shell in **live/demo mode** (no persistence) with an "Install MyOS" button → runs `installer/`.

---

## 8. ARM64 targets (M7 — Raspberry Pi / TV boxes)

No UEFI on most ARM boards; each has a vendor boot ROM. Two strategies:

1. **Raspberry Pi 5 (first ARM target):** Pi firmware reads FAT partition → loads `kernel8.img` or, better, **U-Boot** → U-Boot reads `extlinux/extlinux.conf` (syslinux-style, supports our A/B via two labeled entries + `bootcount` env for rollback). Config template in `os/kernel/rpi/`.
2. **Generic ARM SBCs / TV boxes:** U-Boot with UEFI emulation (`u-boot` provides EFI runtime) → then **the exact same systemd-boot flow as x86**. Prefer this wherever U-Boot mainline supports the board — one boot stack everywhere.

Device trees: ship `.dtb`s per board in `/efi/dtbs/<vendor>/`, referenced by `devicetree` line in the boot entry (systemd-boot supports it) or extlinux `FDT` line.

Android-bootloader phones (M8): totally different world — `fastboot flash boot boot.img` with kernel+initramfs packed in Android boot image format (`mkbootimg`), vendor kernel likely required. Isolate all of this in `os/kernel/phone-<model>/`; do not let it complicate the main path.

---

## 9. VM quirks cheat-sheet (you will hit these)

| Symptom | Cause | Fix |
|---|---|---|
| VMware black screen until login | vmwgfx not in initramfs | `kms` hook + `MODULES=(vmwgfx)` for VMware image |
| QEMU boots BIOS mode unexpectedly | no OVMF | `make run-qemu` must pass `-drive if=pflash,readonly=on,file=OVMF_CODE.fd` |
| VMware won't boot ISO in EFI | VM created as BIOS | `.vmx`: `firmware = "efi"` (our `make run-vmware` writes this) |
| ISO boots but installed system doesn't | forgot `bootctl install` or ESP not mounted at /efi | installer must verify `bootctl status` post-install |
| "Secure Boot violation" in VMware EFI | VMware SB enabled, unsigned loader | disable SB in VM settings until M6 signing lands |

---

## 10. Acceptance checklist (bootloader done when…)

- [ ] `make iso` output boots on: QEMU+OVMF, QEMU BIOS, VMware EFI, one real laptop via USB.
- [ ] Installed system: power-on → Plymouth logo <3 s → shell <20 s, zero console text visible.
- [ ] Hold-Space shows menu with slot A/B + a recovery entry (`systemd.unit=rescue.target` variant).
- [ ] Simulated bad update (slot B with broken shell) auto-falls-back to A after 3 tries, and Settings shows "update rolled back".
- [ ] `editor no` verified: cannot edit cmdline from menu.
- [ ] Same disk moved between VMware and QEMU still boots (generic initramfs proof).
