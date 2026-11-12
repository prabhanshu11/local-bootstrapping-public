# MicOSD Lessons Learned

> Waveform overlay for hyprwhspr voice typing. Daemon-based (SIGUSR1/SIGUSR2 show/hide).

## Architecture

```
hyprwhspr (systemd service)
  └── MicOSDRunner (runner.py) — spawns daemon subprocess
        └── /usr/bin/python3 -u -c "..." (daemon process)
              └── GTK4 + gtk4-layer-shell overlay window
```

- Daemon runs as separate process with `start_new_session=True`
- Parent signals SIGUSR1 (show) / SIGUSR2 (hide)
- PID file at `~/.config/hyprwhspr/mic_osd.pid`

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| `runner.py` | `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/runner.py` | Daemon lifecycle management |
| `main.py` (patch) | `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/main.py` | Monkey-patches hyprwhspr for OSD |
| `main.py` (osd) | `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/main.py` | GTK4 app with signal handlers |
| `window.py` | `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/window.py` | Layer shell window setup |
| Installed location | `~/.local/lib/hyprwhspr-patch/` | Runtime copy (must sync after edits) |
| Daemon log | `~/Programs/omarchy-voice-typing/logs/mic-osd-daemon.log` | Daemon stdout/stderr |

## Issue 1: LD_PRELOAD Segfault in systemd Context (Feb 2026)

### Symptom
- Daemon spawns and immediately dies (PID dead within milliseconds)
- Daemon log file is **0 bytes** — even with `python3 -u`, `flush=True`, and try/except
- `[MIC-OSD] Daemon process (PID ...) is dead, cleaning up` in journal

### Root Cause
`LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so` combined with `os.environ.copy()` (full parent environment) causes a segfault. The systemd service environment includes nvidia-related variables (`__GLX_VENDOR_LIBRARY_NAME=nvidia`, `LIBVA_DRIVER_NAME=nvidia`, `GDK_SCALE=2`) that likely conflict with LD_PRELOAD's library loading on the laptop (ThinkPad T14 Gen 1, AMD/Intel GPU).

### Diagnosis Path
1. Empty log with try/except = not a Python exception
2. Empty log with `-u` (unbuffered) + `flush=True` = process dies before Python main() runs
3. LD_PRELOAD loads native code during process init (before Python)
4. Works from terminal (clean env), fails from systemd (polluted env)
5. Works WITHOUT LD_PRELOAD (GTK4LayerShell loads via GI typelib) but no layer shell positioning

### Fix
Use a **minimal environment dict** instead of `os.environ.copy()`:

```python
env = {
    'HOME': str(Path.home()),
    'WAYLAND_DISPLAY': os.environ.get('WAYLAND_DISPLAY', 'wayland-1'),
    'XDG_RUNTIME_DIR': os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'),
    'DISPLAY': os.environ.get('DISPLAY', ''),
    'PYTHONPATH': os.environ.get('PYTHONPATH', ''),
    'PYTHONUNBUFFERED': '1',
    'LD_PRELOAD': '/usr/lib/libgtk4-layer-shell.so',
    'GDK_BACKEND': 'wayland',
    'PATH': os.environ.get('PATH', '/usr/bin'),
}
```

### Key Insight: Debugging Silent Crashes
- **Empty log file (0 bytes) = signal death before Python starts**
- LD_PRELOAD is the only mechanism that runs native code before Python's main()
- Try/except CANNOT catch these — they're not Python exceptions
- `coredumpctl` may not capture them either
- Test with `env -i` (clean env) to isolate

## Issue 2: OSD Layer Surface Blocks Text Injection (Feb 2026)

### Symptom
- When OSD is visible: transcription works but text is NOT typed/pasted
- When OSD daemon is dead: text injection works fine
- Clipboard has the text (wl-copy works), but ydotool paste doesn't fire

### Root Cause
The GTK4 layer shell overlay window (even with `KeyboardMode.NONE`) interferes with ydotool's keyboard simulation for the paste shortcut (Ctrl+V). The layer surface at OVERLAY layer intercepts or disrupts the simulated keystrokes.

### Fix
**Hide OSD BEFORE text injection**, not after. In `main.py` (patch):

```python
def _patched_stop_recording(self):
    # Hide MicOSD BEFORE original stop — original triggers text injection
    # and the OSD layer surface interferes with ydotool keyboard simulation
    if hasattr(self, 'mic_osd_runner') and self.mic_osd_runner:
        try:
            self.mic_osd_runner.hide()
        except Exception as e:
            print(f"[WARN] Failed to hide MicOSD: {e}", flush=True)

    # Call original (stops recording, transcribes, injects text)
    _original_stop_recording(self)
```

