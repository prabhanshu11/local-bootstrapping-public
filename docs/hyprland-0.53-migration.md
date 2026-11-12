# Hyprland 0.53.3 Migration Guide

## Context

**Date:** 2026-02-17
**Hyprland version:** 0.53.3 (released Jan 2026)
**Triggered by:** Desktop reboot showing config errors

## Breaking Changes in Hyprland 0.53.3

### 1. windowrulev2 Deprecated

**What changed:**
- `windowrulev2` syntax is now deprecated
- Must use `windowrule` instead
- Syntax conversion: `windowrulev2 = action, class:pattern` → `windowrule = action, pattern`

**Why it matters:**
- Config errors on every Hyprland reload
- May cause window rules to stop working
- Red error messages clutter the screen

### 2. Stricter Regex Validation

**What changed:**
- Character classes now validated strictly
- Pipe `|` operator not allowed inside `[...]` brackets
- Alternation must use `(option1|option2)` not `[option1|option2]`

**Common mistakes:**
- `[p|P]` → should be `[pP]` (character class) or `(p|P)` (alternation)
- `[F|f]` → should be `[Ff]`
- `[open|save]` → should be `(open|save)`

### 3. Removed Config Options

**Options removed:**
- `new_window_takes_over_fullscreen` in `misc{}` block

## Files Affected

### Local-Bootstrapping (Synced Across Both Machines)

#### bindings-streaming.conf
**Location:** `dotfiles/hypr/bindings-streaming.conf`

**Errors:**
```
windowrulev2 is deprecated. Correct syntax can be found on the wiki.
```

**Before:**
```conf
windowrulev2 = noborder, class:^(com\.moonlight_stream\.Moonlight)$, fullscreen:1
windowrulev2 = noshadow, class:^(com\.moonlight_stream\.Moonlight)$, fullscreen:1
windowrulev2 = noanim, class:^(com\.moonlight_stream\.Moonlight)$, fullscreen:1
windowrulev2 = stayfocused, class:^(com\.moonlight_stream\.Moonlight)$, fullscreen:1
windowrulev2 = idleinhibit always, class:^(com\.moonlight_stream\.Moonlight)$
windowrulev2 = nofocus, class:^(?!com\.moonlight_stream\.Moonlight).*$, floating:1, fullscreenstate:* 2
```

**After:**
```conf
# NOTE: windowrulev2 deprecated in Hyprland 0.53.3
# Converted to windowrule (fullscreen conditions removed - not supported in v1)
windowrule = noborder, ^(com\.moonlight_stream\.Moonlight)$
windowrule = noshadow, ^(com\.moonlight_stream\.Moonlight)$
windowrule = noanim, ^(com\.moonlight_stream\.Moonlight)$
windowrule = idleinhibit always, ^(com\.moonlight_stream\.Moonlight)$
# Note: stayfocused and nofocus with complex conditions may need alternative approach
```

**Tradeoffs:**
- Lost fullscreen-specific conditions (not supported in windowrule v1)
- `stayfocused` and complex `nofocus` rules may need rework

#### windowrules-mic-osd.conf
**Location:** `dotfiles/hypr/windowrules-mic-osd.conf`

**Errors:**
```
windowrulev2 is deprecated.
```

**Before:**
```conf
windowrulev2 = float, class:^(mic-osd)$
windowrulev2 = pin, class:^(mic-osd)$
windowrulev2 = nofocus, class:^(mic-osd)$
windowrulev2 = noborder, class:^(mic-osd)$
windowrulev2 = noshadow, class:^(mic-osd)$
windowrulev2 = noanim, class:^(mic-osd)$
windowrulev2 = opacity 1.0 override, class:^(mic-osd)$
windowrulev2 = size 400 68, class:^(mic-osd)$
windowrulev2 = move 760 882, class:^(mic-osd)$
```

**After:**
```conf
# NOTE: Converted from windowrulev2 (deprecated in Hyprland 0.53.3)
windowrule = float, ^(mic-osd)$
windowrule = pin, ^(mic-osd)$
windowrule = nofocus, ^(mic-osd)$
windowrule = noborder, ^(mic-osd)$
windowrule = noshadow, ^(mic-osd)$
windowrule = noanim, ^(mic-osd)$
windowrule = opacity 1.0 override, ^(mic-osd)$
windowrule = size 400 68, ^(mic-osd)$
windowrule = move 760 882, ^(mic-osd)$
```

**Status:** ✅ Fixed (commit f7c3a41)

### Omarchy Defaults (Machine-Specific)

#### looknfeel.conf
**Location:** `~/.local/share/omarchy/default/hypr/looknfeel.conf`

**Error:**
```
config option new_window_takes_over_fullscreen does not exist
```

