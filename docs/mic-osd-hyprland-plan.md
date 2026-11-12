# Plan: Fix MicOSD on Laptop + Merge Deepgram Branch

## Context

MicOSD waveform overlay segfaults on the laptop (ThinkPad T14 Gen 1, hybrid Intel+NVIDIA GPU) when spawned from the hyprwhspr systemd service. Root cause: `LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so` triggers a native segfault before Python even starts — empty daemon log, every approach (full env, minimal env, ctypes.CDLL) fails. Works on desktop.

**Novel fix**: Replace gtk4-layer-shell entirely with **Hyprland window rules** for positioning. No LD_PRELOAD needed. The OSD becomes a regular GTK4 window that Hyprland positions, pins, and makes non-focusable natively.

Also: the OSD must be hidden BEFORE text injection — the layer surface/window interferes with ydotool keyboard simulation (discovered during debugging).

Second task: merge `feature/local-whisper` → `master` in omarchy-voice-typing.

---

## Step 1: Create Hyprland window rules

**New file**: `~/Programs/local-bootstrapping/dotfiles/hypr/windowrules-mic-osd.conf`

```conf
# MicOSD overlay positioning (replaces gtk4-layer-shell)
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

Position math (1920x1080): X = (1920-400)/2 = 760, Y = 1080-68-130 = 882

**Source it** by adding to `~/.config/hypr/bindings.conf` (where voice/streaming configs are sourced):
```
source = ~/.config/hypr/windowrules-mic-osd.conf
```

Symlink via install.sh (existing pattern in local-bootstrapping).

## Step 2: Set Wayland app_id in window.py

**File**: `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/window.py`

Add after imports (line ~22), before class definition:
```python
GLib.set_prgname("mic-osd")
```

This sets the Wayland `app_id` that Hyprland matches with `class:^(mic-osd)$`. Must be called before any window creation.

## Step 3: Clean up runner.py

**File**: `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/runner.py`

- Remove `ctypes.CDLL` and `import ctypes` from embedded code string
- Keep `env = os.environ.copy()` + `env.pop('LD_PRELOAD', None)`
- Keep log file redirect (essential for debugging)
- Keep try/except wrapper in embedded code

## Step 4: Keep hide-before-type fix in main.py

**File**: `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/main.py`

Already done: `_patched_stop_recording` hides OSD before calling `_original_stop_recording` (which triggers ydotool text injection). No further changes needed.

## Step 5: Deploy and test

```bash
# Symlink new config
ln -sf ~/Programs/local-bootstrapping/dotfiles/hypr/windowrules-mic-osd.conf \
       ~/.config/hypr/windowrules-mic-osd.conf

# Copy patched files to installed location
cp ~/Programs/local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/runner.py \
   ~/.local/lib/hyprwhspr-patch/mic_osd/runner.py
cp ~/Programs/local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/window.py \
   ~/.local/lib/hyprwhspr-patch/mic_osd/window.py

# Reload Hyprland config + restart hyprwhspr
hyprctl reload
kill $(cat ~/.config/hyprwhspr/mic_osd.pid 2>/dev/null) 2>/dev/null
rm -f ~/.config/hyprwhspr/mic_osd.pid
systemctl --user restart hyprwhspr
```

## Step 6: Merge Deepgram streaming branch

```bash
cd ~/Programs/omarchy-voice-typing
git add gateway/internal/deepgram/streaming.go \
        gateway/internal/handlers/realtime.go \
        gateway/cmd/server/main.go \
        gateway/internal/handlers/handlers.go \
        gateway/go.mod gateway/go.sum \
        hyprwhspr-configs/realtime-gateway.json \
        README.md progress.md
git commit -m "Add Deepgram Nova-2 streaming transcription ..."
git checkout master
git merge feature/local-whisper
```

---

## Files to modify

| File | Action |
|------|--------|
| `local-bootstrapping/dotfiles/hypr/windowrules-mic-osd.conf` | **NEW** — Hyprland window rules |
| `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/window.py` | Add `GLib.set_prgname("mic-osd")` |
| `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/runner.py` | Remove ctypes/LD_PRELOAD, keep log redirect |
| `~/.config/hypr/bindings.conf` | Add `source` line for windowrules |

## Verification

1. `Super+backtick` → OSD appears at bottom center (not center of screen)
2. Speak → waveform bars respond
3. `Super+backtick` again → OSD hides, transcript is typed into active window
4. `hyprctl clients | grep mic-osd` → shows window with correct rules applied
5. `journalctl --user -u hyprwhspr` → no "daemon is dead" messages
6. `cat ~/Programs/omarchy-voice-typing/logs/mic-osd-daemon.log` → no crash errors
7. Repeat 2-3 times for stability
