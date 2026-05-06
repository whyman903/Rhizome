from __future__ import annotations

from dataclasses import dataclass

from compile.markdown import WORD_RE
from compile.obsidian import ObsidianConnector, VaultPage
from compile.page_types import MAP_PAGE_TYPES


_STOP_WORDS = {
    "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
    "of", "with", "by", "from", "is", "it", "its", "was", "are", "be",
    "this", "that", "not", "as", "has", "had", "have", "do", "does",
    "will", "can", "may", "so", "if", "no", "we", "they", "he", "she",
    "you", "your", "their", "our",
    "source", "sources", "note", "notes", "synopsis", "provenance",
    "review", "status", "document", "file", "files", "section", "sections",
    "key", "keys", "claim", "claims", "finding", "findings",
    "page", "pages", "test", "another", "paragraph",
}


def _search_terms(value: str) -> list[str]:
    return [term.lower() for term in WORD_RE.findall(value) if term.lower() not in _STOP_WORDS]


def _summary_text(page: VaultPage) -> str:
    return str(page.frontmatter.get("summary") or "").strip()


def _body_excerpt(page: VaultPage, *, char_limit: int = 400) -> str:
    kept: list[str] = []
    total = 0
    for line in page.body.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("![[") or stripped.startswith("- Source file:"):
            continue
        if "registration shell" in stripped.lower():
            continue
        if "needs document-level review" in stripped.lower():
            continue
        kept.append(stripped)
        total += len(stripped) + 1
        if total >= char_limit:
            break
    return " ".join(kept)[:char_limit]


def _page_term_sets(page: VaultPage) -> dict[str, set[str]]:
    return {
        "title": set(_search_terms(page.title)),
        "tags": set(_search_terms(" ".join(page.tags))),
        "aliases": set(_search_terms(" ".join(page.aliases))),
        "summary": set(_search_terms(_summary_text(page))),
        "body": set(_search_terms(_body_excerpt(page))),
    }


def _score_map_match(source_page: VaultPage, map_page: VaultPage) -> tuple[int, list[str]]:
    source_terms = _page_term_sets(source_page)
    map_terms = _page_term_sets(map_page)

    source_primary = source_terms["title"] | source_terms["tags"] | source_terms["aliases"] | source_terms["summary"]
    map_primary = map_terms["title"] | map_terms["tags"] | map_terms["aliases"]
    map_secondary = map_terms["summary"] | map_terms["body"]

    primary_overlap = source_primary & map_primary
    secondary_overlap = source_primary & map_secondary
    body_overlap = source_terms["body"] & (map_primary | map_secondary)

    score = 0
    score += 6 * len(primary_overlap)
    score += 3 * len(secondary_overlap - primary_overlap)
    score += min(len(body_overlap - secondary_overlap - primary_overlap), 3)

    shared_terms = sorted(primary_overlap | secondary_overlap | body_overlap)
    return score, shared_terms


def _is_map_match(score: int, shared_terms: list[str]) -> bool:
    if score >= 12:
        return True
    return score >= 6 and len(shared_terms) >= 2


@dataclass
class MapSuggestion:
    map_title: str
    map_path: str
    source_notes: list[VaultPage]
    score: int
    reason: str

    def to_dict(self) -> dict[str, object]:
        return {
            "map_title": self.map_title,
            "map_path": self.map_path,
            "source_notes": [{"title": p.title, "relative_path": p.relative_path} for p in self.source_notes],
            "score": self.score,
            "reason": self.reason,
        }


def suggest_map_updates(
    connector: ObsidianConnector,
    *,
    limit: int = 10,
) -> tuple[list[MapSuggestion], list[VaultPage]]:
    pages = connector.scan()
    map_pages = [page for page in pages if page.page_type in MAP_PAGE_TYPES]
    unanchored_sources = connector.source_pages_without_topic_anchors()

    if not map_pages or not unanchored_sources:
        return [], unanchored_sources

    grouped: dict[str, dict[str, object]] = {}
    unmatched: list[VaultPage] = []

    for source_page in unanchored_sources:
        best_map: VaultPage | None = None
        best_score = 0
        best_terms: list[str] = []
        for map_page in map_pages:
            score, shared_terms = _score_map_match(source_page, map_page)
            if score > best_score:
                best_map = map_page
                best_score = score
                best_terms = shared_terms

        if best_map is None or not _is_map_match(best_score, best_terms):
            unmatched.append(source_page)
            continue

        group = grouped.setdefault(
            best_map.relative_path,
            {
                "map_page": best_map,
                "source_notes": [],
                "score": 0,
                "terms": set(),
            },
        )
        source_notes = group["source_notes"]
        assert isinstance(source_notes, list)
        source_notes.append(source_page)
        group["score"] = int(group["score"]) + best_score
        terms = group["terms"]
        assert isinstance(terms, set)
        terms.update(best_terms)

    suggestions = [
        MapSuggestion(
            map_title=str(group["map_page"].title),
            map_path=str(group["map_page"].relative_path),
            source_notes=sorted(group["source_notes"], key=lambda page: page.title.lower()),
            score=int(group["score"]),
            reason=(
                f"Shared terms: {', '.join(sorted(group['terms'])[:6])}."
                if group["terms"]
                else "Keyword overlap suggests this map should absorb the source notes."
            ),
        )
        for group in grouped.values()
        if group["source_notes"]
    ]
    suggestions.sort(key=lambda item: (-len(item.source_notes), -item.score, item.map_title.lower()))
    return suggestions[: max(limit, 1)], sorted(unmatched, key=lambda page: page.title.lower())
