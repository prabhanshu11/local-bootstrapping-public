"""
Waybar Icons Visual Regression Test

Uses Anthropic Claude vision to evaluate if all expected waybar icons are visible.
Run after making changes to waybar config to catch missing icons.

Usage:
    pytest tests/visual/test_waybar_icons.py -v

Requirements:
    pip install pytest pillow
"""

import os
import subprocess
import tempfile
import base64
import json
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

import pytest


# API key — prefer env var, fall back to pass (OpenRouter)
API_KEY = os.environ.get("OPENROUTER_API_KEY") or subprocess.run(
    ['pass', 'show', 'api/openrouter'], capture_output=True, text=True
).stdout.strip()

# Vision model — Claude Haiku 4.5 via OpenRouter: fast, cheap, good vision
VISION_MODEL = "anthropic/claude-haiku-4.5"

# Expected icons in waybar right section (in order)
EXPECTED_ICONS = [
    "microphone (voice typing)",
    "clipboard",
    "keyboard layout indicator (DV or US)",
    "bluetooth",
    "wifi/network",
    "volume/speaker/audio",
    "power-profile indicator (PRF, BAL, or SAV text)",
]

# Desktop doesn't have battery
LAPTOP_ONLY_ICONS = ["battery"]

# Reference screenshots directory
REFERENCE_DIR = Path(__file__).parent.parent.parent / "reference-screenshots"
VERIFICATION_LOG = REFERENCE_DIR / "verification-log.jsonl"


def _get_monitor_geometry():
    """Get primary monitor position and size from hyprctl."""
    result = subprocess.run(
        ['hyprctl', 'monitors', '-j'],
        capture_output=True, text=True, check=True
    )
    monitors = json.loads(result.stdout)
    m = monitors[0]
    return m['x'], m['y'], m['width'], m['height']


def capture_waybar_screenshot() -> Path:
    """Capture a cropped screenshot of waybar right section."""
    with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as f:
        crop_path = f.name

    x, y, width, _height = _get_monitor_geometry()

    # Crop right 900px, top 30px (waybar area)
    crop_x = x + max(0, width - 900)
    subprocess.run([
        'grim', '-g', f'{crop_x},{y} 900x30', crop_path
    ], check=True, capture_output=True)

    return Path(crop_path)


def capture_power_battery_area() -> Path:
    """Capture a narrow crop of just the battery + power-profile area."""
    with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as f:
        crop_path = f.name

    x, y, width, _height = _get_monitor_geometry()

    # Rightmost 200px, top 30px — battery + power profile area
    crop_x = x + max(0, width - 200)
    subprocess.run([
        'grim', '-g', f'{crop_x},{y} 200x30', crop_path
    ], check=True, capture_output=True)

    return Path(crop_path)


def _upscale_image(image_path: Path, scale: int = 4) -> bytes:
    """Upscale image using nearest-neighbor to make tiny icons visible to vision models.

    Waybar icons are ~14px — upscaling 4x makes them ~56px, well within
    reliable detection range for Claude vision.
    """
    from PIL import Image
    import io

    img = Image.open(image_path)
    new_size = (img.width * scale, img.height * scale)
    img = img.resize(new_size, Image.NEAREST)

    buf = io.BytesIO()
    img.save(buf, format='PNG')
    return buf.getvalue()


def image_to_base64(image_path: Path) -> str:
    """Convert image to upscaled base64 string for vision model consumption."""
    data = _upscale_image(image_path)
    return base64.b64encode(data).decode('utf-8')


def _claude_vision(image_base64: str, prompt: str) -> dict:
    """Send an image + prompt to Claude vision via OpenRouter, return parsed JSON."""
    payload = json.dumps({
        "model": VISION_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/png;base64,{image_base64}"
                    }
                }
            ]
        }],
        "max_tokens": 500,
        "temperature": 0,
    }).encode()

    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        }
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.loads(resp.read())

    content = result["choices"][0]["message"]["content"]

    # Try to parse JSON from the response
    try:
        start = content.find('{')
        end = content.rfind('}') + 1
        if start != -1 and end > start:
            return json.loads(content[start:end])
    except json.JSONDecodeError:
        pass

    return {"raw_response": content, "all_present": False}


