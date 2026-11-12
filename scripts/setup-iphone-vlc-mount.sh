#!/usr/bin/env bash
# Auto-mount the iPhone's VLC Documents folder at ~/iPhone-VLC whenever the iPhone is plugged in (USB).
# Idempotent. Needs: ifuse (extra), usbmuxd (already present), the phone unlocked + trusted.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if ! pacman -Q ifuse >/dev/null 2>&1; then
  # The omarchy mirror's sync db can lag its files ("Exceeded the maximum allowed file size"):
  # fall back to the signed package from the Arch archive.
  sudo-with-notify "install ifuse" -- sudo pacman -S --noconfirm --needed ifuse || {
    v="$(pacman -Si ifuse | awk '/^Version/{print $3}')"; t="$(mktemp -d)"
    curl -fsSL -o "$t/ifuse.pkg.tar.zst" "https://archive.archlinux.org/packages/i/ifuse/ifuse-$v-x86_64.pkg.tar.zst"
    curl -fsSL -o "$t/ifuse.pkg.tar.zst.sig" "https://archive.archlinux.org/packages/i/ifuse/ifuse-$v-x86_64.pkg.tar.zst.sig"
    sudo-with-notify "install ifuse (archive)" -- sudo pacman -U --noconfirm "$t/ifuse.pkg.tar.zst"
  }
fi
sudo-with-notify "install iPhone VLC udev rule" -- sudo sh -c "install -m644 '$REPO/system/udev-rules/90-iphone-vlc-mount.rules' /etc/udev/rules.d/ && udevadm control --reload && udevadm trigger --subsystem-match=usb --attr-match=idVendor=05ac"
mkdir -p ~/.config/systemd/user ~/iPhone-VLC
ln -sf "$REPO/dotfiles/systemd/user/iphone-vlc-mount.service" ~/.config/systemd/user/iphone-vlc-mount.service
systemctl --user daemon-reload
echo "done: plug in the iPhone -> ~/iPhone-VLC"
