# agent-nice — agent work never starves the UI or the tracker

Installed on the laptop and the desktop by `scripts/setup-agent-nice.sh` (user half) and
`sudo scripts/setup-agent-nice.sh --root` (root half). Survives reboots: a user service
(`default.target`, both machines linger) plus a static systemd drop-in.

## Why

2026-09-30 ~01:30–02:05 on the laptop: the cursor stuttered, the UI stopped refreshing, keystrokes
echoed late. Measured at 02:06: load 23 on 8 threads, CPU 97 °C pinned at 1.7 GHz, swap 10.5/12 GB,
IO pressure 96 %. The load was agent lanes (three pytest suites, voice renders, a YOLO bench, a
video replay, footage analysis) sharing the CPU with Hyprland at equal priority. The main session
reniced those jobs by hand (`renice -n 19` + `ionice -c3`); he asked for that to be permanent, on
both machines, in this repo. The standing rule that heavy compute runs on the desktop
(star-trek-camera preamble §12) is the other half; this is the safety net for whatever still runs.

## What it does

| Piece | Where | Effect |
|---|---|---|
| `agent-nice` daemon | `~/.local/bin/agent-nice`, user service `agent-nice.service` | Every 2 s: every thread of every descendant of a Claude Code session, and every process whose cwd is under `~/lanes/`, gets nice 19 + idle IO class. ~26 ms per pass. |
| session-scope weight | `/etc/systemd/system/session-.scope.d/50-agent-work-weight.conf` | Every ssh/login session scope gets `CPUWeight=1` (default 100): the cgroup equivalent of nice 19. Applies to running sessions at install too. |

Left alone on purpose:
- Claude session processes themselves (`claude`, `claude -p`, Remote Control's per-session
  children whose name is the version, e.g. `2.1.283`): the TUI and phone sessions stay snappy;
  only what they spawn is demoted.
- GUI apps an agent launches (chrome, firefox, waybar, swaybg, ghostty, mpv, … — `SKIP_EXES`)
  and everything under them.
- It only ever raises nice. Anything already at 19 or deliberately niced stays as it was.

## Two things that made the manual renice weaker than it looked

1. **Nice is per thread on Linux.** `renice -p PID` sets only the thread whose tid is PID. numpy,
   torch and ffmpeg worker threads that already existed kept nice 0 (`ps -eLo pid,tid,ni`). The
   daemon walks `/proc/PID/task/*`.
2. **Nice does not cross cgroups.** With the cpu controller on, the kernel first splits CPU between
   sibling cgroups by `cpu.weight`, then by nice inside each. On the laptop Hyprland, ghostty,
   claude and its jobs all sit in one cgroup (`session.slice/wayland-wm@hyprland.desktop.service`),
   so nice works there. On the desktop the tracker runs in `user@1000.service/app.slice/
   star-trek-camera.service` while each lane arrives over ssh in its own `session-N.scope`, weight
   100 each: nine niced lanes still took nine shares to the tracker's one. Hence the drop-in.
   (Autogroup is irrelevant: it only applies to tasks in the root cpu cgroup.)

## Opting out (a job that needs full priority, e.g. a timing benchmark)

- On the desktop over ssh: `systemd-run --user --scope --quiet <cmd>` moves the job into
  `user@1000.service/app.slice` at the default weight (tested 2026-09-30). Nice still applies if the
  job's cwd is under `~/lanes/`, so run it from elsewhere or say so in the lane doc.
- From a Claude Bash tool: there is no opt-out short of `systemctl --user stop agent-nice` (then
  `start` it again). Benchmarks belong on the desktop anyway.
- GUI apps from an agent: launch with `hyprctl dispatch exec <app>` so Hyprland is the parent and
  the app starts at nice 0. A GUI app started with `app &` from an already-niced shell inherits
  nice 19 and an unprivileged user cannot lower it again.

## Check it

```bash
systemctl --user status agent-nice                 # running?
journalctl --user -u agent-nice -n 20              # 5-minute summaries of what it demoted
agent-nice --dry-run                               # what one pass would change right now
ps -eLo pid,tid,ni,comm --sort=-pcpu | head        # per-thread nice
cat /sys/fs/cgroup/user.slice/user-1000.slice/session-*.scope/cpu.weight   # new sessions: 1
```

`systemctl daemon-reload` applies the drop-in to session scopes that are ALREADY running too, not
only to new ones (seen 2026-09-30 02:41 on the desktop: the running lane sessions 786 and 1054 went
100 -> 1). A benchmark running at install time switches weight mid-run; under no contention it makes
no difference (`cpu.pressure` of the scope stays ~0), under contention it does.
