from __future__ import annotations

from dataclasses import dataclass

from compile.obsidian import ObsidianConnector
from compile.text import ExtractedSource, normalize_text

DEFAULT_SOURCE_SYNOPSIS = "Minimal source content; no substantive summary available."


@dataclass(frozen=True)
class IngestArtifact:
    title: str
    page_summary: str
    synopsis: str
    key_sections: list[str]
    raw_relative: str
    metadata_only: bool
    extraction_method: str | None
    needs_document_review: bool
    full_text: str = ""


def build_ingest_artifact(
    *,
    raw_relative: str,
    extracted: ExtractedSource,
    connector: ObsidianConnector,
    title: str | None = None,
) -> IngestArtifact:
    effective_title = title or extracted.title
    synopsis = _build_synopsis(extracted)
    full_text = ""
    if not extracted.metadata_only:
        candidate = extracted.full_text or extracted.normalized_text
        if candidate.strip():
            full_text = candidate
    return IngestArtifact(
        title=effective_title,
        page_summary=_frontmatter_summary(synopsis),
        synopsis=synopsis,
        key_sections=list(extracted.headings[:6]) if not extracted.metadata_only else [],
        raw_relative=raw_relative,
        metadata_only=extracted.metadata_only,
        extraction_method=extracted.extraction_method,
        needs_document_review=extracted.requires_document_review,
        full_text=full_text,
    )


def render_source_body(artifact: IngestArtifact) -> str:
    lines = [
        "## Synopsis",
        "",
        artifact.synopsis,
    ]

    if artifact.needs_document_review:
        method = artifact.extraction_method or "local_text_extraction"
        lines.extend([
            "",
            "## Review Status",
            "",
            f"This source note was built from local PDF text extraction (`{method}`). "
            "It still needs document-level review for layout, tables, figures, captions, and reading order.",
        ])

    if artifact.key_sections:
        lines.extend([
            "",
            "## Key Sections",
            "",
            *[f"- {section}" for section in artifact.key_sections],
        ])

    if artifact.metadata_only:
        lines.extend([
            "",
            "## Note",
            "",
            "This is a registration shell. The source content could not be extracted automatically. "
            "Read the raw file directly and replace this note with a proper synopsis, key claims, and limitations.",
        ])

    lines.extend([
        "",
        "## Provenance",
        "",
        f"- Source file: ![[{artifact.raw_relative}]]",
    ])
    if artifact.full_text:
        lines.extend([
            "",
            render_full_text_callout(artifact.full_text),
        ])
    return "\n".join(lines)


def render_full_text_callout(full_text: str) -> str:
    prefixed = "\n".join(
        f"> {line}" if line else ">"
        for line in full_text.splitlines()
    )
    return f"> [!abstract]- Full extracted text\n{prefixed}"


def _build_synopsis(extracted: ExtractedSource) -> str:
    if extracted.metadata_only:
        return _truncate_sentence(extracted.normalized_text, 600) or DEFAULT_SOURCE_SYNOPSIS

    candidates = [
        paragraph
        for paragraph in extracted.paragraphs
        if _is_substantive_paragraph(paragraph)
    ] or extracted.paragraphs
    if not candidates:
        return DEFAULT_SOURCE_SYNOPSIS

    selected: list[str] = []
    total_length = 0
    for paragraph in candidates:
        if len(selected) >= 2:
            break
        paragraph_length = len(paragraph)
        separator = 2 if selected else 0
        if selected and total_length + separator + paragraph_length > 600:
            break
        selected.append(paragraph)
        total_length += separator + paragraph_length

    synopsis = "\n\n".join(selected or candidates[:1])
    return _truncate_sentence(synopsis, 600) or DEFAULT_SOURCE_SYNOPSIS


def _frontmatter_summary(synopsis: str) -> str:
    return _truncate_sentence(normalize_text(synopsis), 220) or DEFAULT_SOURCE_SYNOPSIS


def _is_substantive_paragraph(paragraph: str) -> bool:
    stripped = paragraph.strip()
    if len(stripped) < 40:
        return False
    if stripped.lower().startswith(("source file:", "fetched:", "source_url:")):
        return False
    return True


def _truncate_sentence(text: str, limit: int) -> str:
    cleaned = text.strip()
    if len(cleaned) <= limit:
        return cleaned

    window = cleaned[:limit]
    boundary = max(window.rfind("."), window.rfind("!"), window.rfind("?"))
    if boundary >= int(limit * 0.6):
        return window[: boundary + 1].strip()
    return window.rstrip() + "..."
