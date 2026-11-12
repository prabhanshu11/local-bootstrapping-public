# OOM Protection Lessons Learned

> On 2026-02-23, `build_phase1_dataset.py` consumed 19.6 GB RAM in 7 minutes, exhausting
> 32 GB RAM + 12 GB swap, and froze the entire system. Three Claude Code sessions were
> running. A hard reboot was required. These are the lessons.

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| Incident report | `~/Programs/utilities/freeze-monitor/analysis/incident-20260223-oom-freeze.md` | Full timeline and diagnosis |
| freeze-monitor | `~/Programs/utilities/freeze-monitor/freeze-monitor.sh` | 3-second system health sampling |
| Claude Code hook | `~/.claude/hooks/memory-pressure.sh` | Memory pressure feedback to Claude sessions |
| Velocity parser | `~/Programs/datalake/parsers/velocity_parser.py` | JSONL → datalake ingestion |
| Setup script | `~/Programs/utilities/freeze-monitor/setup-oom-protection.sh` | Install all components |

---

## Lesson 1: The System Has No Effective OOM Protection (Feb 2026)

### Symptom
- System froze completely: keyboard unresponsive, Hyprland locked, no OOM kill messages
- Required hard reboot (power button hold)
- 32 GB RAM + 12 GB swap fully exhausted in 7 minutes by a single process

### Root Cause
The Linux OOM killer didn't fire in time. When swap fills, the system enters I/O thrash:
every page fault requires a disk read/write, CPU spends 49% on I/O wait, and the kernel
never gets enough CPU time to evaluate which process to kill. The system deadlocks before
the OOM killer can intervene.

### Fix
Built a 3-layer protection system:
1. **freeze-monitor** writes `/tmp/freeze-monitor-state.json` every 3 seconds with severity classification
2. **Claude Code hook** reads the state file on every Bash/Task tool call:
   - CRITICAL (< 2 GB available or swap > 90%): **blocks tool execution**
   - WARNING (< 4 GB or velocity > 500 MB/s): detailed advisory with time windows
   - ELEVATED (velocity > 300 MB/s sustained): brief informational note
   - NOMINAL: silent
3. **Datalake ingestion** stores high-res time-series for long-term analysis

### Key Insight: Detection Speed > Absolute Thresholds
The key metric is **velocity** (MB/s), not absolute usage. The process consumed 19.6 GB
in 7 minutes = 46 MB/s sustained. Velocity-based detection caught this pattern within
15 seconds of sustained growth, long before absolute thresholds were breached.

---

## Lesson 2: AI Agents Launch Unbounded Memory Consumers (Feb 2026)

### Symptom
- 3 concurrent Claude Code sessions, each spawning memory-heavy subprocesses
- Session 1 (Vision Foundation): `build_phase1_dataset.py` extracting 500+ frames per MKV via ffmpeg
- Session 2 (Active Scene Manager): YOLO v8 inference on 2304x1296 RTSP frames
- Session 3 (Financial Dashboard): Gmail email batch loading + parsing

### Root Cause
AI agents run shell commands that spawn subprocesses with no memory ceiling. Each session
had an unbounded bulk-loading pattern:
- Frame extraction: accumulating decoded numpy arrays in a dict (500 frames x 150KB each)
- YOLO inference: high-resolution frame buffers + model weights + inference memory
- Email parsing: loading 100+ emails into Python lists without pagination

No session had any awareness of total system memory state or what other sessions were consuming.

### Fix
The hook creates a feedback loop: Claude Code now learns about memory pressure in real time.
When one session starts consuming heavily, ALL sessions get informed via the state file.
At CRITICAL, ALL sessions are blocked from launching more processes.

### Key Insight: The Problem Is Coordination, Not Limits
A single session using 10 GB is fine on a 32 GB machine. Three sessions each using 10 GB
isn't. No individual session was "wrong" — the failure was that none could see the total.
The hook solves this by broadcasting system-wide state to all sessions simultaneously.

---

## Lesson 3: More RAM Doesn't Solve Unbounded Processes (Feb 2026)

### Symptom
- Old system: 16 GB RAM → OOM freezes
- New system: 32 GB RAM + 8 GB SSD swap → same freeze, just took 7 minutes instead of 3
- Upgrading from 16 to 32 GB only doubled the time-to-crash, not the safety

### Root Cause
Headroom ≠ safety. An unbounded process will consume any amount of RAM given enough time.
Swap extends the runway but makes the crash worse: thrashing encrypted SSD swap is far
more catastrophic than hitting a simple OOM kill. More RAM just makes the slope gentler —
the cliff is still there.