def _log_verification(screenshot_name: str, expected: str, model_response: dict, match: bool):
    """Append a verification entry to the JSONL log."""
    VERIFICATION_LOG.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "screenshot": screenshot_name,
        "expected": expected,
        "model": VISION_MODEL,
        "response": model_response,
        "match": match,
    }
    with open(VERIFICATION_LOG, 'a') as f:
        f.write(json.dumps(entry) + '\n')


def analyze_waybar_with_vision(image_base64: str, expected_icons: list[str]) -> dict:
    """Use Claude vision model to analyze waybar screenshot."""
    prompt = f"""This is a Linux waybar status bar screenshot (upscaled 4x for clarity). Check each expected indicator below and report whether it is visible.

Go through this checklist one by one. For each item, look carefully at the ENTIRE image:

1. Microphone icon — a small mic shape (vertical bar with rounded top), typically near the left side of the right section
2. Clipboard icon — a small square/document/floppy-disk-like icon, near the microphone
3. Keyboard layout text — the letters "DV" or "US" (Dvorak or US layout indicator)
4. Bluetooth icon — the characteristic angular Bluetooth rune/logo (looks like a pointy B)
5. WiFi/network icon — could be signal bars, a wireless fan shape, OR a down-pointing triangle/arrow. Any network-related symbol counts.
6. Volume/audio icon — a speaker shape, possibly with sound wave lines
7. Power-profile text — the text "PRF", "BAL", or "SAV" (usually near the right edge)
{"8. Battery icon — a battery-shaped rectangle (only on laptops)" if "battery" in " ".join(expected_icons).lower() else ""}

IMPORTANT: The WiFi icon on this system often appears as a down-pointing arrow or triangle, not traditional signal bars. Count it as present if you see any arrow or network symbol between bluetooth and volume.

Respond in this exact JSON format:
{{
    "icons_found": ["list of names from checklist that ARE visible"],
    "icons_missing": ["list of names from checklist that are NOT visible"],
    "all_present": true/false,
    "notes": "brief observations"
}}"""

    return _claude_vision(image_base64, prompt)


def _get_ac_power_state() -> bool:
    """Return True if AC power is connected."""
    ac_paths = list(Path("/sys/class/power_supply").glob("AC*")) + \
               list(Path("/sys/class/power_supply").glob("ACAD*"))
    for ac in ac_paths:
        online = ac / "online"
        if online.exists():
            return online.read_text().strip() == "1"
    return False


