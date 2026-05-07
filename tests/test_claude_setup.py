from __future__ import annotations

import json
from pathlib import Path

from click.testing import CliRunner

from compile.cli import main, install_claude_files
from compile.workspace import init_workspace


def _make_workspace(tmp_path: Path, name: str = "wiki") -> Path:
    ws = tmp_path / name
    init_workspace(ws, "Test Wiki", "A test workspace.")
    return ws


def _template_names(*parts: str) -> list[str]:
    template_dir = Path(__file__).resolve().parents[1] / "compile" / "templates"
    for part in parts:
        template_dir /= part
    return sorted(path.name for path in template_dir.iterdir() if path.is_file())


def test_fresh_install(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()

    result = install_claude_files(ws, home, force=False)

    global_templates = _template_names("global")
    workspace_templates = _template_names("workspace", "commands")

    assert len(result["installed"]) == len(global_templates) + len(workspace_templates) + 2
    assert result["skipped"] == []
    assert result["mispointed"] == []

    for name in global_templates:
        content = (home / ".claude" / "commands" / name).read_text()
        assert str(ws) in content
        assert "{{wiki_path}}" not in content

    query = (home / ".claude" / "commands" / "query.md").read_text()
    assert "markdown is the fallback" not in query
    assert "First try the current working directory" in query
    assert f'cd "{ws}" && compile ...' in query
    assert "--nodes-file" in query
    assert "--script-file" in query
    assert "Brief/casual lookup or callback" in query
    assert "Explicit artifact request" in query
    assert "create the artifact immediately" in query
    assert "Do not ask whether to save it again" in query
    assert "Do not use a generic save offer" in query
    assert "Want me to save this as a wiki output page?" not in query
    assert "Only save it if the user says yes" not in query
    assert "fill any gaps from web-backed or general knowledge" in query
    assert "Do not refuse just because the topic is outside the wiki" in query
    assert "Do not mention your knowledge cutoff" in query
    assert "direct `rg`/file search across `wiki/` and `raw/`" in query
    assert "inventory, count, list-all, and duplicate queries" in query
    assert "quote, verbatim, or \"in their own words\"" in query
    assert "which sources support which moves" in query
    assert "WebSearch`/`WebFetch" in query
    assert "LaTeX math notation, not Unicode math symbols" in query

    context = (home / ".claude" / "commands" / "context.md").read_text()
    assert "First try the current working directory" in context
    assert f'cd "{ws}" && compile ...' in context

    assert not (ws / ".claude" / "commands" / "query.md").exists()
    assert not (ws / ".claude" / "commands" / "context.md").exists()

    workspace_claude = (ws / "CLAUDE.md").read_text()
    assert "markdown paragraphs are the fallback" in workspace_claude.lower()
    assert "compile render canvas" in workspace_claude
    assert "low-level page writes" in workspace_claude.lower()
    assert "below the fold" in workspace_claude.lower()
    assert "direct pdf or document understanding" in workspace_claude.lower()
    assert "compile source packet" not in workspace_claude
    assert "## Enrich Workflow" not in workspace_claude
    assert "<!-- compile:figures:start -->" not in workspace_claude
    assert "create them when the user asks for them or explicitly agrees" in workspace_claude.lower()
    assert "not a hard boundary on what you can answer" in workspace_claude
    assert "answer from web-backed or general knowledge anyway" in workspace_claude
    assert "knowledge-cutoff disclaimers" in workspace_claude
    assert (ws / ".claude" / "settings.local.json").exists()
    settings_content = (ws / ".claude" / "settings.local.json").read_text()
    assert '"mcp__notion"' in settings_content
    assert '"Edit(raw/notion/**)"' in settings_content
    assert '"Bash(compile health)"' in settings_content
    assert '"Bash(compile status*)"' not in settings_content
    assert '"Bash(compile health*)"' not in settings_content
    assert ".compile/rhizome-bin/compile status --path . --json-output" in settings_content
    for name in workspace_templates:
        assert (ws / ".claude" / "commands" / name).exists()


def test_setup_backfills_existing_pdf_fulltext_callouts(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()

    raw_sha = "a" * 64
    extract_dir = ws / ".compile" / "extract"
    extract_dir.mkdir(parents=True)
    (extract_dir / f"{raw_sha}.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "raw_path": "raw/paper.pdf",
                "raw_sha256": raw_sha,
                "media_type": "application/pdf",
                "extractor_name": "pymupdf_text",
                "extractor_version": "1.27.2.2",
                "extracted_at": "2026-01-01T00:00:00+00:00",
                "extraction_mode": "text",
                "requires_document_review": True,
                "warnings": [],
                "pages": [{"page_number": 1, "text": "Backfilled full text."}],
            }
        )
    )
    source_path = ws / "wiki" / "sources" / "Paper.md"
    source_path.write_text(
        "---\n"
        "title: Paper\n"
        "type: source\n"
        "sources:\n"
        "- raw/paper.pdf\n"
        "---\n\n"
        "# Paper\n\n"
        "## Provenance\n\n"
        "- Source file: ![[raw/paper.pdf]]\n"
    )

    install_claude_files(ws, home, force=False)

    content = source_path.read_text()
    assert "> [!abstract]- Full extracted text" in content
    assert "> Backfilled full text." in content
    assert not (ws / "extracted" / f"{raw_sha}.txt").exists()


