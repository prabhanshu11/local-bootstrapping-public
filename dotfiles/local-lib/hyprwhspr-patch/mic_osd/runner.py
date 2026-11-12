"""
MicOSD Runner - Daemon-based wrapper for instant mic-osd overlay.

Spawns mic-osd once in daemon mode, then uses SIGUSR1/SIGUSR2 to show/hide.
This eliminates subprocess spawn latency on each recording.
"""

import subprocess
import signal
import sys
import os
import json
import threading
from pathlib import Path

# Rotate the daemon log when it grows past this. A wedged GTK loop once spammed
# VK_ERROR_DEVICE_LOST warnings into a 74 GB log (2026-09-04).
LOG_MAX_BYTES = 5 * 1024 * 1024
# After SIGUSR2, how long to wait before checking the window really went away.
HIDE_VERIFY_DELAY = 1.5

# Import PID file path with multiple fallbacks
try:
    from ..src.paths import MIC_OSD_PID_FILE
except ImportError:
    try:
        from src.paths import MIC_OSD_PID_FILE
    except ImportError:
        # Ultimate fallback: construct path manually
        import os
        home = Path.home()
        xdg_config = Path(os.environ.get('XDG_CONFIG_HOME', home / '.config'))
        MIC_OSD_PID_FILE = xdg_config / 'hyprwhspr' / 'mic_osd.pid'


