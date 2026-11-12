# Touch-native window control on the laptop: plan (2026-09-25)

Status: **plan only, nothing built or changed**. Written by the "touch-windows"
planning lane. Laptop: ThinkPad T14 Gen 1, ELAN touchscreen (evdev
`ELAN Touchscreen`, Hyprland name `elan-touchscreen`, raw 3312x1872, 10 slots),
eDP-1 1920x1080 at scale 1, **currently transform 2** (`screen-flip`),
Hyprland **0.55.2** (commit `39d7e209`), layout `dwindle`, gaps_out 10,
border 2.

Goal: move, resize, place/snap, focus, close, fullscreen/float, switch
workspaces and apps, and use 2/3/4-finger gestures and edge swipes, with the
finger alone.

---

## 1. What exists today

| Piece | Where | Commit(s) | State today |
|---|---|---|---|
| **bar-touch** daemon: evdev reader (passive; EVIOCGRAB in mouse mode), uinput mouse `bar-touch-mouse`, `hyprctl dispatch movecursor`, tap/long-press on the bar, popups, **overview** (two-finger swipe up, mouse mode only) | `dotfiles/local-bin/bar-touch` (1804 lines), `dotfiles/systemd-user/bar-touch.service`, `docs/touch-bar.md` | `1a8e19b` … `a3d43f3` (stuck-session fix), `7a8c3e1`, `77a41f9` | running |
| **touch-scroll-daemon**: evdev reader, one-finger vertical drag -> REL_WHEEL via uinput, **only when Ghostty is focused** (Chrome etc. scroll natively via wl_touch) | `dotfiles/local-bin/touch-scroll-daemon`, `dotfiles/systemd-user/touch-scroll-daemon.service` | `6cf10b3` (2026-02-13, "Add touchscreen scroll daemon and hyprgrass plugin setup"), `a6b5670` (allowlist), `38fe0cf` (screen-flip SIGUSR1) | running since 09-18 (this is the "terminal scrolling by touch, done long back") |
| **hyprgrass** plugin config + build script | `dotfiles/hypr/hyprgrass.conf` (symlinked to `~/.config/hypr/hyprgrass.conf`, sourced from `hyprland.conf` line 33), `scripts/setup-hyprgrass.sh`, `~/.local/share/hypr/plugins/libhyprgrass.so` (built 2026-02-13 against 0.52.2) | `6cf10b3` | **dead**: `hyprctl plugin list` = "no plugins loaded", `hyprpm list` empty. The stale .so no longer matches Hyprland 0.55.2, so the `plugin =` line loads nothing (no config error shown). |
| Touchpad gesture (not touchscreen) | `dotfiles/hypr/input.conf`: `gesture = 3, horizontal, workspace` | `766d42e` | works on the touchpad only |
| Hyprland native touch | built in | – | a touch on a window **focuses it** (`refocus()` on touch-down, `src/managers/input/Touch.cpp`). `gestures:workspace_swipe_touch` = **0** (off). |
| screen-flip | `dotfiles/local-bin/screen-flip` | `38fe0cf`, `b6cbc35` | sets `device[elan-touchscreen]:transform` to 0/2 and SIGUSR1s touch-scroll-daemon |
| Test harness | `tests/touch/virtual-touch.py` (tap, swipe2, wait, shot, status), `tests/touch/virtual-hover.py` | `1a8e19b`… | a uinput `bar-touch-test-screen` shaped like the ELAN panel |

Past transcripts: the February session that built the scroll daemon and
hyprgrass is no longer on disk (no `.jsonl` from 2026-02-12..20 mentions it);
the commit messages above are the record.

Note: in **mouse mode** bar-touch holds EVIOCGRAB on the panel, so Hyprland,
any Hyprland plugin **and touch-scroll-daemon** see no touches at all. Every
gesture that must work in mouse mode has to live in bar-touch.

---

## 2. The options

### 2a. Hyprland native (0.55.2)

