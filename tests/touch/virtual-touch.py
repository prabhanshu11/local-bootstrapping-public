#!/usr/bin/env python3
"""
virtual-touch — drive gestures on a virtual multitouch screen shaped like the
laptop's ELAN panel (0..3312 x 0..1872, 10 slots). Hyprland treats it like the
real screen, so waybar receives the touches and bar-touch sees them too.

Usage:  tests/touch/virtual-touch.py '<json list of steps>'
Steps:  ["tap", x, y, hold_s]        one finger at logical (x, y)
        ["swipe2", x, y, dy]         two fingers 120 px apart moving dy px
        ["wait", s]
        ["shot", file, "X,Y WxH"]    grim screenshot
        ["status", label]            print `bar-touch status`
The device appears 6.5 s before the first step (libinput pickup + the daemon's
5 s rescan). To test MOUSE MODE without grabbing the real screen, run a second
daemon limited to this device (stop the service first):
  BAR_TOUCH_DEVICES=bar-touch-test-screen bar-touch daemon &
Coordinates assume the 1920x1080 panel at scale 1, transform 0.
"""
import sys, time, subprocess, json
from evdev import UInput, ecodes as e, AbsInfo
caps = {e.EV_KEY: [e.BTN_TOUCH], e.EV_ABS: [
    (e.ABS_X, AbsInfo(0, 0, 3312, 0, 0, 11)), (e.ABS_Y, AbsInfo(0, 0, 1872, 0, 0, 11)),
    (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
    (e.ABS_MT_POSITION_X, AbsInfo(0, 0, 3312, 0, 0, 11)), (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, 1872, 0, 0, 11)),
    (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0))]}
ui = UInput(caps, name="bar-touch-test-screen", input_props=[e.INPUT_PROP_DIRECT])
time.sleep(6.5)
R = lambda x, y: (int(x / 1920 * 3312), int(y / 1080 * 1872))
tid = [900]
def put(slot, x, y, new=False):
    rx, ry = R(x, y); ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
    if new: tid[0] += 1; ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, tid[0])
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, rx); ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, ry)
def lift(slot): ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot); ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
def syn(t): ui.write(e.EV_KEY, e.BTN_TOUCH, t); ui.syn()
for step in json.loads(sys.argv[1]):
    k = step[0]
    if k == "tap":
        x, y, hold = step[1:]; put(0, x, y, True); syn(1); time.sleep(hold); lift(0); syn(0)
    elif k == "swipe2":
        x, y, dy = step[1:]; put(0, x, y, True); put(1, x + 120, y, True); syn(1); time.sleep(0.05)
        for i in range(1, 16):
            put(0, x, y + dy * i / 15); put(1, x + 120, y + dy * i / 15); syn(1); time.sleep(0.015)
        lift(0); lift(1); syn(0)
    elif k == "wait": time.sleep(step[1])
    elif k == "shot": subprocess.run(["grim", "-g", step[2], step[1]])
    elif k == "status":
        print(step[1], subprocess.run(["bar-touch", "status"], capture_output=True, text=True).stdout.replace("\n", " "), flush=True)
