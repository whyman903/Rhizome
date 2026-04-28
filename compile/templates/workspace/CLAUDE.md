# Compile — Wiki Maintainer Contract

You maintain a persistent, LLM-maintained wiki for Obsidian. The wiki compounds over time: every source processed and every useful answer saved should make it better.

Read `WIKI.md` in the workspace root for topic-specific editorial rules. If it differs from this file, follow `WIKI.md`.

## Layout

```text
raw/            Immutable source artifacts. Read freely, never modify.
wiki/
  articles/     Durable synthesis pages
  sources/      Source notes anchored to raw material
  maps/         Navigation pages
  outputs/      Saved derived artifacts
  index.md      Catalog of all pages
  overview.md   Landing page
  log.md        Append-only chronology
.compile/       Runtime state
WIKI.md         Workspace-specific schema
```

## CLI Tools

If the global `compile` entrypoint is unavailable, use `uv run compile ...`.

### Discovery and inspection

```bash
compile status
compile obsidian inspect
compile obsidian search "query"
compile obsidian page "Title"
compile obsidian neighbors "Title"
compile obsidian graph
compile suggest maps
compile health
compile health --json-output
```

### Writing and maintenance

```bash
compile ingest <source>
compile obsidian refresh
compile obsidian cleanup
compile schema
compile render canvas <title> --nodes-file /tmp/nodes.json [--edges-file /tmp/edges.json]
compile render marp <title> --body-file /tmp/deck.md
compile render chart <title> --script-file /tmp/chart.py
```

### Low-level page writes

Use this only as the executor beneath the workflows above, or for deliberate manual repair:

```bash
compile obsidian upsert "Title" \
  --page-type article \
  --status emerging \
  --body-file /tmp/page.md
```

### Connected workspace commands

- `/notion-setup` — use the connected Notion tools in Claude to save a local sync profile without asking the user for page IDs.
- `/notion-sync` — sync Notion pages into `raw/notion/`, then run the normal ingest workflow.

### Tool selection

- Search before creating pages. Prefer updating an existing page over spawning a near-duplicate.
- **Prefer targeted edits over rewrites.** When updating an existing page with a narrow change — fixing a claim, adding a bullet, revising one section, inserting a `[[wikilink]]` or citation, tightening a summary line — use the `Edit` tool directly on the `.md` file in `wiki/`. Rewriting a long page to change one paragraph invites hallucination in the parts you did not mean to touch.
- Keep `compile obsidian upsert` below the fold: use it for (a) creating a new page, (b) frontmatter-only updates like status, tags, or sources, or (c) a deliberate whole-body rewrite where a surgical edit is not enough.
- When a full rewrite is warranted, use `compile obsidian upsert --body-file ...`. A substantive rewrite via `--body-file` automatically clears `review_status: needs_document_review`; pass `--keep-review-status` to opt out, or `--clear-review-status` to force-clear after any write.
- Run `compile obsidian refresh` after page changes, then `compile health`.
- Prefer file-backed render inputs (`--body-file`, `--script-file`, `--nodes-file`) over large inline shell strings.

## Rich Formatting

The wiki is not text-only. Markdown paragraphs are the fallback, but richer formats should be used selectively when they materially improve comprehension or navigation.

Format triggers — use the first match, with explicit user wording taking precedence over internal labels or eval slugs:

| Trigger | Format |
|---|---|
| Comparison of 3+ items on shared dimensions | Table (or `compile render chart` if quantitative) |
| Explicit request to build/make/render/create a deck, chart, or canvas | Create the artifact immediately with `compile render ...` and report the created path |
| Relationships between 4+ concepts, causal chains, actor maps, dependencies | Mermaid in-page, unless the user explicitly requested a saved canvas |
| Sequential process, argument flow, or small hierarchy (3–15 nodes) | Mermaid diagram in-page |
| Teaching explanation, briefing, or walkthrough | Structured prose or Mermaid; use `compile render marp` only when the user asks to build a deck |
| Quantitative data, trends, distributions | Table or inline recommendation; use `compile render chart` only when the user asks for a chart artifact |
| Notable caveat, definition, or strong claim | Callout (`> [!note]`, `> [!warning]`, etc.) |
| None of the above | Plain prose with wikilinks |

Use callouts when they add clarity. For math, use LaTeX math notation, not Unicode math symbols.

Do not create rendered artifacts by default for routine notes or answers. Offer them when they would clearly help, and create them when the user asks for them or explicitly agrees. "Build/make/render/create me a deck/chart/canvas" is explicit consent to render and save that artifact; after rendering, report the created path and do not ask whether to save it again.

## Ingest Workflow

When the user adds a source to `raw/` and asks you to process it, work through two phases. Phase A stands up the source note. Phase B wires it into the wiki and is mandatory — a source note disconnected from any article or map is incomplete.

### Parallelism

