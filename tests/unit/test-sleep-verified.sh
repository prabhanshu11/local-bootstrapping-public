#!/bin/bash
# tests/unit/test-sleep-verified.sh — sleep-verified, battery-guard's use of it,
# and laptop-state-restore. Nothing real is suspended, killed or notified:
# systemctl, journalctl, logger, notify-send, ffplay and fusermount3 are stubs,
# /sys and /proc are fakes, HOME is a throwaway directory.
#
# Fixture tests/fixtures/sleep-verified/kernel-2026-10-03-freeze-failed.log is
# the real kernel log of the 2026-10-03 01:39 freeze failure.
#
#   tests/unit/test-sleep-verified.sh        # exit 0 = all passed
set -u
export SLEEP_VERIFIED_MARKER="${TMPDIR:-/tmp}/sleep-verified-test-marker.$$"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SV="$HERE/dotfiles/local-bin/sleep-verified"
BG="$HERE/dotfiles/local-bin/battery-guard"
RS="$HERE/dotfiles/local-bin/laptop-state-restore"
FX="$HERE/tests/fixtures/sleep-verified"
T=$(mktemp -d -t sleep-verified-test.XXXXXX)
trap 'kill "${SLEEPER:-0}" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------------------------------------------------------------- 1. kernel parsing
echo "kernel log parsing (real 2026-10-03 lines)"
J="$T/parse.json"
"$SV" --parse-kernel "$FX/kernel-2026-10-03-freeze-failed.log" > "$J"
check "two freeze failures"                 '[[ $(jq .freeze_failures "$J") == 2 ]]'
check "one blocking process (tgid)"          '[[ $(jq ".blockers | length" "$J") == 1 ]]'
check "blocker pid = tgid 3798495"           '[[ $(jq ".blockers[0].pid" "$J") == 3798495 ]]'
check "seven threads ioq-0..6"               '[[ $(jq -c ".blockers[0].threads" "$J") == "[\"ioq-0\",\"ioq-1\",\"ioq-2\",\"ioq-3\",\"ioq-4\",\"ioq-5\",\"ioq-6\"]" ]]'
check "parent 3798493"                       '[[ $(jq ".blockers[0].ppid" "$J") == 3798493 ]]'
check "stuck in fuse_readdir_uncached"       '[[ $(jq -r ".blockers[0].fuse_fn" "$J") == fuse_readdir_uncached ]]'
check "deep then s2idle"                     '[[ $(jq -r ".entries[0:2] | join(\",\")" "$J") == deep,s2idle ]]'

# ---------------------------------------------------------------- 2. functions
echo "verdict, knobs, FUSE scan (functions)"
mkdir -p "$T/proc/self" "$T/proc/777/task/778" "$T/proc/900/task/901" \
         "$T/sys/sys/fs/fuse/connections/90" "$T/sys/sys/fs/fuse/connections/91" "$T/sys/sys/power/suspend_stats"
