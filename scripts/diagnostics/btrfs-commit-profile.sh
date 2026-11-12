#!/usr/bin/env bash
# Root-only, read-only profile of slow btrfs commits.
# Samples the kernel stack of btrfs-transaction (and of blocked tasks) every 0.2 s
# for $DUR seconds and dumps quota/snapshot state. Writes nothing but $OUT.
# Usage: sudo btrfs-commit-profile.sh OUTDIR [DUR=75]
set -u; TX_REQUIRED=1
OUT=${1:?outdir}; DUR=${2:-75}; OWNER=${SUDO_UID:-1000}
mkdir -p "$OUT"
UUID=$(findmnt -no UUID /); SYS=/sys/fs/btrfs/$UUID
TX=$(for p in /proc/[0-9]*; do [[ "$(cat $p/comm 2>/dev/null)" == btrfs-transacti* ]] && { basename $p; break; }; done)
[ -n "$TX" ] || { echo "btrfs-transaction thread not found" >&2; exit 2; }
{
  date -Is; uname -r; echo "tx pid $TX"; cat $SYS/commit_stats
  echo "== qgroup sysfs"; cat $SYS/qgroups/{enabled,inconsistent,status,drop_subtree_threshold,mode} 2>&1
  echo "== subvolumes";        btrfs subvolume list / 2>&1
  echo "== snapshots only";    btrfs subvolume list -s / 2>&1
  echo "== qgroup show";       btrfs qgroup show -pcre --raw / 2>&1 | head -60
  echo "== fs usage";          btrfs filesystem usage -T / 2>&1
  echo "== swapfile";          btrfs inspect-internal map-swapfile /swap/swapfile 2>&1 | head -3; lsattr /swap/swapfile 2>&1
} > "$OUT/state.txt" 2>&1
end=$(( $(date +%s) + DUR ))
: > "$OUT/tx-stacks.log"; : > "$OUT/blocked-stacks.log"
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date +%T.%N | cut -c1-12); cur=$(awk '/cur_commit/{print $2}' $SYS/commit_stats)
  st=$(awk '{print $3}' /proc/$TX/stat)
  { echo "@ $ts cur=$cur state=$st"; cat /proc/$TX/stack; } >> "$OUT/tx-stacks.log"
  if [ "$cur" != 0 ]; then
    for t in /proc/[0-9]*/task/[0-9]*; do
      [ "$(awk '{print $3}' $t/stat 2>/dev/null)" = D ] || continue
      { echo "@ $ts cur=$cur $(basename $t) $(cat $t/comm 2>/dev/null)"; cat $t/stack 2>/dev/null; } >> "$OUT/blocked-stacks.log"
    done
  fi
  sleep 0.2
done
cat $SYS/commit_stats > "$OUT/commit_stats_after.txt"
chown -R "$OWNER" "$OUT"
