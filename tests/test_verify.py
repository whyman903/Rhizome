from __future__ import annotations

from compile.verify import verify_page_content


def test_verify_flags_missing_frontmatter() -> None:
    content = "# No frontmatter\n\nJust a page with some content that is long enough to count."

    issues = verify_page_content(page_type="article", content=content)

    codes = {issue.code for issue in issues}
    assert "missing_frontmatter" in codes


def test_verify_flags_unresolved_wikilinks() -> None:
    content = """---
title: Test Page
type: article
updated: "2026-01-01"
---

# Test Page

See [[Nonexistent Page]] for details. This paragraph has enough content to avoid thin warnings.
"""

    issues = verify_page_content(
        page_type="article",
        content=content,
        valid_link_targets=["Other Page"],
    )

    assert any(issue.code == "unresolved_wikilink" for issue in issues)


def test_verify_ignores_wikilinks_in_fenced_code() -> None:
    content = """---
title: Test Page
type: article
updated: "2026-01-01"
---

# Test Page

Plenty of real content in this paragraph so the page is not flagged thin either.

```python
# [[Ghost Topic]] inside code should not be flagged
identifier = "[[Also Ghost]]"
```

> [!abstract]- Full extracted text
> ```python
> [[Callout Ghost]]
> ```
"""

    issues = verify_page_content(
        page_type="article",
        content=content,
        valid_link_targets=["Other Page"],
    )

    assert not any(issue.code == "unresolved_wikilink" for issue in issues)


def test_verify_passes_clean_page() -> None:
    content = """---
title: Friendship
type: article
updated: "2026-01-01"
---

# Friendship

Aristotle distinguishes three kinds of friendship: utility, pleasure, and virtue.

Virtue friendship is the most durable because it is grounded in mutual recognition of character.
"""

    issues = verify_page_content(page_type="article", content=content)

    assert not any(issue.severity == "high" for issue in issues)


def test_verify_ignores_wikilinks_in_full_text_callout() -> None:
    content = """---
title: Test Page
type: article
status: provisional
summary: Just a test
created: "2026-01-01"
updated: "2026-01-01"
---

# Test Page

This page has plenty of prose to avoid the thin_content warning because the paragraph is long enough.

Another substantive paragraph so the content check is satisfied without needing the callout.

> [!abstract]- Full extracted text
> Imported prose references [[Ghost Topic]] and [[Another Ghost]] verbatim.
"""

    issues = verify_page_content(
        page_type="article",
        content=content,
        valid_link_targets=["Other Page"],
    )

    assert not any(issue.code == "unresolved_wikilink" for issue in issues)


def test_verify_thin_content_ignores_code_lines() -> None:
    content = """---
title: Code Only Page
type: article
status: provisional
summary: A page that is essentially just a code sample
created: "2026-01-01"
updated: "2026-01-01"
---

# Code Only Page

```python
very_long_identifier_name_one = compute_with_arguments(alpha, beta, gamma)
very_long_identifier_name_two = compute_with_arguments(delta, epsilon, zeta)
```
"""

    issues = verify_page_content(page_type="article", content=content)

    assert any(issue.code == "thin_content" for issue in issues)


def test_verify_source_provenance() -> None:
    content = """---
title: Brief Is Better
type: source
updated: "2026-01-01"
---

# Brief Is Better

Summary of the paper without linking back to the raw file.
"""

    issues = verify_page_content(
        page_type="source",
        content=content,
        raw_source_path="raw/brief-is-better.pdf",
    )

    assert any(issue.code == "missing_provenance" for issue in issues)
