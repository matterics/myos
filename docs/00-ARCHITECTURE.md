# MyOS — Architecture & Master Plan

> **Audience:** an AI coding agent or engineer implementing MyOS. This is the top-level spec.
> Every other doc (`01`–`04`) hangs off this one. When docs conflict, this one wins.

---

## 1. What MyOS is

MyOS is an **AI-native operating system**. Not "a Linux distro with a chatbot app" — the assistant *is* the shell. There is no desktop, no icon grid as the primary surface. The primary surface is:

1. **A chat bar** — type anything; the agent plans and executes using OS-level tools.
2. **Connect provider** — link Anthropic / OpenAI / Google / local model as the brain.
3. **Provider selector** — pick which connected brain handles requests.
4. **Voice** — say "Hey `<AgentName>`" (name chosen at onboarding) and speak.
5. **Terminal escape hatch** — `Ctrl+Shift+T` (or `Cmd+Shift+T` on Mac keyboards) opens a real shell, always.
6. **Device mesh** — two MyOS devices pair over LAN; phone controls PC, PC extends to phone (dual screen), and vice versa.

One codebase. The same shell binary adapts its layout to phone (portrait, touch), laptop/PC (pointer, keyboard), and TV (10-foot UI, remote/voice).

### Non-goals (v1)

- Running Android or Windows apps.
- Replacing a general-purpose desktop. MyOS is opinionated: chat-first.
- Custom kernel. We use Linux; our value is above the kernel.
- Phone hardware support in v1 (locked bootloaders make this a later, targeted effort — see §9).

---

## 2. System layers

```
┌────────────────────────────────────────────────────────────┐
│  MyOS Shell (Flutter, one codebase)                        │
│  onboarding · chat UI · provider mgmt · settings ·         │
│  terminal (xterm.dart) · pairing UI · adaptive layouts     │
├────────────────────────────────────────────────────────────┤
│  myosd — Agent Daemon (Rust or Go, systemd service)        │
│  agent loop · tool registry · provider connectors ·        │
│  secrets vault · policy/permissions · session store        │
├──────────────┬───────────────────┬─────────────────────────┤
│ myos-voiced  │ myos-linkd        │ myos-updated            │
│ wake word ·  │ discovery (mDNS)· │ A/B OTA updates ·       │
│ STT · TTS    │ pairing (mTLS) ·  │ image verification      │
│              │ input relay ·     │                         │
│              │ screen streaming  │                         │
├────────────────────────────────────────────────────────────┤
│  Session: cage (Wayland kiosk compositor) + greetd         │
├────────────────────────────────────────────────────────────┤
│  Linux userspace: systemd · PipeWire · NetworkManager ·    │
│  BlueZ · udisks2 · polkit · flatpak (optional apps)        │
├────────────────────────────────────────────────────────────┤
│  Linux kernel (arch-specific config) · firmware blobs      │
├────────────────────────────────────────────────────────────┤
│  Bootloader: systemd-boot (UEFI) / GRUB (BIOS) / U-Boot    │
└────────────────────────────────────────────────────────────┘
```

### Component contracts

| Component | Language | Runs as | Talks over |
|---|---|---|---|
| `myos-shell` | Dart/Flutter | user session (inside cage) | gRPC over Unix socket to `myosd` |
| `myosd` | Rust (recommended) or Go | systemd system service | gRPC Unix socket `/run/myos/agent.sock`; HTTPS out to providers |
| `myos-voiced` | Rust + whisper.cpp/Piper FFI | systemd user service | PipeWire for audio; gRPC to `myosd` |
| `myos-linkd` | Rust | systemd system service | mDNS, QUIC/WebRTC to peers; gRPC to `myosd` and shell |
| `myos-updated` | shell around `systemd-sysupdate` | systemd service + timer | HTTPS to update server |
| `myos-firstboot` | part of shell (onboarding mode) | oneshot before greetd | writes `/etc/myos/` config |

