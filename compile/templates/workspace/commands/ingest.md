Process a raw source into the wiki.

Argument: $ARGUMENTS (filename in `raw/`, a URL, or leave blank to process the next unprocessed file)

Use the workspace `CLAUDE.md` as the canonical workflow contract. Work through two phases. Phase A creates the source note. Phase B wires it into the wiki and is mandatory — do not stop after Phase A.

### Parallelism

Treat `/ingest` as phased work. You may batch independent read-only steps in one message when helpful, such as `compile obsidian search`, reading candidate pages, and reading raw sources. Serialize workspace writes: do not run multiple `compile ingest` commands in parallel, do not rewrite multiple anchor pages concurrently, and run `compile obsidian refresh` plus `compile health` once after the write phase is done.

### Phase A — Create and enrich the source note

1. If no argument is given, run `compile status` and pick the next unprocessed source. If the argument is a URL, use that URL directly. Otherwise use the provided `raw/` file.
2. Run `compile obsidian search` with key terms from the source to see what already exists.
3. Run `compile ingest <source>`, where `<source>` is the URL or `raw/` filename. For ugly PDF filenames, pass `--title "Proper Title"`.
4. Read the created source note. If the raw source is itself thin — an empty Notion stub, a stub page with no substantive content, a failed extraction shell — mark the note `status: seed` (using `compile obsidian upsert --status seed`) and carry into Phase B with whatever themes you can defensibly identify. Keep the note short rather than padding it; do not add a `> [!note]` callout to flag the gap.
5. Read the raw source itself when the note is weak, incomplete, or needs verification.
6. For substantial improvements, rewrite the source note in place using the low-level page writer with `--body-file`. Before you commit any `[[wikilink]]`: identify 1–3 broader themes for this source, run `compile obsidian search` for each, and apply the 3-source bar from Phase B — only write `[[Theme Anchor]]` when the anchor already exists or you will create one this pass. Otherwise refer to the theme by plain text. Write the body as continuous prose covering the source's main claims with a brief evidence-strength judgment and any material caveats. Do not add `## Themes`, `## Key Claims`, or `## Caveats` headed sections; fold them into the prose so the page reads as a short article.

### Phase B — Wire into the wiki

7. Locality guard: direct edits during `/ingest` are limited to the source note plus 1–3 theme anchors identified in Phase A. If the right fix would spread beyond those anchors into a broader cluster, defer it to `/lint` or `/synthesize`.
8. For each theme identified in Phase A:
   - If an article or map already covers it, treat that page as the anchor. **Use the `Edit` tool** on the anchor's `.md` file to surgically update the relevant paragraph or section — insert the new evidence, add the `[[Source Title]]` citation, or extend a list. Do not rewrite the whole anchor body to add one claim. Ensure a `[[wikilink]]` connects the source note and the article/map.
   - If no article exists but 3+ sources now touch the theme, create a `seed` article via `compile obsidian upsert --page-type article --status seed --body-file ...` and use that new page as the anchor for this ingest pass.
   - If fewer than 3 sources share the theme, log the gap and run `compile suggest maps` to check for existing hubs before creating anything new. Do not create a single-source map or back-fill `[[wikilinks]]` to anchors that will not exist.
9. Verify wiring with `compile obsidian neighbors "Source Title"`. The source note should be connected to at least one article or map page (outbound links, or backlinks from an article/map). If it isn't and a plausible target exists, return to step 8. If no target exists yet, document why in the log.
10. If two sources materially disagree, name the disagreement directly in prose in the relevant anchor article, citing both sources and the specific point of contention. Do not resolve it by picking a winner, and do not use `> [!warning] Disagreement` callouts — write the disagreement as plain sentences.

### Phase C — Artifacts, refresh, report

11. Consider a companion artifact using the format triggers in the workspace `CLAUDE.md`:
    - Source maps 4+ related concepts or actors → `compile render canvas`
    - Source contains quantitative data, trends, or distributions → `compile render chart`
    - Source is a tutorial, lecture, or walkthrough → `compile render marp`
    - Source describes a sequential process or argument flow → add a mermaid diagram in the source note
    Offer the artifact when it would add durable value. Create it only if the user asks for it or explicitly agrees.
12. Run `compile obsidian refresh`.
13. Run `compile health` and fix any issues.
14. Set article status honestly per the Status Discipline rules in the workspace `CLAUDE.md`. Upgrade articles whose body now clears a higher bar.
15. Report what changed: source note path, articles/maps updated or created, any disagreements named in prose, any gaps logged.
