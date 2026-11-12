#!/bin/bash
# Claude Code Memory Monitor
# Monitors all Claude Code processes and their children for memory usage
# Logs to /var/log/claude-memory/ for datalake ingestion

set -euo pipefail

# Configuration
LOG_DIR="/var/log/claude-memory"
METRICS_LOG="$LOG_DIR/metrics.jsonl"
EVENTS_LOG="$LOG_DIR/events.jsonl"
WARN_THRESHOLD_MB=4000      # Warning at 4GB
CRITICAL_THRESHOLD_MB=8000  # Critical at 8GB
CHECK_INTERVAL=10           # Check every 10 seconds
RATE_THRESHOLD_MB_MIN=250   # Alert if growing > 250 MB/min

# Create log directory
mkdir -p "$LOG_DIR"

# Track previous memory readings for rate calculation
declare -A prev_memory
declare -A prev_timestamp

log_metric() {
    local pid=$1
    local session_id=$2
    local rss_bytes=$3
    local rss_mb=$4
    local rate_mb_min=$5
    local command=$6
    local timestamp=$(date +%s)

    echo "{\"timestamp\":$timestamp,\"pid\":$pid,\"session_id\":\"$session_id\",\"rss_bytes\":$rss_bytes,\"rss_mb\":$rss_mb,\"rate_mb_min\":$rate_mb_min,\"command\":\"$command\"}" >> "$METRICS_LOG"
}

log_event() {
    local event_type=$1
    local pid=$2
    local session_id=$3
    local severity=$4
    local message=$5
    local details=$6
    local timestamp=$(date +%s)

    echo "{\"timestamp\":$timestamp,\"type\":\"$event_type\",\"pid\":$pid,\"session_id\":\"$session_id\",\"severity\":\"$severity\",\"message\":\"$message\",\"details\":$details}" >> "$EVENTS_LOG"
}

get_claude_sessions() {
    # Find all Claude Code main processes
    # Filters out grep itself and only shows actual claude processes
    pgrep -f "claude" 2>/dev/null || true
}

get_process_tree_memory() {
    local pid=$1

    # Get RSS of main process (threads are already included in main process RSS)
    local main_rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}' || echo "0")

    # Get RSS of child processes (not threads)
    local children_rss=$(ps --ppid "$pid" -o rss= 2>/dev/null | awk '{sum+=$1} END {print sum+0}')

    # Total
    echo $((main_rss + children_rss))
}

get_memory_rate() {
    local pid=$1
    local current_mb=$2
    local current_ts=$(date +%s)

    if [[ -v prev_memory[$pid] ]]; then
        local prev_mb=${prev_memory[$pid]}
        local prev_ts=${prev_timestamp[$pid]}
        local time_diff=$((current_ts - prev_ts))

        if [[ $time_diff -gt 0 ]]; then
            # Calculate MB/min
            local rate=$(awk "BEGIN {printf \"%.2f\", ($current_mb - $prev_mb) * 60 / $time_diff}")
            echo "$rate"
        else
            echo "0"
        fi
    else
        echo "0"
    fi

    # Update tracking
    prev_memory[$pid]=$current_mb
    prev_timestamp[$pid]=$current_ts
}

get_session_id() {
    local pid=$1

    # Try to extract session ID from process working directory or command line
    # This is a placeholder - actual implementation may need to read from
    # ~/.claude/sessions/ or process environment
    local cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null || echo "")

    # Generate a simple session ID based on PID and start time
    local start_time=$(ps -o lstart= -p $pid 2>/dev/null | tr -d ' :' || echo "")
    echo "session-${pid}-${start_time:0:10}"
}

check_memory_threshold() {
    local pid=$1
    local rss_mb=$2
    local rate_mb_min=$3
    local session_id=$4

    if (( $(awk "BEGIN {print ($rss_mb >= $CRITICAL_THRESHOLD_MB)}") )); then
        log_event "memory_critical" "$pid" "$session_id" "critical" \
            "Session using ${rss_mb}MB (critical threshold: ${CRITICAL_THRESHOLD_MB}MB)" \
            "{\"rss_mb\":$rss_mb,\"threshold\":$CRITICAL_THRESHOLD_MB,\"rate_mb_min\":$rate_mb_min}"

        # Send desktop notification
        notify-send -u critical "Claude Memory CRITICAL" \
            "Session $session_id using ${rss_mb}MB (rate: ${rate_mb_min}MB/min)" 2>/dev/null || true

        return 2
    elif (( $(awk "BEGIN {print ($rss_mb >= $WARN_THRESHOLD_MB)}") )); then
        log_event "memory_warning" "$pid" "$session_id" "warning" \
            "Session using ${rss_mb}MB (warning threshold: ${WARN_THRESHOLD_MB}MB)" \
            "{\"rss_mb\":$rss_mb,\"threshold\":$WARN_THRESHOLD_MB,\"rate_mb_min\":$rate_mb_min}"

        # Send desktop notification
        notify-send -u normal "Claude Memory Warning" \
            "Session $session_id using ${rss_mb}MB (rate: ${rate_mb_min}MB/min)" 2>/dev/null || true

        return 1
    fi

    # Check rate threshold
    if (( $(awk "BEGIN {print ($rate_mb_min > $RATE_THRESHOLD_MB_MIN)}") )); then
        log_event "memory_rate_high" "$pid" "$session_id" "warning" \
            "Memory growing rapidly at ${rate_mb_min}MB/min" \
            "{\"rss_mb\":$rss_mb,\"rate_mb_min\":$rate_mb_min,\"threshold\":$RATE_THRESHOLD_MB_MIN}"

        notify-send -u normal "Claude Memory Growth" \
            "Session $session_id growing at ${rate_mb_min}MB/min" 2>/dev/null || true
    fi

    return 0
}

monitor_loop() {
    echo "[$(date)] Claude Memory Monitor started" | tee -a "$EVENTS_LOG"
    log_event "monitor_start" "0" "" "info" "Claude memory monitor service started" "{}"

    while true; do
        # Get all Claude sessions
        local claude_pids=$(get_claude_sessions)

        if [[ -z "$claude_pids" ]]; then
            # No Claude sessions running
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Monitor each session
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue

            # Get memory for entire process tree
            local rss_kb=$(get_process_tree_memory "$pid")
            local rss_bytes=$((rss_kb * 1024))
            local rss_mb=$(awk "BEGIN {printf \"%.2f\", $rss_kb / 1024}")

            # Get session ID
            local session_id=$(get_session_id "$pid")

            # Calculate memory growth rate
            local rate_mb_min=$(get_memory_rate "$pid" "$rss_mb")

            # Get command
            local command=$(ps -o comm= -p "$pid" 2>/dev/null || echo "unknown")

            # Log metric
            log_metric "$pid" "$session_id" "$rss_bytes" "$rss_mb" "$rate_mb_min" "$command"

            # Check thresholds
            check_memory_threshold "$pid" "$rss_mb" "$rate_mb_min" "$session_id"

        done <<< "$claude_pids"

        sleep "$CHECK_INTERVAL"
    done
}

# Signal handling for clean shutdown
cleanup() {
    echo "[$(date)] Claude Memory Monitor stopping" | tee -a "$EVENTS_LOG"
    log_event "monitor_stop" "0" "" "info" "Claude memory monitor service stopped" "{}"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Start monitoring
monitor_loop
