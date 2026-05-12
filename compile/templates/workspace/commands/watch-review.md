Audit every active watch in the wiki and surface what should be tuned, paused, or pruned.

Argument: $ARGUMENTS (optional; a watch title or filter — leave blank to review all)

Use this command when watches have been running for a while and the user wants a sanity check. Watches drift: URLs go stale, intents become irrelevant, page bodies bloat with low-value digests, and the launchd schedule keeps running them anyway.

Workflow:

1. Run `compile watch list --json-output` and read every watch record. Note `watch_status`, `last_status`, `consecutive_failures`, `last_run`, and `next_run`.

2. For each watch, classify it into one of these buckets:
   - **Failing** — `watch_status: error` or `paused` because of `consecutive_failures >= 3`. The CLI auto-pauses these. Read `watch_last_error` and propose either a URL fix, an intent rewrite, or removal.
   - **Stale** — `last_status: unchanged` for many runs in a row. Suggest lowering the frequency (e.g. daily → weekly) or removing the watch if the source clearly does not change often enough to justify it.
   - **Bloated** — the page body is more than ~500 lines of digest history. Suggest archiving older digests to `wiki/watches/_archive/<slug>-<year>.md` or trimming the body manually.
   - **Misaligned** — read the most recent two or three digests and compare them to the watch's `intent`. If the synthesis is consistently off-target, propose an intent rewrite. Show the user the current intent and a proposed replacement.
   - **Healthy** — running, recent digests are useful, no action needed. Do not list these individually; just report the count.

3. Surface duplicates: two watches pointing at the same URL with overlapping intents. Suggest consolidating.

4. Surface coverage gaps: watches whose digests repeatedly cite the same wiki article. Those are good candidates for the article to absorb the watch's findings as its own section, with the watch downgraded to a lighter cadence.

5. Report a punch list: failing/stale/bloated/misaligned watches with a one-line recommendation each, and the count of healthy watches. Do not auto-apply changes — surface the recommendations and let the user decide which to apply via `compile watch pause`, `compile watch remove`, or by editing the page frontmatter directly in Obsidian.
