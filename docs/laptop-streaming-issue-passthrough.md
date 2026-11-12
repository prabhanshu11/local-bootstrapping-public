# Issue: Hyprland Keyboard Passthrough Not Working in Moonlight

## Problem

When Moonlight was running and streaming the desktop, keyboard shortcuts were being intercepted by the **laptop's Hyprland** instead of passing through to the **remote desktop**.

**Symptoms:**
- `Super+Space` opened laptop's rofi menu, not remote menu
- `Super+1/2/3/4` switched laptop workspaces, not remote workspaces
- `Super+Arrow` changed laptop window focus, not remote focus
- `Super+\`` (backtick) triggered laptop voice typing, not remote

**Expected behavior:** ALL keys (except `Super+Escape`) should pass to remote desktop when Moonlight is active and in streaming submap.

## Root Cause

**Hyprland submaps don't automatically pass through unbound keys**

Our configuration used this submap:
```bash
submap = streaming

bindd = SUPER, Escape, Exit Streaming Mode, ...
bindd = SUPER SHIFT CTRL, S, Disconnect and Exit, ...

# Comment said: "Catch-all: pass everything else to Moonlight"
# Comment said: "(This is implicit - Hyprland passes unbound keys through)"

submap = reset
```

**The problem:** The comment was incorrect. Hyprland does **NOT** implicitly pass unbound keys through in submaps. Instead, unbound keys are **silently ignored**.

## How Hyprland Submaps Actually Work

From [Hyprland documentation](https://wiki.hypr.land/Configuring/Binds/):

> Submaps (also called "modes") allow you to activate separate keybind sets.
> **Unbound keys in a submap are ignored, not passed through.**

To enable passthrough, you must use:
1. **`bind = , catchall, pass`** - Explicitly passes ALL unbound keys to the underlying application
2. **`bindn`** with `n` flag - Makes a binding "non-consuming" (passes key AND executes binding)

## Solution

**Add explicit catchall passthrough**

Updated streaming submap to:
```bash
submap = streaming

# Exit bindings (only these work locally)
bindd = SUPER, Escape, Exit Streaming Mode, exec, notify-send "Streaming" "Returned to laptop control" && hyprctl dispatch submap reset
bindd = SUPER SHIFT CTRL, S, Disconnect and Exit, exec, moonlight-toggle kill && hyprctl dispatch submap reset

# CRITICAL: Explicit passthrough for all other keys
# This ensures Super+1, Super+Space, etc. reach the remote desktop
bind = , catchall, pass

submap = reset
```

## Additional Issues Discovered

### 1. No Way to Verify Submap is Active

Hyprland 0.52.2 doesn't have a built-in command to check which submap is active. This was a [feature request](https://github.com/hyprwm/Hyprland/issues/2641) but was closed as "not planned".

**Workaround for debugging:**
```bash
# Monitor Hyprland events:
socat - UNIX-CONNECT:/run/user/$(id -u)/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock | grep -i submap
```

### 2. Window Class Detection

Moonlight window rules target `class:^(com\.moonlight_stream\.Moonlight)$`, but the actual class name might differ.

**Verify after launch:**
```bash
hyprctl clients | grep -i moon
```

If the class is different (e.g., just `moonlight`), update windowrulev2 patterns.

### 3. Window Rules Only Apply When Fullscreen

The `windowrulev2` rules with `fullscreen:1` condition only apply when Moonlight is already fullscreen. There's a potential race condition between:
1. Moonlight launching
2. Entering streaming submap
3. Moonlight going fullscreen

## Testing

After implementing the fix:

1. **Launch Moonlight:**
   ```bash
   Super+Shift+S
   ```

2. **Verify submap is active** (should auto-enter after launch)

3. **Test passthrough:**
   - Press `Super+1` → should switch remote workspace 1
   - Press `Super+Space` → should open remote menu
   - Press `Super+Arrow` → should change remote window focus

4. **Exit passthrough:**
   ```bash
   Super+Escape
   ```
   - Should show notification "Returned to laptop control"
   - Keys should now act on laptop again

## Files Modified

- `dotfiles/hypr/bindings-streaming.conf` - Added `bind = , catchall, pass` to streaming submap

## Known Limitations

1. **No automatic exit:** If Moonlight closes unexpectedly, submap doesn't auto-reset. Must press `Super+Escape` manually.

2. **No visual indicator:** Can't easily see if submap is active. Consider adding waybar module or notification.

3. **Fullscreen-only window rules:** `stayfocused` and other rules only apply when `fullscreen:1`. Windowed mode may have focus glitches.

## References

- [Hyprland Binds Documentation](https://wiki.hypr.land/Configuring/Binds/)
- [Hyprland Issue #2641 - Show active submap](https://github.com/hyprwm/Hyprland/issues/2641)
- [Hyprland Issue #3149 - Submap suggestions](https://github.com/hyprwm/Hyprland/issues/3149)
- [Moonlight Qt Issue #1201 - Hyprland compatibility](https://github.com/moonlight-stream/moonlight-qt/issues/1201)

## Discovery: Alt+Shift Escapes Capture (2026-01-11)

**Key finding:** When using `--capture-system-keys always`, the **Alt+Shift** combination triggers keyboard layout change on **BOTH** the laptop AND the remote desktop simultaneously.

This is significant because:
1. Moonlight's keyboard-shortcuts-inhibit protocol captures ALL keys
2. Yet Alt+Shift somehow registers on both systems
3. This suggests modifier-only combinations may bypass the capture

**Possible explanations:**
- Alt+Shift is handled at XKB/input-method level, not keybind level
- Hyprland processes layout switch before passing to Moonlight
- Wayland protocol handles layout separately from key events

**Potential exit mechanism:**
- Use Alt+Shift+<key> combination since Alt+Shift passes through
- Or trigger exit on layout change event
- Needs further investigation

## Current Exit Workaround

Until a proper exit mechanism is found:
1. SSH to desktop: `ssh desktop`
2. Restart Sunshine: `systemctl --user restart sunshine`

Or physically access the desktop to close Moonlight.

## Fullscreen Mode Issue

`--display-mode fullscreen` doesn't work reliably on Wayland:
- Window starts semi-fullscreen (top bar visible)
- Then closes and reopens in windowed mode
- Use `Super+F` (Hyprland fullscreen toggle) after window opens

## Date

2026-01-11
