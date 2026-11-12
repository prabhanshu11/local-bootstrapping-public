"""
Voice typing safety net — no recording is ever lost (2026-09-30 incident).

Incident (omarchy-voice-typing/docs/issues/2026-09-30-voice-data-loss.md):
  * 02:18 the gateway stopped reading hyprwhspr's WebSocket (its Deepgram
    stream stalled). hyprwhspr gave up after 30 s: text gone, nothing on disk.
  * 02:24 next recording: upstream AudioCapture.audio_callback holds
    AudioCapture.lock while calling the streaming callback, which does a
    blocking ws.send(). The send never returned -> record thread, stop key and
    main thread all waited on that lock. Deadlock; the audio only existed in RAM
    (recovered from a core dump).

What this module adds (installed by hyprwhspr-patch/main.py):
  1. Spool: every audio chunk is queued (never blocks) to a writer thread that
     appends it to ~/Programs/recordings/client/<utc>_client.wav while recording.
     The WAV header is rewritten on each write, so the file is valid even if
     hyprwhspr is killed. A <stem>.json sidecar records status/source/pipeline.
  2. Sender: network sends happen on their own thread, never inside
     AudioCapture.lock. A stalled gateway can no longer freeze capture or stop.
  3. Send watchdog: any WebSocket send blocked longer than SEND_TIMEOUT_S gets
     its socket shut down (websocket-client then reconnects).
  4. Honest commit: the queued audio is drained before commit; if this
     recording's stream was interrupted (not connected, send stalled, drain
     timed out) no partial buffer is committed.
  5. Rescue: when no transcript comes back and the spool holds speech, the
     spool WAV is re-transcribed with Deepgram batch (voice-retranscribe) and
     the text goes through the normal typing path. If that fails too: critical
     notification naming the file + the command to retry.
  6. Startup: spool files left by a crash are recovered in the background
     (clipboard + notification).
"""

import json
import os
import queue
import socket
import subprocess
import threading
import time
import wave
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

SPOOL_DIR = Path(os.environ.get('VOICE_SPOOL_DIR', Path.home() / 'Programs' / 'recordings' / 'client'))
RETRANSCRIBE = Path(os.environ.get(
    'VOICE_RETRANSCRIBE', Path.home() / 'Programs' / 'omarchy-voice-typing' / 'scripts' / 'voice-retranscribe'))
SEND_TIMEOUT_S = float(os.environ.get('VOICE_SEND_TIMEOUT_S', 5.0))
DRAIN_TIMEOUT_S = 8.0
RESCUE_TIMEOUT_S = 25.0   # floor; see wait_for(): long clips get more
RESCUE_DEEPGRAM_S = 8.0   # the rescue's Deepgram try; then the laptop's Whisper
# 2026-11-04: offline, clips >= 25 s go to distil-large-v3 on the MX330 at ~1x
# real time (48.6 s took 71 s). A flat 30 s commit wait and a 25 s rescue gave up
# on text that was coming; scale both with the clip length.
WAIT_BASE_S = 20.0
WAIT_PER_AUDIO_S = 1.6


def wait_for(duration_s, floor):
    return max(floor, WAIT_BASE_S + WAIT_PER_AUDIO_S * (duration_s or 0.0))
SILENCE_RMS_I16 = 100.0   # same gate as the gateway (gateway-rs/src/audio.rs)
MIN_SPEECH_S = 0.5
PIPELINE = 'local-bootstrapping/dotfiles/local-lib/hyprwhspr-patch/voice_safety.py'


def log(msg):
    print(f'[SAFETY] {msg}', flush=True)


