# OOM-Guard Claude Code Hook

A global Claude Code `PreToolUse` hook that warns — and at a critical threshold,
blocks — when the system is heading toward an out-of-memory crash.

## Why

On 2026-05-22 an agent-spawned `build_thumbs.py`, launched detached (`nohup … &`)
and left unwatched, leaked to ~27 GB and triggered a kernel OOM kill that took down
the whole graphical session (every Claude Code terminal + both browsers). The agent
had no feedback that memory was running out. This hook is that feedback.

## What it does

- **Script:** `dotfiles/.claude/hooks/oom-guard.sh` → symlinked to
  `~/.claude/hooks/oom-guard.sh`.
- **Event:** `PreToolUse`, matcher `*` — runs before every tool call.
- Reads `/proc/meminfo` + `ps`, then classifies:
  - **OK** — silent.
  - **WARN** — low RAM, high swap, one process over 55 % of RAM, or a process that
    grew >3 GB between checks. Injects a non-blocking warning naming the largest
    memory consumer (PID, RSS, command, growth) with a `kill` suggestion.
  - **CRITICAL** — RAM <7 % free or swap >90 % used. `permissionDecision: deny` for
    the tool call — except `kill`/`pkill`/diagnostics, which always pass so the
    agent can recover.
- **Attribution:** a process is only called "agent-spawned" when it is provably a
  live descendant of a `claude` process; otherwise the wording stays neutral. The
  hook never tells an agent to kill a browser or a user service.
- **Fail-safe:** any error → exit 0, no output. It never breaks a session and only
  ever emits `deny` on a clean, confident CRITICAL classification.
- Thresholds are env-overridable constants at the top of the script. Disable
  entirely with `touch ~/.claude/hooks/.oom-guard-off`.

## Deployment

`install.sh` handles both halves:
- a `SYMLINKS` entry links the script into `~/.claude/hooks/`;
- `setup_oom_guard_hook()` registers it in `~/.claude/settings.json` via a
  non-destructive, idempotent `jq` merge.

## Relationship to freeze-monitor — and future work

This repo also carries an older, more elaborate OOM-protection design:
`freeze-monitor` + `memory-pressure.sh` (`~/Programs/utilities/freeze-monitor/`,
documented in `docs/oom-protection-lessons.md`) — a 3-second sampling daemon, a
velocity-based hook, and datalake ingestion. On this machine only its logging
service (`claude-memory-monitor.service`) runs; the `memory-pressure.sh` hook was
never installed. `oom-guard.sh` is the lighter, self-contained, daemon-free
replacement for that hook layer.

The two systems have **not** been reconciled. The planned work — scientifically
test both and merge them into one well-tested memory-protection system — is
tracked in `progress_actual.md`.
