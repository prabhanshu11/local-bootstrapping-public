#!/bin/bash
# Kill child processes to free memory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/memory-utils.sh"

PID=${1:-$$}
DRY_RUN=false
EXCEPT=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --except) EXCEPT+=("$2"); shift 2 ;;
        *) PID=$1; shift ;;
    esac
done

echo "Killing child processes for PID $PID..."
if $DRY_RUN; then
    echo "(DRY RUN - no processes will be killed)"
fi
echo

# Get children
children=$(get_children "$PID")

if [[ -z "$children" ]]; then
    echo "No child processes found."
    exit 0
fi

# Show what we'll kill
total_freed_kb=0
killed_count=0
preserved_count=0

while read child_pid rss comm; do
    # Check if in except list
    skip=false
    for except in "${EXCEPT[@]}"; do
        if [[ "$comm" == "$except" ]]; then
            skip=true
            break
        fi
    done

    rss_mb=$(awk "BEGIN {printf \"%.0f\", $rss / 1024}")

    if $skip; then
        echo "  ⊘ Preserving $comm (PID $child_pid) - in except list"
        ((preserved_count++))
    else
        if $DRY_RUN; then
            echo "  [DRY] Would kill $comm (PID $child_pid) - would free ${rss_mb} MB"
        else
            if kill "$child_pid" 2>/dev/null; then
                echo "  ✓ Killed $comm (PID $child_pid) - freed ${rss_mb} MB"
                total_freed_kb=$((total_freed_kb + rss))
                ((killed_count++))
            else
                echo "  ✗ Failed to kill $comm (PID $child_pid)"
            fi
        fi
    fi
done <<< "$children"

echo
if $DRY_RUN; then
    echo "Dry run complete. Would have killed $killed_count processes."
else
    echo "Killed $killed_count processes, preserved $preserved_count"
    if [[ $total_freed_kb -gt 0 ]]; then
        total_freed_mb=$(awk "BEGIN {printf \"%.0f\", $total_freed_kb / 1024}")
        echo "Total memory freed: ${total_freed_mb} MB"

        # Show new memory usage
        sleep 1
        new_mb=$(get_current_memory "$PID")
        echo "New memory usage: $(format_memory $new_mb)"

        # Log event
        log_event "child_processes_killed" "info" "Killed $killed_count child processes, freed ${total_freed_mb}MB" "$PID"
    fi
fi

exit 0
