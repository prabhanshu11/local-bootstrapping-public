---
name: sudo-with-notify
description: Handle sudo authentication across local and remote machines using hardware auth (fingerprint/YubiKey) with automatic password fallback. Use when any command needs sudo, privilege escalation, or root access — whether local or via SSH. Triggers on "sudo", "root", "install package", "system update", or any operation requiring elevated privileges.
allowed-tools:
  - Bash
  - Read
---

# sudo-with-notify — Universal Sudo Authentication

## Philosophy

The purpose of this system is that **the user never types a password and the agent never stops working**. Hardware auth (fingerprint on laptop, YubiKey on desktop) makes sudo invisible — a beep sounds, the user touches the device, and the command runs. No typing, no interruption.

When hardware auth is unavailable (device dead, user not physically at the machine), the tmux password fallback is a pragmatic compromise — it requires the user to type a password, but the prompt appears automatically on their screen wherever they are. The agent handles everything; the user only ever types a password or touches hardware.

**Ideal hierarchy (best to worst):**
1. Hardware auth available → silent, no user typing (ideal)
2. Hardware auth unavailable → password prompt appears on user's screen (fallback)
3. ~~User runs commands manually~~ — **NEVER. This is not acceptable.**
4. ~~Agent uses raw `sudo` or `ssh -tt ... sudo`~~ — **NEVER.**

## Agent Rules — BINDING

1. **ALWAYS use `sudo-with-notify`** for local sudo commands
2. **ALWAYS use `sudo-with-notify-remote`** for sudo on remote machines via SSH
3. **NEVER use raw `sudo`**, `ssh -tt ... sudo`, or any other method
4. **NEVER tell the user to run a command** — the agent handles everything. The user only types a password when a prompt appears on their screen, or touches their fingerprint/YubiKey.
5. **When the tmux fallback triggers, tell the user WHY**: "Hardware auth on [host] failed — device unreachable or you're not physically there. A password prompt has opened on your screen."

## Commands

### Local sudo (same machine)
```bash
sudo-with-notify "description" -- sudo command args...
sudo-with-notify "description" delay -- sudo command args...
```

**Flow:**
1. Check if credentials cached → exec immediately
2. Beep + notify → try hardware auth (fingerprint/YubiKey) up to 3 times
3. If local display available → open popup terminal for password
4. If no display (headless) → exit 2 (tmux fallback, handled by remote wrapper)

### Remote sudo (via SSH)
```bash
sudo-with-notify-remote <ssh-host> "description" -- sudo command args...
sudo-with-notify-remote <ssh-host> "description" delay -- sudo command args...
```

**Flow:**
1. SSH to remote, run `sudo-with-notify` there
2. If hardware auth works (exit 0) → done
3. If hardware auth fails (exit 2) → open foot terminal on LOCAL machine showing remote tmux session → password prompt appears on user's screen → poll for result → re-run command with cached credentials

## Auth Landscape

| Machine | PAM order | Hardware |
|---------|-----------|----------|
| Laptop | fprintd → pam_u2f → pam_unix | Fingerprint reader (YubiKey if plugged in) |
| Desktop | pam_u2f → pam_unix | YubiKey on Honeywell USB hub |

**Hostname is part of the key's identity (2026-10-01).** pam_u2f's rp id defaults to `pam://$(hostname)`; the credential was enrolled as `pam://omarchy`, so `origin`/`appid` are pinned to that in `system/pam.d/sudo`. A key that fails *instantly without lighting up* = rp id / hostname mismatch, and every such miss also feeds `pam_faillock` (10 in 120 s locks the account, correct password refused). See `docs/issues/hostname-rename-breaks-fido-sudo-2026-10-01.md`.

YubiKey requires physical touch — it lights up and the user touches it. Fingerprint requires the user to place their finger on the reader. Both are "touch and done" — no typing.

## Timing

- **Default 2-second delay** after beep — gives time to position finger/hand
- **Configurable**: pass delay as second arg (e.g., `1` for fast ops, `0` for immediate)
- **Both machines are notified** (2026-09-15): `sudo-with-notify-remote` beeps (`sudo-beep1k.wav`, `--volume=18500`) and shows a critical `notify-send` on the CALLING machine before the ssh, and `sudo-with-notify` on the remote beeps/notifies there. The user asked for this on 2026-02-16, 02-21, 09-11 and 09-14; it was lost each time it lived in a session-local wrapper. Do not add another wrapper — fix the helper.
- **Batch remote sudo**: per-tty sudo timestamps mean every ssh call re-prompts. Write one logged script per phase and run it under one `sudo bash script.sh` so touches are rare.

## Notification visibility (2026-09-17)

- **One slot, never sticky.** Every notification of the family carries the hint `x-canonical-private-synchronous:sudo-auth` (each replaces the previous one) and an expiry; `sudo-with-notify` runs `sudo-notify --clear` as soon as authentication is over. Critical notifications never expire in mako, and mako keeps its single surface on the monitor where the first visible notification was born — eight stale "Authentication Required/Failed" popups had pinned it to eDP-1 while the user worked on HDMI-A-2, so he heard the beep and saw nothing.
- **Wrong-monitor fallback.** If mako's surface already sits on a non-focused monitor (another app's sticky notification), `sudo-notify` also raises a Hyprland-native `hyprctl notify`, which always renders on the focused monitor.
- **"Beep but no notification" → check first:** `hyprctl layers | grep -B3 'namespace: notifications'` against the focused monitor in `hyprctl monitors`, and `makoctl list` for a sticky pile. Do not touch the beep.

## Script Locations

| Script | Purpose | Location |
|--------|---------|----------|
| `sudo-notify` | Basic beep + notify-send | `dotfiles/local-bin/sudo-notify` |
| `sudo-with-notify` | Retry + popup/tmux fallback | `dotfiles/local-bin/sudo-with-notify` |
| `sudo-with-notify-remote` | Local wrapper for remote sudo | `dotfiles/local-bin/sudo-with-notify-remote` |
| `sudo-popup-auth` | GUI popup terminal for password | `dotfiles/local-bin/sudo-popup-auth` |
| `check-sudo-popup.sh` | Stop hook — detects auth signal | `dotfiles/.claude/hooks/check-sudo-popup.sh` |

## Stop Hook (user-away scenario)

When the user is away and all auth methods time out, `/tmp/sudo-auth-signal` is written. The Stop hook (`check-sudo-popup.sh`) reads it on the next conversation turn and injects context:
- "credentials cached" → agent re-runs the failed command immediately
- "user present but not authenticated" → agent re-runs `sudo-with-notify`