**Before (line 126):**
```conf
misc {
    disable_hyprland_logo = true
    disable_splash_rendering  = true
    focus_on_activate = true
    anr_missed_pings = 3
    new_window_takes_over_fullscreen = 1
}
```

**After:**
```conf
misc {
    disable_hyprland_logo = true
    disable_splash_rendering  = true
    focus_on_activate = true
    anr_missed_pings = 3
    # new_window_takes_over_fullscreen removed in Hyprland 0.53.3
}
```

**Status:** ✅ Fixed on desktop (not in local-bootstrapping - Omarchy default)

#### apps/1password.conf
**Location:** `~/.local/share/omarchy/default/hypr/apps/1password.conf`

**Error:**
```
invalid field {{prefix}}Password8 (from misinterpreted regex [p|P])
```

**Before:**
```conf
windowrule = noscreenshare, class:^(1[p|P]assword)$
windowrule = tag +floating-window, class:^(1[p|P]assword)$
```

**After:**
```conf
windowrule = noscreenshare, class:^(1[pP]assword)$
windowrule = tag +floating-window, class:^(1[pP]assword)$
```

**Status:** ✅ Fixed on desktop (not in local-bootstrapping - Omarchy default)

#### apps/system.conf
**Location:** `~/.local/share/omarchy/default/hypr/apps/system.conf`

**Errors:**
```
invalid field [F|f] (regex syntax)
invalid field [C|c] (regex syntax)
invalid field [open|save] (should be alternation, not character class)
```

**Before:**
```conf
windowrule = tag +floating-window, class:(xdg-desktop-portal-gtk|sublime_text|DesktopEditors|org.gnome.Nautilus), title:^(Open.*Files?|Open [F|f]older.*|Save.*Files?|Save.*As|Save|All Files|.*wants to [open|save].*|[C|c]hoose.*)
```

**After:**
```conf
windowrule = tag +floating-window, class:(xdg-desktop-portal-gtk|sublime_text|DesktopEditors|org.gnome.Nautilus), title:^(Open.*Files?|Open [Ff]older.*|Save.*Files?|Save.*As|Save|All Files|.*wants to (open|save).*|[Cc]hoose.*)
```

**Changes:**
- `[F|f]` → `[Ff]` (remove pipe from character class)
- `[C|c]` → `[Cc]` (remove pipe from character class)
- `[open|save]` → `(open|save)` (use parentheses for alternation)

**Status:** ✅ Fixed on desktop (not in local-bootstrapping - Omarchy default)

### Final Resolution (2026-02-17)

**Status: ✅ RESOLVED**

Desktop booting cleanly with 0 config errors after:
1. Disabling windowrules-mic-osd.conf entirely (windowrule v1 syntax incompatible)
2. Removing incompatible window rules from bindings-streaming.conf
3. Fixing scrolltouchpad errors in input.conf
4. Desktop reboot verification: Clean boot with no red error text

**Root cause:**
- windowrule v1 syntax fundamentally incompatible with many properties
- Even basic rules like "float" showed "missing a value" errors
- Solution: Disabled problematic rules entirely

**Fixes applied:**
- bindings-streaming.conf: Removed noborder, noshadow, noanim, idleinhibit rules ✓
- windowrules-mic-osd.conf: Disabled entirely (renamed to .disabled) ✓
- input.conf: Commented out scrolltouchpad rules (lines 46-47) ✓
- bindings.conf: Commented out source line for disabled windowrules-mic-osd.conf ✓
- looknfeel.conf: Removed new_window_takes_over_fullscreen ✓
- 1password.conf: Fixed [p|P] → [pP] regex ✓
- system.conf: Fixed [F|f] → [Ff], [C|c] → [Cc], [open|save] → (open|save) ✓

**Verification:**
- Desktop: `hyprctl configerrors` → 0 errors
- Screenshot: `docs/screenshots/desktop-clean-boot-2026-02-17.png`
- Functionality: Moonlight streaming works, voice typing works (OSD visual customizations lost)

## Verification After Fixes

### Quick Test
```bash
# Desktop
ssh desktop "SIG=\$(ls /run/user/1000/hypr/) && HYPRLAND_INSTANCE_SIGNATURE=\$SIG hyprctl reload"
# Should return: ok

# Laptop
hyprctl reload
# Should return: ok
```

### Screenshot Verification
- NO red error text at top of screen
- Waybar displays correctly
- Desktop wallpaper visible

### Functional Tests
1. **Window rules:** Open app, verify opacity/floating behavior
2. **Moonlight:** `Super+Shift+M` launches streaming
3. **Voice typing:** `Super+Caps` activates MicOSD overlay
4. **File dialogs:** Open file dialog, verify floating window rule works

## Migration Checklist

