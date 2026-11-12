#!/bin/bash
# secrets.sh - Load secrets securely (supports 1Password CLI or pass)
# NEVER commit actual secrets - this file loads them from secure storage

# Option 1: 1Password CLI (if configured)
# Only attempt if op is installed AND has accounts configured (config file exists)
if command -v op &>/dev/null && [[ -f "$HOME/.config/op/config" ]]; then
    # GitHub token from 1Password
    # Adjust the vault/item path to match your 1Password structure
    # Example: op read "op://Personal/GitHub Token/credential"
    # export GITHUB_PERSONAL_ACCESS_TOKEN="$(op read 'op://Personal/GitHub/token' 2>/dev/null)"

    # Assembly AI key for voice typing
    # export ASSEMBLYAI_API_KEY="$(op read 'op://Personal/AssemblyAI/api_key' 2>/dev/null)"
    :
fi

# Option 2: pass (GPG-encrypted password store)
if command -v pass &>/dev/null && [[ -d "$HOME/.password-store" ]]; then
    # GitHub token
    if pass show api/github-token &>/dev/null 2>&1; then
        export GITHUB_PERSONAL_ACCESS_TOKEN="$(pass show api/github-token)"
    fi

    # Assembly AI key
    if pass show api/assemblyai-key &>/dev/null 2>&1; then
        export ASSEMBLYAI_API_KEY="$(pass show api/assemblyai-key)"
    fi
fi

# Fallback: Environment file (for dev, NOT for production secrets)
# This file should be in .gitignore
if [[ -f "$HOME/.config/secrets.env" ]]; then
    source "$HOME/.config/secrets.env"
fi