- `gestures:workspace_swipe_touch = true`: a **one-finger swipe that starts
  within gaps_out + border (10 + 2 = 12 px, about 2 mm) of the left or right
  screen edge** drags the workspace 1:1 with animation. The touch is consumed
  (not sent to the app). `workspace_swipe_touch_invert` flips direction.
  Source: `Touch.cpp` at v0.55.2 (TARGETLEFT/TARGETRIGHT computed from
  gaps_out + border_size).
- The newer `gesture = <fingers>, <direction>, <action>` keyword (actions
  `workspace, move, resize, close, float, fullscreen, special, cursorZoom,
  dispatcher`, directions incl. `pinchin/pinchout`) lives in
  `src/managers/input/trackpad/` and is fed by **touchpad** swipe/pinch events
  only. Touchscreens do not reach it (hyprgrass bridges this, see 2b).
  Source: Hyprland wiki "Gestures" (now written for the 0.56 Lua config);
  Hyprland source tree v0.55.2.
- Mouse-style window drag: Omarchy binds `SUPER + mouse:272 = movewindow`,
  `SUPER + mouse:273 = resizewindow` (checked live with `hyprctl binds`).
  These run Hyprland's own drag controller: tiled windows are re-inserted
  where they are dropped, floats move, resize adjusts split ratios. The
  `mouse` dispatcher is only honoured with a real pressed state
  (`Actions::mouse` checks `m_passPressed`), so it cannot be driven from
  `hyprctl dispatch`; it needs a real (uinput) button **with SUPER held**.
- Plain dispatchers usable from any daemon: `movewindowpixel exact X Y,address:…`
  (floating), `resizewindowpixel exact W H,address:…`, `movewindow l|r|u|d`,
  `swapwindow`, `layoutmsg togglesplit|swapsplit`, `setfloating`/`settiled`/
  `togglefloating`, `fullscreen 0|1`, `killactive`/`closewindow`,
  `workspace e±1`, `cyclenext`, `focuswindow address:…`, `movetoworkspace`.

Verdict: native gives **focus** (already) and **edge-swipe workspace switching**
(one config line, but a 2 mm target). Nothing else native reaches the
touchscreen.

### 2b. hyprgrass plugin

- Features: workspace swipe (N fingers or from an edge), `hyprgrass-bind` on
  `swipe:N:dir`, `edge:origin:dir`, `tap:N`, `longpress:N`, `pinch:N:i|o`
  to any dispatcher; `hyprgrass-bindm` long press -> movewindow/resizewindow;
  `hyprgrass-gesture` = the native trackpad gesture actions on touch;
  `resize_on_border_long_press`; `experimental:send_cancel` (default on) sends
  `wl_touch.cancel` to the app once a gesture is recognised, i.e. **it can
  consume gestures**, which no evdev daemon can.
  Sources: https://github.com/horriblename/hyprgrass (README,
  `docs/configuration.md`, `src/main.cpp`, `src/GestureManager.cpp` at pin
  `3236fbb1`).
- **Builds for us**: `hyprpm.toml` pins Hyprland `39d7e209…` (v0.55.2) to
  hyprgrass `3236fbb1a2f9c3a91ac1a4f390ed6d510c2aaf19`.
- **But on exactly 0.55.2 long-press move/resize is broken**: issue #379
  (2026-05-23, reporter on the same commit `39d7e209`): "hyprgrass-bindm is
  unable to move/resize windows on latest hyprland … Downgrading to 0.54.3
  solves the issue." Open.
- Other risks: #270 Hyprland itself **exits** when a finger is added during a
  workspace swipe with a window present (open; compositor exit = every
  unsaved window lost); #146 bindm fails with `cursor:no_warps` (we have 0, OK);
  it warps the cursor on every touch-down; alpha ("expect breaking changes");
  a rebuild (hyprpm, sudo for the headers dir) after **every** Hyprland update
  or it silently stops loading, exactly what happened here after February; the
  newest pins drop the legacy config for 0.56's Lua config, so our
  `hyprgrass.conf` will need a rewrite at the next major upgrade.

Verdict: good for **consumed** edge swipes and multi-finger dispatch binds,
not usable for move/resize on this version, and a maintenance and crash risk.
Park it (phase 4, optional).

