#!/bin/bash
# sync-from-master.sh - Safely sync local-bootstrapping from master branch
#
# This script:
# 1. Fetches updates from origin/master
# 2. Validates changes before applying
# 3. Only merges if validation passes
# 4. Creates backup before applying
# 5. Sends notifications on success/failure
#
# Usage:
#   ./sync-from-master.sh           # Normal sync
#   ./sync-from-master.sh --force   # Skip validation (emergency only)
#   ./sync-from-master.sh --dry-run # Check for updates without applying

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$HOME/.local-bootstrapping-backups"
LOG_FILE="$HOME/.local/share/local-bootstrapping-sync.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
FORCE=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo "$msg" >> "$LOG_FILE"
}

notify() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    # Try notify-send if available
    if command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$message" 2>/dev/null || true
    fi

    log "$title: $message"
}

# =============================================================================
# Core Sync Logic
# =============================================================================

check_for_updates() {
    cd "$REPO_ROOT"

    # Fetch latest from origin
    git fetch origin master --quiet 2>/dev/null || {
        log "ERROR: Failed to fetch from origin"
        return 1
    }

    # Compare local master with origin/master
    local local_hash remote_hash
    local_hash=$(git rev-parse master)
    remote_hash=$(git rev-parse origin/master)

    if [[ "$local_hash" == "$remote_hash" ]]; then
        return 1  # No updates
    fi

    # Show what's changed
    local commits_behind
    commits_behind=$(git rev-list master..origin/master --count)
    log "Found $commits_behind new commit(s) on origin/master"

    return 0  # Updates available
}

get_changed_files() {
    cd "$REPO_ROOT"
    git diff --name-only master..origin/master
}

create_backup() {
    log "Creating backup..."
    mkdir -p "$BACKUP_DIR"

    local backup_file="$BACKUP_DIR/backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    # Backup current dotfiles
    tar -czf "$backup_file" \
        -C "$REPO_ROOT" \
        dotfiles/ \
        2>/dev/null || {
        log "WARNING: Backup creation had issues"
    }

    # Keep only last 5 backups
    ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

    log "Backup created: $backup_file"
    echo "$backup_file"
}

validate_incoming_changes() {
    log "Validating incoming changes..."

    cd "$REPO_ROOT"

    # Temporarily checkout origin/master files to validate
    local temp_dir=$(mktemp -d)
    # dotfiles/ plus the scripts that will run next (this sync itself, the
    # reconcile) and the per-device files, when origin/master has them
    local -a paths=(dotfiles/)
    local p
    for p in scripts machine-specific; do
        git cat-file -e "origin/master:$p" 2>/dev/null && paths+=("$p/")
    done
    git archive origin/master "${paths[@]}" | tar -x -C "$temp_dir" 2>/dev/null || {
        rm -rf "$temp_dir"
        log "ERROR: Failed to extract changes for validation"
        return 1
    }

    # Run validation on the temp directory
    # We need to temporarily modify REPO_ROOT for the validation script
    DOTFILES="$temp_dir/dotfiles" REPO_ROOT="$temp_dir" \
        "$SCRIPT_DIR/validate-configs.sh" 2>&1 || {
        rm -rf "$temp_dir"
        log "ERROR: Validation failed for incoming changes"
        return 1
    }

    rm -rf "$temp_dir"
    log "Validation passed"
    return 0
}

apply_updates() {
    log "Applying updates..."
    cd "$REPO_ROOT"

    # Fast-forward merge only (safe)
    if git merge --ff-only origin/master 2>/dev/null; then
        log "Successfully merged updates"
        return 0
    else
        log "ERROR: Cannot fast-forward merge. Manual intervention required."
        return 1
    fi
}

check_local_changes() {
    cd "$REPO_ROOT"

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log "WARNING: Local uncommitted changes detected"
        return 1
    fi

    return 0
}

# =============================================================================
# Main
# =============================================================================
#
# Every run, whether or not new commits arrived:
#   1. pull origin/master when it is safe (master, clean tree, validation ok)
#   2. self-heal: install.sh --reconcile (links, hypr sources, gated user units,
#      no-sudo checks, monitor-chooser build, waybar) — scripts/lib/reconcile.sh
#   3. hand whatever is still unresolved to lb-drift, which opens a Claude agent
#      on this machine once the same drift outlives its grace period
# See docs/issues/desktop-drift-2026-09-30.md.

REPORT=""
item() {  # kind key detail — drift the self-heal cannot fix
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$REPORT"
}

# Notify only when this message differs from the last one (the timer runs every
# 10 minutes; a standing condition must not notify every run).
notify_once() {
    local stamp_file="$HOME/.local/state/local-bootstrapping/last-notify"
    local key="$1|$2"
    mkdir -p "$(dirname "$stamp_file")"
    if [[ "$(cat "$stamp_file" 2>/dev/null)" == "$key" ]]; then
        log "$1: $2 (unchanged, not re-notified)"
        return 0
    fi
    echo "$key" > "$stamp_file"
    notify "$@"
}

