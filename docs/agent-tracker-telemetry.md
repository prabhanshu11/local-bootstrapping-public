# Claude Code token telemetry → local sink (laptop + desktop), 2026-11-02

His ask (agent-tracker, 2026-11-02): see per agent how many tokens it has used and will use. His answer to "turn on Claude Code's
usage telemetry, sent only to the tracker on this laptop and the desktop": **"Yes, local only"**.

What is installed on each machine (by `~/Programs/agent-tracker/deploy/install-telemetry.sh`, no sudo):
- `~/.claude/settings.json` → `env`: `CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_LOGS_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`,
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318`, `OTEL_LOGS_EXPORT_INTERVAL=5000` (a dated `settings.json.bak-agent-tracker-*` copy is kept).
  Prompt and response text stay `<REDACTED>` (OTEL_LOG_USER_PROMPTS is not set).
- `~/.config/systemd/user/service.d/zz-agent-tracker-otel.conf`: the same env + `OTEL_RESOURCE_ATTRIBUTES=agent.unit=%n` for EVERY user
  service, so calls from units that pass `--setting-sources ""` are reported and named by unit.
- User unit `agent-tracker-otel-sink.service` → `~/.local/share/agent-tracker/telemetry_sink.py` on 127.0.0.1:4318, writes
  `~/.local/state/agent-tracker/calls-YYYY-MM.jsonl` (one line per API request: model, effort, tokens, cost, unit, cwd, caller).
Undo: `install-telemetry.sh --undo` (renames the drop-in, removes the env keys, disables the sink; the call logs stay).
Verified 2026-11-02 02:4x IST: laptop + desktop, including a `systemd-run --user` call with `--setting-sources ""` (attributed to its unit).
