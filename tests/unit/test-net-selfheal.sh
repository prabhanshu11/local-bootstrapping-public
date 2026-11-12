#!/usr/bin/env bash
# Dry-run test of system/bin/net-selfheal: simulated clock, forced probe failures, nothing executed.
# Usage: tests/unit/test-net-selfheal.sh   (no root; prints a timeline and PASS/FAIL per check)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$HERE/system/bin/net-selfheal"
ST="$(mktemp -d)"; trap 'rm -rf "$ST"' EXIT
export NET_SELFHEAL_TEST=1 NET_SELFHEAL_STATE="$ST"
T0=1800000000; fails=0
tick() {  # tick <minute> <force> <uptime_s> [boot]
    NET_SELFHEAL_NOW=$((T0 + $1*60)) NET_SELFHEAL_FORCE="$2" NET_SELFHEAL_UPTIME="$3" \
    NET_SELFHEAL_BOOT_ID="${4:-boot1}" "$BIN" | sed "s/^/  t+$1m [$2] /"
}
check() { if grep -q -- "$2" "$ST/out"; then echo "PASS: $1"; else echo "FAIL: $1 (no '$2')"; fails=$((fails+1)); fi; }
nocheck() { if grep -q -- "$2" "$ST/out"; then echo "FAIL: $1 (found '$2')"; fails=$((fails+1)); else echo "PASS: $1"; fi; }

echo "== 1. LAN (A) down 0..34 min, boot1 uptime 1 h"
for m in $(seq 0 34); do tick "$m" A $((3600 + m*60)); done > "$ST/out"; cat "$ST/out"
check "reconfigure at 2 min"   "t+2m .*DRY: networkctl reconfigure enp4s0"
check "bounce at 5 min"        "t+5m .*DRY: ip link set enp4s0 down"
check "networkd restart 5 min" "t+5m .*DRY: systemctl restart systemd-networkd"
check "tailscaled at 10 min"   "t+10m .*DRY: systemctl restart tailscaled"
check "reboot at 30 min"       "t+30m .*DRY: systemctl reboot"
nocheck "no reboot before 30"  "t+29m .*reboot"
nocheck "no Tailscale logout"  "tailscale logout"

echo "== 2. after the reboot: boot2, still down; ladder restarts, reboot held by uptime then gap"
for m in $(seq 36 75); do tick "$m" A $(( (m-35)*60 )) boot2; done > "$ST/out"; cat "$ST/out" | grep -v '^$'
check "ladder restarts after boot" "t+38m .*DRY: networkctl reconfigure"
check "reboot held by 2h gap"     "reboot held: last reboot"
check "repeat bounce while held"  "repeat link bounce"
nocheck "no 2nd reboot inside 2h" "DRY: systemctl reboot"

echo "== 3. LAN back at 76 min -> one queued Telegram line, state cleared"
tick 76 none 2460 boot2 > "$ST/out"; cat "$ST/out"
check "LAN back logged"   "LAN back after 1h16m"
check "telegram on return" "DRY: telegram: desktop net-selfheal: LAN path was down 1h16m"
[[ ! -e "$ST/a_since" ]] && echo "PASS: outage state cleared" || { echo "FAIL: a_since left"; fails=$((fails+1)); }

echo "== 4. uplink (B) down 0..80 min with LAN ok: no network actions, tailscaled at 15 min then hourly"
rm -rf "$ST"/*; for m in $(seq 100 180); do tick "$m" B 9000; done > "$ST/out"
grep -v '^\s*$' "$ST/out"
check "uplink-down logged"  "uplink down; changing nothing"
check "tailscaled at 15 min" "t+115m .*DRY: systemctl restart tailscaled"
check "tailscaled hourly"    "t+175m .*DRY: systemctl restart tailscaled"
nocheck "no reconfigure on B" "networkctl reconfigure"
nocheck "no link bounce on B" "ip link set"
nocheck "no reboot on B"      "systemctl reboot"
tick 181 none 9000 > "$ST/out"; cat "$ST/out"
check "telegram after uplink return" "DRY: telegram: .*Internet (Tata) was down 1h21m"

echo "== 5. reboot guards: within 10 min of boot / GPU busy"
rm -rf "$ST"/*; for m in $(seq 0 31); do tick "$m" A $((m*60)) b3; done > "$ST/out"
check "reboot allowed once uptime >= 10 min (31 min here)" "t+30m .*DRY: systemctl reboot"
rm -rf "$ST"/*; for m in $(seq 0 31); do NET_SELFHEAL_GPU_BUSY=1 tick "$m" A 7200 b4; done > "$ST/out"
check "GPU busy defers reboot" "reboot held: GPU busy"
nocheck "GPU busy: no reboot"  "DRY: systemctl reboot"
rm -rf "$ST"/*; for m in $(seq 0 31); do tick "$m" A 300 b5; done > "$ST/out"
nocheck "short outage at boot w/ low uptime: no reboot" "DRY: systemctl reboot"

echo "== 6. a blip (1 failed minute) does nothing"
rm -rf "$ST"/*; { tick 0 A 9000; tick 1 none 9000; } > "$ST/out"; cat "$ST/out"
nocheck "blip: no action" "DRY: "
(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
