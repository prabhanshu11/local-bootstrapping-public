"""power-profile-daemon against an in-RAM fake power-profiles-daemon (2026-11-01).

Never touches the real power profile: PPD_FAKE=1 replaces ppd, PPD_FLAG_DIR /
PPD_SOCK / PPD_SPOOL / PPD_SYS point into pytest's tmp dir (tmpfs on the laptop),
and PPD_MONITOR is a stub that only records that the fallback ran.

Run: uv run --no-project --with pytest pytest -q tests/power-profile   (~10 s)
"""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import socket
import subprocess
import threading
import time

import pytest

HERE = pathlib.Path(__file__).parent
BIN = HERE.parent.parent / "dotfiles" / "local-bin"
DAEMON = BIN / "power-profile-daemon"


def fake_sys(root, battery=True):
    """A /sys tree with only what the daemon reads."""
    ps = root / "sys/class/power_supply"
    ps.mkdir(parents=True)
    if battery:
        (ps / "AC").mkdir()
        (ps / "AC/online").write_text("1\n")
        (ps / "BAT0").mkdir()
        (ps / "BAT0/capacity").write_text("77\n")
        lap = root / "sys/bus/platform/devices/thinkpad_acpi"
        lap.mkdir(parents=True)
        (lap / "dytc_lapmode").write_text("0\n")
    return root


@pytest.fixture
def env(tmp_path):
    stub = tmp_path / "monitor-stub"
    stub.write_text(f"#!/bin/sh\necho \"$@\" >> {tmp_path}/fallback-ran\n")
    stub.chmod(0o755)
    e = dict(os.environ, PPD_FAKE="1", PPD_SOCK=str(tmp_path / "pp.sock"), PPD_FLAG_DIR=str(tmp_path),
             PPD_SPOOL=str(tmp_path / "spool.csv"), PPD_MONITOR=str(stub),
             PPD_SYS=str(fake_sys(tmp_path / "root")), PPD_FAKE_START="balanced",
             PYTHONDONTWRITEBYTECODE="1", PPD_NO_SIGNAL="1",
             PATH="/usr/bin:" + os.environ.get("PATH", ""))   # system python3 has gi; uv's may not
    e.pop("PPM_DIRECT", None)
    return e