def notify(title, body, urgency='normal'):
    try:
        subprocess.Popen(['notify-send', '-a', 'Voice typing', '-u', urgency, title, body],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log(f'notify-send failed: {e}')


# ─────────────────────────── spool ───────────────────────────

class Spool:
    """Writes one recording to disk as it is captured (16 kHz mono PCM16 WAV)."""

    def __init__(self, sample_rate=16000):
        self.sample_rate = sample_rate
        stamp = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')
        SPOOL_DIR.mkdir(parents=True, exist_ok=True)
        base, n = SPOOL_DIR / f'{stamp}_client', 2
        while base.with_suffix('.wav').exists() or base.with_suffix('.json').exists():
            base, n = SPOOL_DIR / f'{stamp}_client_{n}', n + 1
        self.wav_path = base.with_suffix('.wav')
        self.meta_path = base.with_suffix('.json')
        self.meta = {
            'source': 'hyprwhspr microphone capture (client-side spool)',
            'pipeline': PIPELINE,
            'created': datetime.now().astimezone().isoformat(timespec='seconds'),
            'status': 'recording',
            'pid': os.getpid(),
            'sample_rate': sample_rate,
            'wav': str(self.wav_path),
        }
        self.samples = 0
        self._sumsq = 0.0
        self._q = queue.SimpleQueue()
        self._sealed = threading.Event()
        self._file = None
        self._wav = None
        self.write_meta()
        threading.Thread(target=self._run, daemon=True, name='VoiceSpool').start()

    # called from the audio callback: must never block
    def put(self, chunk):
        self._q.put(chunk)

    def _open(self):
        self._file = open(self.wav_path, 'wb')
        self._wav = wave.open(self._file, 'wb')
        self._wav.setnchannels(1)
        self._wav.setsampwidth(2)
        self._wav.setframerate(self.sample_rate)

    def _run(self):
        last_sync = time.monotonic()
        stop = False
        while not stop:
            batch = [self._q.get()]
            while True:
                try:
                    batch.append(self._q.get_nowait())
                except queue.Empty:
                    break
            stop = any(b is None for b in batch)
            data = [b for b in batch if b is not None]
            if not data:
                continue
            try:
                a = np.concatenate([np.asarray(d, dtype=np.float32).reshape(-1) for d in data])
                i16 = (np.clip(a, -1.0, 1.0) * 32767).astype(np.int16)
                if self._wav is None:
                    self._open()
                self._wav.writeframes(i16.tobytes())   # also rewrites the header sizes
                self._file.flush()
                self.samples += len(i16)
                self._sumsq += float(np.sum(i16.astype(np.float64) ** 2))
                if time.monotonic() - last_sync > 2.0:
                    os.fsync(self._file.fileno())
                    last_sync = time.monotonic()
            except Exception as e:
                log(f'spool write failed ({self.wav_path.name}): {e}')
        try:
            if self._wav is not None:
                self._wav.close()
                self._file.flush()
                os.fsync(self._file.fileno())
                self._file.close()
        except Exception as e:
            log(f'spool close failed: {e}')
        self._sealed.set()

    def seal(self, timeout=5.0):
        """Flush every queued chunk and close the WAV. Idempotent."""
        if not self._sealed.is_set():
            self._q.put(None)
            self._sealed.wait(timeout)
        return self._sealed.is_set()

    @property
    def duration(self):
        return self.samples / float(self.sample_rate)

    @property
    def rms(self):
        return (self._sumsq / self.samples) ** 0.5 if self.samples else 0.0

    def has_speech(self):
        return self.duration >= MIN_SPEECH_S and self.rms >= SILENCE_RMS_I16

    def write_meta(self, **update):
        self.meta.update(update)
        self.meta['duration_s'] = round(self.duration, 2)
        self.meta['rms_i16'] = round(self.rms, 1)
        try:
            tmp = self.meta_path.with_suffix('.json.tmp')
            tmp.write_text(json.dumps(self.meta, indent=2))
            tmp.replace(self.meta_path)
        except Exception as e:
            log(f'spool meta write failed: {e}')


# ─────────────────────────── sender ───────────────────────────

class Sender:
    """Runs network sends on one thread, in order, off the audio callback."""

    def __init__(self):
        self._q = queue.SimpleQueue()
        self._cv = threading.Condition()
        self._pending = 0
        threading.Thread(target=self._run, daemon=True, name='VoiceSender').start()

    def put(self, fn, chunk):
        with self._cv:
            self._pending += 1
        self._q.put((fn, chunk))

    def _run(self):
        while True:
            fn, chunk = self._q.get()
            try:
                if fn is not None:
                    fn(chunk)
            except Exception as e:
                log(f'send failed: {e}')
            finally:
                with self._cv:
                    self._pending -= 1
                    self._cv.notify_all()

    def drain(self, timeout):
        with self._cv:
            return self._cv.wait_for(lambda: self._pending == 0, timeout)

    def pending(self):
        with self._cv:
            return self._pending


# ─────────────────────── send watchdog ───────────────────────

_inflight = {}            # id -> (start monotonic, WebSocketApp)
_inflight_lock = threading.Lock()


def _shutdown_socket(app):
    try:
        sock = getattr(getattr(app, 'sock', None), 'sock', None)
        if sock is not None:
            sock.shutdown(socket.SHUT_RDWR)
    except Exception as e:
        log(f'socket shutdown failed: {e}')


def _watchdog():
    while True:
        time.sleep(0.5)
        now = time.monotonic()
        stalled = []
        with _inflight_lock:
            for key, (t0, app) in list(_inflight.items()):
                if now - t0 > SEND_TIMEOUT_S:
                    stalled.append(app)
                    del _inflight[key]
        for app in stalled:
            log(f'WebSocket send blocked > {SEND_TIMEOUT_S:.0f} s — gateway is not reading; '
                f'shutting the socket down (audio is on disk)')
            STATE.mark_broken('send stalled > %.0f s' % SEND_TIMEOUT_S)
            _shutdown_socket(app)


def install_send_guard():
    import websocket
    if getattr(websocket.WebSocketApp.send, '_voice_guarded', False):
        return
    orig = websocket.WebSocketApp.send

    def guarded_send(self, data, *args, **kwargs):
        key = object()
        with _inflight_lock:
            _inflight[id(key)] = (time.monotonic(), self)
        try:
            return orig(self, data, *args, **kwargs)
        finally:
            with _inflight_lock:
                _inflight.pop(id(key), None)

    guarded_send._voice_guarded = True
    websocket.WebSocketApp.send = guarded_send
    threading.Thread(target=_watchdog, daemon=True, name='VoiceSendWatchdog').start()
    log(f'send guard installed (timeout {SEND_TIMEOUT_S:.0f} s)')


# ─────────────────────────── state ───────────────────────────

class _State:
    def __init__(self):
        self.lock = threading.Lock()
        self.spool = None
        self.sender = Sender()
        self.rc = None                # RealtimeClient, set at init
        self.broken = None            # reason this recording's stream is incomplete
        self.result = None            # 'ok' | 'rescued' | 'silent' | 'failed'
        self.transcribe_called = False
        self.gen = 0                  # recording generation: stale queued chunks are dropped
        self.cb_issued = False        # streaming callback handed out for this recording

    def mark_broken(self, reason):
        with self.lock:
            if self.spool is not None and self.broken is None:
                self.broken = reason
                log(f'stream to gateway interrupted for this recording: {reason}')

    # ── recording lifecycle ──
    def begin(self, sample_rate=16000):
        with self.lock:
            old = self.spool
        if old is not None:           # a recording that never ended properly
            self.end('superseded')
        try:
            spool = Spool(sample_rate)
        except Exception as e:
            log(f'could not create spool (recording continues unspooled): {e}')
            spool = None
        with self.lock:
            self.gen += 1
            self.cb_issued = False
            self.spool = spool
            self.broken = None
            self.result = None
            self.transcribe_called = False
        if spool:
            log(f'recording to {spool.wav_path}')
        self.ensure_connected()

    def ensure_connected(self):
        rc = self.rc
        if rc is None or rc.connected or getattr(rc, 'connecting', False):
            return
        log('gateway WebSocket is down at recording start — reconnecting in background')
        rc.reconnect_attempts = 0

        def go():
            try:
                rc._connect_internal()
            except Exception as e:
                log(f'reconnect failed: {e}')
        threading.Thread(target=go, daemon=True, name='VoiceReconnect').start()

    def on_chunk(self, chunk, send_fn):
        spool = self.spool
        if spool is not None:
            spool.put(chunk)
        if send_fn is not None:
            self.sender.put(send_fn, (self.gen, chunk))

    def end(self, reason='stopped'):
        """Seal the spool and record its outcome. Safe to call more than once."""
        with self.lock:
            spool, self.spool = self.spool, None
            result, broken, called = self.result, self.broken, self.transcribe_called
        if spool is None:
            return
        spool.seal()
        if result in ('ok', 'rescued', 'silent', 'failed'):
            status = {'ok': 'transcribed', 'rescued': 'recovered'}.get(result, result)
            spool.write_meta(status=status, ended=reason, stream_interrupted=broken)
            return
        # transcription never ran (mute cancel, stream broke, busy, crash in stop path)
        if not spool.has_speech():
            spool.write_meta(status='no-speech', ended=reason, stream_interrupted=broken)
            return
        spool.write_meta(status='not-transcribed', ended=reason, stream_interrupted=broken,
                         transcribe_called=called)
        log(f'{spool.wav_path.name}: {spool.duration:.1f}s of speech was not transcribed ({reason}) '
            f'— recovering to the clipboard')
        threading.Thread(target=_background_recover, args=(spool.wav_path,), daemon=True).start()

    # ── called from the patched RealtimeClient.commit_and_get_text ──
    def before_commit(self, rc):
        if not self.sender.drain(DRAIN_TIMEOUT_S):
            self.mark_broken(f'{self.sender.pending()} audio chunks still unsent after {DRAIN_TIMEOUT_S:.0f} s')
            _shutdown_socket(getattr(rc, 'ws', None))
            return False
        with self.lock:
            broken = self.broken
        if broken:
            log(f'not committing a partial recording ({broken}); will re-transcribe the saved audio')
            return False
        return True

    # ── called from the patched WhisperManager.transcribe_audio ──
    def after_transcribe(self, text):
        with self.lock:
            spool = self.spool
            self.transcribe_called = True
        if spool is None:
            return text
        spool.seal()
        if text and text.strip():
            with self.lock:
                self.result = 'ok'
            return text
        if not spool.has_speech():
            with self.lock:
                self.result = 'silent'
            return text
        reason = self.broken or 'no transcript from the gateway'
        rescue_s = RESCUE_DEEPGRAM_S + wait_for(spool.duration, RESCUE_TIMEOUT_S)
        log(f'{spool.wav_path.name}: {reason} — re-transcribing {spool.duration:.1f}s '
            f'(Deepgram {RESCUE_DEEPGRAM_S:.0f} s, then local Whisper; up to {rescue_s:.0f} s)')
        rescued, err, answered = run_retranscribe(
            spool.wav_path, rescue_s, extra=('--timeout', str(RESCUE_DEEPGRAM_S)))
        if answered and not rescued:
            # Deepgram heard the whole file and found no words (noise, a cough):
            # nothing was lost, so no alarm.
            with self.lock:
                self.result = 'silent'
            spool.write_meta(rescue_reason=reason, note='batch re-transcription found no words')
            return text
        if rescued:
            with self.lock:
                self.result = 'rescued'
            spool.write_meta(rescue_reason=reason)
            notify('Voice typing: recovered',
                   f'The live transcript failed ({reason}); typed the batch transcript instead.\n'
                   f'file://{spool.wav_path}')
            return rescued
        with self.lock:
            self.result = 'failed'
        spool.write_meta(error=f'{reason}; rescue: {err}')
        notify('Voice typing: transcript FAILED — audio saved',
               f'{reason}; rescue failed: {err}\nAudio: file://{spool.wav_path}\n'
               f'Retry: tap the mic icon → "Retry the last failed recording"', 'critical')
        return text


STATE = _State()


def run_retranscribe(wav_path, timeout, extra=()):
    """Returns (text, error, answered). answered=True: Deepgram processed the
    file (text may legitimately be empty); False: the rescue itself failed."""
    if not RETRANSCRIBE.exists():
        return '', f'{RETRANSCRIBE} missing', False
    try:
        out = subprocess.run(['/usr/bin/python3', str(RETRANSCRIBE), '--json', *extra, str(wav_path)],
                             capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return '', f'timed out after {timeout:.0f} s', False
    except Exception as e:
        return '', str(e), False
    text, answered = '', False
    for line in out.stdout.splitlines():
        try:
            text = json.loads(line).get('text', '') or text
            answered = True
        except ValueError:
            pass
    answered = answered and out.returncode == 0
    if text:
        return text, '', True
    err = (out.stderr.strip().splitlines() or ['empty transcript'])[-1]
    return '', err[:200], answered


def _background_recover(wav_path):
    text, err, answered = run_retranscribe(wav_path, 90, extra=('--copy',))
    if answered and not text:
        log(f'{Path(wav_path).name}: batch re-transcription found no words')
        return
    if text:
        notify('Voice typing: recovered to clipboard',
               f'{text[:160]}{"…" if len(text) > 160 else ""}\nfile://{wav_path}')
    else:
        notify('Voice typing: recording NOT transcribed — audio saved',
               f'{err}\nAudio: file://{wav_path}\nRetry: tap the mic icon → "Retry the last failed recording"', 'critical')


def recover_pending_at_startup():
    """Spool files left by a crash/failed rescue: recover in the background."""
    def go():
        time.sleep(10)   # let the gateway and network settle after (re)start
        if not RETRANSCRIBE.exists():
            return
        try:
            subprocess.run(['/usr/bin/python3', str(RETRANSCRIBE), '--pending', '--copy', '--notify'],
                           capture_output=True, text=True, timeout=300)
        except Exception as e:
            log(f'pending recovery failed: {e}')
    threading.Thread(target=go, daemon=True, name='VoicePendingRecovery').start()


# ─────────────────────────── install ───────────────────────────

def install(app_cls, whisper_manager_cls):
    """Monkey-patch hyprwhspr classes. Called once from hyprwhspr-patch/main.py."""
    install_send_guard()

    orig_get_cb = whisper_manager_cls.get_realtime_streaming_callback
    orig_transcribe = whisper_manager_cls.transcribe_audio

    def get_realtime_streaming_callback(self):
        if STATE.spool is not None and STATE.cb_issued:
            # upstream restarts capture mid-recording (recover_audio_capture) and the
            # clear below wipes the gateway's buffer: the live transcript would be partial
            STATE.mark_broken('audio capture restarted mid-recording')
        STATE.cb_issued = True
        send_fn = orig_get_cb(self)   # sends input_audio_buffer.clear (guarded)
        rc = getattr(self, '_realtime_client', None)
        if rc is not None:
            STATE.rc = rc
            _patch_realtime_client(type(rc))

        def send_checked(item):
            gen, chunk = item
            if gen != STATE.gen:
                return   # left over from an earlier, interrupted recording
            client = STATE.rc
            if client is not None and not client.connected:
                STATE.mark_broken('gateway WebSocket not connected')
                return
            send_fn(chunk)

        def callback(chunk):   # runs under AudioCapture.lock: queue only, never block
            STATE.on_chunk(chunk, send_checked if send_fn is not None else None)
        return callback

    def transcribe_audio(self, audio_data, *args, **kwargs):
        text = ''
        try:
            text = orig_transcribe(self, audio_data, *args, **kwargs)
        finally:
            text = STATE.after_transcribe(text)
        return text

    whisper_manager_cls.get_realtime_streaming_callback = get_realtime_streaming_callback
    whisper_manager_cls.transcribe_audio = transcribe_audio
    log('installed: client spool, off-lock sender, send watchdog, rescue')


def _patch_realtime_client(rc_cls):
    if getattr(rc_cls, '_voice_safety_patched', False):
        return
    orig_commit = rc_cls.commit_and_get_text

    def commit_and_get_text(self, timeout=30.0):
        if not STATE.before_commit(self):
            return ''
        spool = STATE.spool
        wait = wait_for(spool.duration if spool is not None else 0.0, timeout)
        if wait > timeout:
            log(f'waiting up to {wait:.0f} s for the transcript of {spool.duration:.1f}s of audio')
        return orig_commit(self, wait)

    rc_cls.commit_and_get_text = commit_and_get_text
    rc_cls._voice_safety_patched = True
