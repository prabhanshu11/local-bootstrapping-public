#!/usr/bin/env python3
"""Time laptop fsync stalls on the DESKTOP's clock (an observer outside the slow system).
Laptop runs this; it opens one ssh pipe to the desktop. The desktop side sends 'go N'
every PERIOD s, the laptop does an append+fsync under /home and a no-disk echo, replies,
and the desktop prints round-trip times measured with its own monotonic clock.
Usage: external-fsync-probe.py [DUR=80] [PERIOD=1.0]"""
import os, subprocess, sys, time
DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 80
PERIOD = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
OBS = f'''
import sys,time,datetime
end=time.monotonic()+{DUR}; n=0
while time.monotonic()<end:
    n+=1; t0=time.monotonic(); print("echo",n,flush=True); sys.stdin.readline(); t1=time.monotonic()
    print("go",n,flush=True); sys.stdin.readline(); t2=time.monotonic()
    sys.stderr.write(f"{{datetime.datetime.now():%H:%M:%S.%f}}"[:-3]+f" desktop-clock  n={{n:3d}}  no-disk-rtt={{(t1-t0)*1000:7.1f}} ms  fsync-rtt={{(t2-t1)*1000:8.1f}} ms\\n"); sys.stderr.flush()
    time.sleep(max(0,{PERIOD}-(time.monotonic()-t0)))
print("bye",flush=True)
'''
import base64
cmd = "python3 -u -c 'import base64;exec(base64.b64decode(\"%s\"))'" % base64.b64encode(OBS.encode()).decode()
p = subprocess.Popen(["ssh", "desktop-lan", cmd],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
f = os.path.expanduser("~/.cache/external-fsync-probe")
for line in p.stdout:
    if line.startswith("go"):
        with open(f, "a") as fh:
            fh.write("x\n"); fh.flush(); os.fsync(fh.fileno())
    elif line.startswith("bye"):
        break
    p.stdin.write("ok\n"); p.stdin.flush()
p.wait()
if os.path.exists(f): os.remove(f)
