#!/bin/bash
# scripts/setup-hibernate.sh — make hibernate real on the laptop so it can be the last resort
# when suspend fails at low battery (2026-10-06). Idempotent: every step checks first.
# See docs/issues/laptop-hibernate-setup-2026-10-06.md
#
#   setup-hibernate.sh [--dry-run]   print the plan, change nothing (default; no root needed)
#   setup-hibernate.sh --apply       do it (root; run ONCE via
#        sudo-with-notify "hibernate setup: ..." -- sudo scripts/setup-hibernate.sh --apply)
#   setup-hibernate.sh --verify      print the verification block only
#
# What --apply does:
#   1. btrfs subvolume @swap (top level, so snapper's @ snapshots never contain the active
#      swapfile), mounted at /swap via fstab, NOCOW; /swap/swapfile 32 GiB (>= RAM), swap prio 5
#      (below zram's 100), fstab line; then the old /var/swap/swapfile1 (inside @) is retired.
#   2. resume=/dev/mapper/root resume_offset=<N> in /etc/default/limine (Omarchy's limine
#      generator input), `resume` hook after `encrypt` (drop-in zz-hibernate-resume.conf),
#      /usr/bin/limine-mkinitcpio rebuilds the UKI + /boot/limine.conf.
#   2b. drop-in zz-hibernate-no-nvidia.conf filters nvidia* out of MODULES, so the boot image
#      never loads the NVIDIA driver before `resume` (2026-10-06 22:30: nv_pmops_freeze -5
#      aborted the resume of a good image). The rebuild then proves no nvidia*.ko is in the UKI.
#   3. /sys/power/resume + resume_offset now, and hibernate-resume-config.service at boot.
#   4. UPower: Low 30 / Critical 12 / Action 6 %, CriticalPowerAction=Hibernate.
#   5. sleep.conf.d: HibernateMode=platform shutdown. logind SleepOperation stays suspend.
#
# Test overrides (dry-run/unit tests only): HIB_FSTAB HIB_LIMINE_DEFAULT HIB_LIMINE_CONF
# HIB_MKINIT_CONF HIB_MKINIT_DIR HIB_PROC_SWAPS HIB_SYS_POWER HIB_LOG_DIR HIB_SWAP_MNT HIB_OLD_SWAP
# HIB_UKI
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=dry-run
[[ $# -le 1 ]] || { echo "setup-hibernate: one argument at most" >&2; usage >&2; exit 2; }
case "${1:-}" in
    ""|--dry-run) MODE=dry-run ;;
    --apply)      MODE=apply ;;
    --verify)     MODE=verify ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "setup-hibernate: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT_DEV=/dev/mapper/root
SWAP_MNT=${HIB_SWAP_MNT:-/swap}
SWAPFILE=$SWAP_MNT/swapfile
SWAP_SIZE_G=32
SWAP_SIZE_B=$((SWAP_SIZE_G * 1024 * 1024 * 1024))
SWAP_PRIO=5
OLD_SWAP=${HIB_OLD_SWAP:-/var/swap/swapfile1}
FSTAB=${HIB_FSTAB:-/etc/fstab}
LIMINE_DEFAULT=${HIB_LIMINE_DEFAULT:-/etc/default/limine}
LIMINE_CONF=${HIB_LIMINE_CONF:-/boot/limine.conf}
MKINIT_CONF=${HIB_MKINIT_CONF:-/etc/mkinitcpio.conf}
MKINIT_DIR=${HIB_MKINIT_DIR:-/etc/mkinitcpio.conf.d}
PROC_SWAPS=${HIB_PROC_SWAPS:-/proc/swaps}
SYS_POWER=${HIB_SYS_POWER:-/sys/power}
LIMINE_MARK="# hibernate resume (scripts/setup-hibernate.sh)"
UKI=${HIB_UKI:-/boot/EFI/Linux/omarchy_linux.efi}
TS=$(date +%Y%m%d-%H%M%S)

