# Issue: Moonlight Streaming Shortcuts Not Working

## Problem

Laptop was configured with `Super+Alt+7/8/9` shortcuts to launch Moonlight, but these shortcuts didn't trigger even though they appeared in `hyprctl binds`.

**Symptoms:**
- `Super+Alt+7` (Stream Desktop) - did nothing
- `Super+Alt+8` (Stream Fullscreen) - did nothing
- `Super+Alt+6` (Desktop Status) - worked ✓
- Manual `moonlight-toggle` command worked fine

## Root Cause

**Omarchy group window switching bindings conflict**

Omarchy's default bindings in `/usr/local/share/omarchy/default/hypr/bindings/tiling-v2.conf` define:
```bash
bindd = SUPER ALT, code:10, Switch to group window 1, changegroupactive, 1
bindd = SUPER ALT, code:11, Switch to group window 2, changegroupactive, 2
bindd = SUPER ALT, code:12, Switch to group window 3, changegroupactive, 3
bindd = SUPER ALT, code:13, Switch to group window 4, changegroupactive, 4
bindd = SUPER ALT, code:14, Switch to group window 5, changegroupactive, 5
```

**Key code mapping:**
```
code:10 = 1    code:11 = 2    code:12 = 3    code:13 = 4    code:14 = 5
code:15 = 6    code:16 = 7    code:17 = 8    code:18 = 9    code:19 = 0
```

**The issue:** Omarchy only defines Super+Alt for codes 10-14 (keys 1-5). Keys 6/7/8/9 (codes 15-18) are **unbound** in Omarchy defaults, which creates inconsistent behavior:
- Super+Alt+1/2/3 trigger group switching (bound by Omarchy)
- Super+Alt+6/7/8/9 should be available but behave unpredictably

## Why Super+Alt+6 Appeared to Work

The Super+Alt+6 shortcut that appeared to work was actually **exhibiting undefined behavior** since code:15 isn't bound in Omarchy. It seemed to work inconsistently because:
1. It wasn't being captured by Omarchy group switching (codes 10-14 only)
2. But it also wasn't being reliably processed by Hyprland bindings

## Solution

**Use the desktop's approach:** `Super+Shift+S/F`

Changed shortcuts to match desktop configuration:
- `Super+Shift+S` → Stream Desktop (no conflicts)
- `Super+Shift+F` → Stream Fullscreen (no conflicts)
- `Super+Shift+Ctrl+S` → Disconnect
- `Super+Shift+D` → Desktop Status

**Why this works:**
1. No Omarchy conflicts with Super+Shift+letter combos
2. Consistent with desktop for easier mental model
3. Super+Shift is already used for workspace management in Omarchy

## Verification

After implementing the fix:
```bash
hyprctl reload
hyprctl binds | grep -i "stream"
```

Test shortcuts:
```bash
# Should launch Moonlight and enter passthrough mode
Super+Shift+S

# Should launch Moonlight fullscreen
Super+Shift+F

# Should disconnect (works both in normal mode and streaming submap)
Super+Shift+Ctrl+S
```

## Files Modified

- `dotfiles/hypr/bindings-streaming.conf` - Changed from Super+Alt+7/8/9 to Super+Shift+S/F

## Related Issues

- See `laptop-streaming-issue-passthrough.md` for keyboard passthrough problems

## Date

2026-01-10
