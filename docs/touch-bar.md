# Touch-native top bar, TOCH and mouse mode (2026-09-24)

What the user asked for, in order:

1. **Touch mode**: the top bar 25% taller with much bigger icons, toggled from
   the bar, one inch to the right of the leftmost workspace number.
2. Everything on the bar **touch-navigable**: a **long press reveals what a
   module is**, and **touching a module shows its state change as a popup**.
3. The touch mode toggle shown as the text **TOCH in a 2x2 letter block that
   lights up**.
4. The old hand icon becomes **mouse mode**: a touch is a left click and the
   arrow goes there, a long press is a right click, and **two fingers swiped up
   show all open windows**.

## What is on the bar

```
[omarchy] 1 2 3 4 5 ........ [TO] [hand] ... centre ... right modules
                              [CH]
          |<--- 1 inch --->|
```

| Element | Tap | Long press |
|---|---|---|
| TOCH (letters lit = on) | touch mode on/off | card |
| hand (lit = on) | mouse mode on/off | card |
| grid (open windows) | full-screen overview: every window as a tile, current desktop first in Alt+Tab (MRU) order; tap a tile = switch, its ✕ = close (the focused one via `hypr-close-ordered`, like Super+W) | card |
| mic (voice typing) | card: Start/Stop, and a Microphone list (tap one = default mic) | card |
| every other module | its normal click action + a popup of its state before and after | card: what it is, full state, a button for every action (tap, right-click, middle-click, scroll up/down) |
| volume (speaker) | a volume popup: big slider, Mute, -5, +5, and the plugged-in outputs (tap one to make it the default); a Bluetooth output shows its codec ("FIIO BR13 · LDAC") and, when selected, a Codec row (SBC … LDAC, tap to switch) | card |
| Wi-Fi | a network list: one tab per radio (the internet one marked), signal bars, lock / saved / connected; tap a saved or open network to join; a new secured network asks for its password in the popup; Rescan | card |
| Bluetooth | power on/off, paired devices (connected first, type icons); tap a device to connect or disconnect; Scan for new devices, then tap one to pair (passkeys shown in the popup) | card |
| battery | the battery panel (charge bar, flow, forecasts, history chart, power profiles) | card |
| cone (mpv history) | the mpv history panel: thumbnails (tap = 20x preview), Resume, Folder | card: full state per video (how far, when, plays) + Resume last / Folder of last |
| US / DV (keyboard) | the **on-screen keyboard** rises from the bottom; again = hides it | card: layout, keyboard shown/hidden, Switch layout |
| workspace numbers, tray icons | waybar's own behaviour (switch / activate) | nothing (built into waybar, cannot be wrapped) |

Popups (volume, Wi-Fi, Bluetooth, cards, toasts) close on a touch anywhere
outside them, on a tap of their own icon again, on any other bar module, and on a bar
touch no module claims (empty bar, workspace numbers, tray; decided 1 s after the
lift). The on-screen keyboard is the one exception ("persistent" in bar-touch):
a touch outside it, a card or another popup leave it up; only its hide key or its own
bar icon close it. The daemon sees touch-downs from evdev, so the touch still reaches the app
underneath. A mouse click outside a popup cannot be seen (layer surfaces get no
outside clicks); the 8/20 s timers still close those.