cat > "$T/proc/self/mountinfo" <<'EOF'
25 1 0:22 / /proc rw,nosuid - proc proc rw
60 25 0:41 / /sys/fs/fuse/connections rw - fusectl fusectl rw
95 30 0:90 / /run/user/1000/gvfs rw,nosuid,nodev - fuse.gvfsd-fuse gvfsd-fuse rw,user_id=1000
96 30 0:91 / /run/user/1000/doc rw,nosuid,nodev - fuse.portal portal rw,user_id=1000
EOF
echo app > "$T/proc/777/comm"; echo ioq-0 > "$T/proc/777/task/778/comm"
echo request_wait_answer > "$T/proc/777/task/778/wchan"
echo "778 (ioq-0) D 1 2 3" > "$T/proc/777/task/778/stat"
echo gvfsd-fuse > "$T/proc/900/comm"; echo gvfsd-fuse > "$T/proc/900/task/901/comm"
echo fuse_dev_do_read > "$T/proc/900/task/901/wchan"
echo "901 (gvfsd-fuse) S 1 2 3" > "$T/proc/900/task/901/stat"
echo 0 > "$T/sys/sys/fs/fuse/connections/90/waiting"; : > "$T/sys/sys/fs/fuse/connections/90/abort"
echo 3 > "$T/sys/sys/fs/fuse/connections/91/waiting"; : > "$T/sys/sys/fs/fuse/connections/91/abort"
cat > "$T/conf" <<'EOF'
# his file
WARN=25
UNSTICK_FUSE="0"   # comment after a value
KILL_BLOCKERS=always
LAST_RESORT=bogus
LAST_RESORT_PCT=4.5
export REMOUNT_AFTER_UNSTICK=0
EOF
OUT=$(SLEEP_VERIFIED_PROC="$T/proc" SLEEP_VERIFIED_SYS="$T/sys" SLEEP_VERIFIED_CONF="$T/conf" python3 - "$SV" <<'EOF'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("sv", sys.argv[1])
spec = importlib.util.spec_from_loader("sv", loader); sv = importlib.util.module_from_spec(spec); loader.exec_module(sv)
r = {
 "v_counter": sv.verdict_of({"success": 4}, {"success": 5}, 0),
 "v_clock": sv.verdict_of({"success": 4}, {"success": 4}, 3600.0),
 "v_failed": sv.verdict_of({"success": 4}, {"success": 4}, 2.0),
 "v_unreadable": sv.verdict_of({"success": ""}, {"success": ""}, 0.5),
 "h_ok": sv.hibernate_verdict(True, "success", 3600.0),
 "h_noran": sv.hibernate_verdict(False, "success", 3600.0),
 "h_result": sv.hibernate_verdict(True, "exit-code", 3600.0),
 "h_nojump": sv.hibernate_verdict(True, "success", 2.0),
 "conf": sv.load_conf(),
 "default_conf": sv.load_conf("/nonexistent"),
 "conns": sv.fuse_connections(),
 "waiters": sv.fuse_waiters(),
}
print(json.dumps(r))
EOF
)
J="$T/fn.json"; echo "$OUT" > "$J"
check "success counter up = SLEPT"            '[[ $(jq -r .v_counter "$J") == SLEPT ]]'
check "1 h on the boot clock = SLEPT"         '[[ $(jq -r .v_clock "$J") == SLEPT ]]'
check "no counter, 2 s = FAILED"              '[[ $(jq -r .v_failed "$J") == FAILED ]]'
check "unreadable stats, 0.5 s = FAILED"      '[[ $(jq -r .v_unreadable "$J") == FAILED ]]'
check "hibernate: ran + success + 1 h jump = HIBERNATED" '[[ $(jq -r ".h_ok[0]" "$J") == HIBERNATED ]]'
check "hibernate: unit never ran = FAILED"    '[[ $(jq -r ".h_noran[0]" "$J") == FAILED && $(jq -r ".h_noran[1]" "$J") == *"never ran"* ]]'
check "hibernate: Result=exit-code = FAILED"  '[[ $(jq -r ".h_result[0]" "$J") == FAILED && $(jq -r ".h_result[1]" "$J") == *"Result=exit-code"* ]]'
check "hibernate: success but no clock jump = FAILED" '[[ $(jq -r ".h_nojump[0]" "$J") == FAILED && $(jq -r ".h_nojump[1]" "$J") == *"never powered off"* ]]'
check "conf: RETRY_GRACE / ACTIVITY_CANCELS defaults" '[[ $(jq -r ".conf.RETRY_GRACE + \" \" + .conf.ACTIVITY_CANCELS" "$J") == "60 watcher" ]]'
check "conf: quoted value + comment"          '[[ $(jq -r .conf.UNSTICK_FUSE "$J") == 0 ]]'
check "conf: KILL_BLOCKERS=always"            '[[ $(jq -r .conf.KILL_BLOCKERS "$J") == always ]]'
check "conf: invalid LAST_RESORT -> default"  '[[ $(jq -r .conf.LAST_RESORT "$J") == hibernate && $(jq -r ._invalid[0] <<<"$(jq .conf "$J")") == LAST_RESORT=bogus ]]'
check "conf: decimal LAST_RESORT_PCT"         '[[ $(jq -r .conf.LAST_RESORT_PCT "$J") == 4.5 ]]'
check "conf: export prefix"                   '[[ $(jq -r .conf.REMOUNT_AFTER_UNSTICK "$J") == 0 ]]'
check "conf absent -> defaults (2026-10-06)"  '[[ $(jq -c "[.default_conf.UNSTICK_FUSE,.default_conf.KILL_BLOCKERS,.default_conf.LAST_RESORT,.default_conf.LAST_RESORT_PCT,.default_conf.RETRY_GRACE,.default_conf.ACTIVITY_CANCELS]" "$J") == "[\"1\",\"lower\",\"hibernate\",\"8\",\"60\",\"watcher\"]" ]]'
check "fuse conn 91 = /run/user/1000/doc waiting 3" '[[ $(jq -r ".conns[] | select(.conn==\"91\") | \"\(.mount) \(.waiting) \(.fstype)\"" "$J") == "/run/user/1000/doc 3 fuse.portal" ]]'
check "waiter found: app/ioq-0 in request_wait_answer, D" '[[ $(jq -r ".waiters | map(\"\(.comm)/\(.thread)/\(.state)\") | join(\",\")" "$J") == app/ioq-0/D ]]'

