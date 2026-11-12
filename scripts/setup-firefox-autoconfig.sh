#!/bin/bash
# Install the Firefox AutoConfig files (configs/firefox-autoconfig/README.md).
# Run: sudo-with-notify "firefox autoconfig" -- sudo scripts/setup-firefox-autoconfig.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)/configs/firefox-autoconfig"
FXDIR=/usr/lib/firefox
[[ -d $FXDIR/defaults/pref ]] || { echo "Firefox install dir $FXDIR not found" >&2; exit 1; }
install -Dm644 "$SRC/autoconfig.js" "$FXDIR/defaults/pref/autoconfig.js"
install -Dm644 "$SRC/firefox.cfg"   "$FXDIR/firefox.cfg"
echo "Installed: $FXDIR/defaults/pref/autoconfig.js, $FXDIR/firefox.cfg (restart Firefox)"
