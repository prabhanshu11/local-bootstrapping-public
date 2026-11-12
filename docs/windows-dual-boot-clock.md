# Windows dual-boot: clock is wrong after the desktop's RTC moved to UTC

**Symptoms (Windows on the desktop, `sda3`):** the clock is off by 5 h 30 min (IST offset), time
"jumps" after booting Linux, Windows Time keeps "correcting" it, TLS/certificate or login errors
right after boot.

**Cause:** on 2026-09-11 the desktop's hardware clock (RTC) was switched from local time to UTC
(`timedatectl set-local-rtc 0`) so NTP stops stepping the Linux clock by 10 minutes on every
boot. Linux now writes UTC into the RTC; Windows still assumes the RTC is local time.
Decision + evidence: `docs/issues/desktop-unattended-boot-2026-09-11.md` (Phase 4).

**Fix (once, in Windows, admin prompt) — tell Windows the RTC is UTC:**

```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

Then reboot Windows once, or `w32tm /resync` if the Windows Time service is running.
For 64-bit Windows this DWORD is enough; do NOT use a QWORD (older advice), it is ignored.

**Do not** "fix" it from the Linux side with `timedatectl set-local-rtc 1` — that reintroduces the
10-minute step at every Linux boot and the DST/timezone warnings systemd prints for local RTC.

**Verify from Linux:** `timedatectl` shows `RTC in local TZ: no` and `cat /sys/class/rtc/rtc0/time`
equals `date -u +%T`.

Status: pending — he has not booted Windows since the change (as of 2026-09-14).
