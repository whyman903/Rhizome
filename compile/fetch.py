"""Fetch a URL and save it as a local raw source."""

from __future__ import annotations

from pathlib import Path
import re
from urllib.parse import urljoin, urlparse

import httpx
from bs4 import BeautifulSoup
from markdownify import markdownify as md

from compile.dates import now_machine
from compile.text import SUPPORTED_EXTENSIONS, slugify

_USER_AGENT = "compile-wiki/0.2 (personal knowledge base builder)"
_TIMEOUT = 30
_HTML_CONTENT_TYPES = {"text/html", "application/xhtml+xml"}
_CONTENT_TYPE_EXTENSIONS = {
    "application/pdf": ".pdf",
    "image/gif": ".gif",
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/svg+xml": ".svg",
    "image/webp": ".webp",
    "text/markdown": ".md",
    "text/plain": ".txt",
    "text/x-markdown": ".md",
}


def fetch_url(
    url: str,
    raw_dir: Path,
    *,
    download_images: bool = False,
) -> tuple[Path, str]:
    """Fetch *url*, convert to markdown, save into *raw_dir*.

    Returns ``(saved_path, title)``.
    """
    response = httpx.get(
        url,
        follow_redirects=True,
        timeout=_TIMEOUT,
        headers={"User-Agent": _USER_AGENT},
    )
    response.raise_for_status()

    content_type = _normalize_content_type(response.headers.get("content-type", ""))
    content_preview = response.content[:1024].decode(errors="ignore")
    if not _is_html_response(url, content_type, content_preview):
        return _save_supported_response(url, response, raw_dir, content_type)

    soup = BeautifulSoup(response.text, "html.parser")
    title = _extract_title(soup, url)

    # Prefer <article> or <main> over the full <body>
    content_node = soup.find("article") or soup.find("main") or soup.body or soup

    if download_images:
        _download_images(content_node, url, raw_dir)

    # Strip nav, footer, aside, script, style
    for tag in content_node.find_all(["nav", "footer", "aside", "script", "style", "noscript"]):
        tag.decompose()

    markdown_body = md(str(content_node), heading_style="ATX", strip=["img"] if not download_images else [])
    markdown_body = _clean_markdown(markdown_body)
    markdown_body = _strip_duplicate_title(markdown_body, title)

    now = now_machine()
    provenance = f"<!-- source_url: {url} -->\n<!-- fetched: {now} -->\n\n"
    full_content = provenance + f"# {title}\n\n" + markdown_body

    slug = slugify(title) or slugify(urlparse(url).netloc + "-" + urlparse(url).path)
    dest = raw_dir / f"{slug}.md"

    # Avoid overwriting — append a counter if needed
    counter = 1
    while dest.exists():
        dest = raw_dir / f"{slug}-{counter}.md"
        counter += 1

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(full_content)
    return dest, title


def _save_supported_response(
    url: str,
    response: httpx.Response,
    raw_dir: Path,
    content_type: str,
) -> tuple[Path, str]:
    """Persist a non-HTML response in a format supported by ``extract_text``."""
    suffix = _suffix_for_response(url, content_type)
    if suffix not in SUPPORTED_EXTENSIONS:
        raise ValueError(
            f"Unsupported remote content type: {content_type or 'unknown'}"
        )

    slug = slugify(Path(urlparse(url).path).stem or urlparse(url).netloc)
    dest = _unique_path(raw_dir, slug, suffix)
    dest.parent.mkdir(parents=True, exist_ok=True)

    if suffix in {".md", ".markdown", ".txt"}:
        text = response.text
        if text and not text.endswith("\n"):
            text += "\n"
        dest.write_text(text)
    else:
        dest.write_bytes(response.content)

    # Let ``extract_text`` derive a title from the saved artifact itself.
    return dest, ""


def _extract_title(soup: BeautifulSoup, url: str) -> str:
    """Pull a page title from OG tags, <title>, or <h1>."""
    og = soup.find("meta", property="og:title")
    if og and og.get("content"):
        return og["content"].strip()[:120]
    if soup.title and soup.title.string:
        return soup.title.string.strip()[:120]
    h1 = soup.find("h1")
    if h1:
        return h1.get_text(strip=True)[:120]
    return urlparse(url).netloc


def _normalize_content_type(content_type: str) -> str:
    return content_type.lower().split(";", 1)[0].strip()


def _is_html_response(url: str, content_type: str, content_preview: str) -> bool:
    suffix = Path(urlparse(url).path).suffix.lower()
    if content_type in _HTML_CONTENT_TYPES:
        return True
    if content_type in {"", "text/plain"} and _looks_like_html(content_preview):
        return True
    if suffix in {".html", ".htm"}:
        return True
    if not content_type and suffix in {"", ".php", ".asp", ".aspx", ".jsp"}:
        return True
    return False


def _looks_like_html(content_preview: str) -> bool:
    preview = content_preview.lstrip().lower()
    return preview.startswith(("<!doctype html", "<html")) or any(
        marker in preview for marker in ("<body", "<article", "<main")
    )


def _suffix_for_response(url: str, content_type: str) -> str:
    suffix = Path(urlparse(url).path).suffix.lower()
    if suffix in SUPPORTED_EXTENSIONS:
        return suffix
    return _CONTENT_TYPE_EXTENSIONS.get(content_type, "")


def _unique_path(raw_dir: Path, slug: str, suffix: str) -> Path:
    dest = raw_dir / f"{slug}{suffix}"
    counter = 1
    while dest.exists():
        dest = raw_dir / f"{slug}-{counter}{suffix}"
        counter += 1
    return dest


def _clean_markdown(text: str) -> str:
    """Remove excessive blank lines and trailing whitespace."""
    text = re.sub(r"\n{3,}", "\n\n", text)
    lines = [line.rstrip() for line in text.splitlines()]
    return "\n".join(lines).strip() + "\n"


def _strip_duplicate_title(markdown_body: str, title: str) -> str:
    """Remove a leading ``# Title`` line if it duplicates the title we prepend."""
    pattern = re.compile(r"^#\s+" + re.escape(title) + r"\s*\n+", re.IGNORECASE)
    return pattern.sub("", markdown_body, count=1)


def _download_images(
    node: BeautifulSoup,
    base_url: str,
    raw_dir: Path,
) -> None:
    """Download <img> sources into raw/assets/ and rewrite src attributes."""
    assets_dir = raw_dir / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)

    for img in node.find_all("img"):
        src = img.get("src")
        if not src:
            continue
        abs_url = urljoin(base_url, src)
        try:
            resp = httpx.get(abs_url, follow_redirects=True, timeout=15, headers={"User-Agent": _USER_AGENT})
            resp.raise_for_status()
        except (httpx.HTTPError, httpx.InvalidURL):
            continue

        # Determine filename from URL path
        url_path = urlparse(abs_url).path
        filename = slugify(Path(url_path).stem) or "image"
        suffix = Path(url_path).suffix or _CONTENT_TYPE_EXTENSIONS.get(_normalize_content_type(resp.headers.get("content-type", "")), "")
        if not suffix:
            suffix = ".png"
        dest = assets_dir / f"{filename}{suffix}"
        counter = 1
        while dest.exists():
            dest = assets_dir / f"{filename}-{counter}{suffix}"
            counter += 1
        dest.write_bytes(resp.content)
        # Rewrite the img src to local relative path
        img["src"] = f"assets/{dest.name}"
