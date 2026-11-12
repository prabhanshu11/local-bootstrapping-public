# shellcheck shell=bash
# scripts/lib/reconcile.sh — the ONE implementation of "make this machine match
# the repo" for everything that needs no sudo. Sourced by scripts/install.sh.
#
#   install.sh               full install: calls lb_reconcile_links + lb_reconcile_units
#   install.sh --reconcile   what sync-from-master.sh runs EVERY 10 minutes:
#                            lb_reconcile_all (links, hypr sources, ssh Include, units, mako reload,
#                            sudo-file checks, monitor-chooser build, hypr
#                            config errors, waybar) — quiet when nothing changed
#
# Why: until 2026-09-30 the sync timer pulled git on every machine but never
# re-ran the linking step, so the desktop drifted 67 of 143 links behind (top
# bar broken). See docs/issues/desktop-drift-2026-09-30.md.
#
# Caller provides: SYMLINKS array ("src-under-dotfiles:dst"), REPO_ROOT,
# DOTFILES, DEVICE_TYPE. Optional:
#   LB_REPORT     file; unresolved drift is appended as "kind<TAB>key<TAB>detail"
#   LB_SKIP_DSTS  array of destinations never touched (sync mode)
#   LB_CHECK_ONLY=1   report what would change, change nothing
#   LB_QUIET=1        only print changes and problems
#
# Link rules (both modes):
#   correct symlink ............ nothing
#   missing .................... create the link
#   dangling symlink, or symlink/regular file whose content is IDENTICAL to
#   the repo source ............ back it up (dst.bak, or dst.bak.<stamp> when
#                                one exists) and link — no behaviour change
#   anything whose content DIFFERS, or a real directory in the way
#                              .. never clobbered: reported as a link-conflict
#                                 (the machine has local changes the repo lacks;
#                                 the escalation agent reconciles and commits)
#   exception: a symlink that is Omarchy's own stock link (LB_STOCK_LINKS,
#   exact target) is not a local change: backed up and linked like a heal
#
# Device-specific files: machine-specific/<device>/symlinks.conf, lines
# "src:dst". src relative = machine-specific/<device>/src; src starting with
# / or ~ is used as is. dst may use ~ or $HOME. An entry with the same dst as a
# SYMLINKS entry replaces it on that device.
# machine-specific/<device>/drift-exceptions.conf, lines "kind key  # reason"
# (kind: unit | link | sysfile): that item is neither changed nor reported.

LB_STAMP() { date +%Y%m%d-%H%M%S; }

_lb_say()  { [[ "${LB_QUIET:-0}" == 1 ]] || echo -e "  $*"; }
_lb_note() { echo -e "  $*"; }   # changes + problems: always printed

lb_item() {  # kind key detail — record unresolved drift
    local kind="$1" key="$2" detail="${3:-}"
    _lb_note "DRIFT [$kind] $key${detail:+ — $detail}"
    if [[ -n "${LB_REPORT:-}" ]]; then
        printf '%s\t%s\t%s\n' "$kind" "$key" "${detail//$'\t'/ }" >> "$LB_REPORT"
    fi
}

lb_expand() {  # expand a leading ~ or $HOME
    local p="$1"
    case "$p" in
        "~/"*) p="$HOME/${p#\~/}" ;;
        '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
    esac
    printf '%s' "$p"
}

lb_detect_device() {  # [forced]
    if [[ -n "${1:-}" ]]; then echo "$1"; return; fi
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || true)
    case "$ts_ip" in
        100.64.0.1) echo "desktop" ;;
        100.64.0.2) echo "laptop" ;;
        *)
            if [[ -d /sys/class/power_supply/BAT0 || -d /sys/class/power_supply/BAT1 ]]; then
                echo "laptop"
            else
                echo "desktop"
            fi
            ;;
    esac
}

lb_machine_dir() { echo "$REPO_ROOT/machine-specific/$DEVICE_TYPE"; }

