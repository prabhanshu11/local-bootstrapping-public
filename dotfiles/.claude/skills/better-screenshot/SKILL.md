---
name: better-screenshot
description: Optimize screenshot capture for token efficiency. ALWAYS apply before running grim, taking screenshots, verifying UI state, checking icons, or debugging visual elements. Calculates minimal crop regions for focused analysis.
allowed-tools:
  - Bash
  - Read
---

# Better Screenshot

**BEFORE taking any screenshot, apply this decision process.**

## Decision Flow

```
1. What am I trying to verify?
   └─→ Identify the specific UI element (icon, button, notification, etc.)

2. How big is the target vs the screen?
   └─→ If target < 5% of screen area → MUST crop
   └─→ If target is a specific region → crop to that region + margin

3. Calculate crop region
   └─→ Use formula: capture_size = element_size × 10
   └─→ Position from nearest corner/edge

4. Only use full screenshot if:
   └─→ Verifying window layout/tiling
   └─→ Multiple windows relationship
   └─→ User explicitly requested full screen
```

## Why This Matters

- **Token efficiency**: A 1920×1080 screenshot uses ~2M pixels. A 140×140 crop uses ~20K pixels (100× smaller)
- **Model accuracy**: Large images with tiny targets confuse the model - it may miss details or hallucinate
- **Faster analysis**: Focused regions give clearer, more confident visual understanding

## Core Principle

**Take the smallest possible screenshot** that captures the relevant information. Full-screen captures waste tokens and make visual analysis harder.

## Wayland Screenshot Commands

Use `grim` for screenshots on Wayland/Hyprland:

```bash
# Full screen (avoid when possible)
grim screenshot.png

# Cropped region - PREFERRED
grim -g "X,Y WxH" screenshot.png

# Interactive selection
grim -g "$(slurp)" screenshot.png
```

## Size Calculation Formula

For status bar icons and small UI elements:

```
Capture area = (element_size_px × 10) × (element_size_px × 10)
```

**Examples:**
| Element Size | Capture Area | Command Example |
|--------------|--------------|-----------------|
| 14px icons | 140×140 px | `grim -g "1780,0 140x140" waybar.png` |
| 24px icons | 240×240 px | `grim -g "1680,0 240x240" tray.png` |
| 32px buttons | 320×320 px | `grim -g "100,100 320x320" button.png` |

## Common Capture Regions

### Waybar/Status Bar (Top-Right)
```bash
# For 1920x1080 display, capturing top-right corner
grim -g "1780,0 140x140" /tmp/waybar-icons.png

# For 2560x1440 display
grim -g "2420,0 140x140" /tmp/waybar-icons.png
```

### System Tray
```bash
# Calculate from right edge: screen_width - capture_width
# 1920 - 200 = 1720
grim -g "1720,0 200x50" /tmp/tray.png
```

### Specific Window Region
```bash
# Use slurp for interactive selection
grim -g "$(slurp)" /tmp/region.png
```

## When to Use Full Screenshots

Only capture full screen when:
- Debugging window layout/tiling issues
- Showing relationship between multiple windows
- User explicitly requests full screenshot
- Context of entire desktop is necessary

## Best Practices

1. **Calculate position from relevant corner**
   - Top-right elements: Start from `(screen_width - capture_width, 0)`
   - Bottom-left elements: Start from `(0, screen_height - capture_height)`

2. **Add margin around target element**
   - The 10× multiplier provides context without excess

3. **Use consistent naming**
   - `/tmp/` for temporary debugging screenshots
   - Descriptive names: `waybar-icons.png`, `notification.png`

4. **Clean up after debugging**
   ```bash
   rm /tmp/*.png
   ```

## Integration with Claude Code

When Claude needs to verify UI changes or debug visual issues:

1. Calculate the minimal region needed
2. Use `grim -g` with precise coordinates
3. Read the screenshot with the Read tool
4. Provide focused analysis of the captured region

## Quick Reference

```bash
# Waybar icons (14px, top-right of 1920px display)
grim -g "1780,0 140x140" /tmp/check.png

# Notification popup (typically 300px wide, top-right)
grim -g "1620,50 300x100" /tmp/notification.png

# Application window corner
grim -g "$(slurp)" /tmp/region.png
```