Mouse clicks run the module's action at once (no toast). Volume, Wi-Fi and
Bluetooth open their popup for a mouse click too: wiremix, impala and bluetui
are never launched from the bar (2026-09-25: "they have no touch support, so
mouse support even… i liked your widgets better"). Their long-press card has
an "Open the … controls" button. Omarchy's own menu still launches the TUIs.

## Files

| File | Role |
|---|---|
| `dotfiles/local-bin/touch-mode` | touch mode state + TOCH status JSON |
| `dotfiles/local-bin/bar-touch` | daemon + client: popups, cards, mouse mode, overview |
| `dotfiles/systemd-user/bar-touch.service` | runs the daemon (`KillMode=process`) |
| `dotfiles/waybar/config.jsonc` | every module's `on-click` is `bar-touch click <module>`; the real command and labels live in its `"touch"` object |
| `dotfiles/waybar/style.css` | TOCH, hand, and all touch-mode sizes |
| `tests/touch/virtual-touch.py` | virtual touchscreen for end-to-end tests |
| `tests/touch/virtual-hover.py` | hover a spot with a virtual mouse and screenshot the tooltip (`hyprctl dispatch movecursor` alone never starts a GTK tooltip) |
| `dotfiles/local-bin/waybar-clock` | the bar clock (`custom/clock`): time, calendar tooltip, zone table with DST on/off |

State: `~/.config/waybar/touch-mode.jsonc` (touch mode) and
`~/.config/bar-touch/mouse-mode` (mouse mode). Logs: `journalctl --user -u bar-touch`.

## Adding a module to the bar

Example (2026-10-31): `custom/read-aloud`, the Computer's read-aloud toggle. Its script and
user unit live in the sister repo `~/Programs/star-trek-computer` (run its `install.sh`); only
the module entry, its `"touch"` card and the on/off/down CSS live here. Without that repo the
module shows nothing (waybar tolerates a missing exec).

Give it `"on-click": "~/.local/bin/bar-touch click <module-key>"` and a
`"touch"` object: `title`, `about`, `click` (the real command), optional
`state` (shell command; custom modules default to their own `exec` JSON), and
labels `click-label`, `right-label`, `middle-label`, `scroll-up-label`,
`scroll-down-label`. Right/middle/scroll commands stay in the normal waybar
keys; the card reads them from there.

Since 2026-11-03 (his picks: "the ui buttons are too large", and the voice card's
"Right-click: Restart voice typing" was the wrong text): card buttons are ~34 px with 13 px
text (the primary button, e.g. ● Start recording, stays 60 px), and the right-click action is
no longer a full-width "Right-click: …" button but a small chip in the title row beside ✕,
named by what it does: `"right-chip"` (short, e.g. "↻ Restart", "Time zone"), else
`right-label`. Every module with an `on-click-right` has a `right-chip`.

`"actions": [{"label", "cmd"}]` add one button each. With `"state-cmd"` instead of a label
the button's text comes from that command: `{"label", "active", "loading"}` JSON (or one plain
line). `active` highlights it green (`.bt-on`); `loading` makes it pulse yellow (one class flip
per 0.8 s, no CSS animation) and re-read `state-cmd` every 1.6 s until `loading` is false, only
while the card is open. A tap runs `cmd` and re-reads it in place; the card stays open. Voice
typing's "Source:" button: `voice-stt-provider label` (loading = local Whisper models still
loading, or Deepgram not reached yet).

A module can set `"tap-card": true`: a tap (or mouse click) only opens the
long-press card; the card's first button runs `click`. `"click-labels"` and
`"status-labels"` (`{class: text, "default": text}`) make that button's text and
a headline follow the module's live JSON `class`. Voice typing (2026-09-25):
tap the icon -> card "Ready." + **● Start recording**; tap it again while
recording -> "Recording — speak now" + **■ Stop recording and type**. The card
closes when a button is pressed, so it is gone before the text is typed;
Super + ` still starts/stops directly. The bar shows no red icon, underline or
level dots while recording: the mic OSD at the bottom is the indicator.

Voice typing was also returning empty text whenever the FiiO BR13 was
connected: it offers only A2DP (no mic), yet both `hyprwhspr-toggle` and the
patched hyprwhspr `main.py` waited for its mic profile (2.5 s + 1.5 s), so
capture began ~5 s late ("Pipeline: 0ms audio"). Both now wait / switch only
when the Bluetooth device has a `headset-*` profile.

**Text goes to the window where the recording started** (2026-09-27, the
user's choice "Where I started", after text landed in the wrong window because
focus moved while he spoke: a tap on the bar, another window, a popup).
- `hyprwhspr-toggle` (start branch only, both Super + ` and the card button)
  writes the focused window to `~/.config/hyprwhspr/target_window` (JSON:
  address, class, title, workspace, source) before sending `start`. If
  `HYPRWHSPR_TARGET_WINDOW=<address>` is set and that window still exists, it
  wins over the active window.
- bar-touch sets that variable for modules whose `"touch"` object has
  `"pass-target-window": true` (only `custom/hyprwhspr`): it reads the active
  window when the card opens (or on a direct tap/click) and passes it in the
  env of the action, so a touch on the card that refocuses a window under it
  cannot change the target. Journal: `custom/hyprwhspr: target window ...`.