### Fix
Velocity-based detection catches the **rate** of consumption, not the absolute level.
Whether you have 16 GB or 128 GB, a process growing at 46 MB/s sustained is anomalous.
The thresholds are absolute for the final safety net (< 2 GB available), but the early
warning system works regardless of total RAM.

### Key Insight: Scale Your Detection, Not Just Your Resources
When you upgrade hardware, also update monitoring. The freeze-monitor config file
(`freeze-monitor.conf`) allows per-platform thresholds so the same detection logic
works on a 4 GB Raspberry Pi and a 32 GB desktop.

---

## Lesson 4: Encrypted Swap Amplifies Thrashing (Feb 2026)

### Symptom
- I/O wait reached 49% during the incident
- System became unresponsive before swap was fully exhausted
- Even with NVMe SSD, swap I/O was the bottleneck

### Root Cause
The system uses LUKS-encrypted SSD swap. Every page fault during thrashing requires:
1. Read encrypted page from SSD
2. Decrypt page (CPU-intensive)
3. If another page needs evicting: encrypt + write to SSD

At high swap churn, this creates a feedback loop: CPU is split between the actual workload
and encrypting/decrypting swap pages. The 49% I/O wait means half the CPU cycles were
spent on swap I/O, leaving less CPU for the OOM killer to evaluate processes.

zram (4 GB compressed RAM swap) saturated first, forcing all overflow to the encrypted
SSD swap which is orders of magnitude slower per page operation.

### Fix
The velocity thresholds are calibrated to trigger WARNING before swap saturation begins.
The goal is to block new memory-heavy processes while there's still enough headroom for
the system to remain responsive. By the time swap is at 90%, it's too late — the CRITICAL
block at that point is a last resort, not a reliable protection.

### Key Insight: Your Swap Configuration Affects Your Safety Window
Encrypted swap narrows the window between "swap is active" and "system is unresponsive."
Plan your monitoring thresholds accordingly — trigger earlier than you think you need to.

---

## Prevention Checklist

Before launching memory-heavy work:
- [ ] `setup-oom-protection.sh --check` — verify hook + service are running
- [ ] Data-loading scripts have explicit batch size limits (e.g., `--max-per-mkv 50`, not 500)
- [ ] Email/API fetchers use pagination, not load-all-into-memory
- [ ] ML inference specifies batch size and max resolution
- [ ] Check current memory before starting: `cat /tmp/freeze-monitor-state.json | jq .severity`

After an incident:
- [ ] Ingest velocity data: `python3 ~/Programs/datalake/parsers/velocity_parser.py`
- [ ] Check `v_memory_anomalies` view for the event timeline
- [ ] Document in `freeze-monitor/analysis/incident-YYYYMMDD-*.md`

---

## Lesson 5: Always-On Services Accumulate Silently (Mar 2026)

### Symptom
- System sluggish, cursor freezing intermittently
- Swap at 91% (10.6/12.3 GB), I/O wait at 46%
- No single runaway process — all services looked "normal" individually

### Root Cause
Over 6 days, long-running services accumulated without anyone noticing:
- QEMU Windows VM: 7.6 GB (running since Mar 4)
- Docker Windows container (`dockurr/windows`): running since Mar 4 — **two Windows instances**
- Firefox with 15+ tabs: ~8-10 GB combined (running since Mar 4)
- Elasticsearch (datalake): 900 MB, auto-started via `restart: unless-stopped`
- local-whisper: ~1 GB idle ML model in swap, auto-started via systemd

Unlike Lesson 1 (single process, 7 minutes to crash), this was gradual — no velocity spike,
just a slow fill over days until swap hit 91% and thrashing began.

### Fix
Killed both Windows instances (freed ~8 GB immediately). Identified that:
1. Docker `restart: unless-stopped` silently auto-starts dev stacks on every boot
2. local-whisper loads an ML model at boot and sits idle consuming memory
3. No visibility into "what heavy services are running right now"

### Key Insight: Velocity Detection Misses Slow Accumulation
The freeze-monitor catches fast memory consumers (46 MB/s = alert in 15 seconds).
But 8 GB accumulated over 6 days is ~0.015 MB/s — far below any velocity threshold.
Need a complementary check: "total swap usage" or "services running longer than N days."

### Prevention
- Use `restart: no` for dev Docker stacks (Elasticsearch, datalake)
- Audit `restart: unless-stopped` containers periodically
- Consider on-demand start for local-whisper instead of boot-time autostart
- Add a "heavy service inventory" check to freeze-monitor or session-start

Incident report: `~/Programs/utilities/freeze-monitor/analysis/incident-20260310-swap-thrash.md`
