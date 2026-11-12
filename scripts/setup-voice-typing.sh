#!/bin/bash
# setup-voice-typing.sh - Deploy full voice typing stack
#
# Sets up:
# - hyprwhspr config with REST API backend
# - hyprwhspr-toggle script for robust toggling
# - ydotool-layout for Dvorak keyboard support
# - hyprwhspr-patch (MicOSD overlay + patched runner)
# - voice-gateway Go binary (builds if missing)
# - local-whisper Python venv (uv sync if missing)
# - .env with API keys from pass
# - Hyprland binding for Super+Caps_Lock

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DOTFILES="$REPO_ROOT/dotfiles"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# Copy a file safely — skips when source and destination are the same inode
# (e.g., when dotfiles are managed via symlinks rather than plain copies)
safe_cp() {
    local src="$1" dst="$2"
    if [[ -e "$dst" ]] && [[ "$(realpath "$src" 2>/dev/null)" == "$(realpath "$dst" 2>/dev/null)" ]]; then
        return 0  # Same inode — already up to date
    fi
    cp "$src" "$dst"
}
safe_cp_r() {
    local src="$1" dst="$2"
    if [[ -e "$dst" ]] && [[ "$(realpath "$src" 2>/dev/null)" == "$(realpath "$dst" 2>/dev/null)" ]]; then
        return 0
    fi
    cp -r "$src" "$dst"
}

info "Setting up voice typing (hyprwhspr + AssemblyAI)"

# Check if hyprwhspr is installed
if ! command -v hyprwhspr &>/dev/null; then
    warn "hyprwhspr not installed. Install from AUR: yay -S hyprwhspr"
    warn "Skipping voice typing setup"
    exit 0
fi

# Ensure Python dependencies are installed for current Python version
# These are AUR packages that need rebuilding after Python major upgrades (e.g., 3.13→3.14)
info "Checking Python dependencies for hyprwhspr..."
for pkg in python-sounddevice python-pulsectl; do
    if ! python -c "import ${pkg#python-}" 2>/dev/null; then
        warn "$pkg not importable — rebuilding for current Python version"
        yay -S --noconfirm "$pkg" || warn "Failed to install $pkg"
    fi
done
# python-websocket-client is in official repos (required for realtime-ws backend)
if ! python -c "import websocket" 2>/dev/null; then
    info "Installing python-websocket-client..."
    sudo pacman -S --noconfirm python-websocket-client || warn "Failed to install python-websocket-client"
fi

# Create directories
mkdir -p ~/.config/hyprwhspr
mkdir -p ~/.config/systemd/user/hyprwhspr.service.d
mkdir -p ~/.local/bin

# Copy hyprwhspr config
if [[ -f "$DOTFILES/hyprwhspr/config.json" ]]; then
    safe_cp "$DOTFILES/hyprwhspr/config.json" ~/.config/hyprwhspr/config.json
    log "Installed hyprwhspr config"
fi

# Copy systemd override
if [[ -f "$DOTFILES/systemd/user/hyprwhspr.service.d/override.conf" ]]; then
    safe_cp "$DOTFILES/systemd/user/hyprwhspr.service.d/override.conf" ~/.config/systemd/user/hyprwhspr.service.d/override.conf
    log "Installed hyprwhspr systemd override"
fi

# Copy voice typing scripts
for script in hyprwhspr-toggle layout-detect layout-send ydotool-layout; do
    if [[ -f "$DOTFILES/local-bin/$script" ]]; then
        safe_cp "$DOTFILES/local-bin/$script" ~/.local/bin/$script
        chmod +x ~/.local/bin/$script
        log "Installed $script"
    fi
done

# Copy keymaps
if [[ -d "$DOTFILES/local-bin/keymaps" ]]; then
    mkdir -p ~/.local/bin/keymaps
    for mapfile in "$DOTFILES/local-bin/keymaps/"*.map; do
        [[ -f "$mapfile" ]] && safe_cp "$mapfile" ~/.local/bin/keymaps/"$(basename "$mapfile")"
    done
    log "Installed keymaps (dvorak, us, us-reverse)"
fi

# Deploy hyprwhspr-patch (MicOSD overlay + patched runner)
# Use rm+cp instead of safe_cp_r: safe_cp_r on a directory when destination
# already exists nests the source *inside* the destination (cp -r behaviour),
# producing ~/.local/lib/hyprwhspr-patch/mic_osd/mic_osd/ stale copies.
if [[ -d "$DOTFILES/local-lib/hyprwhspr-patch" ]]; then
    rm -rf ~/.local/lib/hyprwhspr-patch
    cp -r "$DOTFILES/local-lib/hyprwhspr-patch" ~/.local/lib/hyprwhspr-patch
    log "Installed hyprwhspr-patch (MicOSD + runner)"
