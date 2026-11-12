#!/usr/bin/env bash
# memory-index-lint — keep Claude Code's auto-memory index inside what Claude Code loads.
#
# Claude Code loads only the first 25 KB / 200 lines of
# ~/.claude/projects/<project>/memory/MEMORY.md at session start; anything past
# that is silently dropped (code.claude.com/docs/en/memory). On 2026-10-01 the
# ~/Programs index had grown to 26.6 KB and the newest entries were the ones
# being lost. This enforces a budget well under the limit so the index gets
# consolidated before it overflows. Design + sources: docs/memory-index-lint.md.
#
# Modes
#   --hook   Claude Code PostToolUse hook (JSON on stdin). Acts only when the
#            tool touched a MEMORY.md under ~/.claude/projects/*/memory/. On a
#            violation: report on stderr + exit 2 (Claude Code shows it to the
#            agent, which consolidates right away). Otherwise silent, exit 0.
#   [PATH…]  CLI. PATH = a MEMORY.md or a memory dir; default = every
#            ~/.claude/projects/*/memory/MEMORY.md. Prints the report; exit 1
#            on any violation.
#
# Budget (soft, env-overridable; the hard limits are Claude Code's own):
SOFT_BYTES=${MEMORY_INDEX_SOFT_BYTES:-16000}   # Claude Code stops loading at 25000
SOFT_LINES=${MEMORY_INDEX_SOFT_LINES:-120}     # … or at 200 lines
MAX_LINE=${MEMORY_INDEX_MAX_LINE:-200}         # chars per entry line
set -u

lint() {  # <MEMORY.md> → report on stdout; returns 1 on violation
    local idx="$1" dir bytes lines entries viol=0 long missing cat f un=""
    dir=$(dirname "$idx")
    [[ -f "$idx" ]] || { echo "$idx: no index (nothing to lint)"; return 0; }
    bytes=$(wc -c <"$idx"); lines=$(wc -l <"$idx")
    entries=$(grep -c '^- \[' "$idx" 2>/dev/null || true)
    echo "$idx: ${bytes} bytes (budget ${SOFT_BYTES}; Claude Code loads 25000), ${lines} lines (budget ${SOFT_LINES}; loads 200), ${entries} entries"
    (( bytes > SOFT_BYTES )) && { echo "VIOLATION: over the byte budget by $((bytes - SOFT_BYTES)) bytes"; viol=1; }
    (( lines > SOFT_LINES )) && { echo "VIOLATION: over the line budget by $((lines - SOFT_LINES)) lines"; viol=1; }
    long=$(awk -v m="$MAX_LINE" '/^- \[/ && length($0) > m { printf "  %d chars: %s…\n", length($0), substr($0, 1, 70) }' "$idx")
    [[ -n "$long" ]] && { echo "VIOLATION: entry lines over ${MAX_LINE} chars (move detail into the topic file):"; echo "$long"; viol=1; }
    missing=$(grep -o '](\([^)]*\.md\))' "$idx" | sed 's/^](\(.*\))$/\1/' | sort -u \
              | while read -r f; do [[ -e "$dir/$f" ]] || echo "  $f"; done)
    [[ -n "$missing" ]] && { echo "VIOLATION: index lines point to files that do not exist:"; echo "$missing"; viol=1; }
    cat="$dir/CATALOG.md"
    for f in "$dir"/*.md; do
        f=$(basename "$f")
        [[ "$f" == MEMORY.md || "$f" == CATALOG.md ]] && continue
        grep -qF "($f)" "$idx" || { [[ -f "$cat" ]] && grep -qF "($f)" "$cat"; } || un+="  $f"$'\n'
    done
    [[ -n "$un" ]] && { echo "VIOLATION: topic files indexed nowhere (add one line to MEMORY.md, or to CATALOG.md if warm):"; printf '%s' "$un"; viol=1; }
    if (( viol )); then
        echo "Fix now (routine at the top of MEMORY.md): fold dated entries into their project's *-current file, move closed/superseded lines to CATALOG.md or archive/, shorten hooks, merge duplicates, log the pass in archive/consolidation-log.md; then re-run memory-index-lint."
    else
        echo "OK"
    fi
    return $viol
}

if [[ "${1:-}" == "--hook" ]]; then
    input=$(cat 2>/dev/null || true)
    [[ -z "$input" ]] && exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.command // empty' 2>/dev/null)
    [[ "$target" == *MEMORY.md* ]] || exit 0
    idx=$(printf '%s' "$target" | grep -oE "[^ \"'<>|;&]*MEMORY\.md" | head -1)
    [[ -z "$idx" ]] && exit 0
    idx="${idx/#\~/$HOME}"
    [[ "$idx" == /* ]] || idx="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)/$idx"
    [[ "$idx" == */.claude/projects/*/memory/MEMORY.md ]] || exit 0
    if report=$(lint "$idx"); then exit 0; fi
    printf 'memory-index-lint: the memory index you just wrote is over budget.\n%s\n' "$report" >&2
    exit 2
fi

rc=0
if [[ $# -eq 0 ]]; then
    set -- "$HOME"/.claude/projects/*/memory/MEMORY.md
fi
for p in "$@"; do
    [[ -d "$p" ]] && p="$p/MEMORY.md"
    lint "$p" || rc=1
done
exit $rc
