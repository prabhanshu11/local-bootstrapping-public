#!/bin/bash
# propagate-to-devices.sh - Propagate local-bootstrapping sync to all reachable Tailscale peers.
#
# Runs setup-voice-typing.sh on each device after pulling both repos.
# Called automatically by sync-from-master.sh when voice typing files change.
#
# Usage:
#   ./propagate-to-devices.sh             # Propagate to all online peers
#   ./propagate-to-devices.sh --background # Run in background (fire-and-forget)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run in background if requested (detach so sync-from-master.sh doesn't block)
if [[ "$1" == "--background" ]]; then
    nohup "$0" >> "${HOME}/.local/share/local-bootstrapping-propagate.log" 2>&1 &
    echo "[propagate] Started in background (PID $!)"
    exit 0
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

log "=== Propagating to Tailscale peers ==="

# Get online peers from tailscale status
PEERS=$(tailscale status --json 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for peer in data.get('Peer', {}).values():
        if peer.get('Online') and peer.get('TailscaleIPs'):
            print(peer['HostName'], peer['TailscaleIPs'][0])
except Exception as e:
    pass
" 2>/dev/null || true)

if [[ -z "$PEERS" ]]; then
    log "No reachable Tailscale peers found"
    exit 0
fi

SUCCESS=0
FAILED=0

while IFS=' ' read -r hostname ip; do
    log "Propagating to $hostname ($ip)..."
    if ssh -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=no \
           -o BatchMode=yes \
           "prabhanshu@$ip" \
        'set -e
         # Pull omarchy-voice-typing
         if [ -d ~/Programs/omarchy-voice-typing/.git ]; then
             git -C ~/Programs/omarchy-voice-typing fetch origin
             git -C ~/Programs/omarchy-voice-typing checkout master 2>/dev/null || true
             git -C ~/Programs/omarchy-voice-typing pull --ff-only origin master
         fi
         # Pull local-bootstrapping
         git -C ~/Programs/local-bootstrapping pull --ff-only
         # Re-run voice typing setup
         ~/Programs/local-bootstrapping/scripts/setup-voice-typing.sh
         # Reload and restart services
         systemctl --user daemon-reload
         systemctl --user restart voice-gateway.service' 2>&1 | \
        sed "s/^/  [$hostname] /" ; then
        log "  ✓ $hostname propagated successfully"
        SUCCESS=$((SUCCESS + 1))
    else
        log "  ✗ $hostname failed or unreachable"
        FAILED=$((FAILED + 1))
    fi
done <<< "$PEERS"

log "=== Propagation complete: $SUCCESS succeeded, $FAILED failed ==="
