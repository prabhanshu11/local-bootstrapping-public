# Fingerprint Authentication for SDDM and TTY Login

## Overview

This setup enables fingerprint authentication for:
- **SDDM login screen** - Biometric login at boot/logout
- **Lock screen** - Quick unlock without typing password
- **TTY login** - Console login via fingerprint

Fingerprint authentication is configured as an **alternative** to password login. If fingerprint fails or times out (30 seconds), you can always fall back to entering your password.

## Prerequisites

### Hardware
- Fingerprint reader (detected via `lsusb | grep -i fingerprint`)
- Typically found on ThinkPad laptops (Synaptics/Validity sensors)

### Software
- `fprintd` package installed (Arch: `sudo pacman -S fprintd`)
- `pam_fprintd.so` PAM module (included in fprintd package)

### Enrollment
You must enroll at least one fingerprint before fingerprint authentication will work:

```bash
# Enroll a fingerprint (interactive)
fprintd-enroll

# Enroll specific finger
fprintd-enroll -f right-index-finger
fprintd-enroll -f left-index-finger

# List enrolled fingerprints
fprintd-list $USER

# Delete a fingerprint
fprintd-delete $USER
```

**Recommendation:** Enroll 2-3 fingers (e.g., both index fingers) for redundancy.

## Automated Setup

The easiest way to set up fingerprint authentication is via the main install script:

```bash
cd ~/Programs/local-bootstrapping
./scripts/install.sh
```

The script will:
1. Detect fingerprint reader hardware
2. Check prerequisites (fprintd, enrolled fingerprints)
3. Backup current PAM configuration
4. Deploy systemd drop-in (ensures fprintd starts before SDDM)
5. Deploy fingerprint-enabled PAM config
6. Verify deployment with automatic rollback on failure
7. Provide testing instructions

## Manual Setup

If you want to run the fingerprint auth setup standalone:

```bash
cd ~/Programs/local-bootstrapping
./scripts/setup-fingerprint-auth.sh
```

This is useful for:
- Troubleshooting installation issues
- Re-applying configuration after system updates
- Testing changes to the setup script

## Testing Procedure

After setup, test in stages to ensure everything works:

### Phase 1: Non-destructive Tests (Stay Logged In)

1. **Lock screen test**
   ```bash
   # Lock screen (Super+L or hyprlock)
   # Touch fingerprint reader → should unlock
   ```

2. **Verify sudo still works**
   ```bash
   sudo echo "test"
   # Should prompt for fingerprint (already working before)
   ```

3. **Verify polkit still works**
   ```bash
   # Open any app requiring authentication
   # Should prompt for fingerprint (already working before)
   ```

### Phase 2: Login Tests (Log Out Required)

4. **SDDM fingerprint test**
   ```
   - Log out (don't reboot yet)
   - SDDM login screen appears
   - Touch fingerprint reader
   - Should log in immediately
   ```

5. **Password fallback test**
   ```
   - Log out again
   - Touch fingerprint reader but DON'T place finger correctly
   - Wait 30 seconds
   - Password prompt should appear
   - Enter password → should log in
   ```

### Phase 3: Reboot Test (Final Verification)

6. **Cold boot test**
   ```
   - Reboot machine
   - SDDM appears after boot
   - Touch fingerprint reader
   - Should log in from cold state
   ```

## Rollback Instructions

If fingerprint authentication causes issues, you can rollback safely:

### Option 1: Use Timestamped Backup (Recommended)

The setup script creates backups with timestamps:

```bash
# List available backups
ls -lt /etc/pam.d/system-login.bak.*

# Restore most recent backup
sudo cp /etc/pam.d/system-login.bak.TIMESTAMP /etc/pam.d/system-login

# Example:
sudo cp /etc/pam.d/system-login.bak.20260217_143000 /etc/pam.d/system-login
```

### Option 2: Restore Arch Linux Default

If backups are unavailable:

```bash
sudo cp /usr/share/factory/etc/pam.d/system-login /etc/pam.d/system-login
```

This restores the vanilla Arch Linux PAM configuration.

### Emergency Access

