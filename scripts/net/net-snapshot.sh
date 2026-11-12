#!/usr/bin/env bash
# net-snapshot.sh — record the working network state before any change. Prints the file path.
set -u
DIR="$HOME/logs/net-snapshots"; mkdir -p "$DIR"; F="$DIR/$(date +%Y%m%d-%H%M%S).txt"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
{ echo "# $(date '+%F %T')"; echo "## wlan0"; iwctl station wlan0 show | strip | grep -E 'State|Connected network|ConnectedBss'
  echo "## ip route"; ip route; echo "## ip rule"; ip rule; echo "## resolv.conf"; cat /etc/resolv.conf
  echo "## resolvectl"; resolvectl status 2>/dev/null | grep -E '^Link|Current DNS|DNS Servers|Default Route'
  echo "## iwctl devices"; iwctl station list | strip; } > "$F"
echo "$F"
