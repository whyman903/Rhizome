from __future__ import annotations

from hashlib import sha1
import json
from pathlib import Path
from typing import Any

from compile.dates import now_machine
from compile.obsidian import ObsidianConnector, READINESS_ISSUE_CODES, VaultIssue
from compile.page_types import ARTICLE_PAGE_TYPES
from compile.verify import audit_vault_content


def _severity_counts(issues: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"high": 0, "medium": 0, "low": 0}
    for issue in issues:
        severity = str(issue.get("severity") or "low")
        if severity not in counts:
            severity = "low"
        counts[severity] += 1
    return counts


def _status_from_counts(counts: dict[str, int], *, empty_status: str = "pass") -> str:
    if counts["high"] > 0:
        return "fail"
    if counts["medium"] > 0 or counts["low"] > 0:
        return "warn"
    return empty_status


def _split_structural_issues(issues: list[VaultIssue]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    readiness: list[dict[str, Any]] = []
    graph: list[dict[str, Any]] = []
    for issue in issues:
        payload = issue.to_dict()
        payload["category"] = "obsidian_readiness" if issue.code in READINESS_ISSUE_CODES else "graph_health"
        if issue.code in READINESS_ISSUE_CODES:
            readiness.append(payload)
        else:
            graph.append(payload)
    return readiness, graph


def _workspace_id(root: Path) -> str:
    workspace_json = root / "workspace.json"
    if workspace_json.exists():
        try:
            payload = json.loads(workspace_json.read_text())
            for key in ("id", "slug", "name"):
                value = str(payload.get(key) or "").strip()
                if value:
                    return value
        except json.JSONDecodeError:
            pass
    return root.name


def _summary_for_status(
    *,
    layout: str,
    readiness_status: str,
    readiness_counts: dict[str, int],
    graph_status: str,
    graph_counts: dict[str, int],
    content_status: str,
    content_counts: dict[str, int],
) -> str:
    if readiness_status == "fail":
        return (
            "Workspace content exists, but Obsidian readiness is incomplete "
            f"({readiness_counts['high']} high-severity issue(s), "
            f"{sum(readiness_counts.values())} total)."
        )
    if graph_status == "fail":
        return (
            "Workspace is not structurally healthy yet "
            f"({graph_counts['high']} high-severity graph issue(s))."
        )
    if content_status == "fail":
        return (
            "Workspace is structurally ready, but the content audit found "
            f"{content_counts['high']} high-severity issue(s)."
        )
    if readiness_status == "warn" or graph_status == "warn" or content_status == "warn":
        parts: list[str] = []
        if readiness_status == "warn":
            parts.append(f"{sum(readiness_counts.values())} readiness issue(s)")
        if graph_status == "warn":
            parts.append(f"{sum(graph_counts.values())} graph issue(s)")
        if content_status == "warn":
            parts.append(f"{sum(content_counts.values())} content issue(s)")
        return f"Workspace needs attention: {', '.join(parts)}."
    if content_status == "not_run":
        if layout == "compile_workspace":
            return "Workspace is structurally healthy and Obsidian-ready. Content audit not run."
        return "Workspace export is structurally clean, but content audit was not run."
    return "Workspace is healthy and Obsidian-ready."


def build_health_report(
    root: Path,
    *,
    content_issues: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    resolved_root = root.resolve()
    connector = ObsidianConnector(root.resolve())
    vault = connector.inspect()
    active_pages = [
        page
        for page in vault.pages
        if not _frontmatter_truthy(page.frontmatter.get("archived"))
    ]
    unanchored_source_notes = [
        page
        for page in connector.source_pages_without_topic_anchors()
        if not _frontmatter_truthy(page.frontmatter.get("archived"))
    ]
    readiness_issues, graph_issues = _split_structural_issues(vault.issues)
    if content_issues is None:
        content_issues = audit_vault_content(resolved_root)
    readiness_counts = _severity_counts(readiness_issues)
    graph_counts = _severity_counts(graph_issues)
    content_counts = _severity_counts(content_issues)

    readiness_status = _status_from_counts(readiness_counts)
    graph_status = _status_from_counts(graph_counts)
    content_status = _status_from_counts(content_counts)

    generated_at = now_machine()
    workspace_id = _workspace_id(root)
    overall_status = (
        "not_obsidian_ready"
        if readiness_status == "fail"
        else "needs_attention"
        if readiness_status == "warn" or graph_status != "pass" or content_status in {"fail", "warn"}
        else "healthy"
    )
    summary = _summary_for_status(
        layout=vault.layout,
        readiness_status=readiness_status,
        readiness_counts=readiness_counts,
        graph_status=graph_status,
        graph_counts=graph_counts,
        content_status=content_status,
        content_counts=content_counts,
    )

    source_count = sum(1 for page in active_pages if page.page_type == "source")
    knowledge_page_count = sum(1 for page in active_pages if page.page_type in ARTICLE_PAGE_TYPES)

    issues = [*readiness_issues, *graph_issues]
    issues.extend(
        {
            "category": "content_health",
            "code": str(issue.get("type") or "content_issue"),
            "severity": str(issue.get("severity") or "low"),
            "message": str(issue.get("title") or issue.get("suggestion") or "Content issue"),
            "details": {
                "title": str(issue.get("title") or ""),
                "suggestion": str(issue.get("suggestion") or ""),
            },
        }
        for issue in content_issues
    )

    return {
        "id": f"health_{sha1(f'{workspace_id}:{generated_at}'.encode('utf-8')).hexdigest()[:10]}",
        "workspace_id": workspace_id,
        "generated_at": generated_at,
        "root": str(root.resolve()),
        "layout": vault.layout,
        "overall_status": overall_status,
        "summary": summary,
        "obsidian_readiness": {
            "status": readiness_status,
            "counts": readiness_counts,
            "issues": readiness_issues,
        },
        "graph_health": {
            "status": graph_status,
            "counts": graph_counts,
            "issues": graph_issues,
        },
        "content_health": {
            "status": content_status,
            "counts": content_counts,
            "issues": content_issues,
        },
        "metrics": {
            "pages": vault.total_pages,
            "pages_with_wikilinks": vault.pages_with_wikilinks,
            "unresolved_links": vault.unresolved_link_count,
            "orphan_pages": vault.orphan_page_count,
            "thin_pages": len(vault.thin_pages),
            "raw_files_without_source_notes": len(vault.raw_files_without_source_notes),
            "source_pages_without_raw_links": len(vault.source_pages_without_raw_links),
            "source_notes_without_topic_anchors": len(unanchored_source_notes),
            "needs_document_review": sum(
                1
                for page in active_pages
                if page.page_type == "source"
                and str(page.frontmatter.get("review_status") or "").strip() == "needs_document_review"
            ),
            "knowledge_page_count": knowledge_page_count,
            "source_to_knowledge_page_ratio": round(source_count / max(knowledge_page_count, 1), 1),
            "archived_pages": len(vault.pages) - len(active_pages),
        },
        "issues": issues,
    }


def write_health_snapshot(root: Path, report: dict[str, Any]) -> Path:
    path = root.resolve() / "health" / "latest.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=False))
    return path


def _frontmatter_truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {"true", "yes", "1"}
