"""CLI integration tests for the `compile watch` command group."""

from __future__ import annotations

from pathlib import Path
from typing import Any
import json

import pytest
from click.testing import CliRunner

from compile import watch as watch_module
from compile.cli import main
from compile.workspace import init_workspace


def _make_workspace(tmp_path: Path) -> Path:
    init_workspace(tmp_path, "Watch CLI", "Smoke")
    return tmp_path


def _add_runner(tmp_path: Path, *, title: str = "AlphaWatch") -> dict[str, Any]:
    runner = CliRunner()
    result = runner.invoke(
        main,
        [
            "watch",
            "add",
            "https://example.com/feed",
            "--frequency", "daily",
            "--intent", "Top stories",
            "--title", title,
            "--path", str(tmp_path),
            "--json-output",
        ],
    )
    assert result.exit_code == 0, result.output
    return json.loads(result.output.strip())


def test_watch_add_emits_stable_json_envelope(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    payload = _add_runner(tmp_path)
    assert payload["ok"] is True
    record = payload["watch"]
    for key in (
        "watch_id", "title", "relative_path", "url", "frequency", "intent",
        "watch_status", "last_status", "last_run", "next_run", "run_count",
        "consecutive_failures", "last_error",
    ):
        assert key in record
    assert record["watch_status"] == "active"
    assert record["url"] == "https://example.com/feed"


def test_watch_list_returns_array(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    _add_runner(tmp_path, title="One")
    _add_runner(tmp_path, title="Two")

    runner = CliRunner()
    result = runner.invoke(main, ["watch", "list", "--path", str(tmp_path), "--json-output"])
    assert result.exit_code == 0
    payload = json.loads(result.output.strip())
    titles = sorted(w["title"] for w in payload["watches"])
    assert titles == ["One", "Two"]


def test_watch_pause_resume_remove_via_cli(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    _add_runner(tmp_path, title="Cycler")

    runner = CliRunner()
    pause = runner.invoke(
        main, ["watch", "pause", "Cycler", "--path", str(tmp_path), "--json-output"],
    )
    assert pause.exit_code == 0
    assert json.loads(pause.output.strip())["watch"]["watch_status"] == "paused"

    resume = runner.invoke(
        main, ["watch", "resume", "Cycler", "--path", str(tmp_path), "--json-output"],
    )
    assert resume.exit_code == 0
    assert json.loads(resume.output.strip())["watch"]["watch_status"] == "active"

    remove = runner.invoke(
        main, ["watch", "remove", "Cycler", "--path", str(tmp_path), "--json-output"],
    )
    assert remove.exit_code == 0
    payload = json.loads(remove.output.strip())
    assert payload["ok"] is True
    assert "watches/Cycler.md" in payload["removed"]


def test_watch_tick_emits_one_event_per_due_watch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_workspace(tmp_path)
    add_one = _add_runner(tmp_path, title="DueOne")
    _add_runner(tmp_path, title="DueTwo")

    # Force both watches' next_run into the past via direct frontmatter edit.
    import re
    for w in (tmp_path / "wiki" / "watches").glob("*.md"):
        text = w.read_text()
        text = re.sub(
            r"^watch_next_run: .*$",
            "watch_next_run: 2000-01-01T00:00:00Z",
            text, count=1, flags=re.MULTILINE,
        )
        w.write_text(text)

    # Stub the network and claude.
    def fake_fetch(url: str, raw_dir: Path, *, download_images: bool = False) -> tuple[Path, str]:
        raw_dir.mkdir(parents=True, exist_ok=True)
        dest = raw_dir / "x.md"
        dest.write_text(f"body for {url}")
        return dest, "x"

    class FakeCompleted:
        returncode = 0
        stdout = json.dumps({"result": "digest body"})
        stderr = ""

    monkeypatch.setattr(watch_module, "fetch_url", fake_fetch)
    monkeypatch.setattr(watch_module.subprocess, "run", lambda *a, **k: FakeCompleted())

    runner = CliRunner()
    result = runner.invoke(
        main,
        ["watch", "tick", "--path", str(tmp_path), "--json-stream"],
    )
    assert result.exit_code == 0, result.output
    events = [json.loads(line)["event"] for line in result.output.strip().splitlines() if line.strip()]
    assert len(events) == 2
    assert all(e["status"] == "ok" for e in events)


def test_watch_add_rejects_sub_hour_cron(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    runner = CliRunner()
    result = runner.invoke(
        main,
        [
            "watch", "add", "https://x.com",
            "--frequency", "cron: */15 * * * *",
            "--intent", "x",
            "--path", str(tmp_path),
            "--json-output",
        ],
    )
    assert result.exit_code == 1
    assert "more than once per hour" in result.output
