#!/bin/bash
# Memory utility functions for Claude memory manager skill

set -euo pipefail

# Configuration
WARN_THRESHOLD_MB=4000
CRITICAL_THRESHOLD_MB=8000
RATE_THRESHOLD_MB_MIN=250
METRICS_LOG="/var/log/claude-memory/metrics.jsonl"
EVENTS_LOG="/var/log/claude-memory/events.jsonl"

# System-wide RAM thresholds (highest priority)
# Only terminate/block when system RAM exceeds these
SYSTEM_RAM_CRITICAL_PERCENT=90  # Block Claude at 90%+ system RAM

# Get system-wide RAM usage percentage
get_system_ram_percent() {
    local mem_percent=$(free | awk 'NR==2 {printf "%.0f", ($2-$7)/$2*100}')
    echo "$mem_percent"
}

# Check if system RAM is critical (90%+)
is_system_ram_critical() {
    local current_percent=$(get_system_ram_percent)
    if [[ "$current_percent" =~ ^[0-9]+$ ]] && [[ $current_percent -ge $SYSTEM_RAM_CRITICAL_PERCENT ]]; then
        return 0  # Critical
    fi
    return 1  # OK
}

# Get system RAM status for display
get_system_ram_status() {
    local percent=$(get_system_ram_percent)
    local total_gb=$(free -g | awk 'NR==2 {print $2}')
    local available_gb=$(free -g | awk 'NR==2 {print $7}')
    echo "${percent}% used (${available_gb}GB available of ${total_gb}GB)"
}

# Get current memory usage for a PID
get_current_memory() {
    local pid=${1:-$$}

    # Get main process RSS
    local main_rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}' || echo "0")

    # Get children RSS
    local children_rss=$(ps --ppid "$pid" -o rss= 2>/dev/null | awk '{sum+=$1} END {print sum+0}')

    # Total in MB
    local total_kb=$((main_rss + children_rss))
    awk "BEGIN {printf \"%.2f\", $total_kb / 1024}"
}

# Get memory stats from metrics log
get_memory_stats() {
    local pid=${1:-$$}

    if [[ ! -f "$METRICS_LOG" ]]; then
        echo "ERROR: Metrics log not found: $METRICS_LOG" >&2
        return 1
    fi

    # Get all metrics for this PID from today
    local today=$(date +%Y-%m-%d)
    local metrics=$(grep "\"pid\":$pid" "$METRICS_LOG" | grep "$today" || echo "")

    if [[ -z "$metrics" ]]; then
        echo "No metrics found for PID $pid today" >&2
        return 1
    fi

    # Parse latest metric
    local latest=$(echo "$metrics" | tail -1)
    local current_mb=$(echo "$latest" | jq -r '.rss_mb')
    local rate=$(echo "$latest" | jq -r '.rate_mb_min // 0')

    # Get peak
    local peak_mb=$(echo "$metrics" | jq -s 'max_by(.rss_mb) | .rss_mb')
    local peak_time=$(echo "$metrics" | jq -s 'max_by(.rss_mb) | .timestamp' | tr -d '"')

    # Calculate minutes ago
    local peak_unix=$(date -d "$peak_time" +%s 2>/dev/null || echo "0")
    local now_unix=$(date +%s)
    local minutes_ago=$(( (now_unix - peak_unix) / 60 ))

    # Return as JSON
    cat <<EOF
{
    "current_mb": $current_mb,
    "peak_mb": $peak_mb,
    "peak_time": "$peak_time",
    "peak_minutes_ago": $minutes_ago,
    "rate_mb_min": $rate,
    "warn_threshold": $WARN_THRESHOLD_MB,
    "critical_threshold": $CRITICAL_THRESHOLD_MB
}
EOF
}

# Get list of child processes
get_children() {
    local pid=${1:-$$}
    ps --ppid "$pid" -o pid,rss,comm --no-headers 2>/dev/null || true
}

# Check if memory is above threshold
check_threshold() {
    local current_mb=$1

    if (( $(awk "BEGIN {print ($current_mb >= $CRITICAL_THRESHOLD_MB)}") )); then
        echo "CRITICAL"
        return 2
    elif (( $(awk "BEGIN {print ($current_mb >= $WARN_THRESHOLD_MB)}") )); then
        echo "WARNING"
        return 1
    else
        echo "OK"
        return 0
    fi
}

# Format memory size
format_memory() {
    local mb=$1
    if (( $(awk "BEGIN {print ($mb >= 1024)}") )); then
        awk "BEGIN {printf \"%.2f GB\", $mb / 1024}"
    else
        awk "BEGIN {printf \"%.0f MB\", $mb}"
    fi
}

# Get status emoji
get_status_emoji() {
    local status=$1
    case "$status" in
        OK) echo "✅" ;;
        WARNING) echo "⚠️" ;;
        CRITICAL) echo "🚨" ;;
        *) echo "❓" ;;
    esac
}

# Log event to events.jsonl
log_event() {
    local event_type=$1
    local severity=$2
    local message=$3
    local pid=${4:-$$}

    local timestamp=$(date +%s)
    local details="{}"

    if [[ ! -w "$EVENTS_LOG" ]]; then
        # Can't write to events log, just print to stderr
        echo "[$(date)] $severity: $message" >&2
        return
    fi

    cat >> "$EVENTS_LOG" <<EOF
{"timestamp":$timestamp,"type":"$event_type","pid":$pid,"session_id":"","severity":"$severity","message":"$message","details":$details}
EOF
}