Even if PAM is completely broken, you can still access your system:

1. **Root login at TTY** - Root account uses separate PAM chain
2. **Single-user mode** - Boot with `init=/bin/bash` kernel parameter
3. **Live USB** - Boot from USB and chroot to fix configuration

**Important:** Password fallback is always preserved. Even with fingerprint auth enabled, you can still log in with your password if fingerprint fails.

## Troubleshooting

### Fingerprint Reader Not Detected

```bash
# Check USB devices
lsusb | grep -i fingerprint

# Check fprintd detection
fprintd-list $USER

# Check for enrolled fingerprints
fprintd-list $USER | grep "finger:"
```

If no reader is detected:
- Verify hardware is enabled in BIOS
- Check kernel modules: `lsmod | grep usb`
- Review dmesg for USB enumeration errors: `dmesg | grep -i fingerprint`

### Fingerprint Prompt Never Appears

```bash
# Check PAM configuration
grep pam_fprintd /etc/pam.d/system-login

# Should show:
# auth       sufficient pam_fprintd.so max-tries=3 timeout=30

# Check fprintd service
systemctl status fprintd.service

# Start if not running
sudo systemctl start fprintd.service
```

### Fingerprint Times Out Immediately

- Verify fingerprints are enrolled: `fprintd-list $USER`
- Re-enroll fingerprints: `fprintd-delete $USER && fprintd-enroll`
- Check reader permissions: `ls -l /dev/bus/usb/...`
- Review fprintd logs: `journalctl -u fprintd.service`

### Password Fallback Not Working

This indicates a serious PAM misconfiguration. Rollback immediately:

```bash
# Use most recent backup
sudo cp /etc/pam.d/system-login.bak.* /etc/pam.d/system-login

# Or restore Arch default
sudo cp /usr/share/factory/etc/pam.d/system-login /etc/pam.d/system-login
```

Then examine the PAM configuration:

```bash
cat /etc/pam.d/system-login
```

Ensure these lines exist:
```
auth       sufficient pam_fprintd.so max-tries=3 timeout=30
auth       include    system-auth
```

The `include system-auth` line MUST be present for password fallback.

### SSH Fingerprint Authentication (Known Issue)

Fingerprint authentication over SSH is **not recommended** due to technical limitations:
- Requires X11/Wayland forwarding (security risk)
- Physical reader must be on remote machine (impractical)
- High latency makes fingerprint verification unreliable

For SSH authentication, use:
- SSH keys (already configured via local-bootstrapping)
- Password as fallback
- Hardware tokens (U2F/FIDO2)

## Technical Details

### PAM Chain Overview

When you log in via SDDM, the PAM authentication chain is:

```
SDDM login → /etc/pam.d/sddm
             ↓
             includes system-login
             ↓
             auth sufficient pam_fprintd.so    ← Try fingerprint first
             ↓ (if fails or times out)
             includes system-auth
             ↓
             auth required pam_unix.so         ← Password fallback
```

### PAM Module Configuration

```
auth       sufficient pam_fprintd.so max-tries=3 timeout=30
```

- **auth** - Authentication phase (not account/session/password)
- **sufficient** - If succeeds, skip remaining auth modules (fast login)
- **sufficient** - If fails, continue to next module (password fallback)
- **max-tries=3** - Allow 3 fingerprint scan attempts
- **timeout=30** - Wait 30 seconds before falling back to password

### Why `system-login` Instead of `sddm`?

We modify `/etc/pam.d/system-login` rather than `/etc/pam.d/sddm` because:

1. **Broader coverage** - Affects SDDM, TTY login, and future login methods
2. **Consistency** - Single configuration point for all login types
3. **Simplicity** - One PAM file instead of multiple
4. **Maintainability** - System updates less likely to conflict

The downside is that TTY login also gets fingerprint auth, but this is a **feature** rather than a bug.

### systemd Timing Fix: fprintd Must Start Before SDDM

**The Problem:**

During initial implementation, PAM was correctly configured but fingerprint authentication didn't work at login. Investigation revealed a race condition:

