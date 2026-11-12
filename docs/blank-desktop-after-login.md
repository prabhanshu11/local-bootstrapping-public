# Blank Desktop After Login

## Incident History

### Incident #1: Python 3.13 → 3.14 Upgrade (2026-02-16)

| Field | Value |
|-------|-------|
| **Date** | 2026-02-16 |
| **Status** | RESOLVED (2026-02-16) |
| **Severity** | CRITICAL — user locked out of desktop |
| **Machine** | Laptop (ThinkPad T14 Gen 1) |
| **Reported by** | User via Claude Code (session `00000000-0000-4000-8000-000000000000`) |

### Incident #2: Hyprland Config Errors + Terminal Hang (2026-02-17)

| Field | Value |
|-------|-------|
| **Date** | 2026-02-17 00:27 UTC |
| **Status** | RESOLVED (2026-02-17 00:33) — user intervention |
| **Severity** | HIGH — desktop boots but terminal hung |
| **Machine** | Desktop |
| **Reported by** | User via Claude Code (laptop session) |
| **Recovery method** | Ctrl+C in hung terminal |
| **Screenshots** | `docs/screenshots/desktop-boot-issue-*.png` |

## Problem

After the login screen (greetd/tuigreet), the desktop is blank/black. The user cannot get into the desktop environment. The login screen itself works — authentication succeeds — but the compositor/desktop session fails to render anything usable afterward.

## Possible Causes to Investigate

### 1. swaybg not starting (MOST LIKELY — prior incident)

On 2026-02-07, a similar blank desktop occurred when `pcmanfm-qt --desktop` killed swaybg. However, that was just the wallpaper — Hyprland itself was still running (windows, keybindings worked). If this current issue is **completely** blank (no waybar, no windows, no keybindings), then swaybg alone is NOT the cause.

See: `docs/known-issues.md` → "swaybg Killed by Desktop Manager Conflicts"

**Check:**
```bash
pgrep -a swaybg
pgrep -a hyprland
```

### 2. Hyprland not launching or crashing after login

If the Hyprland compositor itself crashes, nothing will render.

**Check:**
```bash
# Check if Hyprland is running
pgrep -a Hyprland

# Check Hyprland crash logs
journalctl --user -u hyprland -b -n 100
cat ~/.local/share/hyprland/hyprland.log

# Check for coredumps
coredumpctl list --since today
```

### 3. uwsm session manager issue

Omarchy uses `uwsm` (Universal Wayland Session Manager) to manage the Hyprland session. If uwsm fails to start the session properly, the compositor may not launch.

**Check:**
```bash
journalctl --user -u wayland-wm@Hyprland.service -b -n 100
systemctl --user status wayland-wm@Hyprland.service
```

### 4. GPU driver issue (nvidia env vars, kernel update)

A kernel update may have broken GPU driver compatibility. NVIDIA drivers are especially fragile across kernel updates.

**Check:**
```bash
# Check kernel version vs installed nvidia modules
uname -r
pacman -Q linux nvidia nvidia-utils

# Check for GPU errors
dmesg | grep -i -E "nvidia|gpu|drm|error"
journalctl -b -k | grep -i -E "nvidia|gpu|drm"

# Check if nvidia module loaded
lsmod | grep nvidia
```

### 5. Wayland/display server not starting

The Wayland display server itself may fail to initialize.

**Check:**
```bash
# Check XDG_RUNTIME_DIR
ls -la $XDG_RUNTIME_DIR/wayland-*

# Check for Wayland socket
echo $WAYLAND_DISPLAY
```

### 6. Login manager (greetd/tuigreet) passing control but compositor fails

greetd successfully authenticates, starts the session command, but the compositor command fails silently.

**Check:**
```bash
# Check greetd configuration
cat /etc/greetd/config.toml

# Check greetd logs
journalctl -u greetd -b -n 100

# Check what command greetd is supposed to launch
grep -i command /etc/greetd/config.toml
```

### 7. Hyprland config syntax error

A config file change (manual or automated) could introduce a syntax error that prevents Hyprland from starting or rendering.

**Check:**
```bash
# Validate hyprland config (from TTY)
Hyprland -c ~/.config/hypr/hyprland.conf --check 2>&1

# Check for recent config changes
cd ~/.config/hypr && git diff 2>/dev/null || ls -lt *.conf | head -10
```

### 8. Recent system update broke something

A `pacman -Syu` may have updated a critical package.

**Check:**
```bash
# Check recent package updates
grep -i "upgraded\|installed\|removed" /var/log/pacman.log | tail -30

# Check if a recent update happened today
grep "$(date +%Y-%m-%d)" /var/log/pacman.log
```