USER_NAME=${SUDO_USER:-$(id -un)}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
LOG_DIR=${HIB_LOG_DIR:-$USER_HOME/logs}
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/setup-hibernate-$TS.log"
exec > >(tee -a "$LOG") 2>&1
[[ $MODE == apply && -n ${SUDO_USER:-} ]] && trap 'chown "$SUDO_USER:" "$LOG" 2>/dev/null || true' EXIT
echo "=== $(date -Is) setup-hibernate --$MODE (log $LOG)"

# ------------------------------------------------------------------ helpers
TODO=0
ok()   { printf '  [ok]   %s\n' "$*"; }
todo() { TODO=$((TODO + 1)); printf '  [todo] %s\n' "$*"; }
doing(){ printf '  [do]   %s\n' "$*"; }
die()  { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
apply(){ [[ $MODE == apply ]]; }

swap_active() { awk -v f="$1" 'NR > 1 && $1 == f { found = 1 } END { exit !found }' "$PROC_SWAPS"; }
fstab_has_target() { awk -v t="$1" '$1 !~ /^#/ && $2 == t { found = 1 } END { exit !found }' "$FSTAB"; }
fstab_has_source() { awk -v s="$1" '$1 == s { found = 1 } END { exit !found }' "$FSTAB"; }

# The resume line we want in /etc/default/limine for a given offset.
limine_line() { printf 'KERNEL_CMDLINE[default]+="resume=%s resume_offset=%s"\n' "$ROOT_DEV" "$1"; }
# /etc/default/limine with our two lines replaced by the ones for offset $1 (stdout).
# Drops any earlier resume_offset line and our marker, and trailing blank lines (so re-runs
# do not grow the file), then appends the marker and the line.
limine_rewrite() {
    awk -v m="$LIMINE_MARK" '
        index($0, "resume_offset=") || $0 == m { next }
        { buf[n++] = $0 }
        END { while (n > 0 && buf[n - 1] == "") n--; for (i = 0; i < n; i++) print buf[i] }
    ' "$LIMINE_DEFAULT"
    printf '\n%s\n' "$LIMINE_MARK"
    limine_line "$1"
}
# HOOKS / MODULES as mkinitcpio sees them: mkinitcpio.conf, then every conf.d drop-in in order
# (mkinitcpio has no print-config flag; this is the same sourcing it does).
effective_var() {
    HIB_C="$MKINIT_CONF" HIB_D="$MKINIT_DIR" HIB_V="$1" bash -c '
        HOOKS=(); MODULES=(); source "$HIB_C" >/dev/null 2>&1
        for f in "$HIB_D"/*.conf; do [[ -e $f ]] && source "$f" >/dev/null 2>&1; done
        declare -n v=$HIB_V; echo "${v[*]}"'
}
effective_hooks()   { effective_var HOOKS; }
effective_modules() { effective_var MODULES; }
modules_ok() {   # same names (and -/_ and "?" spellings) as zz-hibernate-no-nvidia.conf filters
    local m
    for m in $(effective_modules); do
        m=${m%\?}; m=${m//-/_}
        case $m in nvidia|nvidia_modeset|nvidia_uvm|nvidia_drm) return 1 ;; esac
    done
}
# The NVIDIA kernel driver modules (nvidia, nvidia-drm/-modeset/-uvm/-peermem) inside a file
# list from lsinitcpio. Not a bare "nvidia" grep: firmware/nvidia/* (nouveau's firmware, pulled
# in by the kms hook), the nouveau blacklist in modprobe.d and hid-nvidia-shield all contain
# the word and are harmless.
NV_KO_RE='/nvidia([-_](drm|modeset|uvm|peermem))?\.ko'
# The UKI's initramfs file list on stdout (no root needed); fails if there is no readable UKI.
uki_initrd_list() {
    command -v objcopy >/dev/null && command -v lsinitcpio >/dev/null && [[ -r $UKI ]] || return 1
    local t rc=0; t=$(mktemp -d)
    objcopy -O binary --only-section=.initrd "$UKI" "$t/initrd" 2>/dev/null && lsinitcpio "$t/initrd" 2>/dev/null || rc=1
    rm -rf "$t"; return $rc
}
hooks_ok() { [[ " $(effective_hooks) " == *" encrypt resume "* ]]; }
swap_offset() { btrfs inspect-internal map-swapfile -r "$SWAPFILE" 2>/dev/null; }

# ------------------------------------------------------------------ verification block
verify() {
    echo
    echo "=== verification $(date -Is)"
    echo "--- swapon --show"
    swapon --show 2>/dev/null || cat "$PROC_SWAPS"
    echo "--- /sys/power"
    echo "resume=$(cat "$SYS_POWER/resume" 2>/dev/null)  resume_offset=$(cat "$SYS_POWER/resume_offset" 2>/dev/null)  disk=$(cat "$SYS_POWER/disk" 2>/dev/null)"
    echo "($ROOT_DEV is $(lsblk -dno MAJ:MIN "$ROOT_DEV" 2>/dev/null | tr -d ' '); offset now $( [[ $EUID == 0 ]] && swap_offset || echo '<needs root>'))"
    echo "--- cmdline source ($LIMINE_DEFAULT)"
    grep -n 'resume' "$LIMINE_DEFAULT" 2>/dev/null || echo "(no resume= in $LIMINE_DEFAULT)"
    echo "--- regenerated $LIMINE_CONF"
    grep -n 'cmdline:' "$LIMINE_CONF" 2>/dev/null | grep -m3 'resume=' || echo "(no resume= in $LIMINE_CONF)"
    if command -v objcopy >/dev/null && [[ -r $UKI ]]; then
        local t; t=$(mktemp -d)
        objcopy -O binary --only-section=.cmdline "$UKI" "$t/cmdline" 2>/dev/null &&
            echo "UKI .cmdline: $(tr -d '\0' < "$t/cmdline" | grep -o 'resume[^ ]*' | tr '\n' ' ')"
        rm -rf "$t"
    fi
    echo "--- UKI initramfs ($UKI)"
    local list
    if list=$(uki_initrd_list); then
        grep -q 'hooks/resume$' <<< "$list" && echo "hooks/resume: yes" || echo "hooks/resume: NO"
        grep -q 'hooks/plymouth$' <<< "$list" && echo "hooks/plymouth: yes" || echo "hooks/plymouth: NO"
        grep -q '/i915\.ko' <<< "$list" && echo "i915.ko: yes" || echo "i915.ko: NO"
        echo "nvidia driver modules (nvidia*.ko): $(grep -cE "$NV_KO_RE" <<< "$list" || true) $(
            grep -E "$NV_KO_RE" <<< "$list" | sed 's|.*/||' | tr '\n' ' ')"
        echo "(lines matching bare 'nvidia': $(grep -c nvidia <<< "$list" || true) = firmware/nvidia/*, modprobe.d, hid-nvidia-shield; not the driver)"
    else
        echo "(cannot read the UKI initramfs)"
    fi
    echo "--- /proc/cmdline (resume= appears here only after the next reboot)"
    grep -o 'resume[^ ]*' /proc/cmdline || echo "(none yet)"
    echo "--- HOOKS (effective)"
    effective_hooks
    echo "--- MODULES (effective: $MKINIT_CONF + $MKINIT_DIR/*.conf)"
    echo "MODULES=($(effective_modules))"
    grep -n '^MODULES' "$MKINIT_CONF" 2>/dev/null | sed 's/^/(raw mkinitcpio.conf line /; s/$/)/'
    echo "--- units"
    for u in nvidia-hibernate nvidia-suspend-then-hibernate hibernate-resume-config; do
        printf '%s: %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || true)"
    done
    echo "logind CanHibernate: $(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null || echo '?')"
    echo "--- sleep.conf.d"
    cat /etc/systemd/sleep.conf.d/10-hibernate.conf 2>/dev/null | grep -v '^#' || echo "(missing)"
    echo "--- UPower"
    grep -v '^#' /etc/UPower/UPower.conf.d/10-battery-guard.conf 2>/dev/null || echo "(missing)"
    echo "upower: $(systemctl is-active upower 2>/dev/null)"
    echo "--- fstab"
    grep -nE "[[:space:]]${SWAP_MNT}[[:space:]]|${SWAPFILE}|${OLD_SWAP}" "$FSTAB" || true
}

if [[ $MODE == verify ]]; then verify; exit 0; fi

# ------------------------------------------------------------------ preflight
[[ $MODE == apply && $EUID -ne 0 ]] && die "--apply needs root (sudo-with-notify ... -- sudo $0 --apply)"
if [[ ! -d /sys/class/power_supply/BAT0 ]]; then
    echo "no battery: hibernate as a low-battery last resort is laptop-only; nothing to do"; exit 0
fi
[[ $(findmnt -no FSTYPE /) == btrfs ]] || die "/ is not btrfs"
[[ $(findmnt -no SOURCE / | sed 's/\[.*//') == "$ROOT_DEV" ]] || die "/ is not on $ROOT_DEV"
FS_UUID=$(findmnt -no UUID /)
RAM_B=$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)
(( SWAP_SIZE_B >= RAM_B )) || die "swapfile ${SWAP_SIZE_G}G is smaller than RAM ($RAM_B bytes)"
echo "root $ROOT_DEV (btrfs $FS_UUID), RAM $((RAM_B / 1024 / 1024)) MiB, swapfile ${SWAP_SIZE_G} GiB at $SWAPFILE"
echo

