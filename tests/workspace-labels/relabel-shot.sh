#!/bin/bash
# Reproduce a relabel view with a long multiline label and grab it (round 9).
# Usage: relabel-shot.sh DESK OUT.png [LABELS_JSON_SOURCE]
# Runs a throwaway daemon (fake-claude, own state dir), seeds the desk's label
# from the live labels.json, triggers a relabel, shows the popup, grabs it.
set -u
D=$1; OUT=$2; SRC=${3:-$HOME/.local/state/workspace-labels/labels.json}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); U=wsl-shot-$$
python3 -c "import json,sys,time; d=json.load(open('$SRC')); v=d['$D']; v['at']=time.time(); json.dump({'$D': v}, open('$T/labels.json','w')); open('$T/fake-label.txt','w').write(v['label'])"
systemd-run --user --unit=$U -E WSL_STATE=$T -E WSL_CLAUDE=$HERE/tests/workspace-labels/fake-claude -E WSL_FAKE_LABEL_FILE=$T/fake-label.txt \
    -E PYTHONUNBUFFERED=1 /usr/bin/python3 $HERE/dotfiles/local-bin/workspace-labels daemon >/dev/null
trap 'systemctl --user stop $U; rm -rf $T' EXIT
for _ in $(seq 50); do grep -q "card page loaded" $T/workspace-labels.log 2>/dev/null && break; sleep 0.2; done
sleep 12   # let the startup pass (it may relabel with the same seeded text) finish
for try in 1 2 3; do
    n0=$(grep -c "ws $D: labelling (asked" $T/workspace-labels.log 2>/dev/null || echo 0)
    $HERE/dotfiles/local-bin/workspace-labels relabel $D >/dev/null
    for _ in $(seq 100); do [ "$(grep -c "ws $D: labelling (asked" $T/workspace-labels.log)" -gt "$n0" ] && break; sleep 0.2; done
    sleep 0.3; $HERE/dotfiles/local-bin/workspace-labels show $D >/dev/null; sleep 0.9
    G=$(hyprctl layers -j | jq -r '.. | objects | select(.namespace? == "workspace-labels") | "\(.x),\(.y) \(.w)x\(.h)"')
    if [ -n "$G" ] && [ "${G##*x}" -gt 500 ]; then grim -g "$G" "$OUT"; echo "grabbed $G"; exit 0; fi
    echo "try $try: popup gone ($G), retry"; sleep 9
done
exit 1