# ---------------------------------------------------------------- 3. full run, stubbed
echo "full run with stubs (FAILED -> unstick -> retry)"
B="$T/bin"; F="$T/fake"; H="$T/home"; mkdir -p "$B" "$F" "$H"
for k in success fail failed_freeze; do echo 0 > "$T/sys/sys/power/suspend_stats/$k"; done
: > "$T/sys/sys/power/suspend_stats/last_failed_step"
cat > "$B/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$F/systemctl.log"
[[ "\$1" == --user ]] && exit 0
case "\$1" in
suspend)
    n=\$(( \$(cat "$F/inv" 2>/dev/null || echo 0) + 1 )); echo \$n > "$F/inv"
    st="$T/sys/sys/power/suspend_stats"
    if [[ -f "$F/succeed_from" ]] && (( n >= \$(cat "$F/succeed_from") )); then
        echo \$(( \$(cat \$st/success) + 1 )) > \$st/success
    else
        echo \$(( \$(cat \$st/fail) + 1 )) > \$st/fail
    fi ;;
show)
    n=\$(cat "$F/inv" 2>/dev/null || echo 0)
    printf 'ActiveState=inactive\nResult=exit-code\nInvocationID=inv%s\nExecMainStatus=1\n' "\$n" ;;
esac
exit 0
EOF
printf '#!/bin/bash\ncat "%s/kernel.log"\n' "$F" > "$B/journalctl"
printf '#!/bin/bash\nshift 2; [[ "$1" == -- ]] && shift; echo "$*" >> "%s/logger.log"\n' "$F" > "$B/logger"
printf '#!/bin/bash\necho "$*" >> "%s/notify.log"; echo 7\n' "$F" > "$B/notify-send"
printf '#!/bin/bash\nexit 0\n' > "$B/ffplay"
printf '#!/bin/bash\necho "$*" >> "%s/fusermount.log"\n' "$F" > "$B/fusermount3"
chmod +x "$B"/*
cp "$FX/kernel-2026-10-03-freeze-failed.log" "$F/kernel.log"
echo 2 > "$F/succeed_from"
: > "$T/conf2"
sv_run() {
    env PATH="$B:$PATH" HOME="$H" SLEEP_VERIFIED_PROC="$T/proc" SLEEP_VERIFIED_SYS="$T/sys" \
        SLEEP_VERIFIED_CONF="$T/conf2" SLEEP_VERIFIED_STATE_DIR="$T/state" "$SV" "$@" 2>/dev/null
}
sv_run --reason upper; RC=$?
L="$T/state/last.json"
check "exit 0 (slept on the retry)"           '[[ $RC == 0 ]]'
check "verdict SLEPT after 2 attempts"        '[[ $(jq -r .verdict "$L") == SLEPT && $(jq ".attempts | length" "$L") == 2 ]]'
check "attempt 1 FAILED with the blocker"     '[[ $(jq -r ".attempts[0].verdict" "$L") == FAILED && $(jq ".attempts[0].blockers[0].pid" "$L") == 3798495 ]]'
check "aborted the hung portal mount only"    '[[ $(jq -r ".remedy_applied[0]" "$L") == unstick:/run/user/1000/doc && $(cat "$T/sys/sys/fs/fuse/connections/91/abort") == 1 && ! -s "$T/sys/sys/fs/fuse/connections/90/abort" ]]'
check "remounted the portal"                  'grep -q "^-uz /run/user/1000/doc" "$F/fusermount.log" && grep -q "restart xdg-document-portal.service" "$F/systemctl.log"'
check "history.jsonl has one line"            '[[ $(wc -l < "$T/state/history.jsonl") == 1 ]]'
check "no FAILED card on success"             '! grep -q "Suspend FAILED" "$F/notify.log" 2>/dev/null'

echo "full run: never recovers (FAILED, report, exit 1)"
rm -f "$F/succeed_from"; echo 0 > "$T/sys/sys/fs/fuse/connections/91/waiting"; : > "$F/notify.log"
sv_run --reason user; RC=$?
check "exit 1"                                '[[ $RC == 1 ]]'
check "verdict FAILED, 1 attempt (nothing to unstick, not urgent)" '[[ $(jq -r .verdict "$L") == FAILED && $(jq ".attempts | length" "$L") == 1 ]]'
check "sticky critical card"                  'grep -q -- "-u critical -t 0 -p" "$F/notify.log" && grep -q "Suspend FAILED" "$F/notify.log"'
check "message names the stuck process"       '[[ $(jq -r .message "$L") == "Suspend FAILED (user, "*"ioq-0 pid 3798495 stuck in FUSE"*"laptop still ON" ]]'

echo "full run: KILL_BLOCKERS at the lower limit (--urgent) kills only the named process"
sleep 300 & SLEEPER=$!; disown "$SLEEPER"
sed "s/pid:3798496 tgid:3798495 ppid:3798493/pid:$SLEEPER tgid:$SLEEPER ppid:$$/" "$FX/kernel-2026-10-03-freeze-failed.log" > "$F/kernel.log"
echo 2 > "$F/succeed_from"; echo 0 > "$F/inv"
env PATH="$B:$PATH" HOME="$H" SLEEP_VERIFIED_SYS="$T/sys" SLEEP_VERIFIED_CONF="$T/conf2" \
    SLEEP_VERIFIED_STATE_DIR="$T/state" "$SV" --reason lower --urgent 2>/dev/null; RC=$?
sleep 0.3
check "exit 0 after the kill + retry"         '[[ $RC == 0 && $(jq -r ".remedy_applied[0]" "$L") == "kill:$SLEEPER" ]]'
check "the named process is gone"             '! kill -0 $SLEEPER 2>/dev/null'
check "pid 3798495 (not his / gone) was not touched" '! grep -q "SIGKILL.*3798495" "$F/logger.log"'

echo "dry run"
OUT=$(env PATH="$B:$PATH" HOME="$H" SLEEP_VERIFIED_PROC="$T/proc" SLEEP_VERIFIED_SYS="$T/sys" \
      SLEEP_VERIFIED_CONF="$T/conf2" SLEEP_VERIFIED_STATE_DIR="$T/state2" "$SV" --dry-run --reason test 2>&1)
check "prints would suspend, suspends nothing" '[[ "$OUT" == *"would suspend (test)"* ]] && [[ $(grep -c "^suspend" "$F/systemctl.log") == 5 ]] && [[ ! -e "$T/state2/last.json" ]]'

# ---------------------------------------------------------------- 3b. hibernate (2026-10-06)
echo "hibernate: the last resort, verified by systemd-hibernate.service + the wall-clock jump"
S3="$T/sys3"; cp -r "$T/sys" "$S3"; BAT3="$S3/sys/class/power_supply/BAT0"; mkdir -p "$BAT3" "$S3/proc"
for k in success fail; do echo 0 > "$S3/sys/power/suspend_stats/$k"; done
echo 1000000 > "$BAT3/energy_full"; echo 110000 > "$BAT3/energy_now"; echo Discharging > "$BAT3/status"   # 11 %
RESUME="BOOT_IMAGE=/vmlinuz-linux root=UUID=x rw resume=UUID=y resume_offset=1234"
echo "$RESUME" > "$S3/proc/cmdline"
SKEW="$F/wall-skew"
cat > "$B/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$F/systemctl.log"
[[ "\$1" == --user ]] && exit 0
case "\$1" in
suspend)
    n=\$(( \$(cat "$F/inv" 2>/dev/null || echo 0) + 1 )); echo \$n > "$F/inv"
    echo \$(( \$(cat $S3/sys/power/suspend_stats/fail) + 1 )) > $S3/sys/power/suspend_stats/fail ;;
hibernate)
    n=\$(( \$(cat "$F/hinv" 2>/dev/null || echo 0) + 1 )); echo \$n > "$F/hinv"
    if [[ -f "$F/hib_ok" ]]; then echo 3600 > "$SKEW"; echo success > "$F/hres"; else echo exit-code > "$F/hres"; fi ;;
show)
    if [[ "\$*" == *systemd-hibernate.service* ]]; then
        printf 'ActiveState=inactive\nResult=%s\nInvocationID=h%s\nExecMainStatus=0\n' "\$(cat "$F/hres" 2>/dev/null || echo success)" "\$(cat "$F/hinv" 2>/dev/null || echo 0)"
    else
        printf 'ActiveState=inactive\nResult=exit-code\nInvocationID=inv%s\nExecMainStatus=1\n' "\$(cat "$F/inv" 2>/dev/null || echo 0)"
    fi ;;
esac
exit 0
EOF
chmod +x "$B/systemctl"
mkdir -p "$H/Programs/phone-file-transfer"
printf '#!/bin/bash\necho "$*" >> "%s/telegram.log"\n' "$F" > "$H/Programs/phone-file-transfer/telegram-send.py"
chmod +x "$H/Programs/phone-file-transfer/telegram-send.py"
: > "$F/kernel.log"
printf 'LAST_RESORT=hibernate\nLAST_RESORT_PCT=8\nKILL_BLOCKERS=lower\n' > "$T/conf3"
sv3() {
    rm -f "$SKEW" "$F/hres"; : > "$F/systemctl.log"; : > "$F/telegram.log"; : > "$F/notify.log"
    env PATH="$B:$PATH" HOME="$H" SLEEP_VERIFIED_PROC="$T/proc" SLEEP_VERIFIED_SYS="$S3" \
        SLEEP_VERIFIED_CONF="$T/conf3" SLEEP_VERIFIED_STATE_DIR="$T/state3" SLEEP_VERIFIED_WALL_SKEW_FILE="$SKEW" \
        "$SV" "$@" 2>/dev/null
}
L3="$T/state3/last.json"
touch "$F/hib_ok"
sv3 --last-resort --check >/dev/null; RC=$?
check "--check with resume= -> 0 (available)"  '[[ $RC == 0 ]]'
sv3 --last-resort --reason last-resort; RC=$?
check "direct last resort: exit 0, HIBERNATED, no suspend tried" '[[ $RC == 0 && $(jq -r .verdict "$L3") == HIBERNATED && $(jq -r ".attempts[0].op" "$L3") == hibernate ]] && ! grep -q "^suspend" "$F/systemctl.log"'
check "verdict from the unit + clock jump"     '[[ $(jq -r ".attempts[0].unit_result" "$L3") == success && $(jq ".attempts[0].wall_jump_s >= 3000" "$L3") == true ]]'
rm -f "$F/hib_ok"
sv3 --last-resort --reason last-resort; RC=$?
check "direct last resort, hibernate fails: exit 1, FAILED with the unit result" '[[ $RC == 1 && $(jq -r .verdict "$L3") == FAILED && $(jq -r .why "$L3") == *"Result=exit-code"* ]]'
check "  ... one Telegram line"                '[[ $(wc -l < "$F/telegram.log") == 1 ]] && grep -q "Hibernate FAILED" "$F/telegram.log"'
touch "$F/hib_ok"
sv3 --reason lower --urgent; RC=$?
check "LOWER suspend fails at 11 % (above 8) -> hibernates at once" '[[ $RC == 0 && $(jq -r .verdict "$L3") == HIBERNATED && $(jq -r ".remedy_applied|join(\",\")" "$L3") == *"last-resort:hibernate"* ]]'
check "  ... suspend first, then hibernate"    '[[ $(grep -E "^(suspend|hibernate)$" "$F/systemctl.log" | paste -sd,) == suspend,hibernate ]]'
check "  ... no FAILED card, a 'hibernated instead' note" '! grep -q "Suspend FAILED" "$F/notify.log" && grep -q "hibernated instead" "$F/notify.log"'
sv3 --reason lower --urgent --no-last-resort; RC=$?
check "--no-last-resort: FAILED, no hibernate" '[[ $RC == 1 ]] && ! grep -q "^hibernate" "$F/systemctl.log"'
sv3 --reason upper; RC=$?
check "UPPER failing at 11 % -> no last resort" '[[ $RC == 1 ]] && ! grep -q "^hibernate" "$F/systemctl.log"'
echo 70000 > "$BAT3/energy_now"   # 7 %
sv3 --reason user; RC=$?
check "his own suspend failing at 7 % (<= 8) -> hibernate" '[[ $RC == 0 && $(jq -r .verdict "$L3") == HIBERNATED ]]'
echo 110000 > "$BAT3/energy_now"
echo "BOOT_IMAGE=/vmlinuz-linux root=UUID=x rw" > "$S3/proc/cmdline"
sv3 --last-resort --check >/dev/null; RC=$?
check "--check without resume= -> 4 (not available)" '[[ $RC == 4 ]]'
sv3 --last-resort --reason last-resort; RC=$?
check "direct last resort without resume=: exit 4, REFUSED, no hibernate call" '[[ $RC == 4 && $(jq -r .verdict "$L3") == REFUSED ]] && ! grep -q "^hibernate" "$F/systemctl.log"'
check "  ... Telegram: hibernate not configured" 'grep -q "hibernate not configured (no resume=), laptop will stay on" "$F/telegram.log"'
sv3 --reason lower --urgent; RC=$?
check "LOWER failure without resume=: refused, FAILED, laptop stays on" '[[ $RC == 1 && $(jq -r .verdict "$L3") == FAILED && $(jq -r ".remedy_applied|join(\",\")" "$L3") == *"hibernate-refused:no-resume"* ]] && ! grep -q "^hibernate" "$F/systemctl.log"'
check "  ... one line says it: card + Telegram"  'grep -q "hibernate not configured (no resume=), laptop will stay on" "$F/notify.log" && [[ $(wc -l < "$F/telegram.log") == 1 ]] && grep -q "Suspend FAILED (lower.*hibernate not configured" "$F/telegram.log"'
echo "$RESUME" > "$S3/proc/cmdline"; printf 'LAST_RESORT=none\n' > "$T/conf3"
sv3 --reason lower --urgent; RC=$?
check "LAST_RESORT=none: no hibernate even at the lower limit" '[[ $RC == 1 ]] && ! grep -q "^hibernate" "$F/systemctl.log"'

# ---------------------------------------------------------------- 4. battery-guard
echo "battery-guard: 2026-10-06 limits (WARN 30 / UPPER 25 / LOWER 12 / last resort 8), displayed percent"
# sv-stub: every call logged; exit codes per mode from files (check / last-resort / suspend)
cat > "$B/sv-stub" <<EOF
#!/bin/bash
echo "\$*" >> "$F/sv.log"
case "\$*" in
*--last-resort*--check*) exit "\$(cat $F/sv.check.rc 2>/dev/null || echo 4)" ;;
*--last-resort*)         exit "\$(cat $F/sv.lr.rc 2>/dev/null || echo 1)" ;;
*)                       exit "\$(cat $F/sv.rc 2>/dev/null || echo 0)" ;;
esac
EOF
chmod +x "$B/sv-stub"
guard_dry() { BATTERY_GUARD_STATE="$T/bg.state" BATTERY_GUARD_FAKE_CAPACITY=$1 BATTERY_GUARD_FAKE_STATUS=Discharging \
              BATTERY_GUARD_SLEEP_CMD="$B/sv-stub" XDG_CONFIG_HOME="$T/noconf" "$BG" --dry-run 2>/dev/null | tail -1; rm -f "$T/bg.state"; }
echo 4 > "$F/sv.check.rc"
check "12.2 % -> lower limit"                 '[[ "$(guard_dry 12.2)" == *"lower limit 12%"*"--reason lower --urgent"* ]]'
check "12.9 % -> lower limit"                 '[[ "$(guard_dry 12.9)" == *"lower limit 12%"* ]]'
check "13.0 % -> upper limit (not lower)"     '[[ "$(guard_dry 13.0)" == *"upper limit 25%"*"--reason upper "* ]]'
check "25 % -> upper limit"                   '[[ "$(guard_dry 25)" == *"upper limit 25%"* ]]'
check "25.1 % -> warning only"                '[[ "$(guard_dry 25.1)" == *"warning at 25.1%"* ]]'
check "30.1 % -> nothing"                     '[[ "$(guard_dry 30.1)" != *"warning"* ]]'
check "8.5 %, hibernate not available -> lower-limit suspend" '[[ "$(guard_dry 8.5)" == *"lower limit 12%"*"--reason lower --urgent"* ]]'
echo 0 > "$F/sv.check.rc"
check "8.5 %, hibernate available -> direct last resort after 30 s" '[[ "$(guard_dry 8.5)" == *"would hibernate (last resort 8%, capacity=8.5%) after 30s notice via sleep-verified --last-resort"* ]]'
check "9.0 % -> lower limit, not the last resort" '[[ "$(guard_dry 9.0)" == *"lower limit 12%"* ]]'
rm -f "$F/sv.log"

echo "battery-guard: upper_done only after a verified sleep; failure retries after GRACE_RETRY"
mkdir -p "$T/bgconf" "$T/ac"; echo 0 > "$T/ac/online"
printf 'GRACE=0\nGRACE_RETRY=0\nLAST_RESORT_GRACE=0\n' > "$T/bgconf/battery-guard.conf"
guard_real() { HOME="$H" BATTERY_GUARD_STATE="$T/bg.state" BATTERY_GUARD_FAKE_CAPACITY=$1 BATTERY_GUARD_FAKE_STATUS=Discharging \
               BATTERY_GUARD_AC="$T/ac" BATTERY_GUARD_NOTIFY=0 BATTERY_GUARD_SLEEP_CMD="$B/sv-stub" \
               XDG_CONFIG_HOME="$T/bgconf" "$BG" >/dev/null 2>&1; }
rm -f "$T/bg.state"; echo 1 > "$F/sv.rc"
guard_real 21
check "failed upper: upper_done=0 retry_pending=1" 'grep -q "^upper_done=0" "$T/bg.state" && grep -q "^retry_pending=1" "$T/bg.state"'
echo 0 > "$F/sv.rc"; guard_real 21
check "retry succeeds: upper_done=1 retry_pending=0" 'grep -q "^upper_done=1" "$T/bg.state" && grep -q "^retry_pending=0" "$T/bg.state"'
guard_real 20
check "no third suspend between the limits"   '[[ $(wc -l < "$F/sv.log") == 2 ]]'
guard_real 12.2
check "lower passes --reason lower --urgent"  '[[ $(tail -1 "$F/sv.log") == "--reason lower --urgent" ]]'
check "upper passed --reason upper (no --urgent)" '[[ $(head -1 "$F/sv.log") == "--reason upper" ]]'

echo "battery-guard: <= 8 % direct last resort (2026-10-06)"
: > "$F/sv.log"; echo 0 > "$F/sv.check.rc"; echo 0 > "$F/sv.lr.rc"; echo 0 > "$F/sv.rc"
guard_real 8.4
check "checks, then sleep-verified --last-resort, no suspend first" '[[ $(paste -sd"|" "$F/sv.log") == "--last-resort --check|--last-resort --reason last-resort" ]]'
: > "$F/sv.log"; echo 1 > "$F/sv.lr.rc"
guard_real 8.4
check "hibernate FAILED -> lower-limit suspend at once, no second last resort" '[[ $(tail -1 "$F/sv.log") == "--reason lower --urgent --no-last-resort" && $(wc -l < "$F/sv.log") == 3 ]]'
: > "$F/sv.log"; echo 4 > "$F/sv.check.rc"
guard_real 8.4
check "hibernate not available -> the lower-limit suspend (whose ladder may still hibernate)" '[[ $(paste -sd"|" "$F/sv.log") == "--last-resort --check|--reason lower --urgent" ]]'
: > "$F/sv.log"; echo 0 > "$F/sv.check.rc"
mkdir -p "$T/bgconf-none"; printf 'LAST_RESORT=none\nGRACE=0\n' > "$T/bgconf-none/battery-guard.conf"
OUT=$(BATTERY_GUARD_STATE="$T/bg.state" BATTERY_GUARD_FAKE_CAPACITY=8 BATTERY_GUARD_FAKE_STATUS=Discharging \
      BATTERY_GUARD_SLEEP_CMD="$B/sv-stub" XDG_CONFIG_HOME="$T/bgconf-none" "$BG" --dry-run 2>/dev/null | tail -1)
check "LAST_RESORT=none -> plain lower limit at 8 %" '[[ "$OUT" == *"lower limit 12%"* ]]'

echo "battery-guard: ACTIVITY_CANCELS knob (activity stand-in)"
printf '#!/bin/bash\necho "$*" >> "%s/act.log"; echo "activity: stand-in"; exit "$(cat %s/act.rc)"\n' "$F" "$F" > "$B/act-stub"
chmod +x "$B/act-stub"
guard_act() {  # capacity, ACTIVITY_CANCELS
    mkdir -p "$T/bgact"; printf 'GRACE=1\nGRACE_RETRY=1\nACTIVITY_CANCELS=%s\n' "$2" > "$T/bgact/battery-guard.conf"
    HOME="$H" BATTERY_GUARD_STATE="$T/bg.state" BATTERY_GUARD_FAKE_CAPACITY=$1 BATTERY_GUARD_FAKE_STATUS=Discharging \
        BATTERY_GUARD_AC="$T/ac" BATTERY_GUARD_NOTIFY=0 BATTERY_GUARD_SLEEP_CMD="$B/sv-stub" \
        BATTERY_GUARD_ACTIVITY_CMD="$B/act-stub" XDG_CONFIG_HOME="$T/bgact" "$BG" >/dev/null 2>&1; }
rm -f "$T/bg.state" "$F/act.log"; : > "$F/sv.log"; echo 0 > "$F/act.rc"; echo 0 > "$F/sv.rc"
guard_act 24 watcher+upper
check "watcher+upper: activity cancels the UPPER grace, no suspend" '[[ ! -s "$F/sv.log" && $(cat "$F/act.log") == "--seconds 1 --settle 1" ]]'
check "  ... and counts as woken (upper_done=1)" 'grep -q "^upper_done=1" "$T/bg.state"'
rm -f "$T/bg.state" "$F/act.log"; echo 1 > "$F/act.rc"
guard_act 24 watcher+upper
check "watcher+upper: no activity -> suspends as before" '[[ $(cat "$F/sv.log") == "--reason upper" && -s "$F/act.log" ]]'
rm -f "$T/bg.state" "$F/act.log"; : > "$F/sv.log"; echo 0 > "$F/act.rc"
guard_act 24 watcher
check "watcher (default): the guard never listens, suspends" '[[ ! -e "$F/act.log" && $(cat "$F/sv.log") == "--reason upper" ]]'
rm -f "$T/bg.state" "$F/act.log"; : > "$F/sv.log"
guard_act 12 watcher+upper
check "LOWER never cancels on activity (even watcher+upper)" '[[ ! -e "$F/act.log" && $(cat "$F/sv.log") == "--reason lower --urgent" ]]'
printf 'ACTIVITY_CANCELS=watcher+upper\n' > "$T/bgact/battery-guard.conf"
OUT=$(BATTERY_GUARD_STATE="$T/bg.dry" BATTERY_GUARD_FAKE_CAPACITY=24 BATTERY_GUARD_FAKE_STATUS=Discharging \
      BATTERY_GUARD_SLEEP_CMD="$B/sv-stub" XDG_CONFIG_HOME="$T/bgact" "$BG" --dry-run 2>/dev/null | tail -1)
check "dry run says activity cancels the upper grace" '[[ "$OUT" == *"180s grace (activity cancels)"* ]]'

echo "battery-guard --init-conf writes only when absent"
rm -rf "$T/cfg"; XDG_CONFIG_HOME="$T/cfg" "$BG" --init-conf >/dev/null
check "conf written with the 2026-10-06 values" 'grep -q "^WARN=30$" "$T/cfg/battery-guard.conf" && grep -q "^UPPER=25$" "$T/cfg/battery-guard.conf" && grep -q "^LOWER=12$" "$T/cfg/battery-guard.conf" && grep -q "^GRACE=180$" "$T/cfg/battery-guard.conf" && grep -q "^LAST_RESORT=hibernate$" "$T/cfg/battery-guard.conf" && grep -q "^LAST_RESORT_PCT=8$" "$T/cfg/battery-guard.conf" && grep -q "^ACTIVITY_CANCELS=watcher$" "$T/cfg/battery-guard.conf"'
echo "UPPER=30  # his edit" > "$T/cfg/battery-guard.conf"; XDG_CONFIG_HOME="$T/cfg" "$BG" --init-conf >/dev/null
check "his existing conf left untouched"      '[[ $(cat "$T/cfg/battery-guard.conf") == "UPPER=30  # his edit" ]]'
check "template knobs parse in sleep-verified" '[[ $(SLEEP_VERIFIED_CONF="$HERE/dotfiles/battery-guard.conf.default" "$SV" --show-conf | jq -c "._invalid") == "[]" ]]'

# ---------------------------------------------------------------- 5. restore --print
echo "laptop-state-restore --print"
OUT=$("$RS" --print "$FX/snapshot-sample.json")
check "windows grouped by workspace"          '[[ "$OUT" == *"Workspace 1 (eDP-1):"*"ghostty"*"Workspace 2 (eDP-1):"*"google-chrome"*"thunar"* ]]'
check "resume line for the running session"   'grep -qF "cd /home/prabhanshu/Programs/local-bootstrapping && claude --resume 11111111-2222-3333-4444-555555555555" <<<"$OUT"'
check "running session shows its last message" 'grep -q "make the suspend smart" <<<"$OUT"'
check "cwd with a space is quoted"            'grep -qF "cd '"'"'/home/prabhanshu/Programs/star trek'"'"' && claude --resume 66666666" <<<"$OUT"'
check "unknown session id said plainly"       'grep -q "pid 4343 in /home/prabhanshu/Programs.*session id unknown" <<<"$OUT"'
check "tmux attach line"                      'grep -qF "tmux attach -t work" <<<"$OUT"'

echo "laptop-state-restore --print: every running session has pid, cwd and a resume line, before the windows"
OUT=$("$RS" --print "$FX/snapshot-sessions.json")
check "sessions within the first 12 lines (2026-10-03: head -12 hid them)" '"$RS" --print "$FX/snapshot-sessions.json" | head -12 | grep -q "claude --resume 887a9446"'
check "sessions before the windows"           '[[ "$OUT" == *"running at the snapshot (4):"*"Windows (5):"* ]]'
check "pid + cwd on each running session"     '[[ $(grep -cE "^  pid [0-9]+ in /home/prabhanshu/Programs" <<<"$OUT") == 4 ]]'
check "session-file id used as is"            'grep -A1 "pid 45518 in /home/prabhanshu/Programs " <<<"$OUT" | grep -qxF "    cd /home/prabhanshu/Programs && claude --resume 887a9446-328a-4a0b-b347-122331cf9676"'
check "remote-control: snapshot transcript match" 'grep -A1 "pid 6373 " <<<"$OUT" | grep -q "claude --resume 15984b19-d881-5c7a-a58a-aa56e10853d2  # matched by transcript"'
check "no id: newest transcript since start (not the older one)" 'grep -A1 "pid 52855 " <<<"$OUT" | grep -q "cd /home/prabhanshu/Programs/star-trek-camera && claude --resume aaaaaaaa-0000-0000-0000-000000000001  # matched"'
check "matched session shows its last message" 'grep -q "pid 52855 .*review the footage" <<<"$OUT"'
check "transcript older than the process: unknown, said plainly" 'grep -q "pid 60000 .*session id unknown, no transcript written since it started" <<<"$OUT"'
check "a matched transcript is not repeated under Other" '! grep -A20 "^Other recent" <<<"$OUT" | grep -q aaaaaaaa'
OUT=$("$RS" --print "$HERE/tests/fixtures/sleep-verified/nonexistent.json" 2>&1); RC=$?
check "unreadable snapshot: exit 1 with the path" '[[ $RC == 1 && "$OUT" == *"cannot read"* ]]'

echo
echo "passed $PASS, failed $FAIL"
[[ $FAIL == 0 ]]
