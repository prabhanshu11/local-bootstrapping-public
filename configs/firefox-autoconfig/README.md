# Firefox AutoConfig: middle-click must not close a tab

**His ask (2026-10-23):** "When i press middle button, tab closes in firefox.
Prevent that behaviour."

Firefox has no about:config pref for this. The close-on-middle-click is
hard-coded in `tabbrowser/tabs.js` (`on_click`, `event.button == 1` →
`gBrowser.removeTab`). Verified by reading the code shipped in
`/usr/lib/firefox/browser/omni.ja` for Firefox 151.0.1.

## How it works

AutoConfig is Firefox's own mechanism for privileged startup scripts:

| File | Installed to | Role |
|------|--------------|------|
| `autoconfig.js` | `/usr/lib/firefox/defaults/pref/autoconfig.js` | tells Firefox to load `firefox.cfg`, sandbox off |
| `firefox.cfg` | `/usr/lib/firefox/firefox.cfg` | adds a capture-phase listener on the tab strip that swallows button-1 clicks on a tab |

Middle-click on page links (open in new tab) and on the empty tab strip
(new tab) keep working; only "middle-click a tab = close it" is removed.

## Install

```bash
sudo-with-notify "firefox autoconfig" -- sudo scripts/setup-firefox-autoconfig.sh
```
Then restart Firefox.

## Notes

- Both files are unowned by the `firefox` pacman package, so they survive
  upgrades (pacman only removes files it owns). If Firefox ever moves its
  install dir, re-run the setup script.
- Add further UI patches to `firefox.cfg` as numbered sections; keep the
  first line a comment (Firefox skips line 1 of the cfg).
- Remove: `sudo rm /usr/lib/firefox/firefox.cfg /usr/lib/firefox/defaults/pref/autoconfig.js`.
