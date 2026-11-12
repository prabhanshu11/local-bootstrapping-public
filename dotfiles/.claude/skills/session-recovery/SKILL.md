---
name: session-recovery
description: Recover context from a crashed, corrupted, or API-errored Claude session. Use when user says "recover session", "crashed session", "continue from crashed", "API error session", "pick up where we left off", or provides a text fragment from a dead conversation.
allowed-tools:
  - Bash
  - Grep
  - Read
  - Glob
  - AskUserQuestion
  - EnterPlanMode
---

# Session Recovery Skill

Recovers context from a session that died (API error, context overflow, crash) and helps the user resume work with a plan.

## When This Triggers

- User says "recover", "crashed session", "pick up from dead session"
- User pastes a text fragment from a broken conversation
- User says "continue the work from [topic]" after a reboot/crash

## Common API Error Patterns

When searching for a crashed session, include these error terms as OR alternatives in your search query. These are the strings that appear in sessions that died from API/infrastructure errors:

```
Unexpected non-2xx response
overloaded_error
context_length_exceeded
rate_limit_error
internal_server_error
Could not process your request
The model's maximum context length
Request too large
```

**Example compound search:**
```bash
find-conversations "UI-agent OR YOLO OR blob OR Unexpected OR context_length" --limit 10
```

## Recovery Steps

### Step 1: Get a search anchor from the user

If the user already provided text or a topic, use that. Otherwise ask:

```
What was the session about? Provide either:
- A few words describing the topic
- A text fragment from the conversation
- The session UUID if you have it
```

### Step 2: Find and summarize the session

**If user provides a UUID directly:**
```bash
summarize-session --refresh UUID
```

**If searching by topic — ONE search call with error patterns included:**
```bash
find-conversations "keyword1 OR keyword2 OR keyword3 OR Unexpected OR context_length" --limit 10
```

Extract ALL relevant keywords from the user's description (aim for 5-10 terms with OR), plus 1-2 error pattern terms.

Present the top matches and ask the user to confirm which session.

### Step 3: Get the session summary (NOT raw messages)

Use `summarize-session` instead of raw `get-messages-from-current` — it returns a context-efficient summary that won't overflow the recovery session:

```bash
# Preferred: AI-summarized, cached, with timestamps and navigation
summarize-session UUID

# If you also need the previous session for continuity:
summarize-session --include-previous 2

# Only use --full when the user explicitly wants raw messages:
summarize-session UUID --full
```

**Do NOT** use `get-messages-from-current --last 50` for recovery — that dumps raw text which can itself cause context overflow. Use `summarize-session` which handles short/long sessions appropriately.

### Step 4: Find and read any plan files

Check for plan files that were active in that session:

```bash
# List recent plan files
ls -lt ~/.claude/plans/ | head -10
```

Read any plan files that match the topic (by name or timestamp).

Also check for progress files in the project:

```bash
# Check for progress tracking files
cat progress_actual.md 2>/dev/null
cat docs/backlog.md 2>/dev/null
```

### Step 5: Present recovery summary

All outputs should include timestamps for temporal awareness:

```
## Session Recovery: [Topic]

**Original Session:** UUID
**Date:** YYYY-MM-DD HH:MM
**Last Activity:** HH:MM (duration: ~Xh Ym)
**Project:** /path/to/project
**Status when it died:** [what was happening]

### What was accomplished
- [completed items from the conversation]

### What was in progress
- [incomplete work, partially done tasks]

### Active plan
- [plan file contents or summary]

### Uncommitted work
[Check git status in the project dir to see if there are uncommitted changes from the dead session]
```

### Step 6: Ask the user what direction to take

Use AskUserQuestion with options based on what you found:

- Continue implementing the existing plan from where it stopped
- Revise the plan based on what happened
- Start fresh with a new approach
- Just summarize what happened (no further action)

### Step 7: Create a plan

Based on the user's choice, enter plan mode and create an implementation plan that:
- References what was already done (don't redo completed work)
- Picks up from the exact point of failure
- Accounts for any uncommitted changes that may exist

## Important Notes

- **Budget:** This skill gets MORE budget than conversation-recall because recovery needs thorough reading. Up to 6 tool calls allowed.
- **Use summarize-session:** Always prefer `summarize-session UUID` over raw message dumps. It handles short sessions (returns messages directly) and long sessions (AI summary + cache) automatically.
- **Timestamps everywhere:** All message outputs and summaries should include `[HH:MM]` timestamps so the recovery agent understands the work timeline.
- **Git check:** Always `git status` and `git log --oneline -5` in the project directory to find uncommitted work from the crashed session.
- **Don't assume:** The crashed session may have made partial changes. Verify file state before planning.
- **Plan files persist:** Check `~/.claude/plans/` — the plan from the crashed session is likely still there.

## Example Flow

User: "recover my UI-agent session that crashed"

```
Turn 1: find-conversations "UI-agent OR YOLO OR blob OR cursor OR detection OR Unexpected OR context_length" --limit 10
→ Found 3 matches, present to user

Turn 2: User confirms session UUID
→ summarize-session UUID

Turn 3: Check plan files and git status
→ ls -lt ~/.claude/plans/ | head -10
→ cd /path/to/project && git status && git log --oneline -5

Turn 4: Present recovery summary with timestamps
→ AskUserQuestion: Continue plan? Revise? New approach?

Turn 5: User picks direction
→ EnterPlanMode with context from recovery
```
