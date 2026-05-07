from __future__ import annotations

import json
from pathlib import Path
import re

import yaml

from compile.config import Config, save_config
from compile.dates import format_frontmatter_datetime, now_frontmatter, now_machine
from compile.markdown import parse_markdown_text
from compile.page_types import ARTICLE_PAGE_TYPES, MAP_PAGE_TYPES, OUTPUT_PAGE_TYPES, WATCH_PAGE_TYPES

COMPILE_CSS = """\
.frontmatter-container .metadata-property[data-property-key="type"] .metadata-property-value {
  font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; font-size: 0.85em;
}
.markdown-preview-view.source, .workspace-leaf-content.source .markdown-preview-view {
  border-left: 3px solid #5078c0; padding-left: 12px;
}
.markdown-preview-view.article, .workspace-leaf-content.article .markdown-preview-view {
  border-left: 3px solid #00a59a; padding-left: 12px;
}
.markdown-preview-view.map, .workspace-leaf-content.map .markdown-preview-view {
  border-left: 3px solid #8e44ad; padding-left: 12px;
}
.markdown-preview-view table { width: 100%; }
"""


def init_workspace(root: Path, topic: str, description: str = "") -> Config:
    if (root / ".compile" / "config.yaml").exists():
        raise FileExistsError(f"Workspace already exists at {root}")

    config = Config(topic=topic, description=description, workspace_root=root)

    for subdir in ["raw", "wiki/articles", "wiki/sources", "wiki/outputs", "wiki/maps", ".compile"]:
        (root / subdir).mkdir(parents=True, exist_ok=True)

    save_config(config)
    _save_state(config, {"processed": {}, "created_at": now_machine()})

    empty_pages: dict[str, list[dict[str, str]]] = {"articles": [], "sources": [], "maps": [], "outputs": [], "other": []}
    write_index(config, empty_pages)
    write_overview(config, empty_pages)
    _write_initial_log(config)
    _write_initial_schema(config)
    _setup_obsidian(root)

    return config


def ensure_workspace_schema(config: Config) -> bool:
    if config.wiki_schema_path.exists():
        return False
    _write_initial_schema(config)
    return True


def read_schema(config: Config) -> str:
    if config.wiki_schema_path.exists():
        return config.wiki_schema_path.read_text()
    return ""


def load_state(config: Config) -> dict:
    if config.state_path.exists():
        return json.loads(config.state_path.read_text())
    return {"processed": {}, "created_at": now_machine()}


def mark_processed(config: Config, raw_path: Path, pages_touched: list[str]) -> None:
    state = load_state(config)
    relative = str(raw_path.relative_to(config.workspace_root))
    state["processed"][relative] = {
        "processed_at": now_machine(),
        "pages_touched": pages_touched,
        "size": raw_path.stat().st_size,
    }
    _save_state(config, state)


def get_unprocessed(config: Config) -> list[Path]:
    from compile.text import is_generated_raw_asset, is_supported
    state = load_state(config)
    processed = state.get("processed", {})
    return [
        path for path in sorted(config.raw_dir.rglob("*"))
        if path.is_file() and is_supported(path)
        and not is_generated_raw_asset(path)
        and str(path.relative_to(config.workspace_root)) not in processed
    ]


def get_status(config: Config) -> dict:
    from compile.text import is_generated_raw_asset, is_supported
    from compile.obsidian import ObsidianConnector
    state = load_state(config)
    raw_files = [
        p for p in config.raw_dir.rglob("*")
        if p.is_file() and is_supported(p) and not is_generated_raw_asset(p)
    ]
    raw_relatives = {
        str(path.relative_to(config.workspace_root))
        for path in raw_files
    }
    processed_count = sum(
        1
        for relative in state.get("processed", {})
        if relative in raw_relatives
    )
    connector = ObsidianConnector(config.workspace_root)
    needs_document_review = sum(
        1
        for page in connector.scan()
        if page.page_type == "source"
        and str(page.frontmatter.get("review_status") or "").strip() == "needs_document_review"
    )
    return {
        "topic": config.topic,
        "description": config.description,
        "raw_files": len(raw_files),
        "processed": processed_count,
        "unprocessed": len(get_unprocessed(config)),
        "needs_document_review": needs_document_review,
        "wiki_pages": len(list(config.wiki_dir.rglob("*.md"))),
        "workspace_root": str(config.workspace_root),
    }


