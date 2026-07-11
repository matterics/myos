# Agent kernel direction

MyOS uses an AIOS-style kernel boundary: the shell never talks directly to a
model. `myosd` owns scheduling, shared conversation context, memory, tool/MCP
policy, audit, and permissions. Agent runtimes sit behind that boundary.

## Runtime roles

- **OpenCode is the default interactive runtime.** It is baked into the ISO and
  supplies provider/model discovery, OAuth-capable provider login, sessions,
  MCP configuration, and non-interactive agent runs.
- **Hermes is the designated learning and long-running agent runtime.** Its
  memory, skill evolution, messaging gateway, cron, and MCP capabilities will
  be integrated behind the same runtime interface; it must not become a second
  source of OS permission truth.
- **Direct HTTP and Ollama are compatibility/fallback adapters**, not the
  default experience.

## Shared context

Conversation transcripts belong to MyOS and survive provider changes. The
daemon supplies the same OS/device context and transcript to every runtime,
tracks a provider-independent token estimate, and exposes current usage and
model readiness to the shell. Provider-native sessions remain available via
provider commands but do not replace MyOS history.

## Loop contract

Every recurring flow follows the loop-engineering spine:

1. schedule or trigger;
2. read durable state and budget;
3. run in an isolated project/worktree when files can change;
4. execute through an agent runtime;
5. verify and record the result;
6. cross the MyOS permission gate before external side effects;
7. update durable state for the next run.

Loops begin report-only. Assisted and unattended modes are explicit upgrades,
not defaults.

## Permission contract

- **Ask for approval**: every OS command produces a confirmation request.
- **Auto accept this session**: approvals are cached only for the active daemon
  session and conversation.
- **Full access**: persists until the user switches it off.

OpenCode/Hermes permission settings may further restrict a run, but they may
never bypass this OS-level policy.

## Provider capabilities

The daemon publishes commands for the selected runtime. The shell uses that
catalog for slash-command autocomplete instead of hard-coding a single
provider's UI. OpenCode commands currently expose sessions, models, MCP, stats,
and connection guidance. Future runtimes implement the same capability query.
