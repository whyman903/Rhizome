Answer a question. Use the wiki first, then fill any gaps from web-backed or general knowledge. Save or render only when the user explicitly asks for an artifact, confirms a follow-up action, or the answer is clearly durable and has no better home.

Argument: $ARGUMENTS (the question to answer)

My wiki lives at: {{wiki_path}}

### Target workspace

Use one `/query` command everywhere:

1. First try the current working directory: run `compile status`.
2. If that succeeds, use the reported workspace root for every command and file read. If you are not already at that root, `cd` there before running follow-up commands.
3. If that fails because there is no workspace here, use the configured wiki:
   - Run compile commands as `cd "{{wiki_path}}" && compile ...`
   - Read files from `{{wiki_path}}/...`

Do not ask the user which command to use. Only ask a follow-up if both the current workspace and the configured wiki are unavailable.

### Workflow

1. **Classify the request before researching.**
   - Brief/casual lookup or callback ("what's the deal", "remind me", "couple sentences") → keep the answer short and do not offer to save.
   - Synthesis across wiki sources → answer, then offer to fold it into the best existing article/map when one exists.
   - Audit, status review, or duplicate cleanup → answer with findings, then offer the concrete fix (apply targeted fixes, delete/redirect duplicates), not an output page.
   - Drafting or wording request → provide the draft and offer iteration first; only discuss saving after the wording is accepted.
   - Explicit artifact request ("build/make/render/create me a deck/chart/canvas") → create the artifact immediately with the relevant `compile render ...` command, then report the created wiki path. Do not ask whether to save it again.
   - Ordinary durable answer with no existing anchor → offer a new `output` page only if it would be reusable later.

2. Run `compile obsidian search` with key terms from the question to find relevant pages.

3. Read the top few results with `compile obsidian page`. Follow `compile obsidian neighbors` if you need more context on how pages connect.

4. Use the right evidence protocol for the request.
   - For absence claims, run both `compile obsidian search` and direct `rg`/file search across `wiki/` and `raw/` for exact phrases, acronyms, expansions, and likely aliases. State what you searched before saying the wiki lacks coverage.
   - For inventory, count, list-all, and duplicate queries, use one broad aggregation pass first (`rg -l`, `grep -rl`, `grep -rh "^sources:"`, `find`, `wc`, or similar), dedupe paths, define the inclusion rule, then inspect candidates.
   - For quote, verbatim, or "in their own words" queries, read the source note and the raw source early when available. Do not rely only on extracted snippets for exact wording.
   - For source-accounting queries ("which sources support which moves"), read every named source note that exists; if you rely on a synthesis page instead, say so.
   - For modern technical/current topics not covered by the wiki, use `WebSearch`/`WebFetch` when current external grounding would materially improve the answer. If you do not search the web, avoid current-state claims.
   - Prefer `Read`, `Glob`, and `Grep` for file inspection. Reserve Bash mainly for `compile` commands and broad aggregation shell commands.
   - Keep searches bounded: after a broad pass plus about five targeted searches, answer with the evidence gathered and offer to dig further if useful.

5. Always answer the question. Use `[[wikilinks]]` for claims the wiki supports. If the wiki only partially covers the question, answer the rest from web-backed or general knowledge and briefly mark those claims as not in the wiki. If the wiki does not cover the question at all, say that once up front and then answer from web-backed or general knowledge. Do not refuse just because the topic is outside the wiki. Do not mention your knowledge cutoff or say you cannot answer because of your role.

6. **Choose output format.** Let the user's wording and content intent override eval slugs or internal labels. Check these triggers in order — use the first match:
   - Explicit request to build/make/render/create a deck, chart, or canvas → create that artifact immediately with `compile render ...`
   - Comparison of 3+ items on shared dimensions → table, or `compile render chart` if the user explicitly requested a chart artifact
   - Relationships between 4+ concepts, causal chains, actor maps, or dependencies → Mermaid in the answer, unless the user explicitly requested a saved canvas
   - Sequential process, argument flow, or small hierarchy (3–15 nodes) → mermaid diagram in the answer
   - Teaching explanation or presentation request → structured prose or Mermaid; use `compile render marp` only when the user asks to build a deck
   - Quantitative data, trends, or distributions → table or inline recommendation; use `compile render chart` only when the user asks for a chart artifact
   - None of the above → standard text, with `[[wikilinks]]` only where the wiki supports a claim
   Use callouts (`> [!note]`, `> [!warning]`, `> [!question]`) for key insights, caveats, or definitions when they add clarity. For math, use LaTeX math notation, not Unicode math symbols.

7. Present the answer in the right register. Match brief or casual wording with concise prose. Do not use todo/planning tools; answer directly.

8. **Persistence and follow-up action.** Do not use a generic save offer. Choose one:
   - Existing article/map is the right home → ask whether to fold the answer into `[[Existing Article]]`.
   - Audit/dedup/status findings → ask whether to apply the targeted fixes or delete/redirect the duplicate.
   - Drafting → ask whether to revise the wording, shorten it, or change the angle.
   - Explicit artifact request already rendered → report the created path and stop.
   - No good anchor but answer is durable → ask whether to save it as a new `output` page.
   - Brief/casual/absence/simple lookup → no save offer.

9. If the user confirms a save/integration action:
   - For canvas: write node JSON to `/tmp/nodes.json` (and optional edges to `/tmp/edges.json`) and use `compile render canvas ... --nodes-file /tmp/nodes.json`.
   - For Marp: write slide markdown to `/tmp/deck.md` and use `compile render marp ... --body-file /tmp/deck.md`.
   - For chart: write the matplotlib script to `/tmp/chart.py` and use `compile render chart ... --script-file /tmp/chart.py`.
   - Render commands create and log the output page automatically. Run `compile obsidian refresh` and `compile health`.
   - For plain markdown output: write the answer to a temporary file, then save it as an `output` page using the low-level page writer (`compile obsidian upsert "Answer Title" --page-type output --body-file /tmp/answer.md`). Run `compile obsidian refresh` and `compile health`, then append to log.