# Gates mirror install.sh's own checks for the matching setup_* step.
lb_gate() {
    case "$1" in
        all)     return 0 ;;
        battery) [[ -d "${LB_SYS:-}/sys/class/power_supply/BAT0" ]] ;;
        edp)     compgen -G "${LB_SYS:-}/sys/class/drm/*eDP*" >/dev/null ;;
        tpacpi)  [[ -e "${LB_SYS:-}/sys/class/leds/tpacpi::kbd_backlight/brightness" ]] ;;
        desktop-board) [[ "$(cat "${LB_SYS:-}/sys/class/dmi/id/board_name" 2>/dev/null)" == "PRIME A520M-K" ]] ;;
        # USB fingerprint reader (libfprint vendors: Synaptics, Goodix, Validity,
        # FocalTech, Upek, Elan-MOC); the laptop's is 06cb:00bd, the desktop has none
        fprint)  grep -qsxE '06cb|27c6|138a|2808|147e|1c7a' "${LB_SYS:-}"/sys/bus/usb/devices/*/idVendor ;;
        desktop) [[ "$DEVICE_TYPE" == "desktop" ]] ;;
        laptop)  [[ "$DEVICE_TYPE" == "laptop" ]] ;;
        *) return 1 ;;
    esac
}

lb_excepted() {  # kind key
    local f
    f="$(lb_machine_dir)/drift-exceptions.conf"
    [[ -f "$f" ]] || return 1
    local kind key
    while read -r kind key _; do
        [[ -z "$kind" || "$kind" == \#* ]] && continue
        key=$(lb_expand "$key")
        [[ "$kind" == "$1" && "$key" == "$2" ]] && return 0
    done < "$f"
    return 1
}

# Fill LB_PLAN_SRC / LB_PLAN_DST from SYMLINKS + the device overlay.
lb_build_plan() {
    LB_PLAN_SRC=(); LB_PLAN_DST=()
    local -A idx=()
    local m src dst i=0
    for m in "${SYMLINKS[@]}"; do
        src="${m%%:*}"; dst="${m##*:}"
        LB_PLAN_SRC+=("$DOTFILES/$src"); LB_PLAN_DST+=("$dst")
        idx["$dst"]=$i; i=$((i + 1))
    done
    local mdir overlay
    mdir="$(lb_machine_dir)"
    overlay="$mdir/symlinks.conf"
    [[ -f "$overlay" ]] || return 0
    while IFS=: read -r src dst; do
        src="${src%%#*}"; src="${src//[[:space:]]/}"
        dst="${dst%%#*}"; dst="${dst//[[:space:]]/}"
        [[ -z "$src" || -z "$dst" ]] && continue
        dst=$(lb_expand "$dst")
        case "$src" in
            /*|"~/"*|'$HOME/'*) src=$(lb_expand "$src") ;;
            *) src="$mdir/$src" ;;
        esac
        if [[ -n "${idx[$dst]:-}" ]]; then
            LB_PLAN_SRC[${idx[$dst]}]="$src"
        else
            LB_PLAN_SRC+=("$src"); LB_PLAN_DST+=("$dst")
            idx["$dst"]=$i; i=$((i + 1))
        fi
    done < "$overlay"
}

# Omarchy's stock links ("dst|target", target exactly as readlink prints it).
# A fresh Omarchy install creates them; the repo file replaces them on purpose
# (it includes the same target), so they heal instead of being a conflict.
# Any other differing link or file at dst is still never clobbered.
LB_STOCK_LINKS=(
    # omarchy install/config/theme.sh: ln -snf ~/.config/omarchy/current/theme/mako.ini ~/.config/mako/config
    "$HOME/.config/mako/config|$HOME/.config/omarchy/current/theme/mako.ini"
)
lb_stock_link() {  # dst — true when dst is the Omarchy stock symlink for it
    local e
    [[ -L "$1" ]] || return 1
    for e in "${LB_STOCK_LINKS[@]}"; do
        [[ "${e%%|*}" == "$1" && "$(readlink "$1")" == "${e#*|}" ]] && return 0
    done
    return 1
}

_lb_backup_path() {
    local dst="$1"
    if [[ -e "$dst.bak" || -L "$dst.bak" ]]; then
        echo "$dst.bak.$(LB_STAMP)"
    else
        echo "$dst.bak"
    fi
}

# Returns (via LB_LINK_STATE): ok | linked | healed | conflict | skipped
lb_link_one() {
    local src="$1" dst="$2" reason=""
    LB_LINK_STATE=ok
    local s
    for s in "${LB_SKIP_DSTS[@]}"; do
        [[ "$s" == "$dst" ]] && { LB_LINK_STATE=skipped; return 0; }
    done
    if lb_excepted link "$dst"; then LB_LINK_STATE=skipped; return 0; fi
    [[ -e "$src" ]] || { LB_LINK_STATE=skipped; return 0; }   # source not in repo (yet)

    if [[ -L "$dst" && "$dst" -ef "$src" ]]; then return 0; fi

    if [[ ! -e "$dst" && ! -L "$dst" ]]; then
        LB_LINK_STATE=linked
    elif [[ -L "$dst" && ! -e "$dst" ]]; then
        LB_LINK_STATE=healed; reason="dangling symlink"
    elif [[ -d "$dst" && ! -L "$dst" ]]; then
        lb_item link-conflict "$dst" "a real directory is in the way of $src"
        LB_LINK_STATE=conflict; return 0
    elif [[ -f "$dst" && -f "$src" ]] && cmp -s "$dst" "$src"; then
        LB_LINK_STATE=healed
        if [[ -L "$dst" ]]; then reason="symlink to an identical copy ($(readlink "$dst"))"
        else reason="identical regular file"; fi
    elif lb_stock_link "$dst"; then
        LB_LINK_STATE=healed; reason="Omarchy stock link to $(readlink "$dst")"
    else
        local what="regular file"
        [[ -L "$dst" ]] && what="symlink to $(readlink "$dst")"
        lb_item link-conflict "$dst" "$what differs from the repo's $src"
        LB_LINK_STATE=conflict; return 0
    fi

    if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
        _lb_note "WOULD $LB_LINK_STATE $dst -> $src${reason:+ ($reason)}"
        return 0
    fi
    if [[ "$LB_LINK_STATE" == healed ]]; then
        local bak
        bak=$(_lb_backup_path "$dst")
        if ! mv "$dst" "$bak"; then
            lb_item link-failed "$dst" "could not move it aside to $bak"
            LB_LINK_STATE=conflict; return 0
        fi
        reason="$reason; old one kept as $bak"
    fi
    if mkdir -p "$(dirname "$dst")" && ln -sfn "$src" "$dst"; then
        _lb_note "$LB_LINK_STATE $dst -> $src${reason:+ ($reason)}"
    else
        lb_item link-failed "$dst" "ln -s $src failed"
        LB_LINK_STATE=conflict
    fi
}

# Reconcile every planned link. Sets LB_CHANGED_DSTS (links created/healed).
lb_reconcile_links() {
    lb_build_plan
    LB_CHANGED_DSTS=()
    local i n_ok=0 n_conf=0
    for i in "${!LB_PLAN_DST[@]}"; do
        lb_link_one "${LB_PLAN_SRC[$i]}" "${LB_PLAN_DST[$i]}"
        case "$LB_LINK_STATE" in
            linked|healed) LB_CHANGED_DSTS+=("${LB_PLAN_DST[$i]}") ;;
            conflict) n_conf=$((n_conf + 1)) ;;
            ok) n_ok=$((n_ok + 1)) ;;
        esac
    done
    _lb_say "links: $n_ok ok, ${#LB_CHANGED_DSTS[@]} changed, $n_conf unresolved"
}

# Hyprland must source the override bindings from bindings.conf (loaded after
# Omarchy's tiling-v2.conf). A commented-out line counts as present: that is a
# deliberate disable and is respected.
LB_HYPR_SOURCES=(bindings-special-keys.conf bindings-close-ordered.conf bindings-alt-tab.conf bindings-no-close-all.conf bindings-screenshot.conf)
# "file gate": device-only files (linked by machine-specific/<device>/symlinks.conf),
# sourced only where the gate passes AND the link exists (a missing source file
# is a Hyprland config error).
LB_HYPR_SOURCES_GATED=(
    "windowrules-wall.conf desktop"
)
lb_ensure_hypr_sources() {
    local bindings_file="$HOME/.config/hypr/bindings.conf" f entry gate
    [[ -f "$bindings_file" ]] || return 0
    local -a files=("${LB_HYPR_SOURCES[@]}")
    for entry in "${LB_HYPR_SOURCES_GATED[@]}"; do
        read -r f gate <<< "$entry"
        lb_gate "$gate" || continue
        [[ -e "$HOME/.config/hypr/$f" ]] || continue
        files+=("$f")
    done
    for f in "${files[@]}"; do
        grep -q "$f" "$bindings_file" && continue
        if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
            _lb_note "WOULD add 'source = ~/.config/hypr/$f' to bindings.conf"
        else
            echo "source = ~/.config/hypr/$f" >> "$bindings_file"
            _lb_note "added 'source = ~/.config/hypr/$f' to bindings.conf"
        fi
    done
}

# User units the installer enables, with the installer's own gate.
# "unit gate now|boot". Keep in sync with the setup_* functions in install.sh.
# NOT here on purpose: claude-remote-control (managed separately), telegram-*
# (enabled on neither machine as of 2026-09-30 — installer stale, his call),
# kbd-backlight-keeper (armed from the widget, a user decision).
LB_USER_UNITS=(
    "bar-touch.service all now"
    "workspace-labels.service edp now"
    "media-history-recorder.service all now"
    "power-profile-daemon.service all now"
    "disk-health-logger.service all now"
    "disk-health-review.timer laptop now"
    "local-bootstrapping-sync.timer all now"
    "clipboard-health.timer all now"
    "drift-detector.timer all now"
    "wallpaper-rotate.timer all now"
    "swayosd-server.service all now"
    "swayosd-health.timer all now"
    "close-all-guard.path all now"
    "close-all-guard.timer all now"
    "power-loss-monitor.service all boot"
    "hyprland-monitor-persist.service edp boot"
    "hyprland-monitor-resume.service edp boot"
    "power-profile-monitor.timer battery now"
    "power-profile-watchdog.timer battery now"
    "battery-guard.timer battery now"
    "laptop-state-snapshot.timer battery now"
    "sleep-watch.service battery now"
    "sunshine-health.timer desktop now"
    "wall-guard.timer desktop now"
    "lane-reaper.timer desktop now"
    "disk-pressure.timer desktop now"
    "uv-cache-prune.timer desktop now"
    "vdi-vm-rdp-proxy.service desktop now"
    "vdi-vm-keeper.service desktop now"
    "claude-tokens-export.timer all now"
    "moonlight-health.timer laptop now"
)

lb_systemctl() { ${LB_SYSTEMCTL:-systemctl} --user "$@"; }

lb_reconcile_units() {
    local units_changed="${1:-0}"
    if [[ "$units_changed" == 1 && "${LB_CHECK_ONLY:-0}" != 1 ]]; then
        lb_systemctl daemon-reload 2>/dev/null || true
        _lb_note "systemctl --user daemon-reload (unit files changed)"
    fi
    local entry unit gate when state
    local -a want=() whens=()
    for entry in "${LB_USER_UNITS[@]}"; do
        read -r unit gate when <<< "$entry"
        lb_gate "$gate" || continue
        lb_excepted unit "$unit" && continue
        [[ -e "$HOME/.config/systemd/user/$unit" ]] || continue  # not linked (no source)
        want+=("$unit"); whens+=("$when")
    done
    [[ ${#want[@]} -gt 0 ]] || return 0
    local -a states=()
    # One call; systemctl prints one state line per unit, in order.
    mapfile -t states < <(lb_systemctl is-enabled "${want[@]}" 2>/dev/null)
    local i
    for i in "${!want[@]}"; do
        unit="${want[$i]}"; state="${states[$i]:-unknown}"
        case "$state" in
            enabled|enabled-runtime|static|indirect|generated|alias) continue ;;
            masked|masked-runtime) _lb_say "unit $unit is masked — left alone"; continue ;;
        esac
        if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
            _lb_note "WOULD enable $unit (${whens[$i]}; is $state)"
            continue
        fi
        local -a args=(enable)
        [[ "${whens[$i]}" == now ]] && args+=(--now)
        if lb_systemctl "${args[@]}" "$unit" >/dev/null 2>&1; then
            _lb_note "enabled $unit (${whens[$i]}; was $state)"
        else
            lb_item unit-failed "$unit" "systemctl --user ${args[*]} $unit failed (was $state)"
        fi
    done
}

# Files the installer puts in place WITH sudo. The sync never uses sudo: a
# missing/different copy is reported as drift (fix: re-run the named step).
# "repo-src dst gate install.sh-step"
LB_SYSTEM_FILES=(
    "system/logind.conf.d/10-sleep-operation.conf /etc/systemd/logind.conf.d/10-sleep-operation.conf battery setup_power_profile"
    "system/upower/10-battery-guard.conf /etc/UPower/UPower.conf.d/10-battery-guard.conf battery setup_power_profile"
    "system/udev-rules/99-power-profile.rules /etc/udev/rules.d/99-power-profile.rules battery setup_power_profile"
    "system/mkinitcpio.conf.d/zz-hibernate-resume.conf /etc/mkinitcpio.conf.d/zz-hibernate-resume.conf battery setup_power_profile"
    "system/mkinitcpio.conf.d/zz-hibernate-no-nvidia.conf /etc/mkinitcpio.conf.d/zz-hibernate-no-nvidia.conf battery setup_power_profile"
    "system/systemd/sleep.conf.d/10-hibernate.conf /etc/systemd/sleep.conf.d/10-hibernate.conf battery setup_power_profile"
    "system/bin/hibernate-resume-config /usr/local/bin/hibernate-resume-config battery setup_power_profile"
    "system/systemd/hibernate-resume-config.service /etc/systemd/system/hibernate-resume-config.service battery setup_power_profile"
    "system/pam.d/system-login /etc/pam.d/system-login fprint setup-fingerprint-auth.sh"
    "system/udev-rules/99-kbd-backlight.rules /etc/udev/rules.d/99-kbd-backlight.rules tpacpi setup_kbd_backlight"
    "system/systemd/walker-resume-restart.service /etc/systemd/system/walker-resume-restart.service battery setup_walker_resume_restart"
    "system/bin/wifi-wedge-watchdog /usr/local/bin/wifi-wedge-watchdog desktop-board setup_wifi_wedge_watchdog"
    "system/chrome/policies/managed/distractions.json /etc/opt/chrome/policies/managed/distractions.json laptop setup_chrome_policy"
    "system/systemd/wifi-wedge-watchdog.service /etc/systemd/system/wifi-wedge-watchdog.service desktop-board setup_wifi_wedge_watchdog"
    "system/systemd/wifi-wedge-watchdog.timer /etc/systemd/system/wifi-wedge-watchdog.timer desktop-board setup_wifi_wedge_watchdog"
    "system/modprobe.d/rtw88.conf /etc/modprobe.d/rtw88.conf desktop-board setup_wifi_wedge_watchdog"
    "system/iwd/main.conf /etc/iwd/main.conf desktop-board setup_wifi_wedge_watchdog"
    "system/udev-rules/60-ioscheduler-bfq.rules /etc/udev/rules.d/60-ioscheduler-bfq.rules desktop desktop-disk-speedup.sh"
    "system/bin/btrfs-autobalance /usr/local/bin/btrfs-autobalance desktop desktop-space-root-install.sh"
    "system/systemd/btrfs-autobalance.service /etc/systemd/system/btrfs-autobalance.service desktop desktop-space-root-install.sh"
    "system/systemd/btrfs-autobalance.timer /etc/systemd/system/btrfs-autobalance.timer desktop desktop-space-root-install.sh"
    "system/bin/net-selfheal /usr/local/bin/net-selfheal desktop desktop-away-1101/phase1.sh"
    "system/systemd/net-selfheal.service /etc/systemd/system/net-selfheal.service desktop desktop-away-1101/phase1.sh"
    "system/systemd/net-selfheal.timer /etc/systemd/system/net-selfheal.timer desktop desktop-away-1101/phase1.sh"
    "system/systemd-network/20-ethernet.network.d/dns.conf /etc/systemd/network/20-ethernet.network.d/dns.conf desktop desktop-away-1101/phase1.sh"
    "configs/keystroke-log/keystroke-logger.py /usr/local/bin/keystroke-logger.py all setup_keystroke_log"
    "configs/keystroke-log/keystroke-sanitizer.py /usr/local/bin/keystroke-sanitizer.py all setup_keystroke_log"
    "configs/keystroke-log/keystroke-log.service /etc/systemd/system/keystroke-log.service all setup_keystroke_log"
    "configs/keystroke-log/keystroke-sanitizer.service /etc/systemd/system/keystroke-sanitizer.service all setup_keystroke_log"
    "configs/keystroke-log/keystroke-log-restart.hook /etc/pacman.d/hooks/keystroke-log-restart.hook all setup_keystroke_log"
    "configs/keystroke-log/ks-unlock /usr/local/bin/ks-unlock all setup_keystroke_log"
    "configs/keystroke-log/ks-redact-refresh.service /etc/systemd/system/ks-redact-refresh.service all setup_keystroke_log"
    "configs/keystroke-log/ks-redact-refresh.timer /etc/systemd/system/ks-redact-refresh.timer all setup_keystroke_log"
)

lb_check_system_files() {
    local entry src dst gate step
    for entry in "${LB_SYSTEM_FILES[@]}"; do
        read -r src dst gate step <<< "$entry"
        lb_gate "$gate" || continue
        [[ -f "$REPO_ROOT/$src" ]] || continue
        lb_excepted sysfile "$dst" && continue
        local real="${LB_SYS:-}$dst"   # LB_SYS: fake root for tests
        if [[ ! -e "$real" ]]; then
            lb_item sudo-needed "$dst" "missing; install.sh step $step (sudo) installs $src"
        elif [[ -r "$real" ]] && ! cmp -s "$REPO_ROOT/$src" "$real"; then
            lb_item sudo-needed "$dst" "differs from repo $src; install.sh step $step (sudo)"
        fi
    done
}

# keystroke-log is default-on text recovery on every machine. Installing its
# files is not enough: on 2026-10-14 a typed V4 answer was missing and
# keystroke-log was found disabled on the laptop, and no check here could say
# whether capture had been running (it had, via the tee). Now every sync checks
# it. Capture has two modes (same test as keystroke-bar):
#   tee     - /etc/interception/udevmon.yaml carries keystroke-pipe-filter
#             (configs/keystroke-log/pipeline-tee, the laptop): udevmon must be
#             enabled + active and the filter process alive. keystroke-log is
#             deliberately disabled there (it is blind behind the grab).
#   passive - keystroke-log.service must be enabled AND active.
# keystroke-sanitizer (the shareable copy) must be enabled + active in both.
# All are system units: the sync has no sudo, so a failure is reported as
# sudo-needed and lb-drift escalates it. Opt a machine out with
# "unit keystroke-log" in its drift-exceptions.conf.
# Physical keyboards udevmon's "EV_KEY: [KEY_SPACE]" rule grabs: nodes with
# KEY_SPACE (57) that are not uinput devices (udevmon skips
# /sys/devices/virtual/input/: its own clones, ydotool, hyprwhspr, the
# bar-touch on-screen keyboard). Bluetooth keyboards (uhid) DO match.
# One name per line. Shared with dotfiles/local-bin/keystroke-bar.
lb_keyboard_nodes() {  # [devices-file]
    awk '
BEGIN { RS = ""; FS = "\n" }
{
    name = ""; sys = ""; key = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^N: Name=/) { name = $i; sub(/^N: Name="/, "", name); sub(/"$/, "", name) }
        if ($i ~ /^S: Sysfs=/) { sys = $i; sub(/^S: Sysfs=/, "", sys) }
        if ($i ~ /^B: KEY=/) { key = $i; sub(/^B: KEY=/, "", key) }
    }
    if (key == "" || sys ~ /^\/devices\/virtual\/input\//) next
    n = split(key, w, " "); last = w[n]
    if (length(last) < 15) next          # bit 57 = hex digit 14 from the right, its bit 1
    v = index("0123456789abcdef", tolower(substr(last, length(last) - 14, 1))) - 1
    if (int(v / 2) % 2 == 1) print name
}' "${1:-/proc/bus/input/devices}" 2>/dev/null
}

# Omarchy's ufw-docker drops UDP replies into containers (ports < 32768) unless our ESTABLISHED rule is in after.rules
# (11-05: the Windows VM's NTP replies, docs/vdi.md "Windows clock"). Checked only; the fix needs sudo.
# Desktop only (his decision 2026-11-10, via local-bootstrapping-4d): the Docker reply problem exists only on the
# desktop, which hosts the Windows container; the laptop's ufw-docker block is left as Omarchy ships it.
lb_check_docker_replies() {
    lb_gate desktop || return 0
    local f="${LB_SYS:-}/etc/ufw/after.rules"
    [[ -r "$f" ]] && grep -q '^:DOCKER-USER - \[0:0\]' "$f" || return 0
    grep -qxF -- '-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN' "$f" && return 0
    lb_item sudo-needed ufw-docker-replies "ufw-docker drops UDP replies into containers (Windows VM clock); fix: sudo scripts/vdi/desktop-docker-replies-firewall.sh"
}

lb_check_keystroke_capture() {
    local root="${LB_SYS:-}" sc="${LB_SYSTEMCTL:-systemctl}"
    [[ -f "$root/etc/systemd/system/keystroke-log.service" ]] || return 0  # not installed: LB_SYSTEM_FILES reports it
    lb_excepted unit keystroke-log && return 0
    local units=(keystroke-sanitizer) unit en act
    if grep -qs keystroke-pipe-filter "$root/etc/interception/udevmon.yaml"; then
        units+=(udevmon)
        if ! ${LB_PGREP:-pgrep} -f keystroke-pipe-filter.py >/dev/null 2>&1; then
            lb_item sudo-needed keystroke-log "disabled/inactive: pipeline-tee configured but keystroke-pipe-filter.py is not running, nothing is captured; fix: sudo systemctl restart udevmon (configs/keystroke-log/pipeline-tee/README.md)"
        fi
        # Every physical keyboard needs its own intercept job (one grab each);
        # an ungrabbed keyboard is typed on but never logged.
        local devs="$root/proc/bus/input/devices" nkb ngrab
        if [[ -r "$devs" ]]; then
            nkb=$(lb_keyboard_nodes "$devs" | wc -l)
            ngrab=$(${LB_PGREP:-pgrep} -cx intercept 2>/dev/null); ngrab=${ngrab:-0}
            if (( ngrab < nkb )); then
                lb_item sudo-needed keystroke-log "disabled/inactive: $nkb physical keyboard(s) but $ngrab intercept grab(s), typing on the rest is not logged ($(lb_keyboard_nodes "$devs" | paste -sd, -)); fix: sudo systemctl restart udevmon"
            fi
        fi
    else
        units=(keystroke-log "${units[@]}")
    fi
    for unit in "${units[@]}"; do
        en=$($sc is-enabled "$unit" 2>/dev/null | head -n1)
        act=$($sc is-active "$unit" 2>/dev/null | head -n1)
        [[ "$en" == enabled && "$act" == active ]] && continue
        lb_item sudo-needed "$unit" "disabled/inactive (is-enabled=${en:-unknown}, is-active=${act:-unknown}); keystroke capture is default-on; fix: sudo systemctl enable --now $unit"
    done
}

# monitor-chooser (bar widget backend) is built from apps/monitor-chooser.
lb_check_monitor_chooser() {
    local app="$REPO_ROOT/apps/monitor-chooser"
    local bin="$app/bin/monitor-chooser"
    [[ -x "$app/build.sh" ]] || return 0
    if [[ -x "$bin" ]] && [[ -z "$(find "$app" -path "$app/bin" -prune -o -path "$app/target" -prune -o \
            -type f -newer "$bin" \( -name '*.rs' -o -name 'Cargo.*' -o -name '*.go' -o -name 'go.*' -o -name '*.py' -o -name build.sh \) -print -quit 2>/dev/null)" ]]; then
        return 0
    fi
    if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
        _lb_note "WOULD build monitor-chooser (binary missing or older than its sources)"
        return 0
    fi
    local log="$HOME/.local/share/local-bootstrapping-build.log"
    if nice -n 19 "$app/build.sh" >> "$log" 2>&1; then
        _lb_note "built monitor-chooser"
    else
        lb_item build-failed monitor-chooser "apps/monitor-chooser/build.sh failed; log $log"
    fi
}

# Graphical session helpers (the sync service inherits the session env from
# uwsm, but a Hyprland restart makes the signature stale: re-resolve it).
lb_hypr_env() {
    local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    [[ -d "$rt/hypr" ]] || return 1
    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" || ! -S "$rt/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock" ]]; then
        local sig
        sig=$(ls -t "$rt/hypr" 2>/dev/null | head -1)
        [[ -n "$sig" && -S "$rt/hypr/$sig/.socket.sock" ]] || return 1
        export HYPRLAND_INSTANCE_SIGNATURE="$sig"
    fi
    export XDG_RUNTIME_DIR="$rt"
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || export WAYLAND_DISPLAY=wayland-1
    return 0
}

# Omarchy updates can overwrite the compat patches (red error bar). Cheap
# check each run; patch only when Hyprland actually reports errors.
lb_check_hypr_errors() {
    command -v hyprctl >/dev/null || return 0
    lb_hypr_env || return 0
    local errs
    errs=$(hyprctl configerrors 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    [[ -z "$errs" ]] && return 0
    if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
        _lb_note "WOULD run the Hyprland compat patches (configerrors: $(head -1 <<< "$errs"))"
        return 0
    fi
    _lb_note "Hyprland reports config errors — running the compat patches"
    "$REPO_ROOT/scripts/fix-hyprland-054-compat.sh" >/dev/null 2>&1 || true
    "$REPO_ROOT/scripts/fix-hyprland-056-compat.sh" >/dev/null 2>&1 || true
    errs=$(hyprctl configerrors 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    if [[ -n "$errs" ]]; then
        lb_item hypr-configerrors "hyprctl configerrors" "$(head -3 <<< "$errs" | tr '\n' ' ')"
    fi
}

# Waybar: reload (SIGUSR2) when its files changed; start it only if it is dead.
# Never a cold restart of a live bar (repo CLAUDE.md "Reload, Never Restart").
lb_waybar_refresh() {
    local changed="${1:-0}"
    command -v waybar >/dev/null || return 0
    lb_hypr_env || return 0
    if pgrep -x waybar >/dev/null; then
        [[ "$changed" == 1 ]] || return 0
        if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then _lb_note "WOULD reload waybar (SIGUSR2)"; return 0; fi
        "$DOTFILES/local-bin/touch-mode" ensure >/dev/null 2>&1 || true
        pkill -SIGUSR2 -x waybar && _lb_note "waybar reloaded (SIGUSR2)"
    else
        if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then _lb_note "WOULD start waybar (not running)"; return 0; fi
        "$DOTFILES/local-bin/touch-mode" ensure >/dev/null 2>&1 || true
        hyprctl dispatch exec waybar >/dev/null 2>&1 || true
        sleep 3
        if pgrep -x waybar >/dev/null; then
            _lb_note "waybar was not running — started it"
        else
            lb_item waybar-dead waybar "waybar is not running and would not start"
        fi
    fi
}

# mako: `makoctl reload` when its config link was just created or healed (a
# reload keeps the active modes, so wall-guard's do-not-disturb stays on).
lb_mako_refresh() {
    local d changed=0
    for d in "${LB_CHANGED_DSTS[@]}"; do
        [[ "$d" == "$HOME/.config/mako/"* ]] && changed=1
    done
    [[ "$changed" == 1 ]] || return 0
    command -v makoctl >/dev/null || return 0
    pgrep -x mako >/dev/null || return 0      # not running: it reads the link when it starts
    if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then _lb_note "WOULD reload mako (makoctl reload)"; return 0; fi
    if makoctl reload >/dev/null 2>&1; then
        _lb_note "mako reloaded (makoctl reload)"
    else
        lb_item mako-reload-failed "$HOME/.config/mako/config" "makoctl reload failed (config error?)"
    fi
}

# Everything above, in order. Used by `install.sh --reconcile` (the sync).
# ---- Claude Code hooks (settings.json) ----------------------------------------
# Hooks the installer registers in ~/.claude/settings.json; the sync re-checks
# them so neither machine runs without one. EVENT::MATCHER::COMMAND
# (empty MATCHER = none). Idempotent, jq merge, never removes anything.
LB_CLAUDE_HOOKS=(
    # memory-index-lint: keeps ~/.claude/projects/*/memory/MEMORY.md inside the
    # 25 KB / 200 lines Claude Code loads (2026-10-01, docs/memory-index-lint.md)
    "PostToolUse::Write|Edit|MultiEdit|Bash::$HOME/.claude/hooks/memory-index-lint.sh --hook"
)

