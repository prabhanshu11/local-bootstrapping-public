#!/bin/bash
# Enable or disable low-memory mode for this Claude session

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/memory-utils.sh"

PID=${1:-$$}
ACTION=${2:-status}

LOW_MEMORY_DIR="/var/log/claude-memory/low-memory-mode"
LOW_MEMORY_FILE="$LOW_MEMORY_DIR/$PID"

# Create directory if it doesn't exist
if [[ ! -d "$LOW_MEMORY_DIR" ]]; then
    if ! mkdir -p "$LOW_MEMORY_DIR" 2>/dev/null; then
        echo "ERROR: Cannot create $LOW_MEMORY_DIR (permission denied)" >&2
        echo "Try: sudo mkdir -p $LOW_MEMORY_DIR && sudo chown $USER $LOW_MEMORY_DIR" >&2
        exit 1
    fi
fi

case "$ACTION" in
    enable)
        current_mb=$(get_current_memory "$PID")

        cat > "$LOW_MEMORY_FILE" <<EOF
{
    "enabled_at": "$(date -Iseconds)",
    "enabled_at_unix": $(date +%s),
    "memory_at_enable_mb": $current_mb,
    "pid": $PID
}
EOF

        echo "✓ Low-memory mode ENABLED for PID $PID"
        echo
        echo "  This session will now receive guidance to conserve memory."
        echo "  Current usage: $(format_memory $current_mb)"
        echo
        echo "  Guidance will include:"
        echo "    - Avoid spawning parallel agents"
        echo "    - Use lightweight commands"
        echo "    - Minimize context retention"
        echo
        echo "  To disable: low-memory-mode.sh $PID disable"

        log_event "low_memory_mode_enabled" "warning" "Low-memory mode enabled at $(format_memory $current_mb)" "$PID"
        ;;

    disable)
        if [[ -f "$LOW_MEMORY_FILE" ]]; then
            rm "$LOW_MEMORY_FILE"
            echo "✓ Low-memory mode DISABLED for PID $PID"

            log_event "low_memory_mode_disabled" "info" "Low-memory mode disabled" "$PID"
        else
            echo "Low-memory mode was not enabled for PID $PID"
        fi
        ;;

    status|check)
        if [[ -f "$LOW_MEMORY_FILE" ]]; then
            echo "Low-memory mode: ✅ ENABLED"
            echo
            enabled_at=$(jq -r '.enabled_at' "$LOW_MEMORY_FILE")
            memory_at=$(jq -r '.memory_at_enable_mb' "$LOW_MEMORY_FILE")
            echo "  Enabled at: $enabled_at"
            echo "  Memory when enabled: $(format_memory $memory_at)"
            echo
            current_mb=$(get_current_memory "$PID")
            echo "  Current memory: $(format_memory $current_mb)"

            # Check if we should auto-disable
            if (( $(awk "BEGIN {print ($current_mb < 3000)}") )); then
                echo
                echo "  💡 Memory is now below 3 GB - consider disabling low-memory mode"
                echo "     Run: low-memory-mode.sh $PID disable"
            fi
        else
            echo "Low-memory mode: ⊘ DISABLED"
            current_mb=$(get_current_memory "$PID")
            echo "  Current memory: $(format_memory $current_mb)"

            # Check if we should suggest enabling
            if (( $(awk "BEGIN {print ($current_mb > 6000)}") )); then
                echo
                echo "  ⚠️  Memory is above 6 GB - consider enabling low-memory mode"
                echo "     Run: low-memory-mode.sh $PID enable"
            fi
        fi
        ;;

    *)
        echo "Usage: low-memory-mode.sh [PID] {enable|disable|status}"
        echo
        echo "Actions:"
        echo "  enable  - Enable low-memory mode (adds guidance to conversation)"
        echo "  disable - Disable low-memory mode"
        echo "  status  - Check if enabled (default)"
        exit 1
        ;;
esac

exit 0
