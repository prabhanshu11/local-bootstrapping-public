# Voice Typing Desktop Sync

How we fixed `local-bootstrapping` so `git pull && ./install.sh` fully deploys voice typing.

## Timeline

- **Jan 2026**: Voice typing stack built on laptop (AssemblyAI gateway, hyprwhspr config)
- **Late Jan 2026**: Deepgram streaming, local-whisper offline fallback, MicOSD overlay added
- **Feb 2026**: Discovered `setup-voice-typing.sh` had gaps — desktop couldn't be synced automatically

## The Problem

After weeks of voice typing development on the laptop, the desktop was out of sync. Running `setup-voice-typing.sh` on desktop would:
- Copy configs and systemd units
- Enable services
- ...then print "clone the repo and build manually"

The script was a **partial deployer** — it handled dotfiles but not the application stack.

## Gaps Found

| Component | Was Deployed | Gap |
|-----------|-------------|-----|
| hyprwhspr config | Yes | — |
| systemd overrides | Yes | — |
| toggle/layout scripts | Yes | — |
| **hyprwhspr-patch** (MicOSD + runner) | **No** | Not copied to `~/.local/lib/hyprwhspr-patch/` |
| **voice-gateway binary** | **No** | Only a "please build manually" warning |
| **local-whisper venv** | **No** | Only a "please run uv sync" warning |
| **.env API keys** | **No** | Not populated from `pass` |
| **hyprwhspr credential store** | **No** | Custom WebSocket provider needs a dummy key |
| **MicOSD window rules** | Partial | Symlink in install.sh but source line not always appended |

## Fixes Applied

### 1. hyprwhspr-patch deployment (CRITICAL)
Without `~/.local/lib/hyprwhspr-patch/`, hyprwhspr crashes on startup because the systemd override runs `main.py` from that path.

```bash
# Added to setup-voice-typing.sh
cp -r "$DOTFILES/local-lib/hyprwhspr-patch/"* ~/.local/lib/hyprwhspr-patch/
```

### 2. Gateway binary build
```bash
if [[ ! -f "$VT_DIR/gateway/voice-gateway" ]]; then
    (cd "$VT_DIR/gateway" && go build -o voice-gateway ./cmd/server)
fi
```

### 3. local-whisper venv
```bash
if [[ ! -d "$VT_DIR/local-whisper/.venv" ]]; then
    (cd "$VT_DIR/local-whisper" && uv sync)
fi
```

### 4. .env from pass
```bash
ASSEMBLYAI_KEY=$(pass show api/assemblyai 2>/dev/null || true)
echo "ASSEMBLYAI_API_KEY=$ASSEMBLYAI_KEY" >> "$VT_DIR/.env"
```

### 5. hyprwhspr credential store
The upstream hyprwhspr validates API keys even for custom/local WebSocket providers. We store a dummy credential:
```json
{"custom": "local-gateway-no-auth-needed"}
```
in `~/.local/share/hyprwhspr/credentials`.

## Desktop GPU: RTX 2060 SUPER

- 8GB VRAM, Compute 7.5 (Turing)
- `distil-large-v3` uses ~1089MB VRAM
- Default model set to `distil-large-v3` in `local-whisper.service`
- First model download takes ~2 minutes; subsequent loads ~5 seconds

## Philosophy

The local-bootstrapping repo should be the **single source of truth** for machine setup. `git pull && ./install.sh` on any machine should:

1. Symlink all dotfiles
2. Deploy application support files (hyprwhspr-patch)
3. Build binaries if missing (voice-gateway)
4. Create venvs if missing (local-whisper)
5. Populate secrets from `pass` if available
6. Enable and configure all services

No manual steps. If something needs to be done by hand, it means the script has a gap.