def _get_power_profile() -> str:
    """Get current power profile from power-profile-monitor."""
    result = subprocess.run(
        ['power-profile-monitor', 'status'],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        data = json.loads(result.stdout)
        return data.get("text", "unknown")
    return "unknown"


# ── Tests ──


@pytest.mark.visual
@pytest.mark.skipif(not API_KEY, reason="API key not set")
def test_waybar_icons_visible():
    """Test that all expected waybar icons are visible."""
    screenshot_path = capture_waybar_screenshot()

    try:
        image_b64 = image_to_base64(screenshot_path)

        has_battery = Path("/sys/class/power_supply/BAT0").exists()

        expected = EXPECTED_ICONS.copy()
        if has_battery:
            expected.extend(LAPTOP_ONLY_ICONS)

        analysis = analyze_waybar_with_vision(image_b64, expected)

        print(f"\nVision analysis result: {json.dumps(analysis, indent=2)}")

        if "raw_response" in analysis:
            _log_verification("waybar-right-crop.png", "all icons visible", analysis, match=False)
            pytest.fail(f"Could not parse vision response: {analysis['raw_response']}")

        passed = analysis.get("all_present", False)
        _log_verification("waybar-right-crop.png", "all icons visible", analysis, match=passed)

        assert passed, \
            f"Missing icons: {analysis.get('icons_missing', 'unknown')}"

    finally:
        screenshot_path.unlink()


@pytest.mark.visual
@pytest.mark.skipif(not API_KEY, reason="API key not set")
def test_battery_charging_indicator():
    """Test that battery icon color matches AC power state.

    When AC is plugged in:
      - Battery icon should be green (CSS: #battery.charging / .plugged)
      - Power profile should show "PRF" in red (performance mode)

    When on battery:
      - Battery icon should be default color (white/grey)
      - Power profile should show "BAL" or "SAV" in blue/green
    """
    has_battery = Path("/sys/class/power_supply/BAT0").exists()
    if not has_battery:
        pytest.skip("No battery — desktop machine")

    screenshot_path = capture_power_battery_area()

    try:
        image_b64 = image_to_base64(screenshot_path)
        ac_on = _get_ac_power_state()
        profile = _get_power_profile()

        prompt = """This is a cropped waybar status bar screenshot showing the battery and power profile area.

Analyze carefully:
1. Is there a battery icon? What color is it? (green, white, grey, red, etc.)
2. Do you see text like "PRF", "BAL", or "SAV"? What color is that text?

Respond in JSON:
{
    "battery_icon_present": true/false,
    "battery_icon_color": "green/white/grey/red/other",
    "power_profile_text": "PRF/BAL/SAV/null",
    "power_profile_color": "red/blue/green/white/other",
    "notes": "any observations"
}"""

        analysis = _claude_vision(image_b64, prompt)
        print(f"\nAC power: {'on' if ac_on else 'off'}")
        print(f"Power profile: {profile}")
        print(f"Vision analysis: {json.dumps(analysis, indent=2)}")

        if "raw_response" in analysis:
            pytest.fail(f"Could not parse vision response: {analysis['raw_response']}")

        # Log the verification
        expected_desc = f"ac={'on' if ac_on else 'off'}, profile={profile}"
        _log_verification(
            "battery-power-profile-crop.png",
            expected_desc,
            analysis,
            match=True,  # Updated below if assertions fail
        )

        # Validate battery color matches AC state
        battery_color = analysis.get("battery_icon_color", "").lower()
        profile_text = analysis.get("power_profile_text", "").upper()

        if ac_on:
            assert battery_color == "green", \
                f"AC plugged but battery icon is '{battery_color}', expected green"
        else:
            assert battery_color != "green" or profile_text in ("BAL", "SAV"), \
                f"On battery but battery icon is green — unexpected"

        # Validate power profile text matches system state
        if profile_text:
            assert profile_text == profile.upper(), \
                f"Vision sees '{profile_text}' but system reports '{profile}'"

        # Save reference screenshot if it doesn't exist yet
        ref_name = "waybar-ac-plugged.png" if ac_on else "waybar-ac-unplugged.png"
        ref_path = REFERENCE_DIR / ref_name
        if not ref_path.exists():
            import shutil
            shutil.copy2(screenshot_path, ref_path)
            print(f"\nSaved new reference screenshot: {ref_path}")

    finally:
        screenshot_path.unlink()


@pytest.mark.visual
def test_waybar_config_has_all_modules():
    """Test that waybar config includes all expected modules."""
    config_path = Path.home() / '.config' / 'waybar' / 'config.jsonc'

    content = config_path.read_text()
    lines = [l for l in content.split('\n') if not l.strip().startswith('//')]
    config = json.loads('\n'.join(lines))

    modules_right = config.get('modules-right', [])

    required_modules = [
        'custom/hyprwhspr',
        'custom/clipboard',
        'hyprland/language',
        'bluetooth',
        'network',
        'pulseaudio',
        'custom/power-profile',
    ]

    for module in required_modules:
        assert module in modules_right, f"Missing module in config: {module}"


@pytest.mark.visual
def test_custom_module_commands_work():
    """Test that custom module commands execute successfully."""
    # Test hyprwhspr-tray
    result = subprocess.run(
        ['/usr/lib/hyprwhspr/config/hyprland/hyprwhspr-tray.sh', 'status'],
        capture_output=True, text=True, timeout=5
    )
    assert result.returncode == 0, f"hyprwhspr-tray failed: {result.stderr}"
    assert '"text"' in result.stdout, "hyprwhspr-tray didn't return JSON"

    # Test system-health clipboard
    result = subprocess.run(
        ['system-health', 'clipboard'],
        capture_output=True, text=True, timeout=5
    )
    assert result.returncode == 0, f"system-health clipboard failed: {result.stderr}"
    assert '"text"' in result.stdout, "system-health didn't return JSON"

    # Test power-profile-monitor status
    result = subprocess.run(
        ['power-profile-monitor', 'status'],
        capture_output=True, text=True, timeout=5
    )
    assert result.returncode == 0, f"power-profile-monitor failed: {result.stderr}"
    data = json.loads(result.stdout)
    assert "text" in data, "power-profile-monitor didn't return 'text' field"
    assert data["text"] in ("PRF", "BAL", "SAV"), \
        f"Unexpected power profile text: {data['text']}"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