### 2c. Extend bar-touch's evdev daemon (recommended core)

bar-touch already has the pieces: every touch is seen in both modes, sessions,
monitor mapping incl. transform 2, a uinput mouse, the Hyprland socket (no
process per command), GTK layer-shell windows, the overview, the virtual test
screen, and the hard-won lessons (DEFAULT priority, windows from idle
callbacks, `drop()` ends a vanished device's session, 3 s stale replacement).
No ABI coupling to Hyprland versions.

What it cannot do: **consume** a gesture. In normal mode the app under the
fingers also receives them (only mouse mode grabs, and a grab is the whole
device). So the evdev route must stick to input the apps ignore or never see:

1. **Zones we own**: the top bar (waybar layer; bar-touch already arbitrates
   its taps) and **new layer-shell affordances** (a window handle, snap
   targets). A touch on our own surface never reaches the app.
2. **3- and 4-finger gestures**: Ghostty, nvim, GTK apps ignore them; the
   scroll daemon acts on one finger only. Chrome may treat 3 fingers as a
   scroll/pinch of the page: measure (P1 test) and, if it does, add
   "grab on recognise" (P3 experiment) or accept it.
3. **Mouse mode**: everything, since the device is grabbed anyway.

Mechanics for move/resize (to be proven by test, in this order):

- **Route A (preferred): real drag through Hyprland's own bindm.** Add a
  uinput keyboard (`bar-touch-keys`, only `KEY_LEFTMETA`) next to the uinput
  mouse. Handle-drag = `movecursor` to the handle, SUPER down, BTN_LEFT down,
  `movecursor` as the finger moves (already done at 8 ms for mouse-mode
  drags), BTN_LEFT up, SUPER up. BTN_RIGHT for resize. Same behaviour as the
  mouse: tiled windows swap/re-insert where dropped, floats move freely.
  Safety: release in `end()`, `drop()`, `release_buttons()`, SIGTERM and
  `quit_`; if the process dies the kernel's `input_unregister_device()`
  releases held keys and libinput reports the removal, so SUPER cannot stay
  stuck past the daemon. To verify first: does `movecursor` (warp +
  `simulateMouseMovement`) advance an active drag? If not, send relative
  REL_X/REL_Y from the uinput mouse instead (bar-touch-mouse already has them;
  set its accel profile flat via `device[bar-touch-mouse]:accel_profile = flat`).
- **Route B (fallback): dispatchers.** Floating: `movewindowpixel exact` /
  `resizewindowpixel exact` with `address:` at ≤60 Hz. Tiled move: on drop,
  `movecursor` to the drop point then `swapwindow`/`movewindow <dir>` toward
  the target tile; tiled resize: `resizewindowpixel` (changes the split).

### 2d. On-screen affordance: a touch handle on the active window

A small layer-shell pill (overlay layer, ~96x22 px, centred on the active
window's top edge, inside its border) shown **only in touch mode** (TOCH on),
following `activewindow>>`, `movewindow>>`, `workspace>>`, `fullscreen>>`,
`closewindow>>` from socket2 (plus a 1 s poll as a net). Hidden for fullscreen
windows and on the bar's own monitor area. Since Omarchy windows have no title
bars, this is the missing "title area". Built with the same `layer_window()`
helper, created from idle callbacks.

- Drag the pill = move (Route A/B).
- A second grip at the window's bottom-right corner (on touch-down on the pill,
  or always in touch mode; decide by test) = resize.
- Tap = window menu card (the bar's card style): **Close, Float/Tile,
  Fullscreen, Maximize, Split direction (`layoutmsg togglesplit`), Swap
  (`layoutmsg swapsplit`), Move to workspace 1..5, Pin**.
- Double-tap = maximize toggle (`fullscreen 1`).

This is conflict-free by construction, works in both modes, and is the most
discoverable: it is the core of the plan.

### 2e. Interaction with apps' own touch

| App | Its own touch handling | Conflicts |
|---|---|---|
| Chrome / Electron (Obsidian) on Wayland | 1-finger drag = scroll, pinch = zoom, long press = context menu, horizontal overscroll = back/forward | any 1- or 2-finger gesture on the page; edge swipes that start on the page; possibly 3-finger (measure) |
| Ghostty | no wl_touch scroll (why the scroll daemon exists); a 1-finger drag selects text | 1-finger drags; the scroll daemon already owns vertical 1-finger in Ghostty |
| GTK3/4 apps (popups, pavucontrol…) | drag = scroll, long press = context menu | 1-finger |
| waybar | on-click fires ~6 ms after finger-down | a horizontal swipe that *starts on a workspace number* first switches to that number (accept, or start swipes from empty bar) |
| bar-touch popups, overview | our own | none |

Rule that falls out: **1 and 2 fingers belong to apps** (except on our own
surfaces and in mouse mode); **3 and 4 fingers and our surfaces belong to
window management**.

---

## 3. Gesture map (proposal)

Effort: S < ½ day, M ≈ 1 day, L > 1 day. Mode: N = normal (passive),
M = mouse mode (grabbed).

| # | Interaction | Proposed gesture | Route | Phase | Effort | Risk | How to test |
|---|---|---|---|---|---|---|---|
| 1 | Focus | tap on the window | **native, exists** (N); mouse mode taps = left click which also focuses | – | 0 | none | virtual tap on a test window, assert `hyprctl activewindow -j` address |
| 2 | Workspace switch | 3-finger swipe left/right anywhere (like the touchpad) | bar-touch | 1 | S | Chrome may scroll the page with 3 fingers (measure) | `swipe3` step, assert `hyprctl activeworkspace -j` id ±1 |
| 3 | Workspace switch (bar) | 1-finger horizontal swipe along the top bar (>80 px, starting on empty bar) | bar-touch | 1 | S | touching a workspace number switches first (waybar) | `drag` step at y=12 from x=700 to x=500 |
| 4 | Overview / app switch | 3-finger swipe up (both modes); keep 2-finger up in mouse mode; 1-finger swipe **down from the bar** also opens it | bar-touch (overview exists) | 1 | S | low | `swipe3` dy=-150, screenshot / assert `hyprctl layers` has `bar-touch-overview`; tap empty space closes |
| 5 | Close window | 3-finger swipe down -> a **confirm chip** "Close <class>? tap" for 2.5 s (no one-gesture kill: a terminal with a running job is lost) | bar-touch | 1 | S | accidental close without confirm, hence the chip | test window only; assert its address gone after tapping the chip, still present after timeout |
| 6 | Window handle (enabler) | pill on the active window, touch mode only | bar-touch layer surface | 2 | M | the handle covering app content (tabs at the top of Chrome): place inside top border, 22 px, test on Chrome | `hyprctl layers` shows it at the active window's top; follows a `movewindow` |
| 7 | Window menu | tap the handle -> card: Close, Float/Tile, Fullscreen, Maximize, Split, Swap, To workspace N, Pin | bar-touch card | 2 | S | low | tap each button on a test window, assert via `hyprctl clients -j` |
| 8 | Move | drag the handle | bar-touch, Route A (SUPER + uinput drag), fallback B | 2 | M | stuck SUPER/button if a release path is missed | drag handle of a test float by (200,100), assert `at` moved ±5 px; tiled: drop on neighbour, assert order swapped; kill -9 mid-drag, assert no stuck SUPER (`hyprctl devices`, type a key) |
| 9 | Resize | drag the corner grip | Route A (SUPER + BTN_RIGHT) / `resizewindowpixel` | 2 | M | same as 8 | assert `size` changed; tiled: split ratio changed |
| 10 | Fullscreen / maximize | double-tap handle = `fullscreen 1`; 3-finger pinch out = `fullscreen 0`, pinch in = exit | bar-touch | 2 (handle), 3 (pinch) | S / M | pinch needs multi-finger spread tracking (session keeps only finger 0 today) | `pinch3` step, assert `fullscreen` field |
| 11 | Float / tile toggle | menu item; 4-finger tap (P3) | bar-touch | 2 | S | low | assert `floating` flips |
| 12 | Snap / place | while dragging a **floating** window: drop near left/right edge = half screen, top edge = maximize, over the tiled area = `settiled` at the drop point; translucent target shown during drag | bar-touch + layer surface for the preview | 3 | L | preview window creation during a drag (deadlock lesson: idle callbacks only) | drag to x<40, assert geometry ≈ 950x1040 at (10, bar+10) |
| 13 | App switch within workspace | 4-finger swipe left/right = `cyclenext` / `cyclenext prev` + `bringactivetotop` | bar-touch | 3 | S | 4 fingers on 14" is cramped | `swipe4` step, assert active address changes |
| 14 | Move window to workspace | 4-finger swipe left/right while touching the handle? Simpler: menu "To workspace N" | menu | 2 | S | – | menu test |
| 15 | 3-finger hold + drag = move the window under the fingers (no handle needed) | bar-touch | 3 | M | overlaps 2/4/5; disambiguate by 0.4 s hold before moving | `hold3drag` step |
| 16 | Edge swipes, left/right | 1-finger from the side edge = workspace | **native** `gestures:workspace_swipe_touch = true` (consumed, animated) | 1 (optional, config) | S | 12 px target may be too thin to hit; cannot be widened without raising gaps_out | real finger only (virtual device: see §5 transform caveat) |
| 17 | Edge swipes, top/bottom and wider margins | e.g. bottom edge up = overview | hyprgrass `edge:d:u` (consumed) | 4 (optional) | M | all hyprgrass risks (2b) | after rebuild, virtual edge swipes |
| 18 | 2-finger gestures | none outside mouse mode (they belong to apps: scroll, zoom); mouse mode keeps 2-up = overview | – | – | – | – | – |
| 19 | Terminal scroll in mouse mode | fold touch-scroll-daemon into bar-touch so one reader serves both modes (today scroll is starved while the panel is grabbed) | bar-touch | 3 | M | behaviour change of a working daemon | Ghostty test window, `drag` step, assert scrollback moved |

## 4. Phased rollout

**Phase 1: small, safe, high value (bar-touch only, no Hyprland config, no plugin)**

1. Multi-finger tracking in `Session`: keep all contacts per frame (centroid,
   finger count, spread), not only `raw[0]`. Pure bookkeeping; mouse-mode
   code keeps using finger 0.
2. 3-finger swipe left/right -> `workspace e±1` (#2), both modes.
3. 3-finger swipe up -> overview (#4), both modes; 1-finger swipe down from
   the bar -> overview.
4. 1-finger horizontal swipe on the bar -> `workspace e±1` (#3).
5. 3-finger swipe down -> close confirm chip (#5).
6. `virtual-touch.py`: new steps `swipe3`, `swipe4`, `drag`, `pinch3`,
   `hold`, plus a `try/finally` that **lifts every slot and sends a final
   SYN before `ui.close()`** (today's stuck-session cause), and a `--target`
   that refuses to run unless the focused workspace is the test workspace.
7. Log every recognised gesture (`journalctl --user -u bar-touch`), as today.
8. Measure: does Chrome scroll or zoom when it receives a 3-finger swipe? If
   yes, note it in `docs/touch-bar.md`; the answer decides the P3 experiment.

Optional in phase 1, needs the user's yes (a Hyprland config change):
`gestures:workspace_swipe_touch = true` (#16).

**Phase 2: the handle** (#6-#9, #11, #14): layer pill, window menu card, drag
to move and resize via Route A, with Route B kept as fallback. Gated on touch
mode.

**Phase 3**: snapping with a drop preview (#12), 3-finger pinch fullscreen
(#10), 4-finger app cycling (#13), hold-drag move (#15), fold terminal scroll
into bar-touch (#19), and the "grab on recognise" experiment (EVIOCGRAB for
the rest of a recognised 3-finger gesture so apps stop seeing it; must prove
that the app receives its touch-up/cancel afterwards, virtual device only).

**Phase 4 (optional)**: hyprgrass for consumed top/bottom edge swipes, only
after #379 is fixed or Hyprland moves past it, with the rebuild wired into the
upgrade path. Until then remove or comment out the dead
`source = ~/.config/hypr/hyprgrass.conf` (user's call).

Code shape: bar-touch is 1800 lines. Put the new recognizer and the handle in a
sibling module (`dotfiles/local-bin/bar_touch_windows.py`, imported by
bar-touch) fed by the existing `frame()`/`end()` hooks, so mouse mode and
normal mode share one reader and one session model. No second daemon: two
processes reading the panel cannot coordinate a grab.

## 5. Testing rules (from today's lessons)

- **Never on the live screen while the user works.** Stop the service and run
  a second daemon limited to the virtual device:
  `BAR_TOUCH_DEVICES=bar-touch-test-screen bar-touch daemon &`, and act only on
  throwaway windows on a dedicated test workspace (e.g. `ghostty --class=touchtest`
  on workspace 9). Restart the service afterwards.
- **Lift every finger before closing the virtual device** (`try/finally`: set
  `ABS_MT_TRACKING_ID -1` on every used slot, `BTN_TOUCH 0`, `SYN`, sleep
  0.1 s, then close). A device removed mid-touch once left bar-touch's
  session open (fixed in `a3d43f3`, but tests must not rely on the fix).
- After each test: `bar-touch status` must show `"touching": false`, and no
  held key/button (type in a test terminal; `hyprctl activewindow` responds to
  a click).
- Assert on `hyprctl -j` state (address, `at`, `size`, `floating`,
  `fullscreen`, workspace id), not only screenshots.
- **Transform caveat**: `screen-flip` sets the transform only on
  `device[elan-touchscreen]`; bar-touch's `map_point` flips for transform 2 on
  every device. With the panel at transform 2 (as now) Hyprland and bar-touch
  may disagree about where a virtual touch lands. Run virtual tests at
  transform 0, or set `device[bar-touch-test-screen]:transform` to match
  during the test.
- Mouse-mode tests grab only the virtual device (`BAR_TOUCH_DEVICES`), never the
  panel.
- Load: the doc records verdicts flipping to "mouse" under load 6 / 96 °C.
  Note the load average in each test log.

## 6. Open questions for the user

1. Is a small **handle pill** on the active window acceptable (touch mode only),
   or should window control stay invisible (gestures only)?
2. Enable native `gestures:workspace_swipe_touch` (1-finger swipe from the very
   left/right edge switches workspace, 2 mm target)? It is a Hyprland config
   change.
3. Remove the dead hyprgrass `source =` line and its stale .so, or rebuild
   hyprgrass later for top/bottom edge swipes (broken move/resize on 0.55.2,
   rebuild after every Hyprland update)?
4. Close by 3-finger swipe down with a confirm tap: OK, or menu-only?
5. 3 fingers for workspace swipes, as on the touchpad: agreed?
6. Should terminal touch scrolling also work in mouse mode (fold the scroll
   daemon into bar-touch)?

## Sources

- Hyprland source v0.55.2: `src/managers/input/Touch.cpp` (native touch,
  workspace_swipe_touch), `src/managers/input/trackpad/*` (gesture actions),
  `src/config/legacy/DispatcherTranslator.cpp` (dispatcher names),
  `src/config/shared/actions/ConfigActions.cpp` (`Actions::mouse`) —
  https://github.com/hyprwm/Hyprland/tree/v0.55.2
- Hyprland wiki, Gestures: https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/
  (repo path `content/configuring/core/binds/gestures.md`, now Lua syntax)
- hyprgrass: https://github.com/horriblename/hyprgrass — `hyprpm.toml`
  (v0.55.2 pin `3236fbb1`), `docs/configuration.md`, `src/main.cpp`,
  `src/GestureManager.cpp`; issues
  https://github.com/horriblename/hyprgrass/issues/379,
  https://github.com/horriblename/hyprgrass/issues/270,
  https://github.com/horriblename/hyprgrass/issues/146
- Local: `docs/touch-bar.md`, `dotfiles/local-bin/bar-touch`,
  `dotfiles/local-bin/touch-scroll-daemon`, `scripts/setup-hyprgrass.sh`,
  `tests/touch/virtual-touch.py`, live `hyprctl binds/getoption/plugin list`.
