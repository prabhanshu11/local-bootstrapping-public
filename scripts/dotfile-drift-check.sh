#!/bin/bash
# dotfile-drift-check.sh - Detect and fix dotfile symlink drift
#
# Since 2026-09-30 this is a thin wrapper over the one reconcile
# implementation (scripts/lib/reconcile.sh via install.sh --reconcile), which
# covers EVERY SYMLINKS entry plus machine-specific/<device>/ files — not the
# old hand-kept list of local-bin/ files. The 10-minute sync runs the same
# self-heal on its own; see docs/issues/desktop-drift-2026-09-30.md.
#
# Usage:
#   dotfile-drift-check.sh          # Check only (exit 0=clean, 1=drift)
#   dotfile-drift-check.sh --fix    # Self-heal now (a file whose content
#                                   # differs from the repo is reported, never
#                                   # clobbered)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT=$(mktemp)
trap 'rm -f "$REPORT"' EXIT

case "${1:-}" in
    --fix) args=(--reconcile) ;;
    "")    args=(--reconcile --check) ;;
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

out=$(bash "$SCRIPT_DIR/install.sh" "${args[@]}" --report "$REPORT" 2>&1)
echo "$out"
if [[ -s "$REPORT" ]] || grep -q "WOULD " <<< "$out"; then
    exit 1
fi
exit 0