# ------------------------------------------------------------------ 1. @swap subvolume + swapfile
echo "1. swap subvolume and swapfile"
SWAP_FSTAB_LINE="UUID=$FS_UUID $SWAP_MNT btrfs rw,noatime,subvol=/@swap 0 0"
# nodatacow is NOT a mount option here: btrfs options are filesystem-wide, the second subvolume
# mount would change them for /. NOCOW comes from chattr +C (mkswapfile sets it on the file).
if [[ $(findmnt -no FSROOT "$SWAP_MNT" 2>/dev/null) == /@swap ]]; then
    ok "@swap mounted at $SWAP_MNT"
else
    todo "create subvolume @swap at the top level (subvolid=5) if missing, mount at $SWAP_MNT"
    if apply; then
        top=$(mktemp -d /run/setup-hibernate.XXXXXX)
        mount -o subvolid=5 "$ROOT_DEV" "$top"
        trap 'umount "$top" 2>/dev/null; rmdir "$top" 2>/dev/null' EXIT
        if [[ -d $top/@swap ]]; then doing "@swap exists"; else btrfs subvolume create "$top/@swap"; fi
        chattr +C "$top/@swap"
        umount "$top"; rmdir "$top"; trap - EXIT
        [[ -n ${SUDO_USER:-} ]] && trap 'chown "$SUDO_USER:" "$LOG" 2>/dev/null || true' EXIT
    fi
