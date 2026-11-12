"""
Pytest configuration and shared fixtures for local-bootstrapping tests.
"""

import subprocess
from pathlib import Path
import pytest


REPO_ROOT = Path(__file__).parent.parent


def detect_device_type():
    """Detect if running on desktop or laptop."""
    # Check Tailscale IP
    result = subprocess.run(
        ["tailscale", "ip", "-4"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        ip = result.stdout.strip()
        if ip == "100.64.0.1":
            return "desktop"
        elif ip == "100.64.0.2":
            return "laptop"

    # Fallback: battery presence
    if Path("/sys/class/power_supply/BAT0").exists():
        return "laptop"
    return "desktop"


@pytest.fixture(scope="session")
def device_type():
    """Current device type (desktop/laptop)."""
    return detect_device_type()


@pytest.fixture(scope="session")
def repo_root():
    """Path to local-bootstrapping repo."""
    return REPO_ROOT


@pytest.fixture(scope="session")
def dotfiles_path(repo_root):
    """Path to dotfiles directory."""
    return repo_root / "dotfiles"


@pytest.fixture
def home_dir():
    """User home directory."""
    return Path.home()


@pytest.fixture(scope="session")
def expected_symlinks():
    """Parse SYMLINKS from install.sh."""
    install_script = REPO_ROOT / "scripts" / "install.sh"
    content = install_script.read_text()

    # Extract SYMLINKS array
    symlinks = []
    in_array = False
    for line in content.split('\n'):
        if 'SYMLINKS=(' in line:
            in_array = True
            continue
        if in_array:
            if ')' in line:
                break
            line = line.strip().strip('"')
            if ':' in line and not line.startswith('#'):
                src, dst = line.split(':', 1)
                symlinks.append((src.strip(), dst.strip()))

    return symlinks


def pytest_collection_modifyitems(config, items):
    """Skip tests based on device type."""
    current_device = detect_device_type()

    for item in items:
        # Skip device-specific tests
        if "desktop" in item.keywords and current_device != "desktop":
            item.add_marker(pytest.mark.skip(reason="desktop-only test"))
        if "laptop" in item.keywords and current_device != "laptop":
            item.add_marker(pytest.mark.skip(reason="laptop-only test"))
