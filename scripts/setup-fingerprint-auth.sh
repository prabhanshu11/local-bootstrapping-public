#!/bin/bash
# Setup fingerprint authentication for SDDM and TTY login
# Safe, idempotent deployment with automatic rollback on failure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PAM_CONFIG="$REPO_ROOT/system/pam.d/system-login"
PAM_TARGET="/etc/pam.d/system-login"
BACKUP_DIR="/etc/pam.d"
SYSTEMD_DROPIN="$REPO_ROOT/system/systemd/sddm.service.d/fprintd.conf"
SYSTEMD_TARGET="/etc/systemd/system/sddm.service.d"
SYSTEMD_CONF="$SYSTEMD_TARGET/fprintd.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if fingerprint reader hardware exists
check_hardware() {
    info "Checking for fingerprint reader hardware..."

    # Check via lsusb for fingerprint devices
    if lsusb | grep -iq fingerprint; then
        success "Fingerprint reader detected via lsusb"
        return 0
    fi

    # Check if fprintd can list devices
    if fprintd-list "$USER" &>/dev/null; then
        success "Fingerprint reader detected via fprintd"
        return 0
    fi

    warn "No fingerprint reader detected"
    return 1
}

# Verify prerequisites
check_prerequisites() {
    info "Verifying prerequisites..."

    # Check if fprintd is installed
    if ! command -v fprintd-enroll &> /dev/null; then
        error "fprintd is not installed. Install with: sudo pacman -S fprintd"
        return 1
    fi

    # Check if pam_fprintd.so exists
    if [[ ! -f /usr/lib/security/pam_fprintd.so ]]; then
        error "pam_fprintd.so not found. Install fprintd package."
        return 1
    fi

    # Check if fingerprints are enrolled
    if ! fprintd-list "$USER" 2>&1 | grep -qE " - #[0-9]+:"; then
        warn "No fingerprints enrolled for user $USER"
        echo ""
        echo "Enroll fingerprints with: fprintd-enroll"
        echo "Or: fprintd-enroll -f right-index-finger"
        echo ""
        read -p "Continue setup anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Setup cancelled. Enroll fingerprints first."
            return 1
        fi
    else
        success "Fingerprints enrolled for $USER"
    fi

    return 0
}

# Check if already configured
check_if_configured() {
    local pam_configured=false
    local systemd_configured=false

    if grep -q "pam_fprintd.so" "$PAM_TARGET" 2>/dev/null; then
        success "Fingerprint auth already configured in $PAM_TARGET"
        pam_configured=true
    fi

    if [[ -f "$SYSTEMD_CONF" ]]; then
        success "systemd drop-in already deployed: $SYSTEMD_CONF"
        systemd_configured=true
    fi

    if [[ "$pam_configured" == true ]] && [[ "$systemd_configured" == true ]]; then
        return 0
    fi
    return 1
}

# Deploy systemd drop-in to ensure fprintd starts before SDDM
deploy_systemd_dropin() {
    info "Deploying systemd drop-in to start fprintd before SDDM..."

    if [[ ! -f "$SYSTEMD_DROPIN" ]]; then
        error "systemd drop-in not found in repo: $SYSTEMD_DROPIN"
        return 1
    fi

    # Create drop-in directory
    sudo mkdir -p "$SYSTEMD_TARGET"

    # Deploy drop-in
    sudo cp "$SYSTEMD_DROPIN" "$SYSTEMD_CONF"

    if [[ $? -eq 0 ]]; then
        success "systemd drop-in deployed to $SYSTEMD_CONF"

        # Reload systemd to pick up the drop-in
        info "Reloading systemd daemon..."
        sudo systemctl daemon-reload

        if [[ $? -eq 0 ]]; then
            success "systemd daemon reloaded"
            return 0
        else
            error "Failed to reload systemd daemon"
            return 1
        fi
    else
        error "Failed to deploy systemd drop-in"
        return 1
    fi
}

# Backup current PAM configuration
backup_pam_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${PAM_TARGET}.bak.${timestamp}"

    info "Backing up current PAM configuration..."
    sudo cp "$PAM_TARGET" "$backup_file"

    if [[ -f "$backup_file" ]]; then
        success "Backup created: $backup_file"
        echo "$backup_file"
        return 0
    else
        error "Failed to create backup"
        return 1
    fi
}

# Deploy new PAM configuration
deploy_pam_config() {
    info "Deploying fingerprint-enabled PAM configuration..."

    if [[ ! -f "$PAM_CONFIG" ]]; then
        error "PAM config not found in repo: $PAM_CONFIG"
        return 1
    fi

    sudo cp "$PAM_CONFIG" "$PAM_TARGET"

    if [[ $? -eq 0 ]]; then
        success "PAM configuration deployed to $PAM_TARGET"
        return 0
    else
        error "Failed to deploy PAM configuration"
        return 1
    fi
}