fi
if fstab_has_target "$SWAP_MNT"; then
    ok "fstab mounts $SWAP_MNT"
else
    todo "fstab: $SWAP_FSTAB_LINE"
    if apply; then
        cp -a "$FSTAB" "$FSTAB.bak-hibernate-$TS"
        printf '# hibernate swap subvolume (scripts/setup-hibernate.sh)\n%s\n' "$SWAP_FSTAB_LINE" >> "$FSTAB"
        systemctl daemon-reload
    fi
fi
if apply && ! mountpoint -q "$SWAP_MNT"; then
    mkdir -p "$SWAP_MNT"; mount "$SWAP_MNT"
    [[ $(findmnt -no FSROOT "$SWAP_MNT") == /@swap ]] || die "$SWAP_MNT did not mount @swap"
fi
if apply; then chattr +C "$SWAP_MNT"; chmod 700 "$SWAP_MNT"; fi

if [[ -f $SWAPFILE && $(stat -c %s "$SWAPFILE" 2>/dev/null) == "$SWAP_SIZE_B" ]]; then
    ok "$SWAPFILE exists, ${SWAP_SIZE_G} GiB"
elif [[ $EUID -ne 0 && -d $SWAP_MNT && ! -x $SWAP_MNT ]]; then
    echo "  [?]    $SWAPFILE size: $SWAP_MNT is root-only (700); --apply re-checks as root"
