#!/bin/bash
# fix-python-sitepackages.sh - Detect and fix stale Python site-packages after major version upgrade
#
# Problem: pacman -Syu can upgrade Python (e.g. 3.13→3.14) without rebuilding all
# dependent packages. This leaves modules in the old site-packages dir, breaking
# tools like uwsm (which kills the desktop session on login).
#
# Usage:
#   ./scripts/fix-python-sitepackages.sh          # Detect only (dry run)
#   ./scripts/fix-python-sitepackages.sh --fix     # Detect and fix
#
# Can be called from:
#   - post-reboot-check.sh (automatic detection)
#   - systemd service (auto-repair before SDDM starts)
#   - Manual recovery from TTY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$HOME/Programs/local-bootstrapping/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/python-sitepackages-fix-$(date +%Y%m%d-%H%M%S).log"

# Colors (only if terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

FIX_MODE=false
if [[ "${1:-}" == "--fix" ]]; then
    FIX_MODE=true
fi

log() {
    echo -e "$1"
    echo -e "$1" >> "$LOGFILE" 2>/dev/null || true
}

# Get current Python major.minor version
CURRENT_PY=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
log "${GREEN}Current Python: $CURRENT_PY${NC}"

# Find old Python site-packages directories
OLD_DIRS=()
for dir in /usr/lib/python3.*/site-packages; do
    ver=$(echo "$dir" | grep -oP 'python\K3\.\d+')
    if [[ "$ver" != "$CURRENT_PY" ]] && [ -d "$dir" ]; then
        OLD_DIRS+=("$ver")
    fi
done

if [ ${#OLD_DIRS[@]} -eq 0 ]; then
    log "${GREEN}No stale Python site-packages found. System is clean.${NC}"
    exit 0
fi

log "${YELLOW}Found stale site-packages for Python: ${OLD_DIRS[*]}${NC}"
log "Current Python is $CURRENT_PY"

# Find affected packages
STALE_PKGS=()
for old_ver in "${OLD_DIRS[@]}"; do
    while IFS= read -r pkg; do
        STALE_PKGS+=("$pkg")
    done < <(pacman -Qq | while read -r pkg; do
        pacman -Ql "$pkg" 2>/dev/null | grep -q "python${old_ver}/site-packages" && echo "$pkg"
    done)
done

# Deduplicate
mapfile -t STALE_PKGS < <(printf '%s\n' "${STALE_PKGS[@]}" | sort -u)

if [ ${#STALE_PKGS[@]} -eq 0 ]; then
    log "${GREEN}No packages with stale Python modules found.${NC}"
    exit 0
fi

log "${RED}Found ${#STALE_PKGS[@]} packages with stale Python site-packages:${NC}"
printf '%s\n' "${STALE_PKGS[@]}" | tee -a "$LOGFILE"

# Check if uwsm is affected (critical — breaks desktop)
UWSM_BROKEN=false
if python3 -c "import sys; sys.path.insert(1, '/usr/share/uwsm/modules'); from uwsm.main import main" 2>/dev/null; then
    log "${GREEN}uwsm imports: OK${NC}"
else
    log "${RED}uwsm imports: BROKEN — desktop login will fail!${NC}"
    UWSM_BROKEN=true
fi

if ! $FIX_MODE; then
    log ""
    log "${YELLOW}Dry run complete. To fix, run:${NC}"
    log "  $0 --fix"
    if $UWSM_BROKEN; then
        log ""
        log "${RED}WARNING: uwsm is broken. Desktop will not start until fixed.${NC}"
    fi
    exit 1
fi

# Fix mode — separate repo packages from AUR
REPO_PKGS=()
AUR_PKGS=()
for pkg in "${STALE_PKGS[@]}"; do
    if pacman -Si "$pkg" &>/dev/null; then
        REPO_PKGS+=("$pkg")
    else
        AUR_PKGS+=("$pkg")
    fi
done

log ""
log "Reinstalling ${#REPO_PKGS[@]} packages from official repos..."

if [ ${#REPO_PKGS[@]} -gt 0 ]; then
    # Try without util-linux-libs first (common dep conflict)
    FILTERED_PKGS=()
    for pkg in "${REPO_PKGS[@]}"; do
        if [[ "$pkg" != "util-linux-libs" ]]; then
            FILTERED_PKGS+=("$pkg")
        fi
    done

    if sudo pacman -S --noconfirm "${FILTERED_PKGS[@]}" 2>&1 | tee -a "$LOGFILE"; then
        log "${GREEN}Official repo packages reinstalled successfully.${NC}"
    else
        log "${RED}Some packages failed to reinstall. Check log: $LOGFILE${NC}"
    fi
fi

if [ ${#AUR_PKGS[@]} -gt 0 ]; then
    log "${YELLOW}AUR packages need manual rebuild:${NC}"
    printf '  %s\n' "${AUR_PKGS[@]}" | tee -a "$LOGFILE"
    log "Run: yay -S --noconfirm ${AUR_PKGS[*]}"
fi

# Verify uwsm after fix
if python3 -c "import sys; sys.path.insert(1, '/usr/share/uwsm/modules'); from uwsm.main import main" 2>/dev/null; then
    log "${GREEN}uwsm imports: OK — desktop should work now.${NC}"
    log "Restart SDDM to recover: sudo systemctl restart sddm"
else
    log "${RED}uwsm still broken after fix. Manual intervention needed.${NC}"
    exit 1
fi

log ""
log "Log saved to: $LOGFILE"
