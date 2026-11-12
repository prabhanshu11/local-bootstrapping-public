#!/bin/bash
# Watches for monitor changes and reapplies the preferred laptop/external layout.
#
# Two entry points:
#   monitor-persist.sh          long-lived; applies once, then listens on
#                               hyprland's socket2 for monitoradded/removed
#   monitor-persist.sh --once   apply once and exit (used by the resume unit)
#
# Why --once exists: a resume from suspend does NOT emit monitoradded or
# monitorremoved. Hyprland takes its "Restoring after VT switch" path, and if
# the atomic modeset test for the native mode fails it silently falls back to a
# lower mode and never retries. The socket listener never sees it, so the
# resume unit calls us directly. (2026-08-07)
#
# Event-loop guards (2026-10-11, after 2026-10-07 22:43-22:47): the hub's DP
# link dropped ~1.5 s after every modeset and we re-applied within 0.5 s of
# each event — a 3.5 s modeset loop for 8 cycles, plus a waybar SIGUSR2 reload
# on every pass (30 in four minutes; waybar crashed). Now:
#   - events arriving within SETTLE_SECS of our own apply are ignored (our
#     retrain's disable/enable and the hub's reaction to our modeset), with a
#     re-check once the window closes so a genuine unplug is still handled;
#   - an event-driven apply is skipped when nothing changed ("unchanged,
#     skipping");
#   - waybar is reloaded only when the active monitor geometry changed or
#     waybar is not running (state shared with --once via XDG_RUNTIME_DIR);
#   - flap guard: FLAP_COUNT removals within FLAP_WINDOW s stop all
#     re-modesetting for FLAP_BACKOFF s, with one log line + one notification.

LAPTOP_MONITOR="eDP-1"
SCREEN_FLIP="$HOME/.local/bin/screen-flip"
LAPTOP_MODE="1920x1080@60.01"
LAPTOP_WIDTH=1920
LAPTOP_HEIGHT=1080
# Only a last-resort fallback: the real mode is read from availableModes.
FALLBACK_EXTERNAL_MODE="preferred"
SIDE_FILE="$HOME/.config/hypr/monitor-side"
LOG_FILE="$HOME/.config/hypr/monitor-persist.log"
LOG_MAX_BYTES=$((256 * 1024))
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
GEOMETRY_FILE="$STATE_DIR/monitor-persist.geometry"
# Env overrides exist for the test harness only.
SETTLE_SECS=${MONITOR_PERSIST_SETTLE_SECS:-6}
FLAP_COUNT=3
FLAP_WINDOW=${MONITOR_PERSIST_FLAP_WINDOW:-60}
FLAP_BACKOFF=${MONITOR_PERSIST_FLAP_BACKOFF:-90}
FLAP_RENOTIFY=600
PRE_GEO=""            # geometry before the current apply (reload baseline)

# Event-loop state (long-lived mode only).
LAST_EXT="(none)"     # external name at the last apply; "" = laptop-only
APPLIED=0             # 1 if the last apply_monitor_config call changed things
SELF_REMOVALS=0       # monitorremoved events our own last apply generated
IGNORE_UNTIL=0
RECHECK_AT=0
BACKOFF_UNTIL=0
LAST_FLAP_NOTIFY=0
REMOVALS=()