def test_skip_existing_without_force(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws, home, force=False)
    result = install_claude_files(ws, home, force=False)

    assert result["installed"] == []
    assert len(result["skipped"]) == len(_template_names("global")) + len(_template_names("workspace", "commands")) + 2
    assert result["mispointed"] == []


def test_force_overwrites(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws, home, force=False)
    result = install_claude_files(ws, home, force=True)

    assert len(result["installed"]) == len(_template_names("global")) + len(_template_names("workspace", "commands")) + 2
    assert result["skipped"] == []
    assert result["mispointed"] == []


def test_force_merges_existing_settings_local_json(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws, home, force=False)
    settings_path = ws / ".claude" / "settings.local.json"
    settings_path.write_text(
        """{
  "permissions": {
    "allow": [
      "Bash(custom command)"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "custom",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom"
          }
        ]
      }
    ]
  }
}
"""
    )

    install_claude_files(ws, home, force=True)

    merged = settings_path.read_text()
    assert '"Bash(custom command)"' in merged
    assert '"mcp__notion"' in merged
    assert '"matcher": "custom"' in merged
    assert ".compile/rhizome-bin/compile status --path . --json-output" in merged


def test_mispointed_globals_detected(tmp_path: Path) -> None:
    ws_a = _make_workspace(tmp_path, "wiki-a")
    ws_b = _make_workspace(tmp_path, "wiki-b")
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws_a, home, force=False)
    result = install_claude_files(ws_b, home, force=False)

    assert len(result["mispointed"]) == len(_template_names("global"))
    local_installed = [f for f in result["installed"] if str(ws_b) in f]
    assert len(local_installed) == len(_template_names("workspace", "commands")) + 2


def test_mispointed_globals_detected_with_prefix_overlap(tmp_path: Path) -> None:
    ws_old = _make_workspace(tmp_path, "wiki-old")
    ws_new = _make_workspace(tmp_path, "wiki")
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws_old, home, force=False)
    result = install_claude_files(ws_new, home, force=False)

    assert len(result["mispointed"]) == len(_template_names("global"))


def test_mispointed_globals_fixed_with_force(tmp_path: Path) -> None:
    ws_a = _make_workspace(tmp_path, "wiki-a")
    ws_b = _make_workspace(tmp_path, "wiki-b")
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws_a, home, force=False)
    result = install_claude_files(ws_b, home, force=True)

    assert result["mispointed"] == []
    for name in _template_names("global"):
        content = (home / ".claude" / "commands" / name).read_text()
        assert str(ws_b) in content
        assert str(ws_a) not in content


def test_path_with_spaces_quoted_in_shell_commands(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path, "Rhizome")
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws, home, force=False)

    for name in _template_names("global"):
        content = (home / ".claude" / "commands" / name).read_text()
        assert f'cd "{ws}"' in content
        for line in content.splitlines():
            if line.strip().startswith(("cd ", "`cd ")):
                assert f'cd "{ws}"' in line, f"Unquoted path in shell command: {line}"


def test_ingest_template_matches_simplified_workflow(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)
    ingest_content = (ws / ".claude" / "commands" / "ingest.md").read_text()
    assert "compile source packet" not in ingest_content
    assert "/enrich" not in ingest_content
    assert "<!-- compile:figures:start -->" not in ingest_content
    assert "compile render chart" in ingest_content
    assert "compile suggest maps" in ingest_content
    assert "workspace `CLAUDE.md`" in ingest_content
    assert "create it only if the user asks for it or explicitly agrees" in ingest_content.lower()
    assert "Connection Audit" not in ingest_content
    assert "## Topic Hubs" not in ingest_content
    # Two-phase structure: enrichment and wiring are explicit.
    assert "Phase A" in ingest_content
    assert "Phase B" in ingest_content
    # Phase A requires anchor existence checks before wikilinks are committed.
    assert "Before you commit any `[[wikilink]]`" in ingest_content
    assert "3-source bar" in ingest_content
    # Visible scaffolding (headed sections, gap callouts, disagreement callouts) is removed.
    assert "Do not add `## Themes`, `## Key Claims`, or `## Caveats`" in ingest_content
    assert "do not use `> [!warning] Disagreement` callouts" in ingest_content
    assert "do not add a `> [!note]` callout" in ingest_content
    assert "single-source map" in ingest_content
    assert "compile obsidian neighbors" in ingest_content
    assert "direct edits during `/ingest` are limited to the source note plus 1–3 theme anchors" in ingest_content
    assert "do not run multiple `compile ingest` commands in parallel" in ingest_content


