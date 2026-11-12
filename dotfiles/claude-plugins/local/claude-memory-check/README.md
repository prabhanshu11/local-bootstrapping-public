# Claude Memory Check Plugin

## Overview

A PreToolUse hook plugin that automatically monitors memory usage before executing Bash commands to prevent Claude Code from consuming excessive RAM and freezing the system.

## How It Works

This plugin hooks into Claude Code's PreToolUse event for all Bash tool calls. Before each Bash command execution, it:

1. **Checks current memory usage** of the Claude Code process tree
2. **Evaluates thresholds:**
   - **OK** (< 4GB): Allow execution, show low-memory mode guidance if enabled
   - **WARNING** (4-8GB): Allow with warning, auto-enable low-memory mode if high growth rate (> 250 MB/min)
   - **CRITICAL** (> 8GB): **BLOCK execution** to prevent system freeze

3. **Auto-manages low-memory mode** based on memory growth rate patterns

## Thresholds

Defined in `~/.claude/skills/claude-memory-manager/lib/memory-utils.sh`:
- `WARN_THRESHOLD_MB=4000` (4GB)
- `CRITICAL_THRESHOLD_MB=8000` (8GB)
- `RATE_THRESHOLD_MB_MIN=250` (250 MB/min growth rate)

## Integration with Memory Manager Skill

This plugin integrates with the `claude-memory-manager` skill:
- Uses shared utilities from `~/.claude/skills/claude-memory-manager/lib/memory-utils.sh`
- Reads metrics from `/var/log/claude-memory/metrics.jsonl`
- Manages low-memory mode flags in `/var/log/claude-memory/low-memory-mode/`

## Installation

### Temporary (Session-Only)

Load the plugin for a single session:

```bash
claude --plugin-dir ~/.claude/plugins/local/claude-memory-check
```

### Permanent (Manual Installation)

Add to `~/.claude/plugins/installed_plugins.json`:

```json
{
  "version": 2,
  "plugins": {
    "claude-memory-check@local": [
      {
        "scope": "user",
        "installPath": "/home/prabhanshu/.claude/plugins/local/claude-memory-check",
        "version": "1.0.0",
        "installedAt": "2026-01-14T00:00:00.000Z",
        "lastUpdated": "2026-01-14T00:00:00.000Z"
      }
    ]
  }
}
```

Then restart Claude Code.

## Hook Behavior Examples

### Critical Memory (>8GB) - Blocks Execution

```
⚠️  MEMORY CRITICAL: Claude is using 9234 MB (8000 MB limit exceeded)

This Bash command has been BLOCKED to prevent system freeze.

Recommended actions:
1. Kill child processes: claude memory kill-children
2. Check what's using memory: claude memory check
3. Restart session: claude memory restart

To override this block (not recommended), disable the memory check hook.
```

### Warning (4-8GB) - Allows with Caution

```
⚠️  Memory usage elevated: 5120 MB (warning threshold: 4000 MB)

Consider enabling low-memory mode: claude memory low-memory enable
```

### Auto Low-Memory Mode Activation

```
⚠️  High memory growth detected (320 MB/min)
Low-memory mode has been automatically enabled for this session.

Current usage: 4980 MB
```

### Low-Memory Mode Guidance

```
ℹ️  Low-memory mode enabled (current: 3200 MB)
Prefer lightweight tools and avoid spawning multiple subprocesses.
```

## Debugging

Hook debug logs are written to:
- `/tmp/memory-check-hook-debug.log`

View logs:
```bash
tail -f /tmp/memory-check-hook-debug.log
```

## Disabling the Hook

### Temporary (Session)
Don't load the plugin when starting Claude Code.

### Permanent
Remove from `installed_plugins.json` or disable via:
```bash
claude plugin disable claude-memory-check@local
```

## Files

```
~/.claude/plugins/local/claude-memory-check/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   ├── hooks.json               # Hook configuration
│   └── memory-check-hook.sh     # Hook script (PreToolUse)
└── README.md                    # This file
```

## Dependencies

- `claude-memory-manager` skill (must be installed)
- `claude-memory-monitor.service` (should be running for growth rate detection)
- `jq` (for JSON parsing)
- `ps`, `awk` (standard Unix tools)

## Version

1.0.0 (2026-01-14)

## Author

main1 (you@example.com)

## License

Part of local-bootstrapping system for Omarchy machines.
