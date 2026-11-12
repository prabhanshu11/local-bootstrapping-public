#!/bin/bash
# install.sh - Bootstrap a new machine with synced configurations
#
# Run this on a fresh Omarchy install to fully restore your environment.
# Handles device-specific differences between desktop/laptop.
#
# Usage:
#   ./install.sh              # Full interactive setup
#   ./install.sh --minimal    # Skip optional components
#   ./install.sh --device laptop  # Force device type
#   ./install.sh --reconcile  # No-sudo self-heal only (links, units, checks);
#                             # what sync-from-master.sh runs every 10 minutes
#   ./install.sh --reconcile --check   # Report what it would change, change nothing
#   Extra: --report FILE (append unresolved drift), --quiet, --root DIR (repo to
#   link to; tests/verification), see scripts/lib/reconcile.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }

HOSTNAME=$(hostname)
DOTFILES="$REPO_ROOT/dotfiles"
MINIMAL=false
FORCE_DEVICE=""
RECONCILE_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --minimal) MINIMAL=true; shift ;;
        --device) FORCE_DEVICE="$2"; shift 2 ;;
        --reconcile) RECONCILE_ONLY=true; shift ;;
        --check) export LB_CHECK_ONLY=1; shift ;;
        --quiet) export LB_QUIET=1; shift ;;
        --report) export LB_REPORT="$2"; shift 2 ;;
        --root) REPO_ROOT="$(cd "$2" && pwd)"; DOTFILES="$REPO_ROOT/dotfiles"; shift 2 ;;
        *) shift ;;
    esac
done

# Shared reconcile implementation (links, units, no-sudo checks) — also what
# the 10-minute sync runs via --reconcile. See the header of that file.
# shellcheck source=lib/reconcile.sh
source "$SCRIPT_DIR/lib/reconcile.sh"

