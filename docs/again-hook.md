# again-hook (UserPromptSubmit, ~/Programs sessions)

His answer 2026-10-22 03:26 to card `rules-1015:again-hook`: "Add the reminder hook".

- Script: `dotfiles/.claude/hooks/again_hook.py` (stdlib only), symlinked to `~/Programs/.claude/hooks/again_hook.py`.
- Config: `~/Programs/.claude/settings.json` → `hooks.UserPromptSubmit` (project scope: chats started in `~/Programs`).
  `~/Programs/.claude/` is not a git repo; this doc is the record. Recreate with the JSON block below if lost.
- Trigger: `\b(again|I told you|I said|I've asked|I have asked)\b`, case-insensitive.
- Effect: adds context "He is repeating himself. Before anything else: write the rule in its home file
  (memory feedback_* or the project's LANE-RULES/CLAUDE.md), say where, then answer." Never blocks a prompt; bad input → silent exit 0.
- Test: `echo '{"prompt":"I told you"}' | ~/Programs/.claude/hooks/again_hook.py` prints the JSON; a prompt without the words prints nothing.

```json
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/home/prabhanshu/Programs/.claude/hooks/again_hook.py"}]}]}}
```