## Diagnosis Steps (Run Once Access is Regained)

### Step 1: Get access via TTY or SSH

```bash
# Option A: Switch to TTY
# Press Ctrl+Alt+F2 (or F3, F4, etc.) to get a text console
# Login with username and password

# Option B: SSH from laptop
ssh desktop  # Uses Tailscale
```

### Step 2: Collect system state

Run these commands and save output:

```bash
# Save all diagnostic info
mkdir -p ~/Programs/local-bootstrapping/logs
LOGFILE=~/Programs/local-bootstrapping/logs/blank-desktop-$(date +%Y%m%d-%H%M%S).log

{
  echo "=== Date ==="
  date

  echo "=== Kernel ==="
  uname -a

  echo "=== Recent pacman activity ==="
  grep "$(date +%Y-%m-%d)" /var/log/pacman.log 2>/dev/null || echo "No updates today"
  grep "$(date -d yesterday +%Y-%m-%d)" /var/log/pacman.log 2>/dev/null || echo "No updates yesterday"

  echo "=== Running processes ==="
  pgrep -a -l "hypr|sway|waybar|uwsm|greetd"

  echo "=== Hyprland log ==="
  journalctl --user -u hyprland -b -n 50 2>/dev/null || echo "No hyprland user journal"

  echo "=== uwsm session ==="
  systemctl --user status wayland-wm@Hyprland.service 2>/dev/null || echo "No uwsm service"

  echo "=== greetd log ==="
  journalctl -u greetd -b -n 50 2>/dev/null

  echo "=== GPU/DRM errors ==="
  dmesg | grep -i -E "nvidia|gpu|drm|error" | tail -20

  echo "=== Coredumps ==="
  coredumpctl list --since today 2>/dev/null || echo "No coredumps"

  echo "=== greetd config ==="
  cat /etc/greetd/config.toml 2>/dev/null

} > "$LOGFILE" 2>&1

echo "Diagnostics saved to $LOGFILE"
```

### Step 3: Attempt recovery

Based on diagnosis, try one of:

```bash
# If Hyprland is not running at all — restart it
uwsm start hyprland

# If swaybg is missing (wallpaper gone but desktop works)
hyprctl dispatch exec "uwsm-app -- swaybg -i ~/.config/omarchy/current/background -m fill"

# If nvidia driver mismatch — rebuild
sudo dkms autoinstall

# If config is broken — start with defaults
Hyprland -c /dev/null  # Minimal test
```

### Step 4: Document findings

Update this file with:
- Which cause was identified
- What the fix was
- Whether it needs a permanent solution in local-bootstrapping

## Recovery Approaches

| Method | How | When to Use |
|--------|-----|-------------|
| TTY login | `Ctrl+Alt+F2`, login with credentials | First attempt — always available |
| SSH from laptop | `ssh desktop` (Tailscale) | If TTY doesn't work or need full tooling |
| Journal from TTY | `journalctl -b -n 200` | Quick log check from console |
| Boot previous kernel | GRUB menu → Advanced → older kernel | If kernel update is suspected |
| Single user mode | Add `single` to kernel params in GRUB | Last resort for recovery |

## Related Issues
- `docs/known-issues.md` → "swaybg Killed by Desktop Manager Conflicts" (2026-02-07)
- MEMORY.md → MicOSD LD_PRELOAD segfault (nvidia env vars in systemd context)

## Resolution

**Root cause:** Python 3.13 → 3.14 upgrade left 106 packages with stale site-packages

A `pacman -Syu` upgraded Python from 3.13 to 3.14, but dependent packages were not rebuilt. This caused `uwsm` (the Wayland session manager) to fail immediately on login:

```
$ uwsm check may-start
ModuleNotFoundError: No module named 'xdg'   # python-pyxdg still in python3.13/site-packages
```

After fixing `pyxdg`, the next import failed:
```
ModuleNotFoundError: No module named 'dbus'   # python-dbus still in python3.13/site-packages
```

SDDM log showed the symptom clearly:
```
Session "/usr/share/wayland-sessions/hyprland-uwsm.desktop" selected, command: "uwsm start -- hyprland.desktop"
Auth: sddm-helper exited with 1
```

The session started and exited instantly because uwsm couldn't import its Python dependencies.

**Diagnosis path:**
1. `pgrep Hyprland` → not running
2. `echo $XDG_SESSION_TYPE` → `tty` (no Wayland session)
3. `journalctl -u sddm -b` → `sddm-helper exited with 1`
4. `uwsm check may-start` → `ModuleNotFoundError: No module named 'xdg'`
5. `python3 --version` → 3.14, but `pacman -Ql python-pyxdg` → installed in `python3.13/site-packages`

