from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re

from bs4 import BeautifulSoup, NavigableString, Tag

from compile.markdown import parse_markdown_text


HTML_BLOCK_TAGS = frozenset({
    "address", "article", "aside", "blockquote", "dd", "details", "dialog",
    "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
    "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main",
    "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th",
    "thead", "tr", "ul",
})


SUPPORTED_EXTENSIONS = {
    ".pdf",
    ".md",
    ".markdown",
    ".txt",
    ".html",
    ".htm",
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".gif",
}

HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*$")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


@dataclass(frozen=True)
class ExtractedPageText:
    page_number: int
    text: str


@dataclass(frozen=True)
class ExtractedSource:
    title: str
    normalized_text: str
    paragraphs: tuple[str, ...]
    headings: tuple[str, ...]
    metadata_only: bool
    extraction_method: str | None = None
    requires_document_review: bool = False
    warnings: tuple[str, ...] = ()
    page_texts: tuple[ExtractedPageText, ...] = ()
    full_text: str = ""


def slugify(value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9]+", "-", value.lower()).strip("-")
    return normalized or "untitled"


UNSAFE_FILENAME_CHARS = re.compile(r'[<>:"/\\|?*#^\[\]]')


def sanitize_raw_filename(name: str) -> str:
    """Return a filename safe for raw/ and Obsidian.

    Strips characters forbidden by common filesystems (``<>:"/\\|?*``) and
    characters that break Obsidian wikilinks (``# ^ [ ]``). Collapses
    whitespace and hyphens, trims trailing dots, and preserves the
    original file extension.
    """
    path = Path(name)
    stem = UNSAFE_FILENAME_CHARS.sub("-", path.stem)
    stem = re.sub(r"\s+", "-", stem)
    stem = re.sub(r"-+", "-", stem).strip("-. ")
    return (stem or "untitled") + path.suffix


def normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _split_camel_case(value: str) -> str:
    """Insert spaces into camelCase or PascalCase runs."""
    value = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", value)
    value = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", value)
    return value


def _title_from_stem(stem: str) -> str:
    """Derive a human-readable title from a filename stem."""
    name = stem.replace("-", " ").replace("_", " ").strip()
    name = _split_camel_case(name)
    return normalize_text(name).title()


def title_from_path(path: Path) -> str:
    return _title_from_stem(path.stem)


def fix_pdf_artifacts(text: str) -> str:
    """Normalize common PDF extraction artifacts."""
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)
    text = text.replace("\ufb01", "fi")
    text = text.replace("\ufb02", "fl")
    text = text.replace("\ufb00", "ff")
    text = text.replace("\ufb03", "ffi")
    text = text.replace("\ufb04", "ffl")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def is_equation_heavy(text: str) -> bool:
    """Return True if the text contains more than 3 equation patterns."""
    display_eqs = len(re.findall(r"\$\$.+?\$\$", text, re.DOTALL))
    inline_eqs = len(re.findall(r"(?<!\$)\$(?!\$).+?(?<!\$)\$(?!\$)", text))
    return (display_eqs + inline_eqs) > 3


def extract_text(path: Path) -> tuple[str, str]:
    """Extract text from a file. Returns (title, text)."""
    extracted = extract_source(path)
    return extracted.title, extracted.normalized_text


def extract_source(path: Path) -> ExtractedSource:
    """Extract structured source details from a file."""
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        return _extract_pdf(path)
    if suffix in {".html", ".htm"}:
        return _extract_html(path)
    if suffix in {".md", ".markdown", ".txt"}:
        return _extract_markdown(path)
    if suffix in {".png", ".jpg", ".jpeg", ".webp", ".gif"}:
        return _extract_image_stub(path)
    raise ValueError(f"Unsupported file type: {suffix}")


