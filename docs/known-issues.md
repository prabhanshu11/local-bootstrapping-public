# Known Issues

## CRITICAL/OPEN: Blank Desktop After Login (2026-02-16)

**Status:** OPEN — NOT YET DIAGNOSED

Desktop shows blank/black screen after login (greetd/tuigreet authentication succeeds but compositor/session fails to render). User is locked out of the desktop environment.

**Dedicated document:** [`docs/blank-desktop-after-login.md`](blank-desktop-after-login.md)

**Quick recovery:** TTY via `Ctrl+Alt+F2`, or SSH via `ssh desktop` (Tailscale) — and if Tailscale itself is down, `ssh desktop-lan` (LAN, works without Tailscale; added 2026-07-20). See dedicated document for full diagnosis steps and possible causes.

---

## RESOLVED: Desktop Icons Gone 4 Days + Config Error Banner Over the Bar (2026-11-06)

**Status:** RESOLVED — two follow-ups open (a reconcile check that dicons runs; the segfault itself)

`dicons` segfaulted on 11-02 and `exec-once` never restarted it, so the desktop icons (including Restart Topbar) were gone for 4 days. Separately, a lane linked `bindings-screenshot.conf` into its own clone before the file existed, which left a stale Hyprland "source= file ... is inaccessible" banner. Fixed by `dotfiles/local-bin/dicons-keepalive` (restarts dicons after a crash) and by re-pointing the link to the main checkout. Lesson: Hyprland's PATH has no `~/.local/bin`, so autostart needs full paths.

**Dedicated document:** [`docs/issues/desktop-icons-gone-and-bar-config-error-2026-11-06.md`](issues/desktop-icons-gone-and-bar-config-error-2026-11-06.md)

---

## RESOLVED: SSH Between Machines Depended Entirely on Tailscale (2026-07-20)

**Status:** RESOLVED — one follow-up open (the `pi5` alias)

UFW allowed port 22 only from `100.64.0.0/10`, so a lapsed Tailscale session cut all access between desktop and laptop — even sitting 2ms apart on the same LAN. Not a regression: this was the original design intent, predating the repo. Fixed by allowing SSH from the home LAN (interlocked behind key-only sshd) and adding `desktop-lan` / `laptop-lan` / `pi5-lan` aliases.

**Dedicated document:** [`docs/issues/ssh-tailscale-single-point-of-failure.md`](issues/ssh-tailscale-single-point-of-failure.md)

**Still open:** `ssh pi5` points at the dead `192.168.29.10`; its pending fix (`d1ff497`, stranded on a desktop branch) repoints it at Tailscale, which is worth reconsidering.

---

## OPEN: Desktop Repo Stranded on a Feature Branch (2026-07-20)

**Status:** OPEN — nothing lost, but 4 commits since April exist on one disk only

Desktop's `local-bootstrapping` sits on `fix/rtl8821au-scan-deaf`: 4 unpushed commits, 23 behind master, dirty tree, 3 stashes. The dirty tree blocks the 10-minute sync timer, which is why it keeps falling further behind.

**Dedicated document:** [`docs/issues/desktop-branch-divergence.md`](issues/desktop-branch-divergence.md)

---

## Expected Waybar Icons (Right Section)

The following icons should be visible in waybar from left to right:

