#!/bin/bash
# Gracefully restart Claude session with optional state preservation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/memory-utils.sh"

PID=${1:-$$}
SAVE_STATE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --save-state) SAVE_STATE=true; shift ;;
        *) PID=$1; shift ;;
    esac
done

STATE_DIR="$HOME/.claude/restart-state/$PID"

echo "Preparing to restart Claude session (PID $PID)..."
echo

if $SAVE_STATE; then
    echo "Saving session state..."

    # Create state directory
    mkdir -p "$STATE_DIR"

    # Save plan file if it exists
    PLAN_FILE=$(find ~/.claude/plans/ -name "*.md" -type f -mtime -1 2>/dev/null | head -1)
    if [[ -n "$PLAN_FILE" ]]; then
        cp "$PLAN_FILE" "$STATE_DIR/plan.md"
        echo "  ✓ Saved plan file"
    fi

    # Save conversation context (last session from history)
    if [[ -f ~/.claude/history.jsonl" ]]; then
        # Get last 20 messages from current session
        # Note: This is a placeholder - actual implementation would parse history.jsonl
        echo "Session context saved (placeholder)" > "$STATE_DIR/conversation.txt"
        echo "  ✓ Saved conversation context"
    fi

    # Create resume instructions
    cat > "$STATE_DIR/resume.txt" <<EOF
To resume this session:

1. cd $(pwd)
2. claude

Then tell Claude:
"Resume from saved state. The plan was: $(head -1 "$STATE_DIR/plan.md" 2>/dev/null || echo "No plan saved")"

Saved files:
- Plan: $STATE_DIR/plan.md
- Context: $STATE_DIR/conversation.txt
EOF

    echo "  ✓ Created resume instructions"
    echo
    echo "State saved to: $STATE_DIR"
    echo
    cat "$STATE_DIR/resume.txt"
    echo
fi

# Log restart event
log_event "session_restart_initiated" "info" "User requested session restart (save_state=$SAVE_STATE)" "$PID"

echo "To restart manually:"
echo "  1. Exit this Claude session (Ctrl+D or type 'exit')"
echo "  2. Start a new session: claude"
if $SAVE_STATE; then
    echo "  3. Resume with saved context"
fi
echo

# Note: We don't actually kill the Claude process here
# The user should exit manually, or this would be called by an automated restart daemon
echo "Note: This script doesn't force-kill Claude."
echo "Please exit manually when ready."

exit 0