lb_reconcile_claude_hooks() {
    local settings="$HOME/.claude/settings.json" spec ev rest matcher cmd tmp
    [[ -f "$settings" ]] || return 0            # no Claude Code on this machine yet
    if ! command -v jq >/dev/null 2>&1; then
        lb_item hook-needs-jq claude-hooks "jq missing: cannot register Claude Code hooks"; return 0
    fi
    for spec in "${LB_CLAUDE_HOOKS[@]}"; do
        ev=${spec%%::*}; rest=${spec#*::}; matcher=${rest%%::*}; cmd=${rest#*::}
        if jq -e --arg ev "$ev" --arg c "$cmd" \
             '.hooks[$ev][]?.hooks[]? | select(.command == $c)' "$settings" >/dev/null 2>&1; then
            continue
        fi
        if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
            _lb_note "would register Claude Code hook: $ev ($matcher) → $cmd"; continue
        fi
        tmp=$(mktemp)
        if jq --arg ev "$ev" --arg m "$matcher" --arg c "$cmd" '
             .hooks = (.hooks // {})
             | .hooks[$ev] = ((.hooks[$ev] // [])
                 + [ (if $m == "" then {} else {matcher: $m} end)
                     + {hooks: [{type: "command", command: $c}]} ])' \
             "$settings" >"$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
            cp "$settings" "${settings}.bak.$(date +%s)"
            mv "$tmp" "$settings"
            _lb_note "registered Claude Code hook: $ev ($matcher) → $cmd"
        else
            rm -f "$tmp"
            lb_item hook-register-failed "$ev" "could not merge $cmd into $settings"
        fi
    done
}

# Claude Code status line (the bar under the input box): conversation id + live
# context bars for the main agent and every running subagent. Set only when
# settings.json has NO statusLine; a different one is reported, never replaced.
# docs/claude-statusline.md
LB_CLAUDE_STATUSLINE_CMD="python3 $HOME/.claude/statusline/agent-context-bar.py"

lb_reconcile_claude_statusline() {
    local settings="$HOME/.claude/settings.json" cur tmp
    [[ -f "$settings" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    cur=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)
    [[ "$cur" == "$LB_CLAUDE_STATUSLINE_CMD" ]] && return 0
    if [[ -n "$cur" ]]; then
        _lb_note "Claude Code statusLine is '$cur', not agent-context-bar (left as is)"; return 0
    fi
    if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
        _lb_note "would set Claude Code statusLine → $LB_CLAUDE_STATUSLINE_CMD"; return 0
    fi
    tmp=$(mktemp)
    if jq --arg c "$LB_CLAUDE_STATUSLINE_CMD" '.statusLine = {type: "command", command: $c, padding: 0}' \
         "$settings" >"$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        cp "$settings" "${settings}.bak.$(date +%s)"
        mv "$tmp" "$settings"
        _lb_note "set Claude Code statusLine → $LB_CLAUDE_STATUSLINE_CMD"
    else
        rm -f "$tmp"
        lb_item statusline-failed claude-statusline "could not set statusLine in $settings"
    fi
}

# ~/.ssh/config must `Include home-routes.conf` (the SYMLINKS entry, linked
# above) at its TOP, or pi5/nas/desktop-auto never resolve and the Include's
# values lose to older Host blocks. setup-ssh.sh writes it on a full install;
# the desktop had the link but not the Include (2026-11-10 drift agent).
# User-level, prepend only: the rest of the file is never rewritten.
lb_reconcile_ssh_include() {
    local cfg="$HOME/.ssh/config" tmp
    [[ -d "$HOME/.ssh" && -f "$DOTFILES/ssh/home-routes.conf" ]] || return 0
    [[ -f "$cfg" ]] && grep -qE '^Include home-routes\.conf' "$cfg" && return 0
    if [[ "${LB_CHECK_ONLY:-0}" == 1 ]]; then
        _lb_note "WOULD add 'Include home-routes.conf' at the top of $cfg"; return 0
    fi
    tmp=$(mktemp) || return 0
    {
        echo "# Home machines by one name in his channel order (pi5/nas, desktop-auto): local-bootstrapping dotfiles/ssh/home-routes.conf"
        echo "Include home-routes.conf"
        echo
        if [[ -f "$cfg" ]]; then cat "$cfg"; fi
    } > "$tmp"
    [[ -f "$cfg" ]] || { : > "$cfg" && chmod 600 "$cfg"; }
    if cat "$tmp" > "$cfg"; then
        _lb_note "added 'Include home-routes.conf' at the top of $cfg"
    else
        lb_item ssh-include "$cfg" "could not add 'Include home-routes.conf' (see scripts/setup-ssh.sh)"
    fi
    rm -f "$tmp"
}

lb_reconcile_all() {
    lb_reconcile_links
    local units_changed=0 bar_changed=0 d
    for d in "${LB_CHANGED_DSTS[@]}"; do
        [[ "$d" == "$HOME/.config/systemd/user/"* ]] && units_changed=1
        [[ "$d" == "$HOME/.config/waybar/"* ]] && bar_changed=1
    done
    if [[ "${LB_CHECK_ONLY:-0}" != 1 ]]; then
        "$DOTFILES/local-bin/touch-mode" ensure >/dev/null 2>&1 || true
    fi
    lb_ensure_hypr_sources
    lb_reconcile_ssh_include
    lb_reconcile_units "$units_changed"
    lb_mako_refresh
    lb_reconcile_claude_hooks
    lb_reconcile_claude_statusline
    lb_check_system_files
    lb_check_keystroke_capture
    lb_check_docker_replies
    lb_check_monitor_chooser
    lb_check_hypr_errors
    [[ "${LB_WAYBAR_CHANGED:-0}" == 1 ]] && bar_changed=1
    lb_waybar_refresh "$bar_changed"
    return 0
}
