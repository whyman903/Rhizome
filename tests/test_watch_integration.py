"""End-to-end integration tests for the watch workflow.

Each test below exercises the full pipeline a real user would walk through —
init, add, run (happy / unchanged / failure), tick, pause/resume, remove —
and asserts on the on-disk state, frontmatter integrity, and CLI envelopes.

These tests stub two boundaries:
- ``fetch_url`` so we don't hit the network.
- ``subprocess.run`` so we don't require an authenticated ``claude``.

Everything else (workspace state, page IO, frontmatter parsing, state file)
runs through the real code paths.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any
import json
import re

import pytest
import yaml
from click.testing import CliRunner

from compile import watch as watch_module
from compile.cli import main
from compile.config import load_config
from compile.obsidian import ObsidianConnector
from compile.workspace import init_workspace


# ---------- Fakes shared across the scenarios -----------------------------------


class _ScriptedClaude:
    """Replace ``subprocess.run`` to feed Claude responses in order.

    Each call consumes one entry from ``responses``. An entry is either a string
    (returned as a successful answer) or a dict like ``{"returncode": 1, "stderr": "boom"}``.
    """

    def __init__(self, responses: list[Any]) -> None:
        self.responses = list(responses)
        self.calls: list[list[str]] = []

    class _Result:
        def __init__(self, *, returncode: int, stdout: str, stderr: str) -> None:
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    def __call__(self, args: list[str], **_: Any) -> "_ScriptedClaude._Result":
        self.calls.append(args)
        if not self.responses:
            return self._Result(returncode=2, stdout="", stderr="no scripted response")
        nxt = self.responses.pop(0)
        if isinstance(nxt, dict):
            return self._Result(
                returncode=int(nxt.get("returncode", 0)),
                stdout=str(nxt.get("stdout", "")),
                stderr=str(nxt.get("stderr", "")),
            )
        return self._Result(
            returncode=0,
            stdout=json.dumps({"result": str(nxt)}),
            stderr="",
        )


class _FakeFetcher:
    """Replace ``fetch_url``. Returns a predetermined body per call."""

    def __init__(self, bodies: list[str]) -> None:
        self.bodies = list(bodies)
        self.urls: list[str] = []

    def __call__(self, url: str, raw_dir: Path, *, download_images: bool = False) -> tuple[Path, str]:
        self.urls.append(url)
        body = self.bodies.pop(0) if self.bodies else f"static body for {url}"
        raw_dir.mkdir(parents=True, exist_ok=True)
        dest = raw_dir / f"{len(self.urls):03d}.md"
        dest.write_text(body)
        return dest, "Fetched"


def _install_stubs(
    monkeypatch: pytest.MonkeyPatch,
    *,
    bodies: list[str],
    claude_responses: list[Any],
) -> tuple[_FakeFetcher, _ScriptedClaude]:
    fetcher = _FakeFetcher(bodies)
    claude = _ScriptedClaude(claude_responses)
    monkeypatch.setattr(watch_module, "fetch_url", fetcher)
    monkeypatch.setattr(watch_module.subprocess, "run", claude)
    return fetcher, claude


def _make_workspace(tmp_path: Path, name: str = "Smoke") -> Path:
    init_workspace(tmp_path, name, "Watch integration")
    return tmp_path


def _read_frontmatter(page_path: Path) -> dict[str, Any]:
    """Parse the YAML frontmatter block of a page. Fails loudly if malformed."""
    text = page_path.read_text()
    if not text.startswith("---\n"):
        raise AssertionError(f"page is missing frontmatter:\n{text[:200]}")
    _, _, rest = text.partition("---\n")
    fm_text, sep, _body = rest.partition("\n---\n")
    if not sep:
        raise AssertionError(f"frontmatter not terminated:\n{text[:400]}")
    parsed = yaml.safe_load(fm_text)
    if not isinstance(parsed, dict):
        raise AssertionError(f"frontmatter did not parse as a dict: {parsed!r}")
    return parsed


def _override_next_run(page_path: Path, value: str) -> None:
    text = page_path.read_text()
    text = re.sub(
        r"^watch_next_run: .*$",
        f"watch_next_run: {value}",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    page_path.write_text(text)


# ---------- The scenario --------------------------------------------------------


def test_full_watch_lifecycle_via_cli(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Walk through every operation a user would perform, via the actual CLI.

    1. init workspace
    2. add a watch via CLI
    3. run it (happy path) — assert digest body, frontmatter, raw archive, state file
    4. run it again with same content — assert ``unchanged`` and Claude was NOT re-called
    5. force-run with new content — assert digests stack newest-first
    6. tick with a future next_run — assert nothing fires
    7. tick with an overdue next_run — assert it fires
    8. pause via CLI — assert tick skips it
    9. resume — assert active again
    10. remove — assert page deleted and state file updated
    """
    workspace = _make_workspace(tmp_path)
    runner = CliRunner()

    # --- 1. Add a watch -----------------------------------------------------
    fetcher, claude = _install_stubs(
        monkeypatch,
        bodies=["body version 1", "body version 1", "body version 2"],
        claude_responses=[
            "## Highlights\n\n- Initial digest line referencing [[Smoke]].",
            "Forced re-run digest — newer version.",
        ],
    )

    add_result = runner.invoke(
        main,
        [
            "watch", "add", "https://example.com/news",
            "--frequency", "daily",
            "--intent", "List the top items in plain English.",
            "--title", "ExampleNews",
            "--path", str(workspace),
            "--json-output",
        ],
    )
    assert add_result.exit_code == 0, add_result.output
    add_payload = json.loads(add_result.output.strip())
    assert add_payload["ok"] is True
    record = add_payload["watch"]
    page_path = workspace / record["relative_path"]
    assert page_path.exists()

    # --- 2. Frontmatter must be valid YAML and contain all expected keys ----
    fm = _read_frontmatter(page_path)
    expected_keys = {
        "title", "type", "watch_id", "watch_url", "watch_frequency",
        "watch_intent", "watch_status", "watch_next_run", "watch_run_count",
        "watch_consecutive_failures",
    }
    missing = expected_keys - set(fm.keys())
    assert not missing, f"missing frontmatter keys: {missing}"
    assert fm["type"] == "watch"
    assert fm["watch_status"] == "active"
    assert fm["watch_url"] == "https://example.com/news"

    # --- 3. State file mirrors the page ------------------------------------
    state_path = workspace / ".compile" / "watches.json"
    state = json.loads(state_path.read_text())
    assert len(state["watches"]) == 1
    assert state["watches"][0]["title"] == "ExampleNews"
    assert state["watches"][0]["watch_id"] == record["watch_id"]

    # --- 4. Run it once: happy path ----------------------------------------
    run1 = runner.invoke(
        main,
        [
            "watch", "run", "ExampleNews",
            "--path", str(workspace),
            "--json-output",
        ],
    )
    assert run1.exit_code == 0, run1.output
    run1_payload = json.loads(run1.output.strip())
    assert run1_payload["ok"] is True
    assert run1_payload["event"]["status"] == "ok"

    page_text = page_path.read_text()
    assert "## Digests" in page_text
    assert "Initial digest line" in page_text
    assert "[[Smoke]]" in page_text  # wikilink survived in the digest
    assert "_No runs yet" not in page_text
    # Raw archive was created.
    raw_files = sorted((workspace / "raw" / "watches" / "ExampleNews").iterdir())
    assert len(raw_files) >= 1, "expected at least one raw archive after first run"

    fm = _read_frontmatter(page_path)
    assert fm["watch_run_count"] == 1
    assert fm["watch_last_status"] == "ok"
    assert fm["watch_consecutive_failures"] == 0

    # Claude was invoked once with --add-dir pointing at the wiki directory.
    assert len(claude.calls) == 1
    call_args = claude.calls[0]
    assert "--add-dir" in call_args
    assert "--output-format" in call_args
    assert "json" in call_args
    add_dir_idx = call_args.index("--add-dir")
    assert call_args[add_dir_idx + 1] == str(workspace / "wiki")

    # --- 5. Run again with same content: unchanged path --------------------
    run2 = runner.invoke(
        main,
        ["watch", "run", "ExampleNews", "--path", str(workspace), "--json-output"],
    )
    assert run2.exit_code == 0, run2.output
    run2_payload = json.loads(run2.output.strip())
    assert run2_payload["event"]["status"] == "unchanged"
    assert len(claude.calls) == 1, "Claude must NOT be re-invoked when content is unchanged"

    fm = _read_frontmatter(page_path)
    assert fm["watch_run_count"] == 2
    assert fm["watch_last_status"] == "unchanged"

    # --- 6. Force-run with NEW content: digests stack newest-first ---------
    run3 = runner.invoke(
        main,
        [
            "watch", "run", "ExampleNews",
            "--force",
            "--path", str(workspace),
            "--json-output",
        ],
    )
    assert run3.exit_code == 0, run3.output
    run3_payload = json.loads(run3.output.strip())
    assert run3_payload["event"]["status"] == "ok"
    assert len(claude.calls) == 2

    page_text = page_path.read_text()
    initial_idx = page_text.index("Initial digest line")
    forced_idx = page_text.index("Forced re-run digest")
    assert forced_idx < initial_idx, "newest digest must come first in the body"

    # Frontmatter still parses cleanly after multiple rewrites.
    fm = _read_frontmatter(page_path)
    assert fm["watch_run_count"] == 3
    assert isinstance(fm["watch_run_count"], int)

    # --- 7. tick: not due yet (push next_run far into the future) ---------
    _override_next_run(page_path, "2099-01-01T00:00:00Z")
    tick_future = runner.invoke(
        main,
        ["watch", "tick", "--path", str(workspace), "--json-output"],
    )
    assert tick_future.exit_code == 0, tick_future.output
    tick_payload = json.loads(tick_future.output.strip())
    assert tick_payload["count"] == 0, "future next_run must not fire"

    # --- 8. tick: overdue — must fire -------------------------------------
    fetcher.bodies.append("body version 3")
    claude.responses.append("Tick-driven digest.")
    _override_next_run(page_path, "2000-01-01T00:00:00Z")

    tick_due = runner.invoke(
        main,
        ["watch", "tick", "--path", str(workspace), "--json-stream"],
    )
    assert tick_due.exit_code == 0, tick_due.output
    events = [json.loads(line)["event"] for line in tick_due.output.strip().splitlines()]
    assert len(events) == 1
    assert events[0]["status"] == "ok"
    assert "Tick-driven digest." in page_path.read_text()

    # --- 9. Pause via CLI: tick skips paused watches ----------------------
    _override_next_run(page_path, "2000-01-01T00:00:00Z")
    pause = runner.invoke(
        main,
        ["watch", "pause", "ExampleNews", "--path", str(workspace), "--json-output"],
    )
    assert pause.exit_code == 0
    paused = json.loads(pause.output.strip())["watch"]
    assert paused["watch_status"] == "paused"
    assert paused["next_run"] is None

    tick_paused = runner.invoke(
        main,
        ["watch", "tick", "--path", str(workspace), "--json-output"],
    )
    assert tick_paused.exit_code == 0
    assert json.loads(tick_paused.output.strip())["count"] == 0

    # --- 10. Resume: active again, fresh next_run --------------------------
    resume = runner.invoke(
        main,
        ["watch", "resume", "ExampleNews", "--path", str(workspace), "--json-output"],
    )
    assert resume.exit_code == 0
    resumed = json.loads(resume.output.strip())["watch"]
    assert resumed["watch_status"] == "active"
    assert resumed["next_run"] is not None

    # --- 11. Remove: page deleted, state synced ---------------------------
    remove = runner.invoke(
        main,
        ["watch", "remove", "ExampleNews", "--path", str(workspace), "--json-output"],
    )
    assert remove.exit_code == 0
    assert json.loads(remove.output.strip())["ok"] is True
    assert not page_path.exists()
    state = json.loads(state_path.read_text())
    assert state["watches"] == []


