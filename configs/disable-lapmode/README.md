# disable-lapmode — kill the DYTC lap-mode CPU clamp (ThinkPad T14 Gen 1)

The EC's DYTC "lap mode" (CQL) infers "on a lap" from tilt/movement — bed use
qualifies — and clamps the CPU to ~0.4–1.1 GHz below the OS. `platform_profile`
cannot override it, and `dytc_lapmode` in sysfs is read-only. Decision
2026-08-18: user found it unbearably sensitive (video playback tanks) and chose
to disable it outright, reversing the earlier "visibility only" stance.

Fix: send the DYTC command that turns the CQL function off, via `acpi_call`:

```
echo '\_SB_.PCI0.LPCB.EC__.HKEY.DYTC 0x000F1001' > /proc/acpi/call
```

**A one-shot disable does NOT stick** (learned 2026-08-18, clamp returned within
minutes): the kernel's thinkpad_acpi driver re-enables CQL on every
`platform_profile` write (it wraps profile sets with CQL off→set→on), and
power-profiles-daemon plus the power-profile watchdog write profiles routinely.
So `disable-lapmode.sh` is a daemon: poll `dytc_lapmode` every 3 s, re-send the
off command whenever it reads 1, log re-arms to the journal
(`journalctl -t disable-lapmode`).

## The second clamp: firmware drops MMIO RAPL PL1 to 5 W

2026-08-18, same night: still pinned at 500 MHz with `dytc_lapmode=0`, cool
temps, `guaranteed_perf=8`, and THERM_STATUS MSRs showing "power limit"
(bits 10/11), not PROCHOT. Root cause: the EC/DPTF writes the **MMIO** RAPL
PL1 (`/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw`)
down to **5 W**, which silently overrides the healthy 51 W MSR limit that the
watchdog was looking at. 5 W sustained ≈ all cores at 400–500 MHz. This is
almost certainly the mechanism behind the previously "open" AC-side clamp too.

Fix: the daemon also checks PL1 every 3 s and restores it to 25 W (Lenovo's
own performance-mode sustained limit for this Comet Lake U chip; thermal
protection at ~95 °C still applies) whenever firmware drops it below that.
Restores are logged. Verified: 500 MHz → 3.8 GHz the instant PL1 was raised.

- `0x000F1001` = DYTC SET, function 1 (CQL/lap mode), mode 0xF, on-bit 0 → off.
  (`0x001F1001` re-enables it.)
- HKEY path from `cat /sys/bus/acpi/devices/LEN0268:00/path` — it is
  `\_SB_.PCI0.LPCB.EC__.HKEY` on this machine, NOT the `LPC0/EC0` path seen in
  most forum posts (that returns AE_NOT_FOUND).
- Success returns `0x8012b01` (low bit set); verify with
  `cat /sys/bus/platform/devices/thinkpad_acpi/dytc_lapmode` → 0.

## Install

```
sudo pacman -S --noconfirm acpi_call-dkms
sudo cp disable-lapmode.sh /usr/local/bin/
sudo cp disable-lapmode.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now disable-lapmode.service
```

Verify: `dytc_lapmode` reads 0 within ~3 s and stays 0 across
`powerprofilesctl set balanced && powerprofilesctl set performance`.

Related: `docs/issues/cpu-clamp-watchdog.md` (the watchdog still logs
`LAPMODE:` transitions — after this fix those should stay at 0). The AC-side
400 MHz clamp is a separate, still-open issue.
