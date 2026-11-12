#!/usr/bin/env bash
# net-revert-dongle.sh — the revert for every dual-Wi-Fi change: take the USB dongle OFF the air.
# wlan0 is never touched (it was never changed), so reverting = stop the dongle watchdog, disconnect the
# dongle (drops every route/DNS it contributed), and put a 30-min hold so nothing reconnects it.
# Needs no root (iwd's D-Bus policy allows group wheel).
set -u
DONGLE_MAC="${DONGLE_MAC:-02:00:00:00:00:04}"; LOG="$HOME/logs/home-lan-dongle.log"; mkdir -p "$(dirname "$LOG")"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
date +%s > "${XDG_RUNTIME_DIR:-/tmp}/home-lan-dongle.hold"
IF="$(iwctl device list 2>/dev/null | strip | awk -v m="$DONGLE_MAC" '$2==m{print $1; exit}')"
[[ -n "$IF" ]] && iwctl station "$IF" disconnect
echo "$(date '+%F %T') REVERT ${1:-manual}: dongle ${IF:-absent} disconnected, hold 30 min; $(bash "$(dirname "$0")/net-state-check.sh")" >> "$LOG"