def read_wiki_page(config: Config, relative_path: str) -> str | None:
    path = config.wiki_dir / relative_path
    return path.read_text() if path.exists() else None


def list_wiki_pages(config: Config) -> list[str]:
    return [str(p.relative_to(config.wiki_dir)) for p in sorted(config.wiki_dir.rglob("*.md"))]


def list_wiki_canvas_files(config: Config) -> list[str]:
    """List ``.canvas`` files in the wiki directory."""
    return [str(p.relative_to(config.wiki_dir)) for p in sorted(config.wiki_dir.rglob("*.canvas"))]


# --- Page collection and navigation ---

def collect_pages_by_type(config: Config) -> dict[str, list[dict[str, str]]]:
    buckets: dict[str, list[dict[str, str]]] = {
        "articles": [], "sources": [], "maps": [], "outputs": [], "watches": [], "other": [],
    }
    for page_path in list_wiki_pages(config):
        if page_path in ("index.md", "overview.md", "log.md"):
            continue
        content = read_wiki_page(config, page_path)
        if not content:
            continue
        fm, body, _ = parse_markdown_text(content)
        page_type = _bucket_for_page(str(fm.get("type") or ""), page_path)
        title = str(fm.get("title") or "").strip() or Path(page_path).stem.replace("-", " ").title()
        summary = str(fm.get("summary") or "").strip()
        if not summary:
            for line in body.splitlines():
                s = line.strip()
                if s and not s.startswith(("#", "<!--")):
                    summary = re.sub(r"^[-*]\s+", "", s)[:120]
                    break
        buckets[page_type].append({"path": page_path, "title": title, "summary": summary})
    for entries in buckets.values():
        entries.sort(key=lambda e: e["title"].lower())
    return buckets


def write_index(config: Config, pages_by_type: dict[str, list[dict[str, str]]]) -> None:
    now = now_frontmatter()
    created = _preserved_created(config.wiki_dir / "index.md", now)
    sections = [
        ("Articles", "articles"), ("Sources", "sources"),
        ("Maps", "maps"), ("Outputs", "outputs"),
        ("Watches", "watches"), ("Other", "other"),
    ]
    has_content = any(pages_by_type.get(key) for _, key in sections)
    index_fm = {"title": "Index", "type": "index", "created": created, "updated": now}
    if not has_content:
        index_fm["bootstrap"] = True
    fm_text = yaml.safe_dump(index_fm, sort_keys=False, allow_unicode=True).strip()
    lines = [
        f"---\n{fm_text}\n---\n",
        f"# {config.topic} — Index\n",
    ]
    for heading, key in sections:
        entries = pages_by_type.get(key, [])
        lines.append(f"## {heading}\n")
        if entries:
            lines.extend(f"- [[{e['title']}]] — {e['summary'] or 'No summary yet.'}" for e in entries)
        lines.append("")
    (config.wiki_dir / "index.md").write_text("\n".join(lines).rstrip() + "\n")


def write_overview(config: Config, pages_by_type: dict[str, list[dict[str, str]]]) -> None:
    now = now_frontmatter()
    created = _preserved_created(config.wiki_dir / "overview.md", now)
    counts = {k: len(v) for k, v in pages_by_type.items()}
    total = sum(counts.values())
    desc = config.description or "A maintained wiki workspace."

    if total == 0:
        state = "This workspace was just initialized. Add material to `raw/` or create pages in `wiki/articles/`."
    else:
        state = "\n".join(f"- {k.title()}: {v}" for k, v in counts.items() if v)

    top_articles = "\n".join(
        f"- [[{e['title']}]] — {e['summary'] or ''}" for e in pages_by_type.get("articles", [])[:8]
    ) or "_No articles yet._"

    overview_fm = {
        "title": f"{config.topic} Overview",
        "type": "overview",
        "created": created,
        "updated": now,
    }
    if total == 0:
        overview_fm["bootstrap"] = True
    fm_text = yaml.safe_dump(overview_fm, sort_keys=False, allow_unicode=True).strip()

    content = f"""---
{fm_text}
---

# {config.topic}

{desc}

## Current State

{state}

## Highlights

{top_articles}

## Navigation

- [[Index]] — full catalog
"""
    (config.wiki_dir / "overview.md").write_text(content)


