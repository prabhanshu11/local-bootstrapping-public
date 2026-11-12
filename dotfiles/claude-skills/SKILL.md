# Claude Memory Manager Skill

**Version:** 1.0.0
**Author:** main1
**Created:** 2026-01-14

## Purpose

Provides Claude Code with **self-awareness and control** over memory usage to prevent OOM kills and system freezes.

## What This Skill Does

Gives Claude 4 memory management actions:

1. **Check Memory** - See current RAM usage and growth rate
2. **Kill Children** - Terminate child processes to free memory
3. **Low-Memory Mode** - Enable guidance to conserve memory
4. **Restart Session** - Gracefully restart with state preservation

## When to Invoke

**Automatic (via PreToolUse hooks - Phase 2B):**
- Before running bash commands that spawn processes
- When memory > 4GB (warning threshold)
- When memory growth rate > 250 MB/min

**Manual (user can run):**
- `/memory` - Check current memory usage
- User types: "I think memory is getting high, can you check?"

## Actions

### 1. Check Memory

**Command:** `check-memory`

**What it does:**
- Reads `/var/log/claude-memory/metrics.jsonl` for this session
- Shows: Current RSS, peak RSS, growth rate, child processes
- Compares against thresholds (4GB warn, 8GB critical)

**Output example:**
```
Memory Status for PID 714886:
  Current: 2.3 GB
  Peak: 3.1 GB (15 minutes ago)
  Growth rate: 45 MB/min
  Child processes: 3 (clangd, bash, grep)
  Status: ✅ Normal (below 4GB warning threshold)
```

### 2. Kill Children

**Command:** `kill-children [--except clangd]`

**What it does:**
- Lists all child processes
- Kills processes (except those in --except list)
- Reports memory freed

**Safety:**
- Never kills the main Claude process
- Preserves essential children (clangd for IDE features)
- Asks for confirmation if >5 children

**Output example:**
```
Killing child processes...
  ✓ Killed bash (PID 12345) - freed 15 MB
  ✓ Killed grep (PID 12346) - freed 2 MB
  ⊘ Preserved clangd (PID 12340) - essential for IDE
Total freed: 17 MB
New total: 2.3 GB → 2.28 GB
```

### 3. Low-Memory Mode

**Command:** `enable-low-memory-mode` / `disable-low-memory-mode`

**What it does:**
- Creates `/var/log/claude-memory/low-memory-mode/$PID`
- Hook reads this and injects guidance into conversation
- Tells Claude to:
  - Avoid spawning parallel agents
  - Use lightweight commands
  - Minimize context retention
  - Suggest user restart session soon

**Guidance injected (example):**
```
⚠️ LOW MEMORY MODE ACTIVE
Current usage: 6.5 GB

Please:
- Avoid Task tool with multiple agents
- Use grep/awk instead of loading large files
- Minimize bash commands that spawn children
- Consider restarting session after current task

This mode will auto-disable when memory drops below 3GB.
```

### 4. Restart Session

**Command:** `restart-session [--save-state]`

**What it does:**
- Saves current plan file (if exists)
- Saves conversation summary
- Prints resume command for user
- Exits gracefully (systemd will restart if configured)

**With --save-state:**
```bash
# Saves to ~/.claude/restart-state/$PID/
plan.md              # Current plan
conversation.txt     # Last 20 messages
resume.txt           # Command to resume
```

**Output example:**
```
Preparing to restart session...
  ✓ Saved plan to ~/.claude/restart-state/714886/plan.md
  ✓ Saved conversation context (20 messages)

To resume this work, run:
  claude --resume ~/.claude/restart-state/714886/

Restarting in 3 seconds...
```

## Integration with Hooks (Phase 2B)

**PreToolUse hook** will call `check-memory` and:
- If memory > 8GB (critical): **BLOCK** tool execution, suggest `kill-children`
- If memory > 4GB (warning): **WARN** but allow, suggest `low-memory-mode`
- If growth rate > 250 MB/min: **WARN** and enable low-memory mode automatically

## Files Created

```
~/.claude/skills/claude-memory-manager/
├── SKILL.md                    # This file
├── check-memory.sh             # Action 1
├── kill-children.sh            # Action 2
├── low-memory-mode.sh          # Action 3
├── restart-session.sh          # Action 4
└── lib/
    ├── memory-utils.sh         # Shared functions
    └── session-state.sh        # State saving logic
```

## Usage Examples

**User invokes manually:**
```
User: "Can you check how much memory you're using?"
Claude: [Runs /memory skill]
        "I'm currently using 3.2 GB, which is normal. Peak was 3.8 GB
        an hour ago when we were running parallel tests."
```

**Hook invokes automatically:**
```
Claude: [About to run: bash -c "npm run build"]
Hook: check-memory → 7.5 GB (warning threshold exceeded)
Claude: ⚠️ Warning: I'm using 7.5 GB RAM (above 4GB warning threshold).

        Before running npm build (which may use more memory), would you like me to:
        1. Free memory by killing unused child processes
        2. Enable low-memory mode
        3. Proceed anyway (we have 8GB SSD swap as backup)

        What would you prefer?
```

## Configuration

**Thresholds (in memory-utils.sh):**
```bash
WARN_THRESHOLD_MB=4000      # 4 GB
CRITICAL_THRESHOLD_MB=8000  # 8 GB
RATE_THRESHOLD_MB_MIN=250   # 250 MB/min
```

**Low-memory mode triggers:**
```bash
ENABLE_AT_MB=6000           # Enable at 6 GB
DISABLE_AT_MB=3000          # Disable below 3 GB
```

## Testing

**Test check-memory:**
```bash
~/.claude/skills/claude-memory-manager/check-memory.sh $$
```

**Test kill-children (dry-run):**
```bash
~/.claude/skills/claude-memory-manager/kill-children.sh --dry-run
```

**Test low-memory mode:**
```bash
~/.claude/skills/claude-memory-manager/low-memory-mode.sh enable
cat /var/log/claude-memory/low-memory-mode/$$
```

## Rollback

To disable this skill:
```bash
mv ~/.claude/skills/claude-memory-manager \
   ~/.claude/skills/claude-memory-manager.disabled
```

Hooks will no longer trigger memory checks.

## Future Enhancements (Phase 3+)

- Automatic restart when memory > 12GB for > 5 minutes
- Integration with datalake dashboard (show memory graph inline)
- Machine learning to predict memory growth patterns
- Proactive warnings before memory-intensive operations
