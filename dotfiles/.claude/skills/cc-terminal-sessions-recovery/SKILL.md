---
name: cc-terminal-sessions-recovery
description: Reopen crashed ghostty terminal windows that held Claude Code sessions, each on its old workspace with a `claude -r <id> --chrome  # what it was about` command typed but NOT run. Use when he says terminals/ghostty/claude windows "crashed", "closed", "died", "recover my windows", or after a failed hibernate, reboot or power loss. (For recovering the CONTEXT of one broken conversation, use session-recovery instead.)
allowed-tools:
  - Bash
  - Read
---

# Claude Code terminal sessions recovery

His rule (2026-10-31): open one terminal per dead session, on the workspace it was on, with
`claude -r <id> --chrome  # <what that chat was about, what it was waiting on>` typed on the prompt
and NOT run. Write the comment after reading a short stretch of the transcript and summarising it.
He presses Enter himself. Never start the sessions for him.

Past runs: 2026-10-06 (failed hibernate), 2026-10-18 (ghostty segfault from the monitor-persist flap
loop), 2026-10-31 (ghostty GTK segfault at 14:42; a single ghostty process held 5 windows on
workspaces 3, 4 and 5, and he named only the two on ws 3).

## 1. Find the crash and everything it took

```bash
journalctl --user --since '<crash-5min>' --until '<crash+5min>' --no-pager | grep -iE 'ghostty|coredump|segfault'
```
One ghostty process holds MANY windows. Recover every window it took, on all workspaces, not only the
ones he mentions, and tell him about the extra ones.

## 2. Read the snapshot from just before the crash

The `laptop-state-snapshot` user timer runs every 5 min.
```bash
laptop-state-restore --list | tail
laptop-state-restore --print ~/.local/state/laptop-state/history/<last ts before crash>.json
```
This prints every running session (cwd + resume line + last prompt) and the windows on each workspace.
Match windows to sessions by the ghostty title ("✳ <topic>"), which is the session's title in the
transcript (`custom-title` / `ai-title` rows in `~/.claude/projects/<proj>/<id>.jsonl`).

Skip sessions whose process survived: `ps -eo args | grep -- --resume`.
A window whose session has no `.jsonl` never saved a conversation, so there is nothing to resume. Say so.

## 3. Write the comment for each session

From the transcript, read (non-sidechain rows only; transcripts can be 10+ MB, so stream them with Python):
the first user prompt, the last 3-4 user prompts, and the end of the last assistant text.
Comment = topic + what it was doing or waiting on, one line. No single quotes inside it.

## 4. Spawn the windows

```bash
P=/home/prabhanshu/.local/bin/prefill-shell   # absolute: hyprctl exec has no ~/.local/bin on PATH
hyprctl dispatch exec "[workspace N silent] ghostty -e $P <cwd> 'claude -r <id> --chrome  # <comment>'"
```
`<cwd>` = the session's cwd from the snapshot (it decides which project dir `-r` looks in).
Sleep ~1.5 s between spawns. `prefill-shell` lives in `local-bootstrapping/dotfiles/local-bin/`.

## 5. Verify

`hyprctl clients -j` shows the new windows on the right workspaces; a half-scale `grim -s 0.5`
of the visible workspace shows the typed commands. Then list each recovered window and its
one-line comment for him.