def append_log_entry(config: Config, kind: str, title: str, lines: list[str] | None = None) -> None:
    log_path = config.wiki_dir / "log.md"
    now = now_frontmatter()
    body = "\n".join(f"- {line}" for line in (lines or [])) or "- No details recorded."
    entry = f"\n\n## [{now}] {kind} | {title}\n{body}\n"

    if log_path.exists():
        existing = log_path.read_text()
        fm, body_text, _ = parse_markdown_text(existing)
        fm.update({"title": "Log", "type": "log", "updated": now})
        fm.setdefault("created", now)
        if not body_text.strip():
            body_text = "# Compile Log\n"
        fm_text = yaml.safe_dump(fm, sort_keys=False, allow_unicode=True).strip()
        log_path.write_text(f"---\n{fm_text}\n---\n\n{body_text.rstrip()}{entry}")
    else:
        log_path.write_text(
            f"---\ntitle: Log\ntype: log\ncreated: {now}\nupdated: {now}\n---\n\n# Compile Log\n{entry}"
        )


# --- Internals ---


def _save_state(config: Config, state: dict) -> None:
    config.compile_dir.mkdir(parents=True, exist_ok=True)
    config.state_path.write_text(json.dumps(state, indent=2))



def _preserved_created(path: Path, fallback: str) -> str:
    if path.exists():
        fm, _, _ = parse_markdown_text(path.read_text())
        value = fm.get("created")
        if value is None:
            return fallback
        # Normalize parsed date/datetime objects back to frontmatter format.
        if hasattr(value, "strftime"):
            return format_frontmatter_datetime(value)
        return str(value)
    return fallback


def _bucket_for_page(page_type: str, page_path: str) -> str:
    t = page_type.strip().lower()
    if t == "source" or page_path.startswith("sources/"):
        return "sources"
    if t in ARTICLE_PAGE_TYPES or page_path.startswith(("articles/", "concepts/", "entities/", "questions/")):
        return "articles"
    if t in MAP_PAGE_TYPES or page_path.startswith(("maps/", "dashboards/")):
        return "maps"
    if t in OUTPUT_PAGE_TYPES or page_path.startswith("outputs/"):
        return "outputs"
    if t in WATCH_PAGE_TYPES or page_path.startswith("watches/"):
        return "watches"
    return "other"


def _write_initial_log(config: Config) -> None:
    now = now_frontmatter()
    (config.wiki_dir / "log.md").write_text(
        f"---\ntitle: Log\ntype: log\ncreated: {now}\nupdated: {now}\n---\n\n"
        f"# Compile Log\n\n## [{now}] init | {config.topic}\n- Workspace initialized\n"
    )


