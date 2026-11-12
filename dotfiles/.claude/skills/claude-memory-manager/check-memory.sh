#!/bin/bash
# Check current memory usage for this Claude session

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/memory-utils.sh"

PID=${1:-$$}

echo "Memory Status for PID $PID:"
echo

# Get current memory
current_mb=$(get_current_memory "$PID")
echo "  Current: $(format_memory $current_mb)"

# Get stats from metrics log
if stats=$(get_memory_stats "$PID" 2>/dev/null); then
    peak_mb=$(echo "$stats" | jq -r '.peak_mb')
    peak_min_ago=$(echo "$stats" | jq -r '.peak_minutes_ago')
    rate=$(echo "$stats" | jq -r '.rate_mb_min')

    echo "  Peak: $(format_memory $peak_mb) ($peak_min_ago minutes ago)"
    echo "  Growth rate: $(format_memory $rate)/min"
else
    echo "  (No historical data available)"
fi

# Show child processes
echo
echo "  Child processes:"
children=$(get_children "$PID")
if [[ -n "$children" ]]; then
    echo "$children" | while read pid rss comm; do
        rss_mb=$(awk "BEGIN {printf \"%.0f\", $rss / 1024}")
        echo "    - $comm (PID $pid): ${rss_mb} MB"
    done
else
    echo "    (none)"
fi

# Check threshold
echo
status=$(check_threshold "$current_mb")
emoji=$(get_status_emoji "$status")
echo "  Status: $emoji $status"

case "$status" in
    CRITICAL)
        echo
        echo "  ⚠️  CRITICAL: Memory above $(format_memory $CRITICAL_THRESHOLD_MB)"
        echo "  Recommended actions:"
        echo "    1. Run: kill-children.sh to free memory"
        echo "    2. Run: enable-low-memory-mode.sh"
        echo "    3. Consider restarting session"
        ;;
    WARNING)
        echo
        echo "  ⚠️  WARNING: Memory above $(format_memory $WARN_THRESHOLD_MB)"
        echo "  Consider enabling low-memory mode if planning heavy operations"
        ;;
    OK)
        echo "  (Below $(format_memory $WARN_THRESHOLD_MB) warning threshold)"
        ;;
esac

exit 0