**Why split shell and daemon:** the agent must act even when the UI is busy or restarted, must run tools as a controlled system actor (not as the raw UI process), and voice/pairing must work from a lock screen. The Unix-socket gRPC boundary is also exactly where the permission system lives (§7).

---

## 3. Repo layout (monorepo)

```
MyOS/
├── docs/                    # these specs
├── proto/                   # gRPC .proto files — single source of truth for IPC
│   ├── agent.proto          # shell <-> myosd
│   ├── voice.proto
│   └── link.proto
├── shell/                   # Flutter app (the entire UI)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── form_factor.dart # detects phone/desktop/tv, picks layout
│   │   ├── onboarding/
│   │   ├── home/            # chat bar, provider chips
│   │   ├── chat/
│   │   ├── terminal/        # xterm.dart + flutter_pty
│   │   ├── settings/
│   │   └── link/            # pairing UI, dual-screen surface
│   └── linux/               # Flutter Linux runner (GTK embedder)
├── daemon/                  # myosd (Rust workspace)
│   ├── crates/
│   │   ├── myosd/           # main binary, gRPC server
│   │   ├── providers/       # anthropic, openai, google, local(llama.cpp)
│   │   ├── tools/           # exec, files, settings, apps, network, media...
│   │   ├── policy/          # permission engine
│   │   └── vault/           # secrets (age-encrypted, TPM-sealed when avail)
├── voiced/                  # wake word + STT + TTS service
├── linkd/                   # discovery, pairing, remote input, screen stream
├── os/                      # the distro itself
│   ├── archiso/             # ISO profile (see doc 04)
│   ├── rootfs-overlay/      # files copied into the image: /etc, systemd units
│   ├── kernel/              # kernel config fragments per target
│   └── branding/            # plymouth theme, wallpapers, logos
├── installer/               # Flutter installer app (runs from live ISO)
├── ci/                      # GitHub Actions / container defs
└── Makefile                 # make iso, make run-qemu, make run-vmware
```

Rule: **`proto/` is the single source of truth.** Shell (Dart), daemon (Rust), voiced, linkd all generate their bindings from it in CI. Never hand-write IPC types.

---

## 4. The agent model (heart of the OS)

`myosd` runs a standard tool-use loop against whichever provider is selected:

```
user msg (text or transcribed voice)
  → myosd builds context: system prompt + device profile + conversation
  → provider streams back text and/or tool calls
  → myosd checks each tool call against policy (§7)
  → executes tool, returns result to provider
  → loop until final answer → stream to shell UI
```

### System prompt (per-device, generated at boot)

Includes: agent name, device form factor, hostname, OS version, connected peers, available tools with schemas, user's display name, locale/timezone. Keep it under ~2k tokens; tool schemas are sent via the provider's native tool-use API, not inlined as prose.

### Core tool registry (v1)

| Tool | Does | Risk tier |
|---|---|---|
| `shell.exec` | run a command, capture output | HIGH |
| `fs.read` / `fs.write` / `fs.list` | file operations under $HOME | MED |
| `settings.get/set` | brightness, volume, wifi on/off, timezone… | LOW |
| `apps.launch` / `apps.list` | start a flatpak/desktop app | LOW |
| `net.status` / `net.connect_wifi` | via NetworkManager D-Bus | MED |
| `media.play/pause/next` | via MPRIS D-Bus | LOW |
| `system.power` | shutdown/reboot/sleep | MED |
| `link.devices` / `link.send` / `link.screen` | mesh: list peers, push file, start dual screen | MED |
| `timer.set` / `notify.send` | reminders, notifications | LOW |
| `search.web` | provider-native web search when available | LOW |

Tools are implemented in `daemon/crates/tools/`, each as a struct with a JSON-schema description auto-exported to the provider. Adding a tool = one file + registry entry. Design for this to be the main axis of growth.

### Providers

