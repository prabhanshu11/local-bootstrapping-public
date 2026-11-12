#!/bin/bash
# unlock-gpg-secrets.sh - Unlock GPG and load secrets into environment
# Part of local-bootstrapping - handles secret management for all services
#
# This script:
# 1. Checks if GPG is already unlocked
# 2. If locked, prompts user via terminal popup
# 3. Loads secrets from pass
# 4. Exports them to a shared environment file for services

set -e

LOG_TAG="[GPG-SECRETS]"
SECRETS_ENV_FILE="$HOME/.config/secrets.env"
LOCK_FILE="$HOME/.config/gpg-unlock.lock"

log() {
    echo "$LOG_TAG $1" >&2
}

# Check if GPG is already unlocked by trying to access a secret
is_gpg_unlocked() {
    timeout 1 pass ls >/dev/null 2>&1
    return $?
}

# Unlock GPG via terminal popup
unlock_gpg_terminal() {
    log "GPG is locked - spawning terminal for unlock"

    # Detect available terminal
    local terminal=""
    for term in ghostty kitty alacritty gnome-terminal xterm; do
        if command -v "$term" &>/dev/null; then
            terminal="$term"
            break
        fi
    done

    if [[ -z "$terminal" ]]; then
        log "ERROR: No terminal emulator found"
        return 1
    fi

    # Create unlock script
    local unlock_script=$(mktemp /tmp/gpg-unlock-XXXXXX.sh)
    cat > "$unlock_script" <<'UNLOCK_EOF'
#!/bin/bash
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔐 System Secret Management"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Services need access to encrypted secrets."
echo "Please unlock your GPG keyring."
echo ""
echo "Unlock method:"
echo "  • Enter your GPG passphrase, OR"
echo "  • Touch your FIDO security key"
echo ""
echo "Running: pass ls"
echo ""

if pass ls >/dev/null 2>&1; then
    echo ""
    echo "✅ GPG unlocked successfully!"
    echo ""
    echo "Services will now start normally."
    echo ""
    echo "Press Enter to close..."
    read
    exit 0
else
    echo ""
    echo "❌ Failed to unlock GPG"
    echo ""
    echo "Services may not work correctly."
    echo ""
    echo "Press Enter to close..."
    read
    exit 1
fi
UNLOCK_EOF
    chmod +x "$unlock_script"

    # Launch terminal with unlock script
    case "$terminal" in
        ghostty)
            "$terminal" --command bash "$unlock_script"
            ;;
        kitty)
            "$terminal" --hold bash "$unlock_script"
            ;;
        alacritty)
            "$terminal" -e bash "$unlock_script"
            ;;
        *)
            "$terminal" -e bash "$unlock_script"
            ;;
    esac

    local result=$?
    rm -f "$unlock_script"
    return $result
}

# Load secrets from pass and export to environment file
load_secrets() {
    log "Loading secrets from pass..."

    # Create secrets directory
    mkdir -p "$(dirname "$SECRETS_ENV_FILE")"

    # Start with empty file (secure permissions)
    : > "$SECRETS_ENV_FILE"
    chmod 600 "$SECRETS_ENV_FILE"

    # Load AssemblyAI API key
    if pass show api/assemblyai &>/dev/null; then
        local api_key=$(pass show api/assemblyai)
        echo "export ASSEMBLYAI_API_KEY='$api_key'" >> "$SECRETS_ENV_FILE"
        log "Loaded ASSEMBLYAI_API_KEY"
    else
        log "WARNING: api/assemblyai not found in pass"
    fi

    # Load GitHub token
    if pass show api/github-pat &>/dev/null; then
        local gh_token=$(pass show api/github-pat)
        echo "export GITHUB_PERSONAL_ACCESS_TOKEN='$gh_token'" >> "$SECRETS_ENV_FILE"
        log "Loaded GITHUB_PERSONAL_ACCESS_TOKEN"
    else
        log "WARNING: api/github-pat not found in pass"
    fi

    log "Secrets loaded to $SECRETS_ENV_FILE"
}

# Main logic
main() {
    # Acquire lock to prevent concurrent runs
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        log "Already running (lock exists), exiting"
        exit 0
    fi
    trap "rmdir '$LOCK_FILE' 2>/dev/null" EXIT

    # Check if GPG is unlocked
    if is_gpg_unlocked; then
        log "GPG already unlocked"
    else
        log "GPG is locked, prompting user..."
        if ! unlock_gpg_terminal; then
            log "ERROR: Failed to unlock GPG"
            exit 1
        fi

        # Verify unlock worked
        if ! is_gpg_unlocked; then
            log "ERROR: GPG still locked after unlock attempt"
            exit 1
        fi
    fi

    # Load secrets
    load_secrets

    log "Secret management complete"
}

main "$@"
