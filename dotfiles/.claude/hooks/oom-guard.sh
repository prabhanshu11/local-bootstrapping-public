#!/usr/bin/env bash
# oom-guard.sh — Claude Code PreToolUse hook (global, matcher "*").
#
# Warns an agent — and at a critical threshold, blocks the tool call — when the
# system is heading toward an out-of-memory crash, naming the offending process
# so the agent (or user) can act.
#
# Born from a 2026-05-22 incident: an agent-spawned `build_thumbs.py`, launched
# detached (`nohup … &`) and left unwatched, leaked to ~27 GB and triggered a
# kernel OOM kill that took down the whole desktop session.
#
# FAIL-SAFE CONTRACT: this hook must never break a session. On ANY error or
# uncertainty it exits 0 with no output (= allow). It emits a `deny` ONLY on a
# clean, confident CRITICAL classification. The exit code is ALWAYS 0; blocking
# is done purely via the JSON permissionDecision field.
#
# ATTRIBUTION: a process is reported as "spawned by this agent" only when it is
# a live descendant of a `claude` process (reliable). Otherwise it is reported
# neutrally — the hook never tells an agent to kill something it cannot confirm
# is the agent's (e.g. a browser or a user service).
#
# Disable without editing settings.json:  touch ~/.claude/hooks/.oom-guard-off

[ -e "$HOME/.claude/hooks/.oom-guard-off" ] && exit 0

# ---------- tunables (env-overridable; the test suite uses these) ----------
# Thresholds are on MemAvailable in absolute MB — the real OOM signal. Swap usage
# alone is NOT a trigger: pages swapped out during an old peak stay there while
# RAM sits 75% free, which made this hook warn on every tool call for no reason
# (2026-09-24). The user's rule: memory only matters at ~700 MB left.
WARN_AVAIL_MB=${OOM_GUARD_WARN_AVAIL_MB:-2048}  # warn when MemAvailable below this
CRIT_AVAIL_MB=${OOM_GUARD_CRIT_AVAIL_MB:-700}   # critical (blocks) below this
BIG_PROC_PCT=${OOM_GUARD_BIG_PROC_PCT:-55}     # warn when one process exceeds this % of RAM
GROWTH_WARN_GB=${OOM_GUARD_GROWTH_GB:-3}       # warn when the worst process grew >= this many GB since last check
DEBOUNCE_SECS=${OOM_GUARD_DEBOUNCE:-600}       # min seconds between repeated WARN emissions (same level)
VEL_WARN_MB_S=${OOM_GUARD_VEL_WARN_MB_S:-500}  # warn on sustained growth at/above this (MB/s)
VEL_SUSTAIN_S=${OOM_GUARD_VEL_SUSTAIN_S:-6}    # ...held for at least this long
CRIT_ETA_S=${OOM_GUARD_CRIT_ETA_S:-30}         # critical when RAM runs out within this many seconds at that rate
FM_STATE=${OOM_GUARD_FM_STATE:-/tmp/freeze-monitor-state.json}  # freeze-monitor sensor (optional)
FM_STALE_S=30
# OOM_GUARD_FAKE_WORST="pid:rss_kb:command"    # test-only: inject a synthetic worst process

# ---------- helper: kB -> "N.N" GB string ----------
gb() {
  local kb=$1 t
  case "$kb" in ''|*[!0-9]*) printf '?'; return;; esac
  t=$(( kb * 10 / 1024 / 1024 ))
  printf '%d.%d' $(( t / 10 )) $(( t % 10 ))
}

# ---------- helper: is PID a live descendant of a `claude` process? ----------
is_claude_descendant() {
  local pid=$1 depth=0 ppid comm
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 50 ]; do
    comm="$(cat /proc/"$pid"/comm 2>/dev/null)" || return 1
    [ "$comm" = "claude" ] && return 0
    ppid="$(awk '/^PPid:/{print $2; exit}' /proc/"$pid"/status 2>/dev/null)"
    case "$ppid" in ''|*[!0-9]*) return 1;; esac
    [ "$ppid" = "$pid" ] && return 1
    pid="$ppid"; depth=$(( depth + 1 ))
  done
  return 1
}

# ---------- read hook stdin (best-effort; `timeout` guards against a hang) ----------
input="$(timeout 2 cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0   # no jq -> cannot emit valid JSON -> no guard

tool_name=""; command_str=""; session_id="default"
if [ -n "$input" ]; then
  tool_name="$(printf '%s' "$input"   | jq -r '.tool_name // ""'          2>/dev/null)" || tool_name=""
  command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || command_str=""
  sid="$(printf '%s' "$input"         | jq -r '.session_id // ""'         2>/dev/null)" || sid=""
  case "$sid" in ''|null) :;; *) session_id="$sid";; esac
fi

