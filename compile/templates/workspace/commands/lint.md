Audit the wiki and fix quality issues.

Work through three phases. The structural audit is mechanical. The editorial audit is prompt-judged and is where most real quality improvements happen. The refresh-and-report closes the loop.

### Phase 1 — Structural audit

1. Run `compile health --json-output` and read the full report. Note every issue, and note the editorial metrics (`source_to_knowledge_page_ratio`, `knowledge_page_count`, `source_notes_without_topic_anchors`). "Knowledge page" covers any synthesis page type (`article`, `concept`, `entity`, etc.), not just those with `type: article`.
2. Run `compile obsidian inspect` for graph-level problems: orphans, thin pages, unresolved links, stale navigation.
3. Run `compile suggest maps` when source notes appear disconnected from the main article/map layer.
4. For each structural issue found, fix it. **Default to the `Edit` tool** for narrow repairs on an existing page (fixing a link, adding a wikilink, tightening a summary line, appending a citation, inserting a callout). Reserve `compile obsidian upsert` for status/tag changes (`--status`, `--tag`), creating a missing target page, or a deliberate whole-body rewrite.
   - **Unresolved links**: read the page with `compile obsidian page`, then use `Edit` to fix the link text, or create the missing target if appropriate.
   - **Orphan pages**: use `Edit` on related pages to add incoming links, or merge the orphan into a parent page if it is too thin to stand alone.
   - **Thin pages**: read them, then either use `Edit` to expand in place with real content or merge into a related article.
   - **Stale navigation**: run `compile obsidian refresh`.
   - **Malformed summaries**: read the page and use `Edit` to fix the `summary:` frontmatter line or the opening summary paragraph.
   - **Source notes without article/map anchors**: use `Edit` on an existing article or map to add a `[[wikilink]]` to the source, or create a lightweight map page if the broad topic clearly lacks a hub. If the problem is systemic — many unanchored sources sharing a theme — run `/synthesize` instead of wiring them one at a time.

### Phase 2 — Editorial audit

Per the workspace `CLAUDE.md`, status is prompt-judged, not machine-enforced. The structural audit only catches the most egregious violations. Use this phase to do the honest assessment.

5. **Status honesty sweep.** For each article, count its source references by reading the page body — both `[[wikilinks]]` to source notes and prose citations. Check the status against the Status Discipline rules:
   - 0–1 sources → `seed`
   - 2+ sources with partial cross-source synthesis → `emerging`
   - 3+ sources with genuine synthesis naming agreements, disagreements, and uncertainty → `stable`
   Upgrade or downgrade as needed. Articles mislabeled `stable` are the most common failure mode; demote them without hesitation.
6. **Coverage gap detection.** Identify themes that have 3+ unanchored source notes and no article or map. Either create a `seed` article or map, or add the gap to the report as a candidate for `/synthesize`.
7. **Disagreement sweep.** For articles with 2+ sources, read the article and its sources. If sources materially disagree — on facts, norms, or framing — and the disagreement is not already surfaced, add a `> [!warning] Disagreement` callout naming both sources and the specific point of contention.
8. **Dead-end source sweep.** Find source notes that are not connected to any article or map (no outbound wikilinks to one, no inbound backlinks from one). For each, either wire it into the appropriate article, create a `seed` article if the theme now has 3+ sources, or document in the report why it legitimately stands alone.
9. **Article quality pass.** For each article, check:
   - Does it synthesize or just paraphrase one source? A paraphrase is a source note mislabeled.
   - Are there missing `[[wikilinks]]` where related pages exist?
   - Are there claims that newer sources have superseded?

### Phase 3 — Refresh and report

10. Run `compile obsidian refresh` after all fixes.
11. Run `compile health --json-output` again. Plain `compile health` shows the headline metrics (knowledge pages, source-to-knowledge-page ratio, unanchored sources), but the JSON output is what you need to verify structural issues are resolved and to pull the counts for the report.
12. Report:
    - **Structural**: issues found, issues fixed.
    - **Editorial**: status changes made, disagreements surfaced, dead-end sources wired, coverage gaps identified.
    - **Wiki Quality Snapshot**: knowledge page count, source-to-knowledge-page ratio, percentage of source notes anchored (compute from `source_notes_without_topic_anchors` and the source count in the JSON), status distribution across articles (count by reading the pages — the JSON does not aggregate this), disagreements surfaced this pass.
    - **Remaining gaps**: themes that need `/synthesize`, or anything that needs user input.
