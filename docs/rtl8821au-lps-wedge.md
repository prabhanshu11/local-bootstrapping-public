# RTL8821AU — Firmware LPS Wedge Incident (2026-04-15)

## Summary

TP-Link Archer T2U PLUS (`usb 5-1`, Realtek RTL8821AU, `rtw88_8821au` driver) went
silently deaf at **13:28:04** on 2026-04-15. The `wlan0` interface name persisted, but
the radio could not scan, authenticate, or pass traffic. Recovery required
physically unplugging and replugging the dongle (re-enumerated as `wlan1`).

This is **distinct from the 2026-01-14 xHCI-dies incident** (see
`progress_actual.md:130`). That was the USB host controller dying from BT
profile-switch flooding. This one is the dongle's own firmware getting stuck in
Low-Power Save (LPS) and failing to wake up — the xHCI controller was fine
throughout.

## Timeline

| Time (Apr 15) | Event |
|---|---|
| 08:09:32 | Boot. `rtw88_8821au` loads, firmware v42.4.0 reported, `wlan0` created |
| 08:09:39 | `wlan0` authenticates/associates with AP `02:00:00:00:00:02`, gets `192.168.0.100` |
| 08:09:41 – 13:28:03 | Normal operation, ~5h20m |
| **13:28:04** | **`read register 0x8ac failed with -71`** (EPROTO — USB protocol error) |
| 13:28:04 | `write register 0x8ac failed with -71` |
| 13:28:04 | `read register 0x8c4 failed with -71` |
| 13:28:04 | `failed to get tx report from firmware` |
| 13:28:07 – 13:28:08 | `failed to send h2c command` (×8) — host→card command channel dead |
| **13:28:08** | **`firmware failed to leave lps state`** ← the smoking gun |
| 13:28 – 23:02 | `wlan0` name persists but radio is deaf. iwctl/iw scans return 0 BSS. |
| 23:02:35 | User physically unplugs dongle |
| 23:02:39 | Replug. Re-enumerates as `wlan1` (stale `phy0` still bound to old name) |
| 23:02:42 | `wlan1` re-associates automatically (iwd remembered the SSID) |

## Root Cause

`rtw88_8821au` tried to wake the chip firmware from **deep Low-Power Save**
and the firmware did not respond. Once the h2c command channel is wedged, the
driver has no way to reset the firmware short of a USB re-enumeration, so the
interface stays up in name only.

### Why it happened

- `rtw88_core` module parameter `disable_lps_deep=N` (default) — **deep LPS enabled**
- `iwd` station power save: `on` (default)
- No suspend/resume, no USB bus disturbance, no BT switching — **spontaneous wedge**
- Confirmed via `/sys/module/rtw88_core/parameters/disable_lps_deep` and
  `iw dev wlan1 get power_save`

This is a well-known failure mode of the `rtw88` driver family for the
RTL8821AU/RTL8822BU/RTL8821CU adapters — upstream bug reports describe the same
`failed to leave lps state` → `failed to send h2c command` cascade, typically
after the radio idles for tens of minutes to hours.

## Why This Isn't the 2026-01 xHCI Incident

| Aspect | 2026-01 xHCI incident | 2026-04-15 LPS incident |
|---|---|---|
| Trigger | BT profile switching stress | Spontaneous (idle power save) |
| Scope | Entire `xhci_hcd 0000:08:00.3` controller | Single device (`usb 5-1` only) |
| Kernel signal | `HC died; cleaning up` | `failed to leave lps state` |
| Other devices affected | BT (UB500), HDMI capture card | None |
| Existing mitigation | 5s BT switch rate-limit, `reset-usb-wifi` | **none yet** |

The `reset-usb-wifi` recovery script works for both — but for the LPS wedge,
prevention is straightforward and worth adding.

## Fix Options

### Option A — Disable deep LPS at module level (recommended)

`/etc/modprobe.d/rtw88.conf`:
```
options rtw88_core disable_lps_deep=Y
```
Persists across reboots. Targets the exact failure mode (the driver still uses
lighter power-save states, just not the deep one that wedges).

### Option B — Disable station power save in iwd

> ⚠️ **Corrected 2026-08-29.** This section originally said
> `[General] DisablePowerSave=true`. **That key does not exist.** `iwd` silently
> ignores unknown keys, so the config would have looked applied while doing
> nothing at all. The correct option, verified against `iwd.config(5)`:

`/etc/iwd/main.conf`:
```ini
[DriverQuirks]
PowerSaveDisable=rtw88*
```
The value is a comma-separated list of driver names or glob matches — not a
boolean. The `rtw88*` glob targets only the Realtek USB adapters, so the file
is a no-op on the laptop's Intel `iwlwifi`.

Verify with `iw dev wlan0 get power_save` → should print `off`.

**Applied on the desktop 2026-08-29** as part of the dormant-wedge fix — see
`wifi-dormant-wedge.md`.

### Option C — Runtime-only (not persistent)

```
iw dev wlan1 set power_save off
```
Useful as a test but needs a systemd service or udev rule to survive reboots —
more moving parts than A or B.

### Recommendation

**Option A** is the minimal, targeted fix that matches the root cause. If it
recurs with `disable_lps_deep=Y`, escalate to **Option B**. Keep
`reset-usb-wifi` as the recovery path either way.

## Verification Plan

After applying Option A:
1. `cat /sys/module/rtw88_core/parameters/disable_lps_deep` → should print `Y`
2. Leave the radio idle for several hours
3. Check `dmesg | grep -i "lps state"` — should be empty
4. Active scan should continue to return networks after extended idle

## References

- Prior incident (xHCI crash): `progress_actual.md` lines 130–170
- Recovery script: `dotfiles/local-bin/reset-usb-wifi`
- Upstream rtw88 LPS bugs: search kernel bugzilla for "rtw88 failed to leave lps"
