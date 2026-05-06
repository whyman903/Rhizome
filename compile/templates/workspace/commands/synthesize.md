Deliberately connect accumulated source notes into articles or maps.

Argument: $ARGUMENTS (an optional theme name to focus on; leave blank to pick the largest unconnected cluster)

Use this command to catch up after ingests that left source notes stranded, or when the source-to-knowledge-page ratio has drifted and the wiki stopped compounding. Follow the workspace `CLAUDE.md` editorial rules, especially Status Discipline and rule 10 on surfacing disagreement.

This is where broader edits belong. `/ingest` is intentionally local: the source note plus 1–3 theme anchors. Use `/synthesize` when the right fix spans a larger cluster, but keep each pass bounded to one chosen theme or cluster.

Workflow:

1. Run `compile health --json-output` and note `source_to_knowledge_page_ratio`, `knowledge_page_count`, and `source_notes_without_topic_anchors`. (A "knowledge page" is any synthesis page: `article`, `concept`, `entity`, `question`, `note`, `person`, `place`, or `timeline`.) A ratio above ~4:1 with many unanchored sources is a signal that synthesis is behind.
2. Run `compile suggest maps` to surface existing hub candidates for unanchored sources.
3. Pick a target:
   - If `$ARGUMENTS` is given, focus on that theme.
   - Otherwise, identify the largest cluster of unconnected source notes that share a theme. Prefer clusters with 3+ sources — they justify a synthesis page.
   - Stay inside that chosen theme or cluster for this pass. If you notice adjacent cleanup work outside it, note it for later rather than expanding scope mid-pass.
4. For each source in the target cluster: read the source note, confirm the theme fits, and check whether an existing article or map already covers it.
5. Create or update the synthesis:
   - If an article exists, **use the `Edit` tool** on its `.md` file to integrate claims from each source into the relevant section — add new `[[Source Title]]` citations, extend the disagreement prose, or tighten a specific claim. Do not regenerate the whole article body unless it is genuinely broken and warrants a deliberate full rewrite via `compile obsidian upsert --body-file ...`.
   - If no article exists and the cluster has 3+ sources, create a new `seed` article via `compile obsidian upsert --page-type article --status seed --body-file ...`. Open with a framing question or thesis. Name agreements, disagreements, and remaining uncertainty.
   - If the cluster has 5+ sources, also consider a map page as a navigational hub.
6. Wire each source note to the synthesis. Ensure either the source note links out to the article/map or the article cites the source with `[[Source Title]]`. Verify with `compile obsidian neighbors`.
7. Surface disagreement. If sources in the cluster materially disagree, add a `> [!warning] Disagreement` callout naming both sources and the specific point of contention. Do not resolve it by picking a winner.
8. Set status honestly per Status Discipline in the workspace `CLAUDE.md`. A fresh synthesis with 3+ sources that names tensions and uncertainty is usually `emerging`. Reserve `stable` for articles that genuinely synthesize and hold up under scrutiny.
9. Run `compile obsidian refresh` and `compile health --json-output` to confirm the ratio moved and the cluster is now anchored. Plain `compile health` surfaces the headline numbers (ratio, unanchored source count), but for a detailed verification of which sources are still unanchored you need the JSON.
10. Report: sources connected, articles/maps created or updated, disagreements surfaced, remaining unanchored clusters, and suggested next themes to synthesize.
