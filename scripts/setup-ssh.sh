#!/bin/bash
# setup-ssh.sh - Configure SSH for seamless device synergy
#
# This script:
# - Ensures SSH server is installed and running
# - Generates SSH keys if not present
# - Exchanges keys with other Tailscale devices for passwordless login
# - Configures SSH client for convenience
#
# Safe to run multiple times (idempotent)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

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

SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
DEVICES_CONF="$REPO_ROOT/devices.conf"

# Load devices from config file
load_devices() {
    DEVICES=()
    if [[ -f "$DEVICES_CONF" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ -z "$line" || "$line" == \#* ]] && continue
            DEVICES+=("$line")
        done < "$DEVICES_CONF"
    else
        warn "devices.conf not found, using defaults"
        DEVICES=(
            "desktop:100.64.0.1:Desktop PC"
            "laptop:100.64.0.2:Laptop"
        )
    fi
}

load_devices

# Detect which device this is based on Tailscale IP
detect_device() {
    local my_ip=$(tailscale ip -4 2>/dev/null)

    for device in "${DEVICES[@]}"; do
        local ip=$(echo "$device" | cut -d: -f2)
        if [[ "$my_ip" == "$ip" ]]; then
            echo "$device" | cut -d: -f1
            return
        fi
    done

    echo "unknown"
}

install_ssh_server() {
    log "Ensuring SSH server is installed..."

    if ! command -v sshd &>/dev/null; then
        log "Installing openssh..."
        sudo pacman -S --noconfirm openssh
    fi

    # Enable and start sshd
    if ! systemctl is-enabled sshd &>/dev/null; then
        log "Enabling sshd service..."
        sudo systemctl enable sshd
    fi

    if ! systemctl is-active sshd &>/dev/null; then
        log "Starting sshd service..."
        sudo systemctl start sshd
    fi

    log "SSH server is running"
}

# Enforce key-only auth.
#
# Arch ships no PasswordAuthentication directive, so the OpenSSH default (yes)
# applies. That was tolerable while UFW only exposed port 22 to the Tailscale
# CIDR, but setup-ufw.sh now also allows the home LAN - so password auth would
# be reachable from every device on the network. Disable it.
#
# Refuses to act unless key auth is already proven working, so a misconfigured
# machine fails loudly instead of locking itself out.
harden_sshd() {
    local dropin="/etc/ssh/sshd_config.d/10-local-bootstrapping.conf"

    log "Enforcing key-only SSH auth..."

    # authorized_keys must be non-empty, or disabling passwords locks us out.
    if [[ ! -s "$SSH_DIR/authorized_keys" ]]; then
        warn "authorized_keys is missing or empty - refusing to disable password auth"
        warn "Run key exchange first, then re-run this script"
        return
    fi

    if [[ -f "$dropin" ]] && grep -q "^PasswordAuthentication no" "$dropin"; then
        log "Key-only auth already enforced"
        return
    fi

    sudo tee "$dropin" >/dev/null << 'EOF'
# Managed by local-bootstrapping (scripts/setup-ssh.sh) - do not edit by hand.
# Port 22 is reachable from the home LAN (see scripts/setup-ufw.sh), so
# password auth must stay off.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
    sudo chmod 644 "$dropin"

    # Validate before reloading - a bad config would leave sshd down.
    # error() here does not exit, so remove the bad drop-in ourselves rather
    # than leaving a config that breaks sshd on its next restart.
    if ! sudo sshd -t; then
        error "sshd config invalid after writing $dropin - reverting, not reloading"
        sudo rm -f "$dropin"
        return 1
    fi

    sudo systemctl reload sshd
    log "Key-only auth enforced ($dropin)"
}

generate_ssh_key() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ -f "$SSH_KEY" ]]; then
        log "SSH key already exists: $SSH_KEY"
        return
    fi

    log "Generating new SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$USER@$(hostname)-$(date +%Y%m%d)"
    log "SSH key generated"
}