def _extract_pdf(path: Path) -> ExtractedSource:
    title = title_from_path(path)
    try:
        import fitz
    except ModuleNotFoundError:
        return _pdf_placeholder(title)

    try:
        doc = fitz.open(path)
    except Exception:
        return _pdf_placeholder(title)

    page_texts: list[ExtractedPageText] = []
    try:
        for page_number, page in enumerate(doc, start=1):
            raw_text = fix_pdf_artifacts(page.get_text("text") or "").strip()
            if raw_text:
                page_texts.append(ExtractedPageText(page_number=page_number, text=raw_text))
    finally:
        doc.close()

    if not page_texts:
        return _pdf_placeholder(title)

    return source_from_pdf_pages(title, tuple(page_texts))


def _extract_html(path: Path) -> ExtractedSource:
    html = path.read_text(errors="ignore")
    soup = BeautifulSoup(html, "html.parser")
    title = normalize_text(soup.title.get_text(" ", strip=True) if soup.title else path.stem)
    article = soup.find("article")
    body_node = article or soup.body or soup
    for tag in body_node.find_all(["nav", "footer", "aside", "script", "style", "noscript"]):
        tag.decompose()

    headings = [
        text
        for text in (
            normalize_text(node.get_text(" ", strip=True))
            for node in body_node.find_all(re.compile("^h[1-6]$"))
        )
        if text
    ]
    paragraphs = [
        text
        for text in (
            normalize_text(node.get_text(" ", strip=True))
            for node in body_node.find_all(["p", "li", "blockquote"])
        )
        if text
    ]
    text = normalize_text(body_node.get_text(" ", strip=True))
    block_text = _html_block_text(body_node)
    return ExtractedSource(
        title=title[:120],
        normalized_text=text,
        paragraphs=tuple(paragraphs or _paragraphs_from_text(block_text)),
        headings=tuple(_dedupe_headings(headings, title[:120])),
        metadata_only=False,
        full_text=block_text,
    )


def _html_block_text(node: Tag) -> str:
    """Flatten an HTML subtree to text with block-level boundaries preserved.

    Inline siblings (e.g., ``<strong>`` inside a ``<p>``) are joined with a
    single space so a phrase like ``Hello <em>world</em>`` stays on one line.
    Block-level elements introduce paragraph breaks (``\\n\\n``). This avoids
    BeautifulSoup's ``get_text("\\n\\n")`` behaviour, which inserts the
    separator between *all* adjacent text nodes and shreds inline prose.
    """
    blocks: list[str] = []
    buffer: list[str] = []

    def flush() -> None:
        if not buffer:
            return
        joined = "".join(buffer)
        collapsed = re.sub(r"\s+", " ", joined).strip()
        if collapsed:
            blocks.append(collapsed)
        buffer.clear()

    def walk(element: object) -> None:
        if isinstance(element, NavigableString):
            buffer.append(str(element))
            return
        if not isinstance(element, Tag):
            return
        if element.name == "br":
            flush()
            return
        if element.name in HTML_BLOCK_TAGS:
            flush()
            for child in element.children:
                walk(child)
            flush()
            return
        for child in element.children:
            walk(child)

    walk(node)
    flush()
    return "\n\n".join(blocks)


def _extract_markdown(path: Path) -> ExtractedSource:
    text = path.read_text(errors="ignore")
    cleaned = _strip_comments(text)
    frontmatter, markdown_body = _strip_markdown_frontmatter(cleaned)
    body_without_code = _strip_fenced_code(markdown_body)
    title = _title_from_markdown(markdown_body, path, frontmatter)
    headings = _dedupe_headings(_extract_markdown_headings(body_without_code), title)
    paragraphs = _paragraphs_from_text(body_without_code, strip_headings=True)
    normalized = normalize_text(body_without_code)
    return ExtractedSource(
        title=title,
        normalized_text=normalized,
        paragraphs=tuple(paragraphs),
        headings=tuple(headings),
        metadata_only=False,
        full_text=markdown_body.strip(),
    )


