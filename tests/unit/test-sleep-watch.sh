#!/bin/bash
# tests/unit/test-sleep-watch.sh — sleep-watch (verifies every sleep via logind's
# PrepareForSleep) and sleep-verified --post-mortem. Nothing real is suspended,
# killed or notified: the gdbus signal source is a script (SLEEP_WATCH_SOURCE_CMD),
# systemctl / journalctl / logger / notify-send / ffplay / fusermount3 are stubs,
# /sys and /proc are fakes, HOME is a throwaway directory.
#
#   tests/unit/test-sleep-watch.sh        # exit 0 = all passed
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SW="$HERE/dotfiles/local-bin/sleep-watch"
SV="$HERE/dotfiles/local-bin/sleep-verified"
SN="$HERE/dotfiles/local-bin/laptop-state-snapshot"
FX="$HERE/tests/fixtures/sleep-verified"
T=$(mktemp -d -t sleep-watch-test.XXXXXX)
trap 'kill "${SLEEPER:-0}" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TRUE_L="/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"
FALSE_L="/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"

# ---------------------------------------------------------------- 1. parsing
echo "signal parsing (gdbus monitor lines, shape checked live 2026-10-03)"
OUT=$("$SW" --parse "$TRUE_L" "$FALSE_L" \
      "/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('7', objectpath '/org/freedesktop/login1/session/_37')" \
      "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForShutdown (true,)" \
      "Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1" "" | tr '\n' ' ')
check "true, false, then four non-sleep lines" '[[ "$OUT" == "true false - - - - " ]]'

echo "who asked (logind lines before the sleep)"
ctx() { printf '%b' "$1" | "$SW" --context; }
check "power key + suspend -> watch/power-key"  '[[ $(ctx "x systemd-logind[841]: Power key pressed short.\nx systemd-logind[841]: The system will suspend now!\n") == watch/power-key ]]'
check "Sleep() (UPower) -> watch/sleep-call"    '[[ $(ctx "x systemd-logind[841]: The system will sleep now!\n") == watch/sleep-call ]]'
check "plain systemctl suspend -> watch/suspend" '[[ $(ctx "x systemd-logind[841]: The system will suspend now!\n") == watch/suspend ]]'
check "lid -> watch/lid"                        '[[ $(ctx "x systemd-logind[841]: Lid closed.\nx: The system will suspend now!\n") == watch/lid ]]'
check "nothing logged -> watch/unknown"          '[[ $(ctx "") == watch/unknown ]]'

# ---------------------------------------------------------------- 2. the daemon loop
B="$T/bin"; F="$T/fake"; H="$T/home"; ST="$T/sys/sys/power/suspend_stats"
mkdir -p "$B" "$F" "$H" "$ST" "$T/proc/self" "$T/sys/sys/fs/fuse/connections/91"
for k in success fail failed_freeze; do echo 0 > "$ST/$k"; done
: > "$ST/last_failed_step"
cat > "$T/proc/self/mountinfo" <<'EOF'
96 30 0:91 / /run/user/1000/doc rw,nosuid,nodev - fuse.portal portal rw,user_id=1000
EOF
echo 0 > "$T/sys/sys/fs/fuse/connections/91/waiting"; : > "$T/sys/sys/fs/fuse/connections/91/abort"
cat > "$B/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$F/systemctl.log"
[[ "\$1" == --user ]] && exit 0
case "\$1" in
suspend)
    n=\$(( \$(cat "$F/inv" 2>/dev/null || echo 0) + 1 )); echo \$n > "$F/inv"
    if [[ -f "$F/retry_ok" ]]; then echo \$(( \$(cat $ST/success) + 1 )) > $ST/success
    else echo \$(( \$(cat $ST/fail) + 1 )) > $ST/fail; fi ;;
show)
    printf 'ActiveState=inactive\nResult=exit-code\nInvocationID=inv%s\nExecMainStatus=1\n' "\$(cat "$F/inv" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