# Files/dirs to symlink from dotfiles/
SYMLINKS=(
    "waybar/config.jsonc:$HOME/.config/waybar/config.jsonc"
    "waybar/style.css:$HOME/.config/waybar/style.css"
    # VDI bar icon: a photo of the Moon (style.css url("icons/moon-*.png"); make-moon-icon.py regenerates)
    "waybar/icons:$HOME/.config/waybar/icons"
    # Touch mode toggle (hand icon, one inch right of workspace "1"): taller bar
    # + big icons. Owns ~/.config/waybar/touch-mode.jsonc; see the script header.
    "local-bin/touch-mode:$HOME/.local/bin/touch-mode"
    # bar-touch: every bar module's click goes through it (tap popup, long-press
    # card) and it owns mouse mode (the hand icon). See docs/touch-bar.md.
    "local-bin/bar-touch:$HOME/.local/bin/bar-touch"
    # battery-info: the battery icon, its tooltip and the bar-touch battery panel
    "local-bin/battery-info:$HOME/.local/bin/battery-info"
    # dicons-keepalive: the desktop icons layer (dicons), started again after a crash
    "local-bin/dicons-keepalive:$HOME/.local/bin/dicons-keepalive"
    # keystroke-bar: the keyboard icon (custom/keystroke), its health colour, and
    # the fingerprint-gated raw log viewer. See configs/keystroke-log/README.md.
    "local-bin/keystroke-bar:$HOME/.local/bin/keystroke-bar"
    "systemd-user/bar-touch.service:$HOME/.config/systemd/user/bar-touch.service"
    # workspace-labels: a label per workspace (hidden ones captured with grim -T),
    # popup under the bar on switch. docs/workspace-labels/REPORT.md
    "local-bin/workspace-labels:$HOME/.local/bin/workspace-labels"
    "systemd-user/workspace-labels.service:$HOME/.config/systemd/user/workspace-labels.service"
    # Bar clock (custom/clock): calendar + zone table with "DST on/off" per zone
    "local-bin/waybar-clock:$HOME/.local/bin/waybar-clock"
    # monitor-chooser waybar widget backend (the binary is built by setup_monitor_chooser)
    "local-bin/monitor-chooser-status:$HOME/.local/bin/monitor-chooser-status"
    "ghostty/config:$HOME/.config/ghostty/config"
    # mpv: HW-accelerated decode + arrow-key bindings (seek ±5s, volume ±5, v=cycle sub)
    "mpv/mpv.conf:$HOME/.config/mpv/mpv.conf"
    "mpv/input.conf:$HOME/.config/mpv/input.conf"
    # mpv watch history (custom/mpv-history bar icon + bar-touch panel), docs/mpv-history.md
    "mpv/scripts/mpv-history.lua:$HOME/.config/mpv/scripts/mpv-history.lua"
    "local-bin/mpv-history:$HOME/.local/bin/mpv-history"
    # any MPRIS player (VLC, browsers, ...) into the same history, docs/mpv-history.md
    "local-bin/media-history-recorder:$HOME/.local/bin/media-history-recorder"
    "systemd-user/media-history-recorder.service:$HOME/.config/systemd/user/media-history-recorder.service"
    "bashrc.d:$HOME/.config/bashrc.d"
    "codex/config.toml:$HOME/.codex/config.toml"
    "hypr/monitors.conf:$HOME/.config/hypr/monitors.conf"
    "hypr/monitor-side:$HOME/.config/hypr/monitor-side"
    "hypr/input.conf:$HOME/.config/hypr/input.conf"
    "hypr/bindings-voice.conf:$HOME/.config/hypr/bindings-voice.conf"
    "hypr/bindings-streaming.conf:$HOME/.config/hypr/bindings-streaming.conf"
    # Screenshot keys -> screenshot-save; saves to ~/Pictures/screenshots (2026-11-06)
    "hypr/bindings-screenshot.conf:$HOME/.config/hypr/bindings-screenshot.conf"
    "local-bin/screenshot-save:$HOME/.local/bin/screenshot-save"
    "hypr/bindings-special-keys.conf:$HOME/.config/hypr/bindings-special-keys.conf"
    # Virtual desktops spanning both monitors (binds + sync daemon)
    "hypr/bindings-workspace-pairs.conf:$HOME/.config/hypr/bindings-workspace-pairs.conf"
    "local-bin/workspace-pair:$HOME/.local/bin/workspace-pair"
    "local-bin/workspace-pairs-daemon:$HOME/.local/bin/workspace-pairs-daemon"
    "systemd-user/workspace-pairs.service:$HOME/.config/systemd/user/workspace-pairs.service"
    # Super+W closes in reverse opening order (see dotfiles/hypr/bindings-close-ordered.conf)
    "hypr/bindings-close-ordered.conf:$HOME/.config/hypr/bindings-close-ordered.conf"
    "local-bin/hypr-close-ordered:$HOME/.local/bin/hypr-close-ordered"
    # Ctrl+Alt+Delete closed every window on 2026-10-26; unbind + delete the script + watch for
    # its return. See docs/issues/ctrl-alt-delete-closed-all-windows-2026-10-26.md
    "hypr/bindings-no-close-all.conf:$HOME/.config/hypr/bindings-no-close-all.conf"
    "local-bin/close-all-guard:$HOME/.local/bin/close-all-guard"
    "systemd-user/close-all-guard.service:$HOME/.config/systemd/user/close-all-guard.service"
    "systemd-user/close-all-guard.path:$HOME/.config/systemd/user/close-all-guard.path"
    "systemd-user/close-all-guard.timer:$HOME/.config/systemd/user/close-all-guard.timer"
    # Windows-style MRU Alt+Tab (see dotfiles/hypr/bindings-alt-tab.conf)
    "hypr/bindings-alt-tab.conf:$HOME/.config/hypr/bindings-alt-tab.conf"
    "local-bin/hypr-alt-tab:$HOME/.local/bin/hypr-alt-tab"
    "local-bin/clipboard-health:$HOME/.local/bin/clipboard-health"
    "local-bin/system-health:$HOME/.local/bin/system-health"
    "local-bin/hyprwhspr-tray.sh:$HOME/.local/bin/hyprwhspr-tray.sh"
    "local-bin/streaming-health:$HOME/.local/bin/streaming-health"
    "local-bin/moonlight-toggle:$HOME/.local/bin/moonlight-toggle"
    # VDI UI (docs/vdi.md): the intro screen (vdi home) + the control bar over the stream (vdi bar)
    "local-bin/vdi:$HOME/.local/bin/vdi"
    # VDI (docs/vdi.md): desktop state + Sunshine knobs (desktop side)
    "local-bin/vdi-state:$HOME/.local/bin/vdi-state"
    "local-bin/vdi-knob:$HOME/.local/bin/vdi-knob"
    # Windows VMs (desktop: vdi-vm; laptop: vdi-rdp opens the VM in its own RDP window). docs/vdi.md
    # (desktop root, not a symlink: Samba drives H:/X:/P: for the VMs = scripts/vdi/desktop-vm-smb-root.sh, docs/vdi.md Round 6)
    "local-bin/vdi-vm:$HOME/.local/bin/vdi-vm"
    "local-bin/vdi-rdp:$HOME/.local/bin/vdi-rdp"
    "local-bin/vdi-keys:$HOME/.local/bin/vdi-keys"
    "local-bin/vdi-win:$HOME/.local/bin/vdi-win"
    "local-bin/moonlight-broadcast:$HOME/.local/bin/moonlight-broadcast"
    "local-bin/streaming-mode:$HOME/.local/bin/streaming-mode"
    "local-bin/omarchy-windows-vm:$HOME/.local/bin/omarchy-windows-vm"
    # kiosk: drive the Star Trek computer wall from any terminal (`kiosk finance 2`, `kiosk home`, `kiosk status`);
    # POSTs the wall's "show" signal (star-trek-camera wall/CLAUDE.md). /usr/bin/wall exists, hence the name.
    "local-bin/kiosk:$HOME/.local/bin/kiosk"
    # Pi NAS connector with auto WiFi switching
    "local-bin/pi-nas:$HOME/.local/bin/pi-nas"
    # Active window border contrast fix
    "local-bin/fix-active-border:$HOME/.local/bin/fix-active-border"
    "hypr/autostart-border-fix.conf:$HOME/.config/hypr/autostart-border-fix.conf"
    # Physical power button: suspend when locked, otherwise show system menu
    "local-bin/power-button-action:$HOME/.local/bin/power-button-action"
    # Sudo notifications for Claude Code automation
    "local-bin/sudo-notify:$HOME/.local/bin/sudo-notify"
    "local-bin/sudo-notify-hw-detect:$HOME/.local/bin/sudo-notify-hw-detect"
    "local-bin/sudo-popup-auth:$HOME/.local/bin/sudo-popup-auth"
    "local-bin/sudo-with-notify:$HOME/.local/bin/sudo-with-notify"
    "local-bin/sudo-with-notify-remote:$HOME/.local/bin/sudo-with-notify-remote"
    # Voice typing and layout tools
    "local-bin/hyprwhspr-toggle:$HOME/.local/bin/hyprwhspr-toggle"
    "local-bin/layout-detect:$HOME/.local/bin/layout-detect"
    "local-bin/layout-send:$HOME/.local/bin/layout-send"
    "local-bin/ydotool-layout:$HOME/.local/bin/ydotool-layout"
    # Claude memory monitoring
    "local-bin/claude-memory-monitor.sh:$HOME/.local/bin/claude-memory-monitor.sh"
    # Home-LAN dual Wi-Fi (laptop USB dongle on the C6 SSID; root half: scripts/net/setup-home-lan-dongle.sh)
    "local-bin/home-lan-dongle-watchdog:$HOME/.local/bin/home-lan-dongle-watchdog"
    "systemd-user/home-lan-dongle-watchdog.service:$HOME/.config/systemd/user/home-lan-dongle-watchdog.service"
    "systemd-user/home-lan-dongle-watchdog.timer:$HOME/.config/systemd/user/home-lan-dongle-watchdog.timer"
    "local-bin/internet-guard:$HOME/.local/bin/internet-guard"
    "systemd-user/internet-guard.service:$HOME/.config/systemd/user/internet-guard.service"
    "systemd-user/internet-guard.timer:$HOME/.config/systemd/user/internet-guard.timer"
    "systemd-user/clipboard-health.service:$HOME/.config/systemd/user/clipboard-health.service"
    "systemd-user/clipboard-health.timer:$HOME/.config/systemd/user/clipboard-health.timer"
    "systemd-user/local-bootstrapping-sync.service:$HOME/.config/systemd/user/local-bootstrapping-sync.service"
    "systemd-user/local-bootstrapping-sync.timer:$HOME/.config/systemd/user/local-bootstrapping-sync.timer"
    "systemd-user/sunshine-health.service:$HOME/.config/systemd/user/sunshine-health.service"
    "systemd-user/sunshine-health.timer:$HOME/.config/systemd/user/sunshine-health.timer"
    "systemd-user/moonlight-health.service:$HOME/.config/systemd/user/moonlight-health.service"
    "systemd-user/moonlight-health.timer:$HOME/.config/systemd/user/moonlight-health.timer"
    # wall-guard: keeps the desktop's HDMI-A-1 wall (Star Trek kiosk) unobscured,
    # mako do-not-disturb + comms.json for the wall. See docs/wall-guard.md.
    "local-bin/wall-guard:$HOME/.local/bin/wall-guard"
    "systemd-user/wall-guard.service:$HOME/.config/systemd/user/wall-guard.service"
    "systemd-user/wall-guard.timer:$HOME/.config/systemd/user/wall-guard.timer"
    # mako: includes the active theme's mako.ini (colours + Omarchy core.ini, so
    # do-not-disturb keeps working) and adds the Chrome 60 s rule (his "yes to
    # chrome rule", 2026-11-10: both machines). Omarchy's stock link to the theme
    # file is replaced (LB_STOCK_LINKS in lib/reconcile.sh); mako reloads.
    "mako/config:$HOME/.config/mako/config"
    # claude-tokens-export: Claude Code tokens per day for the habits view (both machines;
    # the laptop pushes its file to the desktop). See the script header.
    "local-bin/claude-tokens-export:$HOME/.local/bin/claude-tokens-export"
    "systemd-user/claude-tokens-export.service:$HOME/.config/systemd/user/claude-tokens-export.service"
    "systemd-user/claude-tokens-export.timer:$HOME/.config/systemd/user/claude-tokens-export.timer"
    "nvim/lua/plugins/autocomplete-ai.lua:$HOME/.config/nvim/lua/plugins/autocomplete-ai.lua"
    "hypr/windowrules-mic-osd.conf:$HOME/.config/hypr/windowrules-mic-osd.conf"
    "hypr/windowrules-browser.conf:$HOME/.config/hypr/windowrules-browser.conf"
    "hypr/layerrules-bar-touch.conf:$HOME/.config/hypr/layerrules-bar-touch.conf"
    "CLAUDE.md:$HOME/Programs/CLAUDE.md"
    ".claude/skills:$HOME/Programs/.claude/skills"
    # OOM-guard PreToolUse hook — warns/blocks agents on memory pressure
    ".claude/hooks/oom-guard.sh:$HOME/.claude/hooks/oom-guard.sh"
    # Subagent context guard — retire subagents at ~240k context (SubagentStop/PreToolUse/PostToolUse)
    ".claude/skills/token-usage/hooks/subagent-context-guard.py:$HOME/.claude/hooks/subagent-context-guard.py"
    ".claude/skills/token-usage/bin/token-usage:$HOME/.local/bin/token-usage"
    # Status line under the Claude Code input box: conversation id + live context bar for the
    # main agent and each running subagent (2026-11-12, docs/claude-statusline.md)
    ".claude/statusline/agent-context-bar.py:$HOME/.claude/statusline/agent-context-bar.py"
    # Sudo popup Stop hook - resumes agents after manual fallback auth
    ".claude/hooks/check-sudo-popup.sh:$HOME/.claude/hooks/check-sudo-popup.sh"
    ".claude/hooks/check-sudo-popup.sh:$HOME/Programs/.claude/hooks/check-sudo-popup.sh"
    # Memory index lint — PostToolUse hook + CLI keeping ~/.claude/projects/*/memory/MEMORY.md
    # inside the 25 KB / 200 lines Claude Code loads (2026-10-01, docs/memory-index-lint.md)
    ".claude/hooks/memory-index-lint.sh:$HOME/.claude/hooks/memory-index-lint.sh"
    ".claude/hooks/memory-index-lint.sh:$HOME/.local/bin/memory-index-lint"
    "local-bin/datalake-health:$HOME/.local/bin/datalake-health"
    # Conversation recall CLI tools (wrappers to datalake/bin/)
    "local-bin/find-conversations:$HOME/.local/bin/find-conversations"
    "local-bin/get-messages-from-current:$HOME/.local/bin/get-messages-from-current"
    "local-bin/get-recent-user-messages:$HOME/.local/bin/get-recent-user-messages"
    "systemd-user/datalake-web.service:$HOME/.config/systemd/user/datalake-web.service"
    "systemd-user/datalake-refresh.service:$HOME/.config/systemd/user/datalake-refresh.service"
    "systemd-user/datalake-refresh.timer:$HOME/.config/systemd/user/datalake-refresh.timer"
    # Nice=19 + idle IO so the refresh's 23 GB VACUUM INTO does not starve the star-trek-camera tracker (G6)
    "systemd-user/datalake-refresh.service.d/nice-idle.conf:$HOME/.config/systemd/user/datalake-refresh.service.d/nice-idle.conf"
    # Telegram Claude Bot
    "local-bin/telegram-bot-health:$HOME/.local/bin/telegram-bot-health"
    "local-bin/telegram-bot-failover:$HOME/.local/bin/telegram-bot-failover"
    "systemd-user/telegram-watcher.service:$HOME/.config/systemd/user/telegram-watcher.service"
    "systemd-user/telegram-failover.service:$HOME/.config/systemd/user/telegram-failover.service"
    "systemd-user/telegram-failover.timer:$HOME/.config/systemd/user/telegram-failover.timer"
    # Drift Detector (cross-machine uncommitted changes)
    "systemd/user/drift-detector.service:$HOME/.config/systemd/user/drift-detector.service"
    "systemd/user/drift-detector.timer:$HOME/.config/systemd/user/drift-detector.timer"
    # WirePlumber: Prevent BT speaker monitor from becoming default source
    "wireplumber/wireplumber.conf.d/50-alsa-profile-thinkpad.conf:$HOME/.config/wireplumber/wireplumber.conf.d/50-alsa-profile-thinkpad.conf"
    "wireplumber/wireplumber.conf.d/51-disable-bt-speaker-monitor.conf:$HOME/.config/wireplumber/wireplumber.conf.d/51-disable-bt-speaker-monitor.conf"
    # XDG default apps: file:// clicks route media→Chrome, text/unknown→nvim, dirs→thunar
    "xdg/mimeapps.list:$HOME/.config/mimeapps.list"
    # GTK sidebar bookmarks (Thunar): external drives on desktop + Pi5 via LAN sftp
    "gtk-3.0/bookmarks:$HOME/.config/gtk-3.0/bookmarks"
    # One ssh name per home machine (pi5/nas, desktop-auto), channel in his order
    # LAN -> VPS relay -> Tailscale; ~/.ssh/config Includes it (setup-ssh.sh).
    # docs/network-and-nas.md §"One name per home machine"
    "ssh/home-routes.conf:$HOME/.ssh/home-routes.conf"
    "local-bin/home-route:$HOME/.local/bin/home-route"
    # Wallpaper slideshow
    "local-bin/wallpaper-rotate:$HOME/.local/bin/wallpaper-rotate"
    "systemd-user/wallpaper-rotate.service:$HOME/.config/systemd/user/wallpaper-rotate.service"
    "systemd-user/wallpaper-rotate.timer:$HOME/.config/systemd/user/wallpaper-rotate.timer"
    # SwayOSD server supervisor — auto-restart on GTK4/Wayland segfault (see the .service header)
    "systemd-user/swayosd-server.service:$HOME/.config/systemd/user/swayosd-server.service"
    # SwayOSD health check — the supervisor above only catches a DEAD process; this
    # catches an alive-but-deaf one that dropped its D-Bus name (volume keys + waybar
    # scroll silently no-op). See the swayosd-health script header.
    "local-bin/swayosd-health:$HOME/.local/bin/swayosd-health"
    "systemd-user/swayosd-health.service:$HOME/.config/systemd/user/swayosd-health.service"
    "systemd-user/swayosd-health.timer:$HOME/.config/systemd/user/swayosd-health.timer"
    # Claude Remote Control server — phone-initiated Claude Code sessions.
    # Supervised because the CLI exits permanently after 10 min of network
    # errors. See docs/issues/remote-control-dies-on-network-outage.md
    "local-bin/claude-rc-server:$HOME/.local/bin/claude-rc-server"
    "systemd-user/claude-remote-control.service:$HOME/.config/systemd/user/claude-remote-control.service"
    # Power profile auto-switching
    "local-bin/power-profile-monitor:$HOME/.local/bin/power-profile-monitor"
    "systemd-user/power-profile-monitor.service:$HOME/.config/systemd/user/power-profile-monitor.service"
    "systemd-user/power-profile-monitor.timer:$HOME/.config/systemd/user/power-profile-monitor.timer"
    # CPU clamp watchdog — the profile above can read BAL/PRF while the platform
    # pins the CPU to ~0.5 GHz. Logs telemetry every 60s and bounces the profile
    # to release it. See docs/issues/cpu-clamp-watchdog.md
    "systemd-user/power-profile-watchdog.service:$HOME/.config/systemd/user/power-profile-watchdog.service"
    "systemd-user/power-profile-watchdog.timer:$HOME/.config/systemd/user/power-profile-watchdog.timer"
    # The bar button, resident in RAM (2026-11-01): the tap never touches btrfs.
    # Both machines (the desktop shares config.jsonc). See
    # docs/issues/power-button-ram-resident-risk-analysis.md
    "local-bin/power-profile-daemon:$HOME/.local/bin/power-profile-daemon"
    "local-bin/bar-touch-click:$HOME/.local/bin/bar-touch-click"
    "systemd-user/power-profile-daemon.service:$HOME/.config/systemd/user/power-profile-daemon.service"
    # Week-long low-impact disk/commit health log + one-off review agent (2026-11-01, docs/issues/btrfs-commit-stall/)
    "local-bin/disk-health-logger:$HOME/.local/bin/disk-health-logger"
    "local-bin/disk-health-review:$HOME/.local/bin/disk-health-review"
    "systemd-user/disk-health-logger.service:$HOME/.config/systemd/user/disk-health-logger.service"
    "systemd-user/disk-health-review.service:$HOME/.config/systemd/user/disk-health-review.service"
    "systemd-user/disk-health-review.timer:$HOME/.config/systemd/user/disk-health-review.timer"
    # Desktop root SSD upkeep that acts (2026-11-01, docs/issues/btrfs-commit-stall/desktop-space-permanent-1101.md):
    # lane-reaper (idle lane clones -> Pi/external, verified + symlinked), disk-upkeep (pressure actions, uv prune).
    # Linked everywhere, timers enabled on the desktop only (LB_USER_UNITS gate desktop).
    "local-bin/lane-reaper:$HOME/.local/bin/lane-reaper"
    "local-bin/disk-upkeep:$HOME/.local/bin/disk-upkeep"
    "systemd-user/lane-reaper.service:$HOME/.config/systemd/user/lane-reaper.service"
    "systemd-user/lane-reaper.timer:$HOME/.config/systemd/user/lane-reaper.timer"
    "systemd-user/disk-pressure.service:$HOME/.config/systemd/user/disk-pressure.service"
    "systemd-user/disk-pressure.timer:$HOME/.config/systemd/user/disk-pressure.timer"
    "systemd-user/uv-cache-prune.service:$HOME/.config/systemd/user/uv-cache-prune.service"
    "systemd-user/uv-cache-prune.timer:$HOME/.config/systemd/user/uv-cache-prune.timer"
    # Battery guard — forced suspend at 25% and again at 12% (hibernate at 8%), so the laptop never
    # runs flat while awake. See docs/issues/laptop-low-battery-suspend.md
    "local-bin/battery-guard:$HOME/.local/bin/battery-guard"
    "systemd-user/battery-guard.service:$HOME/.config/systemd/user/battery-guard.service"
    "systemd-user/battery-guard.timer:$HOME/.config/systemd/user/battery-guard.timer"
    # sleep-verified — the one suspend entry point: proves it slept, unsticks hung
    # FUSE mounts, reports failures; laptop-state-snapshot keeps a map of what was
    # open. See docs/issues/laptop-suspend-fails-freeze-2026-10-03.md
    "local-bin/sleep-verified:$HOME/.local/bin/sleep-verified"
    "local-bin/laptop-state-snapshot:$HOME/.local/bin/laptop-state-snapshot"
    "local-bin/laptop-state-restore:$HOME/.local/bin/laptop-state-restore"
    "systemd-user/laptop-state-snapshot.service:$HOME/.config/systemd/user/laptop-state-snapshot.service"
    "systemd-user/laptop-state-snapshot.timer:$HOME/.config/systemd/user/laptop-state-snapshot.timer"
    # sleep-watch — verifies EVERY sleep (Omarchy menu, hypridle, UPower) via logind's PrepareForSleep
    "local-bin/sleep-watch:$HOME/.local/bin/sleep-watch"
    # input-activity-wait — "is he back?" (key/mouse/touch) for the sleep-watch retry
    # grace and, optionally, battery-guard's upper grace (2026-10-06)
    "local-bin/input-activity-wait:$HOME/.local/bin/input-activity-wait"
    "systemd-user/sleep-watch.service:$HOME/.config/systemd/user/sleep-watch.service"
    # Keyboard backlight — waybar widget plus a keep-on watchdog, because the EC
    # times the light off by itself without telling the kernel. The service is
    # ConditionPathExists-gated, so it is a clean skip on machines without the
    # LED. See the kbd-backlight script header.
    "local-bin/kbd-backlight:$HOME/.local/bin/kbd-backlight"
    "systemd-user/kbd-backlight-keeper.service:$HOME/.config/systemd/user/kbd-backlight-keeper.service"
    # Thermal monitoring: waybar module + screenshot guard
    "local-bin/thermal-alarm:$HOME/.local/bin/thermal-alarm"
    "local-bin/thermal-screenshot-guard:$HOME/.local/bin/thermal-screenshot-guard"
    "systemd-user/thermal-screenshot-guard.service:$HOME/.config/systemd/user/thermal-screenshot-guard.service"
    # Touchscreen scroll daemon and hyprgrass config (laptop)
    "local-bin/touch-scroll-daemon:$HOME/.local/bin/touch-scroll-daemon"
    "hypr/hyprgrass.conf:$HOME/.config/hypr/hyprgrass.conf"
    "systemd-user/touch-scroll-daemon.service:$HOME/.config/systemd/user/touch-scroll-daemon.service"
    # Bluetooth keyboard auto-reconnect + bluetuith launcher
    "local-bin/bt-keyboard-reconnect:$HOME/.local/bin/bt-keyboard-reconnect"
    "local-bin/omarchy-launch-bluetooth:$HOME/.local/bin/omarchy-launch-bluetooth"
    "systemd-user/bt-keyboard-reconnect.service:$HOME/.config/systemd/user/bt-keyboard-reconnect.service"
    # Power loss detection (boot-time monitor)
    "local-bin/power-loss-monitor:$HOME/.local/bin/power-loss-monitor"
    "local-bin/power-loss-waybar:$HOME/.local/bin/power-loss-waybar"
    "systemd-user/power-loss-monitor.service:$HOME/.config/systemd/user/power-loss-monitor.service"
    # Hyprland autostart (dicons, monitor-chooser, etc.). The desktop links its
    # own copy: machine-specific/desktop/symlinks.conf (same for monitors.conf)
    "hypr/autostart.conf:$HOME/.config/hypr/autostart.conf"
    # Screen rotation (display + touchscreen + scroll direction); the laptop
    # autostart re-applies it and the Flip/Normal desktop icons call it
    "local-bin/screen-flip:$HOME/.local/bin/screen-flip"
    # Drift escalation: bar module, touch reopen path, Claude agent launcher
    # (see docs/issues/desktop-drift-2026-09-30.md)
    "local-bin/lb-drift:$HOME/.local/bin/lb-drift"
    # Super+Enter / xdg-terminal-exec go through this wrapper: single-instance
    # hand-off with a timeout, standalone fallback if the instance is deadlocked.
    "local-bin/ghostty-launch:$HOME/.local/bin/ghostty-launch"
    "desktop-entries/com.mitchellh.ghostty.desktop:$HOME/.local/share/applications/com.mitchellh.ghostty.desktop"
    "hypr/scripts/monitor-persist.sh:$HOME/.config/hypr/scripts/monitor-persist.sh"
    "hypr/scripts/monitor-resume-watch.sh:$HOME/.config/hypr/scripts/monitor-resume-watch.sh"
    "systemd-user/hyprland-monitor-persist.service:$HOME/.config/systemd/user/hyprland-monitor-persist.service"
    "systemd-user/hyprland-monitor-resume.service:$HOME/.config/systemd/user/hyprland-monitor-resume.service"
    # Desktop icons
    "desktop-entries/Flip-Landscape.desktop:$HOME/Desktop/Flip-Landscape.desktop"
    "desktop-entries/Normal-Screen.desktop:$HOME/Desktop/Normal-Screen.desktop"
    "desktop-entries/Firefox.desktop:$HOME/Desktop/Firefox.desktop"
    "desktop-entries/Google-Chrome.desktop:$HOME/Desktop/Google-Chrome.desktop"
    "desktop-entries/Chromium.desktop:$HOME/Desktop/Chromium.desktop"
    "desktop-entries/Display-Settings.desktop:$HOME/Desktop/Display-Settings.desktop"
    "desktop-entries/ChatGPT.desktop:$HOME/Desktop/ChatGPT.desktop"
    "desktop-entries/Claude.desktop:$HOME/Desktop/Claude.desktop"
    "desktop-entries/Steam.desktop:$HOME/Desktop/Steam.desktop"
    "desktop-entries/Obsidian.desktop:$HOME/Desktop/Obsidian.desktop"
    # App launcher webapps (walker, super+space) — deploy to ~/.local/share/applications/
    "desktop-entries/Telegram.desktop:$HOME/.local/share/applications/Telegram.desktop"
    "desktop-entries/icons/Telegram.png:$HOME/.local/share/applications/icons/Telegram.png"
    "desktop-entries/ChatGPT.desktop:$HOME/.local/share/applications/ChatGPT.desktop"
    "desktop-entries/icons/ChatGPT.png:$HOME/.local/share/applications/icons/ChatGPT.png"
    "desktop-entries/Claude.desktop:$HOME/.local/share/applications/Claude.desktop"
    "desktop-entries/icons/Claude.png:$HOME/.local/share/applications/icons/Claude.png"
)

