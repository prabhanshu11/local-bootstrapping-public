#!/bin/bash
# Setup agent-nice: agent work runs at nice 19 + idle IO, and ssh login sessions get CPU weight 1,
# so Hyprland, input and the star-trek-camera tracker always win the CPU. Both machines.
# See configs/agent-nice/README.md.
#
#   scripts/setup-agent-nice.sh               user half: ~/.local/bin/agent-nice + user service
#   sudo scripts/setup-agent-nice.sh --root   root half: session-.scope drop-in (CPUWeight=1)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)/configs/agent-nice"
DROPIN=/etc/systemd/system/session-.scope.d/50-agent-work-weight.conf

if [ "${1:-}" = "--root" ]; then
    [ "$(id -u)" = 0 ] || { echo "--root needs sudo" >&2; exit 1; }
    install -Dm644 "$SRC/50-agent-work-weight.conf" "$DROPIN"
    systemctl daemon-reload
    echo "Installed $DROPIN (daemon-reload applies it to running ssh/login sessions too)."
    exit 0
fi

echo "=== Setting up agent-nice ==="
install -Dm755 "$SRC/agent-nice.py" "$HOME/.local/bin/agent-nice"
install -Dm644 "$SRC/agent-nice.service" "$HOME/.config/systemd/user/agent-nice.service"
systemctl --user daemon-reload
systemctl --user enable agent-nice.service
systemctl --user restart agent-nice.service   # pick up changes on re-run
systemctl --user --no-pager --lines=2 status agent-nice.service | head -5

if ! cmp -s "$SRC/50-agent-work-weight.conf" "$DROPIN" 2>/dev/null; then
    echo "NEXT (root half): sudo $SCRIPT_DIR/setup-agent-nice.sh --root"
fi
