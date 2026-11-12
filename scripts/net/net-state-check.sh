#!/usr/bin/env bash
# net-state-check.sh — prints "INTERNET OK ..." / "INTERNET FAIL ..." and exits 0/1.
# OK = default route is on wlan0 (the built-in Intel card) AND an HTTPS HEAD to example.com succeeds via it.
set -u
DEF="$(ip route show default | head -1)"
DEVDEF="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$DEF")"
SRC="$(curl -sI -m 5 -o /dev/null -w '%{local_ip}' https://example.com 2>/dev/null)"; RC=$?
if [[ "$DEVDEF" == "wlan0" && $RC -eq 0 ]]; then echo "INTERNET OK default_dev=$DEVDEF curl_src=$SRC"; exit 0; fi
echo "INTERNET FAIL default='${DEF:-none}' curl_rc=$RC curl_src=${SRC:-none}"; exit 1