- The hyprwhspr patch (`local-lib/hyprwhspr-patch/main.py`) snapshots the file
  when recording starts (a missing or >30 s old file -> it asks Hyprland for the
  active window itself), and wraps `_inject_text`: just before typing it runs
  `hyprctl dispatch focuswindow address:<addr>`, polls `activewindow` for up to
  300 ms, then pastes. Window closed meanwhile -> types where focus is. The file
  is deleted after typing (and on a muted cancel). The mic OSD is still hidden
  in `_stop_recording`, before any of this.
- One journal line per dictation (`journalctl --user -u hyprwhspr | grep TARGET`):
  `[TARGET] start=<class/title> now=<class/title> → refocused | already focused |
  start window is gone, typing where focus is | refocus not confirmed ...`.
- A target on another workspace is brought forward (Hyprland switches to it).
- Tests (2026-09-29): fake-injector unit test (restore before inject, file
  deleted, injection still happens if hyprctl fails, 300 ms bound); live test
  with two throwaway ghostty windows on workspace 19 (focus B, restore -> A in
  70 ms; closed A -> "gone"); the env pass-through with test modules.

A module can set `"links": [{"label": "...", "url": "..."}]` in its `"touch"`
object: each becomes a card button (`↗ label`) that hides the card and opens the
URL with `xdg-open` (added 2026-09-25). Voice typing uses it for **Fix wrong
words / words to concentrate on** -> `http://127.0.0.1:8771/`, the voice-labels
web app (`omarchy-voice-typing/stt/webapp`, user unit `voice-labels.service`).