else
    todo "btrfs filesystem mkswapfile --size ${SWAP_SIZE_G}g $SWAPFILE"
    if apply; then
        swap_active "$SWAPFILE" && swapoff "$SWAPFILE"
        rm -f "$SWAPFILE"
        avail=$(df --output=avail -B1 "$SWAP_MNT" | tail -1)
        (( avail > SWAP_SIZE_B + 20 * 1024 ** 3 )) || die "not enough free space ($avail bytes) for a ${SWAP_SIZE_G}G swapfile + 20G margin"
        btrfs filesystem mkswapfile --size "${SWAP_SIZE_G}g" "$SWAPFILE"
    fi
fi
if fstab_has_source "$SWAPFILE"; then
    ok "fstab swap line for $SWAPFILE"
else
    todo "fstab: $SWAPFILE none swap defaults,pri=$SWAP_PRIO 0 0"
    if apply; then
        [[ -e $FSTAB.bak-hibernate-$TS ]] || cp -a "$FSTAB" "$FSTAB.bak-hibernate-$TS"
        printf '%s none swap defaults,pri=%s 0 0\n' "$SWAPFILE" "$SWAP_PRIO" >> "$FSTAB"
        systemctl daemon-reload
    fi
fi
if swap_active "$SWAPFILE"; then
    ok "$SWAPFILE active"
else
    todo "swapon -p $SWAP_PRIO $SWAPFILE"
    apply && swapon -p "$SWAP_PRIO" "$SWAPFILE"
fi

# Retire the old swapfile only once the new one is active (gate destructive steps on success).
if swap_active "$OLD_SWAP" || fstab_has_source "$OLD_SWAP" || [[ -e $OLD_SWAP ]]; then
    todo "retire $OLD_SWAP: swapoff, drop its fstab line, delete it (only after $SWAPFILE is active)"
    if apply; then
        swap_active "$SWAPFILE" || die "new swap not active; old swap left in place"
        swap_active "$OLD_SWAP" && swapoff "$OLD_SWAP"
        if fstab_has_source "$OLD_SWAP"; then
            [[ -e $FSTAB.bak-hibernate-$TS ]] || cp -a "$FSTAB" "$FSTAB.bak-hibernate-$TS"
            awk -v s="$OLD_SWAP" '$1 != s' "$FSTAB" > "$FSTAB.new" && cat "$FSTAB.new" > "$FSTAB" && rm "$FSTAB.new"
            systemctl daemon-reload
        fi
        rm -f "$OLD_SWAP"
        rmdir "$(dirname "$OLD_SWAP")" 2>/dev/null || true
    fi
else
    ok "old $OLD_SWAP gone"
fi

# ------------------------------------------------------------------ 2. cmdline + initramfs
echo "2. resume= cmdline, resume hook, UKI"
if [[ $EUID == 0 && -f $SWAPFILE ]]; then
    OFFSET=$(swap_offset) || die "map-swapfile failed for $SWAPFILE"
    [[ $OFFSET =~ ^[0-9]+$ ]] || die "bad resume_offset '$OFFSET'"
elif [[ $(cat "$SYS_POWER/resume_offset" 2>/dev/null) =~ ^[1-9][0-9]*$ ]]; then
    OFFSET=$(cat "$SYS_POWER/resume_offset")   # dry-run as a user: the live value; --apply re-measures
else
    OFFSET='<N>'
fi
echo "  resume_offset=$OFFSET"
REGEN=0
if grep -qxF "$(limine_line "$OFFSET")" "$LIMINE_DEFAULT" 2>/dev/null; then
    ok "$LIMINE_DEFAULT has $(limine_line "$OFFSET")"
