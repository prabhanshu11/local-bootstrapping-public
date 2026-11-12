#!/usr/bin/env bash
# setup-home-lan-dongle.sh — ROOT half of the laptop dual-Wi-Fi setup (phase 1).
# Run: sudo-with-notify "home-LAN dongle setup" -- sudo scripts/net/setup-home-lan-dongle.sh
#
# Installs (all idempotent, none restarts iwd, none touches wlan0):
#   /etc/systemd/network/10-home-lan-dongle.network  LAN-only link for the dongle (no default route/DNS)
#   /etc/modprobe.d/rtw88.conf                        disable_lps_deep=Y (firmware LPS wedge)
#   /etc/iwd/main.conf                                PowerSaveDisable=rtw88* (takes effect at next iwd start)
# and applies the runtime equivalents now: LPS-deep param, `iw set power_save off` on the dongle,
# `networkctl reload` + `networkctl reconfigure <dongle>`.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MAC=02:00:00:00:00:04
LOG=/var/log/home-lan-dongle-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%F %T') setup-home-lan-dongle"

install -Dm644 "$REPO/system/systemd-network/10-home-lan-dongle.network" /etc/systemd/network/10-home-lan-dongle.network
install -Dm644 "$REPO/system/modprobe.d/rtw88.conf" /etc/modprobe.d/rtw88.conf
if [[ -f /etc/iwd/main.conf ]] && ! cmp -s /etc/iwd/main.conf "$REPO/system/iwd/main.conf"; then
  cp -a /etc/iwd/main.conf "/etc/iwd/main.conf.bak-$(date +%Y%m%d%H%M%S)"
fi
install -Dm644 "$REPO/system/iwd/main.conf" /etc/iwd/main.conf

echo Y > /sys/module/rtw88_core/parameters/disable_lps_deep 2>/dev/null || echo "WARN: rtw88_core param not writable/loaded"
IF=""
for d in /sys/class/net/*; do [[ "$(cat "$d/address" 2>/dev/null)" == "$MAC" ]] && IF="$(basename "$d")"; done
networkctl reload
if [[ -n "$IF" ]]; then
  iw dev "$IF" set power_save off || true
  networkctl reconfigure "$IF"
  echo "dongle=$IF power_save=$(iw dev "$IF" get power_save) lps_deep_disabled=$(cat /sys/module/rtw88_core/parameters/disable_lps_deep)"
else
  echo "WARN: dongle $MAC not present; config installed for next plug-in"
fi
echo "=== done"
