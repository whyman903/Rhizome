from __future__ import annotations

from compile.markdown import (
    WIKILINK_RE,
    count_content_paragraphs,
    extract_wikilinks,
    parse_markdown_text,
)


class TestParseMarkdownText:
    def test_basic_frontmatter(self) -> None:
        text = "---\ntitle: Hello\ntype: article\n---\n\nBody text."
        fm, body, has_fm = parse_markdown_text(text)
        assert has_fm is True
        assert fm["title"] == "Hello"
        assert fm["type"] == "article"
        assert body == "Body text."

    def test_no_frontmatter(self) -> None:
        text = "# Just a heading\n\nSome body."
        fm, body, has_fm = parse_markdown_text(text)
        assert has_fm is False
        assert fm == {}
        assert "Just a heading" in body

    def test_malformed_yaml(self) -> None:
        text = "---\n[invalid yaml: {\n---\n\nBody."
        fm, body, has_fm = parse_markdown_text(text)
        assert has_fm is False
        assert fm == {}

    def test_incomplete_frontmatter_delimiter(self) -> None:
        text = "---\ntitle: Hello\nNo closing delimiter."
        fm, body, has_fm = parse_markdown_text(text)
        assert has_fm is False

    def test_empty_frontmatter(self) -> None:
        text = "---\n\n---\n\nBody here."
        fm, body, has_fm = parse_markdown_text(text)
        assert has_fm is True
        assert fm == {}
        assert body == "Body here."

    def test_frontmatter_with_lists(self) -> None:
        text = "---\ntags:\n  - alpha\n  - beta\n---\n\nBody."
        fm, body, has_fm = parse_markdown_text(text)
        assert fm["tags"] == ["alpha", "beta"]


class TestExtractWikilinks:
    def test_basic_links(self) -> None:
        body = "See [[Page A]] and [[Page B]]."
        links = extract_wikilinks(body)
        assert links == ["Page A", "Page B"]

    def test_pipe_aliases(self) -> None:
        body = "See [[Page A|display text]]."
        links = extract_wikilinks(body)
        assert links == ["Page A"]

    def test_no_links(self) -> None:
        assert extract_wikilinks("Plain text.") == []

    def test_empty_link_ignored(self) -> None:
        body = "See [[]] and [[Valid]]."
        links = extract_wikilinks(body)
        assert links == ["Valid"]

    def test_hash_fragment_excluded(self) -> None:
        # The regex excludes links containing # entirely (they're section refs)
        body = "See [[Page#section]]."
        links = extract_wikilinks(body)
        assert links == []

    def test_fenced_code_block_wikilinks_ignored(self) -> None:
        body = (
            "See [[Real Link]].\n\n"
            "```python\n"
            "# [[Ghost In Code]] should not count\n"
            "x = \"[[Also Ghost]]\"\n"
            "```\n\n"
            "And [[Another Real]]."
        )
        assert extract_wikilinks(body) == ["Real Link", "Another Real"]

    def test_callout_prefixed_fenced_code_wikilinks_ignored(self) -> None:
        body = (
            "> [!note]- Nested code example\n"
            "> See [[Real Callout Link]].\n"
            "> ```python\n"
            "> [[Ghost Topic]]\n"
            "> ```\n"
            "> End of callout."
        )
        assert extract_wikilinks(body) == ["Real Callout Link"]

    def test_inline_code_wikilinks_ignored(self) -> None:
        body = "See [[Real]] and `[[Ghost]]` and more `code [[Also Ghost]] here`."
        assert extract_wikilinks(body) == ["Real"]

    def test_tilde_fence_wikilinks_ignored(self) -> None:
        body = (
            "See [[Real]].\n\n"
            "~~~\n"
            "[[Ghost]]\n"
            "~~~\n"
        )
        assert extract_wikilinks(body) == ["Real"]

    def test_full_text_callout_wikilinks_ignored(self) -> None:
        body = (
            "See [[Real Outbound]].\n\n"
            "## Provenance\n\n"
            "- Source file: ![[raw/imported.md]]\n\n"
            "> [!abstract]- Full extracted text\n"
            "> Imported prose linking to [[Ghost Topic]].\n"
            "> And another [[Ghost Two]] reference.\n"
        )
        assert extract_wikilinks(body) == ["Real Outbound", "raw/imported.md"]

    def test_double_backtick_inline_code_wikilinks_ignored(self) -> None:
        body = "See [[Real]] and ``code with ` and [[Ghost]]`` here."
        assert extract_wikilinks(body) == ["Real"]

    def test_longer_opening_fence_requires_matching_close(self) -> None:
        body = (
            "See [[Real]].\n\n"
            "````markdown\n"
            "```inner\n"
            "[[Ghost Inside]]\n"
            "```\n"
            "[[Also Ghost]]\n"
            "````\n\n"
            "After [[Real Two]]."
        )
        assert extract_wikilinks(body) == ["Real", "Real Two"]

    def test_full_text_callout_stops_at_blank_line(self) -> None:
        body = (
            "> [!abstract]- Full extracted text\n"
            "> [[Ghost]]\n"
            "\n"
            "After the callout: [[Real]].\n"
        )
        assert extract_wikilinks(body) == ["Real"]


class TestCountContentParagraphs:
    def test_counts_substantial_lines(self) -> None:
        body = (
            "# Heading\n\n"
            "This is a paragraph long enough to count as content (over 30 chars easily).\n\n"
            "Another substantial paragraph with enough text to be meaningful here.\n\n"
            "- A list item\n"
            "> A blockquote\n"
        )
        assert count_content_paragraphs(body) == 2

    def test_empty_body(self) -> None:
        assert count_content_paragraphs("") == 0

    def test_only_headings(self) -> None:
        body = "# Heading 1\n## Heading 2\n### Heading 3"
        assert count_content_paragraphs(body) == 0

    def test_short_lines_not_counted(self) -> None:
        body = "Short.\nAlso short.\nTiny."
        assert count_content_paragraphs(body) == 0

    def test_mixed_content(self) -> None:
        body = (
            "# Title\n\n"
            "A very long paragraph that definitely exceeds thirty characters.\n\n"
            "Short.\n\n"
            "- list item\n"
            "Another paragraph that is long enough to be counted as a content paragraph.\n"
        )
        assert count_content_paragraphs(body) == 2


class TestWikilinkRegex:
    def test_matches_basic(self) -> None:
        match = WIKILINK_RE.search("[[Hello World]]")
        assert match is not None
        assert match.group(1) == "Hello World"

    def test_matches_with_pipe(self) -> None:
        match = WIKILINK_RE.search("[[Target|Display]]")
        assert match is not None
        assert match.group(1) == "Target"