log() {
    # Keep the log bounded — this process is long-lived and fires on every
    # hotplug; an unbounded file in $HOME would grow forever.
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > LOG_MAX_BYTES )); then
        tail -c $((LOG_MAX_BYTES / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null \
            && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Re-applying the monitor layout above always resets eDP-1's `transform` to
# unset (0) since none of the `hyprctl keyword monitor ...` calls carry a
# transform field, but it never touches the touchscreen's transform — leaving
# the two out of sync whenever screen-flip has the panel rotated. Re-assert
# whatever screen-flip has persisted so display and touch stay matched after
# every hotplug/resume (2026-09-22).
resync_screen_flip() {
    [[ -x "$SCREEN_FLIP" ]] && "$SCREEN_FLIP" apply
}

# In-process reload: a cold waybar restart leaves layer surfaces anchored at the
# old coordinates when monitors move (see docs/issues/layer-surfaces-stale-after
# -monitor-move.md, commit 277e138). Only start waybar cold if it isn't running.
# Zombies count as "not running": waybar's own reaped-late children show up
# as [waybar] <defunct> and a bare `pgrep -x waybar` matches them.
waybar_running() { pgrep -x -r R,S,D,T waybar >/dev/null 2>&1; }

reload_waybar() {
    if waybar_running; then
        pkill -SIGUSR2 -x waybar 2>/dev/null || true
    else
        hyprctl dispatch exec waybar >/dev/null 2>&1 || { waybar >/dev/null 2>&1 & disown; }
    fi
}

# Signature of the active outputs' geometry. A reload is needed when outputs
# appear, disappear or move (layer surfaces stay where they were, see above);
# an identical re-apply must never reload (2026-10-07: 30 reloads in four
# minutes during a hub flap preceded a waybar crash).
monitor_geometry() {
    hyprctl monitors -j 2>/dev/null | jq -r \
        '[.[] | select(.disabled | not) | "\(.name):\(.x),\(.y):\(.width)x\(.height)"] | sort | join(" ")'
}

reload_waybar_if_needed() {
    local now_geo old_geo
    now_geo=$(monitor_geometry)
    # Baseline: what the last apply recorded (catches hotplugs in between);
    # with no record yet (first start after login/deploy), the geometry from
    # just before this apply.
    old_geo=$(cat "$GEOMETRY_FILE" 2>/dev/null) || old_geo=$PRE_GEO
    if ! waybar_running; then
        log "waybar not running; starting it"
        reload_waybar
    elif [[ "$now_geo" != "$old_geo" ]]; then
        log "Monitor geometry changed ($old_geo -> $now_geo); reloading waybar"
        reload_waybar
    fi
    printf '%s\n' "$now_geo" > "$GEOMETRY_FILE"
}

saved_side() {
    local side
    side=$(sed -n '1p' "$SIDE_FILE" 2>/dev/null)
    case "$side" in
        external-left|external-right|mirror|ignore) printf '%s\n' "$side" ;;
        *) printf 'external-left\n' ;;
    esac
}

# The connector name is NOT stable: this panel has come up as both DP-1 and
# DP-2 across replugs, which is why the old hardcoded `== "DP-1"` test silently
# stopped matching. Trust the saved name only if it still exists, else detect
# whatever isn't the laptop.
saved_external_monitor() {
    local saved detected
    saved=$(sed -n '2p' "$SIDE_FILE" 2>/dev/null)
    if [[ -n "$saved" ]] && hyprctl monitors all -j 2>/dev/null | jq -e --arg mon "$saved" '.[] | select(.name == $mon)' >/dev/null; then
        printf '%s\n' "$saved"
        return
    fi

    detected=$(hyprctl monitors all -j 2>/dev/null | jq -r --arg laptop "$LAPTOP_MONITOR" '.[] | select(.name != $laptop) | .name' | head -1)
    printf '%s\n' "$detected"
}

monitor_field() {
    local mon="$1" field="$2"
    hyprctl monitors all -j 2>/dev/null \
        | jq -r --arg mon "$mon" --arg field "$field" '.[] | select(.name == $mon) | .[$field]' \
        | head -1
}

# hyprland orders availableModes best-first. Never hardcode a mode string here:
# the old EXTERNAL_MODE="2560x1440@60.00" was not even a real mode on this panel
# (it reports 59.95 and 99.95), so it could only ever have failed.
best_mode() {
    local mon="$1"
    hyprctl monitors all -j 2>/dev/null \
        | jq -r --arg mon "$mon" '.[] | select(.name == $mon) | .availableModes[0] // empty' \
        | head -1 | sed 's/Hz$//'
}

# Always WxH@RR.RR with two decimals, the same shape as availableModes /
# LAPTOP_MODE. jq printed 60.0 as "60", so "1920x1080@60" never equalled
# "1920x1080@60.00": every event-driven apply re-modeset the external output,
# retrained its link twice, generated four more monitor events, re-checked
# after the settle window and did it all again — a 12 s off/on loop that
# crashed ghostty (SIGSEGV in GTK's Wayland dispatch) and waybar 127 times
# on 2026-10-18.
current_mode() {
    local mon="$1"
    hyprctl monitors all -j 2>/dev/null | jq -r --arg mon "$mon" \
        '.[] | select(.name == $mon and .width > 0) |
         "\(.width)x\(.height)@\(.refreshRate)"' | head -1 \
        | awk -F'@' 'NF == 2 { printf "%s@%.2f\n", $1, $2 }'
}

