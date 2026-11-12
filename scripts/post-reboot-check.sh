#!/bin/bash
# post-reboot-check.sh - Run after system reboot to verify recovery
#
# Usage:
#   ./scripts/post-reboot-check.sh
#
# This script:
# 1. Captures post-reboot waybar screenshot
# 2. Runs automated tests
# 3. Displays manual checklist

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Post-Reboot Recovery Verification${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. Capture post-reboot screenshot
echo -e "${YELLOW}[1/3]${NC} Capturing waybar screenshot..."
timestamp=$(date +%Y%m%d-%H%M%S)
tmpfile="/tmp/waybar-full-${timestamp}.png"
screenshot_path="tests/visual/screenshots/post-reboot-waybar-${timestamp}.png"

grim "$tmpfile"
magick "$tmpfile" -crop "2560x40+0+0" "$screenshot_path"
rm "$tmpfile"

echo -e "${GREEN}✓${NC} Screenshot saved: $screenshot_path"
echo ""

# 2. Run automated tests
echo -e "${YELLOW}[2/3]${NC} Running automated tests..."
if pytest tests/acceptance/test_post_reboot.py -m reboot -v; then
    echo ""
    echo -e "${GREEN}✓ All automated tests PASSED${NC}"
else
    echo ""
    echo -e "${RED}✗ Some tests FAILED - check output above${NC}"
fi
echo ""

# 3. Display manual checklist
echo -e "${YELLOW}[3/3]${NC} Manual verification checklist:"
echo ""
cat tests/acceptance/checklists/reboot_checklist.md

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "Screenshots for comparison:"
echo -e "  Baseline:     $(ls -t tests/visual/screenshots/baseline-* | head -1)"
echo -e "  Post-reboot:  $screenshot_path"
echo ""
echo -e "Compare visually or use:"
echo -e "  magick compare baseline.png post-reboot.png diff.png"
echo -e "${CYAN}========================================${NC}"
