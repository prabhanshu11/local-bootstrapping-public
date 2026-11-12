"""
Post-reboot verification tests.

Run after system reboot to verify all services recover correctly.
"""

import subprocess
import pytest


@pytest.mark.reboot
@pytest.mark.acceptance
def test_tailscale_connected():
    """Verify Tailscale reconnected after reboot."""
    result = subprocess.run(
        ["tailscale", "status"],
        capture_output=True, text=True
    )
    assert result.returncode == 0, "Tailscale not running"
    assert "offline" not in result.stdout.lower(), "Tailscale offline"


@pytest.mark.reboot
@pytest.mark.acceptance
def test_systemd_user_services_active(device_type):
    """Verify user services are active after reboot."""
    services = [
        "clipboard-health.timer",
    ]

    if device_type == "desktop":
        services.append("sunshine-health.timer")
        services.append("sunshine.service")
    elif device_type == "laptop":
        services.append("moonlight-health.timer")

    for service in services:
        result = subprocess.run(
            ["systemctl", "--user", "is-active", service],
            capture_output=True, text=True
        )
        assert result.returncode == 0, f"Service {service} not active"


@pytest.mark.reboot
@pytest.mark.acceptance
def test_waybar_running():
    """Verify waybar process is running."""
    result = subprocess.run(
        ["pgrep", "-x", "waybar"],
        capture_output=True
    )
    assert result.returncode == 0, "Waybar not running"


@pytest.mark.reboot
@pytest.mark.acceptance
def test_streaming_health_scripts_work(device_type):
    """Verify streaming-health scripts execute without error."""
    result = subprocess.run(
        ["streaming-health", "sunshine"],
        capture_output=True, text=True, timeout=5
    )
    assert result.returncode == 0, f"streaming-health sunshine failed: {result.stderr}"
    assert '"text"' in result.stdout, "streaming-health didn't return JSON"

    result = subprocess.run(
        ["streaming-health", "moonlight"],
        capture_output=True, text=True, timeout=5
    )
    assert result.returncode == 0, f"streaming-health moonlight failed: {result.stderr}"
    assert '"text"' in result.stdout, "streaming-health didn't return JSON"


@pytest.mark.reboot
@pytest.mark.acceptance
@pytest.mark.desktop
def test_sunshine_service_running():
    """Desktop: Verify Sunshine service is running."""
    result = subprocess.run(
        ["systemctl", "--user", "is-active", "sunshine"],
        capture_output=True, text=True
    )
    assert result.returncode == 0, "Sunshine service not active on desktop"


@pytest.mark.reboot
@pytest.mark.acceptance
def test_hyprland_bindings_loaded():
    """Verify Hyprland loaded streaming bindings."""
    result = subprocess.run(
        ["hyprctl", "binds"],
        capture_output=True, text=True
    )
    assert result.returncode == 0, "hyprctl binds failed"

    # Check for streaming-related bindings
    binds_output = result.stdout.lower()
    # Desktop status check should be bound
    assert "desktop status" in binds_output or "stream" in binds_output, \
        "Streaming bindings not loaded in Hyprland"