```
04:16:40 - SDDM starts and tries PAM authentication
04:16:40 - pam_fprintd.so tries to contact fprintd via D-Bus
04:16:40 - fprintd NOT RUNNING YET → fingerprint fails → password-only screen
04:17:38 - fprintd finally starts (58 seconds too late)
```

**Why This Happens:**

- `fprintd.service` is Type=dbus (D-Bus activated)
- It's configured as "static" (not auto-enabled at boot)
- SDDM authentication happens before fprintd has started
- When PAM tries to use fingerprint, fprintd isn't available

**The Solution:**

Create a systemd drop-in that makes SDDM wait for fprintd:

```ini
# /etc/systemd/system/sddm.service.d/fprintd.conf
[Unit]
Wants=fprintd.service
After=fprintd.service
```

This ensures fprintd is running BEFORE SDDM tries to authenticate.

**Deployment:**

The setup script automatically:
1. Deploys the drop-in to `/etc/systemd/system/sddm.service.d/fprintd.conf`
2. Runs `systemctl daemon-reload` to pick up the change
3. Verifies the drop-in is correctly installed

**Verification:**

```bash
# Check drop-in is deployed
ls /etc/systemd/system/sddm.service.d/fprintd.conf

# View SDDM service dependencies
systemctl show sddm.service | grep -E 'Wants|After'

# Should show:
# Wants=fprintd.service ...
# After=fprintd.service ...
```

This fix ensures fingerprint authentication is available immediately at the login screen, not just after the system has been running for a minute.

### Device Detection Logic

The setup script uses two hardware detection methods:

```bash
# Method 1: Check for battery (laptop indicator)
if [[ -d /sys/class/power_supply/BAT0 ]]; then
    # Laptop detected, proceed with setup
fi

# Method 2: Check for fingerprint reader directly
if lsusb | grep -iq fingerprint; then
    # Reader detected, proceed with setup
fi

# Method 3: Check fprintd device list
if fprintd-list "$USER" &>/dev/null 2>&1; then
    # fprintd can see reader, proceed
fi
```

On desktop machines (no battery, no reader), the setup script exits gracefully without making changes.

### Performance Impact

Fingerprint authentication adds minimal overhead:
- **Cold boot:** <100ms to initialize fprintd service
- **Authentication:** ~50-200ms per scan
- **Timeout wait:** 30 seconds if finger not placed

Password fallback has the same performance as before (no change).

## Files Modified

### Repository Files (Git-Tracked)

- `system/pam.d/system-login` - PAM config with fprintd enabled
- `system/systemd/sddm.service.d/fprintd.conf` - systemd drop-in for timing fix
- `scripts/setup-fingerprint-auth.sh` - Setup script with safety checks
- `scripts/install.sh` - Integration into main bootstrap script
- `docs/fingerprint-auth.md` - This documentation
- `README.md` - Feature list updated

### System Files (Deployment Targets)

- `/etc/pam.d/system-login` - Deployed PAM configuration
- `/etc/pam.d/system-login.bak.*` - Timestamped backups
- `/etc/systemd/system/sddm.service.d/fprintd.conf` - systemd drop-in (timing fix)

## Related Documentation

- [PAM Configuration Guide](https://wiki.archlinux.org/title/PAM)
- [fprintd Documentation](https://fprint.freedesktop.org/)
- [SDDM Configuration](https://wiki.archlinux.org/title/SDDM)
- [local-bootstrapping README](../README.md)

## Future Enhancements (Not Implemented)

- **Multi-factor authentication** - Require both fingerprint AND password
- **Automated enrollment** - Script to guide fingerprint enrollment during setup
- **U2F hardware keys** - Add support for YubiKey/hardware tokens
- **Auth attempt monitoring** - Log failed authentication attempts
- **Remote fingerprint auth** - Research feasibility for SSH

## Support

If you encounter issues:

1. Check this documentation's troubleshooting section
2. Review setup script output for error messages
3. Examine PAM logs: `journalctl -u fprintd.service`
4. Verify enrollment: `fprintd-list $USER`
5. Test rollback procedure before rebooting

**Remember:** Password fallback is always available. You can't lock yourself out by enabling fingerprint authentication.