class MicOSDRunner:
    """
    Daemon-based runner for the mic-osd overlay.
    
    Spawns mic-osd in daemon mode at init, then signals it to show/hide.
    """
    
    def __init__(self):
        self._process = None
        self._daemon_just_spawned = False
        self._mic_osd_dir = Path(__file__).parent
        # Incremented on every show(); a hide-verify timer only acts if the
        # generation it captured is still current (no show() happened since).
        self._show_gen = 0
    
    @staticmethod
    def is_available() -> bool:
        """Check if mic-osd can run (only needs GTK4, not gtk4-layer-shell)."""
        try:
            import gi
            gi.require_version('Gtk', '4.0')
            return True
        except (ImportError, ValueError):
            return False

    @staticmethod
    def get_unavailable_reason() -> str:
        """Get reason why mic-osd is unavailable."""
        try:
            import gi
            gi.require_version('Gtk', '4.0')
        except (ImportError, ValueError):
            return "GTK4 (python-gobject) is not installed"
        return ""
    
    def _ensure_daemon(self):
        """Ensure the daemon process is running."""
        # Check in-memory reference first
        if self._process is not None and self._process.poll() is None:
            return True  # Already running

        # Kill orphaned daemon from previous hyprwhspr instance.
        # Reusing it doesn't work: the Wayland layer surface is stale after
        # the parent process restarted, so SIGUSR1 fails silently.
        if MIC_OSD_PID_FILE.exists():
            try:
                pid = int(MIC_OSD_PID_FILE.read_text().strip())
                os.kill(pid, 0)  # Check if alive
                print(f"[MIC-OSD] Killing orphaned daemon (PID {pid}) — spawning fresh", flush=True)
                os.kill(pid, signal.SIGTERM)
                # Brief wait for clean exit
                import time
                time.sleep(0.3)
                try:
                    os.kill(pid, 0)
                    os.kill(pid, signal.SIGKILL)  # Force kill if still alive
                except (ProcessLookupError, OSError):
                    pass
            except (ValueError, ProcessLookupError, PermissionError):
                pass
            try:
                MIC_OSD_PID_FILE.unlink()
            except Exception:
                pass

        # Build the Python code to run
        # PATCHED: Insert patch directory BEFORE system lib for custom mic_osd module
        lib_dir = self._mic_osd_dir.parent
        patch_dir = Path.home() / '.local' / 'lib' / 'hyprwhspr-patch'
        code = f"""
import sys, traceback
# No gtk4-layer-shell needed — positioning handled by Hyprland window rules
# Load patched modules first (if available), then fall back to system
sys.path.insert(0, '{lib_dir}')
if '{patch_dir}'.strip() and __import__('os').path.isdir('{patch_dir}'):
    sys.path.insert(0, '{patch_dir}')
try:
    from mic_osd.main import main
    sys.argv = ['mic-osd', '--daemon']
    sys.exit(main())
except Exception:
    traceback.print_exc()
    sys.exit(1)
"""

        # Minimal environment — no LD_PRELOAD needed.
        # OSD positioning is handled by Hyprland window rules (windowrules-mic-osd.conf)
        # matching class "mic-osd" (set via GLib.set_prgname in window.py).
        # Full os.environ segfaults with nvidia env vars; minimal env is safe.
        # See: local-bootstrapping/docs/mic-osd-lessons.md
        env = {
            'HOME': str(Path.home()),
            'WAYLAND_DISPLAY': os.environ.get('WAYLAND_DISPLAY', 'wayland-1'),
            'XDG_RUNTIME_DIR': os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'),
            'DISPLAY': os.environ.get('DISPLAY', ''),
            'PYTHONPATH': os.environ.get('PYTHONPATH', ''),
            'PYTHONUNBUFFERED': '1',
            'GDK_BACKEND': 'wayland',
            # Software renderer: a 400x68 waveform needs no GPU, and the GL/Vulkan
            # renderers wedge the main loop forever after a GPU reset
            # (VK_ERROR_DEVICE_LOST spam, window frozen on screen, 2026-09-04).
            'GSK_RENDERER': 'cairo',
            'PATH': os.environ.get('PATH', '/usr/bin'),
        }

        try:
            log_dir = Path.home() / 'Programs' / 'omarchy-voice-typing' / 'logs'
            log_dir.mkdir(parents=True, exist_ok=True)
            log_path = log_dir / 'mic-osd-daemon.log'
            try:
                if log_path.exists() and log_path.stat().st_size > LOG_MAX_BYTES:
                    log_path.replace(log_path.with_suffix('.log.1'))
            except OSError:
                pass
            log_file = open(log_path, 'a')
            self._process = subprocess.Popen(
                ['/usr/bin/python3', '-u', '-c', code],
                env=env,
                stdout=log_file,
                stderr=log_file,
                start_new_session=True,
            )

            # Write PID file
            MIC_OSD_PID_FILE.parent.mkdir(parents=True, exist_ok=True)
            MIC_OSD_PID_FILE.write_text(str(self._process.pid))

            self._daemon_just_spawned = True
            return True
        except Exception:
            self._process = None
            return False

    def _cleanup(self):
        """Clean up process reference and PID file."""
        self._process = None
        if MIC_OSD_PID_FILE.exists():
            try:
                MIC_OSD_PID_FILE.unlink()
            except Exception:
                pass

    def show(self) -> bool:
        """Show the mic-osd overlay (instant via signal)."""
        if not self.is_available():
            return False

        if not self._ensure_daemon():
            return False

        # If daemon was just spawned, wait for Python + GTK4 to initialize
        # and install signal handlers. Sending SIGUSR1 too early kills the
        # process with the default handler (terminate) before signal.signal()
        # has been called. 800ms covers Python startup + GTK + Wayland connect.
        if self._daemon_just_spawned:
            self._daemon_just_spawned = False
            import time
            time.sleep(0.8)
            if self._process.poll() is not None:
                print("[MIC-OSD] Daemon died during startup", flush=True)
                self._cleanup()
                return False

        self._show_gen += 1
        try:
            os.kill(self._process.pid, signal.SIGUSR1)
            return True
        except (ProcessLookupError, OSError):
            self._cleanup()
            return False

    def hide(self):
        """Hide the mic-osd overlay (instant via signal)."""
        if self._process is None:
            return

        if self._process.poll() is not None:
            print(f"[MIC-OSD] Daemon (PID {self._process.pid}) is dead, cleaning up", flush=True)
            self._cleanup()
            return

        try:
            os.kill(self._process.pid, signal.SIGUSR2)
        except (ProcessLookupError, OSError) as e:
            print(f"[MIC-OSD] Failed to hide (PID {self._process.pid}): {e}", flush=True)
            self._cleanup()
            return

        # Verify off-thread so text injection is not delayed. If the daemon's
        # main loop is wedged (GPU reset etc.) SIGUSR2 is never processed and
        # the window stays frozen on screen; the only fix is to kill it.
        timer = threading.Timer(
            HIDE_VERIFY_DELAY, self._verify_hidden,
            args=(self._process, self._show_gen),
        )
        timer.daemon = True
        timer.start()

    @staticmethod
    def _osd_window_mapped() -> bool:
        """True if Hyprland currently has a mapped window of class mic-osd."""
        try:
            out = subprocess.run(
                ['hyprctl', 'clients', '-j'],
                capture_output=True, text=True, timeout=2,
            ).stdout
            return any(
                c.get('class') == 'mic-osd' and c.get('mapped')
                for c in json.loads(out or '[]')
            )
        except Exception:
            return False  # can't tell; don't kill on a guess

    def _verify_hidden(self, proc, gen):
        """Kill the daemon if its window is still on screen after hide()."""
        if proc is not self._process or gen != self._show_gen:
            return  # daemon replaced, or show() called again since — window is legit
        if proc.poll() is not None:
            return
        if not self._osd_window_mapped():
            return
        print(f"[MIC-OSD] Window still mapped {HIDE_VERIFY_DELAY}s after hide — "
              f"daemon (PID {proc.pid}) is wedged, killing it", flush=True)
        try:
            os.kill(proc.pid, signal.SIGKILL)
            proc.wait(timeout=1.0)
        except Exception:
            pass
        if proc is self._process:
            self._cleanup()

    def stop(self):
        """Stop the daemon completely."""
        if self._process is None:
            return

        try:
            os.kill(self._process.pid, signal.SIGTERM)
            self._process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            os.kill(self._process.pid, signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
        finally:
            self._cleanup()
