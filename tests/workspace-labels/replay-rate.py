#!/usr/bin/env python3
"""Replay a workspace-labels log window and estimate labelling calls/hour under
the round-3 rules (2026-11-02). Usage:
  replay-rate.py LOG START END        e.g. ... 07:05 07:40
BEFORE = every trigger in the log ('timing ws N ... (reason)').
AFTER  = the same triggers with the new rules:
  * window changes whose class diff is only TRANSIENT_CLASSES -> dropped
  * 10-min refreshes need >= WORK_SECONDS of input on that ws in the last 10 min.
    The log has no per-second input, so dwell time (switch to next switch,
    minus SWITCH_GRACE) is used as input time: an UPPER bound on calls.
  * the unchanged-input skip cannot be replayed (no old fingerprints): reported
    separately from a live 10 s measurement."""
import re, sys
from datetime import datetime
from importlib.machinery import SourceFileLoader
import os
m = SourceFileLoader("w", os.path.join(os.path.dirname(__file__), "../../dotfiles/local-bin/workspace-labels")).load_module()
log, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
T = lambda s: datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp()
switches, triggers = [], []
for line in open(log):
    hm = line[11:16]
    if not (start <= hm <= end):
        continue
    t = T(line[:19])
    if (mm := re.match(r".{20}popup ws (\d+): (?!empty)", line)):
        switches.append((t, int(mm.group(1))))
    elif (mm := re.match(r".{20}timing ws (\d+): .*after the need was seen \((.*)\)", line)):
        triggers.append((t, int(mm.group(1)), mm.group(2)))
switches.sort()


def dwell(ws, t0, t1):
    tot = 0.0
    for i, (ts, w) in enumerate(switches):
        te = switches[i + 1][0] if i + 1 < len(switches) else t1
        if w != ws:
            continue
        a, b = max(ts + m.SWITCH_GRACE, t0), min(te, t1)
        tot += max(0.0, b - a)
    return tot


kept, why = [], {}
for t, ws, reason in triggers:
    if reason.startswith("windows changed"):
        a, b = re.findall(r"\[(.*?)\]", reason)[:2]
        ca = [x.strip(" '").split(":")[0] for x in a.split(",") if x.strip()]
        cb = [x.strip(" '").split(":")[0] for x in b.split(",") if x.strip()]
        diff = set(ca) ^ set(cb) or {"(count)"}
        if all(m.TRANSIENT_CLASSES.match(c) for c in diff if c != "(count)") and "(count)" not in diff:
            why["transient window"] = why.get("transient window", 0) + 1
            continue
        if diff == {"(count)"}:
            extra = [c for c in set(ca + cb) if ca.count(c) != cb.count(c)]
            if all(m.TRANSIENT_CLASSES.match(c) for c in extra):
                why["transient window"] = why.get("transient window", 0) + 1
                continue
    if "refresh" in reason:
        d = dwell(ws, t - m.REFRESH, t)
        if d < m.WORK_SECONDS:
            why["refresh without 30 s of work"] = why.get("refresh without 30 s of work", 0) + 1
            continue
    kept.append((t, ws, reason))
hours = (T(f"2026-11-02 {end}:00") - T(f"2026-11-02 {start}:00")) / 3600
print(f"window {start}-{end} ({hours * 60:.0f} min), {len(switches)} switches")
print(f"BEFORE: {len(triggers)} calls = {len(triggers) / hours:.0f}/h")
print(f"AFTER (upper bound): {len(kept)} calls = {len(kept) / hours:.0f}/h; dropped: {why}")
for t, ws, r in kept:
    print("  kept", datetime.fromtimestamp(t).strftime("%H:%M:%S"), "ws", ws, r[:80])