setup_ssh_config() {
    local config="$SSH_DIR/config"

    log "Setting up SSH client config..."

    # Create config if it doesn't exist
    if [[ ! -f "$config" ]]; then
        touch "$config"
        chmod 600 "$config"
    fi

    # Add host aliases for Tailscale devices
    for device in "${DEVICES[@]}"; do
        local name=$(echo "$device" | cut -d: -f1)
        local ip=$(echo "$device" | cut -d: -f2)
        local desc=$(echo "$device" | cut -d: -f3)

        # Anchored: an unanchored "Host $name" also matches "Host $name-lan",
        # which would suppress the primary alias depending on write order.
        if ! grep -qE "^Host ${name}\$" "$config" 2>/dev/null; then
            log "Adding SSH alias: $name -> $ip"
            cat >> "$config" << EOF

# $desc
Host $name
    HostName $ip
    User $USER
    IdentityFile ~/.ssh/id_ed25519
EOF
        fi

        # Optional LAN fallback alias, used when the tailnet is unavailable.
        # Kept as a separate alias rather than changing the primary: the laptop
        # travels, so the Tailscale address stays the correct default.
        local lan_ip=$(echo "$device" | cut -d: -f4)
        if [[ -n "$lan_ip" ]] && ! grep -qE "^Host ${name}-lan\$" "$config" 2>/dev/null; then
            log "Adding SSH alias: ${name}-lan -> $lan_ip"
            cat >> "$config" << EOF

# $desc - LAN fallback (works without Tailscale)
Host ${name}-lan
    HostName $lan_ip
    User $USER
    IdentityFile ~/.ssh/id_ed25519
EOF
        fi
    done

    # pi5 / nas and desktop-auto: one name per home machine, channel chosen in his
    # order (LAN -> VPS relay -> Tailscale) by ~/.local/bin/home-route. The blocks
    # live in dotfiles/ssh/home-routes.conf (linked by install.sh); the Include must
    # be at the TOP so its values win over any older "Host pi5" further down.
    # (Replaces the pi5 -> 192.168.29.10 alias of the old house, dead since 2026-09.)
    if ! grep -qE "^Include home-routes.conf" "$config" 2>/dev/null; then
        log "Adding 'Include home-routes.conf' at the top of $config"
        local tmp; tmp=$(mktemp)
        { echo "# Home machines by one name in his channel order (pi5/nas, desktop-auto): local-bootstrapping dotfiles/ssh/home-routes.conf"
          echo "Include home-routes.conf"; echo; cat "$config"; } > "$tmp" && cat "$tmp" > "$config"
        rm -f "$tmp"
    fi
    if grep -qE "^ *HostName 192\.168\.29\.10" "$config" 2>/dev/null; then
        warn "$config still has the old-house pi5 address 192.168.29.10; home-routes.conf overrides it, remove that block by hand"
    fi
    mkdir -p "$SSH_DIR/cm" && chmod 700 "$SSH_DIR/cm"

    # Pi5 LAN fallback. The Pi runs no firewall (ufw inactive), so port 22 has
    # always been open on the LAN - it was only ever unreachable because the
    # alias above points at a dead address on the old 192.168.29.x subnet and
    # ProxyJumps through desktop, inheriting desktop's Tailscale dependency.
    # Direct, no jump host, no tailnet.
    if ! grep -qE "^Host pi5-lan\$" "$config" 2>/dev/null; then
        log "Adding SSH alias: pi5-lan -> 192.168.0.2 (direct LAN, no jump)"
        cat >> "$config" << EOF

# Raspberry Pi 5 - LAN fallback (works without Tailscale, no jump host)
Host pi5-lan
    HostName 192.168.0.2
    User pi
EOF
    fi

    log "SSH config updated. Aliases: desktop, laptop (+ -lan variants), pi5-lan; pi5/nas + desktop-auto via home-routes.conf"
}

show_public_key() {
    echo ""
    info "Your public key (share with other devices):"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""
}