# True when two WxH@RR strings name the same mode: equal size, refresh within
# 0.05 Hz (hyprland reports 60.008 for a 60.01 mode, 59.94 for 59.94).
mode_equal() {
    local a="$1" b="$2"
    [[ "${a%%@*}" == "${b%%@*}" ]] || return 1
    awk -v x="${a#*@}" -v y="${b#*@}" 'BEGIN { d = x - y; if (d < 0) d = -d; exit !(d < 0.05) }'
}

mode_width()  { local m="$1"; printf '%s' "${m%%x*}"; }
mode_height() { local m="$1"; m="${m#*x}"; printf '%s' "${m%%@*}"; }

validate_display_and_topbar() {
    local active_count
    active_count=$(hyprctl monitors all -j 2>/dev/null | jq '[.[] | select(.disabled == false and .width > 0 and .height > 0)] | length' 2>/dev/null)

    if [[ -z "$active_count" || "$active_count" -lt 1 ]]; then
        return 1
    fi

    if ! waybar_running; then
        reload_waybar
        sleep 0.8
    fi

    waybar_running
}

reset_safe_display() {
    log "Safety validation failed; resetting to laptop-only layout"
    hyprctl keyword monitor "$LAPTOP_MONITOR,$LAPTOP_MODE,0x0,1.00"
    reload_waybar_if_needed
}

# Apply the requested mode, then CHECK it actually took. A failed atomic modeset
# test leaves hyprland on a lower mode with no error surfaced to us. Toggling the
# output off and on forces a DP link retrain — the software equivalent of the
# cable replug that is known to fix it.
apply_external_mode_with_retrain() {
    local mon="$1" mode="$2" pos="$3" attempt live
    for attempt in 1 2 3; do
        if (( attempt > 1 )); then
            log "$mon: mode is $live, wanted $mode — retraining link (attempt $attempt)"
            hyprctl keyword monitor "$mon,disabled" >/dev/null 2>&1
            SELF_REMOVALS=$((SELF_REMOVALS + 1))
            sleep 1
        fi
        hyprctl keyword monitor "$mon,$mode,$pos,1.00" >/dev/null 2>&1
        sleep 1
        live=$(current_mode "$mon")
        mode_equal "$live" "$mode" && return 0
    done
    log "$mon: WARNING gave up after 3 attempts; live mode is $live, wanted $mode"
    return 1
}

# Sets EXT_MON SIDE EXT_MODE EXT_W EXT_H LAPTOP_Y for the current hardware.
compute_layout() {
    EXT_MON=$(saved_external_monitor)
    SIDE=$(saved_side)
    EXT_MODE="" EXT_W="" EXT_H="" LAPTOP_Y=0
    [[ -n "$EXT_MON" ]] || return 0

    EXT_MODE=$(best_mode "$EXT_MON")
    [[ -n "$EXT_MODE" ]] || EXT_MODE="$FALLBACK_EXTERNAL_MODE"

    # Geometry derived from the mode being applied, never read separately —
    # mixing the two is how a 1080p mode ended up beside offsets computed for
    # 1440p, leaving a 640px dead gap (2026-08-07).
    if [[ "$EXT_MODE" == "preferred" ]]; then
        EXT_W=$(monitor_field "$EXT_MON" width)
        EXT_H=$(monitor_field "$EXT_MON" height)
    else
        EXT_W=$(mode_width "$EXT_MODE")
        EXT_H=$(mode_height "$EXT_MODE")
    fi
    [[ "$EXT_W" =~ ^[0-9]+$ && "$EXT_W" -gt 0 ]] || EXT_W=$LAPTOP_WIDTH
    [[ "$EXT_H" =~ ^[0-9]+$ && "$EXT_H" -gt 0 ]] || EXT_H=$LAPTOP_HEIGHT

    if (( EXT_H > LAPTOP_HEIGHT )); then
        LAPTOP_Y=$(( (EXT_H - LAPTOP_HEIGHT) / 2 ))
    fi
}

monitor_pos() {
    hyprctl monitors all -j 2>/dev/null | jq -r --arg mon "$1" \
        '.[] | select(.name == $mon) | "\(.x)x\(.y)"' | head -1
}

