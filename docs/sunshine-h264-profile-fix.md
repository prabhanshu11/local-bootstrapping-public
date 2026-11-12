# Sunshine H.264 Profile Compatibility Fix

## Problem
Moonlight connections from laptop to desktop were failing after ~1.5 minutes with frame drop errors. The root cause was H.264 encoding at High Profile (profile 100), which the laptop's VA API NVDEC decoders don't support.

### Symptoms
- Moonlight connection would start but fail after 1-2 minutes
- Logs showed "No support for codec h264 profile 100"
- Frame drops and "Reached consecutive drop limit" errors

## Solution
Configure Sunshine to use H.264 Main Profile (profile 1) instead of High Profile for better decoder compatibility.

### Configuration
Create or update `~/.config/sunshine/sunshine.conf`:

```ini
# Sunshine configuration for Moonlight streaming
# H.264 Main profile ensures compatibility with all Moonlight clients
# Profile 0 = Baseline, 1 = Main (recommended), 2 = High
nv_enc_h264_profile = 1

# Audio settings (optional)
audio_device = alsa_output.pci-0000_07_00.1.hdmi-stereo.monitor
```

### Implementation
After updating the config file, restart Sunshine:
```bash
systemctl --user restart sunshine
```

## Results
- Moonlight connections now establish successfully
- Streaming is stable and maintains full bitrate
- No more frame drop errors or connection timeouts

## Related Files
- `~/.config/sunshine/sunshine.conf` - Sunshine encoder configuration
- `~/.local/share/systemd/user/sunshine.service` - Service startup configuration