# Verify deployment
verify_deployment() {
    info "Verifying deployment..."

    # Check for pam_fprintd.so line
    if ! grep -q "auth.*sufficient.*pam_fprintd.so" "$PAM_TARGET"; then
        error "pam_fprintd.so line not found in deployed config"
        return 1
    fi

    # Check for system-auth include (password fallback)
    if ! grep -q "auth.*include.*system-auth" "$PAM_TARGET"; then
        error "system-auth include missing (password fallback broken)"
        return 1
    fi

    # Check systemd drop-in exists
    if [[ ! -f "$SYSTEMD_CONF" ]]; then
        error "systemd drop-in not found: $SYSTEMD_CONF"
        return 1
    fi

    # Verify drop-in content
    if ! grep -q "Wants=fprintd.service" "$SYSTEMD_CONF" || ! grep -q "After=fprintd.service" "$SYSTEMD_CONF"; then
        error "systemd drop-in has incorrect content"
        return 1
    fi

    # Check fprintd service
    if ! systemctl is-active --quiet fprintd.service && ! systemctl start fprintd.service 2>/dev/null; then
        warn "fprintd service not running (will start on-demand)"
    fi

    success "Deployment verification passed"
    return 0
}

# Rollback to backup
rollback() {
    local backup_file="$1"

    error "Deployment failed. Rolling back..."

    if [[ -f "$backup_file" ]]; then
        sudo cp "$backup_file" "$PAM_TARGET"
        if [[ $? -eq 0 ]]; then
            success "Rollback complete. Original configuration restored."
            return 0
        else
            error "Rollback failed! Manual intervention required."
            error "Restore manually: sudo cp $backup_file $PAM_TARGET"
            return 1
        fi
    else
        error "Backup file not found: $backup_file"
        error "Restore from Arch default: sudo cp /usr/share/factory/etc/pam.d/system-login $PAM_TARGET"
        return 1
    fi
}

# Print testing instructions
print_testing_instructions() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Setup Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Fingerprint authentication is now enabled for:"
    echo "  • SDDM login screen"
    echo "  • Lock screen"
    echo "  • TTY login"
    echo ""
    echo -e "${BLUE}What was configured:${NC}"
    echo "  • PAM module (pam_fprintd.so) in /etc/pam.d/system-login"
    echo "  • systemd drop-in to start fprintd before SDDM"
    echo "  • Password fallback preserved for safety"
    echo ""
    echo -e "${YELLOW}Testing Instructions:${NC}"
    echo ""
    echo "Phase 1 - Non-destructive tests:"
    echo "  1. Lock screen (Super+L) → touch fingerprint reader"
    echo "  2. sudo echo test → verify sudo fingerprint still works"
    echo ""
    echo "Phase 2 - Login testing:"
    echo "  3. Log out → SDDM → touch fingerprint reader"
    echo "  4. Wait 30s → verify password prompt appears (fallback)"
    echo "  5. Log in with password → verify fallback works"
    echo ""
    echo "Phase 3 - Reboot testing:"
    echo "  6. Reboot → SDDM cold boot → touch fingerprint reader"
    echo ""
    echo -e "${YELLOW}If issues occur:${NC}"
    echo ""
    echo "Manual rollback (latest backup):"
    echo "  sudo cp ${PAM_TARGET}.bak.* $PAM_TARGET"
    echo ""
    echo "Rollback to Arch default:"
    echo "  sudo cp /usr/share/factory/etc/pam.d/system-login $PAM_TARGET"
    echo ""
    echo -e "${BLUE}Note:${NC} Password fallback is always available. Even if fingerprint"
    echo "      fails, you can still log in with your password."
    echo ""
}

# Main execution
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Fingerprint Authentication Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Hardware check
    if ! check_hardware; then
        error "No fingerprint reader detected. Exiting."
        exit 0
    fi

    # Prerequisites check
    if ! check_prerequisites; then
        error "Prerequisites not met. Exiting."
        exit 1
    fi

    # Check if already configured
    if check_if_configured; then
        info "Nothing to do. Exiting."
        exit 0
    fi

    # Backup current config
    backup_file=$(backup_pam_config)
    if [[ $? -ne 0 ]]; then
        error "Backup failed. Aborting."
        exit 1
    fi

    # Deploy systemd drop-in first (ensures fprintd starts before SDDM)
    if ! deploy_systemd_dropin; then
        error "systemd drop-in deployment failed. Aborting."
        exit 1
    fi

    # Deploy new config
    if ! deploy_pam_config; then
        rollback "$backup_file"
        exit 1
    fi

    # Verify deployment
    if ! verify_deployment; then
        rollback "$backup_file"
        exit 1
    fi

    # Print testing instructions
    print_testing_instructions

    exit 0
}

main "$@"
