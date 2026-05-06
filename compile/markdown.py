from __future__ import annotations

from pathlib import Path
import re
from typing import Any

import yaml


WIKILINK_RE = re.compile(r"\[\[([^\]|#]+?)(?:\|[^\]]*?)?\]\]")
WORD_RE = re.compile(r"\b[\w'-]+\b")
LINE_RE = re.compile(r"\r?\n")

_FENCE_LINE_RE = re.compile(r"^(?:\s*>\s*)*\s*(`{3,}|~{3,})")
# Match backtick runs of any length with a same-length closing run on the
# same line, so both `` `code` `` and `` `` `code with ` tick` `` are treated
# as inline code — per CommonMark, the closing run must match the opening run.
_INLINE_CODE_RE = re.compile(r"(`+)(?:(?!\1)[^\n])+\1")
_FULL_TEXT_CALLOUT_HEADER_RE = re.compile(
    r"^\s*>\s*\[!abstract\][-+]?\s*Full extracted text\s*$",
    re.IGNORECASE,
)
_CALLOUT_BODY_LINE_RE = re.compile(r"^\s*>")


def strip_code_regions(text: str) -> str:
    """Return ``text`` with opaque, non-authored regions blanked out.

    Blanks three kinds of region so downstream wikilink and verification
    passes do not treat imported or illustrative text as authored wiki
    semantics:

    - Fenced code blocks (triple-backtick or triple-tilde), including fences
      nested inside Obsidian callouts (lines prefixed with ``> ``).
    - Inline backtick code spans.
    - The body of the ``> [!abstract]- Full extracted text`` callout that
      :func:`compile.ingest.render_full_text_callout` emits. Its contents are
      a verbatim copy of the raw source file, so any ``[[links]]`` inside
      belong to the upstream author — not to the generated source note.
    """
    result: list[str] = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    in_full_text_callout = False
    for line in text.splitlines():
        if in_full_text_callout:
            if _CALLOUT_BODY_LINE_RE.match(line):
                result.append("")
                continue
            in_full_text_callout = False
            in_fence = False
            fence_char = ""
            fence_len = 0
        if _FULL_TEXT_CALLOUT_HEADER_RE.match(line):
            in_full_text_callout = True
            result.append("")
            continue
        match = _FENCE_LINE_RE.match(line)
        if match:
            marker = match.group(1)
            if not in_fence:
                in_fence = True
                fence_char = marker[0]
                fence_len = len(marker)
                result.append("")
                continue
            # CommonMark: closing fence must be the same character and at
            # least as long as the opening fence, otherwise it's ignored
            # and we stay inside the code block.
            if marker[0] == fence_char and len(marker) >= fence_len:
                in_fence = False
                fence_char = ""
                fence_len = 0
                result.append("")
                continue
        if in_fence:
            result.append("")
            continue
        result.append(_INLINE_CODE_RE.sub("", line))
    return "\n".join(result)


def parse_markdown_text(text: str) -> tuple[dict[str, Any], str, bool]:
    if not text.startswith("---\n"):
        return {}, text.strip(), False

    marker = "\n---\n"
    if marker not in text[4:]:
        return {}, text.strip(), False

    frontmatter_text, body = text[4:].split(marker, 1)
    try:
        frontmatter = yaml.safe_load(frontmatter_text) or {}
    except yaml.YAMLError:
        return {}, text.strip(), False
    return frontmatter, body.strip(), True


def parse_markdown_file(path: Path) -> tuple[dict[str, Any], str, bool]:
    return parse_markdown_text(path.read_text(errors="ignore"))


def extract_wikilinks(body: str) -> list[str]:
    scannable = strip_code_regions(body)
    return [match.group(1).strip() for match in WIKILINK_RE.finditer(scannable) if match.group(1).strip()]


def count_content_paragraphs(body: str) -> int:
    count = 0
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped[0] in "#-*>|" or stripped.startswith("<!--") or stripped.startswith("$$"):
            continue
        if len(stripped) > 30:
            count += 1
    return count
