#!/bin/bash
# Setup audio-viz — multi-pane audio visualization dashboard
# Pulls the audio-viz repo and runs its installer with --link (symlinks for auto-sync)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

AUDIO_VIZ_DIR="$HOME/Programs/audio-viz"

main() {
    log "Setting up audio-viz..."

    # Clone or update the repo
    if [[ -d "$AUDIO_VIZ_DIR/.git" ]]; then
        info "audio-viz repo exists, pulling latest..."
        git -C "$AUDIO_VIZ_DIR" pull --ff-only origin main 2>/dev/null || \
        git -C "$AUDIO_VIZ_DIR" pull --ff-only origin master 2>/dev/null || \
            warn "Could not pull (may have local changes)"
    else
        warn "audio-viz repo not found at $AUDIO_VIZ_DIR"
        info "Clone it first: git clone <url> $AUDIO_VIZ_DIR"
        return 1
    fi

    # Run the app's own installer with --link so configs stay synced to repo
    log "Running audio-viz installer..."
    bash "$AUDIO_VIZ_DIR/install.sh" --link

    log "audio-viz setup complete"
}

main "$@"
