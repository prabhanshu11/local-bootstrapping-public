#!/usr/bin/env python3
"""subagent-context-guard.py — Claude Code hook (global, stdlib only).

Enforces the "retire subagents at ~240k context" discipline.

Why: each subagent turn re-reads its whole context, so cost grows with context
size on every turn — and past a point the extra context stops helping and starts
hurting: the agent loses the goal in the noise and drifts (mission creep). This
happens regardless of the model's nominal window. The remedy is a graceful
retirement: the bloated agent writes a handover, a fresh successor picks up.

The number this hook measures is the same one Claude Code prints as
<subagent_tokens> in task notifications: the agent's CURRENT CONTEXT SIZE
(last turn's input + cache_read + cache_creation + output), read from the
agent's own transcript file — NOT cumulative billed tokens.

Events handled (register the same command for all of them):
  SubagentStop          measure the agent that just stopped, remember it, and
                        surface a WARN/RETIRE line to the user (systemMessage)
                        when it crosses a threshold.
  PreToolUse  Agent     inject a fleet status line (every agent at/over WARN)
                        so the orchestrator knows who is due for retirement
                        before it spawns/plans more work.
  PreToolUse  SendMessage
                        THE GATE. Sending new work to an agent at/over RETIRE
                        is denied with a handover recipe — unless the message
                        carries an explicit override:  [long-context-ok: why]
                        Agents at/over WARN get an advisory additionalContext.
  PostToolUse Agent     remember agentId -> description so status lines are
                        readable.
  PostToolUse *         (main session only; skipped inside subagents) measure
                        THIS session's context; first crossing of MAIN_WARN /
                        MAIN_STRONG injects a nudge to the model and a line to
                        the user. Warning only — never blocks.

FAIL-SAFE CONTRACT: this hook must never break a session. On ANY error it exits
0 with no output (= allow). It denies ONLY a SendMessage to an agent whose
context it measured cleanly at/over the RETIRE threshold.

Disable without editing settings.json:
    touch ~/.claude/hooks/.subagent-context-guard-off
Tunables (env):
    SUBAGENT_CTX_WARN    default 9000000 (subagent gating EXPIRED by the user 2026-09-30 19:2x; main-session nudges stay)
    SUBAGENT_CTX_RETIRE  default 9999000 (expired — see above)
    SUBAGENT_CTX_MAIN_WARN    default 340000  (top-level session, warn only)
    SUBAGENT_CTX_MAIN_STRONG  default 600000  (top-level session, strong nudge)
    SUBAGENT_CTX_STATE   state dir, default ~/.claude/hooks/state/subagent-context
"""
import json
import os
import re
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME", "~")).expanduser()
OFF_SWITCH = HOME / ".claude/hooks/.subagent-context-guard-off"
WARN = int(os.environ.get("SUBAGENT_CTX_WARN", "9000000"))
RETIRE = int(os.environ.get("SUBAGENT_CTX_RETIRE", "9999000"))
# Top-level (main session) thresholds. Main warn 340k (2026-09-30 per the user: subagents retire at 550k, main auto-compacts at 750k) as subagents: one
# number to remember. The strong nudge sits higher because retiring the main
# agent means a session handover the user has to act on.
MAIN_WARN = int(os.environ.get("SUBAGENT_CTX_MAIN_WARN", "340000"))
MAIN_STRONG = int(os.environ.get("SUBAGENT_CTX_MAIN_STRONG", "600000"))
STATE_DIR = Path(os.environ.get("SUBAGENT_CTX_STATE", str(HOME / ".claude/hooks/state/subagent-context")))
OVERRIDE_RE = re.compile(r"\[long-context-ok\s*(?::\s*([^\]]*))?\]", re.I)
TAIL_CHUNK = 64 * 1024
TAIL_MAX = 16 * 1024 * 1024  # never scan more than this from the end of a transcript


# ----------------------------------------------------------------- helpers ---
def k(n):
    return f"{n/1000:.0f}k"


