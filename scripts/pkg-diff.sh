#!/bin/bash
# pkg-diff.sh - Show packages installed beyond vanilla omarchy
# This compares explicitly installed packages against the omarchy base

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VANILLA_LIST="$REPO_ROOT/packages/vanilla-omarchy.txt"
OUTPUT_DIR="$REPO_ROOT/packages"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  diff      Show packages not in vanilla omarchy (default)"
    echo "  save      Save current non-vanilla packages to machine list"
    echo "  update    Update vanilla baseline from fresh omarchy install"
    echo "  install   Install packages from saved lists"
    echo ""
}

get_explicit_packages() {
    pacman -Qeq | sort
}

get_vanilla_packages() {
    if [[ -f "$VANILLA_LIST" ]]; then
        sort "$VANILLA_LIST"
    else
        echo "Warning: No vanilla list found. Run '$0 update' on a fresh install." >&2
        echo ""
    fi
}

diff_packages() {
    local current=$(get_explicit_packages)
    local vanilla=$(get_vanilla_packages)

    if [[ -z "$vanilla" ]]; then
        echo -e "${YELLOW}No vanilla baseline. Showing all explicit packages:${NC}"
        echo "$current"
        return
    fi

    echo -e "${GREEN}=== Non-default packages ($(hostname)) ===${NC}"
    echo ""

    # Packages added (in current but not vanilla)
    local added=$(comm -23 <(echo "$current") <(echo "$vanilla"))
    if [[ -n "$added" ]]; then
        echo -e "${GREEN}Added packages:${NC}"
        echo "$added" | while read pkg; do
            desc=$(pacman -Qi "$pkg" 2>/dev/null | grep "^Description" | cut -d: -f2- | xargs)
            printf "  %-30s %s\n" "$pkg" "$desc"
        done
        echo ""
    fi

    # Packages removed (in vanilla but not current)
    local removed=$(comm -13 <(echo "$current") <(echo "$vanilla"))
    if [[ -n "$removed" ]]; then
        echo -e "${RED}Removed from vanilla:${NC}"
        echo "$removed"
        echo ""
    fi

    # Summary
    local added_count=$(echo "$added" | grep -c . || echo 0)
    local removed_count=$(echo "$removed" | grep -c . || echo 0)
    echo -e "${YELLOW}Summary: +$added_count added, -$removed_count removed${NC}"
}

save_packages() {
    local hostname=$(hostname)
    local outfile="$OUTPUT_DIR/${hostname}.txt"

    echo -e "${GREEN}Saving non-vanilla packages to $outfile${NC}"

    local vanilla=$(get_vanilla_packages)
    local current=$(get_explicit_packages)

    if [[ -z "$vanilla" ]]; then
        echo "$current" > "$outfile"
        echo "Saved all $(echo "$current" | wc -l) explicit packages (no vanilla baseline)"
    else
        comm -23 <(echo "$current") <(echo "$vanilla") > "$outfile"
        echo "Saved $(wc -l < "$outfile") non-vanilla packages"
    fi
}

update_vanilla() {
    echo -e "${YELLOW}This should be run on a FRESH omarchy install!${NC}"
    echo "Current hostname: $(hostname)"
    read -p "Are you sure this is a fresh install? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        get_explicit_packages > "$VANILLA_LIST"
        echo -e "${GREEN}Saved $(wc -l < "$VANILLA_LIST") packages to vanilla baseline${NC}"
    fi
}

install_packages() {
    local hostname=$(hostname)
    local common="$OUTPUT_DIR/common.txt"
    local machine="$OUTPUT_DIR/${hostname}.txt"

    local packages=""

    if [[ -f "$common" ]]; then
        packages+=$(cat "$common")
        packages+=$'\n'
    fi

    if [[ -f "$machine" ]]; then
        packages+=$(cat "$machine")
    fi

    if [[ -z "$packages" ]]; then
        echo "No package lists found for $(hostname)"
        exit 1
    fi

    echo -e "${GREEN}Installing packages for $(hostname)${NC}"
    echo "$packages" | sort -u | xargs yay -S --needed --noconfirm
}

case "${1:-diff}" in
    diff)    diff_packages ;;
    save)    save_packages ;;
    update)  update_vanilla ;;
    install) install_packages ;;
    -h|--help) show_help ;;
    *)       show_help; exit 1 ;;
esac
