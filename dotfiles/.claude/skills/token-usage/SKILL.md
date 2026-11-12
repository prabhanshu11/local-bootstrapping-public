---
name: token-usage
description: Quick insight into this agent's own context size and every subagent's context. The subagent retirement gate is EXPIRED (the user, 2026-09-30 19:2x); main-session nudges at 340k/600k stay. Use when asking "how big is my context", "how many tokens have I used", "which subagents are bloated", or when planning handovers. Also owns the subagent-context-guard hook.
allowed-tools:
  - Bash
---

# token-usage

Claude Code shows token counts to the **human** (statusline, `/context`,
`/cost`) but gives the **model** nothing: there is no tool, env var, or
reminder that says "your context is N tokens" or "subagent X is at N". The
only model-visible number is `<subagent_tokens>` in a task notification, and
only when that agent stops. This skill closes that gap.

## Run it

```bash
token-usage            # full report: this agent + every subagent + ledger
token-usage --brief    # one line, cheap enough to run before any big step
token-usage --json     # for scripts
```

Works from the main session and from inside a subagent's Bash tool (the
caller is detected from the transcript; the row is marked `*`).

Example:

```
token-usage · session 66104f24 · window 1000k · warn 450k · retire 550k
this agent: main session · context 141k (14% of window) · 87 turns · 63 tool uses · budget left 14.99M
subagents (3; 1 RETIRE, 1 warn):
  id          ctx level  turns tools  last  name
  a6cb704c   366k RETIRE   152   140    2h  W14 tracker rebuild [overrides:2]
  a1828637   191k WARN      13    12   40m  Write experience 021 + GOAL addendum
  a3743e88    33k ok         1     0    3m  Hook smoke test probe
  1 agent(s) at/over 550k: new work to them is gated; retire with a handover + fresh successor, or tag [long-context-ok: why].
```

## What the numbers mean

- **context** = the agent's current context window occupancy: last turn's
  `input + cache_read + cache_creation + output`. Same figure as
  `<subagent_tokens>`. Not cumulative billing.
- **warn 450k / retire 550k** for subagents (the user, 2026-09-30: "let the subagents retire at 550k"; were 180k/240k) are the soft limits from the retirement rule
  (Prabhanshu, 2026-08-02). Cost per turn scales with context, and past this
  size agents lose the goal in the noise and drift, regardless of the model's
  nominal window.

## The discipline (enforced by the bundled hook)

`hooks/subagent-context-guard.py` is registered globally for three events:

| Event | Effect |
|-------|--------|
| PreToolUse `SendMessage` | Target at/over 550k → the call is **bounced** with the handover recipe. Resend with `[long-context-ok: <reason>]` anywhere in the message if the task truly needs that context (e.g. the handover request itself). Each override is logged with its reason. Target at/over 450k → advisory only. |
| PreToolUse `Agent` | Injects a fleet status line (agents at/over 450k) before every spawn. |
| SubagentStop | Prints one WARN / RETIRE line to the user on first crossing. Never blocks anything. |
| PostToolUse `Agent` | Records agent id → description for readable labels. |
| PostToolUse any tool | Top-level session only: warns model + user once when this session crosses 340k, strong handover nudge at 600k (auto-compact at 750k). Never blocks. |

**Retirement recipe:** one final message to the bloated agent tagged
`[long-context-ok: handover]` asking for a handover doc (done / left / exact
file paths / gotchas / verified facts), then spawn a fresh agent with that
handover plus the new task. Never resume the bloated agent with new work.

## Ledger

`~/.claude/hooks/state/subagent-context/guard.log` records every DENY,
OVERRIDE (with reason), and every stop past 550k, keyed by session and agent.
Review it to see which tasks genuinely needed long context and which were
habit. `token-usage` prints this session's ledger rows at the bottom.

## Files

- `bin/token-usage` — the CLI (symlinked to `~/.local/bin/token-usage`)
- `hooks/subagent-context-guard.py` — the hook (symlinked to `~/.claude/hooks/`)
- `tests/test-subagent-context-guard.sh` — 25 checks on synthetic transcripts
- Off switch: `touch ~/.claude/hooks/.subagent-context-guard-off`
- Tunables: `SUBAGENT_CTX_WARN`, `SUBAGENT_CTX_RETIRE` (env)
- Docs: `local-bootstrapping/docs/subagent-context-guard-hook.md`