`daemon/crates/providers/` — one adapter per provider behind a common trait:

```rust
trait Provider {
    fn id(&self) -> &str;                    // "anthropic", "openai", "local"
    async fn stream(&self, req: ChatRequest) // messages + tools in,
        -> impl Stream<Item = Event>;        // text deltas + tool calls out
    fn auth(&self) -> AuthKind;              // ApiKey | OAuth | None(local)
}
```

- **Anthropic:** Messages API, streaming, native tool use. Default recommendation in UI.
- **OpenAI / Google:** same shape via their chat/tool APIs.
- **Local:** llama.cpp server (`llama-server`) launched on demand; models stored in `/var/lib/myos/models`. Used for offline mode and as the always-on cheap model for wake-word confirmation and intent routing.

API keys/OAuth tokens live in the **vault** (age-encrypted file, key sealed to TPM2 via `systemd-cred` when hardware allows, else derived from user login). Never in plain config, never readable by the shell process directly.

---

## 5. Form-factor adaptation (one codebase, every screen)

Detection at boot (in `shell/lib/form_factor.dart`, fed by `myosd` device profile):

| Signal | Phone | Laptop/PC | TV |
|---|---|---|---|
| DMI chassis type / device tree | handset | laptop/desktop | — |
| Touchscreen present, no keyboard | ✓ | | |
| HDMI-only display + CEC available | | | ✓ |
| Screen diagonal + DPI | <7" | 11–32" | >32", 10ft viewing |
| Kernel cmdline override `myos.formfactor=` | manual override always wins | | |

Layout rules (enforced in one `AdaptiveScaffold` widget, never per-screen):

- **Phone:** chat bar bottom, full-screen conversation, swipe navigation, on-screen keyboard (implement with Flutter's built-in; system keyboard = the shell's own widget since we own the whole screen).
- **Desktop:** chat bar centered (Spotlight-style) over a status bar + wallpaper; windows for terminal/settings are Flutter routes in a windowed canvas, not real Wayland windows (v1: single fullscreen Flutter surface owns everything; real multi-window via additional Wayland toplevels is v2).
- **TV:** giant chat bar top, focus-based navigation (D-pad from remote via CEC or BT remote), voice-first, 2× font scale, safe-area margins.

---

## 6. Device mesh (phone ↔ PC)

Handled by `myos-linkd`. Full protocol in `02-IO.md §8`. Summary:

- **Discovery:** mDNS/DNS-SD, service type `_myos-link._udp`, TXT records carry device name, form factor, cert fingerprint.
- **Pairing:** short-lived QR code (PC shows, phone scans) or 6-digit PIN; exchange = SPAKE2 → both sides store peer cert → all later traffic is mTLS/QUIC. Pair once, trust forever until revoked in settings.
- **Channels over one QUIC connection:** control (JSON-RPC), input relay (evdev events, phone touchpad-mode → PC cursor), clipboard sync, file push, notification mirror, **screen stream** (H.264/HEVC via VA-API/V4L2 encode, ~"Moonlight-class" latency target <60 ms LAN).
- **Dual screen:** PC compositor adds a virtual output (cage → wlr virtual output protocol), streams it to phone; phone renders it as a fullscreen surface with touch mapped back as absolute input. Reverse direction identical.
- **Agent integration:** the mesh is also a tool surface — "send this file to my phone", "show my phone screen here" are just `link.*` tool calls.

---

## 7. Security & permission model

The agent can execute shell commands. This is the most dangerous thing in the OS. Non-negotiable rules:

