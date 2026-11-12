"""claude-tokens-export on a tiny synthetic ~/.claude/projects tree.

Run: uv run --no-project --with pytest pytest -q tests/claude-tokens-export
"""
import importlib.machinery
import importlib.util
import json
import pathlib
import subprocess
from datetime import datetime, timedelta, timezone

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "dotfiles" / "local-bin" / "claude-tokens-export"


def load(tmp_path, monkeypatch, device="desktop"):
    monkeypatch.setenv("CLAUDE_TOKENS_PROJECTS", str(tmp_path / "projects"))
    monkeypatch.setenv("CLAUDE_TOKENS_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("CLAUDE_TOKENS_DEVICE", device)
    loader = importlib.machinery.SourceFileLoader("cte", str(SCRIPT))
    spec = importlib.util.spec_from_loader("cte", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    monkeypatch.setattr(mod.socket, "gethostname", lambda: "testhost")
    return mod


def row(mid, rid, sid, i=1, o=10, cr=100, cc=1000, model="claude-opus-5-5", ts=None, typ="assistant"):
    ts = ts or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return json.dumps({"type": typ, "sessionId": sid, "requestId": rid, "timestamp": ts,
                       "message": {"id": mid, "model": model, "usage": {
                           "input_tokens": i, "output_tokens": o,
                           "cache_read_input_tokens": cr, "cache_creation_input_tokens": cc}}}) + "\n"


def today(tmp_path):
    doc = json.loads((tmp_path / "state" / "testhost.json").read_text())
    return doc, doc["days"][-1]


def test_dedupe_subagents_models_window(tmp_path, monkeypatch):
    mod = load(tmp_path, monkeypatch)
    p = tmp_path / "projects" / "-proj"
    (p / "s1" / "subagents").mkdir(parents=True)
    old = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat().replace("+00:00", "Z")
    (p / "s1.jsonl").write_text(
        row("m1", "r1", "s1")                       # counted
        + row("m1", "r1", "s1")                     # same response rewritten: deduped
        + row("m1", "r1", "s1", o=12)               # streamed rewrite with more output: max wins
        + row("m2", "r2", "s1", model="claude-fable-5-1")
        + row("m3", "r3", "s1", ts=old)             # outside the 30-day window
        + json.dumps({"type": "user", "sessionId": "s1", "message": {"content": "hi"}}) + "\n"
        + row("m9", "r9", "s1", 0, 0, 0, 0))        # zero usage ignored
    (p / "s1" / "subagents" / "agent-a.jsonl").write_text(row("m4", "r4", "s1", model="claude-sonnet-5-5"))
    (p / "s2.jsonl").write_text(row("m5", "r5", "s2") + '{"type":"assistant","partial')  # partial last line
    assert mod.main(["--no-push"]) == 0
    doc, t = today(tmp_path)
    assert doc["host"] == "testhost" and doc["device"] == "desktop" and len(doc["days"]) == 30
    one = 1 + 10 + 100 + 1000
    assert t["total"] == 4 * one + 2              # m1 (output 12), m2, m4, m5
    assert t["output"] == 12 + 10 * 3
    assert t["input"] == 4 and t["cache_read"] == 400 and t["cache_creation"] == 4000
    assert t["sessions"] == 2
    assert t["models"]["claude-opus-5-5"]["total"] == 2 * one + 2
    assert t["models"]["claude-fable-5-1"]["total"] == one
    assert t["models"]["claude-sonnet-5-5"]["total"] == one


def test_incremental_append_and_rewrite(tmp_path, monkeypatch):
    mod = load(tmp_path, monkeypatch)
    p = tmp_path / "projects" / "-proj"
    p.mkdir(parents=True)
    f = p / "s.jsonl"
    f.write_text(row("m1", "r1", "s"))
    mod.main(["--no-push"])
    one = today(tmp_path)[1]["total"]
    with open(f, "a") as fh:                       # appended: only new bytes are read
        fh.write(row("m1", "r1", "s") + row("m2", "r2", "s"))
    mod.main(["--no-push"])
    assert today(tmp_path)[1]["total"] == 2 * one
    f.write_text(row("m1", "r1", "s"))             # file replaced/shrunk: re-read from 0, no double count
    mod.main(["--no-push"])
    assert today(tmp_path)[1]["total"] == 2 * one  # m2 stays known (max-merged cache)
    mod.main(["--no-push", "--rebuild"])
    assert today(tmp_path)[1]["total"] == one


def test_laptop_push_offline_is_exit_0(tmp_path, monkeypatch, capsys):
    mod = load(tmp_path, monkeypatch, device="laptop")
    (tmp_path / "projects" / "-p").mkdir(parents=True)
    (tmp_path / "projects" / "-p" / "s.jsonl").write_text(row("m1", "r1", "s"))
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 255, b"", b"ssh: connect to host desktop: No route to host")
    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    assert mod.main([]) == 0
    assert calls and calls[0][0] == "ssh" and "desktop" in calls[0]
    assert "push to desktop skipped" in capsys.readouterr().err


def test_desktop_never_pushes(tmp_path, monkeypatch):
    mod = load(tmp_path, monkeypatch, device="desktop")
    (tmp_path / "projects").mkdir()
    monkeypatch.setattr(mod.subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(AssertionError("pushed")))
    assert mod.main([]) == 0
