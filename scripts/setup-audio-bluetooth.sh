#!/bin/bash
# setup-audio-bluetooth.sh - Configure Bluetooth audio codec preferences
#
# Ensures Bluetooth headsets use SbcXQ instead of AAC for better stability
# and lower latency. AAC on Linux often has issues with phone interruptions.
#
# Usage: ./setup-audio-bluetooth.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPEWIRE_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
BT_CONF_FILE="$PIPEWIRE_CONF_DIR/50-bluetooth-codec.conf"

echo "==> Setting up Bluetooth audio codec preferences"

# Create PipeWire config directory
mkdir -p "$PIPEWIRE_CONF_DIR"

# Write Bluetooth codec configuration
cat > "$BT_CONF_FILE" <<'EOF'
# Bluetooth Codec Preferences for hyprwhspr Voice Typing
#
# Prefer SBC-XQ (high quality SBC) over AAC for better stability
# AAC on Linux Bluetooth often has issues:
# - Phone interruptions cause audio routing failures
# - Higher CPU usage
# - Latency spikes during codec negotiation
#
# SBC-XQ provides:
# - Rock-solid stability
# - Low latency
# - Good quality (close to AAC)
# - Better compatibility with phone handoffs

context.properties = {
    # Bluetooth codec preferences (highest priority first)
    bluez5.codecs = [ sbc_xq sbc ldac aptx aptx_hd aptx_ll aac ]

    # SBC-XQ specific tuning
    bluez5.default.rate = 48000
    bluez5.default.channels = 2
}

# SBC-XQ quality settings
bluez5.enable-sbc-xq = true
bluez5.enable-msbc = true
bluez5.enable-hw-volume = true

# Disable AAC by default (can be enabled manually if needed)
# bluez5.codecs = [ sbc_xq sbc ]
EOF

echo "✓ Created $BT_CONF_FILE"

# Restart PipeWire to apply changes
if systemctl --user is-active --quiet pipewire.service; then
    echo "==> Restarting PipeWire to apply codec preferences"
    systemctl --user restart pipewire.service
    sleep 2
    echo "✓ PipeWire restarted"
else
    echo "⚠️  PipeWire not running - changes will apply on next start"
fi

echo "
✓ Bluetooth audio codec configuration complete

Codec priority: SBC-XQ > SBC > LDAC > aptX > AAC

To verify active codec:
  pactl list cards | grep -A 20 'bluez'

To manually test different codecs:
  pactl set-card-profile bluez_card.XX_XX_XX_XX_XX_XX a2dp-sink-sbc_xq
"
