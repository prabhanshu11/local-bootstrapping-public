#!/bin/bash
# tests/unit/test-reconcile.sh — the no-drift self-heal and its escalation.
#
# Simulates drift in a throwaway HOME + repo copy and asserts what
# `install.sh --reconcile` (scripts/lib/reconcile.sh) and `lb-drift record`
# do. Touches nothing real: systemctl, hyprctl, pkill, pgrep, notify-send and
# tailscale are stubs; XDG_RUNTIME_DIR and the /sys + /etc gates are fakes.
#
#   tests/unit/test-reconcile.sh        # exit 0 = all passed
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d -t lb-reconcile-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------------------------------------------------------------- fixture
R="$T/repo"; H="$T/home"; S="$T/sys"; B="$T/bin"
mkdir -p "$R/scripts/lib" "$R/dotfiles" "$H" "$S" "$B" "$T/run"
cp "$HERE/scripts/install.sh" "$R/scripts/"
cp "$HERE/scripts/lib/reconcile.sh" "$R/scripts/lib/"
mkdir -p "$R/dotfiles/local-bin" "$R/dotfiles/waybar" "$R/dotfiles/hypr" \
         "$R/dotfiles/systemd-user" "$R/dotfiles/bashrc.d"
cp "$HERE/dotfiles/local-bin/lb-drift" "$R/dotfiles/local-bin/"
printf '#!/bin/sh\nexit 0\n' > "$R/dotfiles/local-bin/touch-mode"; chmod +x "$R/dotfiles/local-bin/touch-mode"
echo bar-touch-code   > "$R/dotfiles/local-bin/bar-touch"
echo waybar-config    > "$R/dotfiles/waybar/config.jsonc"
echo waybar-style     > "$R/dotfiles/waybar/style.css"
echo laptop-monitors  > "$R/dotfiles/hypr/monitors.conf"
echo laptop-autostart > "$R/dotfiles/hypr/autostart.conf"
echo repo-claude-md   > "$R/dotfiles/CLAUDE.md"
echo 'alias x=y'      > "$R/dotfiles/bashrc.d/a.sh"
mkdir -p "$R/dotfiles/mako"; echo repo-mako > "$R/dotfiles/mako/config"
mkdir -p "$R/dotfiles/ssh"; echo repo-home-routes > "$R/dotfiles/ssh/home-routes.conf"
printf '[Service]\nExecStart=/bin/true\n' > "$R/dotfiles/systemd-user/bar-touch.service"
printf '[Timer]\nOnCalendar=daily\n'      > "$R/dotfiles/systemd-user/battery-guard.timer"
printf '[Timer]\nOnCalendar=daily\n'      > "$R/dotfiles/systemd-user/wallpaper-rotate.timer"
printf '[Service]\nExecStart=/bin/rc\n'   > "$R/dotfiles/systemd-user/claude-remote-control.service"
mkdir -p "$R/machine-specific/desktop/hypr" "$R/system/iwd"
echo desktop-monitors > "$R/machine-specific/desktop/hypr/monitors.conf"
echo desktop-autostart > "$R/machine-specific/desktop/hypr/autostart.conf"
cat > "$R/machine-specific/desktop/symlinks.conf" <<'EOF'
# comment: with a colon
hypr/monitors.conf:~/.config/hypr/monitors.conf
hypr/autostart.conf:$HOME/.config/hypr/autostart.conf   # trailing comment
EOF
echo "unit wallpaper-rotate.timer  # test exception" > "$R/machine-specific/desktop/drift-exceptions.conf"
echo iwd-conf > "$R/system/iwd/main.conf"
printf 'DEVICE_NAME="desktop"\n' > "$R/device-role.conf"

# desktop board, no battery, iwd config missing from the fake /etc
mkdir -p "$S/sys/class/dmi/id"; echo "PRIME A520M-K" > "$S/sys/class/dmi/id/board_name"

# stubs
cat > "$B/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$T/systemctl.log"
[[ "\$1" == --user ]] && shift
case "\$1" in
  is-enabled) shift; for u in "\$@"; do grep -qx "\$u" "$T/enabled" 2>/dev/null && echo enabled || echo disabled; done ;;
  enable) shift; [[ "\$1" == --now ]] && shift; echo "\$1" >> "$T/enabled" ;;
  is-active) shift; for u in "\$@"; do grep -qx "\$u" "$T/active" 2>/dev/null && echo active || echo inactive; done ;;
