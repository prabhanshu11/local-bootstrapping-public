---
name: debug-with-logging
description: Diagnose "works manually but fails via automation" issues by adding logging. Use when keybindings fail silently, systemd services don't work, cron jobs miss, or any command works in terminal but not when automated. Reveals PATH, environment, and permission issues.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
---

# Debug with Logging Skill

When a command works manually but fails silently when triggered by keybindings, systemd services, or other automation - add logging to reveal the root cause.

## When to Use This Skill

Use this skill when encountering these symptoms:
- "Command works in terminal but not via keyboard shortcut"
- "Script runs fine manually but fails when automated"
- Keybinding triggers (notification shows) but nothing happens
- Systemd service shows "active" but doesn't work
- Cron job doesn't execute expected action
- Hyprland/i3/other WM bindings fail silently

**Key indicator:** User says "it works when I run it manually"

## Common Root Causes (Revealed by Logging)

### 1. PATH Issues
**Symptom:** `command not found` in logs
**Cause:** `~/.local/bin`, `/usr/local/bin` not in PATH when automation runs
**Fix:** Use full paths (`~/.local/bin/script` instead of `script`)

**Case Study: Moonlight Streaming (2026-01-10)**
- Binding triggered (notification showed)
- Moonlight didn't launch
- Log revealed: `/bin/sh: line 1: moonlight-toggle: command not found`
- Solution: Changed `moonlight-toggle` to `~/.local/bin/moonlight-toggle`

### 2. Environment Variables Missing
**Symptom:** Script fails with "variable not set" or uses wrong values
**Cause:** `$HOME`, `$USER`, `$DISPLAY`, `$WAYLAND_DISPLAY` not available
**Fix:** Source environment file or use absolute paths

### 3. Working Directory Wrong
**Symptom:** "File not found" for relative paths
**Cause:** Automation runs from `/` or unexpected directory
**Fix:** Use `cd` before commands or absolute paths

### 4. Permissions Issues
**Symptom:** "Permission denied" in logs
**Cause:** Script not executable, wrong file ownership
**Fix:** `chmod +x script` or fix ownership

## How It Works

### Step 1: Add Event Logging
Log when the trigger fires (before executing command):
```bash
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Event: Command triggered" >> ~/logs/events.log
```

### Step 2: Redirect Command Output
Capture stdout and stderr from the actual command:
```bash
command >> ~/logs/output.log 2>&1
```

### Step 3: Combine in Automation
**Hyprland example:**
```bash
bindd = SUPER SHIFT, S, Launch App, exec, \
  echo "[$(date)] Super+Shift+S pressed" >> ~/logs/events.log && \
  ~/.local/bin/mycommand >> ~/logs/output.log 2>&1
```

**Systemd example:**
```ini
[Service]
ExecStartPre=/bin/sh -c 'echo "Service starting at $(date)" >> /var/log/myservice/events.log'
ExecStart=/usr/local/bin/mycommand
StandardOutput=append:/var/log/myservice/output.log
StandardError=append:/var/log/myservice/output.log
```

### Step 4: Test and Read Logs
```bash
# Trigger the automation (press keybinding, start service, etc.)

# Check event log (did trigger fire?)
tail -f ~/logs/events.log

# Check output log (what happened?)
tail -f ~/logs/output.log
```

## Logging Structure Best Practices

### Directory Organization
```
~/Programs/project-name/logs/
├── .gitignore          # Ignore *.log files
├── README.md           # Document log files and formats
├── events.log          # High-level triggers (keybinds, service starts)
└── output.log          # Command stdout/stderr (verbose)
```

### Log Format Standards

**events.log** - Structured, one line per event:
```
[YYYY-MM-DD HH:MM:SS] EventName: Description
[2026-01-10 23:32:48] Super+Shift+S: Launching moonlight-toggle
[2026-01-10 23:33:12] Super+Escape: Exiting streaming submap
```

**output.log** - Raw command output (can be verbose):
```
Moonlight 5.0.1 starting...
SDL Info: Using Wayland
Connected to 100.64.0.1
...
```

### .gitignore Template
```gitignore
# Ignore all log files
*.log

# Keep directory structure
!.gitignore
!README.md
```

## Output Format

When logging reveals an issue, present:

