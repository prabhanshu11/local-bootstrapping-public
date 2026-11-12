# memory-index-lint: keeping Claude Code's auto-memory index loadable

**Status:** live on both machines since 2026-10-01 (hook `dotfiles/.claude/hooks/memory-index-lint.sh`, registered by `LB_CLAUDE_HOOKS` in `scripts/lib/reconcile.sh`; CLI `memory-index-lint`).

## The problem (2026-10-01)

Claude Code's per-project auto-memory is a directory of one-fact-per-file notes plus an index, `~/.claude/projects/<project>/memory/MEMORY.md`, loaded into every session. Claude Code loads only **the first 25 KB or 200 lines** of it; the rest is silently dropped. The `~/Programs` index had grown to 26.6 KB / 130 lines / 97 entries (63 entries over 200 chars, three multi-line content blocks inline), so the five newest entries, the ones most likely to matter, were the ones not loaded. One index line pointed at a file that never existed.

## What the research says (fetched 2026-10-01)

- **Anthropic, Claude Code memory docs:** "The first 200 lines of `MEMORY.md`, or the first 25KB, whichever comes first, are loaded at the start of every conversation." Topic files are "read on demand". Near the limit, Claude is told to "keep one line per entry, move detail into topic files, and merge or drop stale entries." https://code.claude.com/docs/en/memory
- **Anthropic, best practices:** "For each line, ask: 'Would removing this cause Claude to make mistakes?' If not, cut it. Bloated CLAUDE.md files cause Claude to ignore your actual instructions!" https://code.claude.com/docs/en/best-practices
- **Anthropic, context engineering (2025-09-29):** aim for "the smallest possible set of high-signal tokens"; keep "lightweight identifiers (file paths, stored queries, web links)" and retrieve just in time. https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- **Anthropic, memory tool docs:** "keep its content up-to-date, coherent and organized… Periodically delete memory files that haven't been accessed in a long time." https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- **Stanford, Generative Agents (Park et al. 2023):** a memory stream of dated observations, retrieval scored by recency × importance × relevance, and *reflection* that synthesises many leaves into higher-level nodes once accumulated importance crosses a threshold. The always-visible layer should hold the abstract nodes; leaves stay in the store. https://arxiv.org/abs/2304.03442
- **MemGPT / Letta:** a small always-visible core with an explicit character budget per block, an archival tier reached by lookup, and a separate "sleep-time" consolidation pass. https://arxiv.org/abs/2310.08560 · https://letta.com/blog/sleep-time-compute
- **Mem0:** every new fact ends in ADD / UPDATE / DELETE / NOOP against the nearest existing memories, instead of always appending. https://arxiv.org/html/2504.19413v1
- **Reflexion:** only the last 1–3 episodes stay in the hot buffer. https://arxiv.org/html/2303.11366v4
- **A-MEM:** Zettelkasten-style notes that link and evolve rather than duplicate. https://arxiv.org/abs/2502.12110

Shared principles: a small hot tier with a fixed budget; a large cold tier reached through identifiers; consolidate episodes into one current-state item per project; durable rules do not decay with age, episodes do; enforce the budget with a trigger, not a reminder.

## The design applied to `~/Programs`

| Tier | File | Loaded | Holds |
|---|---|---|---|
| hot | `MEMORY.md` | every session | ≤16 KB / ≤120 lines / ≤200 chars per entry: user facts, binding rules (grouped by theme), **one START-HERE per live project**, references, a pointer to the catalog |
| warm | `CATALOG.md` | on demand | every topic file with its full hook (the long hooks trimmed from the hot index live here), closed / done / superseded items |
| archive | `archive/<project>-sessions.md`, `archive/consolidation-log.md` | on demand | dated session chains, verbatim, chronological; the log of every consolidation pass |

Rules adopted:
- `feedback` / `user` memories never leave the hot tier because of age; only when contradicted (record "superseded by") or merged into a themed file that keeps the dated verbatim quotes.
- `project` memories leave the hot tier when a newer state for the same project exists (fold it into `project_<x>-current.md`, updated in place; the old line goes to the ledger) or when closed for more than ~14 days.
- Dated session handovers are never new index lines; they update the project's current file and append one ledger line.
- Topic files are never moved or deleted by a consolidation pass (other sessions and `[[links]]` point at them); only index lines move.

## The lint

`memory-index-lint.sh` runs as a **PostToolUse** hook (matcher `Write|Edit|MultiEdit|Bash`) and acts only when the tool touched a `MEMORY.md` under `~/.claude/projects/*/memory/`. Checks:

1. bytes ≤ 16 000 (Claude Code's hard stop is 25 000)
2. lines ≤ 120 (hard stop 200)
3. every entry line ≤ 200 chars
4. no index line points at a missing file
5. every topic file is referenced from `MEMORY.md` or `CATALOG.md`

On a violation it prints the report to stderr and exits 2, which Claude Code shows to the agent right after the write, so the consolidation routine (written at the top of `MEMORY.md`) runs while the agent still has the context. Clean writes are silent. As a CLI, `memory-index-lint [MEMORY.md|dir…]` lints every project's index by default and exits 1 on a violation. Thresholds: `MEMORY_INDEX_SOFT_BYTES`, `MEMORY_INDEX_SOFT_LINES`, `MEMORY_INDEX_MAX_LINE`.

Registration is part of the self-heal: `lb_reconcile_claude_hooks` merges each `LB_CLAUDE_HOOKS` entry into `~/.claude/settings.json` with jq when missing (idempotent, never removes), on every sync run and in a full `install.sh`. `--check` only reports.

## First pass, 2026-10-01

Before 26.6 KB / 130 lines / 97 entries → after 14.4 KB / 98 lines / 73 entries, all ≤200 chars; 12 closed items moved to the catalog; the 17 dated star-trek session lines moved verbatim to `archive/strek-sessions.md` with `project_strek-current.md` as the single START pointer; the three inline header blocks became topic files; the missing `feedback_no_default_flipping.md` was reconstructed from the 2026-09-05 conversation log. Details: `memory/archive/consolidation-log.md`.
