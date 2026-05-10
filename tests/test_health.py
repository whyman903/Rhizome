from __future__ import annotations

import json
from pathlib import Path

from compile.health import build_health_report, write_health_snapshot
from compile.workspace import (
    collect_pages_by_type,
    init_workspace,
    write_index,
    write_overview,
)


def _write_page(path: Path, title: str, page_type: str, body: str, **extra_fm: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fm_lines = [f"title: {title}", f"type: {page_type}"]
    for k, v in extra_fm.items():
        fm_lines.append(f"{k}: {v}")
    fm = "\n".join(fm_lines)
    path.write_text(f"---\n{fm}\n---\n\n# {title}\n\n{body}\n")


def _refresh_nav(tmp_path: Path) -> None:
    from compile.config import load_config
    config = load_config(tmp_path)
    pages = collect_pages_by_type(config)
    write_index(config, pages)
    write_overview(config, pages)


class TestBuildHealthReport:
    def test_healthy_workspace(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "topic.md",
            "Topic",
            "article",
            "A meaningful article with enough content to not be thin.\n\n"
            "Second paragraph with substantial text linking to [[Index]].",
            status="seed",
            summary='"A good summary."',
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)
        assert report["overall_status"] in ("healthy", "needs_attention")
        assert "summary" in report
        assert report["metrics"]["pages"] >= 4

    def test_empty_workspace_is_healthy(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        report = build_health_report(tmp_path)
        # Empty but valid workspace
        assert report["layout"] == "compile_workspace"

    def test_backend_workspace_not_obsidian_ready(self, tmp_path: Path) -> None:
        pages_dir = tmp_path / "pages"
        pages_dir.mkdir()
        (tmp_path / "workspace.json").write_text('{"id": "test-backend"}')
        _write_page(pages_dir / "concept.md", "Concept", "concept", "Body.")

        report = build_health_report(tmp_path)
        assert report["overall_status"] == "not_obsidian_ready"
        assert report["workspace_id"] == "test-backend"

    def test_report_structure(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        report = build_health_report(tmp_path)

        assert "id" in report
        assert "generated_at" in report
        assert "root" in report
        assert "obsidian_readiness" in report
        assert "graph_health" in report
        assert "content_health" in report
        assert "metrics" in report
        assert "issues" in report

        for section in ("obsidian_readiness", "graph_health", "content_health"):
            assert "status" in report[section]
            assert "counts" in report[section]

        assert "knowledge_page_count" in report["metrics"]
        assert "source_to_knowledge_page_ratio" in report["metrics"]

    def test_editorial_metrics(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "topic.md",
            "Topic",
            "article",
            "Article body linking to [[Source A]] and [[Source B]].",
            status="emerging",
            summary='"An article."',
        )
        for index in range(4):
            _write_page(
                tmp_path / "wiki" / "sources" / f"source-{index}.md",
                f"Source {index}",
                "source",
                "Source body linking to [[Topic]].",
                status="stable",
                summary='"A source note."',
            )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["metrics"]["knowledge_page_count"] == 1
        assert report["metrics"]["source_to_knowledge_page_ratio"] == 4.0

    def test_editorial_metrics_counts_all_synthesis_page_types(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "topic.md",
            "Topic", "article", "Article body.", status="seed", summary='"Article."',
        )
        _write_page(
            tmp_path / "wiki" / "articles" / "thing.md",
            "Thing", "concept", "Concept body.", status="seed", summary='"Concept."',
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["metrics"]["knowledge_page_count"] == 2

    def test_editorial_metrics_with_zero_knowledge_pages(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "sources" / "source.md",
            "Source",
            "source",
            "Lone source.",
            status="seed",
            summary='"Lone source."',
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["metrics"]["knowledge_page_count"] == 0
        assert report["metrics"]["source_to_knowledge_page_ratio"] == 1.0

    def test_content_issues_passed_through(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        custom_issues = [
            {"type": "custom_check", "severity": "medium", "title": "Custom issue found."}
        ]
        report = build_health_report(tmp_path, content_issues=custom_issues)
        assert any(i.get("code") == "custom_check" for i in report["issues"])

    def test_report_is_json_serializable(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        report = build_health_report(tmp_path)
        # Should not raise
        json.dumps(report)

    def test_raw_files_without_source_notes(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "orphan.md").write_text("Orphan source.")
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)
        assert report["metrics"]["raw_files_without_source_notes"] >= 1

    def test_needs_document_review_surfaces_in_content_health(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        (tmp_path / "raw" / "paper.pdf").write_bytes(b"%PDF-1.4 fake")
        _write_page(
            tmp_path / "wiki" / "sources" / "paper.md",
            "Paper",
            "source",
            "See [[raw/paper.pdf]] for provenance.",
            status="stable",
            summary='"Extracted source note."',
            review_status="needs_document_review",
            extraction_method="pymupdf_text",
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["metrics"]["needs_document_review"] == 1
        assert report["content_health"]["status"] == "warn"
        assert any(issue["code"] == "needs_document_review" for issue in report["issues"])

    def test_source_without_topic_anchor_surfaces_in_health(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "sources" / "paper.md",
            "Paper",
            "source",
            "Source summary.\n\nAnother paragraph.",
            status="seed",
            summary='"Unanchored source note."',
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["metrics"]["source_notes_without_topic_anchors"] == 1
        assert any(issue["code"] == "source_without_topic_anchor" for issue in report["issues"])

    def test_many_unanchored_sources_raise_topic_hub_gap_issue(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        for index in range(5):
            _write_page(
                tmp_path / "wiki" / "sources" / f"source-{index}.md",
                f"Source {index}",
                "source",
                "Unanchored source summary.\n\nAnother paragraph.",
                status="seed",
                summary='"Unanchored source note."',
            )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["content_health"]["status"] == "warn"
        assert any(issue["code"] == "topic_hub_coverage_gap" for issue in report["issues"])

    def test_stable_thin_source_surfaces_in_health(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "sources" / "stub.md",
            "Stub",
            "source",
            "A short source note.",
            status="stable",
            summary='"Short source."',
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert any(issue["code"] == "stable_thin_source" for issue in report["issues"])

    def test_duplicate_source_provenance_surfaces_in_health(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        for name in ("one", "two"):
            _write_page(
                tmp_path / "wiki" / "sources" / f"{name}.md",
                name.title(),
                "source",
                "A source summary with enough words to avoid being only a bare title.\n\n"
                "Another paragraph gives the note some body.",
                status="seed",
                summary='"Source note."',
                notion_page_id="same-page-id",
            )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert any(issue["code"] == "duplicate_source_provenance" for issue in report["issues"])

    def test_archived_pages_are_excluded_from_editorial_metrics(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        _write_page(
            tmp_path / "wiki" / "articles" / "old.md",
            "Old",
            "article",
            "Archived article body.",
            status="stable",
            summary='"Archived."',
            archived="true",
        )
        _refresh_nav(tmp_path)

        report = build_health_report(tmp_path)

        assert report["metrics"]["knowledge_page_count"] == 0
        assert report["metrics"]["archived_pages"] == 1


class TestWriteHealthSnapshot:
    def test_writes_file(self, tmp_path: Path) -> None:
        init_workspace(tmp_path, "Test")
        report = build_health_report(tmp_path)
        path = write_health_snapshot(tmp_path, report)

        assert path.exists()
        loaded = json.loads(path.read_text())
        assert loaded["layout"] == "compile_workspace"

    def test_creates_directory(self, tmp_path: Path) -> None:
        report = {"test": True}
        path = write_health_snapshot(tmp_path, report)
        assert path.parent.is_dir()
        assert path.exists()