printf '#!/bin/bash\ncat "%s/kernel.log"\n' "$F" > "$B/journalctl"
printf '#!/bin/bash\ntag=$2; shift 2; [[ "$1" == -- ]] && shift; echo "$tag: $*" >> "%s/logger.log"\n' "$F" > "$B/logger"
printf '#!/bin/bash\necho "$*" >> "%s/notify.log"; echo 7\n' "$F" > "$B/notify-send"
printf '#!/bin/bash\nexit 0\n' > "$B/ffplay"
printf '#!/bin/bash\necho "$*" >> "%s/fusermount.log"\n' "$F" > "$B/fusermount3"
printf '#!/bin/bash\necho "$*" >> "%s/snapshot.log"\n' "$F" > "$B/snapshot"
# input-activity-wait stand-in: logs its arguments, exit code from activity.rc (default 1 = timeout)
printf '#!/bin/bash\necho "$*" >> "%s/activity.log"; [[ "$(cat %s/activity.rc 2>/dev/null)" == 0 ]] && echo "activity: stand-in keyboard"; exit "$(cat %s/activity.rc 2>/dev/null || echo 1)"\n' "$F" "$F" "$F" > "$B/activity"
chmod +x "$B"/*
mkdir -p "$H/Programs/phone-file-transfer"
printf '#!/bin/bash\necho "$*" >> "%s/telegram.log"\n' "$F" > "$H/Programs/phone-file-transfer/telegram-send.py"
chmod +x "$H/Programs/phone-file-transfer/telegram-send.py"
echo "Oct 03 01:39:20 omarchy systemd-logind[841]: The system will suspend now!" > "$F/logind.log"
# A live stand-in named by the kernel: the post-mortem must never kill it, even with KILL_BLOCKERS=always.
sleep 300 & SLEEPER=$!; disown "$SLEEPER"
sed "s/pid:3798496 tgid:3798495 ppid:3798493/pid:$SLEEPER tgid:$SLEEPER ppid:$$/" \
    "$FX/kernel-2026-10-03-freeze-failed.log" > "$F/kernel.log"
printf 'KILL_BLOCKERS=always\nUNSTICK_FUSE=1\nREMOUNT_AFTER_UNSTICK=1\n' > "$T/conf"
MK="$T/run/sleep-verified.active"; mkdir -p "$T/run"
S="$T/state"; L="$S/last.json"

# source script: each argument is "true", "false", "ok" (count a successful suspend) or "sleep N"
watch() {
    {
        echo 'echo "Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1"'
        for a in "$@"; do
            case "$a" in
            true)  echo "sleep 0.4; echo '$TRUE_L'; sleep 0.4" ;;
            false) echo "echo '$FALSE_L'" ;;
            ok)    echo "echo \$(( \$(cat $ST/success) + 1 )) > $ST/success" ;;
            sleep*) echo "$a" ;;
            esac
        done
    } > "$F/source.sh"
    env PATH="$B:$PATH" HOME="$H" SLEEP_WATCH_SOURCE_CMD="bash $F/source.sh" SLEEP_WATCH_EXIT_ON_EOF=1 \
        SLEEP_WATCH_SETTLE=0 SLEEP_WATCH_SNAPSHOT="$B/snapshot" SLEEP_WATCH_JOURNAL_CMD="cat $F/logind.log" \
        SLEEP_VERIFIED_SYS="$T/sys" SLEEP_VERIFIED_PROC="$T/proc" SLEEP_VERIFIED_CONF="$T/conf" \
        SLEEP_VERIFIED_STATE_DIR="$S" SLEEP_VERIFIED_MARKER="$MK" SLEEP_VERIFIED_ACTIVITY_CMD="$B/activity" \
        timeout 60 "$SW" 2>/dev/null
}
lines() { wc -l < "$S/history.jsonl" 2>/dev/null || echo 0; }

echo "an unverified sleep that slept is recorded (the tooltip covers every path)"
watch true ok false; RC=$?
check "exits 0 at end of source"               '[[ $RC == 0 ]]'
check "subscribed line logged"                 'grep -q "^sleep-watch: subscribed: Monitoring signals" "$F/logger.log"'
check "last.json SLEPT, reason watch/suspend, source sleep-watch" '[[ $(jq -r "[.verdict,.reason,.source]|join(\" \")" "$L") == "SLEPT watch/suspend sleep-watch" ]]'
check "snapshot started at PrepareForSleep(true)" '[[ $(cat "$F/snapshot.log") == --quiet ]]'
check "no post-mortem, nothing suspended"       '! grep -q "FAILED sleep nobody verified" "$F/logger.log" && ! grep -q "^suspend" "$F/systemctl.log" 2>/dev/null'

echo "an unverified sleep that FAILED: post-mortem unsticks FUSE, retries once, the retry's own signals are ignored"
echo 3 > "$T/sys/sys/fs/fuse/connections/91/waiting"; touch "$F/retry_ok"; : > "$F/logger.log"
watch true false true ok false; RC=$?
check "post-mortem started once, with a retry"  '[[ $(grep -c "FAILED sleep nobody verified (watch/suspend); post-mortem + one retry" "$F/logger.log") == 1 ]]'
check "the retry signals are left to the post-mortem" 'grep -q "PrepareForSleep(true): owned by sleep-watch.s post-mortem" "$F/logger.log"'
check "exactly one retry suspend"               '[[ $(grep -c "^suspend" "$F/systemctl.log") == 1 ]]'
check "hung portal aborted, then remounted"     '[[ $(cat "$T/sys/sys/fs/fuse/connections/91/abort") == 1 ]] && grep -q "^-uz /run/user/1000/doc" "$F/fusermount.log"'
check "record: SLEPT after unstick + retry, observed attempt first" '[[ $(jq -r "[.verdict,.reason,(.remedy_applied|join(\",\")),.attempts[0].observed,(.attempts|length)]|join(\" \")" "$L") == "SLEPT watch/suspend unstick:/run/user/1000/doc,retry,remounted true 2" ]]'
check "observed failure names the blocker"      '[[ $(jq ".attempts[0].blockers[0].pid" "$L") == $SLEEPER ]]'
check "never kills (KILL_BLOCKERS=always is for the guard)" 'kill -0 $SLEEPER 2>/dev/null && ! grep -q SIGKILL "$F/logger.log"'
check "marker removed after the post-mortem"    '[[ ! -e "$MK" ]]'
check "retry waited for him: input-activity-wait --seconds 60 --settle 1" '[[ $(cat "$F/activity.log") == "--seconds 60 --settle 1" ]]'
check "sticky countdown card with how to cancel" 'grep -q -- "-u critical -t 0 -p Sleep failed at ? % — retrying in 60 s Press a key, move the mouse or touch the screen to cancel." "$F/notify.log"'
check "no activity -> retried as before (exit 0)" 'grep -q "no activity in 60s; retrying" "$F/logger.log" && grep -q "post-mortem finished (exit 0)" "$F/logger.log"'

echo "activity during the grace cancels the retry (his 2026-10-06 words)"
rm -f "$S/watch.json" "$F/activity.log"; echo 0 > "$F/activity.rc"; touch "$F/retry_ok"
: > "$F/logger.log"; : > "$F/systemctl.log"; : > "$F/notify.log"; : > "$F/telegram.log"
watch true false
check "nothing suspended"                       '! grep -q "^suspend" "$F/systemctl.log"'
check "post-mortem exit 3 (cancelled)"          'grep -q "post-mortem finished (exit 3)" "$F/logger.log" && grep -q "retry cancelled — activity during the grace (activity: stand-in keyboard)" "$F/logger.log"'
check "card replaced: Retry cancelled: you're back" 'grep -q -- "-r 7 Retry cancelled: you.re back Laptop is awake at ? %." "$F/notify.log"'
check "no FAILED alarm card"                    '! grep -q "Suspend FAILED" "$F/notify.log"'
check "one Telegram line"                       '[[ $(wc -l < "$F/telegram.log") == 1 ]] && grep -q "retry cancelled: you.re back" "$F/telegram.log"'
check "record: cancelled=activity, verdict FAILED" '[[ $(jq -r "[.cancelled,.verdict,(.remedy_applied|join(\",\"))]|join(\" \")" "$L") == "activity FAILED "*"retry-cancelled:activity"* && $(jq -r ".remedy_applied|index(\"retry\")" "$L") == null ]]'

echo "ACTIVITY_CANCELS=never: no grace, immediate retry (the 10-03 behaviour)"
rm -f "$S/watch.json" "$F/activity.log"; : > "$F/logger.log"; : > "$F/systemctl.log"
printf 'KILL_BLOCKERS=always\nUNSTICK_FUSE=1\nREMOUNT_AFTER_UNSTICK=1\nACTIVITY_CANCELS=never\n' > "$T/conf"
watch true false true ok false
check "no listener, retried at once, slept"     '[[ ! -e "$F/activity.log" && $(grep -c "^suspend" "$F/systemctl.log") == 1 && $(jq -r .verdict "$L") == SLEPT ]]'
printf 'KILL_BLOCKERS=always\nUNSTICK_FUSE=1\nREMOUNT_AFTER_UNSTICK=1\nRETRY_GRACE=5\n' > "$T/conf"
rm -f "$S/watch.json" "$F/activity.log"; echo 1 > "$F/activity.rc"
watch true false true ok false
check "RETRY_GRACE knob passed through"         '[[ $(cat "$F/activity.log") == "--seconds 5 --settle 1" ]]'
printf 'KILL_BLOCKERS=always\nUNSTICK_FUSE=1\nREMOUNT_AFTER_UNSTICK=1\n' > "$T/conf"; rm -f "$F/retry_ok"

echo "a second failure within 10 minutes: analyse + alert, no second retry"
rm -f "$F/retry_ok"; : > "$F/logger.log"; : > "$F/systemctl.log"; : > "$F/notify.log"
echo 0 > "$T/sys/sys/fs/fuse/connections/91/waiting"
watch true false; RC=$?
check "post-mortem without retry (10-minute cap)" 'grep -q "post-mortem, no retry (one already within 10 min)" "$F/logger.log"'
check "nothing suspended"                       '! grep -q "^suspend" "$F/systemctl.log"'
check "record FAILED, one observed attempt"     '[[ $(jq -r "[.verdict,(.attempts|length),.attempts[0].observed]|join(\" \")" "$L") == "FAILED 1 true" ]]'
check "sticky critical card, names the process" 'grep -q -- "-u critical -t 0 -p" "$F/notify.log" && [[ $(jq -r .message "$L") == "Suspend FAILED (watch/suspend, "*"pid $SLEEPER stuck in FUSE"* ]]'
check "still never kills"                       'kill -0 $SLEEPER 2>/dev/null'

echo "a sleep-verified run owns the sleep (marker with a live pid): the watcher only logs"
rm -f "$S/watch.json"; : > "$F/logger.log"
echo "$SLEEPER 1791020000" > "$MK"; N=$(lines)
watch true false
check "deferred at true and at false"           'grep -q "PrepareForSleep(true): owned by sleep-verified (pid $SLEEPER)" "$F/logger.log" && grep -q "PrepareForSleep(false): FAILED.*owned by sleep-verified" "$F/logger.log"'
check "no post-mortem, no record"               '! grep -q "FAILED sleep nobody verified" "$F/logger.log" && [[ $(lines) == $N ]]'

echo "a stale marker (dead pid) does not defer"
echo "999999 1791020000" > "$MK"; : > "$F/logger.log"; N=$(lines)
watch true ok false
check "unverified sleep recorded"               '[[ $(lines) == $((N + 1)) ]] && grep -q "unverified sleep starting" "$F/logger.log"'
rm -f "$MK"

echo "PrepareForSleep(false) without a true (watcher started mid-sleep)"
: > "$F/logger.log"; N=$(lines)
watch false
check "ignored, nothing recorded"               'grep -q "without a true" "$F/logger.log" && [[ $(lines) == $N ]]'

echo "sleep-verified holds the marker while it runs (so the watcher defers to it)"
: > "$F/kernel.log"; touch "$F/retry_ok"
cat > "$B/systemctl" <<EOF
#!/bin/bash
[[ "\$1" == suspend ]] && cat "$MK" > "$F/marker-during" && echo \$(( \$(cat $ST/success) + 1 )) > $ST/success
[[ "\$1" == show ]] && printf 'ActiveState=inactive\nInvocationID=x%s\n' "\$RANDOM"
exit 0
EOF
env PATH="$B:$PATH" HOME="$H" SLEEP_VERIFIED_SYS="$T/sys" SLEEP_VERIFIED_PROC="$T/proc" SLEEP_VERIFIED_CONF="$T/conf" \
    SLEEP_VERIFIED_STATE_DIR="$S" SLEEP_VERIFIED_MARKER="$MK" "$SV" --reason user --no-notify 2>/dev/null; RC=$?
check "marker held during the suspend, its own pid" '[[ $RC == 0 && -s "$F/marker-during" && $(cut -d" " -f1 "$F/marker-during") =~ ^[0-9]+$ ]]'
check "marker removed afterwards"               '[[ ! -e "$MK" ]]'

# ---------------------------------------------------------------- 2b. input-activity-wait
echo "input-activity-wait: what counts as him"
IAW="$HERE/dotfiles/local-bin/input-activity-wait"
OUT=$(python3 - "$IAW" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("iaw", sys.argv[1])
spec = importlib.util.spec_from_loader("iaw", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
# EV_SYN 0, EV_KEY 1, EV_REL 2, EV_ABS 3, EV_MSC 4, EV_SW 5, EV_LED 17
print(" ".join(str(int(m.is_activity(t))) for t in (0, 1, 2, 3, 4, 5, 17)))
EOF
)
check "key/rel/abs count; syn/msc/switch(lid)/led do not" '[[ "$OUT" == "0 1 1 1 0 0 0" ]]'
OUT=$("$IAW" --bogus 2>&1); RC=$?
check "bad argument -> exit 2"                  '[[ $RC == 2 ]]'
if [[ -w /dev/uinput ]] && python3 -c "import evdev" 2>/dev/null; then
    # A fake device with only ABS_MISC + MSC_SCAN: no compositor treats it as a pointer,
    # keyboard or touchscreen, so its events never reach his session.
    OUT=$(python3 - "$IAW" <<'EOF'
import subprocess, sys, time
from evdev import UInput, AbsInfo, ecodes as e
iaw = sys.argv[1]
ui = UInput({e.EV_ABS: [(e.ABS_MISC, AbsInfo(0, 0, 255, 0, 0, 0))], e.EV_MSC: [e.MSC_SCAN]},
            name="input-activity-wait-test")
time.sleep(0.5)
def run(extra, script, secs="3"):
    p = subprocess.Popen([iaw, "--seconds", secs, "--settle", "1", "--device", ui.device.path] + extra,
                         stdout=subprocess.PIPE, text=True)
    t0 = time.monotonic()
    for at, typ, code, val in script:
        time.sleep(max(0, at - (time.monotonic() - t0)))
        ui.write(typ, code, val); ui.syn()
    out, _ = p.communicate(timeout=10)
    return f"{p.returncode}:{round(time.monotonic() - t0)}:{out.strip()[:40]}"
res = [
    run([], [(0.3, e.EV_ABS, e.ABS_MISC, 5), (1.5, e.EV_MSC, e.MSC_SCAN, 7), (1.8, e.EV_ABS, e.ABS_MISC, 9)]),
    run([], [(0.3, e.EV_ABS, e.ABS_MISC, 5), (1.5, e.EV_MSC, e.MSC_SCAN, 7)], "2.5"),
    run(["--ignore-name", "activity-wait-test"], [(1.5, e.EV_ABS, e.ABS_MISC, 3)], "2.5"),
]
ui.close()
print("|".join(res))
EOF
)
    IFS='|' read -r A1 A2 A3 <<<"$OUT"
    check "fake device: event after the 1 s settle -> exit 0, names the device" '[[ "$A1" == 0:2:"activity: input-activity-wait-test"* ]]'
    check "fake device: only a settle-time event + MSC -> exit 1 (timeout)" '[[ "$A2" == 1:* ]]'
    check "--ignore-name skips the device -> exit 1" '[[ "$A3" == 1:* ]]'
else
    echo "  skip input-activity-wait UInput checks (/dev/uinput not writable or no evdev)"
fi

# ---------------------------------------------------------------- 3. snapshot transcript match
echo "laptop-state-snapshot: a process without a session file gets the newest transcript since it started"
OUT=$(HOME="$T/h2" python3 - "$SN" <<'EOF'
import importlib.machinery, importlib.util, json, os, sys, time
home = os.environ["HOME"]; d = os.path.join(home, ".claude/projects/-home-u-Programs-star-trek")
os.makedirs(d, exist_ok=True)
for name, age in (("old", 5000), ("claimed", 10), ("mine", 60)):
    p = os.path.join(d, name + ".jsonl"); open(p, "w").close()
    t = time.time() - age; os.utime(p, (t, t))
loader = importlib.machinery.SourceFileLoader("sn", sys.argv[1])
spec = importlib.util.spec_from_loader("sn", loader); sn = importlib.util.module_from_spec(spec); loader.exec_module(sn)
now = time.time()
procs = [{"pid": 1, "cwd": "/home/u/Programs/star trek", "started": now - 600},
         {"pid": 2, "cwd": "/home/u/Programs/star trek", "started": now - 300, "sessionId": "claimed"},
         {"pid": 3, "cwd": "/home/u/Programs/star trek", "started": now - 30}]
sn.match_transcripts(procs)
print(json.dumps([p.get("transcript_guess", {}).get("sessionId") for p in procs]))
EOF
)
check "skips the claimed one and the one older than the process" '[[ "$OUT" == "[\"mine\", null, null]" ]]'

echo
echo "passed $PASS, failed $FAIL"
[[ $FAIL == 0 ]]
