#!/usr/bin/env python3
"""
virtual-hover — hover the pointer over a spot and screenshot the tooltip.

`hyprctl dispatch movecursor` alone moves the arrow without a motion event, so
GTK never starts a tooltip. This adds a virtual relative mouse and nudges it a
few pixels after the warp, which GTK sees as real motion.

Usage:  tests/touch/virtual-hover.py X Y SHOT.png "X,Y WxH" [wait_s]
The pointer goes back to where it was afterwards.
Coordinates are global layout pixels (hyprctl cursorpos).
"""
import sys, time, subprocess
from evdev import UInput, ecodes as e

x, y, shot, geom = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
wait = float(sys.argv[5]) if len(sys.argv) > 5 else 2.0
home = subprocess.run(["hyprctl", "cursorpos"], capture_output=True, text=True).stdout.strip()
ui = UInput({e.EV_REL: [e.REL_X, e.REL_Y], e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT]},
            name="bar-touch-test-mouse")
time.sleep(1.5)                      # libinput picks the device up
try:
    subprocess.run(["hyprctl", "dispatch", "movecursor", str(x - 3), str(y)], capture_output=True)
    for _ in range(3):
        time.sleep(0.1)
        ui.write(e.EV_REL, e.REL_X, 1); ui.syn()
    time.sleep(wait)
    subprocess.run(["grim", "-g", geom, shot], check=True)
finally:
    hx, hy = (home.replace(",", " ").split() + ["0", "0"])[:2]
    subprocess.run(["hyprctl", "dispatch", "movecursor", hx, hy], capture_output=True)
    ui.close()
