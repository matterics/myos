# MyOS — OS Creation Guide (the distro + every MyOS component)

> **Goal:** step-by-step, implementation-ordered guide to building MyOS itself: base system,
> session, the Flutter shell, `myosd` agent daemon, providers, tools, vault, voice, onboarding,
> terminal, and permissions. Follow top to bottom; each section states its milestone (M#) from
> doc 00 §9. Boot chain details → doc 01. I/O subsystems → doc 02. Packaging/ISO → doc 04.

---

## 1. Strategy: assemble, don't invent (M0)

We build a **custom Arch-based distro**. Arch because: rolling packages (fresh mesa/pipewire/flutter deps), `archiso` gives us ISO building day one, `pacman` repos are trivial to self-host, and AUR-style PKGBUILDs are the easiest packaging format for an AI agent to generate correctly.

**Own packages**: everything MyOS ships as pacman packages built from `PKGBUILD`s in-repo:

```
myos-shell, myosd, myos-voiced, myos-linkd, myos-updated,
myos-branding (plymouth, wallpapers), myos-settings (rootfs config files),
myos-installer
```

A self-hosted repo (`[myos]` in pacman.conf, served from CI artifacts / any static host) is how both the ISO build and OTA updates consume our code. Set this up in M0 — it forces clean packaging from the start.

Base package set (the whole OS, ~800 MB installed):

```
base linux linux-firmware intel-ucode amd-ucode systemd
mesa vulkan-intel vulkan-radeon libinput cage greetd
pipewire pipewire-alsa pipewire-pulse wireplumber
networkmanager iwd bluez systemd-resolvconf nftables
udisks2 polkit flatpak foot ttf-inter noto-fonts noto-fonts-emoji noto-fonts-cjk
plymouth mkinitcpio open-vm-tools qemu-guest-agent
+ all myos-* packages
```

No display manager UI, no desktop environment, no browser (v1). `foot` = fallback terminal for recovery only; the real terminal is inside the shell.

---

## 2. Session: boot → shell (M1)

### 2.1 greetd + cage

`/etc/greetd/config.toml` (in `os/rootfs-overlay/`):

```toml
[terminal]
vt = 1

[default_session]
command = "cage -d -s -- myos-session"
user = "myos"          # before onboarding creates a real user; installer rewrites to autologin that user
```

`myos-session` (tiny shell script, packaged in myos-settings):

```sh
#!/bin/sh
# environment for the shell
export XDG_SESSION_TYPE=wayland
export GDK_BACKEND=wayland
if [ ! -f /etc/myos/onboarded ]; then
    exec myos-shell --onboarding
fi
exec myos-shell
```

### 2.2 systemd units (all in `os/rootfs-overlay/usr/lib/systemd/`)

| Unit | Type | Notes |
|---|---|---|
| `myosd.service` | system | `ExecStart=/usr/bin/myosd`, socket-activated via `myosd.socket` (`/run/myos/agent.sock`, `SocketMode=0660`, `SocketGroup=myos`) |
| `myos-linkd.service` | system | wants `network-online.target`; `AmbientCapabilities=` none, uinput via group |
| `myos-voiced.service` | **user** | needs the user's PipeWire; `WantedBy=default.target` |
| `myos-updated.timer` | system | daily + on-boot check |
| `myos-shell-ready.service` | system oneshot | `WantedBy=boot-complete.target` (doc 01 §3.3) |

Hardening on every service: `ProtectSystem=strict`, `ProtectHome=read-only` (myosd gets `ReadWritePaths=/home` only for `fs.*` tools — see §7), `NoNewPrivileges=yes`, `PrivateTmp=yes`, dedicated `DynamicUser=no` static users `myosd`, `myoslink`.

---

## 3. The Flutter shell (M1–M3)

One Flutter app (`shell/`), Linux desktop embedder (GTK), compiled AOT, runs fullscreen under cage.

### 3.1 App skeleton

```
lib/
├── main.dart              # arg parse (--onboarding), DI setup, AdaptiveApp
├── form_factor.dart       # doc 00 §5 detection (reads myosd DeviceProfile)
├── ipc/                   # generated gRPC client + reconnect logic
├── theme/                 # dark-first, per-form-factor type scale
├── home/
│   ├── home_screen.dart   # wallpaper, status bar, ChatBar, provider chips
│   └── chat_bar.dart      # THE hero widget: input + mic button + streaming state
├── chat/
│   ├── conversation.dart  # message list, streaming markdown, tool-call cards
│   └── confirm_sheet.dart # HIGH-risk tool confirmation modal (policy §7)
├── onboarding/            # 6-step flow (doc 00 §8)
├── terminal/              # §5
├── settings/              # providers, devices, audio, network, agent audit log
└── link/                  # pairing, device list, remote-control + screen surfaces
```

- State management: Riverpod. IPC: `grpc` Dart package over `InternetAddress(type: unix)`.
- Streaming chat: server-streaming RPC `Chat(stream ClientEvent) returns (stream ServerEvent)`; render markdown incrementally (`gpt_markdown` or custom); tool calls render as collapsible cards with live status (running → ok/denied/error).
- Wallpaper/theme: `myos-branding` assets; TV form factor swaps type scale + focus traversal (`FocusTraversalGroup`, D-pad).
- The shell **never** does privileged work. It renders, it asks `myosd`.

### 3.2 proto/agent.proto (the contract — write this before any code)

```proto
service Agent {
  rpc Chat(stream ClientEvent) returns (stream ServerEvent);   // text/voice msgs, confirms
  rpc GetDeviceProfile(Empty) returns (DeviceProfile);          // form factor, agent name...
  rpc ListProviders(Empty) returns (ProviderList);
  rpc ConnectProvider(ConnectRequest) returns (stream ConnectProgress); // api-key or oauth device-code
  rpc SelectProvider(ProviderId) returns (Empty);
  rpc GetAuditLog(AuditQuery) returns (stream AuditEntry);
  rpc Onboard(OnboardConfig) returns (Empty);                  // writes /etc/myos, creates user
}
message ServerEvent { oneof ev { TextDelta delta; ToolCallStart tool_start; ToolCallEnd tool_end;
                                 ConfirmRequest confirm; TurnDone done; Err error; } }
message ClientEvent { oneof ev { UserMessage msg; ConfirmResponse confirm; CancelTurn cancel; } }
```

---

## 4. `myosd` — the agent daemon (M1–M2)

Rust. Crates per doc 00 §3. Build order:

### 4.1 M1: echo skeleton
tonic gRPC server on the unix socket; `Chat` echoes. Proves shell↔daemon plumbing + socket activation + permissions on the socket.

### 4.2 M2: provider loop

```rust
// crates/myosd/src/turn.rs — the core loop
loop {
    let stream = provider.stream(ChatRequest { system, messages, tools }).await?;
    while let Some(ev) = stream.next().await {
        match ev {
            Event::TextDelta(t) => shell_tx.send(delta(t)),
            Event::ToolCall(call) => {
                let decision = policy.check(&call, &session)?;          // §7
                let outcome = match decision {
                    Allow => tools.execute(&call).await,
                    NeedsConfirm => { shell_tx.send(confirm_req(&call));
                                      if shell_rx.confirmed().await { tools.execute(&call).await }
                                      else { ToolResult::denied() } }
                };
                audit.log(&call, &decision, &outcome);
                messages.push(tool_result(outcome));                     // feed back, continue loop
            }
            Event::Done(stop) => if stop == EndTurn { return Ok(()); }   // else loop again with tool results
        }
    }
}
```

- **Anthropic adapter first** (Messages API, `tools` param, `tool_use`/`tool_result` blocks, SSE streaming). Then OpenAI (chat completions/responses API), Google, and `local` (llama.cpp `llama-server` child process, OpenAI-compatible endpoint — reuse the OpenAI adapter pointed at localhost).
- Conversation persistence: SQLite at `/var/lib/myos/sessions.db` (rusqlite), one conversation per device by default, "new chat" supported; prune/window context to model limits (keep system + last N turns + summaries).
- Context builder: device profile, time, locale, connected peers, **no secrets ever**.

### 4.3 Tools (M2, grow forever)

Each tool = one file in `crates/tools/src/`:

```rust
pub trait Tool: Send + Sync {
    fn name(&self) -> &'static str;                 // "settings.set_volume"
    fn schema(&self) -> serde_json::Value;          // JSON Schema for the provider
    fn risk(&self) -> Risk;                         // Low | Med | High
    async fn run(&self, args: Value, ctx: &ToolCtx) -> Result<Value>;
}
```

v1 registry per doc 00 §4. Implementation notes for the tricky ones:
- `shell.exec`: spawn via `systemd-run --user --scope --collect -p RuntimeMaxSec=120 -p MemoryMax=2G -- bash -c <cmd>` as the session user; stream stdout/stderr; truncate output to 16 KB for the model (full copy in audit log).
- `settings.*`: D-Bus to logind (brightness), PipeWire (volume), NM (wifi), timedated (tz).
- `fs.*`: canonicalize paths, jail to `$HOME` + `/run/media` unless policy grants wider; reject traversal.
- `apps.*`: enumerate flatpak + `.desktop` entries; launch via `systemd-run --user`.

### 4.4 Vault (M2)

`crates/vault`: secrets file `/var/lib/myos/vault.age` encrypted with age; identity key wrapped by TPM2 (`systemd-creds encrypt` with `--tpm2-device=auto`) when available, else by a key derived from user auth at login (PAM hook exports to keyring; myosd reads via `systemd-creds` LoadCredential). API: `get(provider_id) -> Secret`, `set`, `delete`. Secrets redaction filter runs over every tool result and every log line (`sk-`, `AKIA`, JWT regexes + exact known-secret match).

---

## 5. Terminal (M1)

Inside the shell: `xterm` Dart package (terminal emulator widget) + `flutter_pty` (spawns `/bin/bash` in a real PTY as the session user).

- `Ctrl+Shift+T`/`Cmd+Shift+T` toggles a terminal route (desktop: overlay panel 70% height; phone: fullscreen route; TV: disabled by default, enable in settings).
- Multiple tabs, scrollback 10k lines, links clickable → toast (no browser v1).
- **Agent hook:** button/gesture "explain this" sends the visible buffer to the agent; and `myos ask "<question>"` CLI (talks to the same socket) works inside the terminal — the terminal and chat are two views of one system.
- The PTY runs *unrestricted as the user* — this is the human's escape hatch, not the agent's. `shell.exec` (agent) keeps its own sandboxed path (§4.3); they never share code paths, so policy can't be bypassed by "the agent opening a terminal".

---

## 6. Voice pipeline (M4)

Own doc section in 02-IO §3. Implementation order:
1. `myos-voiced` skeleton: PipeWire capture, VAD gate, push-to-talk first (hold mic button in chat bar) → whisper.cpp (`base.en` q5) → transcript → `Chat` as `UserMessage{source: VOICE}`.
2. Piper TTS out, sentence-streamed, duck other audio.
3. Wake word: openWakeWord runtime + on-device custom-name training (02-IO §3.1). Ship "hey_myos.onnx" as guaranteed fallback.
4. Barge-in: wake word while TTS is playing pauses TTS and listens.
5. TV far-field: beam-forming if hardware provides multi-mic; else rely on remote's mic button.

Voice settings: engine picker (local whisper vs provider STT), voice picker, wake sensitivity slider, "mute mic" hardware-respecting toggle.

---

## 7. Policy & permissions engine (M2, extend forever)

`crates/policy`. Input: `(tool, args, session context)`. Output: `Allow | NeedsConfirm | Deny`.

- Static tier per tool (doc 00 §7) + **arg-sensitive escalation**: `fs.write` outside `$HOME` → High; `shell.exec` matching destructive patterns (`rm -rf /`, `dd of=/dev/`, fork bombs, `mkfs`, writes to `/etc|/usr|/boot`) → Deny outright with explanation; `net.*` to disable networking while on remote session → NeedsConfirm.
- User rules persisted from confirm sheet choices: "Always allow `shell.exec` matching `^git .*` in ~/code" → `/etc/myos/policy.d/user.toml`.
- Rate limits: >30 tool calls per turn or >5 High confirms per turn → hard stop turn, tell user.
- Everything → audit JSONL (doc 00 §7.5) + Settings timeline UI.
- **Tests are mandatory here**: table-driven policy tests are the closest thing this OS has to a safety spec.

---

## 8. Onboarding & first boot (M3)

- Runs as `myos-shell --onboarding` under the throwaway `myos` greeter user (§2.1).
- Steps per doc 00 §8. Implementation notes:
  - User creation + config writes happen via `myosd.Onboard()` (daemon runs as root-capable service; it shells to `useradd`, writes `/etc/myos/agent.toml`, `locale.conf`, greetd autologin, then `touch /etc/myos/onboarded`).
  - Provider connect: API key → paste field (validated with a 1-token test call); OAuth → device-code flow: show code + QR of verification URL, poll token endpoint.
  - Wake-word enrollment kicks off the training job (§6) in background; onboarding doesn't block on it.
  - Ends with `systemctl restart greetd` → real session.
- `/etc/myos/agent.toml`:

```toml
[agent]
name = "Nova"            # the wake word + display name
voice = "en_US-lessac-medium"
[device]
name = "harsh-laptop"
form_factor = "desktop"  # auto-detected, user-overridable
```

---

## 9. Build system & dev loop (M0)

- **Makefile targets:** `make protos` (buf → Dart/Rust codegen), `make shell` (flutter build linux), `make daemon` (cargo build --release), `make pkgs` (build all PKGBUILDs into `out/repo/` + repo-add), `make iso`, `make run-qemu`, `make run-vmware`, `make test`.
- All builds run in a container (`ci/archlinux-build.Containerfile`) so Windows/macOS hosts work: `podman run ... make pkgs`. **You develop on Windows; everything Linux-side happens in the container or a WSL2 Arch instance — set WSL2 up first, it's the fastest inner loop** (`wsl --install -d ArchLinux`, then flutter run inside WSLg to iterate on the shell UI without booting an ISO).
- Inner loops:
  - Shell UI: `flutter run -d linux` in WSL2 with a mock myosd (`myosd --mock` echoes + fake tools). Seconds, not minutes.
  - Daemon: `cargo test` + `cargo run` against `grpcurl`/the shell in WSL2.
  - Integration: `make iso && make run-qemu` (~5 min). VMware for periodic real-GPU/vmwgfx checks.
- CI (doc 04 §9) runs the same containers.

---

## 10. Implementation order recap (do it in exactly this order)

1. **M0**: repo layout, `proto/agent.proto`, Makefile, build container, archiso profile boots to TTY (doc 04 §3), pacman repo pipeline.
2. **M1**: greetd+cage+shell autostart; ChatBar echo via `myosd --mock`→real skeleton; terminal with PTY; `Ctrl+Shift+T`.
3. **M2**: Anthropic adapter + tool loop; `settings/fs/shell.exec` tools; policy + confirm sheet; vault; audit log.
4. **M3**: onboarding flow; installer (doc 04 §5); A/B disk layout (doc 01 §2); branding/plymouth.
5. **M4**: voice (push-to-talk → TTS → wake word → barge-in).
6. **M5–M6**: mesh (doc 02 §8), OTA updates (doc 04 §7), UKI+signing (doc 01 §3.4/§6).
7. **M7**: ARM64/Pi image profile, TV layout.

Every milestone must end with: ISO built by CI, boots in QEMU + VMware, acceptance boxes for that milestone checked in the relevant doc.
