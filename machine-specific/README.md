# machine-specific/

Per-device files for `scripts/install.sh` and the 10-minute sync self-heal
(`scripts/lib/reconcile.sh`). The device name comes from `detect_device`
(Tailscale IP, else battery = laptop).

| File | Meaning |
|---|---|
| `<device>/symlinks.conf` | `src:dst` links overlaid on `SYMLINKS`; same `dst` replaces the common entry |
| `<device>/drift-exceptions.conf` | `kind key # reason`: known differences the sync neither fixes nor reports |
| `<device>/setup.sh` | optional, run by a full `install.sh` only |

A device with no directory here gets the common `SYMLINKS` unchanged.