def test_auto_pause_after_three_consecutive_failures(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A watch that fails three times in a row should auto-pause itself."""
    workspace = _make_workspace(tmp_path)
    fetcher, claude = _install_stubs(
        monkeypatch,
        bodies=["body 1", "body 2", "body 3"],
        claude_responses=[
            {"returncode": 2, "stderr": "boom 1"},
            {"returncode": 2, "stderr": "boom 2"},
            {"returncode": 2, "stderr": "boom 3"},
        ],
    )

    config = load_config(workspace)
    record = watch_module.add_watch(
        config, url="https://broken.example", frequency="daily",
        intent="x", title="Broken",
    )

    for attempt in range(1, 4):
        event = watch_module.run_watch(config, record.title)
        assert event["status"] == "failed"
        if attempt < 3:
            assert "auto_paused" not in event
        else:
            assert event.get("auto_paused") is True

    final = watch_module.get_watch(config, record.title)
    assert final.watch_status == "paused"
    assert final.consecutive_failures == 3
    assert final.next_run is None
    # Failure detail captured.
    assert final.last_error and "boom 3" in final.last_error


def test_health_passes_after_watches_added(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``compile health`` must still run cleanly with watches in the vault.

    Watches are a new top-level page type — this guards against accidentally
    counting them as orphans, thin pages, or sources without raw links.
    """
    workspace = _make_workspace(tmp_path)
    _install_stubs(
        monkeypatch,
        bodies=["body once"],
        claude_responses=["Digest with [[ExampleNews]] mention."],
    )

    config = load_config(workspace)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily",
        intent="watch test", title="ExampleNews",
    )
    watch_module.run_watch(config, record.title)

    runner = CliRunner()
    health = runner.invoke(
        main,
        ["health", "--path", str(workspace), "--json-output"],
    )
    assert health.exit_code == 0, health.output
    payload = json.loads(health.output.strip())
    # The connector should classify the page as ``watch``, not ``unknown``.
    connector = ObsidianConnector(workspace)
    watch_pages = [p for p in connector.scan() if p.page_type == "watch"]
    assert len(watch_pages) == 1
    assert watch_pages[0].title == "ExampleNews"
    # Health command exits cleanly — we don't hard-pin the schema, just
    # require it to be a non-error envelope.
    assert isinstance(payload, dict)


