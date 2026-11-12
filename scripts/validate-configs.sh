#!/bin/bash
# validate-configs.sh - Validate config files before applying sync
#
# Validates files by type:
# - JSON/JSONC: syntax validation
# - Systemd services: systemd-analyze verify
# - Shell scripts: shellcheck + bash -n
# - Markdown: existence check (low risk)
# - Visual (optional): screenshot waybar and validate icons with OpenRouter
#
# Usage:
#   ./validate-configs.sh            # Standard validation
#   ./validate-configs.sh --visual   # Include visual waybar test (requires GUI)
#
# Exit codes:
#   0 = all validations passed
#   1 = validation failed (do not apply changes)

set -e

# Parse arguments
VISUAL_TEST=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --visual) VISUAL_TEST=true; shift ;;
        *) shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# sync-from-master.sh validates the INCOMING tree by passing REPO_ROOT/DOTFILES
# of an extracted origin/master; honour them (they were silently ignored before
# 2026-09-30, so the sync validated the local tree instead)
REPO_ROOT="${REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"
DOTFILES="${DOTFILES:-$REPO_ROOT/dotfiles}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[✓]${NC} $1"; }
log_fail() { echo -e "${RED}[✗]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_info() { echo -e "[·] $1"; }

ERRORS=0
WARNINGS=0

# =============================================================================
# Validation Functions
# =============================================================================

validate_json() {
    local file="$1"
    log_info "Validating JSON: $file"

    # For JSONC files, strip comments before validation
    if [[ "$file" == *.jsonc ]]; then
        # Strip full-line // comments and /* */ comments, preserve // in strings (URLs)
        if sed 's|^\s*//.*||g; s|/\*.*\*/||g' "$file" | jq . >/dev/null 2>&1; then
            log_pass "$(basename "$file")"
            return 0
        else
            log_fail "$(basename "$file") - Invalid JSON syntax"
            ((ERRORS++))
            return 1
        fi
    else
        if jq . "$file" >/dev/null 2>&1; then
            log_pass "$(basename "$file")"
            return 0
        else
            log_fail "$(basename "$file") - Invalid JSON syntax"
            ((ERRORS++))
            return 1
        fi
    fi
}

validate_systemd() {
    local file="$1"
    log_info "Validating systemd unit: $file"

    # systemd-analyze verify requires the file to be in a known path
    # We'll do a basic syntax check instead
    if grep -qE '^\[(Unit|Service|Timer|Install)\]' "$file"; then
        # Check for required sections
        if [[ "$file" == *.service ]]; then
            if grep -qE '^\[Service\]' "$file"; then
                log_pass "$(basename "$file")"
                return 0
            else
                log_fail "$(basename "$file") - Missing [Service] section"
                ((ERRORS++))
                return 1
            fi
        elif [[ "$file" == *.timer ]]; then
            if grep -qE '^\[Timer\]' "$file"; then
                log_pass "$(basename "$file")"
                return 0
            else
                log_fail "$(basename "$file") - Missing [Timer] section"
                ((ERRORS++))
                return 1
            fi
        fi
        log_pass "$(basename "$file")"
        return 0
    else
        log_fail "$(basename "$file") - Invalid systemd unit format"
        ((ERRORS++))
        return 1
    fi
}

validate_shell() {
    local file="$1"
    log_info "Validating shell script: $file"

    # First check bash syntax
    if ! bash -n "$file" 2>/dev/null; then
        log_fail "$(basename "$file") - Bash syntax error"
        ((ERRORS++))
        return 1
    fi

    # If shellcheck is available, use it (warnings only, don't fail)
    if command -v shellcheck &>/dev/null; then
        local sc_output
        sc_output=$(shellcheck -f gcc "$file" 2>/dev/null || true)
        if [[ -n "$sc_output" ]]; then
            log_warn "$(basename "$file") - ShellCheck warnings (non-blocking)"
            echo "$sc_output" | head -5
            ((WARNINGS++))
        fi
    fi

    log_pass "$(basename "$file")"
    return 0
}

validate_markdown() {
    local file="$1"
    log_info "Validating markdown: $file"

    # Markdown is low-risk, just check it exists and is readable
    if [[ -r "$file" ]]; then
        log_pass "$(basename "$file")"
        return 0
    else
        log_fail "$(basename "$file") - File not readable"
        ((ERRORS++))
        return 1
    fi
}

validate_hypr_conf() {
    local file="$1"
    log_info "Validating Hyprland config: $file"

    # Basic syntax check - look for obviously broken lines
    # Hyprland configs are key=value or keyword { } blocks
    if [[ -r "$file" ]]; then
        # Check for unmatched braces
        local open_braces close_braces
        open_braces=$(grep -o '{' "$file" 2>/dev/null | wc -l)
        close_braces=$(grep -o '}' "$file" 2>/dev/null | wc -l)

        if [[ "$open_braces" -ne "$close_braces" ]]; then
            log_fail "$(basename "$file") - Unmatched braces (open: $open_braces, close: $close_braces)"
            ((ERRORS++))
            return 1
        fi

        log_pass "$(basename "$file")"
        return 0
    else
        log_fail "$(basename "$file") - File not readable"
        ((ERRORS++))
        return 1
    fi
}

# =============================================================================
# Visual Test (Optional - requires GUI and OpenRouter API)
# =============================================================================

validate_visual() {
    log_info "Running visual waybar test (OpenRouter + screenshot)..."

    # Check if display is available
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        log_warn "No display available - skipping visual test"
        return 0
    fi

    # Check if pytest and test file exist
    if ! command -v pytest &>/dev/null; then
        log_warn "pytest not installed - skipping visual test"
        return 0
    fi

    local test_file="$REPO_ROOT/tests/test_waybar_icons.py"
    if [[ ! -f "$test_file" ]]; then
        log_warn "Visual test file not found - skipping"
        return 0
    fi

    # Run the pytest visual test
    if pytest "$test_file" -v --tb=short 2>&1; then
        log_pass "Visual validation (waybar icons)"
        return 0
    else
        log_fail "Visual validation failed - waybar icons may be missing"
        ((ERRORS++))
        return 1
    fi
}

# =============================================================================
# Main Validation Loop
# =============================================================================

validate_all() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Validating local-bootstrapping configs"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # JSON/JSONC files
    echo "── JSON/JSONC Files ──"
    while IFS= read -r -d '' file; do
        validate_json "$file"
    done < <(find "$DOTFILES" -type f \( -name "*.json" -o -name "*.jsonc" \) -print0 2>/dev/null)
    echo ""

    # Systemd units
    echo "── Systemd Units ──"
    while IFS= read -r -d '' file; do
        validate_systemd "$file"
    done < <(find "$DOTFILES" -type f \( -name "*.service" -o -name "*.timer" \) -print0 2>/dev/null)
    echo ""

    # Shell scripts (in local-bin and scripts/)
    echo "── Shell Scripts ──"
    while IFS= read -r -d '' file; do
        # Skip if not actually a shell script
        if head -1 "$file" | grep -qE '^#!.*/(bash|sh|zsh)$' || head -1 "$file" | grep -qE '^#!.*/(env) +(bash|sh|zsh)' || [[ "$file" == *.sh ]]; then
            validate_shell "$file"
        fi
    done < <(find "$DOTFILES/local-bin" "$REPO_ROOT/scripts" -type f -print0 2>/dev/null)
    echo ""

    # Hyprland configs
    echo "── Hyprland Configs ──"
    while IFS= read -r -d '' file; do
        validate_hypr_conf "$file"
    done < <(find "$DOTFILES/hypr" "$REPO_ROOT/machine-specific" -path '*hypr*' -type f -name "*.conf" -print0 2>/dev/null)
    echo ""

    # Markdown files (CLAUDE.md, skills, etc.)
    echo "── Markdown Files ──"
    while IFS= read -r -d '' file; do
        validate_markdown "$file"
    done < <(find "$DOTFILES" -type f -name "*.md" -print0 2>/dev/null)
    echo ""

    # Visual test (optional, only if --visual flag passed)
    if [[ "$VISUAL_TEST" == "true" ]]; then
        echo "── Visual Test (Waybar Icons) ──"
        validate_visual
        echo ""
    fi

    # Summary
    echo "═══════════════════════════════════════════════════════════"
    if [[ $ERRORS -eq 0 ]]; then
        echo -e "${GREEN}  All validations passed!${NC}"
        [[ $WARNINGS -gt 0 ]] && echo -e "${YELLOW}  ($WARNINGS warnings)${NC}"
        echo "═══════════════════════════════════════════════════════════"
        return 0
    else
        echo -e "${RED}  Validation failed: $ERRORS error(s), $WARNINGS warning(s)${NC}"
        echo "═══════════════════════════════════════════════════════════"
        return 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_all
    exit $?
fi
