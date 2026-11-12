#!/usr/bin/env python3
"""
Patched hyprwhspr launcher.

Wraps the system hyprwhspr to add:
- MicOSD visual feedback during recording
- Fix 9: Mute detection grace period for BT codec init (prevents BT recordings
  from being silently killed during the 1-3s mSBC codec startup silence)
- Target window: text is typed into the window focused when recording STARTED
- No recording is ever lost (voice_safety.py, 2026-09-30): spool to disk while
  recording, network sends off the audio lock, send watchdog, batch rescue
"""

import json
import subprocess
import sys
import threading
import time
from pathlib import Path

# Add system hyprwhspr to path so we can import from it
sys.path.insert(0, '/usr/lib/hyprwhspr/lib')
sys.path.insert(0, '/usr/lib/hyprwhspr/lib/src')

import main as hyprwhspr_main

# No recording is ever lost (2026-09-30): client-side spool to disk, network
# sends off the audio lock, send watchdog, rescue by batch re-transcription.
import voice_safety
voice_safety.install(hyprwhspr_main.hyprwhsprApp, hyprwhspr_main.WhisperManager)

try:
    from mic_osd.runner import MicOSDRunner
    _mic_osd_available = True
except ImportError as e:
    print(f"[WARN] MicOSD not available: {e}", flush=True)
    _mic_osd_available = False
    MicOSDRunner = None

_original_init = hyprwhspr_main.hyprwhsprApp.__init__
_original_start_recording = hyprwhspr_main.hyprwhsprApp._start_recording
_original_stop_recording = hyprwhspr_main.hyprwhsprApp._stop_recording
_original_cancel_recording_muted = hyprwhspr_main.hyprwhsprApp._cancel_recording_muted
_original_cleanup = hyprwhspr_main.hyprwhsprApp._cleanup
_original_on_shortcut_triggered = hyprwhspr_main.hyprwhsprApp._on_shortcut_triggered
_original_inject_text = hyprwhspr_main.hyprwhsprApp._inject_text


# --- Stage 4: BT pre-flight state assertion ---
# Hyprland's Super+` binding spawns hyprwhspr-toggle (does BT A2DP→HFP switch with
# 1.5s sleep). The daemon's evdev hook ALSO fires _on_shortcut_triggered
# simultaneously and would call _start_recording immediately, before BT has
# finished switching profiles. The daemon's verify_and_play_sound() (500ms timeout)
# fails because the bluez_input source either doesn't exist yet (still A2DP) or is
# producing no audio (HFP codec still initializing). Net result: "Microphone
# disconnected" error within ~500ms of keypress.
#
# Fix: before _start_recording runs, wait until BT is in HFP profile and the source
# exists. Times out after 2.5s (toggle's switch is 1.5s + buffer). If no BT card
# present, returns immediately. If timeout reached, proceeds anyway (falls back to
# whatever default source is set, usually internal mic).

def _read_bt_state():
    """Returns (has_bt, profile, source_exists) — fast snapshot via pactl."""
    try:
        cards_short = subprocess.check_output(
            ['pactl', 'list', 'cards', 'short'], text=True, timeout=1
        )
        if 'bluez' not in cards_short:
            return (False, None, False)

        cards = subprocess.check_output(['pactl', 'list', 'cards'], text=True, timeout=1)
        in_bluez = False
        profile = None
        has_mic = False
        for line in cards.splitlines():
            if line.startswith('Card #'):
                in_bluez = False
            if 'Name: bluez_card' in line:
                in_bluez = True
            elif in_bluez and line.strip().startswith('headset-') and 'available: yes' in line:
                has_mic = True   # the device offers a mic (HFP/HSP) profile
            elif in_bluez and 'Active Profile:' in line and profile is None:
                profile = line.split('Active Profile:')[1].strip()
        # A playback-only BT device (e.g. FiiO BR13: A2DP profiles only) has no
        # mic to wait for: record from the laptop mic at once. Waiting 2.5 s for
        # a source that can never appear ate the start of every recording and
        # left them empty (2026-09-25).
        if not has_mic:
            return (False, profile, False)

        sources = subprocess.check_output(
            ['pactl', 'list', 'sources', 'short'], text=True, timeout=1
        )
        source_exists = any(line.startswith('bluez_input') or '\tbluez_input' in line
                            for line in sources.splitlines())
        # simpler: just check if 'bluez_input' is anywhere
        source_exists = 'bluez_input' in sources

        return (True, profile, source_exists)
    except Exception:
        return (False, None, False)


