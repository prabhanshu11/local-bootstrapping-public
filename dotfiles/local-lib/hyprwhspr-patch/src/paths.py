"""
Path definitions for hyprwhspr patch modules.
"""
import os
from pathlib import Path

# Configuration directory
home = Path.home()
xdg_config = Path(os.environ.get('XDG_CONFIG_HOME', home / '.config'))
HYPRWHSPR_CONFIG_DIR = xdg_config / 'hyprwhspr'

# Recording status file (written by hyprwhspr during recording)
RECORDING_STATUS_FILE = HYPRWHSPR_CONFIG_DIR / 'recording_status'

# MIC OSD PID file (written by mic-osd daemon)
MIC_OSD_PID_FILE = HYPRWHSPR_CONFIG_DIR / 'mic_osd.pid'
