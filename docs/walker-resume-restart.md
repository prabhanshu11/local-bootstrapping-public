# Power Menu Dies After Suspend (Walker Vulkan Device Lost)

## Symptom

The physical power button stops popping up the Omarchy system menu. Super+Space
and every other Walker-backed menu break the same way. Nothing looks broken —
the `walker` process is still alive and the Hyprland bind is still correct.

## Root Cause

Walker renders via Vulkan. When the GPU is powered down across a suspend/resume
cycle, Walker's Vulkan context is invalidated and the process spins forever on:

```
vkWaitForFences(): The logical or physical device has been lost. (VK_ERROR_DEVICE_LOST) (-4)
vkQueueSubmit():   The logical or physical device has been lost. (VK_ERROR_DEVICE_LOST) (-4)
```

Because the process never exits, systemd never restarts it. It stays up serving
menus that silently fail to render. Restarting Walker fixes it instantly.

## Diagnosis

```bash
# Is Walker in the device-lost state?
journalctl --user -b -u app-walker@autostart.service | grep -c VK_ERROR_DEVICE_LOST

# Correlate with suspends this boot
journalctl -b -o short-iso | grep -E "PM: suspend entry|PM: suspend exit"
```

A nonzero count plus a preceding `PM: suspend exit` confirms it.

## Fix

`system/systemd/walker-resume-restart.service` — a system unit wanted by
`suspend.target` / `hibernate.target` / `hybrid-sleep.target` /
`suspend-then-hibernate.target` that restarts `elephant.service` and
`app-walker@autostart.service` as the user after every resume. Installed and
enabled by `install.sh` → `setup_walker_resume_restart()`.

Manual recovery, if ever needed: `omarchy-restart-walker`

## Relationship to the Deep Sleep (S3) Change — UNRESOLVED

**Correction (2026-07-20):** an earlier version of this document claimed the
2026-07-20 breakage was caused by the 03:54 s2idle resume and was unrelated to
the deep sleep change. **That claim was wrong** and has been retracted. It was
based on an assumption about when the errors began, not on the log.

The actual journal evidence for that boot:

| Time (2026-07-20) | Event |
|---|---|
| 03:53:45 | `Started Walker.` (PID 1970) |
| 03:54:08 | `PM: suspend entry (s2idle)` |
| 03:54:21 | `PM: suspend exit` — **Walker survives this cleanly, zero VK errors** |
| 03:54–04:06 | Power menu **confirmed working** (used repeatedly by the user) |
| 04:00:20 | `mem_sleep_default=deep` written to `/etc/default/limine`; `limine-update` run |
| 04:00:54 | `echo deep > /sys/power/mem_sleep` |
| **04:06:08** | **First `VK_ERROR_DEVICE_LOST`** — no suspend in between |
| 04:08:42 | Walker restarted manually → menu works again |

Key facts:

- Only **one** suspend occurred during the entire boot (03:54, s2idle), and
  Walker demonstrably survived it.
- The failure began **~5 minutes after the deep sleep change**, with **no
  intervening suspend, GPU reset, or DRM error** (GPU is Intel i915; the kernel
  log shows no `drm`/GPU hang events at that time).

**What is established:** the breakage is temporally correlated with the deep
sleep change, and is *not* explained by a suspend/resume cycle.

**What is NOT established:** a mechanism. Writing to `/sys/power/mem_sleep` only
changes what happens at the *next* suspend and should not affect a running GPU
context; `limine-update` regenerates boot files and likewise should not. So the
correlation is real but unexplained — do not treat either direction as settled.

**Open question for next occurrence:** capture `journalctl --user -b -u
app-walker@autostart.service | grep -m1 VK_ERROR_DEVICE_LOST` for the first
error timestamp, and correlate against `PM: suspend entry` and any
`limine-update` / boot-config activity. That is the datum that distinguishes the
two hypotheses; it was not collected in June.

## Status of the Fix in This Document

`walker-resume-restart.service` handles the **resume** case, which is the
documented June 2026 failure mode and a real risk under S3 (the GPU powers off
completely, so a lost Vulkan context on resume is expected).

It is a reasonable safety net and is harmless, **but it is not proven to address
the 2026-07-20 occurrence**, which happened without a suspend. If the power menu
dies again with no suspend involved, this unit will not catch it and the real
trigger still needs to be found.

## Recurrence History

| Date | Trigger | Response |
|---|---|---|
| 2026-06-17 | s2idle resume (Walker up 3 days) | Diagnosed via Codex; Walker restarted by hand; power-button helper made durable in this repo (`f62d60d`). Root cause identified but not automated — so it recurred. |
| 2026-07-20 | s2idle resume at 03:54 | Walker restarted; **automated** via `walker-resume-restart.service` so it cannot recur silently. |
