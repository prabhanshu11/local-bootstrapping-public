#!/bin/bash
# Root half of the low-battery fix (docs/issues/laptop-low-battery-suspend.md).
# Run once through sudo-with-notify; install.sh setup does the same on a fresh machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LOG=/var/log/apply-low-battery-root.log
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) apply-low-battery-root"

install -D -m 644 "$REPO_ROOT/system/logind.conf.d/10-sleep-operation.conf" \
    /etc/systemd/logind.conf.d/10-sleep-operation.conf
install -D -m 644 "$REPO_ROOT/system/upower/10-battery-guard.conf" \
    /etc/UPower/UPower.conf.d/10-battery-guard.conf
install -m 644 "$REPO_ROOT/system/pam.d/system-login" \
    /etc/pam.d/system-login

# reload, not restart: restarting logind can drop the graphical session
systemctl reload systemd-logind
systemctl restart upower

echo "SleepOperation: $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager SleepOperation)"
echo "done"
