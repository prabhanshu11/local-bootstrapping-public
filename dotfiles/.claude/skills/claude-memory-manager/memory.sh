#!/bin/bash
# Main entry point for claude-memory-manager skill

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION=${1:-check}
shift || true

case "$ACTION" in
    check|status)
        exec "$SCRIPT_DIR/check-memory.sh" "$@"
        ;;
    kill|kill-children)
        exec "$SCRIPT_DIR/kill-children.sh" "$@"
        ;;
    low-memory|lm)
        exec "$SCRIPT_DIR/low-memory-mode.sh" $$ "$@"
        ;;
    restart)
        exec "$SCRIPT_DIR/restart-session.sh" "$@"
        ;;
    help|--help|-h)
        cat <<EOF
Claude Memory Manager - Memory management and self-awareness

Usage: memory.sh <action> [options]

Actions:
  check              Check current memory usage (default)
  kill-children      Kill child processes to free memory
  low-memory <cmd>   Enable/disable/check low-memory mode
  restart            Restart session with state preservation

Examples:
  memory.sh check
  memory.sh kill-children --except clangd
  memory.sh low-memory enable
  memory.sh restart --save-state

For more info: cat ~/.claude/skills/claude-memory-manager/SKILL.md
EOF
        ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Run 'memory.sh help' for usage"
        exit 1
        ;;
esac
