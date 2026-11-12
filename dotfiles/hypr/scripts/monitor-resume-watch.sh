#!/bin/bash
# Re-applies the monitor layout after a resume from suspend.
#
# Why this exists as its own watcher:
#
# A resume does NOT emit monitoradded/monitorremoved on hyprland's socket2, so
# monitor-persist.sh's event loop never sees it. Hyprland instead takes its
# "Restoring after VT switch" path; if the atomic modeset test for the native
# mode fails there, it silently falls back to a lower mode and never retries.
# On 2026-08-07 that dropped the external from 2560x1440 to 1920x1080, and the
# next persist froze the downgrade into monitors.conf.
#
# systemd's USER manager has no sleep.target / suspend.target (checked on
# systemd 260 — `systemctl --user list-units | grep sleep` is empty), so a user
# unit cannot be WantedBy=suspend.target. logind's PrepareForSleep signal on the
# system bus is the supported hook and needs no root.
#
# Cost: gdbus blocks on the bus. No polling, no timer, ~0% CPU when idle.

PERSIST="$HOME/.config/hypr/scripts/monitor-persist.sh"
# Let DRM finish rescanning connectors before we touch modes.
SETTLE_SECONDS=3

[[ -x "$PERSIST" ]] || { echo "monitor-persist.sh not found at $PERSIST" >&2; exit 1; }

# PrepareForSleep(true)  = going to sleep
# PrepareForSleep(false) = resumed
gdbus monitor --system \
      --dest org.freedesktop.login1 \
      --object-path /org/freedesktop/login1 2>/dev/null \
| while IFS= read -r line; do
    case "$line" in
        *PrepareForSleep*false*)
            echo "Resume detected; re-applying monitor layout in ${SETTLE_SECONDS}s"
            sleep "$SETTLE_SECONDS"
            "$PERSIST" --once
            ;;
    esac
done