def _wait_for_bt_mic_ready(timeout=2.5):
    """Wait until BT card is in HFP profile AND a bluez_input source exists.

    The hyprwhspr-toggle script switches the profile; we just wait for the result.
    If no BT card exists, returns immediately (laptop mic path).
    Returns True on success, False on timeout.
    """
    has_bt, profile, source = _read_bt_state()
    if not has_bt:
        return True  # no BT, internal mic path

    # If already in HFP with a source, no wait needed
    if profile and profile.startswith('headset-') and source:
        return True

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.05)
        _, profile, source = _read_bt_state()
        if profile and profile.startswith('headset-') and source:
            elapsed = timeout - (deadline - time.monotonic())
            print(f"[BT-WAIT] HFP source ready after {elapsed:.2f}s", flush=True)
            return True

    print(f"[BT-WAIT] Timeout {timeout}s — profile={profile} source={source} — proceeding", flush=True)
    return False


# --- Mic guard: never record from something that is not a microphone ---
# hyprwhspr records from the PipeWire default source. Twice that default was not
# a microphone and every recording came back empty with no error:
#   2026-01-14/18 desktop: default source = bluez_output.<Auto 12>.monitor — the
#     BT speaker's playback loopback. The user: "I want you to make it such that
#     'Auto 12' never is assigned a mic. Because that device does not have one."
#     (fixed then with a per-MAC WirePlumber rule, 51-disable-bt-speaker-monitor)
#   2026-04-04 desktop (FiiO BR13): "i want jabra to used as mic. and fiio is
#     just a speaker"
# The per-MAC rule only covers one speaker. This check covers every device: just
# before capture starts, if the default source is a monitor, a null sink, or
# gone, point it at a real microphone (a BT headset input if one exists, else
# the built-in mic). A real mic that is already the default is never touched.

def _pick_real_mic(default, sources):
    """Return the source to switch to, or None to leave the default alone.

    default: name from `pactl get-default-source`; sources: names from
    `pactl list sources short`. Pure function so it can be tested offline.
    """
    def is_mic(name):
        return (not name.endswith('.monitor')
                and not name.startswith('auto_null'))

    if default in sources and is_mic(default):
        return None
    mics = [s for s in sources if is_mic(s)]
    for prefer in (lambda s: s.startswith('bluez_input.'),
                   lambda s: s.startswith('alsa_input.') and 'Mic1' in s,
                   lambda s: s.startswith('alsa_input.')):
        for s in mics:
            if prefer(s):
                return s
    return mics[0] if mics else None


def _ensure_real_mic_default():
    try:
        default = subprocess.check_output(
            ['pactl', 'get-default-source'], text=True, timeout=1).strip()
        sources = [line.split('\t')[1] for line in subprocess.check_output(
            ['pactl', 'list', 'sources', 'short'], text=True, timeout=1
        ).splitlines() if '\t' in line]
        target = _pick_real_mic(default, sources)
        if target is None:
            if default not in sources or not sources:
                print(f"[MIC-GUARD] default source '{default}' is not a mic and no mic exists", flush=True)
            return
        subprocess.run(['pactl', 'set-default-source', target], timeout=1, check=False)
        print(f"[MIC-GUARD] default source '{default}' is not a mic — switched to '{target}'", flush=True)
    except Exception as e:
        print(f"[MIC-GUARD] check failed: {e}", flush=True)


# --- Target window: type where the recording STARTED ---
# 2026-09-27 the text landed in the wrong window: while speaking, the user had
# tapped the bar / another window / a popup, and ydotool pastes into whatever
# has focus at the end. His choice: "Where I started". hyprwhspr-toggle writes
# the window focused at START to ~/.config/hyprwhspr/target_window (bar-touch
# passes the window that was active when its card opened, so a touch on the
# card cannot change it). The daemon snapshots that file when recording starts
# (or asks Hyprland itself if the file is missing/stale) and, just before
# typing, refocuses that window and waits until Hyprland reports it active.
# If the window was closed meanwhile, the text goes where focus is (logged).