- [x] Document all errors while visible
- [x] Create migration guide (this file)
- [x] Fix local-bootstrapping files (bindings-streaming, windowrules-mic-osd)
- [x] Fix desktop Omarchy defaults (looknfeel, 1password, system, windows)
- [x] Pull updated local-bootstrapping to desktop
- [x] Reload Hyprland on both machines (`hyprctl reload` → ok)
- [x] Identify remaining errors (scrolltouchpad in input.conf, windowrule v1 syntax issues)
- [x] Verify desktop clean after reboot (0 config errors)
- [x] Verify laptop clean (0 config errors)
- [x] Final commit with resolution
- [x] Update blank-desktop-after-login.md with final status

---

# Hyprland 0.54 Migration — Windowrule v3

## Context

**Date:** 2026-04-01
**Hyprland version:** 0.54
**Triggered by:** Hyprland 0.54 introduced "windowrule v3" — a complete syntax overhaul

## Breaking Changes in 0.54

### Windowrule v3 Syntax

The entire windowrule format changed:

**Old (v1/v2):** `windowrule = action, class:pattern`
**New (v3 inline):** `windowrule = effect_name value, match:prop_name pattern`
**New (v3 block):**
```
windowrule {
    name = my-rule
    effect_name = value
    match:prop_name = pattern
}
```

### Effect Name Changes

| Old | New |
|-----|-----|
| `float` (no value) | `float true` |
| `pin` (no value) | `pin true` |
| `tile` (no value) | `tile true` |
| `center` (no value) | `center true` |
| `fullscreen` (no value) | `fullscreen true` |
| `nofocus` | `no_focus true` |
| `noborder` | `border_size 0` |
| `noshadow` | `no_shadow true` |
| `noanim` | `no_anim true` |
| `noscreenshare` | `no_screen_share true` |
| `noinitialfocus` | `no_initial_focus true` |
| `nofollowmouse` | `no_follow_mouse true` |
| `nodim` | `no_dim true` |
| `stayfocused` | `stay_focused true` |
| `keepaspectratio` | `keep_aspect_ratio true` |
| `opaque` | `opaque true` |
| `idleinhibit X` | `idle_inhibit X` |
| `suppressevent X` | `suppress_event X` |
| `scrolltouchpad X` | `scroll_touchpad X` |
| `opacity X Y` | `opacity X Y` (unchanged) |
| `size W H` | `size W H` (unchanged) |
| `move X Y` | `move X Y` (unchanged) |
| `tag +X` | `tag +X` (unchanged) |
| `rounding X` | `rounding X` (unchanged) |

### Matcher Changes

| Old | New |
|-----|-----|
| `, class:pattern` | `, match:class pattern` |
| `, title:pattern` | `, match:title pattern` |
| `, tag:name` | `, match:tag name` |
| `, floating:1` | `, match:float 1` |
| `, pinned:0` | `, match:pin 0` |
| `, xwayland:1` | `, match:xwayland 1` |
| `, fullscreen:0` | `, match:fullscreen 0` |
| `, initialTitle:X` | `, match:initial_title X` |

### Misc Option Change

`new_window_takes_over_fullscreen` → `on_focus_under_fullscreen`

## Solution: Automated Patch Script

Instead of manually editing each file (error-prone, lost on omarchy updates), created
`scripts/fix-hyprland-054-compat.sh` — a sed-based idempotent script that:

1. Converts `new_window_takes_over_fullscreen` → `on_focus_under_fullscreen` in looknfeel.conf
2. Rewrites all windowrule lines in windows.conf and apps/*.conf to v3 syntax
3. Fixes legacy regex issues ([p|P] → [pP], etc.)
4. Verifies with `hyprctl configerrors` at end

**Integration points:**
- `scripts/install.sh` — runs after symlinks (catches fresh installs)
- `scripts/sync-from-master.sh` — runs on every sync (catches omarchy updates)

**Managed dotfiles also updated:**
- `dotfiles/hypr/windowrules-mic-osd.conf` — v3 syntax
- `dotfiles/hypr/input.conf` — scroll_touchpad v3 syntax

## Verification

```bash
# Run patch
bash scripts/fix-hyprland-054-compat.sh

# Reload and check
hyprctl reload
hyprctl configerrors  # Should return empty/no errors
```

---

## Lessons Learned

**For future Hyprland upgrades:**
1. Check changelog for breaking changes BEFORE rebooting
2. Test config with `hyprctl reload` after upgrade
3. Keep backup of working configs (`.bak` files)
4. Document errors immediately while visible
5. Fix in local-bootstrapping first, then sync to machines

**What worked:**
- Documenting BEFORE fixing preserved context
- Screenshots captured exact error messages
- Git history in local-bootstrapping allows rollback
- Systematic approach (one file at a time, test each)

**What didn't work:**
- Trying to fix everything at once led to confusion
- Not checking if apps.conf was commented out
- Assuming windowrule v1 syntax would be simple drop-in replacement
