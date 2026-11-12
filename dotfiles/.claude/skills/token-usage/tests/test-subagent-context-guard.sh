#!/usr/bin/env bash
# Tests for subagent-context-guard.py — synthetic transcripts + hook inputs.
# Run:  dotfiles/.claude/hooks/tests/test-subagent-context-guard.sh
set -u
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/subagent-context-guard.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SUBAGENT_CTX_STATE="$T/state" HOME_REAL="$HOME"
# Fixtures were written for the pre-2026-09-30 lines; pin them so the tests check the logic, not the defaults.
export SUBAGENT_CTX_WARN=180000 SUBAGENT_CTX_RETIRE=240000 SUBAGENT_CTX_MAIN_WARN=240000 SUBAGENT_CTX_MAIN_STRONG=400000
SID=test-session
PROJ="$T/projects/-x"; mkdir -p "$PROJ/$SID/subagents"
TP="$PROJ/$SID.jsonl"; : >"$TP"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — got: ${2:-<empty>}"; fi; }
none() { if [[ -z "$2" ]]; then ok "$1"; else bad "$1 — expected no output, got: $2"; fi; }

# transcript with N turns; last turn's context = $2 tokens (spread over cache_read)
mk() { # id ctx
  local f="$PROJ/$SID/subagents/agent-$1.jsonl"
  {
    echo '{"type":"user","message":{"role":"user","content":"go"}}'
    echo '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":5}}}'
    # a huge tool result line, to exercise the backwards chunked read
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$(head -c 300000 /dev/zero | tr '\0' x)"
    echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":$(( $2 - 200 )),\"cache_creation_input_tokens\":50,\"output_tokens\":50}}}"
  } >"$f"
}
mk small 50000
mk warm  190000
mk fat   300000
# fork header only (no assistant turn yet)
echo '{"type":"fork-header","agentId":"fork","contextLength":250000}' >"$PROJ/$SID/subagents/agent-fork.jsonl"

run() { # event tool json-extra
  printf '{"hook_event_name":"%s","tool_name":"%s","session_id":"%s","transcript_path":"%s"%s}' \
    "$1" "$2" "$SID" "$TP" "${3:-}" | python3 "$HOOK"
}

echo "PostToolUse Agent records description"
out=$(run PostToolUse Agent ',"tool_input":{"description":"Fat worker","prompt":"x"},"tool_response":{"agentId":"fat","status":"async_launched"}')
none "no output" "$out"
grep -q '"Fat worker"' "$SUBAGENT_CTX_STATE/$SID.json" && ok "state has description" || bad "state missing description"

echo "SubagentStop"
out=$(run SubagentStop '' ',"agent_id":"small","agent_name":"tiny"'); none "small: silent" "$out"
out=$(run SubagentStop '' ',"agent_id":"warm"');  check "warm: warns" "$out" "190k"
out=$(run SubagentStop '' ',"agent_id":"warm"');  none "warm: no repeat warn" "$out"
out=$(run SubagentStop '' ',"agent_id":"fat"');   check "fat: retire msg" "$out" "240k soft limit"
check "fat: label uses description" "$out" "Fat worker"
out=$(run SubagentStop '' ',"agent_id":"ghost","input_tokens":260000,"output_tokens":100'); check "no transcript: falls back to event tokens" "$out" "260k"

echo "PreToolUse SendMessage"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"small","message":"hi"}'); none "small: allowed silently" "$out"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"warm","message":"hi"}'); check "warm: advisory" "$out" "additionalContext"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"fat","message":"do more"}'); check "fat: denied" "$out" '"deny"'
check "fat: deny explains override" "$out" "long-context-ok"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"fat","message":"[long-context-ok: handover] write handover"}'); check "fat: override accepted" "$out" "override #1"
[[ "$out" != *'"deny"'* ]] && ok "override not denied" || bad "override still denied"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"Fat worker","message":"x"}'); check "resolve by description" "$out" '"deny"'
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"tiny","message":"x"}'); none "resolve by agent_name, small" "$out"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"fork","message":"x"}'); check "fork header contextLength counts" "$out" '"deny"'
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"nobody","message":"x"}'); none "unknown target: allowed" "$out"

echo "PreToolUse Agent fleet status"
out=$(run PreToolUse Agent ',"tool_input":{"prompt":"x","description":"new"}')
check "lists fat" "$out" "fat"; check "lists warm" "$out" "warm"; check "marks RETIRE" "$out" "[RETIRE]"
[[ "$out" != *"- small"* ]] && ok "omits small" || bad "listed small"

echo "PostToolUse * — main session"
mkmain() { { echo '{"type":"user","message":{"content":"hi"}}'; echo "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":$(( $1 - 100 )),\"output_tokens\":0}}}"; } >"$TP"; }
mkmain 100000; out=$(run PostToolUse Bash ',"tool_input":{"command":"ls"}'); none "main 100k: silent" "$out"
mkmain 250000; out=$(run PostToolUse Bash ',"tool_input":{"command":"ls"}'); check "main 250k: warns model" "$out" "additionalContext"; check "main 250k: warns user" "$out" "systemMessage"
out=$(run PostToolUse Bash ',"tool_input":{"command":"ls"}'); none "main 250k: no repeat" "$out"
mkmain 450000; out=$(run PostToolUse Bash ',"tool_input":{"command":"ls"}'); check "main 450k: strong nudge" "$out" "Handover + fresh session"
out=$(run PostToolUse Bash ',"tool_input":{"command":"ls"},"agent_id":"fat"'); none "inside subagent: skipped" "$out"

echo "Fail-safe"
out=$(echo 'not json' | python3 "$HOOK"); none "garbage stdin: silent, exit 0" "$out"
out=$(run PreToolUse SendMessage ',"tool_input":{"to":"fat","message":"x"},"transcript_path":"/nonexistent/x.jsonl"'); none "missing transcript dir: allowed" "$out"
mkdir -p "$T/.claude/hooks"; touch "$T/.claude/hooks/.subagent-context-guard-off"
out=$(HOME="$T" run PreToolUse SendMessage ',"tool_input":{"to":"fat","message":"x"}'); none "off-switch disables the gate" "$out"

echo; echo "passed=$pass failed=$fail"; [[ $fail -eq 0 ]]