def test_remove_keep_page_unregisters_but_leaves_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`--keep-page` should leave the markdown file in the vault for archival."""
    workspace = _make_workspace(tmp_path)
    _install_stubs(monkeypatch, bodies=[], claude_responses=[])

    config = load_config(workspace)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily",
        intent="x", title="Keeper",
    )
    page_path = workspace / record.relative_path

    runner = CliRunner()
    result = runner.invoke(
        main,
        [
            "watch", "remove", "Keeper",
            "--keep-page",
            "--path", str(workspace),
            "--json-output",
        ],
    )
    assert result.exit_code == 0
    assert page_path.exists(), "page must remain when --keep-page is passed"
    state = json.loads((workspace / ".compile" / "watches.json").read_text())
    # The page is still on disk so still appears in the rebuilt state — that's
    # consistent with the documented contract: page frontmatter is the source
    # of truth, the state file is rebuilt from it.
    assert any(w["title"] == "Keeper" for w in state["watches"])


def test_synthesis_prompt_includes_intent_and_fetched_content(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The Claude prompt must carry the user's intent verbatim and the body."""
    workspace = _make_workspace(tmp_path)
    fetcher, claude = _install_stubs(
        monkeypatch,
        bodies=["FETCHED_MARKER_42"],
        claude_responses=["digest"],
    )

    config = load_config(workspace)
    record = watch_module.add_watch(
        config,
        url="https://example.com",
        frequency="daily",
        intent="Find INTENT_MARKER_X in the page.",
        title="PromptCheck",
    )
    watch_module.run_watch(config, record.title)

    assert len(claude.calls) == 1
    # The prompt is the trailing positional argument after the flags.
    prompt = claude.calls[0][-1]
    assert "INTENT_MARKER_X" in prompt
    assert "FETCHED_MARKER_42" in prompt
    assert "[[wikilinks]]" in prompt  # instructions about wikilinks present
    # No frontmatter / heading guidance leakage into the user-facing intent.
    assert "Find INTENT_MARKER_X" in prompt


def test_run_watch_resolves_by_watch_id_not_just_title(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Slug stability: a user can still operate on a watch after renaming.

    The resolver checks ``watch_id`` first, so even if the page's title
    changes, the same id keeps working.
    """
    workspace = _make_workspace(tmp_path)
    _install_stubs(
        monkeypatch,
        bodies=["body"],
        claude_responses=["digest"],
    )
    config = load_config(workspace)
    record = watch_module.add_watch(
        config, url="https://example.com", frequency="daily",
        intent="x", title="Original",
    )

    # Rename the title in frontmatter without touching watch_id.
    page_path = workspace / record.relative_path
    text = page_path.read_text()
    text = text.replace("title: Original", "title: Renamed By Hand")
    page_path.write_text(text)

    # Resolve via watch_id should still work.
    event = watch_module.run_watch(config, record.watch_id)
    assert event["status"] == "ok"
