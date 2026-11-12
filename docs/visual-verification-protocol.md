# Visual Verification Protocol

How to visually verify waybar widget states using AI vision models.

## Agent Requirement: Manual Before/After Screenshots

This applies whenever an AI agent works on the topbar (waybar) or any of the
desktop controls built around it (`screen-flip`, `restart-waybar`, the
`.desktop` icons in `~/Desktop` / `dotfiles/desktop-entries/`) — see
`CLAUDE.md` → "Screenshot Verification — MANDATORY".

Independent of the automated pytest/vision-API suite below, the agent itself
must:

1. Capture a **before** screenshot (`grim`, cropped — use the
   `better-screenshot` skill) showing the problem state.
2. Apply the fix.
3. Capture an **after** screenshot of the same region and visually confirm
   the fix (bar/icon actually renders correctly) before reporting success.

A restarted process or a `0` exit code is not sufficient evidence — the bug
report is about what's on screen, so the verification must look at the screen.

## Quick Start

```bash
# Run all visual tests
pytest tests/visual/ -v -m visual

# Run only the battery/power-profile test
pytest tests/visual/test_waybar_icons.py::test_battery_charging_indicator -v
```

## How It Works

1. `grim` captures a cropped screenshot of the waybar area
2. The image is sent to Gemini Flash via OpenRouter's vision API
3. The model describes what it sees (icons, text, colors)
4. Assertions compare the model's description against expected state (AC power, profile)

## Model Choice

**google/gemini-2.5-flash** via OpenRouter

| Factor | Details |
|--------|---------|
| Speed | ~2-3 seconds per request |
| Cost | ~$0.001 per screenshot analysis |
| Vision quality | Correctly identifies small icons, text, and colors in 30px-tall waybar crops |
| Availability | Via OpenRouter (no separate Google API key needed) |

Previously used `qwen/qwen2.5-vl-72b-instruct`. Switched to Gemini Flash for better speed/cost.

## API Key

Stored in `pass`:

```bash
pass show api/openrouter
```

Tests skip automatically if the key is not available.

## Reference Screenshots

Location: `reference-screenshots/`

| File | Description |
|------|-------------|
| `waybar-mic-on.png` | Mic recording active (red waveform) |
| `waybar-mic-off.png` | Mic idle (grey icon) |
| `waybar-ac-plugged.png` | AC connected — green battery, PRF in red |
| `waybar-ac-unplugged.png` | On battery — default battery, BAL/SAV in blue/green |
| `reference-meta.json` | Metadata for all references (expected colors, CSS classes) |

Reference screenshots are auto-saved the first time a test runs for a state that has no reference yet.

## Verification Log

`reference-screenshots/verification-log.jsonl` (gitignored) stores every verification run:

```json
{
  "timestamp": "2026-02-13T14:15:00+00:00",
  "screenshot": "battery-power-profile-crop.png",
  "expected": "ac=off, profile=SAV",
  "model": "google/gemini-2.5-flash",
  "response": { "battery_icon_color": "white", "power_profile_text": "SAV", ... },
  "match": true
}
```

## Adding New States

To add visual verification for a new waybar module:

1. **Add to EXPECTED_ICONS** in `test_waybar_icons.py`
2. **Add to required_modules** in `test_waybar_config_has_all_modules()`
3. **Create a new test function** if the module has dynamic states (like battery charging)
4. **Update reference-meta.json** with expected colors and CSS classes
5. **Run `pytest -v`** — reference screenshots are auto-saved on first run

## Color Map (from style.css)

| CSS Selector | Color | Hex |
|-------------|-------|-----|
| `#custom-power-profile.performance` | Red | `#f38ba8` |
| `#custom-power-profile.balanced` | Blue | `#89b4fa` |
| `#custom-power-profile.power-saver` | Green | `#a6e3a1` |
| `#battery.charging` | Green | `#a6e3a1` |
| `#battery.plugged` | Green | `#a6e3a1` |

## Multi-Monitor Note

The test handles multi-monitor setups by reading the focused monitor's position from `hyprctl monitors -j` and adjusting grim coordinates accordingly. The crop area is always relative to the monitor's origin, not the absolute screen position.
