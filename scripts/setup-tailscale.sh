#!/bin/bash
# setup-tailscale.sh - Install and configure Tailscale for secure networking
#
# This script:
# - Installs Tailscale if not present
# - Enables and starts the Tailscale daemon
# - Guides through authentication
# - Verifies connection to tailnet
#
# Safe to run multiple times (idempotent)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

install_tailscale() {
    if command -v tailscale &>/dev/null; then
        log "Tailscale already installed: $(tailscale version | head -1)"
        return
    fi

    log "Installing Tailscale..."
    sudo pacman -S --noconfirm tailscale
}

enable_tailscale_service() {
    log "Enabling Tailscale daemon..."

    if ! systemctl is-enabled tailscaled &>/dev/null; then
        sudo systemctl enable tailscaled
    fi

    if ! systemctl is-active tailscaled &>/dev/null; then
        sudo systemctl start tailscaled
    fi

    log "Tailscale daemon is running"
}

authenticate_tailscale() {
    # Check if already authenticated
    if tailscale status &>/dev/null; then
        local ip=$(tailscale ip -4 2>/dev/null)
        if [[ -n "$ip" ]]; then
            log "Already connected to tailnet with IP: $ip"
            return
        fi
    fi

    info "Tailscale needs authentication."
    info "Running 'tailscale up' - follow the link to authenticate..."
    echo ""

    sudo tailscale up

    echo ""
    log "Authenticated successfully!"
}

show_status() {
    echo ""
    info "Tailscale Status:"
    tailscale status
    echo ""

    local ip=$(tailscale ip -4 2>/dev/null)
    info "Your Tailscale IP: $ip"
}

main() {
    echo -e "${CYAN}=== Tailscale Setup ===${NC}"
    echo ""

    install_tailscale
    enable_tailscale_service
    authenticate_tailscale
    show_status

    echo ""
    log "Tailscale setup complete!"
    info "You can now access other devices in your tailnet."
}

main "$@"
