#!/usr/bin/env python3
"""agent-nice: keep agent work at nice 19 + idle IO so the UI and the camera tracker always win.

Why (2026-09-30 02:0x, laptop): load 24 on 8 threads, 97 C, swap full from agent lanes; the cursor
stuttered and keystrokes echoed late. The main session reniced the heavy jobs by hand; he asked for
that behaviour to be permanent, on the laptop and the desktop. See README.md next to this file.

What counts as agent work (user-owned processes only):
  * every descendant of a Claude Code session: Bash-tool shells, pytest, renders, replays. Session
    processes themselves (interactive `claude`, `claude -p`, Remote Control's per-session children)
    are left alone so the TUI and phone sessions stay snappy; only the work they spawn is demoted.
  * every process whose cwd is under ~/lanes/ (lane work run on the desktop over ssh).
GUI programs an agent happens to launch (chrome, firefox, waybar, ...) are skipped.

Linux nice is per THREAD: `renice -p PID` only changes the thread whose tid == PID, so numpy/torch
worker threads kept nice 0 after the manual renice. This walks /proc/PID/task/* and sets every tid.
It only ever raises nice (an unprivileged user cannot lower it), so deliberate settings survive.

Usage: agent-nice            run forever (the systemd user service)
       agent-nice --once     one pass, print what was changed
       agent-nice --dry-run  one pass, print what would change, change nothing
"""
import argparse
import ctypes
import os
import sys
import time

NICE = 19
INTERVAL_S = 2.0
SUMMARY_EVERY_S = 300
LANES_DIR = os.path.join(os.path.expanduser("~"), "lanes") + "/"
AGENT_COMMS = {"claude"}
CLAUDE_VERSIONS_DIR = "/.local/share/claude/versions/"
# Launched by an agent but used by him: keep them (and their subtree) at normal priority.
SKIP_EXES = {
    "chrome", "chromium", "firefox", "ghostty", "kitty", "foot", "alacritty",
    "Hyprland", "waybar", "swaybg", "mako", "swayosd-server", "walker", "hyprlock", "hypridle",
    "mpv", "imv", "vlc", "obsidian", "moonlight",
}

# x86_64 syscall numbers; ioprio "idle" class = 3, data ignored.
SYS_IOPRIO_GET, SYS_IOPRIO_SET = 252, 251
IOPRIO_WHO_PROCESS = 1
IOPRIO_IDLE = 3 << 13
_libc = ctypes.CDLL(None, use_errno=True)
MY_UID = os.getuid()


def read_procs():
    """pid -> (ppid, comm) for every process owned by this user."""
    procs = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            if os.stat(f"/proc/{pid}").st_uid != MY_UID:
                continue
            with open(f"/proc/{pid}/stat", "rb") as f:
                stat = f.read().decode(errors="replace")
        except OSError:
            continue
        lpar, rpar = stat.find("("), stat.rfind(")")
        comm = stat[lpar + 1:rpar]
        ppid = int(stat[rpar + 2:].split()[1])
        procs[pid] = (ppid, comm)
    return procs


def exe_path(pid, exes):
    if pid not in exes:
        try:
            exes[pid] = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            exes[pid] = ""
    return exes[pid]


def is_claude(pid, procs, exes):
    """A Claude Code session: `claude` itself, or a Remote Control child (comm is its version, e.g. 2.1.283)."""
    return procs[pid][1] in AGENT_COMMS or CLAUDE_VERSIONS_DIR in exe_path(pid, exes)


def is_agent_work(pid, procs, cache, exes):
    """True if pid descends from a Claude session (sessions themselves excluded) or lives in ~/lanes."""
    if pid in cache:
        return cache[pid]
    chain, cur, verdict = [], pid, False
    while cur in procs and cur not in cache:
        chain.append(cur)
        cur = procs[cur][0]
    if cur in cache:
        verdict = cache[cur] or (cur in procs and is_claude(cur, procs, exes))
    for p in reversed(chain):  # walk down from the oldest ancestor
        parent = procs[p][0]
        verdict = verdict or (parent in procs and is_claude(parent, procs, exes))
        if verdict and os.path.basename(exe_path(p, exes)) in SKIP_EXES:
            verdict = False  # a GUI app and everything under it stays normal
        cache[p] = verdict and not is_claude(p, procs, exes)
    if not cache.get(pid):
        try:
            if os.readlink(f"/proc/{pid}/cwd").startswith(LANES_DIR):
                cache[pid] = os.path.basename(exe_path(pid, exes)) not in SKIP_EXES
        except OSError:
            pass
    return cache.get(pid, False)


def thread_nice(pid, tid):
    with open(f"/proc/{pid}/task/{tid}/stat", "rb") as f:
        stat = f.read().decode(errors="replace")
    return int(stat[stat.rfind(")") + 2:].split()[16])


def demote(pid, dry_run):
    """Set every thread of pid to NICE + idle IO. Returns the number of threads changed."""
    changed = 0
    try:
        tids = [int(t) for t in os.listdir(f"/proc/{pid}/task")]
    except OSError:
        return 0
    for tid in tids:
        try:
            touched = False
            if thread_nice(pid, tid) < NICE:
                touched = True
                if not dry_run:
                    os.setpriority(os.PRIO_PROCESS, tid, NICE)
            if _libc.syscall(SYS_IOPRIO_GET, IOPRIO_WHO_PROCESS, tid) >> 13 != 3:
                touched = True
                if not dry_run:
                    _libc.syscall(SYS_IOPRIO_SET, IOPRIO_WHO_PROCESS, tid, IOPRIO_IDLE)
            changed += touched
        except OSError:
            continue  # thread exited, or a setuid child (sudo) we may not touch
    return changed


def one_pass(dry_run, verbose):
    procs = read_procs()
    cache, exes = {}, {}
    touched = []
    for pid, (_, comm) in procs.items():
        if is_agent_work(pid, procs, cache, exes):
            n = demote(pid, dry_run)
            if n:
                touched.append((pid, comm, n))
    if verbose:
        for pid, comm, n in touched:
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    cmd = f.read().replace(b"\0", b" ").decode(errors="replace")[:120]
            except OSError:
                cmd = comm
            print(f"{'would set' if dry_run else 'set'} pid {pid} ({n} threads): {cmd}")
    return touched


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--once", action="store_true", help="one pass, then exit")
    ap.add_argument("--dry-run", action="store_true", help="one pass, change nothing")
    args = ap.parse_args()
    if args.once or args.dry_run:
        touched = one_pass(args.dry_run, verbose=True)
        print(f"{len(touched)} processes {'would change' if args.dry_run else 'changed'}")
        return
    print(f"agent-nice: nice {NICE} + idle IO for claude descendants and {LANES_DIR}*, every {INTERVAL_S}s",
          flush=True)
    procs_n = threads_n = 0
    comms = {}
    last = time.monotonic()
    while True:
        for _, comm, n in one_pass(False, verbose=False):
            procs_n += 1
            threads_n += n
            comms[comm] = comms.get(comm, 0) + 1
        if time.monotonic() - last >= SUMMARY_EVERY_S:
            if procs_n:
                top = ", ".join(f"{c}x{k}" for k, c in sorted(comms.items(), key=lambda kv: -kv[1])[:6])
                print(f"last {SUMMARY_EVERY_S}s: demoted {procs_n} processes / {threads_n} threads ({top})",
                      flush=True)
            procs_n = threads_n = 0
            comms = {}
            last = time.monotonic()
        time.sleep(INTERVAL_S)


if __name__ == "__main__":
    sys.exit(main())
