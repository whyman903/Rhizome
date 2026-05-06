from __future__ import annotations

import json
from pathlib import Path

import pytest

from compile.config import Config
from compile.workspace import (
    append_log_entry,
    collect_pages_by_type,
    ensure_workspace_schema,
    get_status,
    get_unprocessed,
    init_workspace,
    list_wiki_pages,
    load_state,
    mark_processed,
    read_schema,
    read_wiki_page,
    write_index,
    write_overview,
)


def _write_page(path: Path, title: str, page_type: str, body: str, summary: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    summary_line = f'summary: "{summary}"\n' if summary else ""
    path.write_text(
        f"---\ntitle: {title}\ntype: {page_type}\n{summary_line}---\n\n# {title}\n\n{body}\n"
    )


class TestInitWorkspace:
    def test_creates_directory_structure(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Rhizome", "A test wiki.")
        assert (tmp_path / "raw").is_dir()
        assert (tmp_path / "wiki" / "articles").is_dir()
        assert (tmp_path / "wiki" / "sources").is_dir()
        assert (tmp_path / "wiki" / "outputs").is_dir()
        assert (tmp_path / "wiki" / "maps").is_dir()
        assert (tmp_path / ".compile").is_dir()
        assert config.topic == "Rhizome"

    def test_creates_navigation_files(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Rhizome")
        assert (tmp_path / "wiki" / "index.md").exists()
        assert (tmp_path / "wiki" / "overview.md").exists()
        assert (tmp_path / "wiki" / "log.md").exists()

    def test_creates_wiki_schema(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Rhizome", "Test description")
        schema = (tmp_path / "WIKI.md").read_text()
        assert "Rhizome" in schema
        assert "Test description" in schema
        assert "Broad topic hubs to maintain" in schema
        assert "Recurring subtopics to group under those hubs" in schema

    def test_creates_obsidian_config(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Rhizome")
        assert (tmp_path / ".obsidian").is_dir()
        assert (tmp_path / ".obsidian" / "app.json").exists()
        assert (tmp_path / ".obsidian" / "graph.json").exists()
        assert (tmp_path / ".obsidian" / "snippets" / "compile.css").exists()

    def test_raises_on_existing_workspace(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "First")
        with pytest.raises(FileExistsError):
            init_workspace(tmp_path, "Second")

    def test_initial_state(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Rhizome")
        state = load_state(config)
        assert state["processed"] == {}
        assert "created_at" in state

    def test_log_contains_init_entry(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Rhizome")
        log = (tmp_path / "wiki" / "log.md").read_text()
        assert "init | Rhizome" in log
        assert "Workspace initialized" in log


class TestState:
    def test_mark_processed(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "source.md"
        raw_file.write_text("Content")

        mark_processed(config, raw_file, ["wiki/sources/Source.md"])

        state = load_state(config)
        assert "raw/source.md" in state["processed"]
        entry = state["processed"]["raw/source.md"]
        assert entry["pages_touched"] == ["wiki/sources/Source.md"]
        assert "processed_at" in entry

    def test_get_unprocessed(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "a.md").write_text("A")
        (tmp_path / "raw" / "b.md").write_text("B")
        (tmp_path / "raw" / "c.xyz").write_text("C")  # unsupported

        unprocessed = get_unprocessed(config)
        names = [p.name for p in unprocessed]
        assert "a.md" in names
        assert "b.md" in names
        assert "c.xyz" not in names

    def test_processed_excluded_from_unprocessed(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        raw_file = tmp_path / "raw" / "done.md"
        raw_file.write_text("Done")
        mark_processed(config, raw_file, ["wiki/sources/Done.md"])

        unprocessed = get_unprocessed(config)
        assert all(p.name != "done.md" for p in unprocessed)

    def test_generated_assets_excluded_from_unprocessed(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "paper.md").write_text("Paper")
        asset = tmp_path / "raw" / "assets" / "paper" / "page-001-image-01.png"
        asset.parent.mkdir(parents=True)
        asset.write_bytes(b"png")

        unprocessed = get_unprocessed(config)

        assert [p.name for p in unprocessed] == ["paper.md"]


class TestGetStatus:
    def test_empty_workspace(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test", "Description")
        status = get_status(config)
        assert status["topic"] == "Test"
        assert status["description"] == "Description"
        assert status["raw_files"] == 0
        assert status["processed"] == 0
        assert status["unprocessed"] == 0
        assert status["wiki_pages"] >= 3  # index, overview, log

    def test_with_raw_files(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "a.md").write_text("A")
        (tmp_path / "raw" / "b.txt").write_text("B")

        status = get_status(config)
        assert status["raw_files"] == 2
        assert status["unprocessed"] == 2

    def test_counts_needs_document_review(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "wiki" / "sources" / "paper.md").write_text(
            "---\n"
            "title: Paper\n"
            "type: source\n"
            "status: stable\n"
            "summary: Extracted PDF note.\n"
            "review_status: needs_document_review\n"
            "---\n\n"
            "# Paper\n\n"
            "Review me.\n"
        )

        status = get_status(config)

        assert status["needs_document_review"] == 1

    def test_scan_failures_surface_instead_of_looking_clean(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        config = init_workspace(tmp_path, "Test")

        def boom(self):
            raise RuntimeError("scan failed")

        monkeypatch.setattr("compile.obsidian.ObsidianConnector.scan", boom)

        with pytest.raises(RuntimeError, match="scan failed"):
            get_status(config)

    def test_generated_assets_excluded_from_status(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "paper.md").write_text("A")
        asset = tmp_path / "raw" / "assets" / "paper" / "page-001-image-01.png"
        asset.parent.mkdir(parents=True)
        asset.write_bytes(b"png")

        status = get_status(config)

        assert status["raw_files"] == 1
        assert status["unprocessed"] == 1

    def test_processed_count_ignores_stale_generated_asset_entries(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "paper.md").write_text("A")
        asset = tmp_path / "raw" / "assets" / "paper" / "page-001-image-01.png"
        asset.parent.mkdir(parents=True)
        asset.write_bytes(b"png")
        config.state_path.write_text(json.dumps({
            "processed": {
                "raw/paper.md": {"processed_at": "x", "pages_touched": [], "size": 1},
                "raw/assets/paper/page-001-image-01.png": {"processed_at": "x", "pages_touched": [], "size": 3},
            },
            "created_at": "x",
        }))

        status = get_status(config)

        assert status["raw_files"] == 1
        assert status["processed"] == 1
        assert status["unprocessed"] == 0


class TestCollectPagesByType:
    def test_categorizes_pages(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        _write_page(tmp_path / "wiki" / "articles" / "a.md", "Article A", "article", "Body.")
        _write_page(tmp_path / "wiki" / "sources" / "s.md", "Source S", "source", "Body.")
        _write_page(tmp_path / "wiki" / "maps" / "m.md", "Map M", "map", "Body.")
        _write_page(tmp_path / "wiki" / "outputs" / "o.md", "Output O", "output", "Body.")

        pages = collect_pages_by_type(config)
        assert len(pages["articles"]) == 1
        assert len(pages["sources"]) == 1
        assert len(pages["maps"]) == 1
        assert len(pages["outputs"]) == 1

    def test_excludes_nav_pages(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        pages = collect_pages_by_type(config)
        all_titles = [
            e["title"]
            for bucket in pages.values()
            for e in bucket
        ]
        assert "Index" not in all_titles
        assert "Log" not in all_titles

    def test_legacy_page_types(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        _write_page(tmp_path / "wiki" / "articles" / "c.md", "Concept C", "concept", "Body.")

        pages = collect_pages_by_type(config)
        assert any(e["title"] == "Concept C" for e in pages["articles"])

    def test_extracts_summary_from_body(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        _write_page(tmp_path / "wiki" / "articles" / "a.md", "Article A", "article", "First real line of body text.")

        pages = collect_pages_by_type(config)
        entry = pages["articles"][0]
        assert "First real line" in entry["summary"]

    def test_uses_frontmatter_summary(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "a.md",
            "Article A", "article", "Body.", summary="Frontmatter summary.",
        )

        pages = collect_pages_by_type(config)
        entry = pages["articles"][0]
        assert entry["summary"] == "Frontmatter summary."


class TestWriteIndex:
    def test_writes_index_with_entries(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        _write_page(tmp_path / "wiki" / "articles" / "a.md", "Alpha", "article", "Body.", summary="Alpha summary.")
        pages = collect_pages_by_type(config)
        write_index(config, pages)

        index = (tmp_path / "wiki" / "index.md").read_text()
        assert "[[Alpha]]" in index
        assert "Alpha summary." in index
        assert "bootstrap" not in index

    def test_empty_index_has_bootstrap_flag(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        pages = collect_pages_by_type(config)
        write_index(config, pages)

        index = (tmp_path / "wiki" / "index.md").read_text()
        assert "bootstrap: true" in index

    def test_preserves_created_date(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        index_text = (tmp_path / "wiki" / "index.md").read_text()

        # Write again — created date should stay the same
        pages = collect_pages_by_type(config)
        write_index(config, pages)

        updated = (tmp_path / "wiki" / "index.md").read_text()
        # Both should contain the same created timestamp
        assert "created:" in updated


class TestWriteOverview:
    def test_empty_workspace(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test", "A test description.")
        pages = collect_pages_by_type(config)
        write_overview(config, pages)

        overview = (tmp_path / "wiki" / "overview.md").read_text()
        assert "A test description" in overview
        assert "just initialized" in overview
        assert "bootstrap: true" in overview

    def test_with_articles(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        _write_page(tmp_path / "wiki" / "articles" / "a.md", "Alpha", "article", "Body.")
        pages = collect_pages_by_type(config)
        write_overview(config, pages)

        overview = (tmp_path / "wiki" / "overview.md").read_text()
        assert "[[Alpha]]" in overview
        assert "Articles: 1" in overview
        assert "bootstrap" not in overview


class TestAppendLogEntry:
    def test_appends_to_existing_log(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        append_log_entry(config, "ingest", "Source A", ["Created source page", "Updated index"])

        log = (tmp_path / "wiki" / "log.md").read_text()
        assert "ingest | Source A" in log
        assert "Created source page" in log
        assert "Updated index" in log

    def test_creates_log_if_missing(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "wiki" / "log.md").unlink()

        append_log_entry(config, "query", "Test Query")

        log = (tmp_path / "wiki" / "log.md").read_text()
        assert "query | Test Query" in log

    def test_multiple_entries(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        append_log_entry(config, "ingest", "First")
        append_log_entry(config, "ingest", "Second")

        log = (tmp_path / "wiki" / "log.md").read_text()
        assert "ingest | First" in log
        assert "ingest | Second" in log


class TestReadWikiPage:
    def test_reads_existing_page(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        content = read_wiki_page(config, "index.md")
        assert content is not None
        assert "Index" in content

    def test_returns_none_for_missing(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        assert read_wiki_page(config, "nonexistent.md") is None


class TestListWikiPages:
    def test_lists_pages(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        pages = list_wiki_pages(config)
        assert "index.md" in pages
        assert "overview.md" in pages
        assert "log.md" in pages


class TestReadSchema:
    def test_reads_schema(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        schema = read_schema(config)
        assert "Workspace Schema" in schema

    def test_returns_empty_when_missing(self, tmp_path: Path) -> None:
        config = Config(topic="Test", workspace_root=tmp_path)
        assert read_schema(config) == ""


class TestEnsureWorkspaceSchema:
    def test_creates_if_missing(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        (tmp_path / "WIKI.md").unlink()

        created = ensure_workspace_schema(config)
        assert created is True
        assert (tmp_path / "WIKI.md").exists()

    def test_does_not_overwrite(self, tmp_path: Path) -> None:
        config = init_workspace(tmp_path, "Test")
        created = ensure_workspace_schema(config)
        assert created is False
