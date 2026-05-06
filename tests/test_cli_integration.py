"""Integration tests for CLI commands."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from compile.cli import main
from compile.pdf_artifacts import compute_sha256
from compile.workspace import init_workspace


def _write_page(path: Path, title: str, page_type: str, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"---\ntitle: {title}\ntype: {page_type}\nstatus: seed\n"
        f"summary: 'Test page.'\nupdated: 2026-01-01 00:00\n---\n\n"
        f"# {title}\n\n{body}\n"
    )


def _write_pdf(path: Path, *, text: str = "") -> None:
    fitz = pytest.importorskip("fitz")

    path.parent.mkdir(parents=True, exist_ok=True)
    doc = fitz.open()
    page = doc.new_page()
    if text:
        page.insert_text((72, 72), text)
    doc.save(path)
    doc.close()


class TestInitCommand:
    def test_basic_init(self, tmp_path: Path) -> None:
        runner = CliRunner()
        result = runner.invoke(main, ["init", "Rhizome", "-p", str(tmp_path / "new")])
        assert result.exit_code == 0
        assert "initialized" in result.output.lower()
        assert (tmp_path / "new" / "wiki").is_dir()

    def test_init_with_description(self, tmp_path: Path) -> None:
        runner = CliRunner()
        result = runner.invoke(main, [
            "init", "Rhizome", "-d", "A personal knowledge base", "-p", str(tmp_path / "new"),
        ])
        assert result.exit_code == 0

    def test_init_existing_fails(self, tmp_path: Path) -> None:
        runner = CliRunner()
        runner.invoke(main, ["init", "First", "-p", str(tmp_path)])
        result = runner.invoke(main, ["init", "Second", "-p", str(tmp_path)])
        assert result.exit_code != 0
        assert "already exists" in result.output.lower()


class TestStatusCommand:
    def test_status(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test Wiki", "Description")
        runner = CliRunner()
        result = runner.invoke(main, ["status", "--path", str(tmp_path)], catch_exceptions=False)
        assert result.exit_code == 0
        assert "Test Wiki" in result.output
        assert "Description" in result.output

    def test_status_scan_failure_surfaces_clean_error(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test Wiki", "Description")
        runner = CliRunner()

        with patch("compile.obsidian.ObsidianConnector.scan", side_effect=RuntimeError("scan failed")):
            result = runner.invoke(main, ["status", "--path", str(tmp_path)])

        assert result.exit_code == 1
        assert "scan failed" in result.output


class TestMachineReadableCommands:
    def test_init_json_success(self, tmp_path: Path) -> None:
        runner = CliRunner()
        result = runner.invoke(main, ["init", "Rhizome", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["workspace"]["topic"] == "Rhizome"
        assert payload["workspace"]["path"] == str(tmp_path)

    def test_init_json_failure(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Existing")
        runner = CliRunner()

        result = runner.invoke(main, ["init", "Rhizome", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code != 0
        payload = json.loads(result.output)
        assert payload["ok"] is False
        assert "already exists" in payload["error"]

    def test_status_json_success(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test Wiki", "Description")
        runner = CliRunner()

        result = runner.invoke(main, ["status", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["workspace"]["topic"] == "Test Wiki"
        assert payload["workspace"]["description"] == "Description"
        assert payload["workspace"]["wikiPageCount"] >= 3

    def test_status_json_failure(self, tmp_path: Path) -> None:
        runner = CliRunner()

        result = runner.invoke(main, ["status", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code != 0
        payload = json.loads(result.output)
        assert payload["ok"] is False
        assert "No workspace found" in payload["error"]

    def test_status_json_scan_failure(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test Wiki", "Description")
        runner = CliRunner()

        with patch("compile.obsidian.ObsidianConnector.scan", side_effect=RuntimeError("scan failed")):
            result = runner.invoke(main, ["status", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code != 0
        payload = json.loads(result.output)
        assert payload["ok"] is False
        assert payload["context"] == "status"
        assert "scan failed" in payload["error"]

    def test_status_json_does_not_recompute_status_after_success(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test Wiki", "Description")
        runner = CliRunner()
        calls = {"count": 0}

        def flaky_status(config):
            calls["count"] += 1
            if calls["count"] > 1:
                raise RuntimeError("second call failed")
            return {
                "topic": "Test Wiki",
                "description": "Description",
                "workspace_root": str(tmp_path),
                "raw_files": 0,
                "processed": 0,
                "unprocessed": 0,
                "needs_document_review": 0,
                "wiki_pages": 3,
            }

        with patch("compile.cli.get_status", side_effect=flaky_status):
            result = runner.invoke(main, ["status", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["workspace"]["topic"] == "Test Wiki"
        assert calls["count"] == 1

    def test_ingest_json_stream_local_file(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "article.md"
        raw_file.write_text("# My Article\n\nImportant findings about the topic.")
        runner = CliRunner()

        result = runner.invoke(
            main,
            ["ingest", "article.md", "--path", str(tmp_path), "--json-stream"],
        )

        assert result.exit_code == 0
        events = [json.loads(line) for line in result.output.splitlines() if line.strip()]
        assert [event["event"] for event in events] == [
            "started",
            "extracting",
            "source_note_written",
            "navigation_refreshed",
            "completed",
        ]
        assert events[-1]["note_path"] == "wiki/sources/My Article.md"
        assert "links_added" not in events[-1]

    def test_ingest_json_stream_url_emits_fetched(self, tmp_path: Path, monkeypatch) -> None:
        init_workspace(tmp_path, "Test")
        fetched = tmp_path / "raw" / "fetched.md"
        fetched.write_text("# Example\n\nFetched content.")

        def fake_fetch_url(url: str, raw_dir: Path, *, download_images: bool = False) -> tuple[Path, str]:
            assert url == "https://example.com/report"
            assert raw_dir == tmp_path / "raw"
            return fetched, "Fetched Title"

        monkeypatch.setattr("compile.cli.fetch_url", fake_fetch_url)
        runner = CliRunner()

        result = runner.invoke(
            main,
            ["ingest", "https://example.com/report", "--path", str(tmp_path), "--json-stream"],
        )

        assert result.exit_code == 0
        events = [json.loads(line) for line in result.output.splitlines() if line.strip()]
        assert events[1]["event"] == "fetched"
        assert events[1]["raw_path"] == "raw/fetched.md"

    def test_ingest_json_stream_preserved(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.md"
        raw_file.write_text("# Paper\n\nFresh content.")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Existing enriched note.\n"
            "sources:\n"
            "- raw/paper.md\n"
            "---\n\n"
            "# Paper\n\n"
            "## Synopsis\n\n"
            "Existing enriched content.\n\n"
            "## Provenance\n\n"
            "- Source file: ![[raw/paper.md]]\n"
        )
        runner = CliRunner()

        result = runner.invoke(main, ["ingest", "paper.md", "--path", str(tmp_path), "--json-stream"])

        assert result.exit_code == 0
        events = [json.loads(line) for line in result.output.splitlines() if line.strip()]
        assert events[-1]["event"] == "preserved"
        assert events[-1]["note_path"] == "wiki/sources/Paper.md"

    def test_ingest_json_stream_failure(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        result = runner.invoke(main, ["ingest", "missing.md", "--path", str(tmp_path), "--json-stream"])

        assert result.exit_code != 0
        events = [json.loads(line) for line in result.output.splitlines() if line.strip()]
        assert events[-1]["event"] == "failed"
        assert "Raw source not found" in events[-1]["message"]


class TestSchemaCommand:
    def test_schema_shows_content(self, tmp_path: Path, monkeypatch) -> None:
        init_workspace(tmp_path, "Test Wiki")
        monkeypatch.chdir(tmp_path)
        runner = CliRunner()
        result = runner.invoke(main, ["schema"])
        assert result.exit_code == 0
        assert "Workspace Schema" in result.output or "schema" in result.output.lower()


class TestIngestCommand:
    def test_ingest_local_file(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "article.md"
        raw_file.write_text("# My Article\n\nImportant findings about the topic.")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "article.md", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "source note created" in result.output.lower()

        # Source page should exist
        source_path = tmp_path / "wiki" / "sources" / "My Article.md"
        assert source_path.exists()
        source_text = source_path.read_text()
        assert "type: source" in source_text
        assert "## Synopsis" in source_text

    def test_ingest_notion_markdown_stamps_frontmatter(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "notion" / "product-notes.md"
        raw_file.parent.mkdir(parents=True, exist_ok=True)
        raw_file.write_text(
            "<!-- source: notion -->\n"
            "<!-- notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54 -->\n"
            "<!-- notion_page_url: https://www.notion.so/product-notes -->\n"
            "<!-- notion_last_edited_time: 2026-04-12T12:00:00Z -->\n"
            "<!-- notion_synced_at: 2026-04-12T12:05:00Z -->\n\n"
            "# Product Notes\n\nImportant roadmap decisions.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "raw/notion/product-notes.md", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Product Notes.md").read_text()
        assert "notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54" in source_text
        assert "notion_url: https://www.notion.so/product-notes" in source_text
        assert "notion_last_edited_time: '2026-04-12T12:00:00Z'" in source_text
        assert "notion_synced_at: '2026-04-12T12:05:00Z'" in source_text

    def test_reingest_notion_markdown_refreshes_matching_source_note(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "notion" / "product-notes.md"
        raw_file.parent.mkdir(parents=True, exist_ok=True)
        raw_file.write_text(
            "<!-- source: notion -->\n"
            "<!-- notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54 -->\n"
            "<!-- notion_page_url: https://www.notion.so/product-notes -->\n"
            "<!-- notion_last_edited_time: 2026-04-12T12:00:00Z -->\n"
            "<!-- notion_synced_at: 2026-04-12T12:05:00Z -->\n\n"
            "# Product Notes\n\nOriginal roadmap decisions.\n"
        )

        runner = CliRunner()
        first = runner.invoke(main, ["ingest", "raw/notion/product-notes.md", "--path", str(tmp_path)])
        assert first.exit_code == 0

        raw_file.write_text(
            "<!-- source: notion -->\n"
            "<!-- notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54 -->\n"
            "<!-- notion_page_url: https://www.notion.so/product-notes -->\n"
            "<!-- notion_last_edited_time: 2026-04-12T13:00:00Z -->\n"
            "<!-- notion_synced_at: 2026-04-12T13:05:00Z -->\n\n"
            "# Product Notes\n\nUpdated roadmap decisions.\n"
        )
        second = runner.invoke(main, ["ingest", "raw/notion/product-notes.md", "--path", str(tmp_path)])

        assert second.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Product Notes.md").read_text()
        assert "Updated roadmap decisions." in source_text
        assert "Original roadmap decisions." not in source_text
        assert "notion_last_edited_time: '2026-04-12T13:00:00Z'" in source_text

    def test_reingest_notion_markdown_preserves_user_claimed_note(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "notion" / "product-notes.md"
        raw_file.parent.mkdir(parents=True, exist_ok=True)
        raw_file.write_text(
            "<!-- source: notion -->\n"
            "<!-- notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54 -->\n"
            "<!-- notion_page_url: https://www.notion.so/product-notes -->\n"
            "<!-- notion_last_edited_time: 2026-04-12T12:00:00Z -->\n"
            "<!-- notion_synced_at: 2026-04-12T12:05:00Z -->\n\n"
            "# Product Notes\n\nOriginal roadmap decisions.\n"
        )

        runner = CliRunner()
        first = runner.invoke(main, ["ingest", "raw/notion/product-notes.md", "--path", str(tmp_path)])
        assert first.exit_code == 0

        source_path = tmp_path / "wiki" / "sources" / "Product Notes.md"
        source_text = source_path.read_text()
        source_text = source_text.replace("notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54\n", "")
        source_text = source_text.replace("Original roadmap decisions.", "User edited source note.")
        source_path.write_text(source_text)

        raw_file.write_text(
            "<!-- source: notion -->\n"
            "<!-- notion_page_id: 1429989f-e8ac-4eff-bc8f-57f56486db54 -->\n"
            "<!-- notion_page_url: https://www.notion.so/product-notes -->\n"
            "<!-- notion_last_edited_time: 2026-04-12T13:00:00Z -->\n"
            "<!-- notion_synced_at: 2026-04-12T13:05:00Z -->\n\n"
            "# Product Notes\n\nUpdated roadmap decisions.\n"
        )
        second = runner.invoke(main, ["ingest", "raw/notion/product-notes.md", "--path", str(tmp_path)])

        assert second.exit_code == 0
        assert "source already enriched" in second.output.lower()
        source_text = source_path.read_text()
        assert "User edited source note." in source_text
        assert "Updated roadmap decisions." not in source_text

    def test_ingest_with_title_override(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.md"
        raw_file.write_text("Content of the paper.")

        runner = CliRunner()
        result = runner.invoke(main, [
            "ingest", "paper.md", "--path", str(tmp_path), "--title", "Custom Title",
        ])

        assert result.exit_code == 0
        source_path = tmp_path / "wiki" / "sources" / "Custom Title.md"
        assert source_path.exists()

    def test_ingest_title_override_does_not_overwrite_existing_article(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "friendship.md",
            "Friendship",
            "article",
            "A durable article that should remain an article.",
        )
        raw_file = tmp_path / "raw" / "notes.md"
        raw_file.write_text("# Misc Notes\n\nReciprocal goodwill matters here.")

        runner = CliRunner()
        result = runner.invoke(main, [
            "ingest", "notes.md", "--path", str(tmp_path), "--title", "Friendship",
        ])

        assert result.exit_code == 0
        article_text = (tmp_path / "wiki" / "articles" / "friendship.md").read_text()
        source_text = (tmp_path / "wiki" / "sources" / "Friendship.md").read_text()
        assert "type: article" in article_text
        assert "type: source" in source_text

    def test_ingest_missing_file(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "nonexistent.md", "--path", str(tmp_path)])
        assert result.exit_code != 0

    def test_ingest_updates_nav(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "source.md"
        raw_file.write_text("# Source Title\n\nContent.")

        runner = CliRunner()
        runner.invoke(main, ["ingest", "source.md", "--path", str(tmp_path)])

        index = (tmp_path / "wiki" / "index.md").read_text()
        assert "Source Title" in index

        log = (tmp_path / "wiki" / "log.md").read_text()
        assert "ingest" in log

    def test_ingest_resolves_from_raw_dir(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "nested" / "deep.md"
        raw_file.parent.mkdir(parents=True)
        raw_file.write_text("# Deep\n\nNested content.")

        runner = CliRunner()
        # Pass relative path under raw/
        result = runner.invoke(main, ["ingest", "raw/nested/deep.md", "--path", str(tmp_path)])
        assert result.exit_code == 0

    def test_ingest_renames_file_with_unsafe_characters(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        bad_name = "retrospective: april 17.md"
        bad_file = tmp_path / "raw" / bad_name
        bad_file.write_text("# Retro\n\nSome thoughts.")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", bad_name, "--path", str(tmp_path)])
        assert result.exit_code == 0, result.output
        assert not bad_file.exists()
        renamed = tmp_path / "raw" / "retrospective-april-17.md"
        assert renamed.exists()
        assert "Renamed raw source" in result.output

    def test_ingest_rename_avoids_collision(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        existing = tmp_path / "raw" / "retrospective-april-17.md"
        existing.write_text("# Existing\n\n")
        bad_name = "retrospective: april 17.md"
        bad_file = tmp_path / "raw" / bad_name
        bad_file.write_text("# Retro\n\nSome thoughts.")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", bad_name, "--path", str(tmp_path)])
        assert result.exit_code == 0, result.output
        assert not bad_file.exists()
        assert existing.exists()  # untouched
        assert (tmp_path / "raw" / "retrospective-april-17-2.md").exists()

    def test_ingest_absolute_path_resolves_symlinks(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "sample.md"
        raw_file.write_text("# Sample\n\nSymlink case.")

        link_root = tmp_path.parent / f"{tmp_path.name}-link"
        link_root.symlink_to(tmp_path, target_is_directory=True)
        try:
            linked_source = link_root / "raw" / "sample.md"
            assert linked_source.exists()

            runner = CliRunner()
            result = runner.invoke(main, ["ingest", str(linked_source), "--path", str(tmp_path)])
            assert result.exit_code == 0, result.output
        finally:
            link_root.unlink()

    def test_ingest_pdf(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        pdf_file.write_bytes(b"%PDF-1.4 fake content")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Paper.md").read_text()
        assert "PDF source registered." in source_text
        assert "## Key Sections" not in source_text
        assert "review_status:" not in source_text
        assert not (tmp_path / ".compile" / "extract").exists()

    def test_ingest_pdf_title_override_keeps_placeholder_summary_title_consistent(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        pdf_file.write_bytes(b"%PDF-1.4 fake content")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.pdf", "--title", "Custom Title", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Custom Title.md").read_text()
        assert "title: Custom Title" in source_text
        assert "PDF source registered." in source_text
        assert "PDF source named Paper." not in source_text

    def test_ingest_pdf_with_text_creates_source_note_without_figure_block(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(
            pdf_file,
            text="This PDF has enough source text to avoid the registration shell fallback.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Paper.md").read_text()
        assert "This is a registration shell." not in source_text
        assert "This PDF has enough source text" in source_text
        assert "## Figures" not in source_text
        assert "<!-- compile:figures:start -->" not in source_text
        assert "review_status: needs_document_review" in source_text
        assert "extraction_method: pymupdf_text" in source_text
        assert "## Review Status" in source_text

        raw_sha = compute_sha256(pdf_file)
        sidecar = tmp_path / ".compile" / "extract" / f"{raw_sha}.json"
        assert sidecar.exists()
        payload = json.loads(sidecar.read_text())
        assert payload["schema_version"] == 1
        assert payload["raw_path"] == "raw/paper.pdf"
        assert payload["raw_sha256"] == raw_sha
        assert payload["extractor_name"] == "pymupdf_text"
        assert payload["requires_document_review"] is True
        assert "chunks" not in payload
        assert payload["pages"][0]["page_number"] == 1
        assert "This PDF has enough source text" in payload["pages"][0]["text"]

        assert "> [!abstract]- Full extracted text" in source_text
        assert "> This PDF has enough source text" in source_text

        connection = sqlite3.connect(tmp_path / ".compile" / "index" / "search.db")
        try:
            chunk_texts = [
                row[0]
                for row in connection.execute(
                    "SELECT chunk_text FROM chunks WHERE raw_sha256 = ?",
                    (raw_sha,),
                ).fetchall()
            ]
        finally:
            connection.close()
        assert any("This PDF has enough source text" in chunk for chunk in chunk_texts)
        for chunk in chunk_texts:
            assert chunk in " ".join(source_text.split())

        if shutil.which("rg") is None:
            pytest.skip("rg is required to verify broad grep visibility")
        rg = subprocess.run(
            ["rg", "This PDF has enough source text", str(tmp_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        assert rg.returncode == 0
        assert "wiki/sources/Paper.md" in rg.stdout

        inspect = runner.invoke(main, ["obsidian", "inspect", "--path", str(tmp_path), "--json-output"])
        assert inspect.exit_code == 0
        report = json.loads(inspect.output)
        assert report["raw_file_count"] == 1
        source_page = next(
            page for page in report["pages"]
            if page["relative_path"] == "wiki/sources/Paper.md"
        )
        assert source_page["resolved_file_links"] == ["raw/paper.pdf"]
        assert source_page["unresolved_outbound_links"] == []

    def test_reingest_unchanged_pdf_reuses_existing_sidecar(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(pdf_file, text="Reusable extracted PDF text.")

        runner = CliRunner()
        first = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert first.exit_code == 0

        sidecar = tmp_path / ".compile" / "extract" / f"{compute_sha256(pdf_file)}.json"
        payload = json.loads(sidecar.read_text())
        payload["extracted_at"] = "sentinel"
        sidecar.write_text(json.dumps(payload, indent=2))

        (tmp_path / "wiki" / "sources" / "Paper.md").unlink()
        second = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])

        assert second.exit_code == 0
        reloaded = json.loads(sidecar.read_text())
        assert reloaded["extracted_at"] == "sentinel"
        assert (tmp_path / "wiki" / "sources" / "Paper.md").exists()

    def test_preserved_pdf_source_note_gets_extracted_text_callout(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(pdf_file, text="Preserved note full text should be discoverable.")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Existing enriched PDF note.\n"
            "sources:\n"
            "- raw/paper.pdf\n"
            "---\n\n"
            "# Paper\n\n"
            "## Synopsis\n\n"
            "Existing enriched PDF content should remain intact.\n\n"
            "## Provenance\n\n"
            "- Source file: ![[raw/paper.pdf]]\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Source already enriched" in result.output
        updated = source_path.read_text()
        assert "Existing enriched PDF content should remain intact." in updated
        assert "> [!abstract]- Full extracted text" in updated
        assert "> Preserved note full text should be discoverable." in updated

    def test_reingest_unreviewed_extracted_pdf_refreshes_source_note_when_raw_changes(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(pdf_file, text="Original extracted PDF text.")

        runner = CliRunner()
        first = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert first.exit_code == 0

        _write_pdf(pdf_file, text="Updated extracted PDF text.")
        second = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])

        assert second.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Paper.md").read_text()
        assert "Updated extracted PDF text." in source_text
        assert "Original extracted PDF text." not in source_text

    def test_reingest_enriched_pdf_with_historical_managed_block_preserves_content(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(
            pdf_file,
            text="This PDF has enough source text to extract.",
        )
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        original = (
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Existing enriched note.\n"
            "sources:\n"
            "- raw/paper.pdf\n"
            "---\n\n"
            "# Paper\n\n"
            "## Synopsis\n\n"
            "Existing enriched content.\n\n"
            "<!-- compile:figures:start -->\n"
            "## Figures\n\n"
            "### Legacy Figure\n\n"
            "![[raw/assets/paper-legacy/page-001-figure-01.png]]\n\n"
            "<!-- compile:figures:end -->\n\n"
            "## Provenance\n\n"
            "- Source file: ![[raw/paper.pdf]]\n"
        )
        source_path.write_text(original)

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Source already enriched" in result.output
        updated = source_path.read_text()
        assert "Existing enriched content." in updated
        assert "<!-- compile:figures:start -->" in updated
        assert "### Legacy Figure" in updated
        assert "![[raw/assets/paper-legacy/page-001-figure-01.png]]" in updated
        assert "<!-- compile:figures:end -->" in updated
        assert "> [!abstract]- Full extracted text" in updated
        assert "> This PDF has enough source text to extract." in updated

    def test_ingest_non_raw_file_rejected(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        docs_file = tmp_path / "docs" / "note.md"
        docs_file.parent.mkdir(parents=True, exist_ok=True)
        docs_file.write_text("Some content outside raw/")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "docs/note.md", "--path", str(tmp_path)])

        assert result.exit_code != 0
        assert "raw/" in result.output

    def test_ingest_image_title_override_keeps_placeholder_summary_title_consistent(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        image_file = tmp_path / "raw" / "photo.jpg"
        image_file.write_bytes(b"\xff\xd8\xff\xe0")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "photo.jpg", "--title", "Custom Photo", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Custom Photo.md").read_text()
        assert "title: Custom Photo" in source_text
        assert "Image asset registered." in source_text
        assert "Image asset named Photo." not in source_text

    def test_ingest_builds_stronger_source_note(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "friendship.md",
            "Friendship",
            "article",
            "A durable synthesis of reciprocal goodwill and social trust.",
        )
        raw_file = tmp_path / "raw" / "friendship-source.md"
        raw_file.write_text(
            "# Friendship Source\n\n"
            "This source explains how friendship relies on reciprocal goodwill and social trust in durable communities. "
            "It frames the topic as a practical relationship rather than a purely abstract virtue.\n\n"
            "## Friendship\n\n"
            "A second paragraph expands on the maintenance of friendship through repeated practice, accountability, "
            "and shared obligations over time.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "friendship-source.md", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Friendship Source.md").read_text()
        assert "## Key Sections" in source_text
        assert "- Friendship" in source_text
        assert "A second paragraph expands" in source_text

    def test_ingest_strips_provenance_comments_from_synopsis(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "fetched.md"
        raw_file.write_text(
            "<!-- source_url: https://example.com/article -->\n"
            "<!-- fetched: 2026-04-07T00:00:00+00:00 -->\n\n"
            "# Fetched Article\n\n"
            "This is the first real paragraph from the fetched article.\n\n"
            "This is the second paragraph with more durable detail.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "fetched.md", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Fetched Article.md").read_text()
        assert "source_url" not in source_text
        assert "fetched:" not in source_text

    def test_ingest_empty_file_uses_default_summary_instead_of_provenance(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "empty.md"
        raw_file.write_text("")

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "empty.md", "--path", str(tmp_path)])

        assert result.exit_code == 0
        source_text = (tmp_path / "wiki" / "sources" / "Empty.md").read_text()
        assert "Minimal source content; no substantive summary available." in source_text
        assert "summary: '- Source file:" not in source_text

    def test_ingest_uses_override_title_for_source_note(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "friendship.md",
            "Friendship",
            "article",
            "A durable synthesis of reciprocal goodwill and social trust.",
        )
        raw_file = tmp_path / "raw" / "notes.md"
        raw_file.write_text("# Misc Notes\n\nShort unrelated text.")

        runner = CliRunner()
        result = runner.invoke(main, [
            "ingest", "notes.md", "--path", str(tmp_path), "--title", "Friendship Research",
        ])

        assert result.exit_code == 0
        source_path = tmp_path / "wiki" / "sources" / "Friendship Research.md"
        assert source_path.exists()
        source_text = source_path.read_text()
        assert "# Friendship Research" in source_text

    def test_ingest_skips_enriched_source_and_marks_processed(self, tmp_path: Path) -> None:
        """Re-ingesting a PDF whose source note was already enriched should not clobber it."""
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.pdf"
        raw_file.write_bytes(b"%PDF-1.4 fake")  # simulates unextractable PDF

        runner = CliRunner()
        # First ingest: creates a registration shell
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert result.exit_code == 0
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        assert "This is a registration shell." in source_path.read_text()

        # Simulate Claude enriching the source note
        enriched_body = (
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: 'A real paper.'\n"
            "sources:\n"
            "- raw/paper.pdf\n"
            "---\n\n"
            "# Paper\n\n"
            "## Synopsis\n\n"
            "Real enriched content here.\n"
        )
        source_path.write_text(enriched_body)

        # Second ingest: should skip and mark processed, not overwrite
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert result.exit_code == 0
        assert "Source already enriched" in result.output
        assert "Marked as processed" in result.output
        # Enriched content should be preserved
        assert "Real enriched content here." in source_path.read_text()
        assert "This is a registration shell." not in source_path.read_text()

    def test_ingest_same_title_from_different_raw_files_creates_distinct_sources(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        first = tmp_path / "raw" / "a" / "paper.md"
        second = tmp_path / "raw" / "b" / "paper.md"
        first.parent.mkdir(parents=True)
        second.parent.mkdir(parents=True)
        first.write_text("# Paper\n\nFirst source content about alpha.")
        second.write_text("# Paper\n\nSecond source content about beta.")

        runner = CliRunner()
        first_result = runner.invoke(main, ["ingest", "a/paper.md", "--path", str(tmp_path)])
        second_result = runner.invoke(main, ["ingest", "b/paper.md", "--path", str(tmp_path)])

        assert first_result.exit_code == 0
        assert second_result.exit_code == 0
        assert "Source already enriched" not in second_result.output

        source_pages = sorted(path.name for path in (tmp_path / "wiki" / "sources").glob("*.md"))
        assert source_pages == ["Paper (B).md", "Paper.md"]
        assert "raw/a/paper.md" in (tmp_path / "wiki" / "sources" / "Paper.md").read_text()
        assert "raw/b/paper.md" in (tmp_path / "wiki" / "sources" / "Paper (B).md").read_text()

    def test_ingest_normalized_title_collision_does_not_overwrite_existing_source(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        first = tmp_path / "raw" / "first.md"
        second = tmp_path / "raw" / "second.md"
        first.write_text("# Paper\n\nFirst source content.")
        second.write_text("# paper\n\nSecond source content.")

        runner = CliRunner()
        first_result = runner.invoke(main, ["ingest", "first.md", "--path", str(tmp_path)])
        second_result = runner.invoke(main, ["ingest", "second.md", "--path", str(tmp_path)])

        assert first_result.exit_code == 0
        assert second_result.exit_code == 0

        pages = sorted((tmp_path / "wiki" / "sources").glob("*.md"))
        assert len(pages) == 2
        contents = [path.read_text() for path in pages]
        assert any("First source content." in content and "raw/first.md" in content for content in contents)
        assert any("Second source content." in content and "raw/second.md" in content for content in contents)

    def test_ingest_fails_when_multiple_source_pages_share_exact_title(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.md"
        raw_file.write_text("# Paper\n\nSource content.")

        first = tmp_path / "wiki" / "sources" / "Paper.md"
        first.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: First source.\n"
            "sources:\n"
            "- raw/a.md\n"
            "---\n\n"
            "# Paper\n\n"
            "First duplicate title.\n"
        )
        second = tmp_path / "wiki" / "sources" / "Paper Copy.md"
        second.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: Second source.\n"
            "sources:\n"
            "- raw/b.md\n"
            "---\n\n"
            "# Paper\n\n"
            "Second duplicate title.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.md", "--path", str(tmp_path)])

        assert result.exit_code != 0
        assert "Multiple source pages titled 'Paper' exist" in result.output


    def test_reingest_with_different_title_reuses_existing_page(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.md"
        raw_file.parent.mkdir(parents=True, exist_ok=True)
        raw_file.write_text("# Paper\n\nOriginal content about something important.")

        runner = CliRunner()
        first = runner.invoke(main, ["ingest", "paper.md", "--path", str(tmp_path)])
        assert first.exit_code == 0

        # Re-ingest with a different title — should find the existing page by raw path,
        # not create a duplicate.  The enrichment guard will skip the overwrite.
        second = runner.invoke(main, ["ingest", "paper.md", "--title", "Better Title", "--path", str(tmp_path)])
        assert second.exit_code == 0
        assert "Source already enriched" in second.output

        source_pages = list((tmp_path / "wiki" / "sources").glob("*.md"))
        assert len(source_pages) == 1, f"Expected 1 source page, got {[p.name for p in source_pages]}"
        assert "raw/paper.md" in source_pages[0].read_text()

    def test_reingest_shell_with_different_title_renames_page(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        pdf_file.parent.mkdir(parents=True, exist_ok=True)
        # Write a fake PDF that produces a registration shell
        pdf_file.write_bytes(b"%PDF-1.4 fake")

        runner = CliRunner()
        first = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert first.exit_code == 0
        assert (tmp_path / "wiki" / "sources" / "Paper.md").exists()

        # Re-ingest the same shell with a title override — should replace the shell
        # at a new file path matching the title, not leave a Paper.md with mismatched title.
        second = runner.invoke(main, ["ingest", "paper.pdf", "--title", "Real Title", "--path", str(tmp_path)])
        assert second.exit_code == 0

        source_pages = sorted(p.name for p in (tmp_path / "wiki" / "sources").glob("*.md"))
        assert len(source_pages) == 1, f"Expected 1 source page, got {source_pages}"
        assert source_pages[0] == "Real Title.md"
        content = (tmp_path / "wiki" / "sources" / "Real Title.md").read_text()
        assert "raw/paper.pdf" in content
        assert "title: Real Title" in content

    def test_ingest_fails_when_multiple_source_pages_claim_same_raw_file(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.md"
        raw_file.write_text("# Paper\n\nSource content.")

        first = tmp_path / "wiki" / "sources" / "Paper.md"
        first.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: First source.\n"
            "sources:\n"
            "- raw/paper.md\n"
            "---\n\n"
            "# Paper\n\n"
            "First duplicate.\n"
        )
        second = tmp_path / "wiki" / "sources" / "Paper Copy.md"
        second.write_text(
            "---\n"
            "title: Paper Copy\n"
            "type: source\n"
            "status: seed\n"
            "summary: Second source.\n"
            "sources:\n"
            "- raw/paper.md\n"
            "---\n\n"
            "# Paper Copy\n\n"
            "Second duplicate.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.md", "--path", str(tmp_path)])

        assert result.exit_code != 0
        assert "Multiple source pages claim 'raw/paper.md'" in result.output

    def test_ingest_reuses_existing_source_when_frontmatter_raw_path_uses_backslashes(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.md"
        raw_file.write_text("# Paper\n\nSource content.")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        original = (
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: Existing source.\n"
            "sources:\n"
            "- raw\\paper.md\n"
            "---\n\n"
            "# Paper\n\n"
            "Existing enriched body.\n"
        )
        source_path.write_text(original)

        runner = CliRunner()
        result = runner.invoke(main, ["ingest", "paper.md", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Source already enriched" in result.output
        assert source_path.read_text() == original
        assert sorted(path.name for path in (tmp_path / "wiki" / "sources").glob("*.md")) == ["Paper.md"]

    def test_review_mark_reviewed_updates_review_frontmatter_and_preserves_body(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Extracted source note.\n"
            "sources:\n"
            "- raw/paper.pdf\n"
            "review_status: needs_document_review\n"
            "extraction_method: pymupdf_text\n"
            "---\n\n"
            "# Paper\n\n"
            "## Synopsis\n\n"
            "Preserve this body exactly.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["review", "mark-reviewed", "Paper", "--path", str(tmp_path)])

        assert result.exit_code == 0
        updated = source_path.read_text()
        assert "review_status: reviewed" in updated
        assert "reviewed_at:" in updated
        assert "Preserve this body exactly." in updated
        assert "extraction_method: pymupdf_text" in updated

    def test_review_mark_reviewed_does_not_rewrite_body_without_heading(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Extracted source note.\n"
            "review_status: needs_document_review\n"
            "---\n\n"
            "Body without an h1 heading.\n"
        )

        runner = CliRunner()
        result = runner.invoke(main, ["review", "mark-reviewed", "Paper", "--path", str(tmp_path)])

        assert result.exit_code == 0
        updated = source_path.read_text()
        assert "\n\nBody without an h1 heading.\n" in updated
        assert "# Paper" not in updated

    def test_obsidian_upsert_preserves_existing_review_frontmatter(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Existing reviewed source.\n"
            "sources:\n"
            "- raw/paper.pdf\n"
            "review_status: reviewed\n"
            "reviewed_at: 2026-01-01 00:00\n"
            "---\n\n"
            "# Paper\n\n"
            "Original body.\n"
        )

        runner = CliRunner()
        result = runner.invoke(
            main,
            [
                "obsidian",
                "upsert",
                "Paper",
                "--path",
                str(tmp_path),
                "--page-type",
                "source",
                "--body",
                "# Paper\n\nUpdated body.\n",
            ],
        )

        assert result.exit_code == 0
        updated = source_path.read_text()
        assert "review_status: reviewed" in updated
        assert "reviewed_at: 2026-01-01 00:00" in updated
        assert "Updated body." in updated

    def test_obsidian_upsert_body_file_auto_clears_needs_document_review(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: Extracted source note.\n"
            "sources:\n"
            "- raw/paper.pdf\n"
            "review_status: needs_document_review\n"
            "extraction_method: pymupdf_text\n"
            "---\n\n"
            "# Paper\n\n"
            "Original extracted body.\n"
        )

        body_file = tmp_path / "rewrite.md"
        substantive_body = "# Paper\n\n" + ("This is a substantive human-grade rewrite of the paper. " * 20)
        body_file.write_text(substantive_body)

        runner = CliRunner()
        result = runner.invoke(
            main,
            [
                "obsidian",
                "upsert",
                "Paper",
                "--path",
                str(tmp_path),
                "--page-type",
                "source",
                "--body-file",
                str(body_file),
            ],
        )

        assert result.exit_code == 0
        updated = source_path.read_text()
        assert "review_status:" not in updated
        assert "extraction_method: pymupdf_text" in updated
        assert "substantive human-grade rewrite" in updated

    def test_obsidian_upsert_body_file_keeps_review_status_with_keep_flag(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: seed\n"
            "summary: Extracted source note.\n"
            "review_status: needs_document_review\n"
            "---\n\n"
            "# Paper\n\n"
            "Original extracted body.\n"
        )

        body_file = tmp_path / "rewrite.md"
        substantive_body = "# Paper\n\n" + ("This is a substantive human-grade rewrite of the paper. " * 20)
        body_file.write_text(substantive_body)

        runner = CliRunner()
        result = runner.invoke(
            main,
            [
                "obsidian",
                "upsert",
                "Paper",
                "--path",
                str(tmp_path),
                "--page-type",
                "source",
                "--body-file",
                str(body_file),
                "--keep-review-status",
            ],
        )

        assert result.exit_code == 0
        updated = source_path.read_text()
        assert "review_status: needs_document_review" in updated

    def test_obsidian_upsert_clear_review_status_flag_clears_without_body_file(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        source_path = tmp_path / "wiki" / "sources" / "Paper.md"
        source_path.write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Extracted source note.\n"
            "review_status: needs_document_review\n"
            "---\n\n"
            "# Paper\n\n"
            "Body that should be preserved.\n"
        )

        runner = CliRunner()
        result = runner.invoke(
            main,
            [
                "obsidian",
                "upsert",
                "Paper",
                "--path",
                str(tmp_path),
                "--page-type",
                "source",
                "--clear-review-status",
            ],
        )

        assert result.exit_code == 0
        updated = source_path.read_text()
        assert "review_status:" not in updated
        assert "Body that should be preserved." in updated


class TestRemovedSourceCommand:
    def test_source_packet_command_is_removed(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["source", "packet", "paper.pdf", "--path", str(tmp_path)])

        assert result.exit_code != 0
        assert "No such command 'source'" in result.output


class TestObsidianInspectCommand:
    def test_inspect_json(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "inspect", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["layout"] == "compile_workspace"
        assert "total_pages" in payload

    def test_inspect_text(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "inspect", "--path", str(tmp_path)])
        assert result.exit_code == 0
        assert "pages" in result.output.lower()


class TestObsidianSearchCommand:
    def test_search_finds_page(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "friendship.md",
            "Friendship", "article", "Aristotle on friendship and virtue.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "search", "friendship", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Friendship" in result.output

    def test_search_filters_by_type(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "unique.md",
            "Unique Article", "article", "Distinct content.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "search", "Unique Article", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Unique Article" in result.output

    def test_search_downranks_generated_navigation_pages(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "evidence.md",
            "Evidence Page",
            "article",
            "needle pattern evidence lives here.",
        )
        _write_page(
            tmp_path / "wiki" / "index.md",
            "Index",
            "index",
            "needle pattern appears here only because this is a generated catalog.",
        )

        runner = CliRunner()
        result = runner.invoke(
            main,
            ["obsidian", "search", "needle pattern", "--path", str(tmp_path), "--json-output"],
        )

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["hits"][0]["title"] == "Evidence Page"
        assert payload["hits"][0]["page_type"] == "article"

    def test_index_rebuild_reuses_sidecars_and_deletes_orphans(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        first_pdf = tmp_path / "raw" / "first.pdf"
        second_pdf = tmp_path / "raw" / "second.pdf"
        _write_pdf(first_pdf, text="First indexed PDF text.")
        _write_pdf(second_pdf, text="Second indexed PDF text.")

        runner = CliRunner()
        first_ingest = runner.invoke(main, ["ingest", "first.pdf", "--path", str(tmp_path)])
        assert first_ingest.exit_code == 0

        orphan = tmp_path / ".compile" / "extract" / ("0" * 64 + ".json")
        orphan.parent.mkdir(parents=True, exist_ok=True)
        orphan.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "raw_path": "raw/missing.pdf",
                    "raw_sha256": "0" * 64,
                    "media_type": "application/pdf",
                    "extractor_name": "pymupdf_text",
                    "extractor_version": "1.27.2.2",
                    "extracted_at": "2026-01-01T00:00:00+00:00",
                    "extraction_mode": "text",
                    "requires_document_review": True,
                    "warnings": [],
                    "pages": [{"page_number": 1, "text": "orphaned"}],
                },
                indent=2,
            )
        )

        rebuild = runner.invoke(main, ["index", "rebuild", "--path", str(tmp_path)])

        assert rebuild.exit_code == 0
        assert "Reused sidecars: 1" in rebuild.output
        assert "Created sidecars: 1" in rebuild.output
        assert "Deleted orphan sidecars: 1" in rebuild.output
        assert (tmp_path / ".compile" / "index" / "search.db").exists()
        assert not orphan.exists()

    def test_search_uses_indexed_pdf_chunks_when_index_exists(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(
            pdf_file,
            text=(
                "Planner executor retrieval depends on local chunked search over extracted PDF text. "
                "This sentence is distinctive enough to appear in the search snippet."
            ),
        )

        runner = CliRunner()
        ingest = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        result = runner.invoke(
            main,
            ["obsidian", "search", "planner executor retrieval", "--path", str(tmp_path)],
        )

        assert ingest.exit_code == 0
        assert result.exit_code == 0
        assert (tmp_path / ".compile" / "index" / "search.db").exists()
        assert "Paper" in result.output
        assert "Planner executor retrieval" in result.output

    def test_search_still_finds_regular_wiki_pages_when_index_exists(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "friendship.md",
            "Friendship",
            "article",
            "A durable article about trust and reciprocity.",
        )
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(pdf_file, text="Indexed PDF text about retrieval.")

        runner = CliRunner()
        runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        runner.invoke(main, ["index", "rebuild", "--path", str(tmp_path)])
        result = runner.invoke(main, ["obsidian", "search", "Friendship", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Friendship" in result.output

    def test_search_uses_live_source_page_metadata_after_manual_edit(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        pdf_file = tmp_path / "raw" / "paper.pdf"
        _write_pdf(pdf_file, text="Searchable corpus text.")

        runner = CliRunner()
        ingest = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert ingest.exit_code == 0

        page_path = tmp_path / "wiki" / "sources" / "Paper.md"
        updated = page_path.read_text().replace("title: Paper", "title: Revised Paper")
        page_path.write_text(updated.replace("# Paper", "# Revised Paper"))

        result = runner.invoke(main, ["obsidian", "search", "Searchable corpus", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Revised Paper" in result.output


class TestObsidianPageCommand:
    def test_page_by_title(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "topic.md",
            "My Topic", "article", "Content about my topic.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "page", "My Topic", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "My Topic" in result.output

    def test_page_not_found(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "page", "Nonexistent", "--path", str(tmp_path)])
        assert result.exit_code != 0


class TestObsidianUpsertCommand:
    def test_create_article(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "New Article",
            "--page-type", "article",
            "--body", "Article body content.",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 0
        assert (tmp_path / "wiki" / "articles" / "New Article.md").exists()

    def test_create_with_tags(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "Tagged",
            "--page-type", "article",
            "--body", "Content.",
            "--tag", "alpha",
            "--tag", "beta",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 0
        content = (tmp_path / "wiki" / "articles" / "Tagged.md").read_text()
        assert "alpha" in content
        assert "beta" in content

    def test_create_source(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "My Source",
            "--page-type", "source",
            "--body", "Source content.",
            "--source", "raw/paper.pdf",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 0
        assert (tmp_path / "wiki" / "sources" / "My Source.md").exists()

    def test_upsert_enriching_shell_marks_processed(self, tmp_path: Path) -> None:
        """compile obsidian upsert replacing a registration shell should mark the raw source processed."""
        from compile.config import load_config
        from compile.workspace import get_unprocessed
        init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "paper.pdf"
        raw_file.write_bytes(b"%PDF-1.4 fake")

        runner = CliRunner()
        # Ingest creates a registration shell (metadata-only, not marked processed)
        result = runner.invoke(main, ["ingest", "paper.pdf", "--path", str(tmp_path)])
        assert result.exit_code == 0
        config = load_config(tmp_path)
        assert len(get_unprocessed(config)) == 1

        # Enrich via upsert (the documented PDF workflow)
        result = runner.invoke(main, [
            "obsidian", "upsert", "Paper",
            "--page-type", "source",
            "--body", "## Synopsis\n\nReal enriched content from reading the PDF.",
            "--path", str(tmp_path),
        ])
        assert result.exit_code == 0
        assert "Marked processed" in result.output
        assert len(get_unprocessed(config)) == 0

    def test_create_map(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "Topic Map",
            "--page-type", "map",
            "--body", "Map content.",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 0
        assert (tmp_path / "wiki" / "maps" / "Topic Map.md").exists()

    def test_create_output(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "Query Result",
            "--page-type", "output",
            "--body", "Output content.",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 0
        assert (tmp_path / "wiki" / "outputs" / "Query Result.md").exists()

    def test_update_existing(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Evolving",
            "--page-type", "article",
            "--body", "Version 1.",
            "--path", str(tmp_path),
        ])
        runner.invoke(main, [
            "obsidian", "upsert", "Evolving",
            "--page-type", "article",
            "--body", "Version 2.",
            "--path", str(tmp_path),
        ])

        content = (tmp_path / "wiki" / "articles" / "Evolving.md").read_text()
        assert "Version 2" in content

    def test_status_flag_sets_and_overrides(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Maturing",
            "--page-type", "article",
            "--body", "Initial body.",
            "--status", "seed",
            "--path", str(tmp_path),
        ])
        content = (tmp_path / "wiki" / "articles" / "Maturing.md").read_text()
        assert "status: seed" in content

        runner.invoke(main, [
            "obsidian", "upsert", "Maturing",
            "--page-type", "article",
            "--body", "Expanded body.",
            "--status", "emerging",
            "--path", str(tmp_path),
        ])
        content = (tmp_path / "wiki" / "articles" / "Maturing.md").read_text()
        assert "status: emerging" in content
        assert "status: seed" not in content

    def test_status_only_update_preserves_body(self, tmp_path: Path) -> None:
        """Status demotion without a body flag must not wipe the page body."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Preserve",
            "--page-type", "article",
            "--body", "Substantive body with real content.",
            "--status", "stable",
            "--path", str(tmp_path),
        ])
        runner.invoke(main, [
            "obsidian", "upsert", "Preserve",
            "--page-type", "article",
            "--status", "seed",
            "--path", str(tmp_path),
        ])

        content = (tmp_path / "wiki" / "articles" / "Preserve.md").read_text()
        assert "status: seed" in content
        assert "Substantive body with real content." in content

    def test_upsert_with_no_body_and_no_existing_page_errors(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "Ghost",
            "--page-type", "article",
            "--status", "seed",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 1
        assert "No body provided" in result.output

    def test_status_only_update_does_not_borrow_body_from_other_page_type(self, tmp_path: Path) -> None:
        """If a page with the same title but a different type exists, a status-only
        upsert must NOT reuse that page's body — it must error because there's no
        same-type page to preserve."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Shared",
            "--page-type", "map",
            "--body", "Map-only body — must not leak into the article.",
            "--path", str(tmp_path),
        ])
        result = runner.invoke(main, [
            "obsidian", "upsert", "Shared",
            "--page-type", "article",
            "--status", "seed",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 1
        assert "No body provided" in result.output
        assert not (tmp_path / "wiki" / "articles" / "Shared.md").exists()

    def test_status_only_update_with_relative_path_preserves_body(self, tmp_path: Path) -> None:
        """--relative-path targets a specific file; status-only upsert must
        preserve that file's body, not error."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Pinned",
            "--page-type", "article",
            "--body", "Pinned body content.",
            "--relative-path", "wiki/articles/custom-path.md",
            "--path", str(tmp_path),
        ])
        result = runner.invoke(main, [
            "obsidian", "upsert", "Pinned",
            "--page-type", "article",
            "--status", "emerging",
            "--relative-path", "wiki/articles/custom-path.md",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 0
        content = (tmp_path / "wiki" / "articles" / "custom-path.md").read_text()
        assert "status: emerging" in content
        assert "Pinned body content." in content

    def test_ambiguous_title_surfaces_error(self, tmp_path: Path) -> None:
        """When upsert cannot unambiguously resolve a target, the command must
        fail with the connector's ambiguity message — not silently write."""
        init_workspace(tmp_path, "Test")
        articles_dir = tmp_path / "wiki" / "articles"
        articles_dir.mkdir(parents=True, exist_ok=True)
        # Two articles with the same title in different files.
        for slug in ("dup-a.md", "dup-b.md"):
            (articles_dir / slug).write_text(
                "---\ntitle: Duplicate\ntype: article\nstatus: seed\n---\n\n"
                "# Duplicate\n\nBody.\n"
            )
        runner = CliRunner()
        result = runner.invoke(main, [
            "obsidian", "upsert", "Duplicate",
            "--page-type", "article",
            "--status", "emerging",
            "--path", str(tmp_path),
        ])

        assert result.exit_code == 1
        assert "Ambiguous" in result.output

    def test_title_rename_rewrites_stale_h1(self, tmp_path: Path) -> None:
        """If the caller renames a page (via new title + same --relative-path),
        the preserved body's stale ``# Old Title`` heading must be rewritten
        to match the new frontmatter title."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Old Title",
            "--page-type", "article",
            "--body", "Body paragraph after the heading.",
            "--relative-path", "wiki/articles/custom.md",
            "--path", str(tmp_path),
        ])
        runner.invoke(main, [
            "obsidian", "upsert", "New Title",
            "--page-type", "article",
            "--status", "emerging",
            "--relative-path", "wiki/articles/custom.md",
            "--path", str(tmp_path),
        ])

        content = (tmp_path / "wiki" / "articles" / "custom.md").read_text()
        assert "title: New Title" in content
        assert "# New Title" in content
        assert "# Old Title" not in content
        assert "Body paragraph after the heading." in content

    def test_title_rename_via_positional_rewrites_stale_h1(self, tmp_path: Path) -> None:
        """Same fix applies when resolution goes through title (no --relative-path):
        a status-only upsert with a new title must rewrite the stale H1."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Alpha",
            "--page-type", "article",
            "--body", "Real content.",
            "--path", str(tmp_path),
        ])
        # Rename in-place by passing the new title and pointing at the same file.
        runner.invoke(main, [
            "obsidian", "upsert", "Beta",
            "--page-type", "article",
            "--status", "seed",
            "--relative-path", "wiki/articles/Alpha.md",
            "--path", str(tmp_path),
        ])

        content = (tmp_path / "wiki" / "articles" / "Alpha.md").read_text()
        assert "title: Beta" in content
        assert "# Beta" in content
        assert "# Alpha" not in content

    def test_user_provided_body_heading_is_not_rewritten(self, tmp_path: Path) -> None:
        """Don't clobber a caller-supplied body whose H1 differs from the title
        — that's an explicit choice, not a stale preservation artifact."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Prior",
            "--page-type", "article",
            "--body", "# Prior\n\nBody.",
            "--path", str(tmp_path),
        ])
        runner.invoke(main, [
            "obsidian", "upsert", "Prior",
            "--page-type", "article",
            "--body", "# Custom Intro\n\nRewritten body.",
            "--path", str(tmp_path),
        ])

        content = (tmp_path / "wiki" / "articles" / "Prior.md").read_text()
        assert "# Custom Intro" in content
        assert "# Prior" not in content

    def test_status_change_rebuilds_cssclasses(self, tmp_path: Path) -> None:
        """Demotion/promotion must not leave stale maturity labels in cssclasses."""
        init_workspace(tmp_path, "Test")
        runner = CliRunner()

        runner.invoke(main, [
            "obsidian", "upsert", "Cycling",
            "--page-type", "article",
            "--body", "Body.",
            "--status", "stable",
            "--path", str(tmp_path),
        ])
        runner.invoke(main, [
            "obsidian", "upsert", "Cycling",
            "--page-type", "article",
            "--status", "seed",
            "--path", str(tmp_path),
        ])

        content = (tmp_path / "wiki" / "articles" / "Cycling.md").read_text()
        assert "- seed" in content
        assert "- stable" not in content
        assert "- article" in content


class TestObsidianRefreshCommand:
    def test_refresh(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "topic.md",
            "Topic", "article", "Content.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "refresh", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "refreshed" in result.output.lower()
        index = (tmp_path / "wiki" / "index.md").read_text()
        assert "[[Topic]]" in index


class TestObsidianNeighborsCommand:
    def test_neighbors(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "a.md",
            "Alpha", "article", "Links to [[Beta]].",
        )
        _write_page(
            tmp_path / "wiki" / "articles" / "b.md",
            "Beta", "article", "Linked from Alpha.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "neighbors", "Alpha", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Alpha" in result.output
        assert "Beta" in result.output


class TestObsidianJsonCommands:
    def test_search_json(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "alpha.md",
            "Alpha",
            "article",
            "Links to [[Beta]].",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "search", "Alpha", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["hits"][0]["title"] == "Alpha"

    def test_page_json(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "alpha.md",
            "Alpha",
            "article",
            "Links to [[Beta]].",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "page", "Alpha", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["page"]["title"] == "Alpha"
        assert "Links to [[Beta]]." in payload["page"]["body"]

    def test_neighbors_json(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "alpha.md",
            "Alpha",
            "article",
            "Links to [[Source A]].",
        )
        _write_page(
            tmp_path / "wiki" / "sources" / "source-a.md",
            "Source A",
            "source",
            "Primary source evidence.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "neighbors", "Alpha", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["neighborhood"]["page"]["title"] == "Alpha"
        assert payload["neighborhood"]["supporting_source_pages"] == ["Source A"]


class TestObsidianGraphCommand:
    def test_graph(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "a.md",
            "Alpha", "article", "Links to [[Beta]].",
        )
        _write_page(
            tmp_path / "wiki" / "articles" / "b.md",
            "Beta", "article", "Content.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "graph", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "nodes" in result.output or "edges" in result.output


class TestSuggestMapsCommand:
    def test_suggest_maps_reports_existing_map_updates(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "maps" / "evaluation-metrics.md",
            "Evaluation Metrics",
            "map",
            "Tracks evaluation metrics for generated text and code generation.",
        )
        _write_page(
            tmp_path / "wiki" / "sources" / "bertscore.md",
            "Evaluation Metrics BERTScore",
            "source",
            "BERTScore compares generated text using contextual embeddings.\n\nAnother paragraph.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["suggest", "maps", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "Suggested map updates" in result.output
        assert "Evaluation Metrics" in result.output
        assert "Evaluation Metrics BERTScore" in result.output

    def test_suggest_maps_json_reports_unmatched_unanchored_sources(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "maps" / "evaluation-metrics.md",
            "Evaluation Metrics",
            "map",
            "Tracks evaluation metrics for generated text and code generation.",
        )
        _write_page(
            tmp_path / "wiki" / "sources" / "bertscore.md",
            "Evaluation Metrics BERTScore",
            "source",
            "BERTScore compares generated text using contextual embeddings.\n\nAnother paragraph.",
        )
        _write_page(
            tmp_path / "wiki" / "sources" / "planning.md",
            "Agentic Planning",
            "source",
            "Planning loops coordinate tools and execution.\n\nAnother paragraph.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["suggest", "maps", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["ok"] is True
        assert payload["suggestions"][0]["map_title"] == "Evaluation Metrics"
        assert payload["suggestions"][0]["source_notes"][0]["title"] == "Evaluation Metrics BERTScore"
        assert payload["unanchored_sources"][0]["title"] == "Agentic Planning"

    def test_suggest_maps_ignores_source_notes_already_connected_to_article(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "topic.md",
            "Topic",
            "article",
            "Topic overview.\n\nAnother paragraph.",
        )
        _write_page(
            tmp_path / "wiki" / "sources" / "source.md",
            "Connected Source",
            "source",
            "Links to [[Topic]].\n\nAnother paragraph.",
        )

        runner = CliRunner()
        result = runner.invoke(main, ["suggest", "maps", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert payload["suggestions"] == []
        assert payload["unanchored_sources"] == []


class TestObsidianCleanupCommand:
    def test_cleanup_empty_files(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        ghost = tmp_path / "Ghost Page.md"
        ghost.write_text("")

        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "cleanup", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert not ghost.exists()

    def test_cleanup_nothing(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["obsidian", "cleanup", "--path", str(tmp_path)])

        assert result.exit_code == 0
        assert "no empty" in result.output.lower()


class TestHealthCommand:
    def test_health_json(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["health", "--path", str(tmp_path), "--json-output"])

        assert result.exit_code == 0
        payload = json.loads(result.output)
        assert "overall_status" in payload

    def test_health_text(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["health", "--path", str(tmp_path)])
        assert result.exit_code == 0

    def test_health_text_surfaces_editorial_metrics(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        runner = CliRunner()
        result = runner.invoke(main, ["health", "--path", str(tmp_path)])
        assert result.exit_code == 0
        assert "knowledge_pages" in result.output
        assert "source_to_knowledge_page_ratio" in result.output
        assert "unanchored_sources" in result.output
        assert "--json-output" in result.output