# ---------- read memory state ----------
[ -r /proc/meminfo ] || exit 0
mem_total=$(awk '/^MemTotal:/    {print $2; exit}' /proc/meminfo 2>/dev/null)
mem_avail=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
swap_total=$(awk '/^SwapTotal:/  {print $2; exit}' /proc/meminfo 2>/dev/null)
swap_free=$(awk '/^SwapFree:/    {print $2; exit}' /proc/meminfo 2>/dev/null)
case "$mem_total" in ''|*[!0-9]*) exit 0;; esac
case "$mem_avail" in ''|*[!0-9]*) exit 0;; esac
[ "$mem_total" -gt 0 ] 2>/dev/null || exit 0
case "$swap_total" in ''|*[!0-9]*) swap_total=0;; esac
case "$swap_free"  in ''|*[!0-9]*) swap_free=0;;  esac

mem_avail_pct=$(( mem_avail * 100 / mem_total ))
swap_used_pct=0
[ "$swap_total" -gt 0 ] && swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))

# ---------- find the largest memory consumer (excluding the claude runtime itself) ----------
worst_pid=""; worst_rss=0; worst_cmd=""
if [ -n "${OOM_GUARD_FAKE_WORST:-}" ]; then
  worst_pid="${OOM_GUARD_FAKE_WORST%%:*}"
  _rest="${OOM_GUARD_FAKE_WORST#*:}"
  worst_rss="${_rest%%:*}"
  worst_cmd="${_rest#*:}"
  case "$worst_rss" in ''|*[!0-9]*) worst_rss=0;; esac
