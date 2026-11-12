#!/usr/bin/env python3
"""
Waybar Widget Validator - Uses Claude Vision API to verify all widgets are present.

This validator:
- Takes a screenshot of the waybar
- Sends it to Claude with vision capabilities
- Gets a structured report on which widgets are present/missing
- Returns exit code 0 if all expected widgets present, 1 otherwise

Usage:
    ./waybar-validator.py                    # Validate current waybar
    ./waybar-validator.py --reference        # Save current as reference
    ./waybar-validator.py --compare REF      # Compare against reference image
    ./waybar-validator.py --list-widgets     # Show expected widgets
"""

import os
import sys
import json
import base64
import subprocess
import tempfile
from pathlib import Path
from datetime import datetime

# Try to import anthropic, fall back to claude CLI if not available
try:
    import anthropic
    HAS_ANTHROPIC = True
except ImportError:
    HAS_ANTHROPIC = False


def get_api_key() -> str:
    """Get Anthropic API key from env or pass"""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key

    # Try to get from pass
    try:
        result = subprocess.run(
            ["pass", "show", "anthropic/api_key"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass

    return None

# Paths
SCRIPT_DIR = Path(__file__).parent
REPO_DIR = SCRIPT_DIR.parent
REFERENCE_DIR = REPO_DIR / "reference-screenshots"
REPORT_DIR = Path("/tmp/waybar-validator")

# Expected widgets in order (from waybar config)
EXPECTED_WIDGETS = {
    "left": ["omarchy-logo", "workspaces"],
    "center": ["clock", "update-indicator", "screenrecording-indicator"],
    "right": [
        "telegram",      # Orange/yellow icon
        "datalake",      # Database icon
        "hyprwhspr",     # Microphone icon (grey=idle, red=recording)
        "sunshine",      # Streaming server icon
        "moonlight",     # Streaming client icon
        "clipboard",     # Clipboard icon
        "language",      # DV or US text
        "tray",          # System tray icons
        "bluetooth",     # Bluetooth icon
        "network",       # Wifi signal icon
        "pulseaudio",    # Volume icon
        "cpu",           # CPU icon
        "battery",       # Battery icon
    ]
}

# Widget descriptions for Claude
WIDGET_DESCRIPTIONS = """
Expected waybar widgets from left to right in the RIGHT section:
1. telegram - Orange/yellow square icon (Telegram bot status)
2. datalake - Database/storage icon
3. hyprwhspr - Microphone icon (grey when idle, red with waveform when recording)
4. sunshine - Streaming server icon (sun-like)
5. moonlight - Streaming client icon (moon-like)
6. clipboard - Clipboard/paste icon
7. language - Text showing "DV" or "US" for keyboard layout
8. tray - System tray area (may have various app icons)
9. bluetooth - Bluetooth icon
10. network - Wifi signal strength icon (bars)
11. pulseaudio - Speaker/volume icon
12. cpu - CPU/processor icon
13. battery - Battery level icon (may show percentage)
"""


def get_monitor_geometry():
    """Get primary monitor geometry for screenshot"""
    try:
        result = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True, text=True, timeout=5
        )
        monitors = json.loads(result.stdout)
        for m in monitors:
            # Find the primary/focused monitor
            if m.get("focused") or m.get("name") == "eDP-1":
                x, y = m["x"], m["y"]
                w, h = m["width"], m["height"]
                return f"{x},{y} {w}x40"  # Top 40px for waybar
        # Fallback to first monitor
        m = monitors[0]
        return f"{m['x']},{m['y']} {m['width']}x40"
    except Exception as e:
        print(f"Error getting monitor: {e}", file=sys.stderr)
        return "0,0 1920x40"  # Default fallback


def take_screenshot() -> Path:
    """Take a screenshot of the waybar and return the path"""
    REPORT_DIR.mkdir(parents=True, exist_ok=True)

    geometry = get_monitor_geometry()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    screenshot_path = REPORT_DIR / f"waybar_{timestamp}.png"

    try:
        subprocess.run(
            ["grim", "-g", geometry, str(screenshot_path)],
            check=True, capture_output=True, timeout=10
        )
        return screenshot_path
    except subprocess.CalledProcessError as e:
        print(f"Screenshot failed: {e.stderr.decode()}", file=sys.stderr)
        sys.exit(1)


def encode_image(image_path: Path) -> str:
    """Encode image to base64"""
    with open(image_path, "rb") as f:
        return base64.standard_b64encode(f.read()).decode("utf-8")


def analyze_with_claude_api(image_path: Path) -> dict:
    """Analyze screenshot using Anthropic Python SDK"""
    api_key = get_api_key()
    if not api_key:
        return {
            "error": "No API key found. Set ANTHROPIC_API_KEY or add to pass as anthropic/api_key",
            "all_present": False
        }
    client = anthropic.Anthropic(api_key=api_key)

    image_data = encode_image(image_path)

    prompt = f"""Analyze this waybar (status bar) screenshot and identify which widgets are present.

{WIDGET_DESCRIPTIONS}

For each widget, report:
- "present": true/false
- "notes": any observations (e.g., "red waveform visible" for recording mic)

Return a JSON object with this exact structure:
{{
  "widgets_found": {{
    "telegram": {{"present": true/false, "notes": "..."}},
    "datalake": {{"present": true/false, "notes": "..."}},
    "hyprwhspr": {{"present": true/false, "notes": "..."}},
    "sunshine": {{"present": true/false, "notes": "..."}},
    "moonlight": {{"present": true/false, "notes": "..."}},
    "clipboard": {{"present": true/false, "notes": "..."}},
    "language": {{"present": true/false, "notes": "..."}},
    "tray": {{"present": true/false, "notes": "..."}},
    "bluetooth": {{"present": true/false, "notes": "..."}},
    "network": {{"present": true/false, "notes": "..."}},
    "pulseaudio": {{"present": true/false, "notes": "..."}},
    "cpu": {{"present": true/false, "notes": "..."}},
    "battery": {{"present": true/false, "notes": "..."}}
  }},
  "summary": "Brief summary of what you see",
  "all_present": true/false,
  "missing": ["list", "of", "missing", "widgets"]
}}

Only return the JSON, no other text."""

    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1024,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": image_data,
                        },
                    },
                    {
                        "type": "text",
                        "text": prompt
                    }
                ],
            }
        ],
    )

    # Parse JSON from response
    response_text = response.content[0].text
    try:
        # Try to extract JSON if wrapped in markdown
        if "```json" in response_text:
            response_text = response_text.split("```json")[1].split("```")[0]
        elif "```" in response_text:
            response_text = response_text.split("```")[1].split("```")[0]
        return json.loads(response_text.strip())
    except json.JSONDecodeError:
        return {
            "error": "Failed to parse response",
            "raw_response": response_text,
            "all_present": False
        }


