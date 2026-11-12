#!/usr/bin/env python3
"""agent-context-bar: Claude Code status line (the bar under the input box).

Line 1: conversation id · model · main context bar  used/window  pct · tool call failures F/N (P%)
Only while a subagent runs, indented lines follow:
    agents: N running, M done
    ● one row per running subagent (and ones finished < 2 min ago, marked ✓), each with
      its own context bar and tool call failures
        ● sub-subagents sit under their parent (meta.json parentAgentId), one indent deeper

Bar length follows the terminal width: the bar takes the columns left over after the
text on its line (5 to 50 cells; 10 when the width cannot be found). The width comes
from the pty of the nearest ancestor process that has one (the claude process), since
this script itself runs on pipes.

Tool counts: every tool call in the transcript, and the ones whose result came back
flagged is_error (non-zero exit, edit that did not match, hook block, ...). Calls he
declined or interrupted are NOT counted as failed. Counted incrementally: a small cache
per transcript (~/.cache/agent-context-bar/stats/) remembers the byte offset, so each
run parses only the new lines.

After /compact the last assistant turn in the transcript is still the pre-compaction
one, so the compact_boundary line wins: the bar shows its postTokens with a "~" until
the next reply brings a real figure.

Claude Code pipes a JSON blob on stdin (session_id, transcript_path, model, ...)
and shows whatever this prints. Context = the last assistant turn's
input + cache_read + cache_creation + output tokens, read from the tail of the
transcript: the same number the token-usage skill and seedeep report.

Subagent transcripts live next to the main one:
  <project>/<session_id>/subagents/agent-<id>.jsonl  (+ agent-<id>.meta.json,
  which carries description, agentType, model and "finished": true when done).

Wired in ~/.claude/settings.json:
  "statusLine": {"type": "command", "command": "python3 ~/.claude/statusline/agent-context-bar.py"}

Debug: the last stdin blob is saved to ~/.cache/agent-context-bar/last-input.json.
Test without Claude Code:
  echo '{"session_id":"<uuid>"}' | python3 agent-context-bar.py
"""
import fcntl
import glob
import json
import os
import re
import struct
import sys
import termios
import time
from pathlib import Path

HOME = Path.home()
TAIL_CHUNK = 64 * 1024
TAIL_MAX = 2 * 1024 * 1024
RECENT_DONE_S = 120        # keep a finished subagent on screen this long, with ✓
STALE_S = 30 * 60          # an unfinished subagent silent this long is not shown
MAX_ROWS = 6               # subagent rows before "+N more"
CELLS = 10                 # bar cells when the terminal width is unknown
MIN_CELLS, MAX_CELLS = 5, 50
RIGHT_MARGIN = 4           # columns kept free at the right edge
TAB = "    "               # one indent level (spaces: a real tab has no fixed width here)
SLOT = "\0"                # where the bar goes in a line, filled by fit()

DIM, RESET = "\033[2m", "\033[0m"
GREEN, YELLOW, RED, CYAN = "\033[32m", "\033[33m", "\033[31m", "\033[36m"


def k(n):
    if n is None:
        return "?"
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M".replace(".0M", "M")
    return f"{n/1000:.0f}k" if n >= 1000 else str(n)


def term_cols():
    """Terminal width from the nearest ancestor that holds a pty, or None."""
    try:
        pid = os.getppid()
        for _ in range(8):
            if pid <= 1:
                break
            for fd in (0, 1, 2):
                try:
                    t = os.readlink(f"/proc/{pid}/fd/{fd}")
                    if not t.startswith("/dev/pts/"):
                        continue
                    f = os.open(t, os.O_RDONLY | os.O_NOCTTY)
                    try:
                        _, cols = struct.unpack("hhhh", fcntl.ioctl(f, termios.TIOCGWINSZ, b"\0" * 8))[:2]
                    finally:
                        os.close(f)
                    if cols > 0:
                        return cols
                except OSError:
                    continue
            with open(f"/proc/{pid}/stat") as fh:
                pid = int(fh.read().rsplit(")", 1)[1].split()[1])
    except Exception:
        pass
    return None


ANSI = re.compile(r"\033\[[0-9;]*m")


def fit(line, used, window, cols):
    """Put the bar into the SLOT of line, as long as the terminal width allows."""
    cells = CELLS
    if cols:
        text = len(ANSI.sub("", line)) - 1
        cells = max(MIN_CELLS, min(MAX_CELLS, cols - RIGHT_MARGIN - text))
    return line.replace(SLOT, bar(used, window, cells)[0])


