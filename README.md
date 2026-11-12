# local-bootstrapping

Machine setup and disaster recovery for my [Omarchy](https://omarchy.org) (Arch Linux + Hyprland)
laptop and desktop: one repo that installs the packages, links the dotfiles, enables the services
and keeps both machines from drifting apart.

**This is a published snapshot of a private working repo.** It is exported by a script, so:

- there is no commit history here beyond one commit per export;
- addresses, MAC addresses, Wi-Fi names and e-mail are placeholders
  (`100.64.0.x`, `203.0.113.x`, `02:00:00:00:00:xx`, `home-wifi`, `you@example.com`);
- incident write-ups, screenshots, the remote-desktop and file-share setup, the PAM files and a
  few other private components are left out, so some paths that scripts or docs mention do not
  exist here;
- it is built for my two machines (a ThinkPad T14 and a desktop). Read before you run anything:
  `scripts/install.sh` changes system files and expects my layout under `~/Programs/`.

Take it as a source of ideas and working pieces rather than a turnkey installer.

## What is in it

| Path | What |
|------|------|
| `scripts/install.sh` | The installer: packages, Tailscale, firewall, SSH, `pass`, symlinks, user services |
| `scripts/lib/reconcile.sh` | Self-heal run on a timer: re-links what drifted, never overwrites differing content |
| `scripts/sync-from-master.sh`, `scripts/validate-configs.sh` | Pull every 10 minutes on every machine, refuse a commit that fails validation |
| `dotfiles/hypr`, `dotfiles/waybar` | Hyprland and Waybar configuration |
| `dotfiles/local-bin/` | About a hundred small tools, see below |
| `dotfiles/systemd-user/`, `system/` | User units and root-installed system files |
| `machine-specific/` | What differs between the desktop and the laptop |
| `dotfiles/.claude/` | Claude Code skills, hooks and the status line I use |
| `docs/` | Design notes and lessons learnt |
| `tests/` | Unit, touch and visual tests for the tools |

## Pieces that may be useful on their own

- **Touch-friendly Waybar** — `dotfiles/local-bin/bar-touch`, `touch-mode`, `docs/touch-bar.md`:
  every bar module usable by finger, long-press cards, an open-windows overview, a virtual
  touchscreen for tests (`tests/touch/`).
- **sudo with hardware auth and a notification** — `dotfiles/local-bin/sudo-with-notify`
  (fingerprint / FIDO key with a desktop notification, password fallback, a remote variant over SSH).
- **Battery guard** — `dotfiles/local-bin/battery-guard`, `battery-info`: charge limits, hibernate
  before empty, a charger rating from the USB-PD offers.
- **Sleep that is verified** — `sleep-verified`, `sleep-watch`, `docs/suspend-deep-sleep.md`.
- **Wi-Fi and network self-healing** — `system/bin/net-selfheal`, `wifi-wedge-watchdog`,
  `docs/rtl8821au-lps-wedge.md`.
- **OOM protection for agent-heavy work** — `docs/oom-guard-hook.md`, `docs/oom-protection-lessons.md`,
  `configs/agent-nice/`.
- **Claude Code extras** — the status line (`docs/claude-statusline.md`), the subagent context
  guard (`docs/subagent-context-guard-hook.md`), the memory index lint (`docs/memory-index-lint.md`).
- **Workspace labels and a monitor chooser** — `dotfiles/local-bin/workspace-labels`,
  `apps/monitor-chooser/` (Rust).

## Secrets

No secret lives in this repo. Everything sensitive is read at run time from
[`pass`](https://www.passwordstore.org/) (GPG-encrypted); `dotfiles/bashrc.d/secrets.sh` shows the pattern.

## Licence

MIT, see [LICENSE](LICENSE). Third-party parts are listed in [NOTICE](NOTICE).
