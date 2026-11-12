# STOP - Review Before Stash

This file exists as a reminder: **Never stash without reviewing what you're hiding.**

## Before `git stash`

```bash
# ALWAYS run these first:
git diff              # See what changes exist
git diff --stat       # Summary view
git stash list        # Check existing stashes
```

## Why This Matters

- Stashed work is hidden work - easy to forget
- Another agent may have left work-in-progress
- Features slip through the cracks when stashed blindly
- Uncommitted changes on another machine may be important

## Cross-Machine Check

```bash
# Before working on shared repos, check ALL machines:
ssh desktop "cd ~/Programs/local-bootstrapping && git status --short"
ssh laptop "cd ~/Programs/local-bootstrapping && git status --short"
```

## If You Find Uncommitted Changes

1. **READ them** - `git diff` to understand what they are
2. **DECIDE** - Should they be committed? Discarded? Continued?
3. **DOCUMENT** - If discarding, note why in progress_actual.md
4. **NEVER** blindly stash or discard

## Drift Detector

This repo has an automated drift detector that runs hourly:
- Logs: `~/.local/state/drift-detector/drift.log`
- Manual check: `~/Programs/local-bootstrapping/scripts/drift-detector.sh`
- Cross-machine: `drift-detector.sh --check-remote`
