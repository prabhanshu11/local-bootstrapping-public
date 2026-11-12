# Claude Code Skills

This directory contains custom skills for Claude Code, following the [Anthropic Agent Skills protocol](https://code.claude.com/docs/en/skills).

## What Are Skills?

Skills are reusable prompts that give Claude specialized capabilities. Each skill is a simple folder with a `SKILL.md` file containing:
- **YAML frontmatter** (name and description)
- **Markdown instructions** that Claude follows when the skill is active
- **Optional bundled resources** (scripts, references, templates)

## How to Use Skills

### Invoke a Skill

Just mention it in your message:
```
"Use conversation-recall to find my tapo sessions"
```

Or use slash command syntax:
```
"/conversation-recall tapo"
```

### Resume from a Conversation

When a skill provides a resume command, use it directly:
```bash
claude --resume 00000000-0000-4000-8000-000000000000
```

## Available Skills

### 0. token-usage
**Location:** `token-usage/SKILL.md`
**Purpose:** Tell the model its own context size and every subagent's, and enforce the 240k subagent retirement rule (bundled `subagent-context-guard.py` hook).

**Use when:**
- "How big is my context?" / "which subagents are bloated?"
- Before resuming a long-running subagent or planning a handover
- CLI: `token-usage`, `token-usage --brief`, `token-usage --json`

### 1. conversation-recall
**Location:** `conversation-recall/SKILL.md`
**Purpose:** Search through Claude Code conversation history to find and summarize past sessions on any topic

**Use when:**
- "Find my conversations about X"
- "What did we discuss about Y?"
- "Resume work on [project]"

**Output includes:**
- Session IDs with timestamps
- One-line summaries (better than default titles)
- Ready-to-use `claude --resume` commands

### 2. debug-with-logging
**Location:** `debug-with-logging/SKILL.md`
**Purpose:** Add comprehensive logging to diagnose "works manually but not via automation" issues

**Use when:**
- Command works in terminal but not via keybinding
- Systemd service fails silently
- Hyprland/WM bindings don't trigger expected action
- User says "it works when I run it manually"

**Common root causes revealed:**
- PATH issues (command not found)
- Missing environment variables
- Wrong working directory
- Permission problems

### 3. session-ascii-diagrams (planned)
**Location:** TBD
**Purpose:** ASCII art rendering utility for voice typing session logs and TUI display

**Will use when:**
- Generating ASCII timeline/data-flow diagrams for session log files
- Rendering animated pipeline diagrams in a TUI window
- Quick inline diagram generation during Claude Code sessions

**Data source:** `~/Programs/omarchy-voice-typing/logs/sessions/`
**Output:** ASCII art diagrams embedded in per-session log files (timestamped filenames)

### 4. pass-helper
**Location:** `pass-helper/SKILL.md` (scripts in `pass-helper/scripts/`, symlinked into `~/.local/bin`)
**Purpose:** Safe `pass` credential handling: agent-generated passwords (`pass-new`), the `pass-wizard` popup for entries the user types, the `pass-copy` popup for Ctrl+V logins, GPG unlock, and `pass-clip-scrub` to purge copied secrets from the Walker clipboard history.

**Use when:**
- "save it in pass", "is X in pass?", "copy my password", "pass wizard"
- Driving any website login/signup in Chrome
- Sharing or moving a credential to the desktop

## Skill Directory Structure

```
/home/prabhanshu/Programs/.claude/skills/
├── README.md                          # This file
├── conversation-recall/
│   └── SKILL.md                       # Conversation search skill
└── debug-with-logging/
    └── SKILL.md                       # Automation debugging skill
```

## Creating New Skills

Follow this template structure:

```markdown
---
name: my-skill-name
description: Clear description of what this skill does and when to use it
---

# My Skill Name

[Instructions that Claude will follow when this skill is active]

## When to Use This Skill
- Trigger condition 1
- Trigger condition 2

## How It Works
1. Step 1
2. Step 2

## Output Format
[Expected format of results]
```

### Best Practices

1. **Keep SKILL.md concise** (under 5,000 words)
2. **Clear name and description** - Claude uses these to decide when to trigger
3. **One level deep references** - Link directly from SKILL.md to reference files
4. **Progressive disclosure** - Start with metadata, load details as needed

## Learn More

- [Agent Skills Overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- [Skill Authoring Best Practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [GitHub - anthropics/skills](https://github.com/anthropics/skills)
- [Inside Claude Code Skills](https://mikhail.io/2025/10/claude-code-skills/)
