# Subagent Context Guard — Claude Code hook

Enforces the "retire subagents at ~240k context" rule (Prabhanshu, 2026-08-02)
mechanically, so the orchestrator does not have to remember it.

## The problem it solves

Every subagent turn re-reads the agent's whole context, so per-turn cost
scales with context size — and past a point the extra context stops helping.
The agent has too many parameters in working memory, loses the goal in the
noise, and drifts (mission creep). This is a property of intelligence under
load, not of a particular model: it shows up even with a 1M-token window.
The remedy is graceful retirement: the bloated agent writes a handover, a
fresh successor boots from it.

## What it measures

The same figure Claude Code prints as `<subagent_tokens>` in task
notifications: the agent's **current context size** — last turn's
`input + cache_read + cache_creation + output` — read from the agent's own
transcript at `~/.claude/projects/<proj>/<session>/subagents/agent-<id>.jsonl`.
Not cumulative billed tokens. Verified against four real agents: the hook's
figure and the notification's figure agree within 0.3%.

The read is a backwards chunked tail scan, so it costs well under a
millisecond even on multi-megabyte transcripts.

## Behaviour

| Event | Matcher | What happens |
|-------|---------|--------------|
| `SubagentStop` | (all agents) | Fires when a subagent finishes a turn (the event name is Claude Code's; nothing here stops an agent). Measure it; first crossing of WARN (180k) or RETIRE (240k) prints a one-line `systemMessage` to the user, no repeats; every stop past 240k is logged to the ledger. |
| `PreToolUse` `SendMessage` | `Agent\|SendMessage` | **The gate.** Target at/over RETIRE → `deny` with a handover recipe. Target at/over WARN → advisory `additionalContext`. Unknown target → silent allow. |
| `PreToolUse` `Agent` | `Agent\|SendMessage` | Before spawning, inject a fleet status line listing every agent in the session at/over WARN, tagged `[warn]`/`[RETIRE]`. |
| `PostToolUse` `Agent` | `*` | Record `agentId → description` so status lines read as `a1828637… (Write experience 021)` rather than a bare id. |
| `PostToolUse` any tool | `*` | **Top-level session check** (skipped inside subagents). Measures this session's own context; first crossing of 240k injects a warning to the model and a line to the user; first crossing of 400k gives a strong nudge to write the session handover and let a fresh session take over. Warning only, never blocks. Silent otherwise. |

### The override

The limit is soft. A task that genuinely needs the accumulated context — most
often the handover request itself — is sent with the marker anywhere in the
message:

```
[long-context-ok: handover] Write the handover doc to docs/handover-w15.md …
```

The gate lets it through, counts it, and prints
`long-context override #N for <agent> at <ctx>: <reason>` so overrides stay
visible to the user. The deny message tells the orchestrator exactly this, so
the cost of forgetting is one denied call, not a stuck session.

### Retirement recipe (as printed in the deny)

1. One final message to the bloated agent, tagged `[long-context-ok: handover]`:
   ask for a handover doc — done / left / exact file paths / gotchas /
   verified facts.
2. Spawn a **fresh** agent with that handover plus the new task.
3. Do not resume the bloated agent with new work.

## Files

- Lives in the `token-usage` skill: `dotfiles/.claude/skills/token-usage/`.
- Script: `hooks/subagent-context-guard.py` → symlinked to
  `~/.claude/hooks/subagent-context-guard.py` (python3, stdlib only).
- CLI: `bin/token-usage` → `~/.local/bin/token-usage`. Reports this agent's
  own context (main session or calling subagent), every subagent's context
  and level, and the session's ledger rows. `--brief` for one line, `--json`.
- Tests: `tests/test-subagent-context-guard.sh`
  (synthetic transcripts + hook inputs; 25 checks).
- State: `~/.claude/hooks/state/subagent-context/<session_id>.json` and
  `guard.log`, the ledger: `CROSS` (first crossing), `OVER` (every stop past
  240k, numbered), `WARN`, `DENY`, `OVERRIDE` (with reason), `ERROR` — each
  line prefixed with session and agent id, so it reads on its own.
- Registration: `setup_subagent_context_guard_hook()` in `scripts/install.sh`
  merges the three event entries into `~/.claude/settings.json` idempotently.

## Tuning / disabling

```bash
touch ~/.claude/hooks/.subagent-context-guard-off   # off switch, no settings edit
SUBAGENT_CTX_WARN=150000 SUBAGENT_CTX_RETIRE=200000  # subagent thresholds
SUBAGENT_CTX_MAIN_WARN=240000 SUBAGENT_CTX_MAIN_STRONG=400000  # top-level session
```

Why 240k / 400k for the top-level session: the same 240k line as subagents so
there is one number to remember (the star-trek orchestrator was at 282k when
this was set, and its drift was the motivating symptom). The strong nudge sits
at 400k because replacing the main agent is a session handover the user has to
act on, so it is asked for less eagerly than a subagent retirement.

## Fail-safe contract

Like `oom-guard.sh`: exit code is always 0; on any error or missing data the
hook emits nothing (= allow). It denies only a `SendMessage` whose target it
resolved to a transcript and measured cleanly at/over RETIRE.

## Known limits

- Registration took effect in the already-running session during testing
  (2.1.259, no restart needed), but treat that as a convenience, not a
  guarantee.
- `CLAUDE_CODE_SESSION_ID` is exported to Bash commands (undocumented but
  verified in main session and subagents); no agent id is, hence the CLI
  detects the calling subagent from the pending Bash tool_use in its transcript.
- `SendMessage` targets are resolved by agent id, then by `agent_name` or the
  spawn `description` recorded in state. Teammates without a transcript under
  this session are not gated.
- Agents that compact their own context will show the post-compaction size,
  which is the honest number.
