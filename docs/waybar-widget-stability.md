# Waybar Widget Stability Issue

## Problem

Waybar widgets (Bluetooth, Sunshine, Moonlight, Clipboard) intermittently disappear throughout the day. Symptoms:

- Bluetooth icon: sometimes visible, sometimes not
- Sunshine indicator: sometimes missing
- Moonlight indicator: sometimes missing
- Clipboard health: sometimes missing
- Widgets cycle unpredictably - never know what features are accessible

## Root Cause

The health check scripts (`streaming-health`, `system-health`, etc.) attempt to auto-install missing packages when run from systemd services:

```bash
# In streaming-health (lines 90-93, 202-205)
if ! command -v sunshine &>/dev/null; then
    notify-send "Sunshine" "Installing sunshine-beta-bin..." || true
    yay -S sunshine-beta-bin --noconfirm --needed  # FAILS: no TTY for sudo
fi
```

**Why this fails:**
1. Systemd services run without a TTY
2. `yay`/`pacman` require sudo for package installation
3. Sudo needs authentication (fingerprint/FIDO2)
4. No terminal = authentication timeout
5. Service fails with exit code 1
6. Waybar widget disappears

**Evidence from logs:**
```
Jan 13 07:52:21 streaming-health: sudo: a terminal is required to read the password
Jan 13 07:52:21 sudo: pam_unix(sudo:auth): conversation failed
Jan 13 07:52:24 streaming-health: sudo: a password is required
Jan 13 07:52:24 systemd: moonlight-health.service: Main process exited, code=exited, status=1/FAILURE
```

## The Fix

### Principle: Separate Concerns

**Health checks should only CHECK, never INSTALL or FIX automatically**

1. **Check** - Read-only status verification (safe in systemd services)
2. **Fix** - Requires user interaction/authentication (manual command only)
3. **Install** - Done during bootstrap, not during health checks

### Changes Required

#### 1. Remove Auto-Installation from Health Checks

**File:** `dotfiles/local-bin/streaming-health`

```bash
# BEFORE (lines 90-93):
if ! command -v sunshine &>/dev/null; then
    notify-send "Sunshine" "Installing sunshine-beta-bin..." || true
    yay -S sunshine-beta-bin --noconfirm --needed
fi

# AFTER:
# Package installation moved to bootstrap - health checks only verify
if ! command -v sunshine &>/dev/null; then
    echo "error:not_installed"
    return
fi
```

Similarly for moonlight_fix() (lines 202-205).

#### 2. Add Packages to Bootstrap

**File:** `scripts/install.sh`

Add laptop/desktop-specific package lists:

```bash
install_laptop_deps() {
    if [[ "$DEVICE_TYPE" != "laptop" ]]; then
        return
    fi

    local packages=(
        moonlight-qt  # Sunshine game streaming client
    )

    log "Installing laptop-specific packages: ${packages[*]}"
    yay -S --needed --noconfirm "${packages[@]}"
}

install_desktop_deps() {
    if [[ "$DEVICE_TYPE" != "desktop" ]]; then
        return
    fi

    local packages=(
        sunshine-beta-bin  # Game streaming server
    )

    log "Installing desktop-specific packages: ${packages[*]}"
    yay -S --needed --noconfirm "${packages[@]}"
}
```

#### 3. Graceful Degradation

If packages are missing, widgets should:
- Show informative error icon (not disappear)
- Display helpful tooltip
- Provide manual fix instructions

**Example:**
```bash
case "$status" in
    error:not_installed)
        text="󰿎"
        class="error"
        tooltip="Sunshine: Not installed\n\nRun: yay -S sunshine-beta-bin\nThen restart service"
        ;;
esac
```

## Implementation Checklist

- [ ] Update streaming-health script (remove auto-install from _fix functions)
- [ ] Update system-health script (same fix)
- [ ] Add install_laptop_deps() to install.sh
- [ ] Add install_desktop_deps() to install.sh
- [ ] Update health check JSON to show error states gracefully
- [ ] Test on both desktop and laptop
- [ ] Document manual fix procedures

## Testing

### Before Fix
```bash
# Simulate missing package
sudo pacman -R moonlight-qt

# Watch service fail
systemctl --user status moonlight-health
# Status: inactive (dead) with FAILURE (exit 1)

# Widget disappears from Waybar
```

### After Fix
```bash
# Simulate missing package
sudo pacman -R moonlight-qt

# Health check returns error, but doesn't fail
systemctl --user status moonlight-health
# Status: inactive (dead) with SUCCESS (exit 0)

# Widget shows error icon with helpful tooltip
# User can manually run: yay -S moonlight-qt
```

## Long-term Solution: Health Check Best Practices

1. **Health checks run in systemd services** = read-only, no sudo, no TTY
2. **Fix commands run manually** = can prompt for sudo, has TTY
3. **Package installation** = done during bootstrap only
4. **Graceful degradation** = show errors, don't hide widgets

### Pattern for Future Health Scripts

```bash
service_check() {
    # Returns: ok, error:reason, warning:reason
    # NEVER calls sudo, yay, pacman, or anything requiring auth

    if ! command -v service_binary &>/dev/null; then
        echo "error:not_installed"
        return
    fi

    # ... rest of read-only checks
    echo "ok"
}

service_json() {
    local status=$(service_check)

    case "$status" in
        error:not_installed)
            # Show error icon, don't disappear
            emit_json "󰋗" "error" "Package not installed\n\nManual fix: yay -S package-name"
            ;;
        # ... other cases
    esac
}

# Fix function is for MANUAL use only, not called from systemd
service_fix() {
    # Can use sudo, yay, etc. because user runs this manually
    if ! command -v service_binary &>/dev/null; then
        notify-send "Service" "Installing package..."
        yay -S package-name --noconfirm --needed
    fi
    # ... rest of fix logic
}
```

## Related Issues

- Voice typing service also has stability issues (separate investigation needed)
- Consider adding `Restart=on-failure` with `RestartSec=30s` to timers
- Add monitoring for health service failures

## References

- systemd service logs: `journalctl --user -u SERVICE-health -n 50`
- Timer status: `systemctl --user status SERVICE-health.timer`
- Waybar config: `dotfiles/waybar/config.jsonc`
- Health scripts: `dotfiles/local-bin/{streaming,system,datalake}-health`