fi

# Deploy MicOSD Hyprland window rules (positions OSD at bottom-center)
if [[ -f "$DOTFILES/hypr/windowrules-mic-osd.conf" ]]; then
    mkdir -p ~/.config/hypr
    safe_cp "$DOTFILES/hypr/windowrules-mic-osd.conf" ~/.config/hypr/windowrules-mic-osd.conf
    # Enable the rules in hyprland.conf if not already sourced
    HYPR_CONF=~/.config/hypr/hyprland.conf
    if [[ -f "$HYPR_CONF" ]] && ! grep -q "windowrules-mic-osd.conf" "$HYPR_CONF"; then
        printf '\nsource = ~/.config/hypr/windowrules-mic-osd.conf\n' >> "$HYPR_CONF"
        log "Added MicOSD window rules to hyprland.conf"
    fi
    log "Installed MicOSD Hyprland window rules"
fi

# Copy orphan recovery systemd units
if [[ -f "$DOTFILES/systemd/user/voice-orphan-recovery.service" ]]; then
    safe_cp "$DOTFILES/systemd/user/voice-orphan-recovery.service" ~/.config/systemd/user/voice-orphan-recovery.service
    safe_cp "$DOTFILES/systemd/user/voice-orphan-recovery.timer" ~/.config/systemd/user/voice-orphan-recovery.timer
    log "Installed voice orphan recovery service and timer"
fi

# Copy voice-gateway and local-whisper systemd units
for unit in voice-gateway.service local-whisper.service; do
    if [[ -f "$DOTFILES/systemd/user/$unit" ]]; then
        safe_cp "$DOTFILES/systemd/user/$unit" ~/.config/systemd/user/$unit
        log "Installed $unit"
    fi
done

# Local STT (omarchy-voice-typing/docs/local-stt.md): the laptop points the
# gateway at the desktop GPU Whisper and runs the voice-labels web app; the
# desktop serves the fine-tuned model.
if grep -qi thinkpad /sys/class/dmi/id/product_family 2>/dev/null; then
    mkdir -p ~/.config/systemd/user/voice-gateway.service.d
    safe_cp "$DOTFILES/systemd/user/voice-gateway.service.d/local-stt.conf" \
        ~/.config/systemd/user/voice-gateway.service.d/local-stt.conf
    ln -sf "$DOTFILES/systemd-user/voice-labels.service" ~/.config/systemd/user/voice-labels.service
    ln -sf "$DOTFILES/local-bin/voice-stt-provider" ~/.local/bin/voice-stt-provider
    log "Installed local-STT gateway drop-in, voice-labels unit, voice-stt-provider"
else
    mkdir -p ~/.config/systemd/user/local-whisper.service.d
    safe_cp "$DOTFILES/systemd/user/local-whisper.service.d/desktop-voice-stt.conf" \
        ~/.config/systemd/user/local-whisper.service.d/desktop-voice-stt.conf
    log "Installed desktop local-whisper drop-in (fine-tuned model)"
    mkdir -p ~/.config/systemd/user/voice-gateway.service.d
    safe_cp "$DOTFILES/systemd/user/voice-gateway.service.d/desktop-mic.conf" \
        ~/.config/systemd/user/voice-gateway.service.d/desktop-mic.conf
    log "Installed desktop voice-gateway drop-in (silence threshold 10 for the Jabra)"
fi

# Enable services
systemctl --user daemon-reload
systemctl --user enable hyprwhspr.service 2>/dev/null || true
log "Enabled hyprwhspr service"

# Enable orphan recovery timer (runs every 5 minutes)
if [[ -f ~/.config/systemd/user/voice-orphan-recovery.timer ]]; then
    systemctl --user enable voice-orphan-recovery.timer 2>/dev/null || true
    log "Enabled voice orphan recovery timer"
fi

# Enable voice-gateway and local-whisper (and the labels web app on the laptop)
for unit in voice-gateway.service local-whisper.service voice-labels.service; do
    if [[ -f ~/.config/systemd/user/$unit ]]; then
        systemctl --user enable "$unit" 2>/dev/null || true
        log "Enabled $unit"
    fi
done

# Ensure hyprwhspr credential store has a "custom" provider entry
# (The local gateway doesn't need auth, but upstream hyprwhspr validates it)
CRED_DIR="$HOME/.local/share/hyprwhspr"
CRED_FILE="$CRED_DIR/credentials"
if [[ ! -f "$CRED_FILE" ]] || ! python3 -c "import json; d=json.load(open('$CRED_FILE')); assert 'custom' in d" 2>/dev/null; then
    mkdir -p "$CRED_DIR"
    python3 -c "
