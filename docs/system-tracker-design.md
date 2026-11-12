# System Modification Tracker - Design Document

## Overview

A CLI tool to programmatically detect, track, and report system modifications from vanilla Omarchy. Enables automatic discovery of changes that should be added to local-bootstrapping.

## Problem Statement

Currently, tracking system modifications requires manual inspection and memory. We need:
1. Automatic detection of what's changed from vanilla Omarchy
2. Categorization of changes (packages, configs, services, visual, etc.)
3. Diff generation for config files
4. Integration with local-bootstrapping for easy sync

## Core Features

### 1. Package Tracking

**Query Method:**
```bash
# Current explicitly installed packages
pacman -Qe | awk '{print $1}' | sort > /tmp/current.txt

# Compare against Omarchy baseline
comm -23 /tmp/current.txt ~/.local/share/omarchy-tracker/baseline-packages.txt
```

**Data Sources:**
- `pacman -Qe` - explicitly installed
- `pacman -Qm` - AUR packages
- Baseline from fresh Omarchy ISO or documented package list

**Output:**
```json
{
  "added": ["hyprwhspr", "tailscale", "pass"],
  "removed": ["nano", "vim"],
  "aur": ["hyprwhspr"]
}
```

### 2. Config File Tracking

**Query Method:**
```bash
# Hash current configs
sha256sum ~/.config/hypr/input.conf > current_hashes.txt

# Compare against baseline hashes
diff baseline_hashes.txt current_hashes.txt
```

**Tracked Locations:**
| Path | Category | Baseline Source |
|------|----------|-----------------|
| `~/.config/hypr/*.conf` | Input/Bindings | Omarchy defaults |
| `~/.config/waybar/*` | Visual | Omarchy defaults |
| `~/.config/hyprwhspr/*` | Services | Package defaults |
| `~/.bashrc`, `~/.config/bashrc.d/*` | Shell | Omarchy defaults |
| `~/.config/systemd/user/*` | Services | Empty baseline |
| `/etc/systemd/system/*` | System services | Empty baseline |
| `/boot/loader/*` | Bootloader | Omarchy defaults |

**Output:**
```json
{
  "modified": [
    {
      "file": "~/.config/hypr/input.conf",
      "category": "input",
      "diff_lines": 3,
      "changes": ["removed compose:caps from kb_options"]
    }
  ],
  "new": [
    {
      "file": "~/.config/hyprwhspr/config.json",
      "category": "services"
    }
  ]
}
```

### 3. Service Tracking

**Query Method:**
```bash
# User services
systemctl --user list-unit-files --state=enabled --no-legend

# System services (beyond defaults)
systemctl list-unit-files --state=enabled --no-legend | \
  grep -v "^$(cat /usr/lib/systemd/system-preset/*.preset | grep enable | awk '{print $2}')"
```

**Output:**
```json
{
  "user_services": {
    "enabled": ["hyprwhspr.service", "voice-gateway.service"],
    "custom_units": ["voice-gateway.service"]
  },
  "system_services": {
    "enabled": ["tailscaled.service"],
    "disabled": []
  }
}
```

### 4. Visual/Theme Tracking

**Query Method:**
```bash
# GTK theme
gsettings get org.gnome.desktop.interface gtk-theme

# Icon theme
gsettings get org.gnome.desktop.interface icon-theme

# Cursor theme
gsettings get org.gnome.desktop.interface cursor-theme

# Waybar config hash
sha256sum ~/.config/waybar/config.jsonc
```

**Output:**
```json
{
  "gtk_theme": "adw-gtk3-dark",
  "icon_theme": "Papirus-Dark",
  "cursor_theme": "Bibata-Modern-Classic",
  "waybar": {
    "modified": true,
    "diff": "Added voice typing indicator, keyboard-layout module"
  }
}
```

### 5. Bootloader Tracking

**Query Method:**
```bash
# systemd-boot
cat /boot/loader/loader.conf
ls /boot/loader/entries/

# GRUB (if used)
cat /etc/default/grub | grep -v "^#" | grep -v "^$"
```

**Output:**
```json
{
  "bootloader": "systemd-boot",
  "timeout": 3,
  "default": "arch.conf",
  "entries": ["arch.conf", "arch-fallback.conf"],
  "modifications": []
}
```

### 6. Power Management

**Query Method:**
```bash
# Power profile
powerprofilesctl get

# TLP (if installed)
tlp-stat -s 2>/dev/null

# Suspend/hibernate config
cat /etc/systemd/sleep.conf | grep -v "^#" | grep -v "^$"
```