def log(msg):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(STATE_DIR / "guard.log", "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
    except Exception:
        pass


def measure_context(path):
    """Return the agent's current context size from its transcript, or None.

    Reads the file backwards in chunks and takes the LAST assistant message
    with a usage block. Falls back to the fork header's contextLength.
    """
    p = Path(path)
    if not p.is_file():
        return None
    size = p.stat().st_size
    with open(p, "rb") as f:
        buf = b""
        pos = size
        scanned = 0
        while pos > 0 and scanned < TAIL_MAX:
            step = min(TAIL_CHUNK, pos)
            pos -= step
            f.seek(pos)
            buf = f.read(step) + buf
            scanned += step
            lines = buf.split(b"\n")
            # lines[0] may be partial unless pos == 0; scan the complete ones
            start = 0 if pos == 0 else 1
            for line in reversed(lines[start:]):
                if b'"usage"' not in line or b'"assistant"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "assistant":
                    continue
                u = (d.get("message") or {}).get("usage") or {}
                ctx = sum(int(u.get(x) or 0) for x in (
                    "input_tokens", "cache_creation_input_tokens",
                    "cache_read_input_tokens", "output_tokens"))
                if ctx > 0:
                    return ctx
            buf = lines[0] if start else b""
        # No assistant turn yet: a forked agent starts with inherited context
        f.seek(0)
        try:
            head = json.loads(f.readline())
            if isinstance(head.get("contextLength"), int):
                return head["contextLength"]
        except Exception:
            pass
    return None


def subagents_dir(inp):
    """~/.claude/projects/<proj>/<session_id>/subagents, derived from transcript_path."""
    tp = inp.get("transcript_path")
    if tp:
        d = Path(tp).with_suffix("") / "subagents"
        if d.is_dir():
            return d
    sid = inp.get("session_id")
    if sid:
        for d in (HOME / ".claude/projects").glob(f"*/{sid}/subagents"):
            return d
    return None


def transcript_for(inp, agent_id):
    atp = inp.get("agent_transcript_path")
    if atp and Path(atp).is_file():
        return Path(atp)
    d = subagents_dir(inp)
    if d:
        p = d / f"agent-{agent_id}.jsonl"
        if p.is_file():
            return p
    return None


def sid(inp):
    return (inp.get("session_id") or "unknown")[:8]


def state_path(inp):
    sid = inp.get("session_id") or "unknown"
    return STATE_DIR / f"{sid}.json"


def load_state(inp):
    try:
        return json.loads(state_path(inp).read_text())
    except Exception:
        return {}


def save_state(inp, st):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = state_path(inp).with_suffix(".tmp")
        tmp.write_text(json.dumps(st, indent=1))
        tmp.replace(state_path(inp))
    except Exception:
        pass


def level(ctx):
    if ctx is None:
        return None
    if ctx >= RETIRE:
        return "RETIRE"
    if ctx >= WARN:
        return "WARN"
    return "ok"


def label(st, aid):
    rec = st.get(aid) or {}
    desc = rec.get("description") or rec.get("agent_name")
    return f"{aid[:8]}… ({desc})" if desc else f"{aid[:8]}…"


def resolve_agent(inp, st, to):
    """SendMessage `to` may be an agent id or a description/name."""
    if not to:
        return None
    if transcript_for(inp, to):
        return to
    low = to.strip().lower()
    for aid, rec in st.items():
        for key in ("agent_name", "description"):
            if (rec.get(key) or "").strip().lower() == low:
                return aid
    return None


def fleet(inp, st):
    """[(agent_id, ctx)] for every agent transcript in this session at/over WARN."""
    d = subagents_dir(inp)
    if not d:
        return []
    out = []
    for p in d.glob("agent-*.jsonl"):
        aid = p.stem[len("agent-"):]
        ctx = measure_context(p)
        if ctx is not None:
            st.setdefault(aid, {})["ctx"] = ctx
            if ctx >= WARN:
                out.append((aid, ctx))
    out.sort(key=lambda t: -t[1])
    return out


HANDOVER = (
    "Retire it gracefully: ask it (one final message, tagged [long-context-ok: handover]) "
    "for a handover doc — what is done, what is left, exact file paths, gotchas, "
    "verified facts — then spawn a FRESH agent with that handover plus the new task. "
    "Do not resume the bloated agent with new work."
)


# ------------------------------------------------------------------ events ---
def on_subagent_stop(inp):
    aid = inp.get("agent_id") or inp.get("agentId")
    if not aid:
        return None
    tp = transcript_for(inp, aid)
    ctx = measure_context(tp) if tp else None
    if ctx is None:
        # Fallback: the event's own counters (last turn, may omit cache reads)
        it, ot = inp.get("input_tokens"), inp.get("output_tokens")
        if isinstance(it, int) and it > 0:
            ctx = it + (ot if isinstance(ot, int) else 0)
    if ctx is None:
        return None
    st = load_state(inp)
    rec = st.setdefault(aid, {})
    prev = rec.get("announced")
    rec.update(ctx=ctx, updated=int(time.time()))
    for key in ("agent_name", "agent_type"):
        if inp.get(key):
            rec[key] = inp[key]
    lvl = level(ctx)
    out = None
    if lvl == "RETIRE":
        # ledger: every stop past the limit, so the log shows how far an agent was let run
        rec["stops_over_limit"] = rec.get("stops_over_limit", 0) + 1
        log(f"OVER {sid(inp)} {aid} ctx={ctx} stop#{rec['stops_over_limit']} desc={rec.get('description') or rec.get('agent_name') or ''!r}")
    if lvl in ("WARN", "RETIRE") and prev != lvl:
        rec["announced"] = lvl
        if lvl == "RETIRE":
            msg = (f"⛔ subagent-context-guard: agent {label(st, aid)} stopped at {k(ctx)} context "
                   f"(≥ {k(RETIRE)} soft limit). Retire it: handover doc + fresh successor. "
                   f"SendMessage to it is now gated.")
        else:
            msg = (f"⚠ subagent-context-guard: agent {label(st, aid)} at {k(ctx)} context "
                   f"(retire at {k(RETIRE)}). Plan its handover now.")
        out = {"systemMessage": msg}
        log(f"CROSS {sid(inp)} {aid} ctx={ctx} level={lvl}")
    save_state(inp, st)
    return out


def on_pre_agent(inp):
    st = load_state(inp)
    hot = fleet(inp, st)
    save_state(inp, st)
    if not hot:
        return None
    lines = []
    for aid, ctx in hot:
        tag = "RETIRE" if ctx >= RETIRE else "warn"
        lines.append(f"  - {label(st, aid)}: {k(ctx)} [{tag}]")
    ctxmsg = (
        f"[subagent-context-guard] Fleet context sizes at/over the {k(WARN)} warn line "
        f"(soft retire limit {k(RETIRE)}):\n" + "\n".join(lines) +
        "\n  Agents marked RETIRE must not receive new work; " + HANDOVER +
        " Fresh agents start small — prefer a new lane over a bloated one."
    )
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": ctxmsg}}


def on_pre_send_message(inp):
    ti = inp.get("tool_input") or {}
    to = ti.get("to")
    message = ti.get("message") or ""
    st = load_state(inp)
    aid = resolve_agent(inp, st, to)
    if not aid:
        return None
    tp = transcript_for(inp, aid)
    ctx = measure_context(tp) if tp else None
    if ctx is None:
        return None
    rec = st.setdefault(aid, {})
    rec.update(ctx=ctx, updated=int(time.time()))
    lvl = level(ctx)
    m = OVERRIDE_RE.search(message)
    out = None
    if lvl == "RETIRE":
        if m:
            why = (m.group(1) or "").strip() or "(no reason given)"
            rec["overrides"] = rec.get("overrides", 0) + 1
            log(f"OVERRIDE {sid(inp)} {aid} ctx={ctx} n={rec['overrides']} desc={rec.get('description') or rec.get('agent_name') or ''!r} why={why!r}")
            out = {"systemMessage": f"subagent-context-guard: long-context override #{rec['overrides']} "
                                    f"for {label(st, aid)} at {k(ctx)}: {why}"}
        else:
            log(f"DENY {sid(inp)} {aid} ctx={ctx} desc={rec.get('description') or rec.get('agent_name') or ''!r}")
            reason = (
                f"[subagent-context-guard] Agent {label(st, aid)} is at {k(ctx)} context, over the "
                f"{k(RETIRE)} soft retirement limit. Every further turn re-reads all of that, and past "
                f"this size agents lose the goal and drift. {HANDOVER} "
                f"If this specific task genuinely needs the agent's accumulated context (e.g. it is the "
                f"handover request itself, or a one-line follow-up on work only it holds), resend with "
                f"`[long-context-ok: <reason>]` anywhere in the message."
            )
            out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                          "permissionDecision": "deny",
                                          "permissionDecisionReason": reason}}
    elif lvl == "WARN":
        log(f"WARN {sid(inp)} {aid} ctx={ctx}")
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext":
               f"[subagent-context-guard] Agent {label(st, aid)} is at {k(ctx)} context; it will hit the "
               f"{k(RETIRE)} retirement limit soon. Keep this message small and start preparing its "
               f"handover + successor."}}
    save_state(inp, st)
    return out


