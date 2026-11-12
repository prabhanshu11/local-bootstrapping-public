# local-bootstrapping Test Suite

Comprehensive testing framework for validating system recovery and configuration integrity.

## Quick Start

### Install Dependencies

```bash
pip install -r requirements.txt
```

### Run Tests

```bash
# All tests
pytest

# Specific test level
pytest tests/unit/ -v           # Fast unit tests
pytest tests/integration/ -v    # Integration tests
pytest tests/acceptance/ -v     # Full acceptance tests

# By marker
pytest -m reboot                # Post-reboot tests
pytest -m visual                # Visual regression tests
pytest -m desktop               # Desktop-only tests
pytest -m laptop                # Laptop-only tests
```

## Test Levels

### Level 0: Unit Tests (`tests/unit/`)
- **Purpose**: Catch syntax errors and logic bugs
- **Speed**: < 30 seconds
- **Run**: Pre-commit, automated
- **Tools**: BATS (bash), pytest (python)

### Level 1: Integration Tests (`tests/integration/`)
- **Purpose**: Verify components work together
- **Speed**: < 5 minutes
- **Run**: After applying configs
- **Tools**: pytest-testinfra

### Level 2: Visual Tests (`tests/visual/`)
- **Purpose**: Catch UI regressions
- **Speed**: ~1 minute (API call)
- **Run**: Optional, requires GUI + OpenRouter API key
- **Tools**: OpenRouter Vision API

### Level 3: Acceptance Tests (`tests/acceptance/`)
- **Purpose**: Validate full system recovery
- **Speed**: 5-10 minutes
- **Run**: After reboot, config wipe, fresh install
- **Tools**: pytest, Goss (future)

## Test Scenarios

### Soft Test (Reboot Recovery)
**Goal**: System recovers after unexpected reboot

```bash
# Before reboot: Baseline captured automatically
# After reboot:
pytest tests/acceptance/test_post_reboot.py -m reboot -v

# Manual checklist
cat tests/acceptance/checklists/reboot_checklist.md
```

**Verifies**:
- Services restart (Tailscale, Sunshine/Moonlight, clipboard-health)
- Waybar renders with all icons
- Network connectivity restored
- SSH accessible

### Config Wipeout Recovery
**Goal**: `install.sh` restores all configs

```bash
# Simulate wipeout
rm -rf ~/.config/waybar ~/.config/hypr/bindings-streaming.conf

# Recover
cd ~/Programs/local-bootstrapping
./scripts/install.sh

# Verify
pytest tests/integration/ -v
pytest -m config_wipe
```

### Fresh Install
**Goal**: Fresh Omarchy + repo = fully operational

```bash
# After fresh Omarchy install
git clone https://github.com/prabhanshu11/local-bootstrapping
cd local-bootstrapping
./scripts/install.sh

# Full validation
pytest -m fresh_install -v
```

## Visual Regression Testing

### Baseline Screenshots

Baseline screenshots are stored in `tests/visual/screenshots/`:
- `baseline-waybar-YYYYMMDD-HHMMSS.png` - Reference waybar state

### Capturing New Baseline

```bash
timestamp=$(date +%Y%m%d-%H%M%S)
tmpfile="/tmp/waybar-full-${timestamp}.png"
grim "$tmpfile"
magick "$tmpfile" -crop "2560x40+0+0" \
  "tests/visual/screenshots/baseline-waybar-${timestamp}.png"
rm "$tmpfile"
```

### Running Visual Tests

```bash
# Requires OpenRouter API key in pass
pytest tests/visual/test_waybar_icons.py -v
```

## Manual Checklists

Located in `tests/acceptance/checklists/`:
- `reboot_checklist.md` - Post-reboot manual verification
- `config_wipe_checklist.md` - Config recovery checks (TODO)
- `fresh_install_checklist.md` - Full reinstall validation (TODO)

## Test Results Tracking

Test results are saved to `tests/results/history.json` for trend analysis (future feature).

## Device-Specific Tests

Tests automatically detect device type (desktop/laptop) and skip non-applicable tests:

```python
@pytest.mark.desktop
def test_sunshine_running():
    # Only runs on desktop
    pass

@pytest.mark.laptop
def test_moonlight_installed():
    # Only runs on laptop
    pass
```

## Future Enhancements

- [ ] BATS tests for shell scripts
- [ ] Goss YAML specifications
- [ ] GitHub Actions CI integration
- [ ] Test result history tracking
- [ ] HTML test report generation
- [ ] Automated screenshot comparison
