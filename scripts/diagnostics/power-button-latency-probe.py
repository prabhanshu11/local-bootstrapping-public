#!/usr/bin/env python3
"""Power-profile button latency, timed on the DESKTOP's clock (2026-11-01).

Same pattern as external-fsync-probe.py: the laptop opens one `ssh desktop-lan`
pipe; the desktop sends "go N" every PERIOD s and times the round trip with its
own monotonic clock while the laptop runs one tap and waits for its effect.
A no-disk "echo" round trip before each probe gives the network share.

Modes (NEVER changes the power profile):
  old  `PPM_DIRECT=1 power-profile-monitor set <current>`: the pre-daemon tap path
       (ppd same-value Set, override flag, log read + append on btrfs, redraw signal
       last). Effect = the command exits, i.e. the moment it signals waybar.
       Log row goes to ~/.cache/pp-probe.log (still btrfs, like the real log).
  new  `sh -c "bar-touch-click custom/power-profile"`: waybar's own on-click
       command, with the daemon in dry-run (the tap shows + pends, never reaches
       ppd, reverts after 1.5 s). Effect = the bar icon's pixels change (grim
       crop polled back to back); the watch line time is recorded too.
The override file and the profile are recorded first and checked/restored last.
A probe counts as "during a commit" when the btrfs commit counter moved or
cur_commit_ms > 0 between its start and its end.

PROBE_IN_COMMIT=1 waits for cur_commit_ms > 0 before each tap (run a write load
beside it so commits happen; see docs/issues/REPORT-power-button.md).
Usage: power-button-latency-probe.py old|new [N=14] [PERIOD=3.0] [CROP=4370,180 70x33]
"""
import base64
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import threading
import time

MODE = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 14
PERIOD = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
CROP = sys.argv[4] if len(sys.argv) > 4 else "4370,180 70x33"
IN_COMMIT = os.environ.get("PROBE_IN_COMMIT") == "1"
ONCLICK = os.environ.get("PROBE_ONCLICK") or f"{os.path.expanduser('~')}/.local/bin/bar-touch-click custom/power-profile"
STATS = "/sys/fs/btrfs/00000000-0000-0000-0000-000000000000/commit_stats"
HOME = os.path.expanduser("~")
OVERRIDE = "/tmp/power-profile-override"
RUN = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")


def commit_stats():
    d = {}
    for ln in open(STATS):
        k, v = ln.split()
        d[k] = int(v)
    return d


def profile():
    return subprocess.run(["busctl", "get-property", "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles",
                           "net.hadess.PowerProfiles", "ActiveProfile"], capture_output=True, text=True,
                          timeout=60).stdout.strip().split('"')[1]


def grab():
    return subprocess.run(["grim", "-g", CROP, "-t", "ppm", "-"], capture_output=True, timeout=5).stdout


start_profile = profile()
saved_override = open(OVERRIDE).read() if os.path.exists(OVERRIDE) else None
print(f"mode={MODE} profile={start_profile} override={saved_override!r}", flush=True)

lines = []
if MODE == "new":
    out = subprocess.run([f"{HOME}/.local/bin/power-profile-daemon", "dryrun", str(N * PERIOD + 20)],
                         capture_output=True, text=True)
    assert '"dry_run_s"' in out.stdout, out
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.path.join(RUN, "power-profile.sock"))
    s.sendall(b"watch\n")
    f = s.makefile("r")

    def reader():
        for ln in f:
            lines.append((time.monotonic(), json.loads(ln)["text"]))
    threading.Thread(target=reader, daemon=True).start()
    time.sleep(0.3)

OBS = f'''
import sys,time
for n in range(1,{N}+1):
    t0=time.monotonic(); print("echo",n,flush=True); sys.stdin.readline(); t1=time.monotonic()
    print("go",n,flush=True); sys.stdin.readline(); t2=time.monotonic()
    print("rtt",n,round((t1-t0)*1000,1),round((t2-t1)*1000,1),flush=True); sys.stdin.readline()
    time.sleep(max(0,{PERIOD}-(time.monotonic()-t0)))
print("bye",flush=True)
'''
cmd = "python3 -u -c 'import base64;exec(base64.b64decode(\"%s\"))'" % base64.b64encode(OBS.encode()).decode()
p = subprocess.Popen(["ssh", "desktop-lan", cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     text=True, bufsize=1)
rows, cur = [], {}
for line in p.stdout:
    w = line.split()
    if w[0] == "echo" and IN_COMMIT:
        # fire the tap only once a btrfs commit is running (cur_commit_ms > 0), so the
        # probe is "during a commit" by construction; the wait sits in echo_ms, not in the tap
        deadline = time.monotonic() + 6
        while commit_stats()["cur_commit_ms"] == 0 and time.monotonic() < deadline:
            time.sleep(0.002)
    if w[0] == "go":
        c0 = commit_stats()
        t0 = time.monotonic()
        if MODE == "old":
            subprocess.run([f"{HOME}/.local/bin/power-profile-monitor", "set", start_profile],
                           env=dict(os.environ, PPM_DIRECT="1", PPM_LOG_FILE=f"{HOME}/.cache/pp-probe.log"),
                           timeout=120)
            t_line = t_px = time.monotonic()
        else:
            base = grab()
            t0 = time.monotonic()
            subprocess.Popen(["sh", "-c", ONCLICK])
            t_px = None
            while time.monotonic() - t0 < 10:
                if grab() != base:
                    t_px = time.monotonic()
                    break
            t_line = next((t for t, _ in lines if t >= t0), None)
        c1 = commit_stats()
        cur = {"local_ms": round(1000 * ((t_px or time.monotonic()) - t0)),
               "line_ms": round(1000 * (t_line - t0)) if t_line else None,
               "seen": t_px is not None,
               "commit": c1["commits"] != c0["commits"] or c0["cur_commit_ms"] > 0 or c1["cur_commit_ms"] > 0,
               "cur_ms": max(c0["cur_commit_ms"], c1["cur_commit_ms"])}
    elif w[0] == "rtt":
        cur.update(n=int(w[1]), echo_ms=float(w[2]), desktop_ms=float(w[3]))
        rows.append(dict(cur))
        print(json.dumps(cur), flush=True)
        if MODE == "new":
            time.sleep(1.7)               # let the dry-run tap revert before the next one
    elif w[0] == "bye":
        break
    p.stdin.write("ok\n")
    p.stdin.flush()
p.wait()

# restore + safety check
if saved_override is not None:
    with open(OVERRIDE, "w") as fh:
        fh.write(saved_override)
if MODE == "new":
    subprocess.run([f"{HOME}/.local/bin/power-profile-daemon", "dryrun", "0"], capture_output=True)
end_profile = profile()
assert end_profile == start_profile, f"PROFILE CHANGED {start_profile} -> {end_profile}"


def p95(v):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))] if v else None


for label, sel in (("all", rows), ("during-commit", [r for r in rows if r["commit"]])):
    net = [r["desktop_ms"] - r["echo_ms"] for r in sel]
    print(f"{MODE} {label}: n={len(sel)} desktop-clock p50={statistics.median(net) if net else None:.0f} "
          f"p95={p95(net)} max={max(net) if net else None} ms (minus ssh echo); "
          f"local p95={p95([r['local_ms'] for r in sel])} ms; unseen={sum(not r['seen'] for r in sel)}"
          if net else f"{MODE} {label}: n=0", flush=True)
print(f"profile unchanged: {end_profile}; override restored: {saved_override!r}")
