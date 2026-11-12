#!/usr/bin/env python3
"""
stale-touch-repro — show that one lost finger-lift makes a GTK3 client deaf to taps.

Opens a small GTK3 layer-shell probe window at (400,400) 300x150, then a virtual
touchscreen puts TWO fingers on it and disappears without lifting them. Later
single-finger taps on the probe arrive as raw touch events only, never as
button-press (GTK3 emulates a click only while no other touch is held), which is
what a waybar module listens for. A lost slot-0 lift heals on the next tap (the
id is reused); a lost slot-1+ lift never does.

Usage: tests/touch/stale-touch-repro.py [fingers]   (default 2; 1 shows the healing case)
Prints the probe's events and PASS (reproduced) / FAIL. Needs Hyprland, gtk-layer-shell,
python-evdev and write access to /dev/uinput. See
docs/issues/waybar-ignores-touch-stale-touch-2026-10-02.md.
"""
import os, subprocess, sys, tempfile, time

if len(sys.argv) > 1 and sys.argv[1] == "--probe":
    import gi
    gi.require_version("Gtk", "3.0"); gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import Gtk, GtkLayerShell, GLib
    t0 = time.monotonic()
    w = Gtk.Window(); GtkLayerShell.init_for_window(w)
    GtkLayerShell.set_layer(w, GtkLayerShell.Layer.OVERLAY)
    for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.LEFT):
        GtkLayerShell.set_anchor(w, edge, True); GtkLayerShell.set_margin(w, edge, 400)
    w.set_size_request(300, 150)
    eb = Gtk.EventBox(); eb.add(Gtk.Label(label="stale-touch probe")); w.add(eb)
    eb.connect("button-press-event", lambda *a: print(f"{time.monotonic()-t0:6.2f} button-press", flush=True))
    w.connect("touch-event", lambda _w, ev: print(f"{time.monotonic()-t0:6.2f} touch {ev.type.value_nick}", flush=True) or False)
    w.show_all(); GLib.timeout_add_seconds(int(sys.argv[2]), Gtk.main_quit); Gtk.main()
    sys.exit(0)

from evdev import UInput, ecodes as e, AbsInfo
fingers = int(sys.argv[1]) if len(sys.argv) > 1 else 2
caps = {e.EV_KEY: [e.BTN_TOUCH], e.EV_ABS: [
    (e.ABS_X, AbsInfo(0, 0, 3312, 0, 0, 11)), (e.ABS_Y, AbsInfo(0, 0, 1872, 0, 0, 11)),
    (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
    (e.ABS_MT_POSITION_X, AbsInfo(0, 0, 3312, 0, 0, 11)), (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, 1872, 0, 0, 11)),
    (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0))]}
R = lambda x, y: (int(x / 1920 * 3312), int(y / 1080 * 1872))

out = tempfile.NamedTemporaryFile("w+", suffix=".probe", delete=False)
probe = subprocess.Popen([sys.executable, __file__, "--probe", "26"], stdout=out, stderr=subprocess.STDOUT)
time.sleep(0.8)

ui = UInput(caps, name="stale-touch-vanish", input_props=[e.INPUT_PROP_DIRECT])
time.sleep(2)
for slot in range(fingers):
    x, y = R(450 + 80 * slot, 475)
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot); ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, 70 + slot)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, x); ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, y)
ui.write(e.EV_KEY, e.BTN_TOUCH, 1); ui.syn()
time.sleep(0.3)
ui.close()                                   # gone with the fingers still down
print(f"virtual screen removed with {fingers} finger(s) down; now 3 normal taps", flush=True)

here = os.path.dirname(os.path.abspath(__file__))
subprocess.run([sys.executable, os.path.join(here, "virtual-touch.py"),
                '[["tap",550,475,0.08],["wait",2],["tap",560,480,0.08],["wait",3],["tap",570,480,0.08],["wait",1]]'])
probe.wait()
out.seek(0); lines = out.read().splitlines(); os.unlink(out.name)
print("\n".join(lines))
# the first button-press is the vanishing fingers' own touch-down
after = [l for l in lines[1:] if "button-press" in l]
print("PASS: taps after the lost lift never became clicks" if not after
      else f"FAIL: {len(after)} tap(s) still clicked (expected when fingers=1)")