def bar(used, window, CELLS=CELLS):
    if not used or not window:
        return DIM + "▱" * CELLS + RESET, "?"
    frac = min(used / window, 1.0)
    full = round(frac * CELLS)
    if used > 0 and full == 0:
        full = 1
    colour = GREEN if frac < 0.5 else YELLOW if frac < 0.8 else RED
    return colour + "▰" * full + DIM + "▱" * (CELLS - full) + RESET, f"{frac*100:.0f}%"


NOT_A_FAILURE = ("The user doesn't want to proceed", "[Tool call interrupted",
                 "[Request interrupted", "The user doesn't want to take this action")


def tool_stats(path):
    """(tool calls, failed tool calls) for a transcript, parsing only bytes not seen before."""
    st = {"offset": 0, "tools": 0, "failed": 0}
    cf = None
    try:
        size = os.path.getsize(path)
        d = HOME / ".cache/agent-context-bar/stats"
        d.mkdir(parents=True, exist_ok=True)
        cf = d / (Path(path).parent.name[-12:] + "_" + Path(path).stem + ".json")
        try:
            old = json.loads(cf.read_text())
            if old.get("offset", 0) <= size:
                st = old
        except Exception:
            pass
        if size > st["offset"]:
            with open(path, "rb") as f:
                f.seek(st["offset"])
                data = f.read()
            end = data.rfind(b"\n") + 1      # only complete lines
            for line in data[:end].split(b"\n"):
                if b'"tool_use"' not in line and b'"tool_result"' not in line:
                    continue
                try:
                    content = (json.loads(line).get("message") or {}).get("content")
                except Exception:
                    continue
                if not isinstance(content, list):
                    continue
                for blk in content:
                    if not isinstance(blk, dict):
                        continue
                    if blk.get("type") == "tool_use":
                        st["tools"] += 1
                    elif blk.get("type") == "tool_result" and blk.get("is_error"):
                        c = blk.get("content")
                        text = c if isinstance(c, str) else json.dumps(c)
                        if not text.lstrip().startswith(NOT_A_FAILURE):
                            st["failed"] += 1
            st["offset"] += end
            tmp = cf.with_suffix(".tmp%d" % os.getpid())
            tmp.write_text(json.dumps(st))
            os.replace(tmp, cf)
    except Exception:
        pass
    return st["tools"], st["failed"]


def tools_txt(tools, failed):
    if not tools:
        return ""
    r = failed / tools
    colour = RED if r >= 0.2 else YELLOW if r >= 0.1 else ""
    return f" · tool call failures {colour}{failed}/{tools} ({r * 100:.0f}%){RESET}"


