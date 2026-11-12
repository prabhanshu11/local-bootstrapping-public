#!/usr/bin/env bash
# Claude Code Stop hook: detect sudo popup fallback completion and tell the
# agent whether cached sudo credentials are ready for retry.

SIGNAL="/tmp/sudo-auth-signal"
[[ ! -f "$SIGNAL" ]] && exit 0

data=$(cat "$SIGNAL")
rm -f "$SIGNAL"

authenticated=$(echo "$data" | jq -r '.authenticated' 2>/dev/null)
desc=$(echo "$data" | jq -r '.description' 2>/dev/null)

if [[ "$authenticated" == "true" ]]; then
    msg="User returned and authenticated via sudo popup ($desc). Sudo credentials are cached. Retry the failed sudo command now using sudo-with-notify."
else
    msg="User returned (closed sudo popup for: $desc) but did not authenticate successfully. User is present - re-run sudo-with-notify to try again with fresh auth."
fi

jq -n --arg msg "$msg" '{"continue": true, "systemMessage": $msg}'