TARGET_FILE = Path.home() / '.config' / 'hyprwhspr' / 'target_window'
TARGET_FRESH_S = 30        # a file older than this at START is a leftover
REFOCUS_TIMEOUT_S = 0.3    # poll activewindow this long after focuswindow
REFOCUS_SETTLE_S = 0.05    # let the app take keyboard focus before the paste


def _hypr_json(what):
    """`hyprctl <what> -j` parsed, or None."""
    try:
        out = subprocess.check_output(['hyprctl', what, '-j'], text=True, timeout=1)
        return json.loads(out)
    except Exception:
        return None


def _hypr_dispatch(*args):
    try:
        subprocess.run(['hyprctl', 'dispatch', *args], capture_output=True, timeout=1, check=False)
    except Exception as e:
        print(f"[TARGET] dispatch {args} failed: {e}", flush=True)


def _describe_window(w):
    if not w or not w.get('address'):
        return 'nothing'
    title = (w.get('title') or '').replace('\n', ' ')
    if len(title) > 40:
        title = title[:39] + '…'
    return f"{w.get('class') or '?'}/{title}"


def _take_start_target(hypr=_hypr_json, now=time.time, target_file=TARGET_FILE):
    """Window to type into, decided at recording START.

    The toggle's file wins when fresh; otherwise ask Hyprland (e.g. a start that
    did not come through hyprwhspr-toggle)."""
    try:
        if target_file.exists() and now() - target_file.stat().st_mtime <= TARGET_FRESH_S:
            t = json.loads(target_file.read_text())
            if t.get('address'):
                return t
    except Exception as e:
        print(f"[TARGET] unreadable {target_file}: {e}", flush=True)
    w = hypr('activewindow') or {}
    if w.get('address') and w.get('class') != 'mic-osd':
        return {'address': w['address'], 'class': w.get('class'),
                'title': w.get('title'), 'source': 'daemon'}
    return None


def _restore_target_focus(target, hypr=_hypr_json, dispatch=_hypr_dispatch,
                          timeout=REFOCUS_TIMEOUT_S, sleep=time.sleep,
                          clock=time.monotonic):
    """Focus `target` before typing. Returns the decision:
    'no-target' | 'already' | 'refocused' | 'refocus-timeout' | 'gone'."""
    now_w = hypr('activewindow') or {}
    start_s, now_s = _describe_window(target), _describe_window(now_w)
    if not target or not target.get('address'):
        decision = 'no-target'
        print(f"[TARGET] start=unknown now={now_s} → typing where focus is", flush=True)
        return decision
    addr = target['address']
    if now_w.get('address') == addr:
        print(f"[TARGET] start={start_s} now={now_s} → already focused", flush=True)
        return 'already'
    clients = hypr('clients') or []
    if not any(c.get('address') == addr for c in clients):
        print(f"[TARGET] start={start_s} now={now_s} → start window is gone, typing where focus is", flush=True)
        return 'gone'
    dispatch('focuswindow', f'address:{addr}')
    deadline = clock() + timeout
    while True:
        cur = hypr('activewindow') or {}
        if cur.get('address') == addr:
            sleep(REFOCUS_SETTLE_S)
            print(f"[TARGET] start={start_s} now={now_s} → refocused", flush=True)
            return 'refocused'
        if clock() >= deadline:
            print(f"[TARGET] start={start_s} now={now_s} → refocus not confirmed in "
                  f"{timeout*1000:.0f} ms (active={_describe_window(cur)}), typing anyway", flush=True)
            return 'refocus-timeout'
        sleep(0.02)


def _clear_target_file(target_file=TARGET_FILE):
    try:
        target_file.unlink()
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"[TARGET] could not delete {target_file}: {e}", flush=True)


def _patched_inject_text(self, text):
    """Refocus the START window, then inject. The MicOSD was already hidden in
    _stop_recording (a Wayland surface interferes with ydotool typing)."""
    target = getattr(self, '_voice_target', None)
    self._voice_target = None
    try:
        _restore_target_focus(target)
    except Exception as e:
        print(f"[TARGET] restore failed ({e}), typing where focus is", flush=True)
    _clear_target_file()
    _original_inject_text(self, text)


