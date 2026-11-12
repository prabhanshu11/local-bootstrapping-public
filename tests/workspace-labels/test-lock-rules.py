#!/usr/bin/env python3
"""Lock rules of the popup (his 2026-11-10), driven on a stub Daemon: no GTK,
no keyboard, no real Super key (injecting Super would fire his shortcuts).

  1. Super alone held 7 s            -> locks
  2. Super + a key (a switch), then held 7 s more -> never locks
  3. Super + mouse movement only     -> clock restarts, then locks
  4. live card: input before CARD_GRACE_S ignored, first input after hides it
  5. plain label: input after 400 ms hides it (unchanged)

Run: python3 tests/workspace-labels/test-lock-rules.py   (< 1 s)
"""
import importlib.machinery, importlib.util, os, sys, time, types

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "dotfiles", "local-bin", "workspace-labels")
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("wl", SRC)
wl = importlib.util.module_from_spec(importlib.util.spec_from_loader("wl", loader))
loader.exec_module(wl)
wl.log = lambda *a, **k: None


class Stub(wl.Daemon):
    def __init__(self):                       # no GTK
        self.locked = False
        self.super_down, self.super_quiet, self.super_combo, self.hold_src = None, 0.0, False, None
        self.shown_ws, self.card_ws, self.active_ws = 3, None, 3
        self.shown_at, self.switched_at = time.monotonic(), 0.0
        self.activity, self.hidden, self.timers = {}, 0, []
        self.GLib = types.SimpleNamespace(
            timeout_add=lambda ms, fn, *a: self.timers.append(fn) or 1,
            idle_add=lambda fn, *a: None)

    def set_locked(self, on, why):
        self.locked = on

    def hide(self):
        self.hidden += 1; self.shown_ws = None

    def screenshot_busy(self):
        return False

    def fire(self):                           # run the pending 300 ms "later" timers
        for fn in self.timers:
            fn()
        self.timers = []


ok = True
def check(name, cond):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name)

now = time.time()
H = wl.LOCK_HOLD_S

d = Stub(); d.on_key_thread("super", True, now - H - 1); d.hold_check()
check("1 Super alone held LOCK_HOLD_S locks", d.locked)

d = Stub(); d.on_key_thread("super", True, now - 30)
d.on_input_thread(now - 20, True)             # Super+N
d.hold_check()
check("2 Super + a key, then 20 s still: no lock", not d.locked)
d.on_key_thread("super", False, now - 8); d.on_key_thread("super", True, now - H - 1); d.hold_check()
check("2b released, pressed alone again LOCK_HOLD_S: locks", d.locked)

d = Stub(); d.on_key_thread("super", True, now - 30)
d.on_input_thread(now - 1, False); d.hold_check()
check("3 Super + mouse 1 s ago: not yet", not d.locked)
d.on_input_thread(now - H - 1, False); d.hold_check()
check("3b Super + mouse, then 5 s still: locks", d.locked)

d = Stub(); d.card_ws = 3; d.shown_at = time.monotonic() - 2
d.on_input(); d.fire()
check("4 live card, input at 2 s: stays, not locked", d.hidden == 0 and not d.locked)
d.shown_at = time.monotonic() - wl.CARD_GRACE_S - 0.1
d.on_input(); d.fire()
check("4b live card, input after 5 s: hidden", d.hidden == 1)

d = Stub(); d.shown_at = time.monotonic() - 0.2; d.on_input(); d.fire()
check("5 label, input at 200 ms: stays", d.hidden == 0)
d.shown_at = time.monotonic() - 0.5; d.on_input(); d.fire()
check("5b label, input at 500 ms: hidden", d.hidden == 1)

check("6 showing the card no longer locks (source)", 'set_locked(True, "live card shown")' not in open(SRC).read())
sys.exit(0 if ok else 1)
