#!/bin/bash
# tests/unit/test-setup-hibernate.sh — scripts/setup-hibernate.sh argument parsing, its dry-run
# plan against fake fstab / limine / mkinitcpio / /proc/swaps files, the /etc/default/limine
# rewrite (idempotent), the zz-hibernate-resume.conf hooks drop-in, the zz-hibernate-no-nvidia.conf
# MODULES drop-in and the verify grep for NVIDIA driver modules in the UKI. Nothing is applied:
# the script is only run with --dry-run / bad arguments, never as root.
#
#   tests/unit/test-setup-hibernate.sh      # exit 0 = all passed
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$HERE/scripts/setup-hibernate.sh"
DROPIN="$HERE/system/mkinitcpio.conf.d/zz-hibernate-resume.conf"
NVDROP="$HERE/system/mkinitcpio.conf.d/zz-hibernate-no-nvidia.conf"
T=$(mktemp -d -t setup-hibernate-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export HIB_LOG_DIR="$T/logs"
export HIB_UKI="$T/no-such-uki.efi"   # never inspect the real boot image from the tests

# ------------------------------------------------------------- 1. arguments
echo "argument parsing"
"$S" --bogus >/dev/null 2>&1; rc=$?
check "unknown argument exits 2" '[[ $rc == 2 ]]'
"$S" --dry-run --apply >/dev/null 2>&1; rc=$?
check "two arguments exit 2" '[[ $rc == 2 ]]'
OUT=$("$S" --help 2>&1); rc=$?
check "--help exits 0 and shows the modes" '[[ $rc == 0 && $OUT == *--apply* && $OUT == *--dry-run* ]]'
if [[ $EUID -ne 0 ]]; then
    OUT=$("$S" --apply 2>&1); rc=$?
    check "--apply as a user refuses (needs root)" '[[ $rc != 0 && $OUT == *"needs root"* ]]'
fi

# ------------------------------------------------------------- 2. dry-run plan
if [[ -d /sys/class/power_supply/BAT0 ]] && [[ $(findmnt -no FSTYPE /) == btrfs ]] &&
   [[ $(findmnt -no SOURCE / | sed 's/\[.*//') == /dev/mapper/root ]]; then
    echo "dry-run plan (fake files; this machine's root is btrfs on /dev/mapper/root)"
    mkdir -p "$T/fresh" "$T/done/swap" "$T/mk"
    printf 'UUID=x / btrfs rw,subvol=/@ 0 0\n/var/swap/swapfile1 none swap sw,pri=10 0 0\n' > "$T/fresh/fstab"
    printf 'Filename Type Size Used Priority\n/var/swap/swapfile1 file 8388604 0 10\n' > "$T/fresh/swaps"
    printf 'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]="root=/dev/mapper/root rw"\n' > "$T/fresh/limine"
    printf 'cmdline: root=/dev/mapper/root rw\n' > "$T/fresh/limine.conf"
    printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm )\nHOOKS=(base udev block encrypt filesystems fsck)\n' > "$T/mkinitcpio.conf"
    sum_before=$(cat "$T"/fresh/* | md5sum)
    OUT=$(HIB_FSTAB="$T/fresh/fstab" HIB_PROC_SWAPS="$T/fresh/swaps" HIB_LIMINE_DEFAULT="$T/fresh/limine" \
          HIB_LIMINE_CONF="$T/fresh/limine.conf" HIB_MKINIT_CONF="$T/mkinitcpio.conf" HIB_MKINIT_DIR="$T/mk" \
          HIB_SWAP_MNT="$T/fresh/swap" HIB_OLD_SWAP=/var/swap/swapfile1 "$S" --dry-run 2>&1); rc=$?
    check "fresh: dry-run exits 0" '[[ $rc == 0 ]]'
    check "fresh: plans the fstab mount line" '[[ $OUT == *"[todo] fstab: UUID="*"subvol=/@swap"* ]]'
    check "fresh: no nodatacow mount option (btrfs options are fs-wide)" '[[ $OUT != *nodatacow* ]]'
    check "fresh: plans mkswapfile 32g" '[[ $OUT == *"[todo] btrfs filesystem mkswapfile --size 32g"* ]]'
    check "fresh: plans swapon at priority 5" '[[ $OUT == *"[todo] swapon -p 5"* ]]'
    check "fresh: plans retiring the old swapfile" '[[ $OUT == *"[todo] retire /var/swap/swapfile1"* ]]'
    check "fresh: plans the resume= cmdline" '[[ $OUT == *"resume=/dev/mapper/root resume_offset="* ]]'
    check "fresh: plans the hooks drop-in" '[[ $OUT == *"[todo] install $T/mk/zz-hibernate-resume.conf"* ]]'
    check "fresh: plans the no-nvidia MODULES drop-in" '[[ $OUT == *"[todo] install $T/mk/zz-hibernate-no-nvidia.conf (MODULES now: nvidia nvidia_modeset nvidia_uvm nvidia_drm)"* ]]'
    check "fresh: plans the UKI rebuild" '[[ $OUT == *"[todo] /usr/bin/limine-mkinitcpio"* ]]'
    check "fresh: says nothing was changed" '[[ $OUT == *"Nothing was changed"* ]]'
    check "fresh: the fake files are untouched" '[[ $(cat "$T"/fresh/* | md5sum) == "$sum_before" ]]'
    check "fresh: a log is written" 'ls "$T"/logs/setup-hibernate-*.log >/dev/null 2>&1'

    # "done" state: fstab lines present, new swap active, old swap gone, drop-in installed.
    truncate -s 32G "$T/done/swap/swapfile"
    printf 'UUID=x / btrfs rw,subvol=/@ 0 0\nUUID=x %s btrfs rw,noatime,subvol=/@swap 0 0\n%s none swap defaults,pri=5 0 0\n' \
        "$T/done/swap" "$T/done/swap/swapfile" > "$T/done/fstab"
    printf 'Filename Type Size Used Priority\n%s file 33554428 0 5\n' "$T/done/swap/swapfile" > "$T/done/swaps"
    cp "$DROPIN" "$NVDROP" "$T/mk/"
    printf 'MODULES+=(thunderbolt)\n' > "$T/mk/thunderbolt_module.conf"
    OUT=$(HIB_FSTAB="$T/done/fstab" HIB_PROC_SWAPS="$T/done/swaps" HIB_LIMINE_DEFAULT="$T/fresh/limine" \
          HIB_LIMINE_CONF="$T/fresh/limine.conf" HIB_MKINIT_CONF="$T/mkinitcpio.conf" HIB_MKINIT_DIR="$T/mk" \
          HIB_SWAP_MNT="$T/done/swap" HIB_OLD_SWAP="$T/done/old/swapfile1" "$S" --dry-run 2>&1)
    check "done: fstab mount line ok"   '[[ $OUT == *"[ok]   fstab mounts $T/done/swap"* ]]'
    check "done: swapfile size ok"      '[[ $OUT == *"[ok]   $T/done/swap/swapfile exists, 32 GiB"* ]]'
    check "done: swap fstab line ok"    '[[ $OUT == *"[ok]   fstab swap line for"* ]]'
    check "done: swap active ok"        '[[ $OUT == *"[ok]   $T/done/swap/swapfile active"* ]]'
    check "done: old swap gone ok"      '[[ $OUT == *"[ok]   old $T/done/old/swapfile1 gone"* ]]'
    check "done: hooks ok (encrypt resume)" '[[ $OUT == *"[ok]   HOOKS: base udev block encrypt resume filesystems fsck"* ]]'
    check "done: MODULES ok, nvidia gone, thunderbolt kept" '[[ $OUT == *"[ok]   MODULES (no nvidia): thunderbolt"* ]]'
    check "done: no nvidia drop-in todo" '[[ $OUT != *"[todo] install $T/mk/zz-hibernate-no-nvidia.conf"* ]]'
else
    echo "dry-run plan: skipped (needs a laptop with btrfs root on /dev/mapper/root)"
fi

# ------------------------------------------------------------- 3. /etc/default/limine rewrite
echo "/etc/default/limine rewrite"
cat > "$T/limine" <<'L'
ESP_PATH="/boot"

KERNEL_CMDLINE[default]="cryptdevice=PARTUUID=abc:root root=/dev/mapper/root rw"
KERNEL_CMDLINE[default]+="quiet splash"

ENABLE_UKI=yes
L
cat > "$T/h.sh" <<H
source <(sed -n '/^limine_line()/,/^}/p' "$S")
ROOT_DEV=/dev/mapper/root
LIMINE_MARK="# hibernate resume (scripts/setup-hibernate.sh)"
LIMINE_DEFAULT="\$1"
limine_rewrite "\$2"
H
bash "$T/h.sh" "$T/limine" 111 > "$T/l1"
bash "$T/h.sh" "$T/l1" 222 > "$T/l2"
bash "$T/h.sh" "$T/l2" 222 > "$T/l3"
check "adds the resume line" 'grep -qxF "KERNEL_CMDLINE[default]+=\"resume=/dev/mapper/root resume_offset=111\"" "$T/l1"'
check "keeps every original line" '! grep -vxFf "$T/l1" "$T/limine"'
check "a new offset replaces the old one" '[[ $(grep -c resume_offset= "$T/l2") == 1 ]] && grep -q "resume_offset=222" "$T/l2"'
check "re-running is a no-op (file does not grow)" 'cmp -s "$T/l2" "$T/l3"'

# ------------------------------------------------------------- 4. hooks drop-in
echo "mkinitcpio hooks drop-in"
hooks() { bash -c "HOOKS=($1); source '$DROPIN'; $2 echo \"\${HOOKS[*]}\""; }
check "resume goes right after encrypt" '[[ $(hooks "base udev block encrypt filesystems fsck btrfs-overlayfs" "") == "base udev block encrypt resume filesystems fsck btrfs-overlayfs" ]]'
check "sourced twice: still one resume" '[[ $(hooks "block encrypt filesystems" "source '"'$DROPIN'"';") == "block encrypt resume filesystems" ]]'
check "no encrypt hook: unchanged" '[[ $(hooks "base udev block filesystems" "") == "base udev block filesystems" ]]'
check "resume already present: unchanged" '[[ $(hooks "block encrypt resume filesystems" "") == "block encrypt resume filesystems" ]]'

# ------------------------------------------------------------- 5. no-nvidia MODULES drop-in
echo "mkinitcpio MODULES drop-in (no nvidia in the boot image)"
# Evaluated the way the script (and mkinitcpio) does: mkinitcpio.conf, then conf.d/*.conf in order.
mkdir -p "$T/m5/conf.d"
printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm )\nHOOKS=(base udev plymouth kms block encrypt filesystems)\n' > "$T/m5/mkinitcpio.conf"
printf 'MODULES+=(thunderbolt)\n' > "$T/m5/conf.d/thunderbolt_module.conf"
cp "$DROPIN" "$NVDROP" "$T/m5/conf.d/"
cat > "$T/eff.sh" <<E
set -euo pipefail
source <(sed -n '/^effective_var()/,/^}/p; /^effective_hooks()/p; /^effective_modules()/p; /^modules_ok()/,/^}/p' "$S")
MKINIT_CONF="\$1" MKINIT_DIR="\$2"
case "\$3" in m) effective_modules ;; h) effective_hooks ;; ok) modules_ok && echo clean || echo dirty ;; esac
E
eff() { bash "$T/eff.sh" "$T/m5/mkinitcpio.conf" "$T/m5/conf.d" "$1"; }
check "Omarchy MODULES + thunderbolt conf.d: only thunderbolt left" '[[ $(eff m) == thunderbolt ]]'
check "modules_ok says clean" '[[ $(eff ok) == clean ]]'
check "HOOKS untouched by the MODULES drop-in (plymouth kept, resume added)" '[[ $(eff h) == "base udev plymouth kms block encrypt resume filesystems" ]]'
rm "$T/m5/conf.d/zz-hibernate-no-nvidia.conf"
check "without the drop-in: nvidia is there (modules_ok dirty)" '[[ $(eff m) == "nvidia nvidia_modeset nvidia_uvm nvidia_drm thunderbolt" && $(eff ok) == dirty ]]'
mods() { bash -c "set -u; MODULES=($1); source '$NVDROP'; echo \"\${MODULES[*]}\""; }
check "dash spellings and optional '?' are filtered too" '[[ $(mods "i915 nvidia-drm nvidia? nvidia-uvm nvidia_modeset btrfs") == "i915 btrfs" ]]'
check "other modules keep their order" '[[ $(mods "thunderbolt i915 nvme") == "thunderbolt i915 nvme" ]]'
check "empty MODULES stays empty (set -u safe)" '[[ -z $(mods "") ]]'
check "only the 4 driver modules: nvidia_wmi_ec_backlight survives" '[[ $(mods "nvidia nvidia_wmi_ec_backlight") == nvidia_wmi_ec_backlight ]]'

# ------------------------------------------------------------- 6. verify grep (UKI file list)
echo "verify grep for NVIDIA driver modules in an lsinitcpio list"
eval "$(grep -m1 '^NV_KO_RE=' "$S")"
K=usr/lib/modules/7.0.9-arch2-1
cat > "$T/list-before" <<E
$K/updates/dkms/nvidia.ko.zst
$K/updates/dkms/nvidia-drm.ko.zst
$K/updates/dkms/nvidia-modeset.ko.zst
$K/updates/dkms/nvidia-uvm.ko.zst
$K/kernel/drivers/gpu/drm/i915/i915.ko.zst
$K/kernel/drivers/hid/hid-nvidia-shield.ko.zst
$K/kernel/drivers/platform/x86/nvidia-wmi-ec-backlight.ko.zst
usr/lib/firmware/nvidia/tu117/gsp/booter_load-535.113.01.bin.zst
usr/lib/modprobe.d/nvidia-580xx-utils.conf
etc/modprobe.d/nvidia.conf
hooks/plymouth
hooks/resume
E
grep -vE "$NV_KO_RE" "$T/list-before" > "$T/list-after"
check "before the fix: 4 driver modules counted" '[[ $(grep -cE "$NV_KO_RE" "$T/list-before") == 4 ]]'
check "after the fix: 0 driver modules" '[[ $(grep -cE "$NV_KO_RE" "$T/list-after" || true) == 0 ]]'
check "firmware/modprobe.d/hid-nvidia-shield/wmi-backlight are not counted" '[[ $(grep -c nvidia "$T/list-after") == 5 ]]'
check "i915.ko is still matched by the verify grep" 'grep -q "/i915\.ko" "$T/list-after"'
OUT=$("$S" --verify 2>&1)
check "--verify with no readable UKI says so and still exits 0" '[[ $OUT == *"cannot read the UKI initramfs"* ]]'
check "--verify prints the effective MODULES line" '[[ $OUT == *"MODULES=("* ]]'

echo
echo "passed $PASS, failed $FAIL"
[[ $FAIL == 0 ]]
