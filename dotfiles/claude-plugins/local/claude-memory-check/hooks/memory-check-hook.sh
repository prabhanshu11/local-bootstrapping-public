#!/bin/bash
# Memory Check PreToolUse Hook
# Runs before Bash commands to check memory usage and enforce limits

set -euo pipefail

# Get skill directory (absolute path to claude-memory-manager skill)
SKILL_DIR="$HOME/.claude/skills/claude-memory-manager"

# Source utilities
source "$SKILL_DIR/lib/memory-utils.sh"

# Thresholds from memory-utils
# WARN_THRESHOLD_MB=4000
# CRITICAL_THRESHOLD_MB=8000
# RATE_THRESHOLD_MB_MIN=250

# Session-specific low-memory mode flag directory
LOW_MEMORY_FLAG_DIR="/var/log/claude-memory/low-memory-mode"

# Debug logging
DEBUG_LOG="/tmp/memory-check-hook-debug.log"
debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DEBUG_LOG" 2>/dev/null || true
}

# Read input from stdin
read_hook_input() {
    # Read JSON from stdin
    local input
    input=$(cat)
    echo "$input"
}

# Check if low-memory mode is enabled for this session
is_low_memory_mode_enabled() {
    local session_id=$1

    if [[ ! -d "$LOW_MEMORY_FLAG_DIR" ]]; then
        return 1  # Not enabled
    fi

    # Check for flag file
    if [[ -f "$LOW_MEMORY_FLAG_DIR/$session_id" ]]; then
        return 0  # Enabled
    fi

    return 1  # Not enabled
}

# Enable low-memory mode for this session
enable_low_memory_mode() {
    local session_id=$1

    mkdir -p "$LOW_MEMORY_FLAG_DIR" 2>/dev/null || true
    touch "$LOW_MEMORY_FLAG_DIR/$session_id" 2>/dev/null || true

    debug_log "Low-memory mode enabled for session $session_id"
}