A module can set `"mic-picker": true` in its `"touch"` object: the card gets a
**Microphone** list (added 2026-09-30, "one of the icons should change the
default mic… the one that shows mic"). Voice typing (the mic icon) has it. Each
row is a real input (`pactl -f json list sources`, minus speaker monitors and
ports reporting "not available", e.g. the empty headphone-jack mic); the default
is `● bold`. A tap runs `pactl set-default-source <name>` and redraws the list,
leaving the card open. hyprwhspr has no `audio_device` in its config and opens a
fresh stream on ALSA `default` (PipeWire's default source) per recording, so the
change applies from the next recording; no restart needed. Picking a Bluetooth
headset mic makes the headset switch to its call profile (lower playback quality)
while it records.

A module can set `"popup": "volume" | "wifi" | "bluetooth"` in its `"touch"` object: a tap or a
mouse click then opens the daemon's built-in popup (no `click` needed) (added 2026-09-25
after "the volume icon is not touch responsive": its tap opened wiremix, a
keyboard-driven terminal mixer).

## How a tap is told from a long press

The daemon reads the touchscreen itself (passively, unless mouse mode is on).
Waybar fires `on-click` ~6 ms after finger-down (measured), so when the click
request arrives the finger is still down: the daemon waits. Lift before 0.5 s
= tap (run the action, then popup); still down at 0.5 s = card. A click with no
finger on the glass = mouse = run immediately.

## Mouse mode

The daemon grabs the touchscreen (EVIOCGRAB) and injects pointer input:
`hyprctl dispatch movecursor` for the arrow plus a uinput mouse
(`bar-touch-mouse`) for the buttons. Tap = left click at the finger; long press
(0.5 s, <14 px of movement) = right click; drag = left drag; two fingers moved
up >110 px = overview (tap a tile to switch to that window, tap empty space or
Esc to close). On the bar itself a touch holds the left button until lift, so
bar taps and long presses work the same in both modes. If the daemon dies the
kernel drops the grab and the touchscreen is normal again.

## Tested (2026-09-24, laptop, virtual touchscreen + screenshots)

- TOCH 2x2 renders; lit when on, dim when off. TOCH centre 156-157 px from the
  "1" centre in both modes (1 inch = 157 px on this 1920 px / 310 mm panel).
- Finger tap on memory: popup with RAM state under the widget.
- Finger tap on TOCH: popup "Touch mode ON -> Touch mode OFF", bar shrank.
- Long press on the hand and on the clock: cards (the clock card shows `cal`).
- Mouse path (no finger): kbd-backlight keep-on toggled on then off.
- Mouse mode: tap -> left click and long press -> right click on a logging test
  bar; two-finger swipe up -> overview of all 5 windows; tap on empty space
  closed it.

## Bugs found on the way (fixed)

- **Deadlock**: the touchscreen watch ran at `GLib.PRIORITY_HIGH`. GLib then
  dispatched it while GDK's Wayland source still held a prepared read, and
  creating the overview window from it hung forever in `wl_display_roundtrip`
  (main thread in `futex_do_wait` inside `GtkLayerShell.init_for_window`). In
  mouse mode that left the touchscreen grabbed by a hung process. Fix: DEFAULT
  priority, and windows are created from idle callbacks. `kill -USR1 <pid>`
  dumps every thread's Python stack to the journal (faulthandler).
- Layer-shell margins count from the bar's exclusive zone, not the screen
  edge: popups use a 6 px top margin, not bar height + 6.
- `gi` must pin `Gdk 3.0` explicitly or it loads Gdk 4 and GTK 3 fails.

- **Stuck touch session (2026-09-25)**: a touchscreen that disappears
  mid-touch never sends its lift. `drop()` left its session open and `frame()`
  ignores other devices while a session is open, so every real tap was judged
  "mouse" (no cards, no popups), and with mouse mode on the grabbed screen was
  dead. Triggered by the virtual test screen being removed while the daemon
  lagged under load. Fix: `drop()` ends that device's session; a touch on
  another device replaces a session idle for 3 s. Neither fires in normal use
  on one screen (long holds and drags are untouched). Symptom check:
  `bar-touch status` shows `"touching": true` with no finger down.

- **Touch-dead waybar (2026-10-02)**: one finger-lift that never reaches
  waybar leaves a stale touch in GTK3's seat table, and GTK3 then stops turning
  taps into clicks for the life of the process (mouse still works; SIGUSR2 does
  not help). The daemon counts bar taps waybar never answers (2 on one spot or
  3 anywhere in 30 s, workspace switches count as answered) and runs
  `restart-waybar` with a notification. Repro: `tests/touch/stale-touch-repro.py`.
  Write-up: `docs/issues/waybar-ignores-touch-stale-touch-2026-10-02.md`.

- **Walker menus by finger (2026-10-11)**: walker keeps its list untargetable
  until the pointer moves twice, so taps on power-menu / omarchy-menu entries did
  nothing. On `openlayer>>walker` the daemon wiggles its uinput mouse 1 px (the
  cursor only moves, to the monitor's left edge, if the menu was opened by finger
  and the cursor sits over it or on another monitor); a first tap on an unprimed
  menu is replayed as a click. Test: `tests/touch/walker-tap.py`.
  Write-up: `docs/issues/walker-menu-ignores-touch-2026-10-11.md`.

## Known limits

- Workspace buttons and tray icons have no popup or card (built into waybar).
- The overview lists windows with app icons, not live thumbnails.
- The 1 inch is calibrated for the laptop panel; on an external monitor the
  same pixels are a different physical distance.
- Rotated screens: coordinates handle transform 0 and 2 (what `screen-flip`
  uses); 90/270 are not mapped.

## Popup policy (2026-09-25, "popup texts are redundant and get in the way")

- Tap that opens something (state unchanged): **no popup** — the new window is
  the feedback.
- Tap that changes state, or a display-only module: **one line** under the
  finger ("Title · state", or just the state when it already starts with the
  title), 1.5 s, and its input region is empty so taps pass straight through.
- `"toast": false` in a module's `"touch"` object silences it (the clock: its
  tap already flips the date on the bar).
- The Wi-Fi / Bluetooth lists no longer carry "tap a … to …" hint lines.
- Clock calendar: the hover tooltip is `xx-large`; the long-press card shows
  the calendar `x-large` (`"big-state": true`).

## Handover (session closed at the 400k context line, 2026-09-25 01:4x IST)

