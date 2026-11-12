#!/bin/bash
# Run waybar icon visual tests inside Docker container.
#
# Bind-mounts host Wayland/Hyprland sockets and system paths
# so grim + hyprctl work against the live compositor.
#
# Usage:
#   ./run-tests.sh                     # run all visual tests
#   ./run-tests.sh -k test_waybar      # run specific test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_NAME="waybar-icon-tests"

# Build container if needed
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# Get API key from pass (host-side)
API_KEY=$(pass show api/openrouter 2>/dev/null || echo "")
if [[ -z "$API_KEY" ]]; then
    echo "Warning: OpenRouter API key not found, vision tests will be skipped"
fi

# Detect Hyprland environment
HYPR_SIG="${HYPRLAND_INSTANCE_SIGNATURE:-}"
WAYLAND="${WAYLAND_DISPLAY:-wayland-1}"
XDG_RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if [[ -z "$HYPR_SIG" ]]; then
    echo "Error: HYPRLAND_INSTANCE_SIGNATURE not set. Run from a Hyprland session."
    exit 1
fi

# Run container with host socket bindings
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e "OPENROUTER_API_KEY=$API_KEY" \
    -e "WAYLAND_DISPLAY=$WAYLAND" \
    -e "HYPRLAND_INSTANCE_SIGNATURE=$HYPR_SIG" \
    -e "XDG_RUNTIME_DIR=$XDG_RT" \
    -e "DBUS_SYSTEM_BUS_ADDRESS=unix:path=/var/run/dbus/system_bus_socket" \
    -v "$XDG_RT:$XDG_RT" \
    -v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro \
    -v /sys/class/power_supply:/sys/class/power_supply:ro \
    -v "$HOME/.config/waybar/config.jsonc:/home/testrunner/.config/waybar/config.jsonc:ro" \
    -v /usr/lib/hyprwhspr:/usr/lib/hyprwhspr:ro \
    -v "$SCRIPT_DIR:/tests:ro" \
    -v "$REPO_ROOT/reference-screenshots:/tests/../reference-screenshots" \
    "$IMAGE_NAME" \
    -v --tb=short "$@"
