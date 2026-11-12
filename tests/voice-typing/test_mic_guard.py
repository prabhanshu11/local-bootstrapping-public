#!/usr/bin/env python3
"""Offline test of the hyprwhspr mic guard (_pick_real_mic) + a live dry run.

Extracts the pure functions from the patched main.py with ast (importing the
file would start hyprwhspr). The live part only reads pactl; it never changes
the default source. Run: python3 tests/voice-typing/test_mic_guard.py
"""
import ast, subprocess
src = open(__import__('pathlib').Path(__file__).resolve().parents[2] / 'dotfiles/local-lib/hyprwhspr-patch/main.py').read()
tree = ast.parse(src)
ns = {'subprocess': subprocess}
for n in tree.body:
    if isinstance(n, ast.FunctionDef) and n.name in ('_pick_real_mic', '_read_bt_state'):
        exec(compile(ast.Module([n], []), 'main.py', 'exec'), ns)
pick = ns['_pick_real_mic']
MIC1='alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source'
MIC2='alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic2__source'
FMON='bluez_output.02_00_00_00_00_06.1.monitor'
BTIN='bluez_input.02_00_00_00_00_06.0'
cases = [
  ("real mic default untouched", MIC1, [FMON, MIC2, MIC1], None),
  ("BT speaker monitor -> laptop Mic1", FMON, [FMON, MIC2, MIC1], MIC1),
  ("monitor, headset input present -> BT input", FMON, [FMON, MIC1, BTIN], BTIN),
  ("BT headset default untouched", BTIN, [MIC1, BTIN], None),
  ("vanished default -> Mic1", BTIN, [FMON, MIC2, MIC1], MIC1),
  ("auto_null -> Mic1", 'auto_null.monitor', ['auto_null.monitor', MIC1], MIC1),
  ("no mic at all -> None", 'auto_null.monitor', ['auto_null.monitor'], None),
]
ok = True
for name, d, s, want in cases:
    got = pick(d, s)
    print(('PASS' if got == want else 'FAIL'), name, '->', got)
    ok &= got == want
# live dry run (no set)
default = subprocess.check_output(['pactl','get-default-source'], text=True).strip()
sources = [l.split('\t')[1] for l in subprocess.check_output(['pactl','list','sources','short'], text=True).splitlines() if '\t' in l]
print('LIVE default:', default, '-> pick:', pick(default, sources))
print('LIVE _read_bt_state:', ns['_read_bt_state']())
print('ALL PASS' if ok else 'SOME FAILED')
raise SystemExit(0 if ok else 1)
