# Claude Code status line: conversation id + live context bars

His ask (2026-11-10/12): see the agent's context and every subagent's context
"live as it goes up throughout a chat", as "a bar showing right at the place
where I type inputs", and "that bar should include the current conversation id
as well".

## What it shows

```
00000000-0000-4000-8000-000000000000 · Fable 5.2 · ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱ 90k/1M 9% · tool call failures 4/81 (5%)
    agents: 3 running, 1 done
    ● fork·fable Write today's handover doc ▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱ 354k/1M 35% · tool call failures 0/4 (0%)
    ● general-purpose·opus Evidence for his 4 diary claims ▰▰▰▰▱▱▱▱▱▱▱▱ 266k/1M 27% · tool call failures 5/97 (5%)
        ● general-purpose·opus Code: what happens after a loss ▰▰▰▱▱▱▱▱▱▱ 210k/1M 21% · tool call failures 0/70 (0%)
        ✓ Explore·sonnet Find UI "not in view" line ▰▱▱▱▱▱▱▱▱▱ 46k/1M 5% · tool call failures 1/25 (4%)
```

- Line 1: the full conversation id (for `claude -r <id>`), model, main context bar, the
  main agent's tool call failures as failed/total (percent).
- No subagent running → line 1 is all there is (his 2026-11-12: "if no agents run, don't
  write 'agents 0 running...'").
- At least one running → everything about agents goes on new lines, indented 4 spaces
  (a real tab has no fixed width in the status line): a count line, then one row per
  running subagent (●) plus ones finished in the last 2 minutes (✓).
- Sub-subagents sit under their parent, one indent deeper per level (`parentAgentId` in
  the child's `.meta.json`; all levels live in the same `subagents/` folder). A parent
  stays listed (○ if it went quiet) while a child of it is listed. Over 6 rows → "+N more".
- Colour: green under 50 %, yellow under 80 %, red above.

## How it works

- Script: `dotfiles/.claude/statusline/agent-context-bar.py`, linked to
  `~/.claude/statusline/agent-context-bar.py` (SYMLINKS in `scripts/install.sh`).
- `~/.claude/settings.json` → `statusLine.command = python3 ~/.claude/statusline/agent-context-bar.py`,
  set by `lb_reconcile_claude_statusline` (`scripts/lib/reconcile.sh`) only when no
  statusLine exists; a different one is reported, never replaced.
- Context = last assistant turn's input + cache_read + cache_creation + output, read
  from the tail of the transcript (or the newer compact boundary, below): the same figure as `token-usage`, seedeep and
  Claude Code's own `context_window.used_percentage`.
- Subagents: `<project>/<session>/subagents/agent-<id>.jsonl` + `.meta.json`
  (description, agentType, model, `finished`). Haiku window = 200k; others use the
  main session's `context_window_size`.
- ~35-50 ms per run, tail reads only.
- Running sessions pick the setting up live, no restart (verified 2026-11-12).
- Debug: last stdin blob in `~/.cache/agent-context-bar/last-input.json`;
  `python3 agent-context-bar.py < that-file` reproduces the bar.

## Verified 2026-11-12 (laptop)

Main 150k/1M 15 % = Claude Code's `used_percentage` 15. A Haiku Explore subagent
sampled every 3 s: ? → 28k → 46k → ✓ 72k/200k; the task notification reported
72,207 tokens.

## Tool counts (added 2026-11-12, his ask: "total tool calls and failed tool calls, and their ratio so that I can judge wasted tokens")

- tools = every `tool_use` block in that transcript; failed = `tool_result` blocks with
  `is_error: true`, minus the ones he declined or interrupted. The main line counts the
  main agent only; each subagent row has its own count.
- What `is_error` means: Bash exit code other than 0, an Edit whose text did not match, a
  missing file, a hook block, a tool crash. It is exact for "the tool said it failed".
- What it is NOT: a measure of waste. `grep` with no match and a test run that fails on
  purpose count as failed; a wrong route made of commands that all succeed counts as 0.
  Read it as a lower-bound hint: a high ratio means look, a low one proves nothing.
- Counted incrementally: `~/.cache/agent-context-bar/stats/<project>_<id>.json` holds the
  byte offset and the two counts, so a run parses only new lines (still ~35-50 ms).
- Ratio colour: yellow from 10 %, red from 20 %.

## After /compact (fixed 2026-11-12)

He compacted at 156k and the bar still said 156k until his next message, then 64k. Cause:
the bar read the last assistant turn, which was still the pre-compaction one. Now a
`compact_boundary` line newer than that turn wins and the bar shows its `postTokens` as
`~16k ... compacted`. That figure is the summary alone; the next reply adds the system
prompt, tools, CLAUDE.md and memory again (here 16k → 64k), and the bar shows it exactly.

## Bar length follows the window width (added 2026-11-12, his ask: "dynamic length, based on the window width")

- The bar takes the columns left over after the text on its line: 5 to 50 cells, with 4
  columns kept free at the right. Each subagent row is fitted on its own.
- The script runs on pipes, so it has no terminal of its own. It walks up its parent
  processes to the first one holding a `/dev/pts/N` (the `claude` process) and asks that
  pty for its size. No pty found (some other app hosting Claude Code) → 10 cells as before.
- Tested at 155 columns: line 151 wide, bar 40 cells. A resize shows at the next refresh
  of the status line (the next message or tool call), not while dragging.

## Related

seedeep (`npm i -g seedeep`, http://localhost:44842) is the browser view of the
same data, installed 2026-11-10 for comparison; not tracked here.
