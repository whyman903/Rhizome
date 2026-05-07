"""Unit tests for the watch engine."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import json

import pytest

from compile import watch as watch_module
from compile.config import load_config
from compile.workspace import init_workspace


def _make_workspace(tmp_path: Path) -> Path:
    init_workspace(tmp_path, "Watch Tests", "Smoke")
    return tmp_path


# ---- Frequency parsing ----------------------------------------------------------


@pytest.mark.parametrize("value,kind", [
    ("hourly", "hourly"),
    ("daily", "daily"),
    ("weekly", "weekly"),
    ("HOURLY", "hourly"),
])
def test_parse_frequency_simple(value: str, kind: str) -> None:
    freq = watch_module.parse_frequency(value)
    assert freq.kind == kind


def test_parse_frequency_cron_at_top_of_hour() -> None:
    freq = watch_module.parse_frequency("cron: 0 9 * * 1-5")
    assert freq.kind == "cron"
    assert freq.cron == "0 9 * * 1-5"


@pytest.mark.parametrize("value", [
    "cron: */15 * * * *",
    "cron: * * * * *",
    "cron: 0,30 * * * *",
    "cron: 5-10 * * * *",
])
def test_parse_frequency_rejects_sub_hour(value: str) -> None:
    with pytest.raises(ValueError, match="more than once per hour"):
        watch_module.parse_frequency(value)


def test_parse_frequency_rejects_garbage() -> None:
    with pytest.raises(ValueError):
        watch_module.parse_frequency("never")


def test_next_fire_time_hourly_advances_one_hour() -> None:
    base = datetime(2026, 1, 1, 12, 30, tzinfo=timezone.utc)
    nxt = watch_module.next_fire_time(watch_module.Frequency("hourly"), after=base)
    assert nxt > base
    assert (nxt - base).total_seconds() <= 3600


def test_next_fire_time_cron_picks_next_match() -> None:
    base = datetime(2026, 1, 1, 12, 30, tzinfo=timezone.utc)
    freq = watch_module.parse_frequency("cron: 0 14 * * *")
    nxt = watch_module.next_fire_time(freq, after=base)
    assert nxt.hour == 14
    assert nxt.minute == 0
    assert nxt.day == 1


# ---- add / list / pause / resume / remove ---------------------------------------


def test_add_creates_page_with_frontmatter(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config,
        url="https://example.com/feed",
        frequency="daily",
        intent="Pull the top 3 stories.",
    )
    assert record.watch_id
    assert record.url == "https://example.com/feed"
    assert record.frequency == "daily"
    assert record.next_run is not None
    page_path = tmp_path / record.relative_path
    assert page_path.exists()
    assert page_path.parent.name == "watches"
    text = page_path.read_text()
    assert "watch_id:" in text
    assert "watch_url: https://example.com/feed" in text
    assert "watch_status: active" in text


def test_list_returns_added_watch(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    watch_module.add_watch(
        config,
        url="https://example.com/a",
        frequency="weekly",
        intent="Anything new about X.",
        title="Alpha Watch",
    )
    records = watch_module.list_watches(config)
    assert len(records) == 1
    assert records[0].title == "Alpha Watch"
    state_file = tmp_path / ".compile" / "watches.json"
    assert state_file.exists()
    state_payload = json.loads(state_file.read_text())
    assert state_payload["watches"][0]["title"] == "Alpha Watch"


def test_pause_then_resume_flips_status_and_clears_failures(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily", intent="x", title="W",
    )
    paused = watch_module.pause_watch(config, record.title)
    assert paused.watch_status == "paused"
    assert paused.next_run is None

    resumed = watch_module.resume_watch(config, record.title)
    assert resumed.watch_status == "active"
    assert resumed.next_run is not None
    assert resumed.consecutive_failures == 0


def test_remove_default_deletes_page(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily", intent="x", title="W",
    )
    page_path = tmp_path / record.relative_path
    watch_module.remove_watch(config, record.title)
    assert not page_path.exists()


def test_remove_keep_page_leaves_file_in_place(tmp_path: Path) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily", intent="x", title="Keep",
    )
    page_path = tmp_path / record.relative_path
    watch_module.remove_watch(config, record.title, keep_page=True)
    # remove_watch with keep_page only rebuilds state — the page itself is still there.
    assert page_path.exists()


# ---- run_watch happy / unchanged / failure paths --------------------------------


def _stub_fetch(monkeypatch: pytest.MonkeyPatch, body: str = "<html>hi</html>") -> list[dict[str, Any]]:
    """Replace ``fetch_url`` with a stub that records calls and writes a fixed file."""
    calls: list[dict[str, Any]] = []

    def fake_fetch(url: str, raw_dir: Path, *, download_images: bool = False) -> tuple[Path, str]:
        raw_dir.mkdir(parents=True, exist_ok=True)
        dest = raw_dir / f"{len(calls):03d}.md"
        dest.write_text(body)
        calls.append({"url": url, "dest": str(dest)})
        return dest, "Stub"

    monkeypatch.setattr(watch_module, "fetch_url", fake_fetch)
    return calls


def _stub_claude_ok(monkeypatch: pytest.MonkeyPatch, answer: str) -> list[list[str]]:
    """Replace subprocess.run with a stub that returns a successful claude payload."""
    invocations: list[list[str]] = []

    class FakeCompleted:
        def __init__(self) -> None:
            self.returncode = 0
            self.stdout = json.dumps({"result": answer})
            self.stderr = ""

    def fake_run(args: list[str], **kwargs: Any) -> FakeCompleted:
        invocations.append(args)
        return FakeCompleted()

    monkeypatch.setattr(watch_module.subprocess, "run", fake_run)
    return invocations


def _stub_claude_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeCompleted:
        def __init__(self) -> None:
            self.returncode = 2
            self.stdout = ""
            self.stderr = "boom\n"

    monkeypatch.setattr(watch_module.subprocess, "run", lambda *a, **k: FakeCompleted())


def test_run_watch_happy_path_appends_digest(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config,
        url="https://example.com",
        frequency="daily",
        intent="Top 3 things.",
        title="HappyWatch",
    )
    _stub_fetch(monkeypatch, body="hello world")
    invocations = _stub_claude_ok(monkeypatch, "## Digest body\n\n- one\n- two")

    event = watch_module.run_watch(config, record.title)
    assert event["status"] == "ok"
    page_text = (tmp_path / record.relative_path).read_text()
    assert "## Digests" in page_text
    assert "- one" in page_text
    assert "synthesized" in page_text
    # Subsequent fields updated
    assert "watch_run_count: 1" in page_text
    assert "watch_last_status: ok" in page_text
    # claude was invoked with --add-dir pointing at the wiki dir
    assert any("--add-dir" in a for a in invocations[0])


def test_run_watch_skips_synthesis_when_content_unchanged(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily", intent="x", title="UnchangedWatch",
    )
    _stub_fetch(monkeypatch, body="static body")
    claude_calls = _stub_claude_ok(monkeypatch, "first run digest")

    first = watch_module.run_watch(config, record.title)
    assert first["status"] == "ok"
    assert len(claude_calls) == 1

    # Second run: same content → unchanged, no synthesis.
    second = watch_module.run_watch(config, record.title)
    assert second["status"] == "unchanged"
    assert len(claude_calls) == 1, "claude should not have been called a second time"

    page_text = (tmp_path / record.relative_path).read_text()
    assert "watch_last_status: unchanged" in page_text


def test_run_watch_force_synthesizes_unchanged_content(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily", intent="x", title="ForceWatch",
    )
    _stub_fetch(monkeypatch, body="static body")
    claude_calls = _stub_claude_ok(monkeypatch, "digest")

    watch_module.run_watch(config, record.title)
    forced = watch_module.run_watch(config, record.title, force=True)
    assert forced["status"] == "ok"
    assert len(claude_calls) == 2


def test_run_watch_failure_increments_and_auto_pauses(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily", intent="x", title="FailWatch",
    )
    _stub_fetch(monkeypatch)
    _stub_claude_fail(monkeypatch)

    for run_index in range(watch_module.AUTO_PAUSE_FAILURES):
        event = watch_module.run_watch(config, record.title)
        assert event["status"] == "failed"
        if run_index == watch_module.AUTO_PAUSE_FAILURES - 1:
            assert event.get("auto_paused") is True

    final = watch_module.get_watch(config, record.title)
    assert final.watch_status == "paused"
    assert final.consecutive_failures == watch_module.AUTO_PAUSE_FAILURES


def test_tick_only_runs_due_active_watches(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_workspace(tmp_path)
    config = load_config(tmp_path)
    due = watch_module.add_watch(
        config, url="https://a.com", frequency="daily", intent="x", title="Due",
    )
    not_due = watch_module.add_watch(
        config, url="https://b.com", frequency="daily", intent="x", title="NotDue",
    )
    paused = watch_module.add_watch(
        config, url="https://c.com", frequency="daily", intent="x", title="Paused",
    )
    watch_module.pause_watch(config, paused.title)

    import re

    def _override_next_run(page_relative: str, value: str) -> None:
        page_path = tmp_path / page_relative
        text = page_path.read_text()
        text = re.sub(
            r"^watch_next_run: .*$",
            f"watch_next_run: {value}",
            text,
            count=1,
            flags=re.MULTILINE,
        )
        page_path.write_text(text)

    _override_next_run(not_due.relative_path, "2099-01-01T00:00:00Z")
    _override_next_run(due.relative_path, "2000-01-01T00:00:00Z")

    _stub_fetch(monkeypatch, body="content")
    _stub_claude_ok(monkeypatch, "digest body")

    events = watch_module.tick(config)
    titles = [e.get("title") for e in events]
    assert titles == ["Due"]


# ---- digest body editing -------------------------------------------------------


def test_prepend_digest_section_keeps_newest_first() -> None:
    body = (
        "> [!note] Automated watch\n> info\n\n"
        "## Intent\n\nfoo\n\n"
        "## Digests\n\n_No runs yet._\n"
    )
    once = watch_module._prepend_digest_section(
        body,
        heading="## 2026-05-06 — W",
        digest="first digest",
        raw_relative="raw/watches/w/01.md",
        timestamp="2026-05-06T09:00:00Z",
    )
    assert "_No runs yet._" not in once
    assert "first digest" in once

    twice = watch_module._prepend_digest_section(
        once,
        heading="## 2026-05-07 — W",
        digest="second digest",
        raw_relative="raw/watches/w/02.md",
        timestamp="2026-05-07T09:00:00Z",
    )
    first_idx = twice.index("first digest")
    second_idx = twice.index("second digest")
    assert second_idx < first_idx, "newest digest should come first"