# Detect device type based on Tailscale IP, falling back to battery presence
detect_device() {
    lb_detect_device "$FORCE_DEVICE"
}

DEVICE_TYPE=$(detect_device)

# Write device role configuration file
write_device_role() {
    local ts_ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
    local role="secondary"  # Default to secondary
    local name="$DEVICE_TYPE"

    # Laptop is primary (always-on, receives syncs)
    if [[ "$DEVICE_TYPE" == "laptop" ]]; then
        role="primary"
    fi

    cat > "$REPO_ROOT/device-role.conf" <<EOF
# Device role configuration
# Generated by install.sh on $(date)

DEVICE_ROLE="$role"
DEVICE_NAME="$name"
TAILSCALE_IP="$ts_ip"
EOF

    log "Device role: $role ($name)"
}

# =============================================================================
# Core Setup Functions
# =============================================================================

install_base_deps() {
    header "Installing Base Dependencies"

    local packages=(
        # Core utilities
        openssh
        pass
        gnupg
        # Network
        tailscale
        ufw
        # Bluetooth
        bluez-utils  # For bluetoothctl CLI and BLE device pairing
        bluez-hid2hci  # HID to HCI mode switching for BLE keyboards/mice
        # Display management
        nwg-displays  # Wayland display configuration GUI
        # Shells and tools
        bash-completion
        git
        # Utilities
        jq       # JSON config merges and validation
        pacman-contrib  # paccache.timer keeps the package cache to 3 versions (desktop-space-permanent-1101)
        sshpass  # For scripted SSH operations
        netcat   # For network diagnostics
        # Hardware auth
        pam-u2f   # YubiKey FIDO2 sudo authentication
        libfido2  # FIDO2 library for pam-u2f
        # workspace-labels popup card (docs/workspace-labels): fonts + glyphs ✻ ✢ ⎿ ❯
        ttf-dejavu
        webkitgtk-6.0  # SPEC's GTK4 route; usable after a full -Syu (glibc 2.44); GTK3 webkit2gtk-4.1 is used now
    )

    log "Installing packages: ${packages[*]}"
    sudo pacman -S --needed --noconfirm "${packages[@]}"

    # AUR packages
    if command -v yay &>/dev/null; then
        yay -S bluetuith-bin --noconfirm --needed  # BT TUI manager with mouse support
        yay -S google-chrome --noconfirm --needed  # Google Chrome browser
        gpg --list-keys 9DEA5E350F9D285E46D3B7E3CE737F191AF5DCFB &>/dev/null \
            || gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 9DEA5E350F9D285E46D3B7E3CE737F191AF5DCFB
        # workspace-labels agent card fonts (Geist, Geist Mono, Instrument Serif)
        yay -S ttf-geist ttf-geist-mono ttf-instrument-serif --noconfirm --needed
    fi
}

