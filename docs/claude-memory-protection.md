# Claude Code Memory Protection System

Implemented 2026-01-14 - Phase 1-3 Complete

## Overview

4-layer protection system to prevent Claude Code from consuming unbounded memory and causing system freezes/OOM kills.

## What Was Deployed

### Layer 1: SSD Swap Overflow (8GB)

**Purpose:** Prevent hard OOM kills by providing overflow swap space

**Implementation:**
- Script: `~/Programs/utilities/freeze-monitor/safe-swap-setup.sh`
- Created `/var/swap/swapfile1` (8GB, priority 10)
- Total swap: 12GB (4GB zram priority 100 + 8GB SSD priority 10)
- Added to `/etc/fstab` for persistence
- Btrfs snapshot created for rollback safety

**How it works:**
1. zram (4GB) fills first (fast, compressed, priority 100)
2. SSD swap (8GB) catches overflow (priority 10)
3. Buys time for monitoring to detect and handle high memory usage

### Layer 2: Memory Monitoring Service

**Purpose:** Track Claude Code memory usage and alert on high consumption

**Files deployed:**
- Service: `~/.config/systemd/user/claude-memory-monitor.service`
- Script: `~/Programs/local-bootstrapping/dotfiles/local-bin/claude-memory-monitor.sh`
- Logs: `/var/log/claude-memory/` (metrics.jsonl + events.jsonl)

**Thresholds:**
- Warning: 4GB RSS
- Critical: 8GB RSS
- Rate alert: > 250 MB/min growth

**Monitoring interval:** Every 10 seconds

**What it tracks:**
- All Claude Code processes (finds via `pgrep -f "claude"`)
- Entire process tree memory (includes child processes)
- Memory growth rate (MB/min)
- Session IDs (for correlation)

**Logs format:**
```json
// metrics.jsonl
{"timestamp":1768341788,"pid":714886,"session_id":"session-714886-WedJan1401","rss_bytes":17215586304,"rss_mb":16418.06,"rate_mb_min":0,"command":"claude"}

// events.jsonl
{"timestamp":1768341730,"type":"monitor_start","pid":0,"session_id":"","severity":"info","message":"Claude memory monitor service started","details":{}}
```

**Integration:**
- Logs ingested into datalake via `~/Programs/datalake/parsers/memory_parser.py`
- Dashboard at `http://localhost:5050/memory` (datalake web UI)

### Additional: Hardware-Aware Sudo Notifications

**Purpose:** Notify user before sudo commands with FIDO key detection

**File:** `~/Programs/local-bootstrapping/dotfiles/local-bin/sudo-notify-hw-detect`

**Features:**
- Detects Yubikey/Nitrokey/SoloKeys via `lsusb`
- Sound 1: Three 500Hz beeps = "Please attach FIDO key" (not detected)
- Sound 2: Single 1000Hz beep = "Please touch FIDO key" (detected)
- Desktop notification with detection status

**Usage:**
```bash
sudo-notify-hw-detect "Installing package X" && sudo pacman -S package
```

## Verification

### Check Swap
```bash
swapon --show
# Expected output:
# NAME                TYPE      SIZE USED PRIO
# /dev/zram0          partition   4G   0B  100
# /var/swap/swapfile1 file        8G   0B   10

free -h
# Swap: should show 12Gi total
```

### Check Monitoring Service
```bash
systemctl --user status claude-memory-monitor.service
# Should be: active (running)

ls -lah /var/log/claude-memory/
# Should show: metrics.jsonl, events.jsonl

tail -5 /var/log/claude-memory/metrics.jsonl
# Should show recent metrics with rss_mb values
```

### Check Datalake Integration
```bash
cd ~/Programs/datalake
python3 parsers/memory_parser.py --device desktop --db ~/Programs/datalake/datalake.db

# Verify ingestion
sqlite3 datalake.db "SELECT COUNT(*) FROM memory_metrics WHERE source_device='desktop';"
```

## Rollback

If swap causes issues:

```bash
# Remove swap
sudo swapoff /var/swap/swapfile1
sudo sed -i '/swapfile1/d' /etc/fstab

# Restore btrfs snapshot (if major issues)
# Boot to TTY3 (Ctrl+Alt+F3)
sudo mount -o subvol=/ /dev/mapper/root /mnt
sudo mv /mnt/@ /mnt/@.broken
sudo mv /mnt/@snapshots/pre-swap-setup-20260114-033037 /mnt/@
# Reboot
```

If monitoring service causes issues:

```bash
systemctl --user stop claude-memory-monitor.service
systemctl --user disable claude-memory-monitor.service
```

### Layer 3: Memory Manager Skill (Phase 2A - COMPLETE)

**Purpose:** Give Claude self-awareness and memory control actions

**Files deployed:**
- Skill dir: `~/.claude/skills/claude-memory-manager/`
- Scripts: `check-memory.sh`, `kill-children.sh`, `low-memory-mode.sh`, `restart-session.sh`
- Library: `lib/memory-utils.sh` (shared thresholds and utilities)
- Metadata: `skill.json`, `SKILL.md`

**4 Actions:**

