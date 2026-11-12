---
name: smarter-ui-navigator
description: Fix Hyprland window management issues. Use when user reports window resizing problems, tiling issues, wrong window getting resized, split direction problems, dwindle layout confusion, or needs help with keyboard resize shortcuts.
allowed-tools:
  - Bash
---

# Smarter UI Navigator

Guidance for handling Hyprland window management issues, particularly tiled window resize problems.

## Problem: Wrong Window Resizes in Tiled Layout

When using `Super+right-click` to resize a window in Hyprland's dwindle layout, the resize may affect an unexpected window or edge due to the **layout tree structure**.

**Common Scenario:**
```
┌──────────┬──────────┐
│    A     │    B     │
├──────────┴──────────┤
│         C           │  ← "the window at the bottom"
└─────────────────────┘
```

When attempting to resize window A vertically:
- **Expected:** Horizontal split between (A,B) and C moves
- **Actual:** Vertical split between A|B moves instead (or vice versa)

**Root Cause:** Hyprland's dwindle layout uses a binary tree structure. Each resize operation affects the nearest split in the tree, which may not be the visually obvious one.

## Solution: Toggle Split Direction

**Use `Super + J` (`togglesplit`) on the problematic window:**

1. Focus the window that's behaving unexpectedly (e.g., window C)
2. Press `Super + J` to toggle its split orientation
3. The resize operation will now affect the correct boundary

**Why this works:** `togglesplit` changes how that node in the layout tree is oriented, redirecting resize operations to the intended split.

## Keyboard Resize Shortcuts (More Precise)

For predictable resizing, use directional keyboard shortcuts instead of mouse:

| Shortcut | Action |
|----------|--------|
| `Super + -` | Expand window left (horizontal resize) |
| `Super + =` | Shrink window left (horizontal resize) |
| `Super + Shift + -` | Shrink window up (vertical resize) |
| `Super + Shift + =` | Expand window down (vertical resize) |

## Other Useful Window Shortcuts

| Shortcut | Action |
|----------|--------|
| `Super + F` | Full screen |
| `Super + Ctrl + F` | Tiled full screen |
| `Super + Alt + F` | Maximize (fills workspace with gaps) |
| `Super + T` | Toggle floating/tiling |
| `Super + J` | Toggle split direction |

## When to Apply This Skill

When a user reports unexpected resize behavior:

1. Ask about their current window layout
2. Explain the dwindle tree structure
3. Suggest `Super + J` on the problematic window
4. Recommend keyboard shortcuts for predictable resizing

## Quick Reference

**Window Resize Issues:**
- `Super + J` toggles split direction (fixes most issues)
- Use keyboard resize shortcuts for precision
- The issue stems from dwindle layout's binary tree structure