def _patched_on_shortcut_triggered(self):
    """Pre-flight BT readiness check before starting recording.

    BT codec init adds ~1.5-2s of inherent latency. Show MicOSD immediately so the
    user sees instant visual feedback even though audio capture is delayed.
    """
    if not self.is_recording:
        # Remember the window the text must go to (see "Target window" above)
        try:
            self._voice_target = _take_start_target()
            t = self._voice_target
            print(f"[TARGET] recording starts in {_describe_window(t)} "
                  f"{(t or {}).get('address', '')} (from {(t or {}).get('source', '-')})", flush=True)
        except Exception as e:
            self._voice_target = None
            print(f"[TARGET] could not read the start window: {e}", flush=True)
        # Show OSD immediately — masks BT init latency with instant visual feedback
        if hasattr(self, 'mic_osd_runner') and self.mic_osd_runner:
            try:
                self.mic_osd_runner.show()
            except Exception as e:
                print(f"[WARN] Failed to show MicOSD early: {e}", flush=True)
        # Wait for BT mic to be ready (toggle script handles profile switch)
        _wait_for_bt_mic_ready(timeout=2.5)
        # Record from a real microphone, never a monitor/null source
        _ensure_real_mic_default()
    # STOP path: no delay needed
    _original_on_shortcut_triggered(self)


# --- Fix 9: Mute detection grace period for BT codec init ---
# System _start_audio_level_monitoring (main.py:533+) fires _cancel_recording_muted
# after 1s of silence (samples_to_cancel=10 at 100ms). BT mSBC codec produces digital
# silence for 1-3s during HFP SCO link establishment, silently killing BT recordings
# before any real audio flows.
# Two-part fix:
#   1. Only arm the cancel counter AFTER first non-silent sample (codec is alive)
#   2. Extend threshold from 10 (1s) to 50 (5s) for brief speech pauses
# Preserves protection for "spoke then mic died" while tolerating BT init silence.

def _patched_start_audio_level_monitoring(self):
    if self.audio_level_thread and self.audio_level_thread.is_alive():
        return

    def monitor_audio_level():
        level_file = Path.home() / '.config' / 'hyprwhspr' / 'audio_level'
        level_file.parent.mkdir(parents=True, exist_ok=True)

        zero_samples = 0
        zero_threshold = 5e-7
        samples_to_cancel = 50
        speech_observed = False

        try:
            while self.is_recording:
                try:
                    level = self.audio_capture.get_audio_level()
                    with open(level_file, 'w') as f:
                        f.write(f'{level:.3f}')

                    raw_level = self.audio_capture.current_level
                    if raw_level >= zero_threshold:
                        if not speech_observed:
                            print("[MUTE-CHECK] First audio observed, mute detector armed", flush=True)
                        speech_observed = True
                        zero_samples = 0
                    elif speech_observed:
                        zero_samples += 1
                        if zero_samples >= samples_to_cancel:
                            print(f"[MUTE-CHECK] {samples_to_cancel/10:.0f}s silence after speech — canceling", flush=True)
                            self._cancel_recording_muted()
                            return
                except Exception:
                    pass
                time.sleep(0.1)
        finally:
            try:
                if level_file.exists():
                    level_file.unlink()
            except Exception:
                pass

    self.audio_level_thread = threading.Thread(target=monitor_audio_level, daemon=True)
    self.audio_level_thread.start()


def _start_recording_control_watcher(self):
    """Poll recording_control file as a fallback when evdev can't grab keyboards.

    The system daemon uses GlobalShortcuts (evdev) to capture Super+`. On this
    machine, the laptop builtin and BT keyboards are 'busy' (grabbed by Hyprland),
    so the daemon's evdev path produces no events. The hyprwhspr-toggle script
    (called by Hyprland's binding) writes 'start'/'stop' to recording_control —
    this watcher consumes those writes and fires _on_shortcut_triggered.
    """
    control_file = Path.home() / '.config' / 'hyprwhspr' / 'recording_control'

    def watcher():
        last_mtime = control_file.stat().st_mtime if control_file.exists() else 0.0

        while True:
            try:
                if control_file.exists():
                    mtime = control_file.stat().st_mtime
                    if mtime > last_mtime:
                        last_mtime = mtime
                        try:
                            action = control_file.read_text().strip().lower()
                        except Exception:
                            action = ""

                        if action == "start" and not self.is_recording:
                            print("[CONTROL] file → start", flush=True)
                            self._on_shortcut_triggered()
                        elif action == "stop" and self.is_recording:
                            print("[CONTROL] file → stop", flush=True)
                            self._stop_recording()
                time.sleep(0.1)
            except Exception as e:
                print(f"[CONTROL] watcher error: {e}", flush=True)
                time.sleep(0.5)

    t = threading.Thread(target=watcher, daemon=True, name='RecordingControlWatcher')
    t.start()
    print("[CONTROL] recording_control file watcher started", flush=True)