**Output:**
```json
{
  "profile": "balanced",
  "tlp_installed": false,
  "hibernate_enabled": true,
  "suspend_then_hibernate": false
}
```

## Architecture

### CLI Tool Structure

```
omarchy-tracker/
├── src/
│   ├── main.py              # Entry point
│   ├── collectors/
│   │   ├── packages.py      # Package diff
│   │   ├── configs.py       # Config file tracking
│   │   ├── services.py      # Systemd services
│   │   ├── visual.py        # Themes, waybar
│   │   ├── bootloader.py    # Boot config
│   │   └── power.py         # Power management
│   ├── baseline/
│   │   ├── packages.txt     # Vanilla Omarchy packages
│   │   ├── config_hashes/   # Default config hashes
│   │   └── services.txt     # Default enabled services
│   └── output/
│       ├── json.py          # JSON output
│       ├── markdown.py      # Markdown report
│       └── bootstrap.py     # local-bootstrapping integration
├── data/
│   └── omarchy-baseline/    # Baseline data from fresh install
└── tests/
```

### Usage

```bash
# Full scan
omarchy-tracker scan

# Specific category
omarchy-tracker scan --category packages
omarchy-tracker scan --category configs

# Output formats
omarchy-tracker scan --format json
omarchy-tracker scan --format markdown
omarchy-tracker scan --format bootstrap  # Update local-bootstrapping

# Interactive mode
omarchy-tracker interactive
# Shows changes, asks: "Add to local-bootstrapping? [y/n]"

# Diff against another machine
omarchy-tracker diff laptop
# Uses Tailscale to compare with laptop's state
```

### Integration with local-bootstrapping

```bash
# Auto-generate dotfiles from current state
omarchy-tracker export --to ~/Programs/local-bootstrapping/dotfiles/

# Update CLAUDE.md pending table
omarchy-tracker update-pending

# Check what's tracked vs untracked
omarchy-tracker status
```

## Baseline Creation

To create baseline data from a fresh Omarchy install:

```bash
# On fresh Omarchy install
omarchy-tracker create-baseline

# Captures:
# - Package list (pacman -Qe)
# - Config file hashes
# - Default services
# - Theme settings
# - Bootloader config
```

Store baseline in `~/.local/share/omarchy-tracker/baseline/` or in the repo.

## Implementation Priority

### Phase 1: Core Detection (MVP)
1. Package diff (pacman -Qe comparison)
2. Config file hash tracking for hypr, waybar
3. User service detection
4. JSON output

### Phase 2: Enhanced Tracking
5. Visual/theme detection
6. Bootloader config
7. Power management
8. Markdown report output

### Phase 3: Integration
9. local-bootstrapping export
10. CLAUDE.md auto-update
11. Cross-machine diff via Tailscale
12. Interactive mode

## Technology Choices

- **Language**: Python (uv for package management)
- **Config**: TOML for tool configuration
- **Output**: JSON primary, Markdown for reports
- **Storage**: SQLite for historical tracking (optional)

## Example Output

```
$ omarchy-tracker scan

╔═══════════════════════════════════════════════════════════╗
║              Omarchy System Modification Report            ║
╚═══════════════════════════════════════════════════════════╝

📦 PACKAGES (3 added, 1 removed)
  + hyprwhspr (AUR)
  + tailscale
  + pass
  - nano

⚙️  CONFIGS (2 modified, 1 new)
  ~ ~/.config/hypr/input.conf
    └─ Removed compose:caps from kb_options
  ~ ~/.config/waybar/config.jsonc
    └─ Added voice typing indicator
  + ~/.config/hyprwhspr/config.json (new)

🔧 SERVICES (2 user services)
  + hyprwhspr.service (enabled)
  + tailscaled.service (system, enabled)

🎨 VISUAL (no changes from default)

⚡ POWER
  Profile: balanced

════════════════════════════════════════════════════════════
📋 Not in local-bootstrapping:
  - ~/.config/hyprwhspr/config.json
  - hyprwhspr-toggle script

Run: omarchy-tracker export --to local-bootstrapping
```

## Questions to Resolve

1. **Baseline source**: Fresh ISO package list, or snapshot from clean install?
2. **Config diff granularity**: Line-by-line diff or just modified/not?
3. **Historical tracking**: Store state over time in SQLite?
4. **Auto-commit**: Should export to local-bootstrapping auto-commit changes?
