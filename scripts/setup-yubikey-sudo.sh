#!/bin/bash
# Setup YubiKey FIDO2 as priority sudo auth method
# Deploys PAM sudo config: YubiKey first, fingerprint fallback, then password
#
# Prerequisites: YubiKey credential already registered in /etc/fido2/fido2
# To register: pamu2fcfg | sudo tee /etc/fido2/fido2

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PAM_CONFIG="$REPO_ROOT/system/pam.d/sudo"
PAM_TARGET="/etc/pam.d/sudo"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    info "Checking prerequisites..."

    # Check pam-u2f is installed
    if ! pacman -Q pam-u2f &>/dev/null; then
        info "Installing pam-u2f and libfido2..."
        sudo pacman -S --needed --noconfirm pam-u2f libfido2
    fi

    # Check pam_u2f.so exists
    if [[ ! -f /usr/lib/security/pam_u2f.so ]]; then
        error "pam_u2f.so not found even after install"
        return 1
    fi
    success "pam_u2f.so available"

    # Check FIDO2 credentials directory
    if [[ ! -d /etc/fido2 ]]; then
        info "Creating /etc/fido2 directory..."
        sudo mkdir -p /etc/fido2
    fi

    # Warn if no credentials registered yet
    if [[ ! -f /etc/fido2/fido2 ]] || [[ ! -s /etc/fido2/fido2 ]]; then
        warn "No FIDO2 credentials registered in /etc/fido2/fido2"
        warn "Register with: pamu2fcfg | sudo tee /etc/fido2/fido2"
        warn "Deploying PAM config anyway — YubiKey auth will fail gracefully to fingerprint/password"
    else
        success "FIDO2 credentials found"
    fi

    return 0
}

check_if_configured() {
    if [[ -f "$PAM_TARGET" ]] && grep -q "pam_u2f.so" "$PAM_TARGET"; then
        # Check ordering: u2f should come before fprintd
        local u2f_line fprintd_line
        u2f_line=$(grep -n "pam_u2f.so" "$PAM_TARGET" | head -1 | cut -d: -f1)
        fprintd_line=$(grep -n "pam_fprintd.so" "$PAM_TARGET" | head -1 | cut -d: -f1)

        if [[ -n "$u2f_line" ]] && [[ -n "$fprintd_line" ]] && [[ "$u2f_line" -lt "$fprintd_line" ]]; then
            success "YubiKey sudo already configured with correct priority"
            return 0
        else
            info "pam_u2f present but not prioritized — will redeploy"
            return 1
        fi
    fi
    return 1
}

deploy_pam_config() {
    info "Backing up current sudo PAM config..."
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    sudo cp "$PAM_TARGET" "${PAM_TARGET}.bak.${timestamp}"
    success "Backup: ${PAM_TARGET}.bak.${timestamp}"

    info "Deploying YubiKey-priority sudo PAM config..."
    sudo cp "$PAM_CONFIG" "$PAM_TARGET"
    success "PAM sudo config deployed"
}

verify_deployment() {
    info "Verifying deployment..."

    if ! grep -q "pam_u2f.so" "$PAM_TARGET"; then
        error "pam_u2f.so not found in deployed config"
        return 1
    fi

    if ! grep -q "pam_fprintd.so" "$PAM_TARGET"; then
        error "pam_fprintd.so not found (fingerprint fallback missing)"
        return 1
    fi

    if ! grep -q "system-auth" "$PAM_TARGET"; then
        error "system-auth include missing (password fallback broken)"
        return 1
    fi

    # Verify ordering
    local u2f_line fprintd_line
    u2f_line=$(grep -n "pam_u2f.so" "$PAM_TARGET" | head -1 | cut -d: -f1)
    fprintd_line=$(grep -n "pam_fprintd.so" "$PAM_TARGET" | head -1 | cut -d: -f1)

    if [[ "$u2f_line" -ge "$fprintd_line" ]]; then
        error "Wrong order: pam_u2f must come before pam_fprintd"
        return 1
    fi

    success "Deployment verified: YubiKey → Fingerprint → Password"
    return 0
}

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  YubiKey FIDO2 Sudo Authentication Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! check_prerequisites; then
        error "Prerequisites not met. Exiting."
        exit 1
    fi

    if check_if_configured; then
        info "Nothing to do. Exiting."
        exit 0
    fi

    deploy_pam_config

    if ! verify_deployment; then
        error "Verification failed — restoring backup"
        local latest_backup
        latest_backup=$(ls -t "${PAM_TARGET}".bak.* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            sudo cp "$latest_backup" "$PAM_TARGET"
            success "Rolled back to $latest_backup"
        fi
        exit 1
    fi

    echo ""
    echo -e "${GREEN}Done!${NC} Sudo auth order: YubiKey tap → Fingerprint → Password"
    echo ""
    if [[ ! -f /etc/fido2/fido2 ]] || [[ ! -s /etc/fido2/fido2 ]]; then
        echo -e "${YELLOW}Remember to register your YubiKey:${NC}"
        echo "  pamu2fcfg | sudo tee /etc/fido2/fido2"
        echo ""
    fi
}

main "$@"