| Icon | Module | Description |
|------|--------|-------------|
| 🎙️ Mic | custom/hyprwhspr | Voice typing status (hover shows Super+` shortcut) |
| 📋 Clipboard | custom/clipboard | Clipboard health status |
| ⌨️ DV | hyprland/language | Keyboard layout (US/DV) |
| 🔷 Tray | tray | System tray icons |
| 󰂯 Bluetooth | bluetooth | Bluetooth status |
| 󰤨 WiFi | network | Network connection |
| 🔊 Volume | pulseaudio | Audio volume (speaker icon) |
| 󰍛 CPU | cpu | CPU usage |
| 🔋 Battery | battery | Battery status (laptop only) |

---

## Waybar Icons Not Displaying

### Problem
Custom waybar modules (hyprwhspr, clipboard) and built-in modules (pulseaudio) sometimes don't display icons after config changes or system updates.

### Symptoms
- Icons appear as invisible/blank in waybar
- Module is in config but nothing shows in the bar
- Commands work fine when run manually (e.g., `hyprwhspr-tray status` outputs valid JSON)

### Root Cause Analysis (2026-01-10)
After extensive debugging comparing desktop (broken) vs laptop (working):

1. **Font name matters**: The font `'JetBrainsMono Nerd Font'` doesn't exist - must use `'JetBrainsMono Nerd Font Mono'` for Nerd Font icons to render
2. **Waybar restart required**: After config/CSS changes, waybar needs full restart (`pkill waybar && hyprctl dispatch exec waybar`)
3. **Pulseaudio icon**: Still investigating - may be related to bluetooth audio device active vs speaker

### Solution (2026-01-10)
Three changes were required to fix all icons:

1. **Font**: Use `'JetBrainsMono Nerd Font Mono'` (not `'JetBrainsMono Nerd Font'`)
2. **Pulseaudio icons**: Use Font Awesome codes `["\uf026", "\uf027", "\uf028"]` instead of Nerd Font Private Use Area icons
3. **hyprwhspr exec path**: Use full system path `/usr/lib/hyprwhspr/config/hyprland/hyprwhspr-tray.sh` instead of wrapper

### Current Status (RESOLVED)
- Voice typing (hyprwhspr) icon: WORKING
- Clipboard icon: WORKING
- Keyboard layout (DV): WORKING
- Bluetooth icon: WORKING
- WiFi icon: WORKING
- CPU icon: WORKING
- Pulseaudio/Volume icon: WORKING

### Debugging Commands
```bash
# Check if module command works
hyprwhspr-tray status
system-health clipboard

# Check font availability
fc-list | grep -i "JetBrainsMono Nerd Font Mono"

# Restart waybar
pkill waybar && hyprctl dispatch exec waybar

# Check waybar logs
journalctl --user -u waybar -n 50
```

### Notes
- The laptop uses `'JetBrainsMono Nerd Font Mono'` in style.css
- The icon bytes ARE being output (verified with `od -c`) but may not render with wrong font
- Waybar version: 0.14.0
- hyprwhspr versions differ: desktop 1.15.1-1, laptop 1.12.0-2

---

## BLE HID Device Pairing (Bluetooth Mice/Keyboards)

### Problem (2026-01-24)
BLE (Bluetooth Low Energy) HID devices like the Toad II Plus mouse fail to pair with `org.bluez.Error.AuthenticationFailed`.

### Symptoms
- Device connects briefly then disconnects
- `bluetoothctl pair` fails with AuthenticationFailed
- System logs show: `No agent available for request type 2`
- `device_confirm_passkey: Operation not permitted`

### Root Cause
1. **Missing package**: `bluez-hid2hci` needed for BLE HID mode switching
2. **Agent persistence**: `bluetoothctl` agent exits before pairing completes when run non-interactively

### Solution

**1. Ensure package is installed:**
```bash
sudo pacman -S --noconfirm bluez-hid2hci
```

**2. Use script-based pairing with persistent agent:**
```bash
{
  echo "agent NoInputNoOutput"
  sleep 0.5
  echo "default-agent"
  sleep 0.5
  echo "pair <MAC_ADDRESS>"
  sleep 12
  echo "quit"
} | bluetoothctl
```

The key is keeping the agent alive during the entire pairing process. The `NoInputNoOutput` agent type enables "just works" pairing for BLE devices.

### Why This Works
- `NoInputNoOutput` agent handles BLE pairing without passkey prompts
- Sleep delays ensure agent is registered before pairing starts
- 12-second wait gives enough time for BLE negotiation

### Verified Working
- Device: Toad II Plus (BLE mouse)
- Adapter: TP-Link UB500
- Date: 2026-01-24

---

## Waybar Bluetooth Icon Missing (Default State)

### Problem (2026-01-24)
Bluetooth icon only shows when a device is connected, not when Bluetooth is powered on but idle.

### Root Cause
The `"format"` field in waybar config was empty string `""` instead of an icon.

### Solution
In `~/.config/waybar/config.jsonc`:
```json
"bluetooth": {
  "format": "󰂯",           // <- Was "" (empty)
  "format-connected": "󰂱",
  "format-disabled": "󰂲",
  ...
}
```

### Format States
| State | Format Key | Icon |
|-------|-----------|------|
| Powered, no connections | `format` | 󰂯 |
| Device connected | `format-connected` | 󰂱 |
| Bluetooth disabled | `format-disabled` | 󰂲 |
| No controller | `format-no-controller` | (empty) |

---

## swaybg Killed by Desktop Manager Conflicts (pcmanfm-qt)

### Problem (2026-02-07)
After a Claude Code agent attempted to add desktop icons via `pcmanfm-qt --desktop`, the wallpaper disappeared. The agent reverted pcmanfm-qt changes but swaybg was left not running, leaving a black/empty desktop background.

### Root Cause
Omarchy uses `swaybg` for wallpaper display. When `pcmanfm-qt --desktop` was launched as a desktop manager, it conflicted with swaybg's role. The cleanup process killed swaybg but did not restart it. The wallpaper cycling shortcut (`Super+Ctrl+Space`) also failed because it works by killing and restarting swaybg — if swaybg isn't running, there's nothing to kill and the restart may fail silently.

### Symptoms
- Black/empty desktop background (no wallpaper)
- `pgrep -a swaybg` returns nothing
- `Super+Ctrl+Space` (wallpaper cycle) doesn't work
- `Super+Ctrl+Shift+Space` (theme change) works but wallpaper still missing after switching
- Background symlink `~/.config/omarchy/current/background` is valid and points to correct image

### Recovery
```bash
# Restart swaybg manually
hyprctl dispatch exec "uwsm-app -- swaybg -i ~/.config/omarchy/current/background -m fill"

# Verify
pgrep -a swaybg
```

### Additional Root Cause: wallpaper-rotate timer (2026-02-08)
Even after manually restarting swaybg, it disappeared again ~4 minutes later. The `wallpaper-rotate.timer` (fires every 30 min + 1 min after boot) was launching bare `swaybg` instead of using `uwsm-app`, so the process didn't persist under Omarchy's uwsm session manager. The systemd service's `KillMode=control-group` also killed swaybg when the oneshot service exited.

**Fix (commit 005e438):**
- `wallpaper-rotate` script: `setsid uwsm-app -- swaybg` (matches `omarchy-theme-bg-next` pattern)
- `wallpaper-rotate.service`: Added `KillMode=none` so swaybg survives oneshot exit

### Prevention
- Do NOT use `pcmanfm-qt --desktop` or any file manager's desktop mode on Omarchy
- Omarchy's wallpaper system is swaybg-based — any other desktop wallpaper manager will conflict
- The wallpaper cycling script is `omarchy-theme-bg-next`
- Custom scripts launching swaybg MUST use `setsid uwsm-app -- swaybg` (not bare `swaybg`)
- If swaybg dies for any reason, the recovery command above restores it

### How Omarchy Wallpaper Works
1. Themes live in `~/.config/omarchy/themes/<theme-name>/backgrounds/`
2. Current background is symlinked: `~/.config/omarchy/current/background` → theme wallpaper
3. `swaybg -i ~/.config/omarchy/current/background -m fill` displays it
4. `Super+Ctrl+Space` runs `omarchy-theme-bg-next` which kills swaybg and restarts with next wallpaper
5. `Super+Ctrl+Shift+Space` opens theme picker which changes the entire theme (including wallpaper)

---

## Programs Folder Parity

The ~/Programs folder should be kept in parity between desktop and laptop machines.

Key projects that should exist on both:
- autocomplete-plugin (Neovim AI autocomplete)
- local-bootstrapping
- omarchy-voice-typing
- personal-website

When adding new projects, ensure they're cloned/copied to both machines.

---

## Bluetooth Earbuds Stuck in HFP (Call Quality) After Voice Typing

Earbuds sound like a phone call and reconnecting doesn't help. A client (leaked
hyprwhspr capture stream, or wiremix) is holding the BT mic open, which pins
WirePlumber to the HFP profile. Run `scripts/bt-audio-fix.sh`.

**Dedicated document:** [`docs/issues/bt-earbuds-stuck-in-hfp-after-voice-typing.md`](issues/bt-earbuds-stuck-in-hfp-after-voice-typing.md)
