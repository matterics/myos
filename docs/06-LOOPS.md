# 06 — Loops: the first-class unit of work

MyOS is **loop-first**. Adapted from [loop-engineering](https://github.com/cobusgreyling/loop-engineering): instead of prompting the agent one turn at a time, the user (or the agent itself) creates **loops** — standing goals that run on a cadence. Projects are never created directly; **a loop creates its project on first run and every subsequent run advances it**.

```
user intent ──▶ Loop (goal + cadence + level) ──▶ runs on schedule ──▶ Project (created + advanced by the loop)
```

## Primitives mapping

| loop-engineering primitive | MyOS implementation | Status |
|---|---|---|
| Automations / scheduling | `myosd` loop scheduler (`loops.rs`, 30s tick) | ✅ M1 |
| State / memory | `Store` (`/var/lib/myos/providers.toml`): loop defs, run history (last 20/loop), projects | ✅ M1 |
| Skills | `/etc/myos/AGENTS.md` + per-project `PROJECT.md` | partial |
| Worktrees | isolated per-run project checkouts | ⏳ M2+ |
| Plugins / connectors (MCP) | daemon tool layer | ⏳ M2+ |
| Sub-agents (maker/checker) | verification run before a loop's report is accepted | ⏳ M2+ |

## Autonomy ladder

Every loop has a level, following the phased-rollout safety model:

| Level | Name | Behavior |
|---|---|---|
| L1 | Report | Run thinks + emits a markdown report. No side effects outside the loop's own project dir. **All loops execute at L1 in M1 regardless of requested level.** |
| L2 | Assisted | Proposes actions; each goes through the existing `ConfirmRequest` flow. |
| L3 | Unattended | Acts within a denylist. Requires audit log + tool layer first. |

## API (proto/agent.proto)

`CreateLoop`, `ListLoops`, `SetLoopEnabled`, `RunLoopNow`, `DeleteLoop`, `GetLoopRuns`, `ListProjects`.

- `LoopSpec`: `name`, `goal` (the standing prompt), `interval_minutes` (default 60), optional `project_name`, `level`.
- New loops are enabled immediately; the scheduler picks them up within 30s (first run is always due).

## Run lifecycle

1. Scheduler tick finds a due loop (`last_run_at + interval` elapsed, or never run).
2. `ensure_project`: if the loop names a project that doesn't exist yet, create `/var/lib/myos/projects/<slug>/` and seed `PROJECT.md` with the goal. Loops make projects.
3. Prompt the selected provider: loop system prompt + goal + tail of the previous run's report (continuity = memory).
4. Persist the run report to the store and append it to the project's `RUNS.md`.

No provider connected → the run is recorded as skipped, never crashes the scheduler.

## Example

```
CreateLoop {
  name: "Ship MyOS voice pipeline"
  goal: "Track progress on the wake-word + STT pipeline. Each run: assess status, list blockers, propose the single next concrete step."
  interval_minutes: 240
  project_name: "Voice Pipeline"
  level: LOOP_LEVEL_REPORT
}
```

First run creates `/var/lib/myos/projects/voice-pipeline/` with `PROJECT.md`; every 4h a new report lands in `RUNS.md` and the run history.

## Next (not in M1)

- Shell UI: Loops panel (list, create, toggle, run-now, run reports) in the Flutter shell.
- Chat integration: the agent creates loops from conversation ("keep an eye on X" → `CreateLoop`) once the daemon tool layer lands.
- L2/L3 execution, worktrees, maker/checker sub-agent verification, per-loop token budgets.