State: all work committed in local-bootstrapping (not pushed). Service
`bar-touch` running, mouse mode off, touch mode on (the user's choice).

Verified by virtual touchscreen + screenshots: tap popups, long-press cards,
mouse mode clicks + overview, volume / Wi-Fi / Bluetooth popups render with
live data, one-line toast, big calendar tooltip.

Not verified: Wi-Fi join, Bluetooth connect/disconnect/power (deliberately not
exercised on the live system), mouse-mode drag, everything with real fingers.

Gotchas for the next session:
- The user tests the bar live while you work; virtual taps land on the real
  bar. Prefer a bottom test bar (`include` the real config, override one
  module's `on-click` with a logger) or `BAR_TOUCH_DEVICES` for mouse mode.
- `bar-touch` source contains literal "…" "·" "↓" characters, not `\u`
  escapes: match them literally when patching.
- Daemon log: `journalctl --user -u bar-touch` (every click verdict + tap).

## Clock: "DST on/off" beside New York (done 2026-09-25)

Asked 2026-09-25 01:4x: beside the New York time in the clock tooltip, write
whether daylight saving is on ("I know EST and EDT tell that, but still").

Waybar's built-in clock cannot (checked `man 5 waybar-clock`): extra zones come
only from `{tz_list}`, one shared `timezone-tooltip-format` for every zone, and
fmt chrono has `%Z`/`%z` but no DST flag. So `clock` became `custom/clock`,
backed by `waybar-clock run`: a continuous script (no `interval`, one JSON line
per second, no process per tick; `restart-interval: 2` if it dies).

- Bar text as before: `Fri Sep 25 01:52:02`, neon-green time; tap flips to
  `25 September W39 2026` (state in `$XDG_RUNTIME_DIR/waybar-clock/`).
- Tooltip as before (month calendar, ISO weeks, today underlined green, zone
  table) plus a note column: `local` on the system zone, and **`DST on`**
  (yellow) / `DST off` on any zone whose offset differs between January and
  July, i.e. New York today. IST and UTC get none.
- Scroll up/down = next/previous month, middle-click = back to this month
  (new; the card offers it as a button).
- Right-click = `omarchy-tz-select` as before; the local zone is re-read from
  `/etc/localtime` every tick, so a change shows without a restart.
- Long-press card: full date + the same calendar and zone table
  (`waybar-clock card`), `big-state`. A long press no longer flips the date:
  the flip is now bar-touch's tap action, not waybar's `format-alt`.
- `toggle` / `shift` SIGUSR1 every `waybar-clock run` (one per bar), matched on
  exact argv: `pkill -f "waybar-clock run"` would also kill any shell whose
  command line contains those words.

Verified (laptop, screenshots): bar text unchanged; hover tooltip identical to
the built-in one plus `DST on` beside EDT; mouse click via `bar-touch click`
flips to the date and back at once; scroll shows October without the today
mark; DST flips at 2026-03-08 07:00 UTC and 2026-11-01 06:00 UTC (script
test). A virtual long press opened the card with the new labels; its state
text was still "Reading state…" when screenshotted under heavy load (load 6,
96 °C) and later presses were judged "mouse" (waybar's click arrived ~1.8 s
after finger-down), so the card's filled-in state is not yet seen on screen.
`waybar-clock card` returns valid Pango markup in 58 ms.

## Touch-native audit (2026-09-30)

His rule (binding, see `CLAUDE.md` §"Touch-Native Rule"): every request, once
done, must work by finger alone. Audit of the requests from 09-27 to 09-30:

| Commit | Request | Touch path | Status |
|---|---|---|---|
| VDI UI 11-01 | VDI intro screen, control bar over the stream, Moon icon (docs/vdi.md) | Moon tap = intro screen / hide / show; every tile, card and chip ≥ 44 px; the bar's "VDI" tab reveals on a finger; min fps, route, release, close all buttons | ok (virtual-touch tap on the tab verified) |
| no-drift 09-30 | drift the sync cannot fix opens a Claude agent | amber sync icon (custom/lb-drift) appears with the agent; tap = reopen/focus the agent, long press = card with the drift list (a mako notification only dismisses on touch) | ok |
| `a6f3429` 09-27 | Super+W closes windows in reverse opening order | overview tile ✕ (grid icon); the focused window goes through the same `hypr-close-ordered` | **gap, fixed 09-30** |
| `846de24` 09-30 | Alt+Tab in MRU order across the current desktop | overview tiles sorted the same way (current desktop first, then MRU); the grid icon opens it in any mode, not only mouse mode | **gap, fixed 09-30** |
| `ccb4025` 09-29 | pin the touchscreen to eDP-1 | touch itself | ok |
| `24e1249` 09-29 | voice typing types into the window where it started | bar tap on the mic card is the main path | ok |
| `506e4aa` 09-29 | power profile: tap switches instantly | tap | ok |
| 11-01 | power profile button resident in RAM | tap (instant dimmed colour), long-press card via `state` | ok |
| `14ba312` 09-29 | design skill: both light and dark modes | web UIs; the pre-flight now also has a touch-native line | ok, extended |
| `82a14a6` 09-30 | the mic icon changes the default mic | Microphone list in the mic card, tap to pick | ok (built touch-first) |

Also checked: all 38 bar modules; every right/middle/scroll action already
appears as a card button, and only the workspace numbers skip `bar-touch`
(waybar switches them natively on tap).

Verified 09-30: the grid icon renders at touch size (before/after screenshots);
`bar-touch overview` drew 18 tiles with the current desktop's windows first,
the focused one outlined, each with a 48 px ✕; `dispatch closewindow
address:…` (the string the ✕ sends) closed a throwaway window on workspace 19.
Not yet done: a ✕ tap driven through `tests/touch/virtual-touch.py`.

## Power profile: the button lives in RAM (2026-11-01)

His words: "power mode button needs to be upgraded. Its process should live in
the RAM, so that the button is responsive, that process can concur with the
params in the disk at times efficiently." Design and risks:
`docs/issues/power-button-ram-resident-risk-analysis.md`.

- `power-profile-daemon` (user unit, `MemorySwapMax=0`) holds the state and
  sends waybar signal 10 on every change; the module's exec is
  `power-profile-daemon state` (answers from RAM, `interval` 30 as a backstop).
  A streaming `watch` exec was tried first and dropped: waybar 0.15 never
  restarted it after a SIGUSR2 reload (a forked child aborted before exec).
  Reload waybar with `kill -USR2 <main pid>`: `pkill` also hits forks that have
  not exec'd yet, and those abort (36 zombies + SIGABRT cores, 10-30..11-01).
- Tap (finger or mouse) -> `bar-touch` -> `power-profile-daemon toggle` -> the
  icon takes the next colour at once, **dimmed** while power-profiles-daemon
  has not confirmed, with `…` after 0.5 s (pattern, not only shade).
- Long press = card; the card reads `touch.state` (`power-profile-daemon
  state`, `"state-json": true`), because the streaming exec never exits.
- Nothing on the tap path writes to btrfs: override flag in /tmp, TOGGLE log
  rows in `/run/user/1000/power-profile-spool.csv`, drained into
  `~/logs/power-profile-watchdog.log` by the per-minute watchdog.
- Daemon dead: `state` runs `power-profile-monitor status` and `toggle` runs
  `power-profile-monitor toggle`; it falls back ONLY when the
  socket cannot be connected (a slow reply is never a second toggle; the same
  fix is in `bar-touch send()` for every module).
- Debug: `power-profile-daemon debug` (state + in-RAM event ring);
  `power-profile-daemon dryrun 60` makes taps show but never reach ppd (tests);
  latency: `scripts/diagnostics/power-button-latency-probe.py old|new`.

## Battery: informative icon, tooltip and panel (2026-09-30)

His words: "I think it just did the bare minimum and there was no taste to its
work. Can you please make sure to introduce whatever you can so that it's very
informative about the state of battery, its drainage, charging, charging
status, etc. And also when I hover over it, the text that I see should be more
informative as well."

Before: built-in `battery` module, tooltip `{capacity}% {power}W`, tap ran the
power menu with a one-line toast. Now `custom/battery`, fed by
`dotfiles/local-bin/battery-info` (one source for the icon, tooltip, panel):

- **Net flow is measured**, not read: a least-squares fit of `energy_now` over
  10 min (own samples in `$XDG_RUNTIME_DIR/battery-info.samples`, seeded from
  battery-guard's per-minute history). The EC reports `power_now = 0` whenever
  the status is "Not charging", and with a weak charger the status flips
  Charging <-> Not charging every few minutes, so neither is trustworthy.
- **States**: on battery / charging / plugged in but draining (`ac-drain`) /
  plugged, not charging / held by the charge limit / full. Icon: bolt glyphs
  while charging; amber for ac-drain and <=20% on battery, red <=10%.
- **Charger rating** comes from the PD source capabilities the charger
  advertises (`/sys/class/typec/port*-partner/pd*/source-capabilities`), e.g.
  "USB-C PD, up to 65 W (20 V × 3.25 A)". Never from the ucsi supply's
  `voltage_now`: it read 5 V while a 65 W charger fed the battery 27 W.
- **Forecasts**: battery-guard's limits read live from the script defaults and
  `~/.config/battery-guard.conf` (2026-10-06: suspend at 25%, again at 12%, last
  resort hibernate at 8%), then empty at **4%** ("4% is the new zero" — his words
  2026-10-06, the old battery falls off a cliff below it), or full; clock times
  included. The Guard row adds "last resort: hibernate at 8%" when `LAST_RESORT`
  is not `none`; the panel's charge bar gets a third tick for it.
- **Guard / Last sleep** (2026-10-03): "guard timer active" comes from
  `systemctl --user is-active battery-guard.timer`, not from the script existing;
  "Last sleep: OK 14:47 (power-button)" or "FAILED 01:47 — ioq-0 stuck in FUSE;
  laptop stayed ON" comes from sleep-verified's `last.json`. Both in the tooltip
  and the panel.
- **Tooltip**: headline + why, flow, forecasts, since when, charger, energy,
  health (83% of 50.5 Wh, 970 cycles), guard, profile, a 6 h sparkline.
- **Panel** (`BatteryPopup` in bar-touch, tap or click; refreshes every 5 s,
  closes after 60 s idle): charge bar with guard ticks, the facts above, a
  1 h / 6 h / 24 h history chart with a dashed forecast (charging = diagonal
  hatch, plugged-not-charging = vertical stripes, so not hue-only), power
  profile buttons (`power-profile-monitor set <profile>`, new), power menu.
- Desktop (no BAT0): the module prints empty text and waybar hides it.

Verified on the laptop (screenshots in `docs/screenshots/battery-panel/`):
bar icon, hover tooltip (`tests/touch/virtual-hover.py`), panel in all three
spans, span buttons / ✕ / a profile button clicked with a virtual mouse, the
long-press card, and state logic over 11 faked scenarios. The span buttons
did NOT respond to `tests/touch/virtual-touch.py` taps, and neither did ✕ on
this panel: button taps inside any popup via the virtual touchscreen are
unverified (known gap, see the audit above). Real-finger taps are untested.

## mpv history (2026-10-03)

His words: "a top bar icon, complete with touch support … which is able to show
the history of mpv player … buttons to open their folder location in thunar, when
I touch on their thumbnail, they preview play at 20X speed. When I hover over it,
just show a list of video filenames, and the length of them."

`custom/mpv-history` (film icon, right of the clipboard). Hover = filenames +
lengths only. Tap or click = `MpvHistoryPopup` (`"popup": "mpv-history"`): a row
per recently watched file with a thumbnail (tap = muted 20x preview inside it,
tap again = stop), progress, **Resume/Play** and **Folder** (Thunar, file
selected), greyed rows for missing files, and a filter box. Only files mpv
itself played are listed (his words 2026-10-03: "strictly list whatever was
played by me"); the icon is the VLC-style cone, on the LEFT of the bar. Data: the mpv script
`dotfiles/mpv/scripts/mpv-history.lua` → `~/.local/state/mpv-history/history.jsonl`,
read by `dotfiles/local-bin/mpv-history`. Full write-up: `docs/mpv-history.md`.

The three bar gestures, aligned 2026-10-03 after "make the touch bar icon
compatible with the other touch bar functionality like what it shows when we
hover over it … a tap from a finger versus … a long press": **hover** = the brief
tooltip (filenames + lengths, his earlier ask); **tap or click** = the panel;
**long press** = the card with the FULL state (`mpv-history card`: per video how
far he got, when, how many plays, "Playing now") and one button per action:
Tap = open the panel, Right-click = `mpv-history open last` (resume the newest),
Middle-click = `mpv-history folder last`. The same two commands are the module's
`on-click-right` / `on-click-middle` for a mouse. Screenshot:
`docs/screenshots/mpv-history/card-long-press-20261003.png`.

Verified 2026-10-03 with `tests/touch/virtual-touch.py` on a test daemon: a
virtual finger tap on the thumbnail started the preview (two crops 1 s apart
showed `×20 04:55` then `×20 05:15`), a second tap stopped it, and a tap on
Folder opened Thunar on the folder with the file selected. So button taps
inside a bar-touch popup DO work through the virtual touchscreen when the
coordinates are monitor-local (see the battery note above).

## On-screen keyboard (2026-10-03)

His words: "There is also an on-screen keyboard missing … An icon which activates
it and it should pop up from the bottom of the screen. And we should be able to use
just the touch screen to type on it. It should have toggle for switching between
the keyboard layouts which are already present … integrate the on-screen keyboard
… on the right hand side into the same top bar icon which controls the layout
switch … make sure it follows the UX or design language of the overall top bar
where hovering has a specific behavior and long press has a specific behavior and
a tap has a specific behavior."

The layout icon (`hyprland/language`, "US" / "DV", right side) now carries it:

| Gesture | What happens |
|---|---|
| hover (mouse) | waybar's tooltip: `Keyboard: English (Dvorak)` |
| tap or click | `KeyboardPopup` (`"popup": "keyboard"`): a full keyboard along the bottom edge; tap the icon again, or its **⌨ ▾ hide** key, to put it away |
| long press | card: what it is, `Layout: … / On-screen keyboard: shown|hidden`, **Tap: Show / hide the on-screen keyboard**, **Right-click: Switch layout** |
| right-click (mouse) | `hyprctl switchxkblayout all next` (touch twin = the card button and the keyboard's layout key) |

How it works (`dotfiles/local-bin/bar-touch`, class `KeyboardPopup`):

- A gtk-layer-shell window anchored to the BOTTOM with an auto exclusive zone, so
  the windows above shrink instead of hiding under it (the test terminal went
  from 1030 px to 690 px tall and back). Keyboard mode NONE: the window he was
  typing in keeps focus. `layerrule = animation slide bottom` for the namespace
  `bar-touch-keyboard` (`dotfiles/hypr/layerrules-bar-touch.conf`) makes it
  rise from the bottom instead of fading.
- Keys are sent through a uinput keyboard, `bar-touch-keyboard`, created when
  the daemon starts; Hyprland treats it like a plugged-in keyboard and applies
  the active xkb layout, so a keycode types what that layout says. The keycaps
  are therefore labelled per layout from libxkbcommon's own compiler
  (`xkbcli compile-keymap --layout us --variant dvorak`, parsed for keycode →
  level-1/level-2 keysyms); QWERTY fallback if xkbcli is missing.
- The **layout key** (big "DV" / "US", shows the next one) runs
  `hyprctl switchxkblayout all <index>` so the physical keyboard, the bar icon
  and the keycaps always agree; the layouts come from `input:kb_layout` /
  `input:kb_variant` (here `us,us` + `dvorak,`), nothing is hard-coded.
- Shift / Ctrl / Alt / Super: tap = held for the next key (○), tap again =
  locked (●), again = off. Caps shows ●. Keys: full ANSI rows, Esc, Tab, Enter,
  Backspace, Del, Home/End, PgUp/PgDn, arrows; every key ≥ 58 px tall.
- Persistent: touches outside it, cards and other popups leave it up (a tap in
  the text field must not close it). Hiding releases any held modifier.

Verified 2026-10-03 (laptop, `tests/touch/virtual-touch.py`, screenshots in
`docs/screenshots/on-screen-keyboard/`): finger tap on the icon → keyboard up with
Dvorak keycaps; taps on h, i, Enter typed `hi` into a `cat` terminal; Shift then a
→ `A` (one-shot latch released after); a touch in the terminal left the keyboard
up; the layout key switched all three keyboards (laptop, fcitx5, ours) to
English (US) and relabelled the keys (the same physical key then typed `j`, as its
keycap said); tap again → Dvorak; the hide key and a second icon tap both closed
it; a 0.9 s press opened the card; `bar-touch click hyprland/language` without a
finger (mouse) toggled it too.

## Bluetooth codec in the Volume panel (2026-10-25)

His FiiO BR13 came up on SBC after a re-pair ("Most devices show AAC, can you do
something about it?"), and he chose the Volume panel for the control once it was
clear the codec is a sound-system setting, not a Bluetooth one: pairing and the
link belong to BlueZ; the codec is negotiated when WirePlumber opens the A2DP
audio stream on top of that link. Switching = `pactl set-card-profile
bluez_card.<addr> <a2dp-sink-…>`; the device stays "Connected: yes" throughout,
audio pauses ~1 s, and WirePlumber stores the choice per card
(`~/.local/state/wireplumber/default-profile`), so it survives reconnects.

- Every `bluez_output.*` row in Output carries ` · <codec>` (read from the card's
  active A2DP profile; `headset (mic)` when on HFP).
- Under the selected Bluetooth output: a dim "Codec" label and the available
  A2DP codecs as buttons, four to a row, worst → best (SBC, SBC-XQ, AAC, aptX,
  aptX-LL, aptX HD, LDAC), the active one marked ●. A tap sets the profile, the
  header shows "→ <codec>…", and the panel redraws after 1.5 s.
- Data: `VolumePopup.bt_cards()` parses `pactl -f json list cards`; the codec
  name comes from the profile description "(A2DP Sink, codec X)"; profiles with
  `available: false` are left out. Only cards with more than one codec get the row.
