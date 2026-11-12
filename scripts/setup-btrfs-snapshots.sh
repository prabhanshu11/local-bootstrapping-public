#!/bin/bash
# setup-btrfs-snapshots.sh - btrfs quotas OFF + snapper snapshots on every pacman change.
#
# Why (2026-11-01, docs/issues/btrfs-commit-stall/README.md): Omarchy's installer runs
# `btrfs quota enable /` (install/login/limine-snapper.sh) for snapper's space-aware cleanup,
# but our snapper configs have QGROUP="" so nothing uses it. Full qgroup accounting made every
# btrfs commit take 25-35 s (perf: 99.45 % in btrfs_qgroup_account_extents), freezing every
# writer (Claude chats, waybar taps). After `quota disable`: commits 38 ms, fsync max 27 ms.
# snap-pac adds pre/post snapshots of the root config on every pacman/yay transaction, which
# limine-snapper-sync turns into boot-menu entries (rollback without a chroot).
# Idempotent. Usage: setup-btrfs-snapshots.sh [--check]
set -euo pipefail
CHECK=0; [ "${1:-}" = --check ] && CHECK=1
[ "$(findmnt -no FSTYPE /)" = btrfs ] || { echo "root is not btrfs, nothing to do"; exit 0; }
uuid=$(findmnt -no UUID /)
if [ -d "/sys/fs/btrfs/$uuid/qgroups" ]; then
    echo "btrfs quotas: ENABLED (causes multi-second commit stalls)"
    if [ $CHECK = 0 ]; then
        sudo-with-notify "Disable btrfs quotas (commit stalls)" -- sudo btrfs quota disable /
    fi
else
    echo "btrfs quotas: disabled (ok)"
fi
if command -v snapper &>/dev/null; then
    if pacman -Q snap-pac &>/dev/null; then echo "snap-pac: installed (ok)"
    else
        echo "snap-pac: missing"
        [ $CHECK = 0 ] && sudo-with-notify "Install snap-pac" -- sudo pacman -S --needed --noconfirm snap-pac
    fi
fi