def _write_initial_schema(config: Config) -> None:
    desc = config.description or "Add a short description for this workspace."
    config.wiki_schema_path.write_text(f"""# Workspace Schema

This file is the per-workspace overlay for the base maintainer contract in `CLAUDE.md`.
Use it to make topic-specific editorial decisions, not to restate generic rules.

## Topic And Framing

- Title: {config.topic}
- Framing: {desc}
- Primary audience: update this for each workspace
- Preferred output style: update this for each workspace

## Canonical Page Types

- `source`: provenance-anchored note for a raw artifact
- `article`: durable synthesis page; default type for concepts, themes, entities, timelines, people, and places unless a workspace-specific type is truly necessary
- `map`: navigation page that curates a region of the wiki
- `output`: saved answer, comparison, memo, deck source, chart spec, or other durable derived artifact
- `index`, `overview`, `log`: maintenance and navigation pages managed continuously

Legacy `concept`, `entity`, `question`, and `dashboard` page types may still appear in older workspaces.
Prefer `article` / `map` for new generic workspaces unless this topic truly benefits from the legacy taxonomy.

## Page Contract

- Every maintained page must include frontmatter with:
  - `title`
  - `type`
  - `status`
  - `summary`
  - `created`
  - `updated`
- Valid `status` values:
  - `seed`: useful but provisional; usually backed by one source or one line of evidence
  - `emerging`: partially synthesized; multiple signals or sources but still incomplete
  - `stable`: durable reference page with synthesis, explicit support, and no obvious unresolved structural gaps
- Recommended optional fields when relevant:
  - `tags`
  - `aliases`
  - `sources`
  - `source_ids`
  - `citations`
  - `cssclasses`
- Use `[[Page Title]]` wikilinks only for pages that already exist, unless you are creating the target page in the same pass.
- Source-backed pages should preserve provenance explicitly.

## Naming And Linking

- Prefer singular, stable page names over brittle filenames or temporary labels.
- Use title case for page titles unless the canonical name is stylized differently.
- Split genuinely ambiguous names with disambiguators only when needed.
- Link the first substantial mention of an important page in a section; avoid linking every repeated occurrence.
- Add links where they improve traversal, not as decoration.

## Page Creation Rules

- Default to updating an existing page rather than creating a new one.
- Create a new `article` only when at least one of these is true:
  - the topic recurs across multiple pages or sources
  - the topic is central enough to deserve durable retrieval and navigation
  - the existing page would become unfocused if expanded further
- Create a new `map` only when readers need navigation across a cluster of pages, not just another summary.
- Create a new `output` only when the answer or artifact will likely remain useful after the current conversation.
- Do not create pages whose only purpose is to restate one source in slightly different words.

## Synthesis Standards

- Prefer updating existing articles over spawning many narrow pages
- `source` pages should capture:
  - what the artifact is
  - the main claims or findings
  - limits or caveats
  - exact provenance back to `raw/`
- `article` pages should usually include:
  - a clear thesis or framing
  - evidence or supporting claims
  - tensions, disagreements, or limitations when present
  - links to related pages
- `map` pages should help readers discover the shape of the topic and the important paths through it.
- `output` pages should record the question answered, the important inputs, and why the output was saved.
- Stable synthesis pages should name where sources agree, where they diverge, and what remains uncertain.

## Page Sizing Guidance

- Aim for `article` pages that are substantial enough to be useful but narrow enough to stay coherent.
- Split a page when it contains multiple separable theses, multiple distinct audiences, or long sections that mostly point to one subtopic.
- Merge or retire a page when it exists only as a weak alias, a one-source paraphrase, or a fragment that would read better as part of a broader page.

## Contradictions And Uncertainty

- Do not flatten contradictions into false consensus.
- If sources disagree, update the existing synthesis page and name the disagreement explicitly.
- Mark unsupported extrapolations as interpretation rather than source fact.
- Use `seed` or `emerging` status when the evidence base is still thin.

## Topic-Specific Priorities

- Broad topic hubs to maintain:
  - fill this in for the workspace
- Recurring subtopics to group under those hubs:
  - fill this in for the workspace
- Important entities / actors / artifacts:
  - fill this in for the workspace
- Important tensions, debates, or unresolved questions:
  - fill this in for the workspace
- Important evidence types or provenance standards:
  - fill this in for the workspace

Fill these in with real editorial priorities. Use them to decide when a source should connect to an existing
article or map page, and when a new lightweight map page is justified because the wiki has a broad topic with
no navigational hub yet.

## Saved Outputs

- Save durable query results to `wiki/outputs/`.
- Promote an output into a normal synthesis page only when it becomes a durable reference, not just a one-off answer.
""")


def _setup_obsidian(root: Path) -> None:
    obs = root / ".obsidian"
    obs.mkdir(exist_ok=True)

    (obs / "app.json").write_text(json.dumps({
        "useMarkdownLinks": False, "showLineNumber": True,
        "attachmentFolderPath": "raw/assets", "newLinkFormat": "shortest",
        "alwaysUpdateLinks": True,
    }, indent=2))

    (obs / "core-plugins.json").write_text(json.dumps([
        "file-explorer", "global-search", "graph", "backlink",
        "outgoing-link", "tag-pane", "page-preview", "command-palette", "outline",
    ], indent=2))

    (obs / "community-plugins.json").write_text("[]")

    (obs / "graph.json").write_text(json.dumps({
        "colorGroups": [
            {"query": "path:wiki/sources", "color": {"a": 1, "rgb": 5275647}},
            {"query": "path:wiki/articles", "color": {"a": 1, "rgb": 40959}},
            {"query": "path:wiki/maps", "color": {"a": 1, "rgb": 9323693}},
            {"query": "path:wiki/outputs", "color": {"a": 1, "rgb": 65280}},
        ],
        "showArrow": True, "nodeSizeMultiplier": 1.1,
    }, indent=2))

    (obs / "appearance.json").write_text(json.dumps({
        "accentColor": "#5b8def", "enabledCssSnippets": ["compile"],
    }, indent=2))

    (obs / "hotkeys.json").write_text("{}")

    snippets = obs / "snippets"
    snippets.mkdir(exist_ok=True)
    (snippets / "compile.css").write_text(COMPILE_CSS)
