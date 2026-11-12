#!/usr/bin/env python3
"""virtual-push — a virtual relative mouse (uinput) that pushes the cursor LEFT, for the VDI left-edge
push test (dotfiles/local-bin/vdi, docs/vdi.md). Hyprland moves the real cursor with it and the VDI
daemon's evdev reader sees the REL_X events like a hand on the mouse.

Usage: tests/touch/virtual-push.py [px=400] [steps=8] [left|up]   (the device exists ~3 s before the push)
"""
import sys, time
from evdev import UInput, ecodes as e
px = int(sys.argv[1]) if len(sys.argv) > 1 else 400
steps = int(sys.argv[2]) if len(sys.argv) > 2 else 8
axis = e.REL_Y if len(sys.argv) > 3 and sys.argv[3] == "up" else e.REL_X
ui = UInput({e.EV_REL: [e.REL_X, e.REL_Y], e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT]}, name="vdi-test-mouse")
time.sleep(3.0)          # libinput + the daemon's device scan (select timeout 2 s)
for _ in range(steps):
    ui.write(e.EV_REL, axis, -px // steps); ui.syn(); time.sleep(0.03)
time.sleep(0.5)
ui.close()
