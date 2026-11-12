#!/bin/bash
# drift-detector.sh - Detect uncommitted changes across machines
#
# Checks all repos in ~/Programs for uncommitted changes and logs them.
# Designed to run on timer and alert future agents about drift.
#
# Usage: drift-detector.sh [--check-remote]
#   --check-remote: Also SSH to other machines and check their state

set -euo pipefail

PROGRAMS_DIR="$HOME/Programs"
LOG_DIR="$HOME/.local/state/drift-detector"
LOG_FILE="$LOG_DIR/drift.log"
STATE_FILE="$LOG_DIR/current-state.json"
DEVICES_CONF="$HOME/Programs/local-bootstrapping/devices.conf"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Get current machine name
get_machine_name() {
    local ts_ip=$(tailscale ip -4 2>/dev/null || true)
    case "$ts_ip" in
        100.64.0.1) echo "desktop" ;;
        100.64.0.2) echo "laptop" ;;
        *) hostname ;;
    esac
}

# Check a single repo for uncommitted changes
check_repo() {
    local repo_path="$1"
    local repo_name=$(basename "$repo_path")

    # Skip if not a git repo
    [[ -d "$repo_path/.git" ]] || return 0

    cd "$repo_path"

    # Get status
    local status=$(git status --porcelain 2>/dev/null || true)
    local stash_count=$(git stash list 2>/dev/null | wc -l || echo 0)
    local unpushed=$(git log --oneline @{upstream}..HEAD 2>/dev/null | wc -l || echo 0)

    if [[ -n "$status" || "$stash_count" -gt 0 || "$unpushed" -gt 0 ]]; then
        echo "$repo_name"

        if [[ -n "$status" ]]; then
            echo "  uncommitted: $(echo "$status" | wc -l) files"
            echo "$status" | head -5 | sed 's/^/    /'
            [[ $(echo "$status" | wc -l) -gt 5 ]] && echo "    ... and more"
        fi

        [[ "$stash_count" -gt 0 ]] && echo "  stashed: $stash_count entries"
        [[ "$unpushed" -gt 0 ]] && echo "  unpushed: $unpushed commits"

        return 1  # Has drift
    fi

    return 0  # Clean
}

# Check all repos on local machine
check_local() {
    local machine=$(get_machine_name)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local has_drift=false
    local drift_repos=""
    # Repos that must ALWAYS be committed: system-level config that other machines
    # sync from. Drift here = the sync design is being violated → the unit FAILS.
    # Every other repo (project work in progress) is only logged + notified.
    # (his rule, 2026-09-14)
    local -a system_repos=(local-bootstrapping)
    local system_drift=false

    echo "[$timestamp] Checking $machine..." | tee -a "$LOG_FILE"

    for repo in "$PROGRAMS_DIR"/*/; do
        [[ -d "$repo" ]] || continue

        if ! output=$(check_repo "$repo" 2>/dev/null); then
            has_drift=true
            drift_repos+="$output"$'\n'
            for sr in "${system_repos[@]}"; do
                [[ "$(basename "$repo")" == "$sr" ]] && system_drift=true
            done
        fi
    done

    if $has_drift; then
        echo "[$timestamp] DRIFT DETECTED on $machine:" >> "$LOG_FILE"
        echo "$drift_repos" | tee -a "$LOG_FILE"

        # Send notification if running interactively or via timer
        # Update state file
        echo "{\"machine\": \"$machine\", \"timestamp\": \"$timestamp\", \"has_drift\": true, \"system_drift\": $system_drift}" > "$STATE_FILE"
        if $system_drift; then
            echo "[$timestamp] SYSTEM-LEVEL DRIFT (${system_repos[*]}) — this must be committed and synced" | tee -a "$LOG_FILE"
            notify-send -u critical "Drift Detector" "local-bootstrapping has uncommitted changes on $machine — commit them" 2>/dev/null || true
            return 1
        fi
        # Project repos with WIP are logged + notified only; not a unit failure
        # (returning 1 for them made the unit show failed on every run, 2026-09-14).
        notify-send -u normal "Drift Detector" "Uncommitted changes found on $machine (project repos only)" 2>/dev/null || true
        return 0
    else
        echo "[$timestamp] $machine: All repos clean" | tee -a "$LOG_FILE"
        echo "{\"machine\": \"$machine\", \"timestamp\": \"$timestamp\", \"has_drift\": false}" > "$STATE_FILE"
        return 0
    fi
}

# Check remote machines via SSH
check_remote() {
    local current_ip=$(tailscale ip -4 2>/dev/null || true)

    [[ -f "$DEVICES_CONF" ]] || {
        echo "No devices.conf found, skipping remote check"
        return 0
    }

    grep -v '^#' "$DEVICES_CONF" | grep -v '^$' | while IFS=: read -r name ip desc; do
        # Skip self
        [[ "$ip" == "$current_ip" ]] && continue

        # Check if reachable
        if ! tailscale ping "$ip" -c 1 --timeout 2s &>/dev/null; then
            echo "[$name] Offline, skipping"
            continue
        fi

        echo "[$name] Checking via SSH..."
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$name" \
            'for repo in ~/Programs/*/; do
                [[ -d "$repo/.git" ]] || continue
                cd "$repo"
                status=$(git status --porcelain 2>/dev/null)
                [[ -n "$status" ]] && echo "$(basename $repo): $(echo "$status" | wc -l) uncommitted files"
            done' 2>/dev/null || echo "[$name] SSH failed"
    done
}

# Main
case "${1:-}" in
    --check-remote)
        check_local
        echo ""
        echo "=== Remote machines ==="
        check_remote
        ;;
    --json)
        # Output current state as JSON (for other tools to read)
        [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo '{"has_drift": null}'
        ;;
    *)
        check_local
        ;;
esac