# True when the live state already is what an apply would produce, for the
# same external connector as the last apply. Call after compute_layout.
layout_unchanged() {
    [[ "$LAST_EXT" != "(none)" && "$EXT_MON" == "$LAST_EXT" ]] || return 1
    if [[ -z "$EXT_MON" ]]; then
        [[ "$(monitor_pos "$LAPTOP_MONITOR")" == "0x0" ]]
        return
    fi
    case "$SIDE" in
        external-left)
            mode_equal "$(current_mode "$EXT_MON")" "$EXT_MODE" \
               && [[ "$(monitor_pos "$EXT_MON")" == "0x0" \
               && "$(monitor_pos "$LAPTOP_MONITOR")" == "${EXT_W}x${LAPTOP_Y}" ]] ;;
        external-right)
            mode_equal "$(current_mode "$EXT_MON")" "$EXT_MODE" \
               && [[ "$(monitor_pos "$EXT_MON")" == "${LAPTOP_WIDTH}x0" \
               && "$(monitor_pos "$LAPTOP_MONITOR")" == "0x${LAPTOP_Y}" ]] ;;
        mirror)
            [[ "$(monitor_field "$EXT_MON" mirrorOf)" =~ ^(eDP-1|$LAPTOP_MONITOR|0)$ \
               && "$(monitor_pos "$LAPTOP_MONITOR")" == "0x0" ]] ;;
        ignore)
            [[ "$(monitor_field "$EXT_MON" disabled)" == "true" \
               && "$(monitor_pos "$LAPTOP_MONITOR")" == "0x0" ]] ;;
        *) return 1 ;;
    esac
}

# apply_monitor_config [--if-changed]
# --if-changed (event-driven calls): do nothing when layout_unchanged.
# Startup and --once always apply, so the resume mode-fallback fix stays.
apply_monitor_config() {
    APPLIED=0
    SELF_REMOVALS=0
    compute_layout

    if [[ "${1:-}" == "--if-changed" ]] && layout_unchanged; then
        log "unchanged, skipping (${EXT_MON:-laptop-only}, $SIDE)"
        return 0
    fi

    APPLIED=1
    LAST_EXT="$EXT_MON"
    PRE_GEO=$(monitor_geometry)
    log "Applying monitor configuration..."

    if [[ -z "$EXT_MON" ]]; then
        log "External monitor not detected, applying laptop-only setup"
        hyprctl keyword monitor "$LAPTOP_MONITOR,$LAPTOP_MODE,0x0,1.00"
        reload_waybar_if_needed
        resync_screen_flip
        return
    fi

    log "External monitor: $EXT_MON; layout: $SIDE; target mode: $EXT_MODE"

    case "$SIDE" in
        external-left)
            apply_external_mode_with_retrain "$EXT_MON" "$EXT_MODE" "0x0"
            hyprctl keyword monitor "$LAPTOP_MONITOR,$LAPTOP_MODE,${EXT_W}x${LAPTOP_Y},1.00" >/dev/null 2>&1
            ;;
        external-right)
            apply_external_mode_with_retrain "$EXT_MON" "$EXT_MODE" "${LAPTOP_WIDTH}x0"
            hyprctl keyword monitor "$LAPTOP_MONITOR,$LAPTOP_MODE,0x${LAPTOP_Y},1.00" >/dev/null 2>&1
            ;;
        mirror)
            hyprctl --batch "keyword monitor $LAPTOP_MONITOR,$LAPTOP_MODE,0x0,1.00 ; keyword monitor $EXT_MON,preferred,auto,1,mirror,$LAPTOP_MONITOR" >/dev/null 2>&1
            ;;
        ignore)
            [[ "$(monitor_field "$EXT_MON" disabled)" == "true" ]] || SELF_REMOVALS=$((SELF_REMOVALS + 1))
            hyprctl --batch "keyword monitor $LAPTOP_MONITOR,$LAPTOP_MODE,0x0,1.00 ; keyword monitor $EXT_MON,disabled" >/dev/null 2>&1
            ;;
    esac

    sleep 1
    reload_waybar_if_needed
    validate_display_and_topbar || reset_safe_display
    resync_screen_flip
    log "Configuration applied: $EXT_MON=$(current_mode "$EXT_MON") $LAPTOP_MONITOR=$(current_mode "$LAPTOP_MONITOR")"
}

if [[ "${1:-}" == "--once" ]]; then
    log "=== Apply once (resume/manual) ==="
    apply_monitor_config
    exit 0
fi

# Run an event-driven apply and open the settle window if it changed things.
apply_from_event() {
    apply_monitor_config --if-changed
    if (( APPLIED )); then
        IGNORE_UNTIL=$(( EPOCHSECONDS + SETTLE_SECS ))
    fi
}

