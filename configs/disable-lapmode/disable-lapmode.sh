#!/bin/sh
# Keep ThinkPad DYTC lap mode (CQL) off. A one-shot disable does not stick:
# the kernel re-enables CQL on every platform_profile write (thinkpad_acpi
# wraps profile sets with CQL off->set->on), so power-profiles-daemon and the
# power-profile watchdog re-arm the clamp behind our backs. Poll and re-send.
LAPMODE=/sys/bus/platform/devices/thinkpad_acpi/dytc_lapmode
CALL=/proc/acpi/call
CMD='\_SB_.PCI0.LPCB.EC__.HKEY.DYTC 0x000F1001'
# Firmware (DPTF/EC) clamps by writing the MMIO RAPL PL1 — it overrides the
# 51W MSR limit; observed dropped to 5W, pinning all cores at 400-500 MHz.
PL1=/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
PL1_WANT=25000000

modprobe acpi_call

while :; do
    if [ "$(cat "$LAPMODE" 2>/dev/null)" = "1" ]; then
        echo "$CMD" > "$CALL"
        logger -t disable-lapmode "lap mode re-armed by EC/kernel; disabled again"
    fi
    cur=$(cat "$PL1" 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" -lt "$PL1_WANT" ]; then
        echo "$PL1_WANT" > "$PL1"
        logger -t disable-lapmode "MMIO PL1 clamped to ${cur}uW by firmware; restored to ${PL1_WANT}uW"
    fi
    sleep 3
done
