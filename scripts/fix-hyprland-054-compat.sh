#!/bin/bash
# fix-hyprland-054-compat.sh — Patch Omarchy default Hyprland configs for v0.54 (windowrule v3)
#
# Hyprland 0.54 introduced "windowrule v3" syntax:
#   Old: windowrule = action, class:pattern
#   New: windowrule = effect value, match:class pattern
#
# This script patches ~/.local/share/omarchy/default/hypr/ in-place.
# Safe to re-run (idempotent — checks for already-converted syntax).
#
# Usage:
#   ./fix-hyprland-054-compat.sh          # Patch and verify
#   ./fix-hyprland-054-compat.sh --check  # Only check, don't patch

set -euo pipefail

OMARCHY_HYPR="$HOME/.local/share/omarchy/default/hypr"
CHECK_ONLY=false

[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

# Check if Hyprland is actually 0.54+
check_hyprland_version() {
    local version
    version=$(hyprctl version -j 2>/dev/null | grep -oP '"tag"\s*:\s*"v?\K[0-9]+\.[0-9]+' || echo "0.0")
    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)

    if (( major > 0 || minor >= 54 )); then
        return 0  # 0.54+
    else
        warn "Hyprland version $version detected (< 0.54). Patch may not be needed."
        return 0  # Still allow running — user may want to prep
    fi
}

# Check if files need patching (look for old syntax markers)
needs_patching() {
    # Check for old-style matchers: ", class:" or ", title:" or ", tag:" etc.
    # Also check for old effect names without values: "= float," "= pin," etc.
    if grep -rqP 'windowrule\s*=\s*(float|pin|tile|center|fullscreen|nofocus|noborder|noshadow|noanim|noscreenshare|noinitialfocus|nofollowmouse|nodim|stayfocused|keepaspectratio|opaque)\s*,' "$OMARCHY_HYPR" 2>/dev/null; then
        return 0
    fi
    if grep -rqP 'windowrule\s*=.*,\s*(class|title|tag|floating|pinned|xwayland|fullscreen|initialTitle):' "$OMARCHY_HYPR" 2>/dev/null; then
        return 0
    fi
    if grep -qP 'new_window_takes_over_fullscreen' "$OMARCHY_HYPR/looknfeel.conf" 2>/dev/null; then
        return 0
    fi
    return 1  # Already patched
}

# ============================================================================
# Patch functions
# ============================================================================

patch_looknfeel() {
    local file="$OMARCHY_HYPR/looknfeel.conf"
    [[ -f "$file" ]] || return 0

    if grep -q 'new_window_takes_over_fullscreen' "$file"; then
        log "Patching looknfeel.conf: new_window_takes_over_fullscreen → on_focus_under_fullscreen"
        sed -i 's/new_window_takes_over_fullscreen\s*=\s*\([0-9]\)/on_focus_under_fullscreen = \1/' "$file"
    fi
}

patch_windows() {
    local file="$OMARCHY_HYPR/windows.conf"
    [[ -f "$file" ]] || return 0

    log "Patching windows.conf"

    # Line 2: windowrule = suppressevent maximize, class:.*
    # → windowrule = suppress_event maximize, match:class .*
    sed -i 's/^windowrule = suppressevent \(.*\), class:\(.*\)/windowrule = suppress_event \1, match:class \2/' "$file"

    # Line 5: windowrule = opacity 0.97 0.9, class:.*
    # → windowrule = opacity 0.97 0.9, match:class .*
    # (opacity syntax unchanged, just matcher)
    sed -i '/^windowrule = opacity/s/, class:\(.*\)/, match:class \1/' "$file"

    # Line 8: windowrule = nofocus,class:^$,title:^$,xwayland:1,floating:1,fullscreen:0,pinned:0
    # → windowrule = no_focus true, match:class ^$, match:title ^$, match:xwayland 1, match:float 1, match:fullscreen 0, match:pin 0
    sed -i 's/^windowrule = nofocus,class:\^$,title:\^$,xwayland:1,floating:1,fullscreen:0,pinned:0/windowrule = no_focus true, match:class ^$, match:title ^$, match:xwayland 1, match:float 1, match:fullscreen 0, match:pin 0/' "$file"
}