def test_claude_md_has_status_discipline_and_synthesis_guidance(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)
    claude_md = (ws / "CLAUDE.md").read_text()
    assert "Status Discipline" in claude_md
    assert "What Good Synthesis Looks Like" in claude_md
    assert "Surface disagreement" in claude_md
    # Disagreements are written as plain prose, not [!warning] callouts.
    assert "Do not use `> [!warning] Disagreement` callouts" in claude_md
    # Maps must cover a coherent cluster, not a miscellaneous bucket.
    assert "miscellaneous" in claude_md
    # Substantive --body-file rewrites auto-clear review_status.
    assert "automatically clears `review_status: needs_document_review`" in claude_md
    # Two-phase ingest structure lives in the contract.
    assert "Phase A" in claude_md
    assert "Phase B" in claude_md
    assert "do not run multiple `compile ingest` commands in parallel" in claude_md


def test_notion_sync_template_separates_snapshot_and_ingest_phases(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)
    notion_sync = (ws / ".claude" / "commands" / "notion-sync.md").read_text()
    assert "write distinct `raw/notion/<page_id>.md` snapshots in parallel" in notion_sync
    assert "run `compile ingest raw/notion/<page_id>.md` one page at a time" in notion_sync
    assert "After the snapshot phase finishes" in notion_sync


def test_synthesize_command_is_installed(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)
    synthesize_path = ws / ".claude" / "commands" / "synthesize.md"
    assert synthesize_path.exists()
    content = synthesize_path.read_text()
    assert "compile health --json-output" in content
    assert "source_to_knowledge_page_ratio" in content
    assert "compile suggest maps" in content
    assert "compile obsidian neighbors" in content
    assert "broader edits belong" in content
    assert "keep each pass bounded to one chosen theme or cluster" in content
    # Wording is consistent with the renamed metric.
    assert "source-to-article ratio" not in content


def test_global_query_template_uses_conditional_persistence_targets(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)
    query_content = (home / ".claude" / "commands" / "query.md").read_text()
    assert "Do not use a generic save offer" in query_content
    assert "fold the answer into `[[Existing Article]]`" in query_content
    assert "apply the targeted fixes or delete/redirect the duplicate" in query_content
    assert "save it as a new `output` page" in query_content
    assert "Brief/casual/absence/simple lookup → no save offer" in query_content


def test_install_covers_all_current_template_files(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()

    install_claude_files(ws, home, force=False)

    installed_globals = sorted(path.name for path in (home / ".claude" / "commands").iterdir() if path.is_file())
    installed_workspace_commands = sorted(
        path.name for path in (ws / ".claude" / "commands").iterdir() if path.is_file()
    )

    assert installed_globals == _template_names("global")
    assert installed_workspace_commands == _template_names("workspace", "commands")


def test_templates_prefer_targeted_edits_over_rewrites(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)

    claude_md = (ws / "CLAUDE.md").read_text()
    assert "Prefer targeted edits over rewrites" in claude_md
    assert "`Edit` tool" in claude_md

    ingest = (ws / ".claude" / "commands" / "ingest.md").read_text()
    assert "Use the `Edit` tool" in ingest
    assert "Do not rewrite the whole anchor body" in ingest

    synthesize = (ws / ".claude" / "commands" / "synthesize.md").read_text()
    assert "use the `Edit` tool" in synthesize
    assert "Do not regenerate the whole article body" in synthesize

    lint = (ws / ".claude" / "commands" / "lint.md").read_text()
    assert "Default to the `Edit` tool" in lint


def test_watch_templates_installed(tmp_path: Path) -> None:
    ws = _make_workspace(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    install_claude_files(ws, home, force=False)

    watch_add = (ws / ".claude" / "commands" / "watch-add.md").read_text()
    assert "compile watch add" in watch_add
    assert "minimum cadence is hourly" in watch_add

    watch_review = (ws / ".claude" / "commands" / "watch-review.md").read_text()
    assert "compile watch list --json-output" in watch_review
    assert "consecutive_failures" in watch_review


def test_invalid_workspace_errors(tmp_path: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["claude", "setup", str(tmp_path / "nope")])
    assert result.exit_code == 1
    assert "No compile workspace" in result.output


def test_cli_reports_mispointed(tmp_path: Path, monkeypatch: object) -> None:
    ws_a = _make_workspace(tmp_path, "wiki-a")
    ws_b = _make_workspace(tmp_path, "wiki-b")
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))

    runner = CliRunner()
    runner.invoke(main, ["claude", "setup", str(ws_a)])
    result = runner.invoke(main, ["claude", "setup", str(ws_b)])

    assert "point at a different wiki" in result.output
    assert "--force" in result.output
