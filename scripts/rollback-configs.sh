#!/bin/bash
# rollback-configs.sh - Rollback to a previous backup
#
# Lists available backups and allows restoring to a previous state.
#
# Usage:
#   ./rollback-configs.sh          # Interactive - shows available backups
#   ./rollback-configs.sh --latest # Rollback to most recent backup
#   ./rollback-configs.sh <backup-file>  # Rollback to specific backup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$HOME/.local-bootstrapping-backups"
DOTFILES="$REPO_ROOT/dotfiles"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

list_backups() {
    echo -e "${BOLD}Available backups:${NC}"
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        warn "No backups found at $BACKUP_DIR"
        return 1
    fi

    local backups
    backups=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warn "No backup files found"
        return 1
    fi

    local i=1
    while IFS= read -r backup; do
        local size timestamp
        size=$(du -h "$backup" | cut -f1)
        timestamp=$(basename "$backup" | sed 's/backup-\([0-9]*-[0-9]*\).tar.gz/\1/' | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')

        echo -e "  ${BOLD}[$i]${NC} $timestamp (${size})"
        echo "      $(basename "$backup")"
        echo ""
        ((i++))
    done <<< "$backups"

    return 0
}

get_backup_by_index() {
    local index="$1"
    ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | sed -n "${index}p"
}

get_latest_backup() {
    ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1
}

restore_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
    fi

    log "Restoring from: $(basename "$backup_file")"

    # Create a pre-rollback backup
    local pre_rollback="$BACKUP_DIR/pre-rollback-$(date +%Y%m%d-%H%M%S).tar.gz"
    log "Creating pre-rollback backup..."
    tar -czf "$pre_rollback" -C "$REPO_ROOT" dotfiles/ 2>/dev/null || warn "Could not create pre-rollback backup"

    # Extract backup to dotfiles
    log "Extracting backup..."
    tar -xzf "$backup_file" -C "$REPO_ROOT" --overwrite 2>/dev/null || {
        error "Failed to extract backup"
    }

    log "Rollback complete!"
    info "Pre-rollback backup saved to: $pre_rollback"
    echo ""
    warn "Note: Symlinked files will use restored configs immediately."
    info "Run 'git status' to see changes in the repo."
}

interactive_restore() {
    list_backups || return 1

    echo ""
    read -p "Enter backup number to restore (or 'q' to quit): " choice

    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        info "Cancelled"
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        error "Invalid selection"
    fi

    local backup
    backup=$(get_backup_by_index "$choice")

    if [[ -z "$backup" ]]; then
        error "Invalid backup selection"
    fi

    echo ""
    warn "This will restore: $(basename "$backup")"
    read -p "Are you sure? (y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Cancelled"
        return 0
    fi

    restore_backup "$backup"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  local-bootstrapping Rollback Tool${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    case "${1:-}" in
        --list|-l)
            list_backups
            ;;
        --latest)
            local latest
            latest=$(get_latest_backup)
            if [[ -z "$latest" ]]; then
                error "No backups found"
            fi
            restore_backup "$latest"
            ;;
        "")
            interactive_restore
            ;;
        *)
            # Assume it's a backup file path
            if [[ -f "$1" ]]; then
                restore_backup "$1"
            elif [[ -f "$BACKUP_DIR/$1" ]]; then
                restore_backup "$BACKUP_DIR/$1"
            else
                error "Backup not found: $1"
            fi
            ;;
    esac
}

main "$@"
