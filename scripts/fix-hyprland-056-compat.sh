#!/bin/bash
# fix-hyprland-056-compat.sh — Patch Omarchy default Hyprland configs for v0.56
#
# Hyprland 0.56 (desktop upgraded 0.54 -> 0.56.2 on 2026-09-24) rejects three
# things in Omarchy's defaults, and the red config-error bar covers the top of
# the screen until they are gone:
#   bindings/tiling-v2.conf  togglesplit dispatcher removed  -> layoutmsg, togglesplit
#   looknfeel.conf           col.border_locked_* = -1        -> lines dropped (default colour)
#   looknfeel.conf           dwindle:pseudotile removed      -> line dropped
#
# Only runs on 0.56+: on 0.55 pseudotile still gates Super+P and -1 still parses.
# `layoutmsg, togglesplit` works on older dwindle too, but stays gated for one rule.
# Idempotent. Pairs with fix-hyprland-054-compat.sh (windowrule v3).
#
# Usage:
#   ./fix-hyprland-056-compat.sh          # Patch and verify
#   ./fix-hyprland-056-compat.sh --check  # Only check, don't patch

set -euo pipefail

OMARCHY_HYPR="$HOME/.local/share/omarchy/default/hypr"
CHECK_ONLY=false

[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

is_056_or_newer() {
    local version major minor
    version=$(hyprctl version -j 2>/dev/null | grep -oP '"tag"\s*:\s*"v?\K[0-9]+\.[0-9]+' || echo "0.0")
    major=${version%%.*}
    minor=${version##*.}
    (( major > 0 || minor >= 56 ))
}

needs_patching() {
    grep -qP ',\s*togglesplit\s*,' "$OMARCHY_HYPR/bindings/tiling-v2.conf" 2>/dev/null && return 0
    grep -qP '^\s*col\.border_locked_(in)?active\s*=\s*-1' "$OMARCHY_HYPR/looknfeel.conf" 2>/dev/null && return 0
    grep -qP '^\s*pseudotile\s*=' "$OMARCHY_HYPR/looknfeel.conf" 2>/dev/null && return 0
    return 1
}

main() {
    if [[ ! -d "$OMARCHY_HYPR" ]]; then
        warn "Omarchy hypr config dir not found: $OMARCHY_HYPR — skipping"
        return 0
    fi

    if ! is_056_or_newer; then
        log "Hyprland < 0.56 — 0.56 compat patch not needed"
        return 0
    fi

    if ! needs_patching; then
        log "Omarchy configs already patched for Hyprland 0.56"
        return 0
    fi

    if $CHECK_ONLY; then
        warn "Configs need 0.56 patching. Run without --check to apply."
        return 1
    fi

    log "Patching Omarchy default configs for Hyprland 0.56..."
    sed -i -E 's/,\s*togglesplit\s*,/, layoutmsg, togglesplit/' "$OMARCHY_HYPR/bindings/tiling-v2.conf"
    sed -i -E '/^\s*col\.border_locked_(in)?active\s*=\s*-1/d' "$OMARCHY_HYPR/looknfeel.conf"
    sed -i -E '/^\s*pseudotile\s*=/d' "$OMARCHY_HYPR/looknfeel.conf"

    if command -v hyprctl &>/dev/null; then
        hyprctl reload &>/dev/null || true
        sleep 0.5
        local errors
        errors=$(hyprctl configerrors 2>/dev/null || echo "")
        if [[ -z "${errors//[[:space:]]/}" || "$errors" == "no errors" ]]; then
            log "Config verification: 0 errors"
        else
            warn "Config errors remain:"
            echo "$errors" | grep "^Config error" | sort -u | head -10
        fi
    fi
}

main "$@"