**Fix applied:**
```bash
# Find all packages still targeting Python 3.13
pacman -Qq | while read pkg; do
  pacman -Ql "$pkg" 2>/dev/null | grep -q "python3.13/site-packages" && echo "$pkg"
done
# → 106 packages

# Reinstall all (minus util-linux-libs which had a separate dep conflict)
sudo pacman -S --noconfirm <104 packages>
# python-sounddevice was AUR, excluded
# util-linux-libs excluded (needs full -Syu for util-linux dep)
```

**Prevention:**
- After any Python major version bump on Arch, run:
  ```bash
  pacman -Qq | while read pkg; do
    pacman -Ql "$pkg" 2>/dev/null | grep -q "python3.OLD/site-packages" && echo "$pkg"
  done | xargs sudo pacman -S --noconfirm
  ```
- Or ensure `pacman -Syu` completes fully — a partial upgrade likely caused this
- Consider adding a pacman hook to detect stale Python site-packages after upgrade

---

## Incident #2 Details: Hyprland Config Errors + Terminal Hang (2026-02-17)

**Symptoms:**
- Desktop booted successfully (Hyprland running, wallpaper visible)
- Terminal application hung/frozen with blank screen
- Red error messages at top of screen about Hyprland config issues:
  - "Config error in file:///home/prabhanshu/.conf at line 126: config status colors:new_window_takes_over_fullscreen does not exist"
  - Multiple errors about invalid values in `hyprwindows.conf`
  - Config value errors: "missing a value", "invalid values"

**User observation:**
> "the terminal is just a blank screen... doing ctrl+c is making it work"

**Recovery:**
- User pressed `Ctrl+C` in the hung terminal
- Terminal became responsive after Ctrl+C
- Desktop fully functional afterward

**Diagnosis:**
- Hyprland process was running (PID 2364, started 00:27)
- Config errors displayed but didn't prevent boot
- Terminal hung during startup (unknown process blocking)
- Ctrl+C killed the blocking process → terminal recovered

**Screenshots:**
1. `docs/screenshots/desktop-boot-issue-user-captured.png` - User's capture showing config errors and hung terminal
2. `docs/screenshots/desktop-boot-issue-full-screen.png` - Full desktop view with errors visible

**Root cause:** Hyprland 0.53.3 upgrade deprecated `windowrulev2` and made regex validation stricter

**Investigation (2026-02-17 continued):**

After initial Ctrl+C recovery, issue persisted and spread to laptop as well. Analysis revealed:

1. **Hyprland version:** 0.53.3 (released Jan 2026)
2. **Breaking changes in 0.53.3:**
   - `windowrulev2` syntax deprecated → use `windowrule` instead
   - Stricter regex validation → character classes like `[p|P]` invalid (pipe shouldn't be in brackets)
   - Config option removed: `new_window_takes_over_fullscreen`

3. **Affected files found:**
   - `bindings-streaming.conf` (local-bootstrapping) - windowrulev2 usage
   - `windowrules-mic-osd.conf` (local-bootstrapping) - windowrulev2 usage
   - `~/.local/share/omarchy/default/hypr/looknfeel.conf` - deprecated option
   - `~/.local/share/omarchy/default/hypr/apps/1password.conf` - regex `[p|P]`
   - `~/.local/share/omarchy/default/hypr/apps/system.conf` - regex `[F|f]`, `[C|c]`, `[open|save]`
   - Additional errors TBD from latest screenshots

4. **Both machines affected:**
   - Desktop: Errors on boot + terminal hang
   - Laptop: Config errors appearing during session
   - Same root cause (shared local-bootstrapping + Omarchy defaults)

**Fixes to be applied:**

See `docs/hyprland-0.53-migration.md` for complete migration guide and all syntax changes.

**Status:** ✅ RESOLVED (2026-02-17)

Desktop now booting cleanly with 0 config errors. See `docs/hyprland-0.53-migration.md` for complete details.

**Final fixes:**
- Disabled windowrules-mic-osd.conf (windowrule v1 syntax incompatible)
- Removed incompatible window rules from bindings-streaming.conf
- Fixed scrolltouchpad errors in input.conf
- Fixed regex syntax in Omarchy defaults (1password.conf, system.conf)

**Screenshots:**
- Desktop (initial): `docs/screenshots/desktop-boot-issue-*.png`
- Laptop: `docs/screenshots/laptop-hyprland-errors-2026-02-17.png`
- Desktop (resolved): `docs/screenshots/desktop-clean-boot-2026-02-17.png`
