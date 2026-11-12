#!/bin/bash
# setup-hyprgrass.sh - Build and install hyprgrass plugin for touchscreen gestures
#
# Builds hyprgrass from source against the installed Hyprland version.
# Also enables the touch-scroll-daemon for single-finger scroll in terminals.
#
# Laptop-only: touchscreen is on ThinkPad T14 Gen 1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

PLUGIN_DIR="$HOME/.local/share/hypr/plugins"
BUILD_DIR="/tmp/hyprgrass-build"

# Get installed Hyprland version commit
get_hyprland_commit() {
    hyprctl version | grep 'commit' | awk '{print $NF}' | head -1
}

# Get hyprgrass commit pin for our Hyprland version
get_hyprgrass_pin() {
    local hl_commit="$1"
    local toml="$BUILD_DIR/hyprgrass/hyprpm.toml"

    if [[ ! -f "$toml" ]]; then
        error "hyprpm.toml not found"
    fi

    # Parse commit_pins to find matching Hyprland commit
    grep "$hl_commit" "$toml" | grep -oP '"\K[a-f0-9]{40}(?="\])' || true
}

install_deps() {
    log "Installing build dependencies..."
    sudo pacman -S --needed --noconfirm cmake meson cpio pkg-config glm glaze python-evdev
}

build_hyprland_headers() {
    log "Building Hyprland headers..."
    local hl_commit="$1"
    local hl_tag
    hl_tag=$(hyprctl version | grep 'Tag:' | awk '{print $2}' | tr -d ',')

    # Create hyprpm state store if needed
    if [[ ! -d /var/cache/hyprpm/$(whoami)/headersRoot ]]; then
        sudo mkdir -p "/var/cache/hyprpm/$(whoami)/headersRoot"
        sudo chown -R "$(whoami):$(whoami)" /var/cache/hyprpm/
    fi

    cd "$BUILD_DIR"
    if [[ ! -d hyprland-src ]]; then
        log "Cloning Hyprland $hl_tag..."
        git clone --depth=1 --branch "$hl_tag" --recurse-submodules \
            https://github.com/hyprwm/Hyprland.git hyprland-src
    fi

    cd hyprland-src
    cmake -B build -DCMAKE_INSTALL_PREFIX="/var/cache/hyprpm/$(whoami)/headersRoot" \
        -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5

    # Install headers (no sudo needed since we own the directory)
    sed -i "s#PREFIX = /usr/local#PREFIX = /var/cache/hyprpm/$(whoami)/headersRoot#" Makefile
    make installheaders 2>&1 | tail -5

    log "Hyprland headers installed"
}

build_hyprgrass() {
    local pin_commit="$1"

    log "Building hyprgrass..."
    cd "$BUILD_DIR"

    if [[ ! -d hyprgrass ]]; then
        git clone https://github.com/horriblename/hyprgrass.git
    fi

    cd hyprgrass

    if [[ -n "$pin_commit" ]]; then
        log "Checking out pinned commit: $pin_commit"
        git checkout "$pin_commit"
    fi

    rm -rf build
    meson setup build --buildtype=release
    ninja -C build

    mkdir -p "$PLUGIN_DIR"
    cp build/src/libhyprgrass.so "$PLUGIN_DIR/"
    log "Plugin installed to $PLUGIN_DIR/libhyprgrass.so"
}

setup_touch_scroll_daemon() {
    log "Setting up touch-scroll-daemon..."

    systemctl --user daemon-reload

    if systemctl --user enable --now touch-scroll-daemon.service 2>/dev/null; then
        log "Enabled touch-scroll-daemon.service"
    fi
}

source_hyprgrass_config() {
    local hyprland_conf="$HOME/.config/hypr/hyprland.conf"
    local source_line='source = ~/.config/hypr/hyprgrass.conf'

    if ! grep -q "hyprgrass.conf" "$hyprland_conf" 2>/dev/null; then
        log "Adding hyprgrass config to hyprland.conf..."
        echo "" >> "$hyprland_conf"
        echo "# Touchscreen gestures (laptop)" >> "$hyprland_conf"
        echo "$source_line" >> "$hyprland_conf"
    else
        log "hyprgrass.conf already sourced in hyprland.conf"
    fi
}

main() {
    log "Setting up hyprgrass for touchscreen gestures"

    local hl_commit
    hl_commit=$(get_hyprland_commit)
    log "Hyprland commit: $hl_commit"

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    install_deps

    # Clone hyprgrass first to get commit pins
    cd "$BUILD_DIR"
    git clone https://github.com/horriblename/hyprgrass.git

    local pin
    pin=$(get_hyprgrass_pin "$hl_commit")
    if [[ -z "$pin" ]]; then
        warn "No hyprgrass pin found for Hyprland $hl_commit, using latest"
    else
        log "Found hyprgrass pin: $pin"
    fi

    build_hyprland_headers "$hl_commit"
    build_hyprgrass "$pin"
    source_hyprgrass_config
    setup_touch_scroll_daemon

    log "Hyprgrass setup complete!"
    log "Reload Hyprland config: hyprctl reload"
    log "Test: touch your screen and swipe vertically in Ghostty"
}

main "$@"
