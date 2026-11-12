#!/usr/bin/env bash
# safe-net-step.sh "<what>" -- <command...>
# His rule (2026-09-24): this laptop must not go off the internet at any cost.
# 1 snapshot state  2 check internet BEFORE  3 arm a detached 90 s revert timer FIRST
# 4 run the step  5 wait ≤10 s, check internet AFTER  6 fail → revert now; OK → cancel the timer.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; WHAT="$1"; shift; [[ "${1:-}" == "--" ]] && shift
LOG="$HOME/logs/home-lan-dongle.log"; UNIT="net-revert-$(date +%s)"
SNAP="$(bash "$HERE/net-snapshot.sh")"
BEFORE="$(bash "$HERE/net-state-check.sh")" || { echo "BEFORE: $BEFORE — refusing to change anything"; exit 2; }
systemd-run --user --quiet --unit="$UNIT" --on-active=90s /usr/bin/bash "$HERE/net-revert-dongle.sh" "timer $UNIT ($WHAT)"
echo "snapshot=$SNAP"; echo "BEFORE: $BEFORE"; echo "revert timer armed: $(systemctl --user list-timers "$UNIT.timer" --no-legend | awk '{print $NF, "fires", $2, $3}')"
"$@"; RC=$?
AFTER="FAIL"; for i in 1 2 3 4 5; do sleep 2; AFTER="$(bash "$HERE/net-state-check.sh")" && break; done
echo "step rc=$RC"; echo "AFTER: $AFTER"
if [[ "$AFTER" == INTERNET\ OK* ]]; then
  systemctl --user stop "$UNIT.timer" 2>/dev/null; echo "revert timer $UNIT cancelled (internet verified)"
  echo "$(date '+%F %T') STEP OK '$WHAT' before=[$BEFORE] after=[$AFTER]" >> "$LOG"
else
  systemctl --user stop "$UNIT.timer" 2>/dev/null; bash "$HERE/net-revert-dongle.sh" "step failed: $WHAT"
  echo "REVERTED: $(bash "$HERE/net-state-check.sh")"; exit 1
fi
