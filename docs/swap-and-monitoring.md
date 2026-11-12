# SSD Swap & Freeze Monitoring

System memory management and freeze diagnosis for Omarchy.

## Problem

Omarchy ships with **zram-only swap** (4GB compressed RAM). Under heavy load:
1. Memory fills up
2. zram swap fills up
3. OOM killer activates → kills random processes
4. System freezes for 2-3 minutes
5. Even TTY becomes unresponsive (GPU driver stalls)

## Solution

Two-part fix:

### 1. Freeze Monitor Service

Continuous metrics logging that captures system state before freezes:
- Memory/swap usage
- CPU and I/O wait
- GPU utilization and temperature
- Top memory/CPU consumers
- Anomaly detection (high memory, swap, I/O wait)

After a freeze, run the analysis script to see what happened.

### 2. SSD Swap File

Add 8GB swap file on SSD as overflow when zram fills:

```
/dev/zram0  4GB   priority 100  (fast, compressed RAM)
swapfile1   8GB   priority 10   (SSD overflow)
```

This gives the system room to breathe instead of immediately OOM-killing.

## Setup

```bash
./scripts/setup-swap-and-monitoring.sh
```

This will:
1. Install the systemd user service
2. Optionally set up SSD swap (requires sudo)

## Files

| Location | Purpose |
|----------|---------|
| `~/Programs/utilities/freeze-monitor/` | Main tool |
| `~/.config/systemd/user/freeze-monitor.service` | Service file |
| `/var/swap/swapfile1` | SSD swap (8GB) |

## Usage

### After a Freeze

```bash
~/Programs/utilities/freeze-monitor/analyze-freeze.sh
```

This generates a report showing:
- OOM killer activity
- GPU errors
- Memory/swap anomalies
- Logging gaps (freeze duration)
- Metrics before the freeze

### Service Management

```bash
systemctl --user status freeze-monitor   # Check status
systemctl --user restart freeze-monitor  # Restart
journalctl --user -u freeze-monitor -f   # Live logs
```

### Manual Swap Management

```bash
swapon --show           # View current swap
free -h                 # Memory overview
sudo swapoff /var/swap/swapfile1  # Disable SSD swap
sudo swapon -p 10 /var/swap/swapfile1  # Re-enable
```

## Configuration

Edit `~/Programs/utilities/freeze-monitor/freeze-monitor.sh`:

```bash
INTERVAL=3                    # Seconds between samples
ANOMALY_MEM_PERCENT=90       # Memory warning threshold
ANOMALY_SWAP_PERCENT=85      # Swap warning threshold
ANOMALY_IOWAIT_PERCENT=30    # I/O wait warning threshold
```

## btrfs Notes

The swap file requires special handling on btrfs:
- `nocow` attribute must be set before file creation
- `safe-swap-setup.sh` handles this automatically
- Creates btrfs snapshot before making changes

## Recovery

If swap setup breaks boot (unlikely):

1. Boot to TTY3 (`Ctrl+Alt+F3`)
2. Remove fstab entry: `sudo sed -i '/swapfile1/d' /etc/fstab`
3. Reboot

Or restore btrfs snapshot:
```bash
mount -o subvol=/ /dev/mapper/root /mnt
mv /mnt/@ /mnt/@.broken
mv /mnt/@snapshots/pre-swap-setup-* /mnt/@
reboot
```

## Related

- `~/Programs/utilities/freeze-monitor/ANALYSIS.md` - Detailed analysis guide
- `~/Programs/utilities/freeze-monitor/MEMORY-MANAGEMENT-DESIGN.md` - Future Claude Code hooks design