def _patched_init(self):
    _original_init(self)

    try:
        rc = getattr(self.whisper_manager, '_realtime_client', None)
        if rc is not None:
            voice_safety.STATE.rc = rc
            voice_safety._patch_realtime_client(type(rc))
        voice_safety.recover_pending_at_startup()
    except Exception as e:
        print(f"[SAFETY] init hook failed: {e}", flush=True)

    self.mic_osd_runner = None
    if _mic_osd_available and MicOSDRunner is not None:
        try:
            runner = MicOSDRunner()
            if runner.is_available():
                self.mic_osd_runner = runner
                print("[INFO] MicOSD visual feedback enabled", flush=True)
            else:
                reason = runner.get_unavailable_reason()
                print(f"[INFO] MicOSD not available: {reason}", flush=True)
        except Exception as e:
            print(f"[WARN] Failed to initialize MicOSD: {e}", flush=True)

    _start_recording_control_watcher(self)


def _patched_start_recording(self):
    if hasattr(self, 'mic_osd_runner') and self.mic_osd_runner:
        try:
            self.mic_osd_runner.show()
        except Exception as e:
            print(f"[WARN] Failed to show MicOSD: {e}", flush=True)

    if self.is_recording:          # upstream ignores a second start; so do we
        _original_start_recording(self)
        return
    try:
        voice_safety.STATE.begin(getattr(self.audio_capture, 'sample_rate', 16000))
    except Exception as e:
        print(f"[SAFETY] spool start failed (recording continues): {e}", flush=True)
    _original_start_recording(self)
    if not self.is_recording:      # start failed (mic missing/unstable)
        voice_safety.STATE.end('start-failed')


def _patched_stop_recording(self):
    if hasattr(self, 'mic_osd_runner') and self.mic_osd_runner:
        try:
            self.mic_osd_runner.hide()
        except Exception as e:
            print(f"[WARN] Failed to hide MicOSD: {e}", flush=True)

    try:
        _original_stop_recording(self)   # stops capture, transcribes, types
    finally:
        voice_safety.STATE.end('stopped')


def _patched_cancel_recording_muted(self):
    _original_cancel_recording_muted(self)
    voice_safety.STATE.end('canceled-muted')
    self._voice_target = None
    _clear_target_file()

    if hasattr(self, 'mic_osd_runner') and self.mic_osd_runner:
        try:
            self.mic_osd_runner.hide()
        except Exception:
            pass


def _patched_cleanup(self):
    try:
        voice_safety.STATE.end('shutdown')
    except Exception:
        pass
    if hasattr(self, 'mic_osd_runner') and self.mic_osd_runner:
        try:
            self.mic_osd_runner.stop()
        except Exception:
            pass

    _original_cleanup(self)


hyprwhspr_main.hyprwhsprApp.__init__ = _patched_init
hyprwhspr_main.hyprwhsprApp._start_recording = _patched_start_recording
hyprwhspr_main.hyprwhsprApp._stop_recording = _patched_stop_recording
hyprwhspr_main.hyprwhsprApp._cancel_recording_muted = _patched_cancel_recording_muted
hyprwhspr_main.hyprwhsprApp._cleanup = _patched_cleanup
hyprwhspr_main.hyprwhsprApp._start_audio_level_monitoring = _patched_start_audio_level_monitoring
hyprwhspr_main.hyprwhsprApp._on_shortcut_triggered = _patched_on_shortcut_triggered
hyprwhspr_main.hyprwhsprApp._inject_text = _patched_inject_text


if __name__ == "__main__":
    hyprwhspr_main.main()
