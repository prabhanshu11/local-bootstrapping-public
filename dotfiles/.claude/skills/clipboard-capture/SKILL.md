---
name: clipboard-capture
description: Popup a terminal window to capture clipboard content (text or image) into the current project. Auto-detects type, generates random name, allows renaming, opens nvim for text. Use when user wants to paste/save clipboard content, capture a note, or save an image from clipboard.
user-invocable: true
allowed-tools:
  - Bash
  - Read
---

# Clipboard Capture

Pops up a Ghostty terminal that:
1. Reads clipboard (auto-detects text vs image via `wl-paste`)
2. Generates a random two-word name (e.g. `drift-opal`)
3. Shows the name, lets user rename or keep
4. **Image**: saves directly as `.png`
5. **Text**: pre-writes to file, opens nvim. Safe even if terminal killed — file already exists.

## Usage

```bash
bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/popup-note.sh"
```

If the project has `popup-note.sh` at its root, run it. Otherwise, copy the script from the camera project template:

```bash
cp ~/Programs/camera/popup-note.sh ./popup-note.sh
chmod +x popup-note.sh
```

Files are saved to `./clipboard/` in the project root.

## Requirements
- `ghostty` (terminal)
- `wl-paste` (Wayland clipboard, from `wl-clipboard`)
- `nvim` (editor)