exchange_keys_interactive() {
    local my_device=$(detect_device)
    local my_ip=$(tailscale ip -4 2>/dev/null)

    echo ""
    info "This device: $my_device ($my_ip)"
    echo ""

    # Show other devices
    info "Other devices in your tailnet:"
    for device in "${DEVICES[@]}"; do
        local name=$(echo "$device" | cut -d: -f1)
        local ip=$(echo "$device" | cut -d: -f2)
        local desc=$(echo "$device" | cut -d: -f3)

        if [[ "$ip" != "$my_ip" ]]; then
            # Check if reachable
            if tailscale ping "$ip" -c 1 --timeout 2s &>/dev/null; then
                echo -e "  ${GREEN}●${NC} $desc ($ip) - online"
            else
                echo -e "  ${RED}●${NC} $desc ($ip) - offline"
            fi
        fi
    done

    echo ""
    info "To enable passwordless SSH between devices:"
    echo ""
    echo "  Option 1: Auto-exchange (if other device is online and accessible):"
    echo "    ssh-copy-id user@<other-device-ip>"
    echo ""
    echo "  Option 2: Manual exchange:"
    echo "    1. Copy your public key (shown above)"
    echo "    2. On the other device, add it to ~/.ssh/authorized_keys"
    echo ""
}

try_auto_exchange() {
    local my_ip=$(tailscale ip -4 2>/dev/null)

    log "Attempting automatic key exchange with reachable devices..."

    for device in "${DEVICES[@]}"; do
        local name=$(echo "$device" | cut -d: -f1)
        local ip=$(echo "$device" | cut -d: -f2)
        local desc=$(echo "$device" | cut -d: -f3)

        # Skip self
        [[ "$ip" == "$my_ip" ]] && continue

        # Check if device is reachable
        if ! tailscale ping "$ip" -c 1 --timeout 2s &>/dev/null; then
            warn "$desc ($ip) is offline, skipping"
            continue
        fi

        # Check if we already have access
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$ip" exit 2>/dev/null; then
            log "$desc ($ip) - already have passwordless access"
            continue
        fi

        # Try ssh-copy-id (will prompt for password)
        info "Attempting key exchange with $desc ($ip)..."
        info "You may be prompted for the password on that device."

        if ssh-copy-id -o ConnectTimeout=10 "$USER@$ip" 2>/dev/null; then
            log "Key exchanged successfully with $desc"
        else
            warn "Could not exchange key with $desc (password may be needed manually)"
        fi
    done
}

ensure_authorized_keys() {
    mkdir -p "$SSH_DIR"
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
}

main() {
    echo -e "${CYAN}=== SSH Synergy Setup ===${NC}"
    echo ""

    # Tailscale is preferred but no longer required. Bailing out here used to
    # make this script unusable in exactly the situation it now fixes: Tailscale
    # down, and needing to configure the LAN fallback. Degrade instead of dying -
    # the tailnet-dependent steps (auto key exchange) check for it themselves.
    if ! command -v tailscale &>/dev/null || ! tailscale status &>/dev/null; then
        warn "Tailscale is not running - configuring LAN paths only."
        warn "Re-run once Tailscale is up to finish tailnet key exchange."
    fi

    install_ssh_server
    generate_ssh_key
    ensure_authorized_keys
    setup_ssh_config
    show_public_key

    # Ask about auto-exchange
    echo ""
    read -p "Attempt automatic key exchange with other devices? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        try_auto_exchange
    else
        exchange_keys_interactive
    fi

    # Must run after key exchange - it refuses to act on an empty authorized_keys.
    harden_sshd

    echo ""
    log "SSH setup complete!"
    echo ""
    info "Quick test commands:"
    echo "  ssh desktop   # SSH to desktop"
    echo "  ssh laptop    # SSH to laptop"
}

# Only auto-run when executed directly. Sourcing the script exposes its
# functions individually (e.g. `source setup-ssh.sh; harden_sshd`), which
# matters because main() is interactive and cannot run unattended.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
