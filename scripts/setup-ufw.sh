#!/bin/bash
# setup-ufw.sh - Configure UFW firewall for secure Tailscale access
#
# This script:
# - Installs UFW if not present
# - Enables UFW with sensible defaults
# - Allows SSH from Tailscale (100.64.0.0/10) and the home LAN (192.168.0.0/16)
#   The LAN rule is skipped unless sshd is already key-only
# - Allows LocalSend (port 53317) for file sharing
#
# Safe to run multiple times (idempotent)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

TAILSCALE_CIDR="100.64.0.0/10"

# Home LAN fallback. Tailscale is the primary transport, but when its session
# lapses (node key expiry) it takes SSH down with it - including to a machine
# sitting 2ms away on the same switch. /16 rather than /24 because the LAN has
# already been renumbered once (192.168.29.x -> 192.168.0.x); a /24 would
# silently break again on the next router change. RFC1918-private either way.
LAN_CIDR="192.168.0.0/16"

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script requires sudo privileges"
    exec sudo "$0" "$@"
fi

# Install UFW if not present
install_ufw() {
    if ! command -v ufw &> /dev/null; then
        log "Installing UFW..."
        pacman -S --noconfirm ufw
    else
        log "UFW already installed"
    fi
}

# Enable and configure UFW defaults
configure_ufw_defaults() {
    log "Configuring UFW defaults..."

    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Enable UFW if not already enabled
    if ! ufw status | grep -q "Status: active"; then
        log "Enabling UFW..."
        ufw --force enable
    else
        log "UFW already active"
    fi
}

# Add rule if it doesn't exist
add_rule_if_missing() {
    local check_pattern="$1"
    local rule_description="$2"
    shift 2
    local rule_args=("$@")

    if ufw status | grep -q "$check_pattern"; then
        log "$rule_description - already exists"
    else
        log "Adding: $rule_description"
        ufw "${rule_args[@]}"
    fi
}

# Configure firewall rules
configure_rules() {
    log "Configuring firewall rules..."

    # SSH from Tailscale only
    add_rule_if_missing "22/tcp.*100.64.0.0/10" \
        "SSH from Tailscale ($TAILSCALE_CIDR)" \
        allow from $TAILSCALE_CIDR to any port 22 proto tcp comment 'SSH from Tailscale'

    # SSH from home LAN - fallback path when Tailscale is unavailable.
    #
    # Interlocked against password auth: opening port 22 to the whole LAN is
    # only acceptable if sshd is key-only. harden_sshd() in setup-ssh.sh sets
    # that up; if it hasn't run, skip the rule rather than widen exposure.
    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then
        warn "sshd still allows password auth - skipping LAN SSH rule"
        warn "Run scripts/setup-ssh.sh first (it enforces key-only auth)"
    else
        add_rule_if_missing "22/tcp.*192.168.0.0/16" \
            "SSH from home LAN ($LAN_CIDR)" \
            allow from $LAN_CIDR to any port 22 proto tcp comment 'SSH from home LAN'
    fi

    # LocalSend for file sharing (all networks - needed for local discovery)
    add_rule_if_missing "53317" \
        "LocalSend (port 53317)" \
        allow 53317 comment 'LocalSend file sharing'

    # Syncthing (if used) - only from Tailscale
    # add_rule_if_missing "22000/tcp.*100.64.0.0/10" \
    #     "Syncthing from Tailscale" \
    #     allow from $TAILSCALE_CIDR to any port 22000 proto tcp comment 'Syncthing from Tailscale'
}

# Reload UFW
reload_ufw() {
    log "Reloading UFW..."
    ufw reload
}

# Show status
show_status() {
    echo ""
    log "Current UFW status:"
    ufw status numbered
}

main() {
    echo -e "${GREEN}=== UFW Firewall Setup ===${NC}"
    echo ""

    install_ufw
    configure_ufw_defaults
    configure_rules
    reload_ufw
    show_status

    echo ""
    log "Firewall configured successfully!"
    log "SSH accessible via Tailscale ($TAILSCALE_CIDR) and home LAN ($LAN_CIDR)"
}

main "$@"
