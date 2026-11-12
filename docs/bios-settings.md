# BIOS Settings for Automated Recovery

## ASUS PRIME A520M-K — Auto Power On After AC Loss

### Problem

When AC power is lost (outage, tripped breaker, UPS failure), the desktop
stays off until someone physically presses the power button.

### BIOS Setting

1. Boot into BIOS: Press `DEL` during POST
2. Navigate: **Advanced > APM Configuration**
3. Set: **Restore AC Power Loss** to **Power On**
4. Save and exit (`F10`)

### Options

| Setting | Behavior |
|---------|----------|
| Power Off (default) | Desktop stays off after power loss |
| Power On | Desktop auto-boots when power returns |
| Last State | Restores whatever state it was in (on/off) |

### Why "Power On"

- Desktop is always-on (Tailscale peer, Telegram bot, Sunshine server)
- Power loss = service outage until manual intervention
- With "Power On", the desktop self-recovers after outages
- Combined with `power-loss-monitor` service for detection and alerting

### Verifying It Works

After setting this, `power-loss-monitor` will track every boot:
```bash
# Check last boot type
power-loss-monitor status

# See all boot history
power-loss-monitor history
```

If you see `POWER_LOSS` events with short gaps (< 5 min), the BIOS
auto-start is working — the system rebooted itself after power returned.

### Related

- `power-loss-monitor` service detects unclean shutdowns at boot
- Waybar widget shows last boot type (clean / reboot / power loss)
- History: `~/.local/state/power-monitor/history.log`

### Other Boards

| Vendor | Path |
|--------|------|
| ASUS | Advanced > APM Configuration > Restore AC Power Loss |
| Gigabyte | BIOS Features > AC Recovery |
| MSI | Settings > Advanced > Power Management |
| ASRock | Advanced > ACPI Configuration > Restore on AC Power Loss |

## The software half: `scripts/setup-server-mode.sh` (added 2026-09-11)

The BIOS setting above is only half of "the desktop is a server". The other half was three hand edits that never lived in this repo:
sleep/suspend/hibernate/hybrid-sleep targets masked (2025-12-25), SDDM autologin, `loginctl enable-linger` (2026-04-15). On 2026-03-09
suspend was unmasked "for today only" and never re-masked; `power-loss-monitor.service` was never enabled on the desktop, so the two
outages of 2026-09-09/10 went unrecorded. `scripts/setup-server-mode.sh on|off|status` makes the state reproducible; `off` is the
reversible "suspend for today" hatch. Wake-on-LAN is deliberately not enabled: the desktop runs on Wi-Fi (enp4s0 has no carrier).

See also `windows-dual-boot-clock.md` — the RTC is UTC since 2026-09-11; Windows needs RealTimeIsUniversal=1.