# Generic windowrule line converter for app configs
# Converts old-style windowrule lines to v3 syntax
convert_windowrule_line() {
    local file="$1"

    # Skip if file doesn't exist
    [[ -f "$file" ]] || return 0

    log "Patching $(basename "$file")"

    # ---- Step 1: Convert effect names (action part, before the comma) ----

    # Boolean effects that need "true" appended (must come before matcher conversion)
    # Pattern: "windowrule = float," → "windowrule = float true,"
    local -a bool_effects=(
        float pin tile center fullscreen opaque
    )
    for effect in "${bool_effects[@]}"; do
        # Only match if it's the bare effect without a value (no space after effect before comma)
        sed -i "s/^windowrule = ${effect}\s*,/windowrule = ${effect} true,/" "$file"
    done

    # Renamed boolean effects
    sed -i 's/^windowrule = nofocus\s*,/windowrule = no_focus true,/' "$file"
    sed -i 's/^windowrule = noborder\s*,/windowrule = border_size 0,/' "$file"
    sed -i 's/^windowrule = noshadow\s*,/windowrule = no_shadow true,/' "$file"
    sed -i 's/^windowrule = noanim\s*,/windowrule = no_anim true,/' "$file"
    sed -i 's/^windowrule = noscreenshare\s*,/windowrule = no_screen_share true,/' "$file"
    sed -i 's/^windowrule = noinitialfocus\s*,/windowrule = no_initial_focus true,/' "$file"
    sed -i 's/^windowrule = nofollowmouse\s*,/windowrule = no_follow_mouse true,/' "$file"
    sed -i 's/^windowrule = nodim\s*,/windowrule = no_dim true,/' "$file"
    sed -i 's/^windowrule = stayfocused\s*,/windowrule = stay_focused true,/' "$file"
    sed -i 's/^windowrule = keepaspectratio\s*,/windowrule = keep_aspect_ratio true,/' "$file"

    # Effects with values that just need renaming
    sed -i 's/^windowrule = idleinhibit /windowrule = idle_inhibit /' "$file"
    sed -i 's/^windowrule = suppressevent /windowrule = suppress_event /' "$file"
    sed -i 's/^windowrule = scrolltouchpad /windowrule = scroll_touchpad /' "$file"

    # ---- Step 1b: Layerrule renames (same pattern as windowrule) ----
    # Layerrules also need value + match:namespace prefix in v3
    # Old: layerrule = noanim, selection
    # New: layerrule = no_anim true, match:namespace selection
    sed -i 's/^layerrule = noanim\s*,\s*\(.*\)/layerrule = no_anim true, match:namespace \1/' "$file"
    sed -i 's/^layerrule = nofocus\s*,\s*\(.*\)/layerrule = no_focus true, match:namespace \1/' "$file"

    # ---- Step 2: Convert matchers (after the comma) ----

    # class:PATTERN → match:class PATTERN
    sed -i 's/, class:\([^,]*\)/, match:class \1/g' "$file"
    sed -i 's/,class:\([^,]*\)/, match:class \1/g' "$file"

    # title:PATTERN → match:title PATTERN
    sed -i 's/, title:\([^,]*\)/, match:title \1/g' "$file"
    sed -i 's/,title:\([^,]*\)/, match:title \1/g' "$file"

    # tag:NAME → match:tag NAME
    sed -i 's/, tag:\([^,]*\)/, match:tag \1/g' "$file"
    sed -i 's/,tag:\([^,]*\)/, match:tag \1/g' "$file"

    # floating:N → match:float N
    sed -i 's/, floating:\([^,]*\)/, match:float \1/g' "$file"
    sed -i 's/,floating:\([^,]*\)/, match:float \1/g' "$file"

    # pinned:N → match:pin N
    sed -i 's/, pinned:\([^,]*\)/, match:pin \1/g' "$file"
    sed -i 's/,pinned:\([^,]*\)/, match:pin \1/g' "$file"

    # xwayland:N → match:xwayland N
    sed -i 's/, xwayland:\([^,]*\)/, match:xwayland \1/g' "$file"
    sed -i 's/,xwayland:\([^,]*\)/, match:xwayland \1/g' "$file"

    # fullscreen:N → match:fullscreen N (in matcher position, after comma)
    # Be careful not to match the effect "fullscreen" before the comma
    sed -i 's/, fullscreen:\([^,]*\)/, match:fullscreen \1/g' "$file"
    sed -i 's/,fullscreen:\([^,]*\)/, match:fullscreen \1/g' "$file"

    # initialTitle:PATTERN → match:initial_title PATTERN
    sed -i 's/, initialTitle:\([^,]*\)/, match:initial_title \1/g' "$file"
    sed -i 's/,initialTitle:\([^,]*\)/, match:initial_title \1/g' "$file"

    # fullscreenstate:PATTERN → match:fullscreenstate PATTERN
    sed -i 's/, fullscreenstate:\([^,]*\)/, match:fullscreenstate \1/g' "$file"
    sed -i 's/,fullscreenstate:\([^,]*\)/, match:fullscreenstate \1/g' "$file"

    # ---- Step 3: Fix regex issues from 0.53 ----
    # [p|P] → [pP], [F|f] → [Ff], [C|c] → [Cc]
    sed -i 's/\[p|P\]/[pP]/g' "$file"
    sed -i 's/\[F|f\]/[Ff]/g' "$file"
    sed -i 's/\[C|c\]/[Cc]/g' "$file"
    # [open|save] → (open|save) — alternation needs parens not brackets
    sed -i 's/\[open|save\]/(open|save)/g' "$file"
}