else
  while read -r p r c a; do
    case "$p" in ''|*[!0-9]*) continue;; esac
    case "$r" in ''|*[!0-9]*) continue;; esac
    [ "$c" = "claude" ] && continue          # the agent runtime itself, not a spawned script
    case "$a" in */claude/versions/*) continue;; esac   # runtime binary is named by version (comm "2.1.281")
    [ "$p" = "$$" ] && continue              # this hook
    worst_pid="$p"; worst_rss="$r"; worst_cmd="$a"
    break                                    # ps is RSS-sorted desc -> first match is the worst
  done < <(ps -eo pid=,rss=,comm=,args= --sort=-rss 2>/dev/null | head -n 30)
fi

worst_pct=0
[ -n "$worst_pid" ] && [ "$worst_rss" -gt 0 ] 2>/dev/null && worst_pct=$(( worst_rss * 100 / mem_total ))

# attribution: only "agent" when provably a live descendant of a claude process
attributed="unknown"
if [ -n "$worst_pid" ] && [ -z "${OOM_GUARD_FAKE_WORST:-}" ] && is_claude_descendant "$worst_pid"; then
  attributed="agent"
fi

# ---------- trend: compare against the previous sample ----------
state_file="/tmp/claude-oom-guard.${session_id}.state"
now=$(date +%s 2>/dev/null || echo 0)
prev_pid=""; prev_rss=0; prev_emit=0; prev_level="ok"
if [ -r "$state_file" ]; then
  IFS='|' read -r _pc prev_pid prev_rss prev_emit prev_level < "$state_file" 2>/dev/null
  case "$prev_rss"  in ''|*[!0-9]*) prev_rss=0;;  esac
  case "$prev_emit" in ''|*[!0-9]*) prev_emit=0;; esac
fi
growth_kb=0
if [ -n "$worst_pid" ] && [ "$worst_pid" = "$prev_pid" ] && [ "$worst_rss" -gt "$prev_rss" ]; then
  growth_kb=$(( worst_rss - prev_rss ))
fi
growth_trips=0
[ $(( growth_kb * 10 / 1024 / 1024 )) -ge $(( GROWTH_WARN_GB * 10 )) ] && growth_trips=1

# ---------- velocity from freeze-monitor (the sensor, where it runs) ----------
# freeze-monitor samples every 3 s, so it sees how fast memory is being eaten
# between tool calls — something a per-call hook cannot. This hook is the single
# messenger to agents; the sensor supplies data, the thresholds live here.
# No monitor (e.g. laptop) or stale file -> velocity unknown, meminfo-only.
vel_mb_s=0; vel_sustained_s=0; eta_s=""
if [ -r "$FM_STATE" ]; then
  fm_age=$(( now - $(stat -c %Y "$FM_STATE" 2>/dev/null || echo 0) ))
  if [ "$fm_age" -le "$FM_STALE_S" ]; then
    read -r _v _vs < <(jq -r '"\((.velocity_mb_s // 0) | floor) \((.velocity_sustained_s // 0) | floor)"' "$FM_STATE" 2>/dev/null)
    case "$_v"  in ''|*[!0-9-]*) _v=0;;  esac
    case "$_vs" in ''|*[!0-9]*)  _vs=0;; esac
    vel_mb_s=$_v; vel_sustained_s=$_vs
  fi
fi
vel_trips=0
if [ "$vel_mb_s" -ge "$VEL_WARN_MB_S" ] && [ "$vel_sustained_s" -ge "$VEL_SUSTAIN_S" ]; then
  vel_trips=1
  eta_s=$(( mem_avail / 1024 / vel_mb_s ))
fi

# ---------- classify ----------
mem_avail_mb=$(( mem_avail / 1024 ))
level="ok"
if [ "$mem_avail_mb" -lt "$WARN_AVAIL_MB" ] || [ "$worst_pct" -ge "$BIG_PROC_PCT" ] \
   || [ "$growth_trips" -eq 1 ] || [ "$vel_trips" -eq 1 ]; then
  level="warn"
fi
if [ "$mem_avail_mb" -lt "$CRIT_AVAIL_MB" ] \
   || { [ -n "$eta_s" ] && [ "$eta_s" -lt "$CRIT_ETA_S" ]; }; then
  level="critical"
fi

# ---------- state writer (runs on every path so trend data stays fresh) ----------
last_emit=$prev_emit; last_level=$prev_level
write_state() {
  printf '%s|%s|%s|%s|%s\n' "$now" "$worst_pid" "$worst_rss" "$last_emit" "$last_level" \
    > "$state_file" 2>/dev/null || true
}
record_emit() { last_emit=$now; last_level="$level"; }

# ---------- OK: silent allow ----------
if [ "$level" = "ok" ]; then
  write_state
  exit 0
fi

# ---------- WARN debounce: one warning per level per DEBOUNCE_SECS ----------
# (not keyed on PID — the top consumer flips between processes, which defeated
# the old per-PID debounce). Fast growth always re-warns: that's the leak signal.
if [ "$level" = "warn" ] && [ "$prev_level" = "warn" ] && [ "$growth_trips" -eq 0 ] && [ "$vel_trips" -eq 0 ] \
   && [ $(( now - prev_emit )) -lt "$DEBOUNCE_SECS" ]; then
  write_state
  exit 0
fi

# ---------- build the human-readable detail ----------
base="System memory ${level^^}: $(gb "$mem_avail") GB of $(gb "$mem_total") GB RAM available (${mem_avail_pct}%), swap $(gb $(( swap_total - swap_free )))/$(gb "$swap_total") GB used (${swap_used_pct}%)."
[ "$vel_trips" -eq 1 ] && base="$base Memory is being consumed at ${vel_mb_s} MB/s (sustained ${vel_sustained_s}s) — RAM runs out in ~${eta_s}s at this rate."

culprit=""
if [ -n "$worst_pid" ]; then
  proc="PID ${worst_pid} — $(gb "$worst_rss") GB RSS (${worst_pct}% of RAM) — $(printf '%s' "$worst_cmd" | cut -c1-130)"
  [ "$growth_trips" -eq 1 ] && proc="${proc} [growing fast: +$(gb "$growth_kb") GB since the last check]"
  if [ "$attributed" = "agent" ]; then
    culprit="A process spawned by this agent is the largest consumer: ${proc}. If it is a runaway or finished script, kill it: kill ${worst_pid}."
  else
    culprit="Largest memory consumer: ${proc}. If this is a script you spawned, kill it ( kill ${worst_pid} ); if it is a user service or app such as a browser, do NOT kill it — alert the user instead."
  fi
fi
short="OOM-guard: RAM ${mem_avail_pct}% free, swap ${swap_used_pct}% used (${level})"

# ---------- WARN: non-blocking context injection ----------
if [ "$level" = "warn" ]; then
  msg="$base"
  [ -n "$culprit" ] && msg="$msg $culprit"
  msg="$msg Don't start new memory-heavy jobs until this clears; no need to stop work already running. Blocking starts below ${CRIT_AVAIL_MB} MB available."
  record_emit; write_state
  jq -n --arg c "$msg" --arg s "$short" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c},systemMessage:$s}' 2>/dev/null
  exit 0
fi

# ---------- CRITICAL ----------
# kill/pkill/diagnostics are allowed through even at critical, so the agent can
# always remediate; everything else is blocked to stop it piling on more load.
is_remediation=0
if [ "$tool_name" = "Bash" ] && [ -n "$command_str" ]; then
  if printf '%s' "$command_str" | grep -qE '\b(kill|pkill|killall|free|top|htop|vmstat|ps)\b' \
     || printf '%s' "$command_str" | grep -q '/proc/'; then
    is_remediation=1
  fi
fi

if [ "$is_remediation" -eq 0 ]; then
  reason="$base ${culprit} This tool call is BLOCKED to prevent an out-of-memory crash of the session — kill/pkill and diagnostics (free, ps) are still allowed. Free memory or alert the user, then continue."
  record_emit; write_state
  jq -n --arg r "$reason" --arg s "$short" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r},systemMessage:$s}' 2>/dev/null
  exit 0
fi

# critical + a remediation command -> allow it, with a forceful warning
msg="$base ${culprit} MEMORY CRITICAL — do not start new work until memory is freed."
record_emit; write_state
jq -n --arg c "$msg" --arg s "$short" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c},systemMessage:$s}' 2>/dev/null
exit 0