else
    todo "$LIMINE_DEFAULT: $(limine_line "$OFFSET") (old resume lines replaced; backup kept)"
    if apply; then
        cp -a "$LIMINE_DEFAULT" "$LIMINE_DEFAULT.bak-hibernate-$TS"
        limine_rewrite "$OFFSET" > "$LIMINE_DEFAULT.new"
        grep -q '^ESP_PATH=' "$LIMINE_DEFAULT.new" && grep -q '^KERNEL_CMDLINE\[default\]="' "$LIMINE_DEFAULT.new" ||
            die "rewritten $LIMINE_DEFAULT lost ESP_PATH or the base cmdline; left unchanged (see .new)"
        cat "$LIMINE_DEFAULT.new" > "$LIMINE_DEFAULT"; rm "$LIMINE_DEFAULT.new"
        REGEN=1
    fi
fi
DROPIN_SRC="$REPO_ROOT/system/mkinitcpio.conf.d/zz-hibernate-resume.conf"
if cmp -s "$DROPIN_SRC" "$MKINIT_DIR/zz-hibernate-resume.conf" && hooks_ok; then
    ok "HOOKS: $(effective_hooks)"
else
    todo "install $MKINIT_DIR/zz-hibernate-resume.conf (resume after encrypt)"
    if apply; then
        install -m 644 "$DROPIN_SRC" "$MKINIT_DIR/zz-hibernate-resume.conf"
        hooks_ok || die "resume hook not after encrypt: $(effective_hooks)"
        REGEN=1
    fi
fi
NV_SRC="$REPO_ROOT/system/mkinitcpio.conf.d/zz-hibernate-no-nvidia.conf"
if cmp -s "$NV_SRC" "$MKINIT_DIR/zz-hibernate-no-nvidia.conf" && modules_ok; then
    ok "MODULES (no nvidia): $(effective_modules)"
else
    todo "install $MKINIT_DIR/zz-hibernate-no-nvidia.conf (MODULES now: $(effective_modules))"
    if apply; then
        install -m 644 "$NV_SRC" "$MKINIT_DIR/zz-hibernate-no-nvidia.conf"
        modules_ok || die "nvidia still in MODULES: $(effective_modules)"
    fi
    REGEN=1   # also in a dry run, so the plan shows the rebuild
fi
if UKI_LIST=$(uki_initrd_list); then
    NV_IN_UKI=$(grep -cE "$NV_KO_RE" <<< "$UKI_LIST" || true)
    if (( NV_IN_UKI == 0 )); then
        ok "UKI initramfs has no NVIDIA driver module"
    else
        todo "UKI initramfs still carries $NV_IN_UKI NVIDIA driver module(s): rebuild"
        REGEN=1
    fi
else
    echo "  (no readable UKI at $UKI to inspect)"
fi
if [[ $OFFSET != '<N>' ]] && grep -q "resume_offset=$OFFSET" "$LIMINE_CONF" 2>/dev/null && (( REGEN == 0 )); then
    ok "$LIMINE_CONF already carries resume_offset=$OFFSET"
else
    todo "/usr/bin/limine-mkinitcpio (rebuild initramfs/UKI: resume hook, no nvidia; regenerate $LIMINE_CONF)"
    if apply; then
        cp -a "$LIMINE_CONF" "$LIMINE_CONF.bak-hibernate-$TS"
        /usr/bin/limine-mkinitcpio
        grep -q "resume_offset=$OFFSET" "$LIMINE_CONF" || die "$LIMINE_CONF has no resume_offset=$OFFSET after regeneration"
        UKI_LIST=$(uki_initrd_list) || die "cannot read the rebuilt UKI initramfs ($UKI)"
        grep -qE "$NV_KO_RE" <<< "$UKI_LIST" && die "rebuilt UKI still carries NVIDIA driver modules"
        grep -q '/i915\.ko' <<< "$UKI_LIST" || die "rebuilt UKI has no i915.ko (the panel's driver)"
        grep -q 'hooks/resume$' <<< "$UKI_LIST" || die "rebuilt UKI has no resume hook"
        ok "rebuilt UKI: resume hook, i915, no nvidia*.ko"
    fi