1. **Policy engine in `myosd`, not in the prompt.** Prompts are not a security boundary.
2. Risk tiers: LOW = auto-allow; MED = allow + log + undo where possible; HIGH (`shell.exec`, writes outside $HOME, power off during activity, sending files off-device) = **explicit confirm in UI** ("Agent wants to run: `rm -rf ~/old-project` — Allow / Deny / Always for this pattern"). Confirmation UX is a shell modal fired over gRPC.
3. `shell.exec` runs in a **transient systemd scope** with resource limits, as the user (never root). Root actions go through polkit with fine-grained action IDs (`org.myos.settings.timezone`, …).
4. Vault secrets never enter the model context. Provider adapters read them at request time; tool results are scrubbed for known secret patterns before being sent back to the provider.
5. Full audit log: every tool call, args, decision, outcome → `/var/log/myos/agent-audit.jsonl` (journald too). Settings has a "what did my agent do" timeline.
6. Mesh: all traffic mTLS; input-relay and screen-stream require the *receiving* device to have accepted the session (no silent remote control).
7. Disk: LUKS2 full-disk encryption offered at install (default ON), TPM2 auto-unlock where available.
8. Updates: signed images, A/B slots, auto-rollback on triple boot failure (see docs 01 & 04).

---

## 8. Boot-to-shell flow (what "install and it just works" means)

```
UEFI → systemd-boot → linux + initramfs (plymouth splash "MyOS")
  → systemd default.target
     → NetworkManager, PipeWire (user), myosd, myos-linkd
     → greetd
        → first boot?  cage → myos-shell --onboarding
        → else         autologin user → cage → myos-shell
```

Onboarding (runs inside the same shell binary, `--onboarding` flag):
1. Language + timezone + Wi-Fi
2. Create user (name, password optional if TPM+PIN)
3. **Name your agent** (this string becomes the wake word, stored `/etc/myos/agent.toml`)
4. Voice enrollment (optional): 3 samples of "Hey `<name>`" to tune wake-word threshold
5. Connect a provider (API key paste or OAuth device-code flow rendered as QR) — skippable, local model offered as fallback
6. Pair other devices (optional) → done, writes config, restarts into normal session.

Target: **power-on → usable chat bar in <20 s** on SSD hardware, <10 s warm boot.

---

## 9. Roadmap / milestones

| Phase | Deliverable | Exit criteria |
|---|---|---|
| **M0** | Repo scaffolding, protos, CI, `make iso` producing a booting Arch-based ISO with plain TTY | ISO boots in QEMU + VMware |
| **M1** | cage + Flutter shell autostarts, chat UI talks to `myosd` echo server | type in chat bar, get echo, `Ctrl+Shift+T` opens terminal |
| **M2** | Real providers (Anthropic first), tool loop with `settings.*`, `fs.*`, `shell.exec` + confirm UI, vault | "set volume to 50%" and "create a file on my desktop" work end-to-end |
| **M3** | Onboarding + installer (live ISO → disk install, LUKS), branding/plymouth | Fresh VM: install → reboot → onboard → chat works |
| **M4** | Voice: wake word with custom agent name, STT, TTS | hands-free "Hey Nova, what time is it" |
| **M5** | Mesh: discovery, pairing, clipboard + file push, remote input | phone (2nd x86 VM or Pi for now) controls PC cursor |
| **M6** | Screen streaming / dual display, OTA A/B updates | dual-screen demo; update server pushes an image, device rolls forward and can roll back |
| **M7** | ARM64 image (Raspberry Pi 5 = stand-in for TV), TV layout | same repo builds Pi image, D-pad navigation works |
| **M8** | Phone target exploration (PinePhone / postmarketOS kernel base) | boots to shell on one real phone |

Each milestone = a tag + an ISO artifact from CI.

---

## 10. Doc map

- **01-BOOTLOADER.md** — everything from power-on to kernel handoff, plus A/B layout the updater relies on.
- **02-IO.md** — every way bytes enter/leave the machine: input, display, audio/mic, network, BT, storage, and the mesh protocol.
- **03-OS-CREATION.md** — the distro build itself + all MyOS services and the Flutter shell, in implementation order.
- **04-ISO-BUILD-AND-SHIP.md** — turning the above into a signed, testable, updatable ISO and shipping it.