def on_post_agent(inp):
    ti = inp.get("tool_input") or {}
    tr = inp.get("tool_response")
    aid = None
    if isinstance(tr, dict):
        aid = tr.get("agentId") or tr.get("agent_id")
    if not aid:
        return None
    st = load_state(inp)
    rec = st.setdefault(aid, {})
    if ti.get("description"):
        rec["description"] = ti["description"]
    rec.setdefault("spawned", int(time.time()))
    save_state(inp, st)
    return None


def main_level(ctx):
    if ctx is None:
        return None
    if ctx >= MAIN_STRONG:
        return "STRONG"
    if ctx >= MAIN_WARN:
        return "WARN"
    return "ok"


def on_post_any(inp):
    """Top-level session context check. Runs after every tool call in the main
    session (not inside subagents), but only speaks on the first crossing of
    each threshold, so it is silent almost always."""
    if inp.get("agent_id"):
        return None
    tp = inp.get("transcript_path")
    if not tp or not Path(tp).is_file():
        return None
    ctx = measure_context(tp)
    if ctx is None:
        return None
    st = load_state(inp)
    rec = st.setdefault("__main__", {})
    rec.update(ctx=ctx, updated=int(time.time()))
    lvl = main_level(ctx)
    prev = rec.get("announced")
    out = None
    if lvl in ("WARN", "STRONG") and prev != lvl:
        rec["announced"] = lvl
        log(f"MAIN-{lvl} {sid(inp)} ctx={ctx}")
        if lvl == "STRONG":
            model = (f"[subagent-context-guard] THIS session's context is {k(ctx)} (strong line {k(MAIN_STRONG)}). "
                     f"Past this size the orchestrator itself drifts. Write the session handover now "
                     f"(progress_actual.md or the project's handover doc: done / left / paths / gotchas / "
                     f"verified facts), then tell the user this session should be replaced by a fresh one "
                     f"booted from that handover. Do not take on new large work here.")
            user = f"⛔ subagent-context-guard: this session is at {k(ctx)} context. Handover + fresh session recommended."
        else:
            model = (f"[subagent-context-guard] THIS session's context is {k(ctx)}, past the {k(MAIN_WARN)} warn line. "
                     f"Re-state the goal explicitly before each next step, keep new work in fresh subagents, "
                     f"and start keeping the session handover current so a fresh session can take over at a "
                     f"natural boundary (strong nudge at {k(MAIN_STRONG)}).")
            user = f"⚠ subagent-context-guard: this session is at {k(ctx)} context (warn line {k(MAIN_WARN)}, strong at {k(MAIN_STRONG)})."
        out = {"systemMessage": user,
               "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": model}}
    save_state(inp, st)
    return out


def main():
    if OFF_SWITCH.exists():
        return
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return
    ev = inp.get("hook_event_name")
    tool = inp.get("tool_name")
    out = None
    if ev == "SubagentStop":
        out = on_subagent_stop(inp)
    elif ev == "PreToolUse" and tool == "SendMessage":
        out = on_pre_send_message(inp)
    elif ev == "PreToolUse" and tool in ("Agent", "Task"):
        out = on_pre_agent(inp)
    elif ev == "PostToolUse":
        if tool in ("Agent", "Task"):
            on_post_agent(inp)
        out = on_post_any(inp)
    if out:
        print(json.dumps(out))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # fail-safe: never break the session
        log(f"ERROR {type(e).__name__}: {e}")
    sys.exit(0)