# Main hook logic
main() {
    # Read hook input
    local hook_input
    hook_input=$(read_hook_input)

    # Extract session ID and tool info
    local session_id
    session_id=$(echo "$hook_input" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

    local tool_name
    tool_name=$(echo "$hook_input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

    debug_log "Hook triggered for tool: $tool_name, session: $session_id"

    # Only check for Bash commands
    if [[ "$tool_name" != "Bash" ]]; then
        debug_log "Not a Bash command, allowing"
        exit 0  # Allow non-Bash tools
    fi

    # Get current memory usage
    local current_pid=$$
    local parent_pid
    parent_pid=$(get_claude_parent_pid "$current_pid")

    if [[ -z "$parent_pid" ]] || [[ "$parent_pid" == "0" ]]; then
        debug_log "Could not find Claude parent process, allowing"
        exit 0  # Allow if we can't find parent
    fi

    debug_log "Found Claude PID: $parent_pid"

    # Get memory metrics
    local rss_kb
    rss_kb=$(get_process_tree_memory "$parent_pid")
    local rss_mb=$((rss_kb / 1024))

    debug_log "Current memory usage: ${rss_mb} MB"

    # Check threshold
    local threshold_status
    threshold_status=$(check_threshold "$rss_mb")
    local threshold_code=$?

    debug_log "Threshold status: $threshold_status (code: $threshold_code)"

    # Check for low-memory mode
    local low_memory_enabled=false
    if is_low_memory_mode_enabled "$session_id"; then
        low_memory_enabled=true
        debug_log "Low-memory mode is enabled for this session"
    fi

    # PRIORITY 1: Check system-wide RAM (only block at 90%+ system RAM)
    # This is the ONLY condition that should block execution
    local system_ram_percent
    system_ram_percent=$(get_system_ram_percent)
    local system_ram_status
    system_ram_status=$(get_system_ram_status)

    debug_log "System RAM: ${system_ram_percent}%"

    if is_system_ram_critical; then
        # System RAM is critical (90%+) - BLOCK
        cat >&2 <<EOF
🚨 SYSTEM RAM CRITICAL: ${system_ram_status}

This Bash command has been BLOCKED because system RAM exceeds 90%.
This is a last-resort protection to prevent system freeze/crash.

Recommended actions:
1. Kill child processes: claude memory kill-children
2. Check what's using memory: claude memory check
3. Close other applications
4. Restart session if needed: claude memory restart

Note: Claude is using ${rss_mb} MB
EOF
        debug_log "BLOCKING: System RAM at ${system_ram_percent}% (threshold: ${SYSTEM_RAM_CRITICAL_PERCENT}%)"
        exit 2  # Block execution
    fi

    # System RAM is OK - allow execution with appropriate messaging
    # (Claude-specific thresholds are now informational only, not blocking)

    case "$threshold_code" in
        2)  # Claude memory high (>8GB) but system RAM OK - ALLOW with info
            debug_log "Claude memory high (${rss_mb}MB) but system RAM OK (${system_ram_percent}%), allowing"

            # Show info but don't block
            cat >&2 <<EOF
ℹ️  Claude memory high: ${rss_mb} MB (system RAM: ${system_ram_percent}% - OK)
System has sufficient memory. Execution allowed.

Tip: Consider killing child processes if memory keeps growing.
EOF
            exit 0  # Allow - system RAM is OK
            ;;

        1)  # WARNING (>4GB)
            # Auto-enable low-memory mode if high growth rate
            if [[ "$low_memory_enabled" != "true" ]]; then
                # Check growth rate from latest metric
                local rate_mb_min
                rate_mb_min=$(get_latest_growth_rate "$parent_pid")

                if (( $(awk "BEGIN {print ($rate_mb_min >= $RATE_THRESHOLD_MB_MIN)}") )); then
                    enable_low_memory_mode "$session_id"
                    low_memory_enabled=true

                    cat >&2 <<EOF
⚠️  High memory growth detected (${rate_mb_min} MB/min)
Low-memory mode has been automatically enabled for this session.

Current usage: ${rss_mb} MB | System RAM: ${system_ram_percent}%
EOF
                    debug_log "Auto-enabled low-memory mode due to high growth rate"
                fi
            fi

            debug_log "WARNING: allowing (system RAM ${system_ram_percent}% OK)"
            exit 0  # Allow
            ;;

        0)  # OK
            debug_log "Memory usage OK, allowing"

            # If low-memory mode enabled, show guidance
            if [[ "$low_memory_enabled" == "true" ]]; then
                cat >&2 <<EOF
ℹ️  Low-memory mode enabled (current: ${rss_mb} MB)
Prefer lightweight tools and avoid spawning multiple subprocesses.
EOF
            fi

            exit 0  # Allow
            ;;
    esac
}

# Helper function to get latest growth rate from metrics
get_latest_growth_rate() {
    local pid=$1
    local metrics_log="/var/log/claude-memory/metrics.jsonl"

    if [[ ! -f "$metrics_log" ]]; then
        echo "0"
        return
    fi

    # Get latest metric for this PID
    local rate
    rate=$(grep "\"pid\":$pid" "$metrics_log" 2>/dev/null | tail -1 | jq -r '.rate_mb_min // 0' 2>/dev/null || echo "0")

    echo "$rate"
}

# Helper function to find Claude parent process
get_claude_parent_pid() {
    local current=$1

    # Walk up the process tree to find claude
    local pid=$current
    local max_iterations=10
    local iterations=0

    while [[ $iterations -lt $max_iterations ]]; do
        local cmdline
        cmdline=$(ps -o comm= -p "$pid" 2>/dev/null || echo "")

        if [[ "$cmdline" == *"claude"* ]] && [[ "$cmdline" != *"hook"* ]]; then
            echo "$pid"
            return 0
        fi

        # Get parent
        local parent
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")

        if [[ "$parent" == "0" ]] || [[ "$parent" == "1" ]]; then
            break
        fi

        pid=$parent
        iterations=$((iterations + 1))
    done

    echo "0"
}

# Run main
main "$@"