Treat ingest as phased work. Batch independent read-only steps together when helpful, such as wiki searches, reading related pages, and reading raw sources. Serialize workspace writes: do not run multiple `compile ingest` commands in parallel, do not update multiple anchor pages concurrently, and run `compile obsidian refresh` plus `compile health` once after the write phase finishes.

### Phase A — Enrich the source note

1. Search the wiki first for existing related pages.
2. Run `compile ingest <filename>` to register the source and create a first-pass source note.
3. Read the generated source note.
4. Read the raw source itself when the generated note is weak, incomplete, or needs verification.
5. When a substantial improvement is warranted, rewrite the source note in place using the low-level page writer with `--body-file`. Before you commit any `[[wikilink]]`: identify 1–3 broader themes for the source, run `compile obsidian search` for each, and apply the 3-source bar from Phase B — only write `[[Theme Anchor]]` when an anchor already exists or you will create one this pass. Otherwise refer to the theme by plain text. Write the body as continuous prose covering the source's main claims with a brief evidence-strength judgment and any material caveats. Do not add `## Themes`, `## Key Claims`, or `## Caveats` headed sections — fold them into prose so the page reads as a short article, not a scaffolded form.

### Phase B — Wire into the wiki

Do not skip this phase. A source note that is not linked from any article or map page, and has no outbound wikilinks to one, is incomplete.

6. **Locality guard.** During ingest, direct edits are limited to the source note plus 1–3 theme anchors identified in Phase A. If a useful change would reach beyond those anchors into a broader cluster, defer it to `/lint` or `/synthesize`.
7. **Wire into existing structure.** For each theme identified in Phase A:
   - If an article or map already covers it and this source strengthens it, treat that page as the anchor. Update only that anchor page to incorporate the source's evidence or nuance, and ensure a `[[wikilink]]` connects the source note and the article/map (either outbound from the source note or via the anchor page citing `[[Source Title]]`).
   - If no article exists but 3+ sources now touch the theme, create a `seed` article that synthesizes across them and treat that new page as the anchor for this ingest pass.
   - If fewer than 3 sources share the theme, log the gap in `log.md` rather than creating a stub article or a single-source map. Do not back-fill `[[wikilinks]]` to anchors that will not exist.
8. **Verify wiring.** Run `compile obsidian neighbors "Source Title"`. The source note should be connected to at least one article or map page via outbound links or inbound backlinks from an article/map. If it isn't and a plausible target exists, return to step 7. If no target exists, explain why in the log entry.
9. **Companion artifact.** Consider a richer format using the triggers below. Offer the artifact when it would add durable value. Create it only when the user asks for it or explicitly agrees.
10. Run `compile obsidian refresh` and then `compile health`.
11. **Cross-source synthesis check.** Before ending the session, if you ingested more than one source, pause and ask: does the set make a claim, pattern, or tension visible that no single source makes visible? If yes, capture it inside the same local boundary when possible. If the right change would span a broader cluster, defer that work to `/synthesize`. If two sources materially disagree — on facts, norms, or framing — name the disagreement directly in prose in the relevant anchor article, citing both sources and the specific point of contention. Do not resolve disagreements by picking a winner, and do not use `> [!warning] Disagreement` callouts — write the disagreement as plain sentences so the article reads as a finished piece.

### PDF sources

PDF handling is best-effort.

- If your Claude client/session supports direct PDF or document understanding, prefer that for real comprehension.
- If not, use the extracted text from `compile ingest` as a starting point.
- If extraction fails, `compile ingest` creates a registration shell. Replace that shell with a proper source note after reading the raw document through whatever tool access is available.
- If a figure, chart, or relationship diagram is worth saving, use an explicit render command instead of relying on automatic media extraction:
  - `compile render chart` for quantitative visuals
  - `compile render canvas` for relationship structure
  - `compile render marp` for teaching or briefing artifacts

## Query Workflow

When answering questions against the wiki:

1. Classify the request before researching: brief lookup, synthesis, inventory/count, quote retrieval, audit/dedup, draft, absence check, or explicit artifact request.
2. Search the wiki first and read wiki pages before raw files.
3. Use the right evidence protocol:
   - Absence claims require both `compile obsidian search` and direct `rg`/file search across `wiki/` and `raw/`; state what you searched.
   - Inventory/count/dedup queries start with a broad aggregation pass (`rg -l`, `grep -rl`, `grep -rh "^sources:"`, `find`, `wc`) before candidate reads.
   - Quote/verbatim queries read the source note and raw source early when available.
   - Source-accounting queries read each named source note when it exists.
   - Modern technical/current topics outside the wiki should use WebSearch/WebFetch when current grounding would materially improve the answer.