def analyze_with_claude_cli(image_path: Path) -> dict:
    """Use claude CLI with Read tool to analyze image (uses Max subscription)"""
    prompt = f"""Please analyze this waybar screenshot and identify which widgets are present.

Use the Read tool to read this image file: {image_path}

{WIDGET_DESCRIPTIONS}

After reading the image, return a JSON object with this exact structure (only the JSON, no other text):
{{
  "widgets_found": {{
    "telegram": {{"present": true/false, "notes": "..."}},
    "datalake": {{"present": true/false, "notes": "..."}},
    "hyprwhspr": {{"present": true/false, "notes": "..."}},
    "sunshine": {{"present": true/false, "notes": "..."}},
    "moonlight": {{"present": true/false, "notes": "..."}},
    "clipboard": {{"present": true/false, "notes": "..."}},
    "language": {{"present": true/false, "notes": "..."}},
    "tray": {{"present": true/false, "notes": "..."}},
    "bluetooth": {{"present": true/false, "notes": "..."}},
    "network": {{"present": true/false, "notes": "..."}},
    "pulseaudio": {{"present": true/false, "notes": "..."}},
    "cpu": {{"present": true/false, "notes": "..."}},
    "battery": {{"present": true/false, "notes": "..."}}
  }},
  "summary": "Brief summary of what you see",
  "all_present": true/false,
  "missing": ["list", "of", "missing", "widgets"]
}}"""

    try:
        # Use claude CLI with tools enabled, bypassing permissions for automation
        env = os.environ.copy()
        env.pop("ANTHROPIC_API_KEY", None)  # Force Max subscription

        result = subprocess.run(
            ["claude", "--print", "-p", prompt, "--dangerously-skip-permissions"],
            capture_output=True,
            text=True,
            timeout=120,
            env=env
        )

        if result.returncode != 0:
            return {
                "error": f"Claude CLI error: {result.stderr[:200]}",
                "all_present": False
            }

        response_text = result.stdout.strip()

        # Try to extract JSON from response
        try:
            if "```json" in response_text:
                response_text = response_text.split("```json")[1].split("```")[0]
            elif "```" in response_text:
                response_text = response_text.split("```")[1].split("```")[0]
            # Find JSON object in response
            start = response_text.find("{")
            end = response_text.rfind("}") + 1
            if start != -1 and end > start:
                response_text = response_text[start:end]
            return json.loads(response_text.strip())
        except json.JSONDecodeError:
            return {
                "error": "Failed to parse JSON from Claude response",
                "raw_response": result.stdout[:500],
                "all_present": False
            }

    except subprocess.TimeoutExpired:
        return {"error": "Claude CLI timed out", "all_present": False}
    except Exception as e:
        return {"error": f"Claude CLI error: {e}", "all_present": False}