pull_updates() {  # returns 0 when new commits were merged
    cd "$REPO_ROOT"

    local current_branch
    current_branch=$(git branch --show-current)
    if [[ "$current_branch" != "master" ]]; then
        log "INFO: On branch '$current_branch' - not pulling"
        item git-branch "$current_branch" "the canonical checkout is not on master, so it does not sync"
        return 1
    fi

    if ! check_local_changes; then
        if [[ "$FORCE" == "true" ]]; then
            log "WARNING: Proceeding despite local changes (--force)"
        else
            local files hash
            files=$(git status --porcelain | wc -l)
            # key changes as the work changes, so live WIP keeps restarting the grace clock
            hash=$( { git status --porcelain; git diff; } | sha1sum | cut -c1-10)
            item git-uncommitted "$hash" "$files uncommitted file(s) block the pull: $(git status --porcelain | awk '{print $2}' | head -6 | tr '\n' ' ')"
            notify_once "Sync Skipped" "Local uncommitted changes. Commit or stash first." "normal"
            return 1
        fi
    fi

    if ! check_for_updates; then
        log "No updates available"
        return 1
    fi

    log "Changed files:"
    get_changed_files | while read -r file; do
        log "  - $file"
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run complete. Would sync the above changes."
        return 1
    fi

    if [[ "$FORCE" != "true" ]]; then
        if ! validate_incoming_changes; then
            item validation-failed "$(git rev-parse --short origin/master)" "validate-configs.sh rejects origin/master; changes NOT applied"
            notify_once "Sync Blocked" "Validation failed. Changes NOT applied." "critical"
            return 1
        fi
    else
        log "WARNING: Skipping validation (--force)"
    fi

    CHANGED_FILES=$(get_changed_files)
    local backup_file
    backup_file=$(create_backup | tail -1)

    if apply_updates; then
        notify "Sync Complete" "local-bootstrapping updated successfully" "normal"
        log "=== Sync completed successfully ==="
        return 0
    fi
    item git-diverged "$(git rev-parse --short master)..$(git rev-parse --short origin/master)" "fast-forward impossible (local commits?); backup $backup_file"
    notify_once "Sync Failed" "Merge failed. Backup at: $backup_file" "critical"
    log "=== Sync failed ==="
    return 1
}

after_pull() {
    # Re-patch Omarchy defaults for Hyprland 0.54+/0.56 (catches omarchy updates
    # that overwrite patches); the reconcile re-checks configerrors every run too
    local p
    for p in fix-hyprland-054-compat.sh fix-hyprland-056-compat.sh; do
        if [[ -x "$SCRIPT_DIR/$p" ]]; then
            log "Re-running $p..."
            "$SCRIPT_DIR/$p" 2>&1 | while read -r line; do log "  $line"; done || true
        fi
    done

    # bar-touch is a long-running daemon: new code needs a restart to load
    if grep -q 'dotfiles/local-bin/bar-touch' <<< "$CHANGED_FILES"; then
        systemctl --user try-restart bar-touch.service 2>/dev/null && log "bar-touch restarted (new code)"
    fi

    # Re-run voice typing setup if voice-related files changed
    if grep -qE '(voice|hyprwhspr|gateway|local-whisper)' <<< "$CHANGED_FILES"; then
        log "Voice typing files changed — re-running setup..."
        if "$SCRIPT_DIR/setup-voice-typing.sh"; then
            log "Voice typing re-deployed"
        else
            log "WARNING: Voice typing re-deploy failed — run setup-voice-typing.sh manually"
        fi
    fi

    # Propagate to other devices if propagation script exists
    if [[ -f "$SCRIPT_DIR/propagate-to-devices.sh" ]]; then
        "$SCRIPT_DIR/propagate-to-devices.sh" --background 2>/dev/null || true
    fi
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log "=== Starting local-bootstrapping sync ==="

    REPORT=$(mktemp -t lb-drift-report.XXXXXX)
    trap 'rm -f "$REPORT"' EXIT
    CHANGED_FILES=""

    local pulled=false
    if pull_updates; then pulled=true; fi
    [[ "$DRY_RUN" == "true" ]] && exit 0

    if $pulled; then after_pull; fi

    # Self-heal every run (not only after a pull): the step the timer used to
    # skip, which let the desktop drift 67 links behind (2026-09-30).
    local waybar_changed=0
    grep -qE 'dotfiles/waybar/(config|style)' <<< "$CHANGED_FILES" && waybar_changed=1
    LB_WAYBAR_CHANGED=$waybar_changed bash "$SCRIPT_DIR/install.sh" --reconcile --quiet --report "$REPORT" 2>&1 \
        | while IFS= read -r line; do log "reconcile: $line"; done || true
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        item reconcile-failed "install.sh --reconcile" "exited non-zero; see $LOG_FILE"
    fi

    # Escalation: notification + Claude agent once drift outlives its grace
    python3 "$REPO_ROOT/dotfiles/local-bin/lb-drift" record "$REPORT" 2>&1 \
        | while IFS= read -r line; do log "$line"; done || true
    log "=== Sync run done ==="
}

main "$@"