esac
exit 0
EOF
for c in hyprctl pkill pgrep notify-send makoctl; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/stub.log"\nexit 1\n' "$c" "$T" > "$B/$c"
done
printf '#!/bin/sh\nexit 1\n' > "$B/tailscale"
chmod +x "$B"/*

run_reconcile() {  # extra args...
    env -i HOME="$H" PATH="$B:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" LB_SYS="$S" \
        LB_RECONCILE_ANY_ROOT=1 bash "$R/scripts/install.sh" --device desktop --reconcile "$@"
}

# ---------------------------------------------------------------- drift setup
mkdir -p "$H/.config/hypr" "$H/.config/waybar" "$H/.local/bin" "$H/.config/systemd/user" "$H/Programs"
echo waybar-config > "$H/.config/waybar/config.jsonc"              # identical regular file
echo waybar-style  > "$H/.config/waybar/style.css"                 # identical, .bak already exists
echo old           > "$H/.config/waybar/style.css.bak"
echo LOCAL-EDITS   > "$H/Programs/CLAUDE.md"                       # differs: conflict
echo desktop-monitors > "$H/.config/hypr/monitors.conf"            # device file, identical
echo DIFFERENT-autostart > "$H/.config/hypr/autostart.conf"        # device file, differs
ln -s "$T/nowhere" "$H/.local/bin/bar-touch"                       # dangling
mkdir -p "$H/.config/bashrc.d"; echo mine > "$H/.config/bashrc.d/mine.sh"   # real dir in the way
echo LOCAL-rc > "$H/.config/systemd/user/claude-remote-control.service"    # excluded
mkdir -p "$H/.config/omarchy/current/theme" "$H/.config/mako"               # Omarchy stock mako link
echo theme-mako > "$H/.config/omarchy/current/theme/mako.ini"
ln -s "$H/.config/omarchy/current/theme/mako.ini" "$H/.config/mako/config"
mkdir -p "$H/.ssh"; printf '# Laptop\nHost laptop\n    HostName 100.64.0.2\n' > "$H/.ssh/config"  # no Include line

echo "== check mode changes nothing"
out=$(run_reconcile --check 2>&1)
check "--check reports would-link"          '[[ "$out" == *"WOULD linked $H/.local/bin/lb-drift"* ]]'
check "--check leaves files alone"          '[[ ! -L "$H/.config/waybar/config.jsonc" && ! -e "$H/.local/bin/lb-drift" ]]'
check "--check: stock mako link would heal" '[[ "$out" == *"WOULD healed $H/.config/mako/config"*"Omarchy stock link"* ]]'
check "--check enables nothing"             '! grep -q "^--user enable" "$T/systemctl.log" 2>/dev/null'
check "--check: ssh Include would be added"  '[[ "$out" == *"WOULD add "?"Include home-routes.conf"?" at the top of $H/.ssh/config"* ]] && ! grep -q Include "$H/.ssh/config"'

echo "== refuses to link HOME to a non-canonical repo"
env -i HOME="$H" PATH="$B:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" bash "$R/scripts/install.sh" --device desktop --reconcile >/dev/null 2>&1
check "apply from a clone is refused"       '[[ $? -ne 0 && ! -e "$H/.local/bin/lb-drift" ]]'

echo "== first run heals"
REPORT="$T/report1.tsv"; : > "$REPORT"
out=$(run_reconcile --quiet --report "$REPORT" 2>&1); rc=$?
check "exit 0"                              '[[ $rc -eq 0 ]]'
check "missing -> linked"                   '[[ "$(readlink "$H/.local/bin/lb-drift")" == "$R/dotfiles/local-bin/lb-drift" ]]'
check "identical file -> backed up + linked" '[[ -L "$H/.config/waybar/config.jsonc" && "$(cat "$H/.config/waybar/config.jsonc.bak")" == waybar-config ]]'
check "existing .bak -> timestamped backup" '[[ -L "$H/.config/waybar/style.css" && "$(cat "$H/.config/waybar/style.css.bak")" == old ]] && ls "$H/.config/waybar/" | grep -q "style.css.bak.2"'
check "dangling symlink healed"             '[[ "$H/.local/bin/bar-touch" -ef "$R/dotfiles/local-bin/bar-touch" ]]'
check "differing file untouched"            '[[ ! -L "$H/Programs/CLAUDE.md" && "$(cat "$H/Programs/CLAUDE.md")" == LOCAL-EDITS ]]'
check "differing file reported"             'grep -q "^link-conflict	$H/Programs/CLAUDE.md	" "$REPORT"'
check "real dir in the way reported"        'grep -q "^link-conflict	$H/.config/bashrc.d	" "$REPORT" && [[ -f "$H/.config/bashrc.d/mine.sh" ]]'
check "Omarchy stock link -> backed up + linked" '[[ "$H/.config/mako/config" -ef "$R/dotfiles/mako/config" && "$(readlink "$H/.config/mako/config.bak")" == "$H/.config/omarchy/current/theme/mako.ini" ]]'
check "stock link not reported"             '! grep -q mako "$REPORT"'
check "mako not running -> no makoctl"      '! grep -q makoctl "$T/stub.log" 2>/dev/null'
check "excluded unit untouched"             '[[ ! -L "$H/.config/systemd/user/claude-remote-control.service" && "$(cat "$H/.config/systemd/user/claude-remote-control.service")" == LOCAL-rc ]]'
check "excluded unit not reported"          '! grep -q claude-remote-control "$REPORT"'
check "device overlay: monitors -> desktop file" '[[ "$(readlink "$H/.config/hypr/monitors.conf")" == "$R/machine-specific/desktop/hypr/monitors.conf" ]]'
check "device overlay: differing autostart kept + reported" '[[ "$(cat "$H/.config/hypr/autostart.conf")" == DIFFERENT-autostart ]] && grep -q "autostart.conf" "$REPORT"'
check "unit files changed -> daemon-reload" 'grep -q "^--user daemon-reload" "$T/systemctl.log"'
check "bar-touch.service enabled --now"     'grep -q "^--user enable --now bar-touch.service" "$T/systemctl.log"'
check "battery-gated unit NOT enabled"      '! grep -q "enable.*battery-guard" "$T/systemctl.log"'
check "drift-exceptions honoured"           '! grep -q "enable.*wallpaper-rotate" "$T/systemctl.log"'
check "sudo file missing -> reported, no sudo" 'grep -q "^sudo-needed	/etc/iwd/main.conf	" "$REPORT"'
check "laptop-only sudo files not checked"  '! grep -q "logind" "$REPORT"'
check "ssh: home-routes.conf linked"         '[[ "$H/.ssh/home-routes.conf" -ef "$R/dotfiles/ssh/home-routes.conf" ]]'
check "ssh: Include added at the top, rest kept" '[[ "$(sed -n 2p "$H/.ssh/config")" == "Include home-routes.conf" ]] && grep -q "^Host laptop" "$H/.ssh/config" && grep -q "^    HostName 100.64.0.2" "$H/.ssh/config"'

echo "== second run is a quiet no-op"
: > "$T/systemctl.log"
REPORT2="$T/report2.tsv"; : > "$REPORT2"
out=$(run_reconcile --quiet --report "$REPORT2" 2>&1)
check "no link changes"                     '! grep -qE "^  (linked|healed) " <<< "$out"'
check "no enable, no daemon-reload"         '! grep -qE "^--user (enable|daemon-reload)" "$T/systemctl.log"'
check "same unresolved items"               '[[ "$(cut -f1,2 "$REPORT" | sort)" == "$(cut -f1,2 "$REPORT2" | sort)" ]]'
check "ssh Include not added twice"          '[[ $(grep -c "^Include home-routes.conf" "$H/.ssh/config") -eq 1 ]] && ! grep -q "Include home-routes" <<< "$out"'

echo "== only the exact Omarchy stock link is replaced (LB_STOCK_LINKS)"
rm "$H/.config/mako/config"; echo own-mako > "$T/own-mako.ini"; ln -s "$T/own-mako.ini" "$H/.config/mako/config"
MR="$T/mako.tsv"; : > "$MR"; run_reconcile --quiet --report "$MR" >/dev/null 2>&1
check "other differing link kept + reported" '[[ "$(readlink "$H/.config/mako/config")" == "$T/own-mako.ini" ]] && grep -q "^link-conflict	$H/.config/mako/config	" "$MR"'
rm "$H/.config/mako/config"; ln -s "$H/.config/omarchy/current/theme/mako.ini" "$H/.config/mako/config"
mv "$B/pgrep" "$B/pgrep.real"
printf '#!/bin/bash\n[[ "$*" == "-x mako" ]] && exit 0\nexec "%s/pgrep.real" "$@"\n' "$B" > "$B/pgrep"; chmod +x "$B/pgrep"
: > "$MR"; run_reconcile --quiet --report "$MR" >/dev/null 2>&1
check "stock link healed again (timestamped .bak)" '[[ "$H/.config/mako/config" -ef "$R/dotfiles/mako/config" ]] && ls "$H/.config/mako/" | grep -q "config.bak.2"'
check "mako running -> makoctl reload"      'grep -q "^makoctl reload" "$T/stub.log"'
check "makoctl reload failure reported"     'grep -q "^mako-reload-failed	" "$MR"'
mv "$B/pgrep.real" "$B/pgrep"

echo "== keystroke capture must be on (system units: report sudo-needed, never sudo)"
check "not installed -> not checked"        '! grep -q keystroke "$REPORT2"'
mkdir -p "$S/etc/systemd/system"; echo unit > "$S/etc/systemd/system/keystroke-log.service"
ksrun() { KR="$T/ks.tsv"; : > "$KR"; : > "$T/systemctl.log"; run_reconcile --quiet --report "$KR" >/dev/null 2>&1; }
ksrun
check "passive, disabled -> keystroke-log sudo-needed" 'grep -q "^sudo-needed	keystroke-log	disabled/inactive" "$KR"'
check "passive, sanitizer off -> reported"  'grep -q "^sudo-needed	keystroke-sanitizer	" "$KR"'
check "never enables a system unit"         '! grep -qE "^enable" "$T/systemctl.log"'
echo keystroke-log >> "$T/enabled"; ksrun
check "enabled but inactive -> still reported" 'grep -q "^sudo-needed	keystroke-log	.*is-active=inactive" "$KR"'
printf 'keystroke-log\nkeystroke-sanitizer\n' >> "$T/active"; echo keystroke-sanitizer >> "$T/enabled"; ksrun
check "passive healthy -> nothing"          '! grep -q keystroke "$KR"'
mkdir -p "$S/etc/interception"
echo "- JOB: intercept -g \$DEVNODE | tee -p >(/usr/local/bin/keystroke-pipe-filter.py) | uinput" > "$S/etc/interception/udevmon.yaml"
sed -i "/^keystroke-log$/d" "$T/enabled" "$T/active"; ksrun
check "tee: keystroke-log disabled is fine" '! grep -q "^sudo-needed	keystroke-log	disabled/inactive (" "$KR"'
check "tee: udevmon off -> reported"        'grep -q "^sudo-needed	udevmon	" "$KR"'
check "tee: filter dead -> reported"        'grep -q "^sudo-needed	keystroke-log	.*keystroke-pipe-filter.py is not running" "$KR"'
echo udevmon >> "$T/enabled"; echo udevmon >> "$T/active"
mv "$B/pgrep" "$B/pgrep.real"
printf '#!/bin/bash\n[[ "$*" == *keystroke-pipe-filter* ]] && exit 0\n[[ "$*" == "-cx intercept" ]] && { cat "%s/ngrab"; exit 0; }\nexec "%s/pgrep.real" "$@"\n' "$T" "$B" > "$B/pgrep"; chmod +x "$B/pgrep"
ksrun
check "tee healthy -> nothing"              '! grep -q keystroke "$KR" && ! grep -q udevmon "$KR"'
# keyboards: built-in (i8042), a Bluetooth one (uhid, matched), udevmon's own
# uinput clone and a power button (both NOT matched)
mkdir -p "$S/proc/bus/input"
cat > "$S/proc/bus/input/devices" <<'DEV'
N: Name="AT Translated Set 2 keyboard"
S: Sysfs=/devices/platform/i8042/serio0/input/input3
B: KEY=402000007 ff803078f800d001 feffffdeffcfffff fffffffffffffffe

N: Name="AT Translated Set 2 keyboard"
S: Sysfs=/devices/virtual/input/input26
B: KEY=402000007 ff803078f800d001 feffffdeffcfffff fffffffffffffffe

N: Name="Ronin X75 BT3 Keyboard"
S: Sysfs=/devices/virtual/misc/uhid/0005:3151:4013.001E/input/input207
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe

N: Name="Power Button"
S: Sysfs=/devices/LNXSYSTM:00/LNXPWRBN:00/input/input2
B: KEY=10000000000000 0
DEV
echo 1 > "$T/ngrab"; ksrun
check "tee: ungrabbed keyboard -> reported" 'grep -q "^sudo-needed	keystroke-log	.*2 physical keyboard(s) but 1 intercept" "$KR"'
echo 2 > "$T/ngrab"; ksrun
check "tee: every keyboard grabbed -> nothing" '! grep -q keystroke "$KR"'
rm -rf "$S/proc"
mv "$B/pgrep.real" "$B/pgrep"; ksrun
echo "unit keystroke-log  # test opt-out" >> "$R/machine-specific/desktop/drift-exceptions.conf"; ksrun
check "drift exception opts the machine out" '! grep -q keystroke "$KR"'
sed -i "/keystroke-log/d" "$R/machine-specific/desktop/drift-exceptions.conf"
rm -rf "$S/etc/systemd/system/keystroke-log.service" "$S/etc/interception"

echo "== ufw-docker replies rule: desktop only"
mkdir -p "$S/etc/ufw"; printf '*filter\n:DOCKER-USER - [0:0]\nCOMMIT\n' > "$S/etc/ufw/after.rules"
DR="$T/dr.tsv"; : > "$DR"; run_reconcile --quiet --report "$DR" >/dev/null 2>&1
check "desktop, rule missing -> sudo-needed" 'grep -q "^sudo-needed	ufw-docker-replies	" "$DR"'
: > "$DR"; env -i HOME="$H" PATH="$B:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" LB_SYS="$S" \
    LB_RECONCILE_ANY_ROOT=1 LB_CHECK_ONLY=1 bash "$R/scripts/install.sh" --device laptop --reconcile --check --quiet --report "$DR" >/dev/null 2>&1
check "laptop, rule missing -> not checked" '! grep -q ufw-docker-replies "$DR"'
rm -rf "$S/etc/ufw"

# ---------------------------------------------------------------- escalation
echo "== Claude Code hooks registered in settings.json (LB_CLAUDE_HOOKS)"
mkdir -p "$H/.claude"
echo '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/x/oom"}]}]}}' > "$H/.claude/settings.json"
out=$(run_reconcile --check 2>&1)
check "check mode only reports the hook"    '[[ "$out" == *"would register Claude Code hook"* ]] && ! grep -q memory-index-lint "$H/.claude/settings.json"'
run_reconcile >/dev/null 2>&1
check "hook registered under PostToolUse"   'jq -e ".hooks.PostToolUse[0].hooks[0].command | test(\"memory-index-lint.sh --hook\")" "$H/.claude/settings.json" >/dev/null'
check "matcher set"                         '[[ "$(jq -r ".hooks.PostToolUse[0].matcher" "$H/.claude/settings.json")" == "Write|Edit|MultiEdit|Bash" ]]'
check "existing hooks kept"                 '[[ "$(jq -r ".hooks.PreToolUse[0].hooks[0].command" "$H/.claude/settings.json")" == "/x/oom" ]]'
n=$(jq ".hooks.PostToolUse | length" "$H/.claude/settings.json")
run_reconcile >/dev/null 2>&1
check "second run idempotent"               '[[ "$(jq ".hooks.PostToolUse | length" "$H/.claude/settings.json")" == "$n" ]]'

echo "== lb-drift grace + rate limit"
ST="$T/state"; mkdir -p "$T/run/hypr/fake"; : > "$T/run/hypr/fake/.socket.sock"
cat > "$B/hyprctl" <<EOF
#!/bin/bash
echo "hyprctl \$*" >> "$T/hypr.log"; echo ok
EOF
chmod +x "$B/hyprctl"
lbd() {  # epoch args...
    local t="$1"; shift
    env -i HOME="$H" PATH="$B:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" HYPRLAND_INSTANCE_SIGNATURE=fake \
        LB_DRIFT_STATE_DIR="$ST" LB_REPO="$R" LB_DRIFT_NOW="$t" python3 "$R/dotfiles/local-bin/lb-drift" "$@"
}
t0=1790000000
lbd $t0 record "$REPORT" >/dev/null
lbd $((t0 + 600)) record "$REPORT" >/dev/null
lbd $((t0 + 1200)) record "$REPORT" >/dev/null
check "no agent before 30 min"              '[[ ! -s "$T/hypr.log" ]]'
check "bar hidden during grace"             '[[ "$(lbd $((t0 + 1200)) waybar)" == *"\"text\": \"\""* ]]'
lbd $((t0 + 1800)) record "$REPORT" >/dev/null
check "agent opens after 3 runs + 30 min"   'grep -q "ghostty .*--class=local-bootstrapping.drift-agent .*lb-drift agent-run" "$T/hypr.log"'
check "notification opened too"             'grep -q "lb-drift notify-wait" "$T/hypr.log"'
check "prompt carries the drift report"     'grep -q "CLAUDE.md" "$ST"/prompt-*.txt && grep -q "should not drift" "$ST"/prompt-*.txt'
check "bar shows the icon once escalated"   '[[ "$(lbd $((t0 + 1800)) waybar)" == *"escalated"* ]]'
: > "$T/hypr.log"
lbd $((t0 + 2400)) record "$REPORT" >/dev/null
check "rate limit: once per fingerprint per day" '[[ ! -s "$T/hypr.log" ]]'

echo "== changed drift restarts the grace; open agent blocks duplicates"
printf 'build-failed\tmonitor-chooser\tx\n' >> "$REPORT"
for i in 0 1 2 3; do lbd $((t0 + 3000 + i * 600)) record "$REPORT" >/dev/null; done
check "new fingerprint escalates after its own grace" 'grep -q "agent-run" "$T/hypr.log"'
: > "$T/hypr.log"
printf 'build-failed\tsomething-else\tx\n' >> "$REPORT"
bash -c 'exec -a claude-fake-agent sleep 60' & fake=$!
printf '{"pid": %d}' "$fake" > "$ST/agent.json"
for i in 0 1 2 3; do lbd $((t0 + 6000 + i * 600)) record "$REPORT" >/dev/null; done
check "no second agent while one is open"   '[[ ! -s "$T/hypr.log" ]]'
kill "$fake" 2>/dev/null; rm -f "$ST/agent.json"

echo "== WIP-only drift waits 2 h"
rm -rf "$ST"; : > "$T/hypr.log"
printf 'git-uncommitted\tabc123\t3 files\n' > "$T/wip.tsv"
for i in 0 1 2 3; do lbd $((t0 + i * 600)) record "$T/wip.tsv" >/dev/null; done
check "no agent at 30 min for WIP"          '[[ ! -s "$T/hypr.log" ]]'
lbd $((t0 + 7200)) record "$T/wip.tsv" >/dev/null
check "agent at 2 h for WIP"                'grep -q "agent-run" "$T/hypr.log"'

echo "== clean report clears the state"
: > "$T/empty.tsv"
lbd $((t0 + 8000)) record "$T/empty.tsv" >/dev/null
check "state clean"                         '[[ "$(lbd $((t0 + 8000)) status)" == "In sync"* ]]'
check "bar hidden when clean"               '[[ "$(lbd $((t0 + 8000)) waybar)" == *"\"text\": \"\""* ]]'

echo "== escalate --test --dry-run opens nothing"
: > "$T/hypr.log"
out=$(lbd $t0 escalate --test --dry-run)
check "dry-run prints the test prompt"      '[[ "$out" == *"lb-drift escalation test received"* && ! -s "$T/hypr.log" ]]'

echo
echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
