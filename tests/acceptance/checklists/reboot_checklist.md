# Post-Reboot Verification Checklist

**Device**: _____________
**Date**: _____________
**Reboot Reason**: _____________

## Automated Tests (run first)

```bash
cd ~/Programs/local-bootstrapping
pytest tests/acceptance/test_post_reboot.py -v -m reboot
```

- [ ] All automated tests pass

## Visual Verification

### Waybar
- [ ] Waybar visible and rendering
- [ ] All icons present (compare to baseline screenshot)
- [ ] Sunshine icon state: _______ (ok/inactive/error)
- [ ] Moonlight icon state: _______ (ok/inactive/error)
- [ ] Clock shows correct time
- [ ] Network icon shows connected
- [ ] CPU/memory indicators working

### Screenshot Comparison
```bash
# Capture post-reboot screenshot
timestamp=$(date +%Y%m%d-%H%M%S)
tmpfile="/tmp/waybar-full-${timestamp}.png"
grim "$tmpfile"
magick "$tmpfile" -crop "2560x40+0+0" \
  "tests/visual/screenshots/post-reboot-waybar-${timestamp}.png"
rm "$tmpfile"

# Compare visually or with vision API
```

- [ ] Post-reboot screenshot captured
- [ ] Screenshots match (no missing icons)

## Service Health

### Core Services
```bash
systemctl --user status clipboard-health.timer
systemctl --user status sunshine-health.timer  # desktop
systemctl --user status moonlight-health.timer # laptop
```

- [ ] clipboard-health.timer: active
- [ ] sunshine-health.timer: active (desktop only)
- [ ] moonlight-health.timer: active (laptop only)

### Network
```bash
tailscale status
ping -c3 100.64.0.1  # desktop IP (from laptop)
ping -c3 100.64.0.2  # laptop IP (from desktop)
```

- [ ] Tailscale connected
- [ ] Can ping other device

## Functionality Spot Checks

### Voice Typing
- [ ] Super+CapsLock triggers hyprwhspr
- [ ] Voice indicator appears in waybar

### Clipboard
- [ ] Copy/paste works between apps
- [ ] clipboard-health script runs: `clipboard-health --status`

### Streaming (if applicable)
- [ ] Desktop: Sunshine accessible at https://localhost:47990
- [ ] Laptop: Can connect via Super+Shift+S
- [ ] Laptop: Super+Escape exits passthrough mode

### SSH
- [ ] SSH to other device works: `ssh desktop` or `ssh laptop`
- [ ] No password prompt (key auth working)

## Performance

- [ ] Desktop responsive within 30 seconds of login
- [ ] No unexpected high CPU/memory usage
- [ ] No error notifications on screen

## Issues Found

_List any problems, warnings, or anomalies:_

1.
2.
3.

---

## Result

- [ ] **PASS** - All checks passed, system fully recovered
- [ ] **PARTIAL** - Some issues but system usable (document above)
- [ ] **FAIL** - Critical issues, system not operational

**Time to Full Recovery**: _____ seconds/minutes
**Test Duration**: _____ minutes

---

## Notes

_Additional observations or context:_




---

**Checklist completed by**: _____________
**Signature**: _____________ (for official test runs)