# Flap guard bookkeeping for one monitorremoved of the external display.
note_removal() {
    local now=$EPOCHSECONDS t kept=()
    for t in "${REMOVALS[@]}"; do
        (( now - t < FLAP_WINDOW )) && kept+=("$t")
    done
    kept+=("$now")
    REMOVALS=("${kept[@]}")

    if (( ${#REMOVALS[@]} >= FLAP_COUNT && now >= BACKOFF_UNTIL )); then
        BACKOFF_UNTIL=$(( now + FLAP_BACKOFF ))
        log "Flap guard: external removed ${#REMOVALS[@]} times in ${FLAP_WINDOW}s; not re-modesetting it for ${FLAP_BACKOFF}s"
        if (( now - LAST_FLAP_NOTIFY >= FLAP_RENOTIFY )); then
            LAST_FLAP_NOTIFY=$now
            notify-send -u critical -a monitor-persist "External display" \
                "External display link is flapping — check the hub/cable" >/dev/null 2>&1 || true
        fi
    fi
}

handle_event() {
    local line="$1" event data now
    event=${line%%>>*}
    data=${line#*>>}
    case "$event" in
        monitoradded | monitorremoved) ;;
        *) return 0 ;;
    esac
    now=$EPOCHSECONDS

    if [[ "$event" == monitorremoved && "$data" != "$LAPTOP_MONITOR" ]]; then
        if (( now < IGNORE_UNTIL && SELF_REMOVALS > 0 )); then
            SELF_REMOVALS=$((SELF_REMOVALS - 1))   # our own retrain/disable
        else
            note_removal
        fi
    fi

    if (( now < BACKOFF_UNTIL )); then
        log "Flap back-off ($(( BACKOFF_UNTIL - now ))s left): ignoring $line"
        RECHECK_AT=$BACKOFF_UNTIL
        return 0
    fi
    if (( now < IGNORE_UNTIL )); then
        log "Settling after own apply: ignoring $line"
        RECHECK_AT=$IGNORE_UNTIL
        return 0
    fi

    log "Monitor event detected: $line"
    sleep 0.5
    apply_from_event
}

# Called at least once a second: end the back-off, run deferred re-checks.
handle_timers() {
    local now=$EPOCHSECONDS
    if (( BACKOFF_UNTIL > 0 && now >= BACKOFF_UNTIL )); then
        log "Flap back-off over; resuming normal handling"
        BACKOFF_UNTIL=0
        REMOVALS=()
        RECHECK_AT=$now
    fi
    if (( RECHECK_AT > 0 && now >= RECHECK_AT && now >= IGNORE_UNTIL && BACKOFF_UNTIL == 0 )); then
        RECHECK_AT=0
        log "Re-checking layout after ignored events"
        apply_from_event
    fi
}

log "=== Monitor Persistence Script Started ==="
apply_monitor_config
IGNORE_UNTIL=$(( EPOCHSECONDS + SETTLE_SECS ))

HYPRLAND_SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

if [[ ! -S "$HYPRLAND_SOCKET" ]]; then
    log "ERROR: Hyprland socket not found at $HYPRLAND_SOCKET"
    exit 1
fi

log "Listening for monitor events on $HYPRLAND_SOCKET"

# A unix socket needs connect(2); bash's `exec 3<> "$sock"` is open(2) and fails
# with ENXIO ("No such device or address") on every attempt. From 2026-08-07 to
# 2026-10-04 this loop logged "Cannot connect" every 5 s and never saw a single
# hotplug, so the layout was only ever applied at start and on resume. Found
# when a replug after resume left eDP-1 and DP-2 both at 0x0 (two pointers, the
# external screen unclickable). OpenBSD nc -U is the connect(2) we need.
while true; do
    if [[ ! -S "$HYPRLAND_SOCKET" ]]; then
        log "ERROR: Hyprland socket gone: $HYPRLAND_SOCKET"
        sleep 5
        continue
    fi

    # read -t 1 so timers (settle re-check, back-off end) fire without events.
    # A timed-out read keeps any partial line, so carry it over.
    partial=""
    while true; do
        if IFS= read -r -t 1 chunk; then
            handle_event "$partial$chunk"
            partial=""
        else
            rc=$?
            (( rc > 128 )) || break          # EOF: nc exited
            partial+="$chunk"
        fi
        handle_timers
    done < <(nc -U "$HYPRLAND_SOCKET" 2>/dev/null)

    log "Socket stream ended; reconnecting"
    sleep 1
done
