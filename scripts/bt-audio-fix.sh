#!/bin/bash
# bt-audio-fix.sh - Force Bluetooth earbuds back to A2DP (media quality)
#
# Symptom: earbuds sound like a phone call (HFP/mSBC, 16kHz mono) and
# reconnecting doesn't fix it. Cause: some client still holds the BT mic
# open (a leaked hyprwhspr capture stream after a BT transport failure
# mid-recording, or wiremix's level meters), so WirePlumber's
# autoswitch-to-headset keeps re-selecting HFP on every reconnect.
#
# See docs/issues/bt-earbuds-stuck-in-hfp-after-voice-typing.md
#
# Usage: bt-audio-fix.sh            # diagnose + fix
#        bt-audio-fix.sh --status   # diagnose only

set -uo pipefail

card=$(pactl list cards short | awk '/bluez_card/ {print $2; exit}')
[[ -z "$card" ]] && { echo "No Bluetooth audio card connected"; exit 1; }
mac=${card#bluez_card.}; mac_colon=${mac//_/:}

echo "Card: $card"
profile() { pactl list cards | awk -v c="$card" '$0 ~ "Name: "c {f=1} f && /Active Profile/ {print $3; exit}'; }
echo "Active profile: $(profile)"
echo "Clients linked to BT mic (bluez_input.$mac_colon):"
# pw-link -l: a port line, then indented "|-> consumer" lines
holders=$(pw-link -l 2>/dev/null | awk -v m="bluez_input.$mac_colon" \
    '$0 ~ "^"m {f=1; next} /^[^ \t]/ {f=0} f && /\|->/ {sub(/:.*/,"",$2); print $2}' | grep -v bluez_capture_internal | sort -u)
echo "${holders:-  (none)}"

[[ "${1:-}" == "--status" ]] && exit 0

if grep -q 'alsa_capture.python' <<<"$holders"; then
    echo "==> hyprwhspr leaked its capture stream - restarting hyprwhspr.service"
    systemctl --user restart hyprwhspr.service
    sleep 3
fi
if grep -q 'wiremix' <<<"$holders"; then
    echo "⚠️  wiremix is capturing the BT mic for level meters - close it or the profile may flip back to HFP"
fi

# Prefer SBC-XQ (matches setup-audio-bluetooth.sh codec priority), fall back to any A2DP
for p in a2dp-sink-sbc_xq a2dp-sink; do
    if pactl set-card-profile "$card" "$p" 2>/dev/null; then echo "==> Set profile $p"; break; fi
done
sleep 2
sink=$(pactl list sinks short | awk -v m="bluez_output.$mac" '$2 ~ m {print $2; exit}')
[[ -n "$sink" ]] && pactl set-default-sink "$sink"
echo "Now: profile=$(profile) codec=$(pactl list sinks | grep 'api.bluez5.codec' | awk -F'"' '{print $2}')"