def last_usage(path):
    """(context tokens, model id, approx) from the last assistant turn with usage.

    approx is True when a /compact happened after that turn: the figure is then the
    compaction's own postTokens (messages only), until the next reply."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            buf, pos, scanned = b"", size, 0
            while pos > 0 and scanned < TAIL_MAX:
                step = min(TAIL_CHUNK, pos)
                pos -= step
                f.seek(pos)
                buf = f.read(step) + buf
                scanned += step
                lines = buf.split(b"\n")
                for line in reversed(lines[0 if pos == 0 else 1:]):
                    if b'"compact_boundary"' in line and b'"postTokens"' in line:
                        try:
                            d = json.loads(line)
                            if d.get("subtype") == "compact_boundary":
                                post = (d.get("compactMetadata") or {}).get("postTokens")
                                if post:
                                    return int(post), None, True
                        except Exception:
                            pass
                    if b'"usage"' not in line or b'"assistant"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get("type") != "assistant":
                        continue
                    m = d.get("message") or {}
                    u = m.get("usage") or {}
                    ctx = sum(int(u.get(x) or 0) for x in (
                        "input_tokens", "cache_read_input_tokens",
                        "cache_creation_input_tokens", "output_tokens"))
                    if ctx:
                        return ctx, m.get("model"), False
                buf = lines[0] if pos > 0 else b""
    except Exception:
        pass
    return None, None, False


def window_for(model, main_window):
    m = (model or "").lower()
    if "haiku" in m:
        return 200_000
    if "[1m]" in m:
        return 1_000_000
    return main_window


def short_model(model):
    m = (model or "").lower()
    for name in ("fable", "opus", "sonnet", "haiku"):
        if name in m:
            return name
    return m.replace("claude-", "")[:10] or "?"


def main():
    raw = sys.stdin.read()
    try:
        inp = json.loads(raw) if raw.strip() else {}
    except Exception:
        inp = {}
    try:
        cache = HOME / ".cache/agent-context-bar"
        cache.mkdir(parents=True, exist_ok=True)
        (cache / "last-input.json").write_text(raw)
    except Exception:
        pass

    sid = inp.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID") or "?"
    tp = inp.get("transcript_path")
    if not tp or not os.path.isfile(tp):
        hits = glob.glob(str(HOME / ".claude/projects" / "*" / f"{sid}.jsonl"))
        tp = hits[0] if hits else None

    model = inp.get("model") or {}
    model_name = model.get("display_name") or model.get("id") or "?"
    cw = inp.get("context_window") or {}
    main_window = cw.get("context_window_size") or (
        1_000_000 if "[1m]" in str(model.get("id", "")) else 200_000)

    main_ctx, approx = None, False
    if tp:
        main_ctx, _, approx = last_usage(tp)
    if main_ctx is None and cw.get("used_percentage") is not None:
        main_ctx = int(cw["used_percentage"] / 100 * main_window)
    cols = term_cols()
    _, pct = bar(main_ctx, main_window)
    out = [f"{CYAN}{sid}{RESET} · {model_name} · {SLOT} {'~' if approx else ''}{k(main_ctx)}/{k(main_window)} {pct}"
           + (f" {DIM}compacted{RESET}" if approx else "")]
    if tp:
        out[0] += tools_txt(*tool_stats(tp))

    # subagents: a tree (sub-subagents sit under their parent, one indent deeper),
    # printed on their own lines and only while at least one is running
    agents, done_total = {}, 0
    if tp:
        sub_dir = Path(tp).with_suffix("") / "subagents"
        now = time.time()
        for jl in sub_dir.glob("agent-*.jsonl") if sub_dir.is_dir() else []:
            try:
                mtime = jl.stat().st_mtime
            except OSError:
                continue
            meta = {}
            try:
                meta = json.loads(jl.with_name(jl.stem + ".meta.json").read_text())
            except Exception:
                pass
            finished = bool(meta.get("finished"))
            done_total += finished
            agents[jl.stem[len("agent-"):]] = {
                "jl": jl, "mtime": mtime, "meta": meta, "finished": finished,
                "parent": meta.get("parentAgentId"), "kids": [],
                "running": not finished and now - mtime <= STALE_S,
                "show": (now - mtime <= RECENT_DONE_S) if finished else (now - mtime <= STALE_S),
            }

    running = sum(a["running"] for a in agents.values())
    if running:
        roots = []
        for aid, a in agents.items():
            par = agents.get(a["parent"])
            (par["kids"] if par else roots).append(a)
            p, seen = par, set()
            while a["show"] and p and id(p) not in seen:   # keep the chain above a shown agent
                seen.add(id(p))
                p["show"] = True
                p = agents.get(p["parent"])
        order = lambda a: (not a["running"], -a["mtime"])  # running first, newest first
        rows = []

        def walk(nodes, depth):
            for a in sorted(nodes, key=order):
                if a["show"]:
                    rows.append((a, depth))
                    walk(a["kids"], depth + 1)
        walk(roots, 1)

        out.append(f"{TAB}agents: {running} running, {done_total} done")
        for a, depth in rows[:MAX_ROWS]:
            meta = a["meta"]
            ctx, mid, _ = last_usage(a["jl"])
            win = window_for(mid or meta.get("model"), main_window)
            _, pct = bar(ctx, win)
            mark = f"{GREEN}✓{RESET}" if a["finished"] else f"{YELLOW}●{RESET}" if a["running"] else f"{DIM}○{RESET}"
            kind = meta.get("agentType") or "agent"
            desc = (meta.get("description") or "")[:40]
            line = (f"{TAB * depth}{mark} {kind}·{short_model(mid or meta.get('model'))} "
                    f"{DIM}{desc}{RESET} {SLOT} {k(ctx)}/{k(win)} {pct}{tools_txt(*tool_stats(a['jl']))}")
            out.append(fit(line, ctx, win, cols))
        if len(rows) > MAX_ROWS:
            out.append(f"{TAB}{DIM}+{len(rows) - MAX_ROWS} more{RESET}")

    out[0] = fit(out[0], main_ctx, main_window, cols)
    print("\n".join(out))


if __name__ == "__main__":
    main()