def _extract_image_stub(path: Path) -> ExtractedSource:
    title = title_from_path(path)
    size = path.stat().st_size
    suffix = path.suffix.lower().lstrip(".")
    text = (
        "Image asset registered. "
        f"Format: {suffix}. "
        f"File size: {size} bytes. "
        "Visual analysis is not available in this pipeline yet, so this ingest is metadata-only. "
        "Use the resulting source page to anchor provenance and link the image into related wiki pages."
    )
    normalized = normalize_text(text)
    return ExtractedSource(
        title=title,
        normalized_text=normalized,
        paragraphs=(normalized,),
        headings=(),
        metadata_only=True,
    )


def _pdf_placeholder(title: str) -> ExtractedSource:
    text = (
        "PDF source registered. "
        "Content extraction is deferred to Claude's document understanding when available during analysis."
    )
    normalized = normalize_text(text)
    return ExtractedSource(
        title=title,
        normalized_text=normalized,
        paragraphs=(normalized,),
        headings=(),
        metadata_only=True,
    )


def source_from_pdf_pages(
    title: str,
    page_texts: tuple[ExtractedPageText, ...],
    *,
    warnings: tuple[str, ...] = (),
    requires_document_review: bool = True,
) -> ExtractedSource:
    cleaned = _strip_repeated_boilerplate(page_texts)
    full_text = _render_paged_full_text(cleaned)
    normalized = normalize_text(full_text)
    paragraphs = tuple(_paragraphs_from_text(full_text))
    return ExtractedSource(
        title=title,
        normalized_text=normalized,
        paragraphs=paragraphs or ((normalized,) if normalized else ()),
        headings=(),
        metadata_only=False,
        extraction_method="pymupdf_text",
        requires_document_review=requires_document_review,
        warnings=tuple(warnings),
        page_texts=cleaned,
        full_text=full_text,
    )


_BOILERPLATE_PAGE_FRACTION = 0.6
_BOILERPLATE_MIN_PAGES = 3


def _strip_repeated_boilerplate(
    page_texts: tuple[ExtractedPageText, ...],
) -> tuple[ExtractedPageText, ...]:
    """Drop lines that appear on a majority of pages.

    Slide decks and branded reports repeat a fixed header/footer on every
    page. Those lines are not content — they pad the extracted text and
    bloat the full-text callout. A line is treated as boilerplate when its
    stripped form appears on at least ``_BOILERPLATE_PAGE_FRACTION`` of the
    pages (minimum three pages). Idempotent: a second pass finds no lines
    over threshold because the first pass already removed them.
    """
    if len(page_texts) < _BOILERPLATE_MIN_PAGES:
        return page_texts

    from collections import Counter

    counter: Counter[str] = Counter()
    for page in page_texts:
        seen: set[str] = set()
        for line in page.text.splitlines():
            key = line.strip()
            if not key or key in seen:
                continue
            counter[key] += 1
            seen.add(key)

    threshold = max(2, int(round(len(page_texts) * _BOILERPLATE_PAGE_FRACTION)))
    boilerplate = {line for line, count in counter.items() if count >= threshold}
    if not boilerplate:
        return page_texts

    cleaned: list[ExtractedPageText] = []
    for page in page_texts:
        kept = [line for line in page.text.splitlines() if line.strip() not in boilerplate]
        stripped = "\n".join(kept).strip()
        if stripped:
            cleaned.append(ExtractedPageText(page_number=page.page_number, text=stripped))
    return tuple(cleaned) if cleaned else page_texts


def _render_paged_full_text(page_texts: tuple[ExtractedPageText, ...]) -> str:
    """Join page texts with scannable ``--- Page N ---`` separators."""
    if not page_texts:
        return ""
    if len(page_texts) == 1:
        return page_texts[0].text.strip()
    sections = [f"--- Page {page.page_number} ---\n\n{page.text}" for page in page_texts]
    return "\n\n".join(sections).strip()