def validate_waybar() -> dict:
    """Main validation function"""
    print("Taking waybar screenshot...", file=sys.stderr)
    screenshot = take_screenshot()
    print(f"Screenshot saved: {screenshot}", file=sys.stderr)

    # Prefer API if key available, otherwise use CLI with Max subscription
    api_key = get_api_key()
    if HAS_ANTHROPIC and api_key:
        print("Analyzing with Claude Vision API...", file=sys.stderr)
        result = analyze_with_claude_api(screenshot)
    else:
        print("Analyzing with Claude CLI (Max subscription)...", file=sys.stderr)
        result = analyze_with_claude_cli(screenshot)

    # Save report
    report_path = REPORT_DIR / f"report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    result["screenshot"] = str(screenshot)
    result["timestamp"] = datetime.now().isoformat()

    with open(report_path, "w") as f:
        json.dump(result, f, indent=2)

    print(f"Report saved: {report_path}", file=sys.stderr)

    return result


def save_reference():
    """Save current waybar as reference"""
    REFERENCE_DIR.mkdir(parents=True, exist_ok=True)

    screenshot = take_screenshot()

    # Copy to reference directory
    ref_path = REFERENCE_DIR / "waybar-reference.png"
    import shutil
    shutil.copy(screenshot, ref_path)

    print(f"Reference saved: {ref_path}")

    # Also save metadata
    meta = {
        "saved_at": datetime.now().isoformat(),
        "expected_widgets": EXPECTED_WIDGETS,
        "geometry": get_monitor_geometry()
    }
    meta_path = REFERENCE_DIR / "reference-meta.json"
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)

    print(f"Metadata saved: {meta_path}")


def print_report(result: dict):
    """Print human-readable report"""
    print("\n" + "="*60)
    print("WAYBAR VALIDATION REPORT")
    print("="*60)

    if "error" in result:
        print(f"\n❌ ERROR: {result['error']}")
        return

    print(f"\nSummary: {result.get('summary', 'N/A')}")
    print(f"\nScreenshot: {result.get('screenshot', 'N/A')}")

    widgets = result.get("widgets_found", {})
    print("\nWidget Status:")
    print("-"*40)

    for name, status in widgets.items():
        if isinstance(status, dict):
            present = status.get("present", False)
            notes = status.get("notes", "")
            icon = "✅" if present else "❌"
            print(f"  {icon} {name}: {notes}")
        else:
            print(f"  ? {name}: {status}")

    missing = result.get("missing", [])
    if missing:
        print(f"\n❌ MISSING WIDGETS: {', '.join(missing)}")
    else:
        print("\n✅ ALL WIDGETS PRESENT")

    print("="*60 + "\n")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Validate waybar widgets")
    parser.add_argument("--reference", action="store_true", help="Save current as reference")
    parser.add_argument("--compare", type=str, help="Compare against reference image")
    parser.add_argument("--list-widgets", action="store_true", help="List expected widgets")
    parser.add_argument("--json", action="store_true", help="Output JSON only")
    args = parser.parse_args()

    if args.list_widgets:
        print("Expected widgets:")
        for section, widgets in EXPECTED_WIDGETS.items():
            print(f"\n{section.upper()}:")
            for w in widgets:
                print(f"  - {w}")
        return 0

    if args.reference:
        save_reference()
        return 0

    # Run validation
    result = validate_waybar()

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_report(result)

    # Return exit code based on result
    if result.get("all_present", False):
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())
