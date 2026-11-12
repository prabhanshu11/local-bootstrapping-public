#!/bin/bash
# Desktop root SSD speed-up, 2026-11-01 (his "Do 1,2,3 alle."). Run as root, ONE sudo:
#   sudo bash desktop-disk-speedup.sh [RULE_FILE]
# 1. TRIM: let LUKS pass discards (persistent flag in the LUKS2 header, unlocked via the TPM2 token,
#    no passphrase), trim the free space once, enable the weekly fstrim.timer.
# 2. BFQ I/O scheduler on SATA disks now (sysfs) and at boot (udev rule) so ionice works.
# Every step logs before/after; a failed step is reported and skipped, never half-applied.
# Context: docs/issues/btrfs-commit-stall/README.md
set -u
RULE_SRC=${1:-$(dirname "$0")/../../system/udev-rules/60-ioscheduler-bfq.rules}
LOG=/var/log/desktop-disk-speedup-2026-11-01.log
exec > >(tee -a "$LOG") 2>&1
echo "===== desktop-disk-speedup $(date -Is) ====="
MAP=root
DEV=$(cryptsetup status "$MAP" | awk '/device:/{print $2}')
DM=$(basename "$(readlink -f /dev/mapper/$MAP)")
echo "-- before: luks dev=$DEV dm=$DM discard_max=$(cat /sys/block/$DM/queue/discard_max_bytes)"
cryptsetup luksDump "$DEV" | grep -E "^Version|^Flags|systemd-tpm2" | sed 's/^/   /'
for d in /sys/block/sd?; do echo "   $(basename $d) scheduler: $(cat $d/queue/scheduler)"; done
echo "   fstrim.timer: $(systemctl is-enabled fstrim.timer 2>&1)"

echo "-- 1. TRIM through LUKS"
if [ "$(cat /sys/block/$DM/queue/discard_max_bytes)" != 0 ]; then
  echo "   discards already allowed"
  TRIM_OK=1
elif cryptsetup refresh --allow-discards --persistent --token-only "$MAP"; then
  echo "   refresh OK: discard_max=$(cat /sys/block/$DM/queue/discard_max_bytes)"
  cryptsetup luksDump "$DEV" | grep -E "^Flags" | sed 's/^/   /'
  TRIM_OK=1
else
  echo "   FAILED: cryptsetup refresh via TPM2 token (exit $?) — TRIM step skipped, nothing changed"
  TRIM_OK=0
fi
if [ "$TRIM_OK" = 1 ] && [ "$(cat /sys/block/$DM/queue/discard_max_bytes)" != 0 ]; then
  t=$(date +%s); fstrim -v / ; echo "   fstrim took $(( $(date +%s)-t )) s"
  systemctl enable --now fstrim.timer && echo "   fstrim.timer: $(systemctl is-enabled fstrim.timer), next: $(systemctl show fstrim.timer -p NextElapseUSecRealtime --value)"
fi

echo "-- 2. BFQ scheduler"
if [ -f "$RULE_SRC" ]; then
  install -m 0644 "$RULE_SRC" /etc/udev/rules.d/60-ioscheduler-bfq.rules && udevadm control --reload \
    && echo "   rule installed: /etc/udev/rules.d/60-ioscheduler-bfq.rules"
else
  echo "   FAILED: rule file $RULE_SRC missing — boot persistence skipped"
fi
for d in /sys/block/sd?; do echo bfq > $d/queue/scheduler 2>/dev/null; echo "   $(basename $d): $(cat $d/queue/scheduler)"; done
echo "===== done $(date -Is) ====="
