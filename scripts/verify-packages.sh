#!/bin/bash
# verify-packages.sh - Check for missing dependencies from install.sh
#
# Usage: ./verify-packages.sh [--install]
#
# Compares installed packages against BASE_PACKAGES in install.sh
# and reports any missing packages.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "Error: install.sh not found at $INSTALL_SH"
    exit 1
fi

# Extract package names from install_base_deps() function in install.sh
# Packages are in: local packages=( pkg1 pkg2 ... )
extract_packages() {
    awk '/install_base_deps\(\)/,/^\}/' "$INSTALL_SH" | \
        awk '/local packages=\(/,/\)/' | \
        grep -v '^[[:space:]]*#' | \
        grep -v 'local packages=' | \
        grep -v '^[[:space:]]*$' | \
        grep -v ')' | \
        sed 's/#.*//' | \
        tr -d ' "' | \
        grep -v '^$'
}

EXPECTED=$(extract_packages)
MISSING=()
INSTALLED=()

for pkg in $EXPECTED; do
    if pacman -Q "$pkg" &>/dev/null; then
        INSTALLED+=("$pkg")
    else
        MISSING+=("$pkg")
    fi
done

echo "=== Package Verification ==="
echo "Expected: $(echo "$EXPECTED" | wc -w) packages"
echo "Installed: ${#INSTALLED[@]}"
echo "Missing: ${#MISSING[@]}"
echo ""

if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "All expected packages are installed."
    exit 0
fi

echo "Missing packages:"
printf '  - %s\n' "${MISSING[@]}"
echo ""

if [[ "${1:-}" == "--install" ]]; then
    echo "Installing missing packages..."
    sudo pacman -S --noconfirm "${MISSING[@]}"
else
    echo "To install: sudo pacman -S --noconfirm ${MISSING[*]}"
    echo "Or run: $0 --install"
fi

exit 1
