# Skill Feedback System

A SQLite-based feedback collection and skill modification system for Claude Code skills.

## Overview

This system allows you to:
1. **Collect feedback** about skill performance (positive, negative, suggestions)
2. **Analyze feedback** to identify patterns and issues
3. **Apply adjustments** automatically using a rule-based lookup table
4. **Track all changes** for audit and rollback

## Architecture

```
~/.local/share/skill-feedback/
└── feedback.db              # SQLite database

~/Programs/local-bootstrapping/scripts/skill-feedback/
├── schema.sql               # Database schema
├── skill-feedback.sh        # CLI for adding feedback
├── apply-feedback.py        # Analyze and apply changes
└── README.md                # This file

~/.claude/skills/            # Symlink to dotfiles/.claude/skills
├── conversation-recall/
├── camera-app/
├── smarter-ui-navigator/
├── better-screenshot/
└── debug-with-logging/
```

## Quick Start

### Initialize the database
```bash
~/Programs/local-bootstrapping/scripts/skill-feedback/skill-feedback.sh init
```

### Add feedback
```bash
# Syntax: skill-feedback add <skill> <aspect> <type> "<feedback>"
skill-feedback.sh add conversation-recall trigger_keywords suggestion "add 'find sessions' as trigger"
skill-feedback.sh add better-screenshot allowed_tools negative "needed Write tool but wasn't allowed"
skill-feedback.sh add debug-with-logging general positive "helped solve PATH issue quickly"
```

### View feedback
```bash
skill-feedback.sh list                    # All feedback
skill-feedback.sh list conversation-recall   # Specific skill
skill-feedback.sh stats                   # Statistics
```

### Analyze and apply changes
```bash
# Preview what changes would be made
python3 apply-feedback.py analyze

# Dry run - show changes without applying
python3 apply-feedback.py apply --dry-run

# Apply changes
python3 apply-feedback.py apply
```

## Feedback Aspects

| Aspect | Description | Example Feedback |
|--------|-------------|------------------|
| `description` | Skill description text | "add trigger keyword 'search history'" |
| `trigger_keywords` | When skill should activate | "should trigger when user says 'find old chats'" |
| `allowed_tools` | Pre-approved tools | "needed Glob tool but it wasn't allowed" |
| `instructions` | How-to content | "needs example for systemd debugging" |
| `examples` | Usage examples | "add example for cron job logging" |
| `general` | Overall feedback | "skill is very helpful" |

## Feedback Types

| Type | Use When |
|------|----------|
| `positive` | Skill worked well, reinforcement |
| `negative` | Skill failed, missing capability |
| `suggestion` | Ideas for improvement |

## Adjustment Rules

The system uses a lookup table of rules to automatically apply changes based on feedback patterns.

### Built-in Rules

| Rule | Trigger Pattern | Action |
|------|-----------------|--------|
| `add_bash_tool` | "need bash\|need shell" | Add `Bash` to allowed-tools |
| `add_read_tool` | "need to read\|file access" | Add `Read` to allowed-tools |
| `add_edit_tool` | "need to edit" | Add `Edit` to allowed-tools |
| `skill_not_triggering` | "not triggering\|did not activate" | Add trigger keyword from feedback |

### Adding Custom Rules

```bash
python3 apply-feedback.py add-rule

# Interactive prompts:
# Rule name: custom_rule
# Aspect: description
# Trigger pattern: should mention
# Adjustment type: add_keyword
# Adjustment value: (empty to extract from feedback)
# Priority: 5
```

### Rule Adjustment Types

| Type | Description |
|------|-------------|
| `append` | Add text to end of field |
| `prepend` | Add text to start of field |
| `replace` | Replace entire field |
| `add_keyword` | Add trigger keyword to description |
| `remove_keyword` | Remove keyword from description |
| `add_tool` | Add tool to allowed-tools list |
| `remove_tool` | Remove tool from allowed-tools list |

## Database Schema

### Tables

1. **skill_feedback** - Raw feedback entries
2. **skill_parameters** - Current skill configuration (synced from SKILL.md)
3. **adjustment_rules** - Lookup table for automatic adjustments
4. **adjustment_log** - Audit trail of all changes

### Viewing Data

```bash
# Open database directly
sqlite3 ~/.local/share/skill-feedback/feedback.db

# Useful queries
.tables
SELECT * FROM skill_feedback ORDER BY created_at DESC LIMIT 10;
SELECT * FROM adjustment_rules WHERE enabled = 1;
SELECT * FROM adjustment_log ORDER BY applied_at DESC LIMIT 10;
```

## Workflow

### Daily Usage

1. When a skill doesn't work as expected:
   ```bash
   skill-feedback.sh add <skill> <aspect> negative "<what happened>"
   ```

2. When a skill works well:
   ```bash
   skill-feedback.sh add <skill> general positive "<what was good>"
   ```

3. When you have improvement ideas:
   ```bash
   skill-feedback.sh add <skill> <aspect> suggestion "<your idea>"
   ```

### Weekly Review

1. Check statistics:
   ```bash
   skill-feedback.sh stats
   ```

2. Analyze pending feedback:
   ```bash
   python3 apply-feedback.py analyze
   ```

3. Apply matched changes:
   ```bash
   python3 apply-feedback.py apply --dry-run  # Preview
   python3 apply-feedback.py apply            # Apply
   ```

4. Commit changes:
   ```bash
   cd ~/Programs/local-bootstrapping
   git add dotfiles/.claude/skills/
   git commit -m "Apply skill feedback adjustments"
   git push
   ```

## Integration with Claude Code

### Automatic Feedback Collection (Future)

A Claude Code hook could automatically collect feedback:
```yaml
# .claude/hooks.yaml (conceptual)
PostToolUse:
  - matcher: "Skill"
    hooks:
      - type: command
        command: "skill-feedback.sh add $SKILL_NAME usage positive 'skill invoked successfully'"
```

### Session-End Feedback (Future)

Prompt user for skill feedback at session end.

## Troubleshooting

### Database not found
```bash
skill-feedback.sh init
```

### Skill parameters out of sync
```bash
skill-feedback.sh sync
```

### Reset everything
```bash
rm -rf ~/.local/share/skill-feedback
skill-feedback.sh init
```

## Files Modified

When `apply-feedback.py apply` runs, it modifies:
- `~/Programs/local-bootstrapping/dotfiles/.claude/skills/*/SKILL.md`

These changes are tracked in git and sync to `~/.claude/skills/` via symlink.