4. Prefer `Read`, `Glob`, and `Grep` for file inspection; reserve Bash mainly for `compile` commands and broad aggregation shell commands. Do not use todo/planning tools for query answers.
5. Keep searches bounded: after a broad pass plus about five targeted searches, answer with the evidence gathered and offer to dig further if useful.
6. Always answer the user's question. The wiki is the preferred evidence base, not a hard boundary on what you can answer.
7. If the wiki partially covers the question, cite the supported claims with `[[wikilinks]]` and answer the unsupported remainder from web-backed or general knowledge, briefly noting that those parts are not in the wiki.
8. If the wiki does not cover the question at all, say that once up front and answer from web-backed or general knowledge anyway. Do not refuse just because a topic is outside the wiki, and do not fall back to knowledge-cutoff disclaimers when a normal answer would suffice.
9. Match the user's register. Brief/casual requests get concise prose and no save offer.
10. Choose persistence by destination, not ritual: offer to fold synthesis into an existing article/map, apply concrete audit fixes, delete/redirect duplicates, or iterate on drafts. Offer a new `output` page only when no better home exists and the answer is reusable.
11. When saving durable material, wire it into the existing wiki structure by updating the relevant article, map, index, or overview page rather than leaving it isolated.

## Lint Workflow

Periodically, or when asked:

1. Run `compile health --json-output`.
2. Run `compile obsidian inspect`.
3. Fix broken links, stale navigation, weak summaries, orphan pages, duplicate pages, and premature `stable` labels.
4. Run `compile obsidian refresh` after edits.

## Frontmatter Contract

Every maintained page should include:

```yaml
title: "Page Title"
type: article
status: seed
summary: "One-line description for index and overview."
created: 2026-04-07 00:00
updated: 2026-04-07 00:00
```

Optional when relevant: `tags`, `aliases`, `sources`, `source_ids`, `cssclasses`.

## Editorial Rules

1. Prefer updating over creating.
2. Keep source notes faithful to the source.
3. Make synthesis pages actually synthesize across sources.
4. State contradictions directly instead of smoothing them away.
5. Use `seed`, `emerging`, and `stable` honestly.
6. Save durable outputs back into the wiki.
7. Keep navigation current.
8. Verify quote-sensitive material against the raw source.
9. Keep map pages lightweight and navigational; use whatever structure helps readers browse the topic. A map should cover a coherent cluster — if it would group unrelated single-source themes into a "miscellaneous" bucket, log the gap and defer the map until a real cluster forms.
10. Surface disagreement. When two sources materially disagree — on factual claims, normative positions, or theoretical frameworks — name the disagreement directly in prose in the relevant article, citing both sources and the specific point of contention. Do not resolve the disagreement by picking a winner. Present both positions with their evidence or reasoning. Do not use `> [!warning] Disagreement` callouts; write disagreements as plain sentences so the article reads as a finished piece.
11. During `/ingest`, keep edits local: the source note plus 1–3 theme anchors. Use `/lint` or `/synthesize` for broader changes.
12. Render math as LaTeX, not Unicode. When rewriting source notes or synthesis pages, convert any Unicode math (superscripts like `ᵀ ⁺ ⁻`, subscripts like `ᵢ ₀`, operators like `Σ ∑ ∫ ∏ ≤ ≥ ≠ ∈ ∀ ∃ ∞`, Greek letters used as variables, etc.) into LaTeX wrapped in `$...$` for inline expressions or `$$...$$` for block expressions. PyMuPDF and Notion exports commonly emit Unicode math that Obsidian does not render — leaving it as raw Unicode produces unreadable notes. Do not leave mathematical expressions as raw Unicode in any maintained page.

## Status Discipline

Status is prompt-judged by you during ingest and lint, not machine-enforced. The health check flags the most egregious violations as a backstop, but you are responsible for honest assessment.

- `seed`: 0–1 sources, or a single line of evidence. Default for new articles.
- `emerging`: 2+ sources with partial synthesis. The page names its sources and attempts cross-source claims.
- `stable`: 3+ sources with genuine synthesis. The page names where sources agree, where they diverge, and what remains uncertain.

Source note status is always `stable` unless the note is a registration shell, has `review_status: needs_document_review`, or is too thin to support meaningful claims (e.g., an empty Notion stub). Thin source notes should be `seed` and kept short rather than padded; do not insert `> [!note]` callouts to flag thinness — the brevity of the note is itself the signal.

Do not mark an article `stable` unless it meets the definition. When in doubt, use `seed`. When you update an article and it now meets a higher bar, upgrade it.

When you need to change a page's status, use the low-level page writer with `--status seed|emerging|stable`. Rewriting the body alone preserves the existing status — do not rely on body edits to promote or demote a page.

## What Good Synthesis Looks Like

A good article:

- Opens with a framing question or thesis.
- Draws claims from multiple sources, citing each with `[[Source Title]]`.
- Names tensions or disagreements between sources rather than smoothing them.
- Identifies what remains uncertain or unresolved.
- Links to related articles and maps.

A bad article restates one source in different words and calls it synthesis. If your article could be written from a single source, it is a source note, not a synthesis page.
