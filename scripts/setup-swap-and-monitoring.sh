#!/bin/bash
# Setup freeze monitor and SSD swap
# Requires: ~/Programs/utilities/freeze-monitor to exist

set -e

FREEZE_MONITOR_DIR="$HOME/Programs/utilities/freeze-monitor"
SERVICE_FILE="$FREEZE_MONITOR_DIR/freeze-monitor.service"
USER_SERVICE_DIR="$HOME/.config/systemd/user"

echo "=== Setting up Freeze Monitor ==="

# 1. Check if freeze-monitor exists
if [[ ! -d "$FREEZE_MONITOR_DIR" ]]; then
    echo "ERROR: $FREEZE_MONITOR_DIR not found"
    echo "Clone utilities repo first: git clone <url> ~/Programs/utilities"
    exit 1
fi

# 2. Install systemd user service
echo "Installing systemd user service..."
mkdir -p "$USER_SERVICE_DIR"
cp "$SERVICE_FILE" "$USER_SERVICE_DIR/"
systemctl --user daemon-reload
systemctl --user enable freeze-monitor
systemctl --user start freeze-monitor

echo "Freeze monitor service installed and started"

# 3. Check if SSD swap is already set up
# /swap/swapfile = the 32 GiB hibernate swap (scripts/setup-hibernate.sh, 2026-10-06) replaces it on the laptop
if swapon --show | grep -qE "/var/swap/swapfile1|/swap/swapfile"; then
    echo "SSD swap already configured, skipping..."
else
    echo ""
    echo "=== SSD Swap Setup ==="
    echo "Your system uses btrfs with zram-only swap (4GB)."
    echo "Adding 8GB SSD swap prevents OOM freezes."
    echo ""
    read -p "Set up SSD swap now? (requires sudo) [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Running safe-swap-setup.sh..."
        sudo "$FREEZE_MONITOR_DIR/safe-swap-setup.sh"
    else
        echo "Skipped. Run manually later:"
        echo "  sudo $FREEZE_MONITOR_DIR/safe-swap-setup.sh"
    fi
fi

# 4. Show status
echo ""
echo "=== Status ==="
systemctl --user status freeze-monitor --no-pager | head -10
echo ""
swapon --show
echo ""
echo "Setup complete!"
echo ""
echo "Commands:"
echo "  Analyze freeze: $FREEZE_MONITOR_DIR/analyze-freeze.sh"
echo "  Service status: systemctl --user status freeze-monitor"
echo "  View logs:      journalctl --user -u freeze-monitor -f"