### Key Insight: Ordering Matters
The original code did:
1. `_original_stop_recording()` → transcribe → inject text (ydotool)
2. `mic_osd_runner.hide()` → SIGUSR2 to daemon

But ydotool's simulated Ctrl+V was blocked by the visible overlay. The fix:
1. `mic_osd_runner.hide()` → SIGUSR2 to daemon → window hidden
2. `_original_stop_recording()` → transcribe → inject text (ydotool works)

## Issue 3: Stale PID File Confusion (Feb 2026)

### Symptom
During rapid restart/debug cycles, `_ensure_daemon()` finds a stale PID file pointing to an old (running or dead) daemon. This creates confusion about whether the daemon is actually alive.

### Prevention
- Always `kill PID && rm PID_FILE` before restarting hyprwhspr during development
- The orphaned daemon detection in `_ensure_daemon()` handles this in production

## Issue 4: Frozen OSD Artifact After GPU Reset + 74 GB Log (Sep 2026)

### Symptom
The waveform overlay stayed on screen, frozen, long after recording ended. `hyprctl clients`
showed the `mic-osd` window mapped; `mic-osd-daemon.log` had grown to 74 GB of
`Gdk-WARNING: vkWaitForFences(): VK_ERROR_DEVICE_LOST` lines.

### Root Cause
GTK4 defaulted to the Vulkan renderer. After a GPU reset the device was lost and GTK's
frame loop spun forever inside the render path, so SIGUSR2 (hide) and the 30 s auto-hide
timer were never serviced. The Wayland surface stayed mapped with its last frame.

### Fix (runner.py)
1. `GSK_RENDERER=cairo` in the daemon env — a 400x68 waveform needs no GPU, and the
   software renderer has no device to lose.
2. Log rotation on spawn: if the log is over 5 MB it is renamed to `.log.1` first.
3. Hide watchdog: `hide()` starts a 1.5 s `threading.Timer` that runs `hyprctl clients -j`;
   if a mapped `mic-osd` window is still there (and no `show()` happened since), the
   daemon is SIGKILLed and the PID file cleared. The next `show()` respawns it.
   Verified by SIGSTOPping the daemon and calling `hide()`.

### Recovery by hand
```bash
kill -9 $(cat ~/.config/hyprwhspr/mic_osd.pid)
truncate -s 0 ~/Programs/omarchy-voice-typing/logs/mic-osd-daemon.log
```

## General Debugging Checklist

1. **Check daemon log**: `cat ~/Programs/omarchy-voice-typing/logs/mic-osd-daemon.log`
2. **Check journal**: `journalctl --user -u hyprwhspr --since "5 min ago" | grep MIC-OSD`
3. **Check daemon process**: `cat ~/.config/hyprwhspr/mic_osd.pid && kill -0 $(cat ~/.config/hyprwhspr/mic_osd.pid)`
4. **Clean restart**: `kill $(cat ~/.config/hyprwhspr/mic_osd.pid) 2>/dev/null; rm -f ~/.config/hyprwhspr/mic_osd.pid; systemctl --user restart hyprwhspr`
5. **Empty log = LD_PRELOAD segfault** — check environment variables passed to Popen
6. **Text not typed = OSD visible during injection** — check hide/show ordering

## gtk4-layer-shell Behavior

| LD_PRELOAD set? | Layer shell works? | Window position |
|---|---|---|
| Yes (clean env) | Yes | Bottom center (overlay layer) |
| Yes (full systemd env) | SEGFAULT | N/A — process dies |
| Yes (minimal env) | Yes | Bottom center (overlay layer) |
| No | No (warnings logged) | Center of screen (regular window) |

The warnings when LD_PRELOAD is missing:
```
Failed to initialize layer surface, GTK4 Layer Shell may have been linked after libwayland.
You may be able to fix without recompiling by setting LD_PRELOAD=/path/to/libgtk4-layer-shell.so
```

## Sync Reminder

After editing files in `local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/`:
```bash
cp ~/Programs/local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/mic_osd/runner.py \
   ~/.local/lib/hyprwhspr-patch/mic_osd/runner.py
cp ~/Programs/local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/main.py \
   ~/.local/lib/hyprwhspr-patch/main.py
systemctl --user restart hyprwhspr
```