import json, os
p = '$CRED_FILE'
d = json.load(open(p)) if os.path.exists(p) else {}
d['custom'] = 'local-gateway-no-auth-needed'
with open(p, 'w') as f: json.dump(d, f, indent=2)
os.chmod(p, 0o600)
"
    log "Set up hyprwhspr credential store (custom provider)"
fi

# --- Voice typing application setup ---
VT_DIR="$HOME/Programs/omarchy-voice-typing"

if [[ ! -d "$VT_DIR" ]]; then
    warn "Voice typing repo not found at $VT_DIR"
    warn "Clone: git@github.com:prabhanshu11/omarchy-voice-typing.git"
    warn "Then re-run this script"
    exit 0
fi

# Pull omarchy-voice-typing to master before building
if [[ -d "$VT_DIR/.git" ]]; then
    log "Pulling omarchy-voice-typing to master..."
    git -C "$VT_DIR" fetch origin
    git -C "$VT_DIR" checkout master 2>/dev/null || true
    git -C "$VT_DIR" pull --ff-only origin master 2>/dev/null || \
        warn "Could not fast-forward omarchy-voice-typing — manual intervention may be needed"
fi

# Build gateway via build contract (build.sh handles Go/Rust/future impls)
if [[ -f "$VT_DIR/build.sh" ]]; then
    log "Building voice-gateway via build.sh..."
    bash "$VT_DIR/build.sh"
    log "Build complete: $VT_DIR/bin/voice-gateway"
else
    warn "No build.sh found in $VT_DIR — cannot build voice-gateway"
    warn "Add build.sh to omarchy-voice-typing per the build contract (CLAUDE.md)"
fi

# Recovery CLI for saved recordings (omarchy-voice-typing/docs/issues/2026-09-30-voice-data-loss.md).
# The hyprwhspr patch (voice_safety.py) calls it by its repo path; the symlink is for the user.
if [[ -f "$VT_DIR/scripts/voice-retranscribe" ]]; then
    ln -sf "$VT_DIR/scripts/voice-retranscribe" ~/.local/bin/voice-retranscribe
    log "Linked voice-retranscribe"
fi

# Set up local-whisper venv if missing
if [[ ! -d "$VT_DIR/local-whisper/.venv" ]]; then
    if command -v uv &>/dev/null; then
        log "Setting up local-whisper venv..."
        (cd "$VT_DIR/local-whisper" && uv sync)
        log "local-whisper venv ready"
    else
        warn "uv not installed — cannot set up local-whisper"
        warn "Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
    fi
else
    log "local-whisper venv exists"
fi

# Create .env with API keys from pass (if pass is available)
if [[ ! -f "$VT_DIR/.env" ]]; then
    if command -v pass &>/dev/null; then
        log "Creating .env from pass..."
        : > "$VT_DIR/.env"
        ASSEMBLYAI_KEY=$(pass show api/assemblyai 2>/dev/null || true)
        if [[ -n "$ASSEMBLYAI_KEY" ]]; then
            echo "ASSEMBLYAI_API_KEY=$ASSEMBLYAI_KEY" >> "$VT_DIR/.env"
        else
            warn "api/assemblyai not found in pass"
        fi
        DEEPGRAM_KEY=$(pass show api/deepgram 2>/dev/null || true)
        if [[ -n "$DEEPGRAM_KEY" ]]; then
            echo "DEEPGRAM_API_KEY=$DEEPGRAM_KEY" >> "$VT_DIR/.env"
        else
            info "api/deepgram not in pass (optional — Deepgram streaming won't work)"
        fi
        # Add LAN whisper fallback for laptop (uses desktop GPU via Tailscale)
        source "$REPO_ROOT/device-role.conf" 2>/dev/null || true
        if [[ "$DEVICE_NAME" == "laptop" ]]; then
            DESKTOP_IP=$(grep "^desktop:" "$REPO_ROOT/devices.conf" | cut -d: -f2)
            if [[ -n "$DESKTOP_IP" ]]; then
                echo "LAN_WHISPER_URL=http://${DESKTOP_IP}:8767" >> "$VT_DIR/.env"
                log "Configured LAN whisper fallback → $DESKTOP_IP:8767"
            fi
        fi
        log "Created .env"
    else
        warn "pass not available — create $VT_DIR/.env manually"
        warn "Required: ASSEMBLYAI_API_KEY=..."
        warn "Optional: DEEPGRAM_API_KEY=..."
    fi
else
    log ".env already exists"
fi

echo ""
info "Voice typing setup complete!"
info "Binding: Super+Caps_Lock (toggle voice recording)"
info "Start services:"
echo "  systemctl --user start hyprwhspr voice-gateway local-whisper"
echo ""
