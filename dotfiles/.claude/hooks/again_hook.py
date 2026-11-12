#!/usr/bin/env python3
"""UserPromptSubmit hook: when he repeats himself, make the agent write the rule down first.

His answer 2026-10-22 03:26 to card rules-1015:again-hook: "Add the reminder hook".
Trigger words (case-insensitive, whole words): again, I told you, I said, I've asked, I have asked.
Stdlib only. Never blocks the prompt; on any error it prints nothing and exits 0.
Configured in ~/Programs/.claude/settings.json (hooks.UserPromptSubmit).
Test: echo '{"prompt":"I told you again"}' | again_hook.py
"""
import json
import re
import sys

PATTERN = re.compile(r"\b(again(?![-_]hook)|I told you|I said|I've asked|I have asked)\b", re.IGNORECASE)
# Not his words: automated turns (task notifications, system reminders) must never trigger the rule-first nudge.
SKIP = ("<system-reminder>", "[SYSTEM NOTIFICATION", "<task-notification>", "<local-command", "<agent-message", "[Subagent hand-back]", "<cross-session-message")
CONTEXT = (
    "He is repeating himself. Before anything else: write the rule in its home file "
    "(memory feedback_* or the project's LANE-RULES/CLAUDE.md), say where, then answer."
)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    prompt = data.get("prompt") or ""
    if any(k in prompt for k in SKIP):
        return 0
    m = PATTERN.search(prompt)
    if not m:
        return 0
    out = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": f"{CONTEXT} (trigger word: \"{m.group(0)}\")",
        }
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