# ============================================================================
# Main
# ============================================================================

main() {
    check_hyprland_version

    if [[ ! -d "$OMARCHY_HYPR" ]]; then
        warn "Omarchy hypr config dir not found: $OMARCHY_HYPR"
        warn "Skipping Omarchy default patching (may not be an Omarchy system)"
        return 0
    fi

    if ! needs_patching; then
        log "Omarchy configs already patched for v0.54 syntax"
        return 0
    fi

    if $CHECK_ONLY; then
        warn "Configs need patching. Run without --check to apply."
        return 1
    fi

    log "Patching Omarchy default configs for Hyprland 0.54 (windowrule v3)..."

    # Patch looknfeel.conf (misc option rename)
    patch_looknfeel

    # Patch windows.conf (3 rules with complex matchers)
    patch_windows

    # Patch all app configs
    for conf in "$OMARCHY_HYPR"/apps/*.conf; do
        [[ -f "$conf" ]] && convert_windowrule_line "$conf"
    done

    log "All Omarchy default configs patched."

    # Verify
    if command -v hyprctl &>/dev/null; then
        log "Reloading Hyprland config..."
        hyprctl reload &>/dev/null || true
        sleep 0.5

        local errors
        errors=$(hyprctl configerrors 2>/dev/null || echo "")
        if [[ -z "$errors" || "$errors" == "no errors" ]]; then
            log "Config verification: 0 errors"
        else
            # Count unique errors (filter out cascading duplicates)
            local unique_errors
            unique_errors=$(echo "$errors" | grep -c "^Config error" || echo "0")
            if [[ "$unique_errors" -gt 0 ]]; then
                warn "Still $unique_errors config error line(s) — may include non-windowrule issues"
                echo "$errors" | grep "^Config error" | head -10
            fi
        fi
    fi
}

main "$@"
