#!/usr/bin/env python3
"""
walker-tap — tap a harmless walker dmenu (alpha / beta / gamma) with a virtual
touchscreen and report what walker printed. Never opens the real power menu.

Usage:  uv run --no-project --with evdev python3 tests/touch/walker-tap.py '<steps>' WxH
  WxH = logical size of the monitor the test screen is mapped to.
Steps (json list), coordinates monitor-local:
  ["open"]               open the dmenu (walker opens on the FOCUSED monitor)
  ["tap", x, y, hold_s]  one finger
  ["cursor", X, Y]       hyprctl dispatch movecursor (global coordinates)
  ["rel", dx, dy, n]     n relative moves of a virtual mouse
  ["click"]              virtual mouse left click
  ["wait", s]
  ["shot", file, "X,Y WxH"]
Hyprland maps an unconfigured touchscreen to the focused monitor. To match
bar-touch (which maps every touch to eDP-1) map it first, runtime only:
  hyprctl keyword 'device[bar-touch-test-screen]:output' eDP-1
Example (eDP-1 1920x1080, menu centred, entries at y 514/566/618, x 868):
  walker-tap.py '[["open"],["wait",1],["tap",868,566,0.08],["wait",1]]' 1920x1080
  -> "walker rc 0 stdout 'beta\\n'" when taps work, "walker still open" when not.
See docs/issues/walker-menu-ignores-touch-2026-10-11.md.
"""
import json, subprocess, sys, time
from evdev import UInput, ecodes as e, AbsInfo

caps = {e.EV_KEY: [e.BTN_TOUCH], e.EV_ABS: [
    (e.ABS_X, AbsInfo(0, 0, 3312, 0, 0, 11)), (e.ABS_Y, AbsInfo(0, 0, 1872, 0, 0, 11)),
    (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
    (e.ABS_MT_POSITION_X, AbsInfo(0, 0, 3312, 0, 0, 11)), (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, 1872, 0, 0, 11)),
    (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0))]}
W, H = map(int, sys.argv[2].split("x"))
ui = UInput(caps, name="bar-touch-test-screen", input_props=[e.INPUT_PROP_DIRECT])
ms = UInput({e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT], e.EV_REL: [e.REL_X, e.REL_Y]}, name="walker-test-mouse")
time.sleep(6.5)   # libinput pickup + bar-touch's 5 s device rescan
R = lambda x, y: (int(x / W * 3312), int(y / H * 1872))
p, tid = None, 900
for step in json.loads(sys.argv[1]):
    k = step[0]
    if k == "open":
        p = subprocess.Popen(["omarchy-launch-walker", "--dmenu", "--width", "295", "--minheight", "1",
                              "--maxheight", "630", "-p", "Test…"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        p.stdin.write("alpha\nbeta\ngamma\n"); p.stdin.close()
    elif k == "tap":
        x, y, hold = step[1:]; rx, ry = R(x, y); tid += 1
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0); ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, tid)
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, rx); ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, ry)
        ui.write(e.EV_ABS, e.ABS_X, rx); ui.write(e.EV_ABS, e.ABS_Y, ry)
        ui.write(e.EV_KEY, e.BTN_TOUCH, 1); ui.syn(); time.sleep(hold)
        ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1); ui.write(e.EV_KEY, e.BTN_TOUCH, 0); ui.syn()
    elif k == "cursor":
        subprocess.run(["hyprctl", "dispatch", "movecursor", str(step[1]), str(step[2])], capture_output=True)
        time.sleep(0.05)
    elif k == "rel":
        for _ in range(step[3]):
            ms.write(e.EV_REL, e.REL_X, step[1]); ms.write(e.EV_REL, e.REL_Y, step[2]); ms.syn(); time.sleep(0.02)
    elif k == "click":
        ms.write(e.EV_KEY, e.BTN_LEFT, 1); ms.syn(); time.sleep(0.06)
        ms.write(e.EV_KEY, e.BTN_LEFT, 0); ms.syn()
    elif k == "wait":
        time.sleep(step[1])
    elif k == "shot":
        subprocess.run(["grim", "-g", step[2], step[1]])
if p:
    try:
        out, _ = p.communicate(timeout=3)
        print("walker rc", p.returncode, "stdout", repr(out))   # rc 130 = closed without a choice
    except subprocess.TimeoutExpired:
        print("walker still open after the steps (tap ignored); closing it")
        subprocess.run(["walker", "-q"]); p.kill()