setup_symlinks() {
    header "Setting Up Symlinks"

    # SYMLINKS + machine-specific/$DEVICE_TYPE/symlinks.conf, one implementation
    # shared with the 10-minute sync (scripts/lib/reconcile.sh). A file whose
    # content differs from the repo is reported, never clobbered.
    lb_reconcile_links
    lb_mako_refresh    # a new mako config link takes effect now, not at next login

    # waybar's config includes this file; tray icon-size lives only there.
    # A missing file is harmless (normal mode, default tray size) but write it.
    "$DOTFILES/local-bin/touch-mode" ensure && log "waybar touch-mode state present"

    # Special keys, Super+W close order and Alt+Tab override Omarchy defaults,
    # so bindings.conf must source them (LB_HYPR_SOURCES in lib/reconcile.sh)
    lb_ensure_hypr_sources

    # Enable the user units the installer owns, with the installer's device
    # gates (LB_USER_UNITS in lib/reconcile.sh)
    lb_reconcile_units 1
}

setup_localsend_preferences() {
    header "Setting Up LocalSend Preferences"

    local destination="$HOME/Downloads/localsend"
    local legacy_destination="$HOME/Downloads/Localsend"
    local prefs_dir="$HOME/.local/share/org.localsend.localsend_app"
    local prefs="$prefs_dir/shared_preferences.json"

    if [[ -d "$legacy_destination" && ! -e "$destination" ]]; then
        mv "$legacy_destination" "$destination"
        log "Renamed existing LocalSend folder to $destination"
    else
        mkdir -p "$destination"
        log "Ensured LocalSend destination folder exists: $destination"
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot set LocalSend destination preference (install jq, then re-run)"
        return 0
    fi

    mkdir -p "$prefs_dir"

    if [[ ! -f "$prefs" ]]; then
        printf '{}\n' > "$prefs"
    elif ! jq -e . "$prefs" &>/dev/null; then
        warn "Invalid LocalSend preferences JSON at $prefs — leaving it unchanged"
        return 0
    fi

    if jq -e --arg destination "$destination" \
        '."flutter.ls_destination" == $destination' "$prefs" &>/dev/null; then
        log "LocalSend destination already set to $destination"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    if jq --arg destination "$destination" \
        '. + {"flutter.ls_destination": $destination}' \
        "$prefs" >"$tmp" 2>/dev/null && jq -e . "$tmp" &>/dev/null; then
        cp "$prefs" "${prefs}.bak.$(date +%s)"
        mv "$tmp" "$prefs"
        log "Set LocalSend destination to $destination"
    else
        rm -f "$tmp"
        warn "Could not update LocalSend destination preference"
    fi
}