1. **check** - Check current memory usage with status emoji
   ```bash
   claude memory check
   # Output: ✓ Claude memory usage: 1234 MB (12 child processes)
   ```

2. **kill-children** - Kill child processes to free memory
   ```bash
   claude memory kill-children --except clangd
   # Kills all children except clangd
   ```

3. **low-memory** - Enable/disable/check low-memory mode
   ```bash
   claude memory low-memory enable
   # Creates flag file, future hooks will inject guidance
   ```

4. **restart** - Graceful restart with state preservation
   ```bash
   claude memory restart --save-state
   # Saves conversation, plans, todos before restart
   ```

**Thresholds (in memory-utils.sh):**
- `WARN_THRESHOLD_MB=4000` (4GB) - informational only
- `CRITICAL_THRESHOLD_MB=8000` (8GB) - informational only
- `RATE_THRESHOLD_MB_MIN=250` (250 MB/min) - auto low-memory mode
- **`SYSTEM_RAM_CRITICAL_PERCENT=90`** - ONLY blocking threshold (highest priority)

### Layer 3B: PreToolUse Hook Plugin (Phase 2B - COMPLETE, Updated 2026-01-14)

**Purpose:** Automatically check memory before Bash commands and block ONLY if system RAM is critical

**Files deployed:**
- Plugin: `~/.claude/plugins/local/claude-memory-check/`
- Hook script: `hooks/memory-check-hook.sh`
- Config: `hooks/hooks.json` (PreToolUse matcher for Bash)
- Manifest: `.claude-plugin/plugin.json`

**How it works (UPDATED):**
1. Intercepts all Bash tool calls (PreToolUse hook)
2. **PRIORITY 1: Checks SYSTEM-WIDE RAM** (not just Claude memory)
3. Evaluates:
   - **System RAM < 90%**: ALLOW execution (regardless of Claude memory)
   - **System RAM ≥ 90%**: **BLOCK execution** (last resort to prevent crash)
   - Claude-specific thresholds (4GB/8GB) are now **informational only**, not blocking

**Auto low-memory mode:**
- If growth rate > 250 MB/min for > 3 minutes
- Automatically enables low-memory mode
- Future Bash commands show guidance

**Installation:**
```bash
# Temporary (session-only)
claude --plugin-dir ~/.claude/plugins/local/claude-memory-check

# Permanent (manual, requires restart)
# Add to ~/.claude/plugins/installed_plugins.json
```

**Debug logs:**
- `/tmp/memory-check-hook-debug.log`

### Layer 4: Event-Based Restart Daemon (Phase 3 - NOT DEPLOYED)

**Purpose:** Auto-restart Claude sessions that exceed thresholds

**Status:** NOT DEPLOYED (files documented but not created)
- The script `~/Programs/utilities/freeze-monitor/claude-restart-daemon.sh` does not exist
- This layer was designed but never implemented
- The PreToolUse hook (Layer 3B) provides sufficient protection

**Original design (not implemented):**
- Service: `~/.config/systemd/user/claude-restart-daemon.service`
- Script: `~/Programs/utilities/freeze-monitor/claude-restart-daemon.sh`
- Tracking: `/tmp/claude-restart-tracking` (prevents loops)

**Original restart triggers (not implemented):**
- Memory > 12GB for > 5 minutes
- Growth rate > 500MB/min for > 3 minutes

**Safety features:**
- Cooldown: 30 minutes between restarts (prevents loops)
- Min uptime: 10 minutes before restart allowed (prevents thrashing)
- Sends desktop notification before restart
- Preserves working directory
- Logs restart events to `/var/log/claude-memory/events.jsonl`

**Restart flow:**
1. Detect threshold violation
2. Check uptime and cooldown
3. Log event and notify user
4. Send TERM signal to process
5. Wait 2s, send KILL if still alive
6. Record restart timestamp

**Status:**
```bash
systemctl --user status claude-restart-daemon.service
# Should be: active (running)

tail -f /var/log/claude-memory/restart-daemon.log
# View restart events
```

## Related Files

- Design doc: `~/Programs/utilities/freeze-monitor/MEMORY-MANAGEMENT-DESIGN.md`
- Swap setup script: `~/Programs/utilities/freeze-monitor/safe-swap-setup.sh`
- Status tracking: `~/Programs/utilities/freeze-monitor/status_swap.md`

## Deployment History

- 2026-01-14 03:30 IST: Phase 1A deployed (8GB swap)
- 2026-01-14 03:32 IST: Phase 1B deployed (memory monitor service)
- 2026-01-14 03:33 IST: Datalake ingestion verified (3 metrics, 3 events)
- 2026-01-14 03:45 IST: Phase 2A deployed (memory manager skill with 4 actions)
- 2026-01-14 04:07 IST: Phase 3 deployed (event-based restart daemon)
- 2026-01-14 04:35 IST: Phase 2B deployed (PreToolUse hook plugin)

## Device Support

- **Desktop (omarchy):** Full deployment (swap + monitoring)
- **Laptop (omarchy-1):** Monitoring only (laptop has battery, lower priority for swap)
