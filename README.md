# MyOS

An AI-native operating system. One codebase, every screen — phone, PC, laptop, TV.

The OS **is** the assistant. You install it, name your agent during onboarding, and from then on the home screen is a chat bar. Everything the machine can do, you can ask for — by text or by voice ("Hey `<AgentName>`"). Power users drop to a real terminal with `Ctrl+Shift+T`. Devices running MyOS discover each other and pair: use your phone as a second screen or remote control for your PC, and vice versa. Think JARVIS, shipped as an ISO.

## Stack (decided)

| Layer | Choice | Why |
|---|---|---|
| Kernel | Linux (custom distro) | Only realistic path to phone + PC + laptop + TV with real drivers |
| Shell UI | Flutter (single Dart codebase) | Adaptive layouts per form factor, GPU-rendered, runs on Wayland kiosk |
| Compositor | `cage` (Wayland kiosk) | Boots straight into the shell, no desktop underneath |
| Init | systemd | Services, first-boot onboarding, updates |
| AI | Cloud providers (Anthropic, OpenAI, …) + optional local (llama.cpp) | "Connect provider" on home screen; wake word runs locally |
| First targets | x86_64 — QEMU, VMware, real laptops via USB | Fastest iteration loop |
| Later targets | ARM64 (Raspberry Pi, TV boxes), phones | Same codebase, different image profiles |

## Documentation

Read in order. These docs are written to be handed to an AI coding agent (or a human) as a complete build spec.

| Doc | Covers |
|---|---|
| [docs/00-ARCHITECTURE.md](docs/00-ARCHITECTURE.md) | Vision, system layers, repo layout, device adaptation, security model, roadmap |
| [docs/01-BOOTLOADER.md](docs/01-BOOTLOADER.md) | UEFI/BIOS boot flow, systemd-boot + GRUB, initramfs, boot splash, A/B partitions, Secure Boot, ARM/U-Boot notes |
| [docs/02-IO.md](docs/02-IO.md) | Input (keyboard/mouse/touch/TV remote), display (DRM/KMS/Wayland), audio (PipeWire), mic + wake word, networking, Bluetooth, storage, device pairing + dual-screen protocol |
| [docs/03-OS-CREATION.md](docs/03-OS-CREATION.md) | Building the distro itself: kernel config, userspace, the Flutter shell, agent daemon (`myosd`), provider connectors, voice pipeline, onboarding, terminal, permissions |
| [docs/04-ISO-BUILD-AND-SHIP.md](docs/04-ISO-BUILD-AND-SHIP.md) | archiso profile, installer, testing in QEMU/VMware, USB flashing, signing, versioning, OTA updates, CI/CD release pipeline |
| [docs/05-DEVELOPMENT.md](docs/05-DEVELOPMENT.md) | Current implementation status, Windows build setup, and M0 boot acceptance testing |

## Quick start

```
make iso          # build MyOS ISO (runs archiso in a container)
make run-qemu     # boot the ISO in QEMU with KVM
make run-vmware   # generate a .vmx and boot in VMware
```

On Windows, run these commands inside WSL2 after starting Docker Desktop. See
[`docs/05-DEVELOPMENT.md`](docs/05-DEVELOPMENT.md).

## Status

M0 bootstrap is implemented: the canonical agent API, Rust daemon skeleton, pacman package
pipeline, containerized toolchain, and branded ArchISO profile build successfully. The current
ISO has verified hybrid BIOS and UEFI boot records; runtime boot testing is the next gate.