class Daemon:
    def __init__(self, env, **extra):
        self.env = dict(env, **extra)
        self.proc = subprocess.Popen([str(DAEMON), "daemon"], env=self.env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 5
        while not os.path.exists(self.env["PPD_SOCK"]):
            assert self.proc.poll() is None, self.proc.stdout.read()
            assert time.monotonic() < deadline, "daemon did not start"
            time.sleep(0.02)

    def run(self, *args, timeout=5):
        return subprocess.run([str(DAEMON), *args], env=self.env, capture_output=True,
                              text=True, timeout=timeout)

    def debug(self):
        return json.loads(self.run("debug").stdout)

    def stop(self):
        self.proc.terminate()
        self.proc.wait(5)


class Watch:
    """A `watch` subscriber like waybar's exec: collects (t, line)."""
    def __init__(self, env):
        self.lines = []
        self.proc = subprocess.Popen([str(DAEMON), "watch"], env=env, stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.wait_for(lambda l: True)

    def _read(self):
        for line in self.proc.stdout:
            self.lines.append((time.monotonic(), json.loads(line)))

    def wait_for(self, pred, after=0.0, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for t, d in list(self.lines):
                if t >= after and pred(d):
                    return t, d
            time.sleep(0.01)
        raise AssertionError(f"no matching line; got {[d for _, d in self.lines]}")

    def stop(self):
        self.proc.kill()


def classes(d):
    c = d["class"]
    return c if isinstance(c, list) else [c]


def test_tap_shows_at_once_then_confirms(env):
    d = Daemon(env, PPD_FAKE_DELAY_MS="800")          # ppd slow, like during a btrfs commit
    w = Watch(env)
    try:
        assert w.lines[0][1]["text"] == "BAL"
        t0 = time.monotonic()
        r = d.run("toggle")
        assert r.returncode == 0
        t_line, line = w.wait_for(lambda x: x["text"].startswith("SAV"), after=t0)
        assert t_line - t0 < 0.3, "icon must not wait for ppd"
        assert "pending" in classes(line) and "power-saver" in classes(line)
        w.wait_for(lambda x: x["text"] == "SAV…", after=t0)          # pattern cue after 0.5 s
        w.wait_for(lambda x: x["text"] == "SAV" and "pending" not in classes(x), after=t0 + 0.7)
        assert (pathlib.Path(env["PPD_FLAG_DIR"]) / "power-profile-override").read_text().strip() == "power-saver"
        spool, deadline = pathlib.Path(env["PPD_SPOOL"]), time.monotonic() + 4
        while not (spool.exists() and "TOGGLE:balanced>power-saver" in spool.read_text()):
            assert time.monotonic() < deadline, "no TOGGLE row in the tmpfs spool"
            time.sleep(0.05)
    finally:
        w.stop()
        d.stop()


def test_two_quick_taps_are_two_steps_latest_wins(env):
    d = Daemon(env, PPD_FAKE_DELAY_MS="300")
    try:
        d.run("toggle")
        d.run("toggle")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            dbg = d.debug()
            if dbg["desired"] is None and dbg["inflight"] is None and dbg["active"] == "performance":
                break
            time.sleep(0.05)
        dbg = d.debug()
        assert dbg["active"] == "performance"                 # BAL -> SAV -> PRF, not SAV twice
        assert dbg["fake_sets"] == 2
    finally:
        d.stop()


def test_heal_holds_display_and_queues_tap(env):
    d = Daemon(env, PPD_FAKE_DELAY_MS="0")
    try:
        healing = pathlib.Path(env["PPD_FLAG_DIR"]) / "power-profile-healing"
        healing.touch()
        d.run("toggle")
        time.sleep(0.4)
        dbg = d.debug()
        assert dbg["desired"] == "power-saver" and dbg["fake_sets"] == 0     # queued
        healing.unlink()
        deadline = time.monotonic() + 4                       # released by the 2 s poll
        while d.debug()["fake_sets"] == 0:
            assert time.monotonic() < deadline
            time.sleep(0.1)
        assert d.debug()["active"] == "power-saver"
    finally:
        d.stop()


def test_state_is_one_shot_json(env):
    d = Daemon(env)
    try:
        r = d.run("state", timeout=2)
        data = json.loads(r.stdout)
        assert data["text"] == "BAL" and data["class"] == "balanced"
        assert "Battery: 77%" in data["tooltip"]
    finally:
        d.stop()


def test_no_battery_desktop(env, tmp_path):
    root = fake_sys(tmp_path / "desk", battery=False)
    d = Daemon(env, PPD_SYS=str(root))
    try:
        data = json.loads(d.run("state").stdout)
        assert "AC: Mains (no battery)" in data["tooltip"] and data["text"] == "BAL"
    finally:
        d.stop()


def test_fallback_only_when_connect_fails(env, tmp_path):
    marker = tmp_path / "fallback-ran"
    # 1. nothing listening -> the old script runs
    r = subprocess.run([str(DAEMON), "toggle"], env=env, capture_output=True, text=True, timeout=5)
    assert r.returncode == 0 and marker.read_text().strip() == "toggle"
    marker.unlink()
    # 2. --no-fallback -> exit 3, nothing run
    r = subprocess.run([str(DAEMON), "--no-fallback", "toggle"], env=env, timeout=5)
    assert r.returncode == 3 and not marker.exists()
    # 3. a daemon that accepts but never answers -> no second toggle
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(env["PPD_SOCK"])
    srv.listen(4)
    try:
        r = subprocess.run([str(DAEMON), "toggle"], env=dict(env), capture_output=True, text=True, timeout=10)
        assert not marker.exists(), "a slow daemon must never cause a second toggle"
    finally:
        srv.close()


def load_bar_touch(monkeypatch, sock):
    loader = importlib.machinery.SourceFileLoader("bar_touch", str(BIN / "bar-touch"))
    spec = importlib.util.spec_from_loader("bar_touch", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    monkeypatch.setattr(mod, "SOCK", str(sock))
    return mod


def test_bar_touch_send_none_only_on_connect_failure(monkeypatch, tmp_path):
    bt = load_bar_touch(monkeypatch, tmp_path / "bt.sock")
    assert bt.send({"cmd": "status"}) is None                       # no daemon
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(tmp_path / "bt.sock"))
    srv.listen(4)
    try:
        reply = bt.send({"cmd": "click", "module": "x"}, reply_timeout=0.5)   # never answers
        assert reply == {"no_reply": True}
    finally:
        srv.close()


def test_fire_and_forget_line_is_not_lost(env):
    """bar-touch click-socket closes right after sending; the toggle must land."""
    d = Daemon(env)
    try:
        for _ in range(3):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(env["PPD_SOCK"])
            s.sendall(b"toggle\n")
            s.close()
            time.sleep(0.2)
        assert d.debug()["fake_sets"] == 3
    finally:
        d.stop()


def test_bar_touch_click_socket(monkeypatch, tmp_path, env):
    bt = load_bar_touch(monkeypatch, tmp_path / "bt.sock")
    monkeypatch.setattr(bt, "RUNTIME", str(tmp_path))
    ran = []
    monkeypatch.setattr(bt, "run_detached", lambda cmd, env=None: ran.append(cmd))
    touch = {"click": "echo fallback", "click-socket": "pp.sock toggle"}
    bt.run_click(touch)                        # no daemon -> the command
    assert ran == ["echo fallback"]
    d = Daemon(env)                            # env's socket is tmp_path/pp.sock
    try:
        bt.run_click(touch)
        time.sleep(0.3)
        assert ran == ["echo fallback"] and d.debug()["fake_sets"] == 1
    finally:
        d.stop()


def test_bar_touch_click_fast_client(tmp_path):
    """bar-touch-click sends the same request as `bar-touch click` and returns."""
    sock = tmp_path / "bt.sock"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock))
    srv.listen(1)
    got = {}

    def serve():
        conn, _ = srv.accept()
        data = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        got.update(json.loads(data))
        conn.sendall(b'{"verdict": "mouse"}')
        conn.close()
    threading.Thread(target=serve, daemon=True).start()
    r = subprocess.run([str(BIN / "bar-touch-click"), "custom/power-profile"], timeout=5,
                       env=dict(os.environ, BAR_TOUCH_SOCK=str(sock)))
    srv.close()
    assert r.returncode == 0
    assert got["cmd"] == "click" and got["module"] == "custom/power-profile" and "env" in got