1. **Root Cause Identified**
   ```
   Found: /bin/sh: line 1: command-name: command not found
   ```

2. **Why It Failed**
   ```
   Hyprland executes bindings with minimal PATH (/usr/bin:/bin)
   Your command is in ~/.local/bin, which isn't included
   ```

3. **Solution**
   ```
   Change:  bindd = SUPER, S, exec, command-name
   To:      bindd = SUPER, S, exec, ~/.local/bin/command-name
   ```

4. **Verification**
   ```bash
   # Test the fix
   tail -f ~/logs/output.log
   # Press keybinding again
   # Should see command output instead of "command not found"
   ```

## Common Logging Patterns

### Pattern 1: Keybinding Automation (Hyprland/i3)
```bash
# In bindings config
bind = MOD, KEY, exec, \
  echo "[$(date)] Keybind triggered" >> ~/logs/events.log && \
  /full/path/to/command arg1 arg2 >> ~/logs/output.log 2>&1
```

### Pattern 2: Systemd Service
```ini
[Service]
StandardOutput=append:/var/log/myservice/output.log
StandardError=append:/var/log/myservice/error.log
ExecStartPre=/bin/sh -c 'echo "Starting at $(date)" >> /var/log/myservice/events.log'
```

### Pattern 3: Cron Job
```cron
*/5 * * * * echo "[$(date)] Cron job started" >> /home/user/logs/events.log && /full/path/to/script >> /home/user/logs/output.log 2>&1
```

### Pattern 4: Shell Script Debugging
```bash
#!/bin/bash
# Enable verbose logging
set -x  # Print each command before executing
exec 2>> /tmp/script-debug.log  # Redirect all stderr to log

# Your script here
```

## Case Studies

### Case 1: Moonlight Streaming Keybinding (2026-01-10)

**Problem:**
- `Super+Shift+S` notification appeared
- Moonlight window never launched
- Manual `moonlight-toggle` worked fine

**Logging Added:**
```bash
bindd = SUPER SHIFT, S, exec, \
  echo "[$(date)] Super+Shift+S pressed" >> ~/logs/events.log && \
  moonlight-toggle >> ~/logs/output.log 2>&1
```

**Log Output Revealed:**
```
[2026-01-10 23:32:48] Super+Shift+S pressed
/bin/sh: line 1: moonlight-toggle: command not found
```

**Root Cause:** PATH didn't include `~/.local/bin`

**Solution:** Changed to `~/.local/bin/moonlight-toggle`

**Outcome:** Moonlight launched successfully

### Case 2: [Template for Future Cases]

**Problem:** [Describe the symptom]

**Logging Added:** [Show code]

**Log Output Revealed:** [Show error]

**Root Cause:** [Explain]

**Solution:** [Show fix]

**Outcome:** [Result]

## Integration with CLAUDE.md

When debugging automation issues, follow this workflow:

1. **Reproduce manually** - Verify command works in terminal
2. **Add logging** (use this skill)
3. **Trigger automation** - Press keybind, start service, etc.
4. **Read logs** - Find the actual error
5. **Fix root cause** - Usually PATH, environment, or permissions
6. **Verify** - Check logs show success
7. **Document** - Add case study to this skill

## When NOT to Use This Skill

Don't add logging if:
- Command fails even when run manually (not an automation issue)
- Error is already visible (not silent failure)
- It's a one-time debug (logging is for recurring/hard-to-reproduce issues)

## Best Practices

1. **Log directory in repo** - `~/Programs/project/logs/` so it's tracked
2. **Ignore log files in git** - Use `.gitignore` to exclude `*.log`
3. **Document log files** - Create `logs/README.md` explaining format
4. **Structured events** - Use consistent timestamp format `[YYYY-MM-DD HH:MM:SS]`
5. **Separate event/output logs** - Don't mix triggers with verbose command output
6. **Full paths** - Always use absolute paths in automation
7. **Keep case studies** - Add successful debugging sessions to this skill

## Learn More

- [Systemd Logging](https://www.freedesktop.org/software/systemd/man/systemd.exec.html#StandardOutput=)
- [Hyprland Binds](https://wiki.hypr.land/Configuring/Binds/)
- [Debugging Bash Scripts](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html)