def _strip_comments(text: str) -> str:
    return HTML_COMMENT_RE.sub("", text)


def _strip_markdown_frontmatter(text: str) -> tuple[dict[str, object], str]:
    frontmatter, body, has_frontmatter = parse_markdown_text(text)
    if has_frontmatter:
        return frontmatter, body
    return {}, text


def _title_from_markdown(text: str, path: Path, frontmatter: dict[str, object] | None = None) -> str:
    if frontmatter:
        frontmatter_title = normalize_text(str(frontmatter.get("title", "")))
        if frontmatter_title:
            return frontmatter_title
    title = _title_from_stem(path.stem)
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match and line.lstrip().startswith("# "):
            title = normalize_text(match.group(1))
            break
    return title


def _extract_markdown_headings(text: str) -> list[str]:
    headings: list[str] = []
    for line in _markdown_lines_without_fences(text):
        match = HEADING_RE.match(line)
        if not match:
            continue
        heading = normalize_text(match.group(1))
        if heading:
            headings.append(heading)
    return headings


def _paragraphs_from_text(text: str, *, strip_headings: bool = False) -> list[str]:
    paragraphs: list[str] = []
    for block in re.split(r"\n\s*\n", text):
        cleaned_lines: list[str] = []
        for line in _markdown_lines_without_fences(block):
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("<!--"):
                continue
            if strip_headings and HEADING_RE.match(stripped):
                continue
            stripped = re.sub(r"^[-*+]\s+", "", stripped)
            stripped = re.sub(r"^>\s*", "", stripped)
            cleaned_lines.append(stripped)
        paragraph = normalize_text(" ".join(cleaned_lines))
        if paragraph:
            paragraphs.append(paragraph)
    return paragraphs


def _strip_fenced_code(text: str) -> str:
    return "\n".join(_markdown_lines_without_fences(text))


def _markdown_lines_without_fences(text: str) -> list[str]:
    lines: list[str] = []
    in_fence = False
    fence_marker = ""
    for line in text.splitlines():
        stripped = line.strip()
        fence_match = re.match(r"^(```+|~~~+)", stripped)
        if fence_match:
            marker = fence_match.group(1)
            if not in_fence:
                in_fence = True
                fence_marker = marker[0]
            elif stripped.startswith(fence_marker * 3):
                in_fence = False
                fence_marker = ""
            continue
        if in_fence:
            continue
        lines.append(line)
    return lines


def _dedupe_headings(headings: list[str], title: str) -> list[str]:
    seen: set[str] = set()
    results: list[str] = []
    title_key = normalize_text(title).lower()
    for heading in headings:
        heading_key = normalize_text(heading).lower()
        if not heading_key or heading_key == title_key or heading_key in seen:
            continue
        seen.add(heading_key)
        results.append(heading)
    return results


def is_url(path_or_url: str) -> bool:
    """Return True if the string looks like an HTTP(S) URL."""
    return path_or_url.startswith("http://") or path_or_url.startswith("https://")


def is_supported(path_or_url: str | Path) -> bool:
    """Return True if the path is a supported file type or an HTTP(S) URL."""
    if isinstance(path_or_url, str) and is_url(path_or_url):
        return True
    path = Path(path_or_url) if isinstance(path_or_url, str) else path_or_url
    return path.suffix.lower() in SUPPORTED_EXTENSIONS and not path.name.startswith(".")


def is_generated_raw_asset(path_or_url: str | Path) -> bool:
    """Return True for generated attachments stored under ``raw/assets/``."""
    if isinstance(path_or_url, str) and is_url(path_or_url):
        return False
    path = Path(path_or_url) if isinstance(path_or_url, str) else path_or_url
    parts = [part.lower() for part in path.parts]
    return any(parts[index] == "raw" and parts[index + 1] == "assets" for index in range(len(parts) - 1))
