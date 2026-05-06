from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Any, Iterable

from compile.markdown import WIKILINK_RE, count_content_paragraphs, parse_markdown_text, strip_code_regions
from compile.page_types import ARTICLE_PAGE_TYPES


PLACEHOLDER_PATTERNS = (
    re.compile(r"_Saved outputs will appear here.*_", re.IGNORECASE),
    re.compile(r"No strong merge candidates are currently flagged\.", re.IGNORECASE),
    re.compile(r"_No .* yet\._", re.IGNORECASE),
)
MALFORMED_SUMMARY_RE = re.compile(r"\b[A-Za-z0-9][^\n]*\s{2,}[A-Za-z0-9]")


@dataclass
class VerificationIssue:
    severity: str
    code: str
    message: str


def verify_page_content(
    *,
    page_type: str,
    content: str,
    raw_source_path: str = "",
    valid_link_targets: Iterable[str] = (),
) -> list[VerificationIssue]:
    issues: list[VerificationIssue] = []
    frontmatter, body, _ = parse_markdown_text(content)

    for required in ("title", "type", "status", "summary", "created", "updated"):
        if required not in frontmatter:
            issues.append(
                VerificationIssue("medium", "missing_frontmatter", f"Missing required frontmatter field: {required}")
            )

    if page_type == "source" and raw_source_path and raw_source_path not in content:
        issues.append(
            VerificationIssue("high", "missing_provenance", "Source page does not link or embed the raw artifact.")
        )

    valid_targets = {target.casefold() for target in valid_link_targets}
    for match in WIKILINK_RE.finditer(strip_code_regions(content)):
        link_target = match.group(1).strip()
        if not link_target or link_target.startswith("raw/"):
            continue
        if valid_targets and link_target.casefold() not in valid_targets:
            issues.append(
                VerificationIssue("medium", "unresolved_wikilink", f"Page links to unresolved target [[{link_target}]].")
            )

    para_count = count_content_paragraphs(strip_code_regions(body))
    if para_count < 2:
        issues.append(
            VerificationIssue("low", "thin_content", f"Page has only {para_count} content paragraph(s).")
        )

    return issues



def audit_vault_content(root: Path) -> list[dict[str, Any]]:
    from compile.obsidian import ObsidianConnector

    connector = ObsidianConnector(root.resolve())
    pages = connector.scan()
    issues: list[dict[str, Any]] = []
    source_pages = [page for page in pages if page.page_type == "source"]
    unanchored_source_pages = connector.source_pages_without_topic_anchors()
    unanchored_source_paths = {page.relative_path for page in unanchored_source_pages}

    def supporting_count(page: Any) -> int:
        return len(connector.supporting_source_titles(page))

    knowledge_pages = [page for page in pages if page.page_type in ARTICLE_PAGE_TYPES]
    single_source_pages = [
        page for page in knowledge_pages
        if supporting_count(page) <= 1
    ]
    if len(knowledge_pages) >= 5 and len(single_source_pages) / len(knowledge_pages) >= 0.6:
        issues.append(
            {
                "type": "provisional_knowledge_base",
                "severity": "medium",
                "title": "Most knowledge pages are still backed by one source.",
                "suggestion": (
                    "Promote fewer pages, merge weak fragments, and add cross-source synthesis before "
                    "treating the vault as editorially healthy."
                ),
            }
        )

    if source_pages and len(source_pages) >= 5 and len(unanchored_source_pages) / len(source_pages) >= 0.4:
        issues.append(
            {
                "type": "topic_hub_coverage_gap",
                "severity": "medium",
                "title": "Many source notes are still disconnected from article and map pages.",
                "suggestion": (
                    "Link source notes to existing article or map pages where appropriate, "
                    "or create lightweight map pages for broad topics that still have no hub."
                ),
            }
        )

    for page in pages:
        issues.extend(
            _audit_page(
                page,
                unanchored_source_paths=unanchored_source_paths,
                source_count=supporting_count(page),
            )
        )

    return issues


def _audit_page(
    page: Any,
    *,
    unanchored_source_paths: set[str],
    source_count: int,
) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    summary = str(page.frontmatter.get("summary") or "").strip()
    status = str(page.frontmatter.get("status") or "").strip().lower()
    review_status = str(page.frontmatter.get("review_status") or "").strip().lower()

    if summary and MALFORMED_SUMMARY_RE.search(summary):
        issues.append(
            {
                "type": "malformed_summary",
                "severity": "medium",
                "title": f"{page.title}: summary appears malformed or truncated.",
                "suggestion": "Rewrite the summary so it reads cleanly and can safely propagate into index and overview pages.",
            }
        )

    if page.page_type not in {"overview", "index"}:
        for pattern in PLACEHOLDER_PATTERNS:
            if pattern.search(page.body):
                issues.append(
                    {
                        "type": "placeholder_content",
                        "severity": "low",
                        "title": f"{page.title}: placeholder text is still visible.",
                        "suggestion": "Replace the placeholder with real content or remove the section until it has meaningful material.",
                    }
                )
                break

    if page.page_type not in {"index", "log"} and _has_empty_section(page.body):
        issues.append(
            {
                "type": "empty_section",
                "severity": "medium",
                "title": f"{page.title}: contains an empty section heading.",
                "suggestion": "Remove empty sections or populate them with real content before considering the page complete.",
            }
        )

    if page.page_type in ARTICLE_PAGE_TYPES and status == "stable" and source_count <= 1:
        issues.append(
            {
                "type": "premature_stability",
                "severity": "medium",
                "title": f"{page.title}: marked stable despite thin evidence.",
                "suggestion": "Keep the page provisional or add more supporting sources and explicit synthesis.",
            }
        )

    if page.page_type == "source" and review_status == "needs_document_review":
        issues.append(
            {
                "type": "needs_document_review",
                "severity": "low",
                "title": f"{page.title}: source note still needs document review.",
                "suggestion": (
                    "Review the raw PDF for layout, tables, figures, captions, and reading order, "
                    "then run `compile review mark-reviewed <locator>`."
                ),
            }
        )

    if page.page_type == "source" and page.relative_path in unanchored_source_paths:
        issues.append(
            {
                "type": "source_without_topic_anchor",
                "severity": "low",
                "title": f"{page.title}: source note is not connected to any article or map page.",
                "suggestion": (
                    "Add a meaningful wikilink to an existing article or map page, or create a lightweight "
                    "map page if this source belongs to a broad topic with no current hub."
                ),
            }
        )

    return issues


def _has_empty_section(body: str) -> bool:
    lines = body.splitlines()
    section_start: int | None = None

    def has_payload(start: int, end: int) -> bool:
        for line in lines[start:end]:
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("<!--") and stripped.endswith("-->"):
                continue
            return True
        return False

    for idx, line in enumerate(lines):
        if line.startswith("## "):
            if section_start is not None and not has_payload(section_start + 1, idx):
                return True
            section_start = idx

    if section_start is not None and not has_payload(section_start + 1, len(lines)):
        return True

    return False