fi

# ------------------------------------------------------------------ 3. /sys/power now + at boot
echo "3. /sys/power/resume now and at every boot"
MAJMIN=$(lsblk -dno MAJ:MIN "$ROOT_DEV" | tr -d ' ')
if [[ $(cat "$SYS_POWER/resume" 2>/dev/null) == "$MAJMIN" && $(cat "$SYS_POWER/resume_offset" 2>/dev/null) == "$OFFSET" ]]; then
    ok "/sys/power/resume=$MAJMIN resume_offset=$OFFSET"
else
    todo "write $OFFSET > /sys/power/resume_offset, $MAJMIN > /sys/power/resume"
    if apply; then
        echo "$OFFSET" > "$SYS_POWER/resume_offset"
        echo "$MAJMIN" > "$SYS_POWER/resume"
    fi
fi
UNIT_SRC="$REPO_ROOT/system/systemd/hibernate-resume-config.service"
BIN_SRC="$REPO_ROOT/system/bin/hibernate-resume-config"
if cmp -s "$UNIT_SRC" /etc/systemd/system/hibernate-resume-config.service &&
   cmp -s "$BIN_SRC" /usr/local/bin/hibernate-resume-config &&
   [[ $(systemctl is-enabled hibernate-resume-config 2>/dev/null) == enabled ]]; then
    ok "hibernate-resume-config.service installed and enabled"
else
    todo "install + enable hibernate-resume-config.service (/usr/local/bin/hibernate-resume-config)"
    if apply; then
        install -m 755 "$BIN_SRC" /usr/local/bin/hibernate-resume-config
        install -m 644 "$UNIT_SRC" /etc/systemd/system/hibernate-resume-config.service
        systemctl daemon-reload
        systemctl enable hibernate-resume-config.service
    fi
fi

# ------------------------------------------------------------------ 4. UPower, 5. sleep.conf.d
echo "4. UPower (Low 30 / Critical 12 / Action 6 %, CriticalPowerAction=Hibernate)"
UP_SRC="$REPO_ROOT/system/upower/10-battery-guard.conf"
UP_DST=/etc/UPower/UPower.conf.d/10-battery-guard.conf
if cmp -s "$UP_SRC" "$UP_DST"; then
    ok "$UP_DST current"
else
    todo "install $UP_DST, restart upower"
    if apply; then
        install -D -m 644 "$UP_SRC" "$UP_DST"
        systemctl restart upower
    fi
fi
echo "5. systemd sleep.conf.d (HibernateMode=platform shutdown; logind SleepOperation untouched)"
SL_SRC="$REPO_ROOT/system/systemd/sleep.conf.d/10-hibernate.conf"
SL_DST=/etc/systemd/sleep.conf.d/10-hibernate.conf
if cmp -s "$SL_SRC" "$SL_DST"; then
    ok "$SL_DST current"
else
    todo "install $SL_DST"
    apply && install -D -m 644 "$SL_SRC" "$SL_DST"
fi
if [[ $(systemctl is-enabled nvidia-hibernate 2>/dev/null) == enabled ]]; then
    ok "nvidia-hibernate.service enabled (nvidia-suspend-then-hibernate deliberately left $(systemctl is-enabled nvidia-suspend-then-hibernate 2>/dev/null || true))"
else
    todo "enable nvidia-hibernate.service"
    apply && systemctl enable nvidia-hibernate.service
fi

echo
if apply; then
    echo "applied. Next: ONE real hibernate test (resume= is on the cmdline since the 10-06 reboot;"
    echo "the rebuilt boot image is used at the next power-on, which is the resume itself)."
    verify
else
    echo "dry run: $TODO step(s) to do. Nothing was changed. Apply with:"
    echo "  sudo-with-notify \"hibernate setup: swapfile, resume hook, limine cmdline, upower\" -- sudo $REPO_ROOT/scripts/setup-hibernate.sh --apply"
fi
