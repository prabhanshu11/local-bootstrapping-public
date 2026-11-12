#!/bin/bash
# Desktop root SSD upkeep that ACTS, 2026-11-01 (his "please fix my desktop space situation.. its always falling low,
# beacues of silly reasons."). Run as root, ONE sudo:  sudo bash desktop-space-root-install.sh [REPO]
# 1. btrfs-autobalance (system/bin + system/systemd, tracked in reconcile LB_SYSTEM_FILES, gate desktop): hourly check,
#    balances only when unallocated < 8 GiB and data slack >= 12 GiB, camera-gated (relative to the tracker's own rate).
# 0. /mnt/external/{lanes-archive,cache} owned by prabhanshu (lane reaper target, HF_HOME).
# 2. pacman-contrib + paccache.timer (weekly, keeps 3 versions) and one paccache -rk2 now (old package files are
#    re-downloadable; 6.6 GB / 2659 files on 11-01).
# Every step logs before/after; a failed step is reported and skipped. Context: docs/issues/btrfs-commit-stall/
set -u
REPO=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
LOG=/var/log/desktop-space-root-install-2026-11-01.log
exec > >(tee -a "$LOG") 2>&1
echo "===== desktop-space-root-install $(date -Is) repo=$REPO ====="
df -B1G / | tail -1 | awk '{print "-- before: / used "$3" G free "$4" G"}'
echo "-- 0. user-owned homes on the 2 TB external (its top level is root-owned)"
if mountpoint -q /mnt/external; then
  install -d -o prabhanshu -g prabhanshu -m 0755 /mnt/external/lanes-archive /mnt/external/cache \
    && ls -ld /mnt/external/lanes-archive /mnt/external/cache | sed 's/^/   /'
else echo "   SKIPPED: /mnt/external not mounted"; fi
echo "-- 1. btrfs-autobalance"
if install -m 0755 "$REPO/system/bin/btrfs-autobalance" /usr/local/bin/btrfs-autobalance \
   && install -m 0644 "$REPO/system/systemd/btrfs-autobalance.service" /etc/systemd/system/btrfs-autobalance.service \
   && install -m 0644 "$REPO/system/systemd/btrfs-autobalance.timer" /etc/systemd/system/btrfs-autobalance.timer; then
  systemctl daemon-reload && systemctl enable --now btrfs-autobalance.timer \
    && echo "   timer: $(systemctl is-enabled btrfs-autobalance.timer), next $(systemctl show btrfs-autobalance.timer -p NextElapseUSecRealtime --value)"
  /usr/local/bin/btrfs-autobalance --dry-run; echo "   dry-run exit $?"
else
  echo "   FAILED: install of btrfs-autobalance files — step skipped"
fi
echo "-- 2. package cache"
echo "   before: $(du -sh /var/cache/pacman/pkg | cut -f1) in $(ls /var/cache/pacman/pkg | wc -l) files"
if pacman -S --needed --noconfirm pacman-contrib >/dev/null; then
  paccache -rk2 | tail -2
  paccache -ruk0 | tail -1
  systemctl enable --now paccache.timer && echo "   paccache.timer: $(systemctl is-enabled paccache.timer)"
  echo "   after: $(du -sh /var/cache/pacman/pkg | cut -f1) in $(ls /var/cache/pacman/pkg | wc -l) files"
else
  echo "   FAILED: pacman -S pacman-contrib — step skipped"
fi
df -B1G / | tail -1 | awk '{print "-- after: / used "$3" G free "$4" G"}'
echo "===== done $(date -Is) ====="