setup_oom_guard_hook() {
    header "Registering OOM-Guard Claude Code Hook"

    local settings="$HOME/.claude/settings.json"
    local hook_cmd="$HOME/.claude/hooks/oom-guard.sh"

    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot register oom-guard hook (install jq, then re-run)"
        return 0
    fi
    if [[ ! -f "$settings" ]]; then
        info "No $settings yet — skipping (re-run install.sh after first Claude Code launch)"
        return 0
    fi
    # Idempotent: skip if this hook is already registered
    if jq -e --arg c "$hook_cmd" \
         '.hooks.PreToolUse[]?.hooks[]? | select(.command == $c)' "$settings" &>/dev/null; then
        log "oom-guard hook already registered in settings.json"
        return 0
    fi
    # Non-destructive merge: append a PreToolUse entry, validate, then swap in
    local tmp
    tmp=$(mktemp)
    if jq --arg c "$hook_cmd" \
         '.hooks = (.hooks // {})
          | .hooks.PreToolUse = ((.hooks.PreToolUse // [])
              + [{matcher: "*", hooks: [{type: "command", command: $c}]}])' \
         "$settings" >"$tmp" 2>/dev/null && jq -e . "$tmp" &>/dev/null; then
        cp "$settings" "${settings}.bak.$(date +%s)"
        mv "$tmp" "$settings"
        log "Registered oom-guard hook in settings.json"
    else
        rm -f "$tmp"
        warn "Could not merge oom-guard hook into settings.json — register it manually"
    fi
}

setup_subagent_context_guard_hook() {
    header "Registering Subagent Context Guard Claude Code Hook"

    local settings="$HOME/.claude/settings.json"
    local hook_cmd="$HOME/.claude/hooks/subagent-context-guard.py"

    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot register subagent-context-guard hook (install jq, then re-run)"
        return 0
    fi
    if [[ ! -f "$settings" ]]; then
        info "No $settings yet — skipping (re-run install.sh after first Claude Code launch)"
        return 0
    fi
    # Idempotent: registered under three events; skip if all three are present
    if jq -e --arg c "$hook_cmd" \
         '(.hooks.PreToolUse[]?.hooks[]? | select(.command == $c)) and
          (.hooks.PostToolUse[]?.hooks[]? | select(.command == $c)) and
          (.hooks.SubagentStop[]?.hooks[]? | select(.command == $c))' "$settings" &>/dev/null; then
        log "subagent-context-guard hook already registered in settings.json"
        return 0
    fi
    local tmp
    tmp=$(mktemp)
    if jq --arg c "$hook_cmd" '
         def has(ev): [ .hooks[ev][]?.hooks[]? | select(.command == $c) ] | length > 0;
         .hooks = (.hooks // {})
         | if has("PreToolUse") then . else
             .hooks.PreToolUse = ((.hooks.PreToolUse // [])
               + [{matcher: "Agent|SendMessage", hooks: [{type: "command", command: $c}]}]) end
         | if has("PostToolUse") then . else
             .hooks.PostToolUse = ((.hooks.PostToolUse // [])
               + [{matcher: "*", hooks: [{type: "command", command: $c}]}]) end
         | if has("SubagentStop") then . else
             .hooks.SubagentStop = ((.hooks.SubagentStop // [])
               + [{hooks: [{type: "command", command: $c}]}]) end' \
         "$settings" >"$tmp" 2>/dev/null && jq -e . "$tmp" &>/dev/null; then
        cp "$settings" "${settings}.bak.$(date +%s)"
        mv "$tmp" "$settings"
        log "Registered subagent-context-guard hook in settings.json"
    else
        rm -f "$tmp"
        warn "Could not merge subagent-context-guard hook into settings.json — register it manually"
    fi
}

setup_sudo_popup_hook() {
    header "Registering Sudo Popup Claude Code Hook"

    local settings="$HOME/.claude/settings.json"
    local hook_cmd="$HOME/.claude/hooks/check-sudo-popup.sh"

    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot register sudo popup hook (install jq, then re-run)"
        return 0
    fi
    if [[ ! -f "$settings" ]]; then
        info "No $settings yet — skipping (re-run install.sh after first Claude Code launch)"
        return 0
    fi
    if jq -e --arg c "$hook_cmd" \
         '.hooks.Stop[]?.hooks[]? | select(.command == $c)' "$settings" &>/dev/null; then
        log "sudo popup hook already registered in settings.json"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    if jq --arg c "$hook_cmd" \
         '.hooks = (.hooks // {})
          | .hooks.Stop = ((.hooks.Stop // [])
              + [{hooks: [{type: "command", command: $c}]}])' \
         "$settings" >"$tmp" 2>/dev/null && jq -e . "$tmp" &>/dev/null; then
        cp "$settings" "${settings}.bak.$(date +%s)"
        mv "$tmp" "$settings"
        log "Registered sudo popup hook in settings.json"
    else
        rm -f "$tmp"
        warn "Could not merge sudo popup hook into settings.json — register it manually"
    fi
}

setup_monitor_chooser() {
    header "Building monitor-chooser"

    local build="$REPO_ROOT/apps/monitor-chooser/build.sh"
    if [[ ! -x "$build" ]]; then
        warn "apps/monitor-chooser/build.sh not found — skipping monitor-chooser build"
        return 0
    fi
    if "$build"; then
        log "monitor-chooser built — apps/monitor-chooser/bin/monitor-chooser"
    else
        warn "monitor-chooser build failed (is the Rust toolchain installed?) — the waybar widget will prompt to build it manually"
    fi
}

setup_bar_touch() {
    header "bar-touch (touch-native top bar + touchscreen mouse mode)"
    systemctl --user daemon-reload
    # Safe everywhere: with no touchscreen the daemon only relays mouse clicks,
    # and the bar's click handler falls back to running the command itself.
    if systemctl --user enable --now bar-touch.service 2>/dev/null; then
        log "Enabled bar-touch.service"
    else
        warn "Could not enable bar-touch.service (bar clicks still work via the fallback)"
    fi
    # workspace-labels (laptop panel only, same gate as reconcile.sh: edp)
    if compgen -G "/sys/class/drm/*eDP*" >/dev/null; then
        systemctl --user enable --now workspace-labels.service 2>/dev/null \
            && log "Enabled workspace-labels.service" \
            || warn "Could not enable workspace-labels.service"
    fi
    # watch history for every MPRIS player (both machines; harmless with no player)
    systemctl --user enable --now media-history-recorder.service 2>/dev/null \
        && log "Enabled media-history-recorder.service" \
        || warn "Could not enable media-history-recorder.service"
    # The power-profile button's RAM-resident state (both machines: config.jsonc
    # is shared; with no battery it shows "AC: Mains"). Dead daemon = the bar
    # falls back to power-profile-monitor, so enabling it is never a risk.
    if systemctl --user enable --now power-profile-daemon.service 2>/dev/null; then
        log "Enabled power-profile-daemon.service"
    else
        warn "Could not enable power-profile-daemon.service (the bar falls back to power-profile-monitor)"
    fi
}

setup_monitor_persist() {
    header "Setting Up Monitor Persistence"

    # Only meaningful on a machine with an internal panel + hotpluggable external.
    if [[ ! -d /sys/class/drm ]] || ! ls -d /sys/class/drm/*eDP* >/dev/null 2>&1; then
        info "No internal (eDP) panel found — skipping monitor persistence"
        return 0
    fi

    systemctl --user daemon-reload

    # Reapplies the saved layout on hotplug (socket2 monitoradded/removed).
    if systemctl --user enable hyprland-monitor-persist.service 2>/dev/null; then
        log "Enabled hyprland-monitor-persist.service"
    fi

    # A resume emits neither socket2 event, and the systemd USER manager has no
    # sleep.target, so resume is handled separately via logind's PrepareForSleep.
    if systemctl --user enable hyprland-monitor-resume.service 2>/dev/null; then
        log "Enabled hyprland-monitor-resume.service"
    fi

    # Deliberately NOT --now: starting the persist service re-applies the layout
    # immediately, which blanks both screens. It starts with the next Hyprland
    # session (WantedBy=graphical-session.target).
    info "Both units start with the next graphical session"
    info "To start now (screens will flicker): systemctl --user start hyprland-monitor-persist"
}

setup_bashrc_sourcing() {
    header "Setting Up Bash Configuration"

    local bashrc="$HOME/.bashrc"
    local source_line='[[ -d ~/.config/bashrc.d ]] && for f in ~/.config/bashrc.d/*.sh; do source "$f"; done'

    if ! grep -q "bashrc.d" "$bashrc" 2>/dev/null; then
        echo "" >> "$bashrc"
        echo "# Source modular bash configs" >> "$bashrc"
        echo "$source_line" >> "$bashrc"
        log "Added bashrc.d sourcing to .bashrc"
    else
        log ".bashrc already sources bashrc.d"
    fi
}

setup_default_browser() {
    header "Setting Default Browser"
    xdg-settings set default-web-browser firefox.desktop
    xdg-mime default firefox.desktop x-scheme-handler/http
    xdg-mime default firefox.desktop x-scheme-handler/https
    log "Default browser set to Firefox"
}

setup_secrets() {
    header "Setting Up Secret Management"
    "$SCRIPT_DIR/secrets-init.sh"
}

setup_tailscale() {
    header "Setting Up Tailscale"
    "$SCRIPT_DIR/setup-tailscale.sh"
}

setup_btrfs_snapshots() {
    header "btrfs: quotas off, snap-pac snapshots"
    "$SCRIPT_DIR/setup-btrfs-snapshots.sh"
}

setup_firewall() {
    header "Setting Up Firewall"
    "$SCRIPT_DIR/setup-ufw.sh"
}

setup_ssh() {
    header "Setting Up SSH"
    "$SCRIPT_DIR/setup-ssh.sh"
}

setup_voice_typing() {
    header "Setting Up Voice Typing"
    "$SCRIPT_DIR/setup-voice-typing.sh"

    # Ensure Hyprland sources the mic-osd window rules
    local bindings_file="$HOME/.config/hypr/bindings.conf"
    if [[ -f "$bindings_file" ]] && ! grep -q "windowrules-mic-osd.conf" "$bindings_file"; then
        log "Adding mic-osd window rules to Hyprland config..."
        echo 'source = ~/.config/hypr/windowrules-mic-osd.conf' >> "$bindings_file"
    fi
    # bar-touch layer rules (the on-screen keyboard slides up from the bottom)
    local hypr_main="$HOME/.config/hypr/hyprland.conf"
    if [[ -f "$hypr_main" ]] && ! grep -q "layerrules-bar-touch.conf" "$hypr_main"; then
        log "Adding bar-touch layer rules to Hyprland config..."
        echo 'source = ~/.config/hypr/layerrules-bar-touch.conf' >> "$hypr_main"
    fi
}

setup_clipboard_health() {
    header "Setting Up Clipboard Health Monitor"

    # Ensure ~/.local/bin exists and is in PATH
    mkdir -p "$HOME/.local/bin"

    # Reload systemd user units
    systemctl --user daemon-reload

    # Enable and start the timer
    if systemctl --user enable clipboard-health.timer 2>/dev/null; then
        log "Enabled clipboard-health.timer"
    fi

    if systemctl --user start clipboard-health.timer 2>/dev/null; then
        log "Started clipboard-health.timer"
    fi

    # Run initial health check
    if [[ -x "$HOME/.local/bin/clipboard-health" ]]; then
        log "Running initial clipboard health check..."
        "$HOME/.local/bin/clipboard-health" --fix || true
    fi
}

setup_git_hooks() {
    header "Setting Up Git Hooks"

    local hooks_src="$REPO_ROOT/hooks"
    local hooks_dst="$REPO_ROOT/.git/hooks"

    if [[ -d "$hooks_src" ]]; then
        for hook in "$hooks_src"/*; do
            local name
            name=$(basename "$hook")
            ln -sf "$hook" "$hooks_dst/$name"
            log "Installed git hook: $name"
        done
    fi

    info "Pre-push hook runs validate-configs.sh before every push"
}

setup_auto_sync() {
    header "Setting Up Auto-Sync Service"

    # Reload systemd user units
    systemctl --user daemon-reload

    # Enable and start the sync timer
    if systemctl --user enable local-bootstrapping-sync.timer 2>/dev/null; then
        log "Enabled local-bootstrapping-sync.timer"
    fi

    if systemctl --user start local-bootstrapping-sync.timer 2>/dev/null; then
        log "Started local-bootstrapping-sync.timer (runs every 10 minutes)"
    fi

    info "Auto-sync will pull changes from master branch"
    info "Changes are validated before applying"
    info "Backups stored in ~/.local-bootstrapping-backups/"
}

setup_drift_detector() {
    header "Setting Up Drift Detector"

    # Ensure log directory exists
    mkdir -p "$HOME/.local/state/drift-detector"

    # Reload systemd user units
    systemctl --user daemon-reload

    # Enable and start the timer
    if systemctl --user enable drift-detector.timer 2>/dev/null; then
        log "Enabled drift-detector.timer"
    fi

    if systemctl --user start drift-detector.timer 2>/dev/null; then
        log "Started drift-detector.timer (runs hourly)"
    fi

    # Run initial check
    log "Running initial drift check..."
    "$SCRIPT_DIR/drift-detector.sh" || true

    info "Drift detector will alert about uncommitted changes across machines"
    info "Logs: ~/.local/state/drift-detector/drift.log"
}

setup_wallpaper_slideshow() {
    header "Setting Up Wallpaper Slideshow"

    # Copy wallpapers to ~/Pictures/Wallpapers/
    mkdir -p "$HOME/Pictures/Wallpapers"
    cp -n "$DOTFILES/wallpapers/"braces-*-4k.png "$HOME/Pictures/Wallpapers/" 2>/dev/null || true
    log "Wallpapers copied to ~/Pictures/Wallpapers/"

    # Reload systemd
    systemctl --user daemon-reload

    # Enable and start timer
    if systemctl --user enable wallpaper-rotate.timer 2>/dev/null; then
        log "Enabled wallpaper-rotate.timer"
    fi

    if systemctl --user start wallpaper-rotate.timer 2>/dev/null; then
        log "Started wallpaper-rotate.timer (rotates every 30 min)"
    fi

    # Set initial wallpaper
    if [[ -x "$HOME/.local/bin/wallpaper-rotate" ]]; then
        "$HOME/.local/bin/wallpaper-rotate" || true
    fi

    info "Wallpaper slideshow active (6 variants, 30 min rotation)"
}

setup_swayosd() {
    header "Setting Up SwayOSD Supervision"

    systemctl --user daemon-reload

    # Layer 1: restart the server if the PROCESS dies (GTK4/Wayland segfault).
    if systemctl --user enable --now swayosd-server.service 2>/dev/null; then
        log "Enabled swayosd-server.service (restarts on crash)"
    fi

    # Layer 2: restart it if the process LIVES but drops its D-Bus name — the
    # failure mode that left volume keys and waybar scroll dead for 2 days in
    # July 2026 while systemd saw a perfectly healthy process.
    if systemctl --user enable --now swayosd-health.timer 2>/dev/null; then
        log "Enabled swayosd-health.timer (D-Bus name check every 60s)"
    fi

    info "SwayOSD supervised: process crash + D-Bus name loss both self-heal"

    # Nothing may close all windows at once (Ctrl+Alt+Delete, 2026-10-26).
    "$HOME/.local/bin/close-all-guard" || true
    if systemctl --user enable --now close-all-guard.path close-all-guard.timer 2>/dev/null; then
        log "Enabled close-all-guard.path + .timer (close-all script and bind stay gone)"
    fi
}

setup_claude_remote_control() {
    header "Setting Up Claude Remote Control Server"

    systemctl --user daemon-reload

    # Supervised because `claude remote-control` exits permanently after 10 min
    # of network errors (2026-07-31: ISP outage killed phone access for ~12h).
    # See docs/issues/remote-control-dies-on-network-outage.md
    if systemctl --user enable --now claude-remote-control.service 2>/dev/null; then
        log "Enabled claude-remote-control.service (phone sessions survive outages)"
    fi

    info "Remote Control supervised: server restarts 30s after any exit"
}

setup_power_profile() {
    header "Setting Up Power Profile Auto-Switching"

    # Only relevant on laptops (desktops stay on AC)
    if [[ ! -d /sys/class/power_supply/BAT0 ]]; then
        info "No battery detected, skipping power profile setup"
        return
    fi

    # Copy udev rule (requires sudo)
    local udev_src="$REPO_ROOT/system/udev-rules/99-power-profile.rules"
    if [[ -f "$udev_src" ]]; then
        sudo cp "$udev_src" /etc/udev/rules.d/
        sudo udevadm control --reload-rules
        log "Installed udev rule for AC plug/unplug detection"
    fi

    # Reload systemd and enable timer
    systemctl --user daemon-reload

    if systemctl --user enable --now power-profile-monitor.timer 2>/dev/null; then
        log "Enabled power-profile-monitor.timer (checks every 5 min)"
    fi

    # Second layer: the policy timer above only decides WHICH profile to ask for.
    # It cannot see the platform clamping the CPU to ~0.5 GHz while the profile
    # still reads balanced/performance (jank during browser video, fixed today by
    # manually cycling the widget). This timer detects that and bounces it.
    mkdir -p "$HOME/logs" "$HOME/.local/state/power-profile-watchdog"
    if systemctl --user enable --now power-profile-watchdog.timer 2>/dev/null; then
        log "Enabled power-profile-watchdog.timer (clamp check every 60s)"
    fi

    # Low-battery protection. The stock UPower action (2%) routed into
    # suspend-then-hibernate, which fails on this machine; the laptop died awake
    # twice in Sep 2026. logind drop-in sends every Sleep() request down plain
    # suspend; battery-guard suspends at 25% and again at 12% (limits in his conf).
    # See docs/issues/laptop-low-battery-suspend.md
    sudo install -D -m 644 "$REPO_ROOT/system/logind.conf.d/10-sleep-operation.conf" \
        /etc/systemd/logind.conf.d/10-sleep-operation.conf
    sudo install -D -m 644 "$REPO_ROOT/system/upower/10-battery-guard.conf" \
        /etc/UPower/UPower.conf.d/10-battery-guard.conf
    sudo systemctl reload systemd-logind
    sudo systemctl restart upower
    # Hibernate as the last resort below the suspend limits (2026-10-06): @swap subvolume with a
    # 32 GiB swapfile, resume hook + resume= on the limine cmdline, UPower CriticalPowerAction=
    # Hibernate. Idempotent (re-run = no-op); needs a reboot before resume= is live.
    # See docs/issues/laptop-hibernate-setup-2026-10-06.md
    if sudo "$REPO_ROOT/scripts/setup-hibernate.sh" --apply; then
        log "Hibernate set up (scripts/setup-hibernate.sh); reboot before the first hibernate"
    else
        warn "setup-hibernate.sh failed; see ~/logs/setup-hibernate-*.log"
    fi
    if systemctl --user enable --now battery-guard.timer 2>/dev/null; then
        log "Enabled battery-guard.timer (limits from ~/.config/battery-guard.conf)"
    fi
    # His limits file: written once with the defaults, never overwritten (his file).
    "$HOME/.local/bin/battery-guard" --init-conf || true
    # Snapshot of open windows / Claude sessions every 5 min (sleep-verified, 2026-10-03).
    if systemctl --user enable --now laptop-state-snapshot.timer 2>/dev/null; then
        log "Enabled laptop-state-snapshot.timer (every 5 min)"
    fi
    # Verifies every sleep, whoever asked; post-mortem + one retry on failure (2026-10-03).
    if systemctl --user enable --now sleep-watch.service 2>/dev/null; then
        log "Enabled sleep-watch.service (verifies every suspend)"
    fi

    # Run initial switch
    if [[ -x "$HOME/.local/bin/power-profile-monitor" ]]; then
        "$HOME/.local/bin/power-profile-monitor" switch || true
        local profile=$(powerprofilesctl get 2>/dev/null || echo "unknown")
        log "Current power profile: $profile"
    fi

    info "Power profiles: AC→performance, Battery>50%→balanced, Battery≤50%→power-saver"
}

setup_kbd_backlight() {
    header "Setting Up Keyboard Backlight Control"

    # ThinkPad-only: the tpacpi LED is what the widget and watchdog act on.
    if [[ ! -e /sys/class/leds/tpacpi::kbd_backlight/brightness ]]; then
        info "No tpacpi keyboard backlight, skipping"
        return
    fi

    # Without this rule the brightness attribute is root-only, and the keeper
    # service (a --user unit outside any login session) cannot fall back to
    # logind's SetBrightness — so its writes would fail every tick.
    local udev_src="$REPO_ROOT/system/udev-rules/99-kbd-backlight.rules"
    if [[ -f "$udev_src" ]]; then
        sudo cp "$udev_src" /etc/udev/rules.d/
        sudo udevadm control --reload-rules
        sudo udevadm trigger --subsystem-match=leds
        log "Installed udev rule for keyboard backlight write access"
    fi

    systemctl --user daemon-reload

    # Deliberately NOT enabled here: the keeper only runs while keep-on is
    # armed (the flag file), and arming is a user decision made from the widget.
    info "Keyboard backlight widget ready — left-click it to hold the light on"
}

setup_power_loss_monitor() {
    header "Setting Up Power Loss Monitor"

    mkdir -p "$HOME/.local/state/power-monitor"

    systemctl --user daemon-reload

    if systemctl --user enable power-loss-monitor.service 2>/dev/null; then
        log "Enabled power-loss-monitor.service (runs at boot)"
    fi

    # Run initial detection for current boot
    if [[ -x "$HOME/.local/bin/power-loss-monitor" ]]; then
        log "Running initial power loss detection..."
        "$HOME/.local/bin/power-loss-monitor" detect || true
    fi

    info "Power loss monitor detects unclean shutdowns at each boot"
    info "History: ~/.local/state/power-monitor/history.log"
}

setup_keystroke_log() {
    header "Setting Up Keystroke Log (local text recovery, default-on)"

    # Root-only keystroke capture so text an app loses (browser form with no
    # draft, a box that clears on reload) can be recovered from disk. Logs live
    # only in /var/log/keystroke-log (0600) and are never synced.
    # See configs/keystroke-log/README.md for the security trade-off.
    "$SCRIPT_DIR/setup-keystroke-log.sh"
}

setup_chrome_policy() {
    header "Setting Up Chrome Distraction Policy (Shorts + Amazon)"

    # His 2026-10-11 ask: YouTube Shorts and Amazon blocked on the laptop. The Pi-hole
    # cannot see the /shorts path (DNS sees hostnames only); a managed Chrome policy can.
    # Root-owned, so the browser UI cannot remove it; visible at chrome://policy.
    # Pairs with the Pi-hole always-on groups (star-trek-camera docs/computer/BEDTIME.md).
    if [[ "$DEVICE_TYPE" != "laptop" ]]; then
        info "Not the laptop, skipping Chrome policy"
        return
    fi
    local src="$REPO_ROOT/system/chrome/policies/managed/distractions.json"
    local dst=/etc/opt/chrome/policies/managed/distractions.json
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        info "Chrome policy already installed"
        return
    fi
    sudo install -D -m 0644 -o root -g root "$src" "$dst"
    success "Chrome policy installed: $dst (Chrome reloads it within minutes, or chrome://policy → Reload)"
}

setup_wifi_wedge_watchdog() {
    header "Setting Up Wi-Fi Wedge Watchdog (desktop USB Wi-Fi)"

    # Desktop only: TP-Link Archer T2U PLUS (rtw88_8821au) associates but stays
    # DORMANT with no DHCP on most boots; restarting iwd clears it.
    # docs/wifi-dormant-wedge.md, docs/rtl8821au-lps-wedge.md,
    # docs/issues/desktop-unattended-boot-2026-09-11.md
    if [[ "$(cat /sys/class/dmi/id/board_name 2>/dev/null)" != "PRIME A520M-K" ]]; then
        info "Not the desktop board, skipping Wi-Fi wedge watchdog"
        return
    fi

    sudo install -m755 "$REPO_ROOT/system/bin/wifi-wedge-watchdog" /usr/local/bin/wifi-wedge-watchdog
    sudo install -m644 "$REPO_ROOT/system/systemd/wifi-wedge-watchdog.service" \
                       "$REPO_ROOT/system/systemd/wifi-wedge-watchdog.timer" /etc/systemd/system/
    sudo install -m644 "$REPO_ROOT/system/modprobe.d/rtw88.conf" /etc/modprobe.d/rtw88.conf
    sudo install -D -m644 "$REPO_ROOT/system/iwd/main.conf" /etc/iwd/main.conf
    sudo systemctl daemon-reload
    sudo systemctl enable --now wifi-wedge-watchdog.timer
    log "wifi-wedge-watchdog.timer enabled (first check 30s after boot, then every 15s; iwd restart at ~45s wedged)"
}

setup_deep_sleep() {
    header "Setting Up Deep Sleep (S3) for Suspend"

    # Only relevant on laptops (fixes fan running during suspend on ThinkPad T14)
    if [[ ! -d /sys/class/power_supply/BAT0 ]]; then
        info "No battery detected, skipping deep sleep setup"
        return
    fi

    # Skip if the kernel doesn't support S3 on this hardware
    if ! grep -q deep /sys/power/mem_sleep 2>/dev/null; then
        warn "Kernel does not report 'deep' sleep support, skipping"
        return
    fi

    # IMPORTANT: the fix must go in /etc/default/limine (the SOURCE), not
    # /boot/limine.conf — limine.conf and the UKI are regenerated from this
    # file by the 99-limine pacman hook on every kernel update, which is why
    # editing limine.conf directly silently reverted (April → June 2026).
    # See docs/suspend-deep-sleep.md for the full history.
    if grep -q "mem_sleep_default=deep" /etc/default/limine 2>/dev/null; then
        log "mem_sleep_default=deep already in /etc/default/limine"
    else
        # /etc/default/limine is sourced as shell, so appending a += line at
        # the end works regardless of where KERNEL_CMDLINE[default] is defined
        echo 'KERNEL_CMDLINE[default]+="mem_sleep_default=deep"' | sudo tee -a /etc/default/limine >/dev/null
        log "Added mem_sleep_default=deep to /etc/default/limine"
        sudo limine-update
        log "Regenerated /boot/limine.conf and UKI"
    fi

    # Activate for the current boot too, so it works before the next reboot
    echo deep | sudo tee /sys/power/mem_sleep >/dev/null || true

    info "Suspend now uses S3 deep sleep: fan stops, wake takes ~2-3s"
}

setup_walker_resume_restart() {
    header "Setting Up Walker Resume Restart"

    # Only where the machine suspends (pairs with setup_deep_sleep); the
    # desktop runs as an always-on server. Same gate as LB_SYSTEM_FILES.
    if ! lb_gate battery; then
        info "No battery detected, skipping walker resume restart"
        return
    fi

    # Walker's Vulkan context dies when the GPU powers down across suspend,
    # which silently kills the power-button menu (and Super+Space). The process
    # stays alive spinning on VK_ERROR_DEVICE_LOST, so systemd never restarts
    # it. See docs/walker-resume-restart.md.
    local unit_src="$REPO_ROOT/system/systemd/walker-resume-restart.service"
    if [[ ! -f "$unit_src" ]]; then
        warn "walker-resume-restart.service not found, skipping"
        return
    fi

    sudo cp "$unit_src" /etc/systemd/system/
    sudo systemctl daemon-reload

    if sudo systemctl enable walker-resume-restart.service >/dev/null 2>&1; then
        log "Enabled walker-resume-restart.service (runs after every resume)"
    fi

    info "Power menu now survives suspend/resume automatically"
}

setup_fingerprint_auth() {
    header "Setting Up Fingerprint Authentication"

    # Detect hardware (battery OR fingerprint reader)
    if [[ ! -d /sys/class/power_supply/BAT0 ]]; then
        if ! lsusb | grep -iq fingerprint && ! fprintd-list "$USER" &>/dev/null 2>&1; then
            info "No fingerprint reader detected, skipping"
            return
        fi
    fi

    "$SCRIPT_DIR/setup-fingerprint-auth.sh"
}

setup_yubikey_sudo() {
    header "Setting Up YubiKey FIDO2 Sudo Authentication"
    "$SCRIPT_DIR/setup-yubikey-sudo.sh"
}

setup_datalake() {
    header "Setting Up Datalake API Service"
    "$SCRIPT_DIR/setup-datalake.sh"
}

setup_streaming() {
    header "Setting Up Game Streaming"

    # Ensure Hyprland sources the streaming keybindings
    local bindings_file="$HOME/.config/hypr/bindings.conf"
    local source_line='source = ~/.config/hypr/bindings-streaming.conf'
    if [[ -f "$bindings_file" ]] && ! grep -q "bindings-streaming.conf" "$bindings_file"; then
        log "Adding streaming keybindings to Hyprland config..."
        echo "$source_line" >> "$bindings_file"
    fi

    if [[ "$DEVICE_TYPE" == "desktop" ]]; then
        log "Installing Sunshine (server)..."
        # sunshine-bin (official LizardByte build). Not sunshine-beta-bin: 2026.1028 needs Qt 6.12
        # and would not start (2026-11-01, docs/vdi.md). Config: machine-specific/desktop/sunshine/.
        yay -S sunshine-bin --noconfirm --needed
        systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service  # upstream unit name (Alias=sunshine.service)
        systemctl --user enable --now sunshine-health.timer
        info "Sunshine installed. Set credentials: https://localhost:47990"
    else
        log "Installing Moonlight (client)..."
        yay -S moonlight-qt --noconfirm --needed
        systemctl --user enable --now moonlight-health.timer
        info "Moonlight installed. Pair with desktop to complete setup."
    fi
}

setup_telegram_bot() {
    header "Setting up Telegram Claude Bot"

    # Ensure phone-file-transfer repo exists
    local tg_dir="$HOME/Programs/phone-file-transfer"
    if [[ ! -d "$tg_dir" ]]; then
        log "Cloning phone-file-transfer (imagine-with-cc)..."
        git clone git@github.com:prabhanshu11/imagine-with-cc.git "$tg_dir"
    fi

    # Check for telegram config
    local tg_config="$HOME/.config/telegram-send/config"
    if [[ ! -f "$tg_config" ]]; then
        warn "Telegram bot not configured"
        info "Run: cd $tg_dir && ./telegram-send.py --setup"
    else
        log "Telegram config found"
    fi

    # Enable services
    systemctl --user daemon-reload
    if systemctl --user enable telegram-failover.timer 2>/dev/null; then
        log "Enabled telegram-failover.timer"
    fi

    # Start watcher on desktop (primary), timer handles laptop failover
    if [[ "$DEVICE_TYPE" == "desktop" ]]; then
        if systemctl --user enable --now telegram-watcher.service 2>/dev/null; then
            log "Started telegram-watcher on desktop (primary)"
        fi
    else
        log "Laptop: telegram-watcher will start via failover if desktop unavailable"
    fi

    info "Send /status to @ship_computer_bot to check bot status"
}

setup_audio_viz() {
    header "Setting Up Audio Visualization"
    bash "$SCRIPT_DIR/setup-audio-viz.sh" || warn "audio-viz setup failed (non-critical)"
}

setup_hyprgrass() {
    header "Setting Up Touchscreen Gestures (hyprgrass)"

    # Only for laptops with touchscreens
    if [[ ! -d /sys/class/power_supply/BAT0 ]]; then
        info "No battery detected, skipping touchscreen setup"
        return
    fi

    "$SCRIPT_DIR/setup-hyprgrass.sh"
}

setup_desktop_icons() {
    header "Setting Up Desktop Icons (dicons)"

    # Build and install dicons if not already present
    if ! command -v dicons &>/dev/null; then
        local build_dir="/tmp/desktop-icons-build"
        rm -rf "$build_dir"
        git clone https://github.com/Geronymos/desktop-icons "$build_dir"
        make -C "$build_dir"
        sudo install -Dm755 "$build_dir/dicons" /usr/local/bin/dicons
        rm -rf "$build_dir"
        log "dicons installed"
    else
        info "dicons already installed"
    fi

    # Ensure ~/Desktop exists
    mkdir -p "$HOME/Desktop"

    # Make .desktop files executable
    chmod +x "$HOME/Desktop/"*.desktop 2>/dev/null || true
}

setup_machine_specific() {
    header "Applying Device-Specific Configuration"

    info "Detected device type: $DEVICE_TYPE"

    local machine_dir="$REPO_ROOT/machine-specific/$DEVICE_TYPE"

    if [[ -d "$machine_dir" ]]; then
        # Run setup script if exists
        if [[ -f "$machine_dir/setup.sh" ]]; then
            log "Running $DEVICE_TYPE-specific setup..."
            bash "$machine_dir/setup.sh"
        fi

        # Device-specific symlinks (symlinks.conf) are applied by setup_symlinks
        # via lb_reconcile_links, which overlays them on SYMLINKS.
    else
        warn "No device-specific configs for $DEVICE_TYPE"
        info "Create configs at: $machine_dir/"
    fi
}

# =============================================================================
# Optional Components
# =============================================================================

setup_autocomplete_plugin() {
    header "Setting up AI Autocomplete Plugin"

    local plugin_dir="$HOME/Programs/autocomplete-plugin"

    if [[ -d "$plugin_dir" ]]; then
        log "Autocomplete plugin already exists at $plugin_dir"
        # Update from git
        cd "$plugin_dir"
        git pull origin master 2>/dev/null || warn "Could not update plugin"
    else
        log "Cloning autocomplete-plugin..."
        mkdir -p "$HOME/Programs"
        git clone git@github.com:prabhanshu11/autocomplete-plugin.git "$plugin_dir"
    fi

    # Ensure OpenRouter API key is in pass
    if ! pass show api/openrouter &>/dev/null; then
        warn "OpenRouter API key not found in pass"
        info "Add it with: pass insert api/openrouter"
    else
        log "OpenRouter API key found in pass"
    fi
}

# =============================================================================
# Post-Setup
# =============================================================================

verify_setup() {
    header "Verifying Setup"

    local checks=(
        "tailscale status:Tailscale connected"
        "systemctl is-active sshd:SSH server running"
        "systemctl is-active ufw:Firewall active"
        "command -v pass:Pass installed"
        "grep -q pam_fprintd.so /etc/pam.d/system-login:Fingerprint auth configured"
    )

    local all_good=true

    for check in "${checks[@]}"; do
        local cmd="${check%%:*}"
        local desc="${check##*:}"

        if eval "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $desc"
        else
            echo -e "  ${RED}✗${NC} $desc"
            all_good=false
        fi
    done

    if $all_good; then
        log "All systems operational!"
    else
        warn "Some checks failed - review above"
    fi

    # Waybar widget validation (optional - uses Claude CLI)
    if command -v waybar &>/dev/null && pgrep -x waybar &>/dev/null; then
        info "Running waybar widget validation..."
        local validator="$SCRIPT_DIR/waybar-validator.py"
        if [[ -x "$validator" ]]; then
            if timeout 120 "$validator" --json > /tmp/waybar-validation.json 2>/dev/null; then
                local all_present=$(jq -r '.all_present // false' /tmp/waybar-validation.json 2>/dev/null)
                if [[ "$all_present" == "true" ]]; then
                    echo -e "  ${GREEN}✓${NC} Waybar widgets validated"
                else
                    local missing=$(jq -r '.missing | join(", ")' /tmp/waybar-validation.json 2>/dev/null)
                    echo -e "  ${YELLOW}⚠${NC} Waybar missing widgets: $missing"
                    echo "    Report: /tmp/waybar-validation.json"
                fi
            else
                echo -e "  ${YELLOW}⚠${NC} Waybar validation skipped (Claude CLI unavailable)"
            fi
        fi
    fi
}

show_manual_steps() {
    header "Manual Steps & Next Actions"

    echo "1. ${BOLD}Secrets${NC} - Store your API keys:"
    echo "   pass insert api/github-token"
    echo "   pass insert api/assemblyai-key"
    echo ""
    echo "2. ${BOLD}SSH Keys${NC} - If key exchange didn't complete:"
    echo "   ssh-copy-id prabhanshu@desktop  # or @laptop"
    echo ""
    echo "3. ${BOLD}Test SSH${NC}:"
    echo "   ssh desktop   # From laptop"
    echo "   ssh laptop    # From desktop"
    echo ""
    echo "4. ${BOLD}Reload Shell${NC}:"
    echo "   source ~/.bashrc"
    echo ""

    if [[ "$DEVICE_TYPE" == "desktop" ]]; then
        echo "5. ${BOLD}Desktop-specific${NC}:"
        echo "   - Check monitor layout in Hyprland config"
        echo "   - Verify GPU drivers"
        echo ""
    elif [[ "$DEVICE_TYPE" == "laptop" ]]; then
        echo "5. ${BOLD}Laptop-specific${NC}:"
        echo "   - Check touchpad settings"
        echo "   - Verify power management"
        echo ""
    fi

    echo "6. ${BOLD}Sync from another machine${NC} (if restoring):"
    echo "   - ~/.password-store/ (GPG-encrypted secrets)"
    echo "   - ~/Programs/ (your projects)"
    echo ""
}

show_quick_reference() {
    header "Quick Reference"

    echo "${BOLD}SSH Shortcuts:${NC}"
    echo "  ssh desktop          # SSH to desktop via Tailscale"
    echo "  ssh laptop           # SSH to laptop via Tailscale"
    echo ""
    echo "${BOLD}Tailscale:${NC}"
    echo "  tailscale status     # Show connected devices"
    echo "  tailscale ping <ip>  # Test connectivity"
    echo ""
    echo "${BOLD}Secrets:${NC}"
    echo "  pass ls              # List secrets"
    echo "  pass show api/xxx    # Show a secret"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           Local Bootstrapping for Omarchy                  ║"
    echo "║                                                           ║"
    echo "║  Device: $DEVICE_TYPE                                          ║"
    echo "║  Host:   $HOSTNAME                                        ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Core setup (always run)
    write_device_role
    install_base_deps
    setup_symlinks  # + hypr sources + gated user units (lib/reconcile.sh)
    setup_localsend_preferences
    setup_oom_guard_hook
    setup_subagent_context_guard_hook
    setup_sudo_popup_hook
    lb_reconcile_claude_hooks   # LB_CLAUDE_HOOKS (scripts/lib/reconcile.sh); the sync re-checks these too
    setup_monitor_chooser
    setup_monitor_persist
    setup_bar_touch
    setup_bashrc_sourcing
    setup_default_browser
    setup_git_hooks
    setup_keystroke_log  # Local root-only keystroke capture for text recovery (default-on)

    # Network and security
    setup_tailscale
    setup_firewall
    setup_btrfs_snapshots  # after Omarchy, which re-enables quotas (2026-11-01 stall fix)
    setup_ssh

    # Optional components
    if ! $MINIMAL; then
        setup_secrets
        setup_voice_typing
        setup_clipboard_health
        setup_auto_sync
        setup_drift_detector  # Cross-machine uncommitted changes alerting
        setup_wallpaper_slideshow  # Rotating braces wallpapers
        setup_swayosd  # Volume keys / waybar scroll survive crash AND D-Bus name loss
        setup_claude_remote_control  # Phone-initiated sessions survive network outages
        setup_power_profile  # AC/battery auto-switching
        setup_kbd_backlight  # Keyboard backlight widget + keep-on watchdog (ThinkPad)
        setup_power_loss_monitor  # Boot-time power loss detection
        setup_wifi_wedge_watchdog  # Desktop USB Wi-Fi: recover assoc-but-no-DHCP wedge
        setup_chrome_policy  # Shorts + Amazon URL blocklist (laptop only, root-owned)
        setup_deep_sleep  # S3 suspend so the fan stops (laptop only)
        setup_walker_resume_restart  # Power menu survives resume (pairs with deep sleep)
        setup_fingerprint_auth  # Biometric login for SDDM/TTY (laptop only)
        setup_yubikey_sudo  # YubiKey FIDO2 priority for sudo auth
        setup_autocomplete_plugin
        setup_streaming
        setup_datalake  # Both machines run datalake now
        setup_telegram_bot  # Telegram Claude bot with failover
        setup_audio_viz  # Multi-pane audio visualization dashboard
        setup_desktop_icons  # Desktop icons for screen rotation etc.
    fi

    # Touchscreen gestures (laptop only)
    if [[ "$DEVICE_TYPE" == "laptop" ]]; then
        setup_hyprgrass
    fi

    # Patch Omarchy defaults for Hyprland 0.54+ windowrule v3 syntax
    header "Patching Hyprland Config Compatibility"
    "$SCRIPT_DIR/fix-hyprland-054-compat.sh" || warn "Hyprland 0.54 compat patch had issues"
    "$SCRIPT_DIR/fix-hyprland-056-compat.sh" || warn "Hyprland 0.56 compat patch had issues"

    # Device-specific
    setup_machine_specific

    # Verification and guidance
    verify_setup
    show_manual_steps
    show_quick_reference

    echo ""
    log "Bootstrap complete for $DEVICE_TYPE!"
    echo ""
}

# --reconcile: the no-sudo self-heal only (the sync timer's entry point)
if $RECONCILE_ONLY; then
    canon="$(cd "$HOME/Programs/local-bootstrapping" 2>/dev/null && pwd -P || true)"
    if [[ "${LB_CHECK_ONLY:-0}" != 1 && "${LB_RECONCILE_ANY_ROOT:-0}" != 1 \
          && "$(cd "$REPO_ROOT" && pwd -P)" != "$canon" ]]; then
        error "--reconcile would link $HOME to $REPO_ROOT, not ~/Programs/local-bootstrapping (use --check, or LB_RECONCILE_ANY_ROOT=1 in tests)"
    fi
    LB_SKIP_DSTS=(
        # Managed separately (2026-09-30): never relinked by the sync
        "$HOME/.config/systemd/user/claude-remote-control.service"
    )
    [[ "${LB_QUIET:-0}" == 1 ]] || info "Reconciling $DEVICE_TYPE against $REPO_ROOT${LB_CHECK_ONLY:+ (check only)}"
    lb_reconcile_all
    exit 0
fi

main "$@"
