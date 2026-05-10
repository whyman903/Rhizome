Sync Notion notes into the wiki using the connected Notion tools available in this Claude session.

Argument: $ARGUMENTS (optional temporary scope override; leave blank to use `.compile/notion-sync-profile.json`)

### Parallelism

Treat `/notion-sync` as two phases. You may batch independent read-only discovery work and per-page Notion fetches for distinct page IDs in one message. It is also safe to write distinct `raw/notion/<page_id>.md` snapshots in parallel. Serialize the wiki-write phase: after the raw snapshots are written, run `compile ingest raw/notion/<page_id>.md` one page at a time, then run `compile obsidian refresh` and `compile health` once at the end.

Workflow:

1. Confirm that Notion connector tools are available in this session. If they are not, stop and tell the user to connect Notion in Claude first.
2. Load `.compile/notion-sync-profile.json` if it exists.
   - If `$ARGUMENTS` is present, use it as a temporary scope override for this run.
   - If there is no saved profile and no argument, stop and ask the user to run `/notion-setup` first.
3. Determine the effective scope:
   - `scope_prompt`: from `$ARGUMENTS` or the saved profile
   - `query`: from the saved profile, or blank to mean all accessible shared pages
   - `include_page_ids` / `exclude_page_ids`: from the saved profile
4. Enumerate candidate Notion pages using the connected search tools.
   - If `query` is blank, search across all accessible shared pages.
   - If `query` is set, use it to narrow scope.
   - Also include any `include_page_ids` even if they are not returned by the current search.
   - Exclude any page IDs listed in `exclude_page_ids`.
5. For each selected page:
   - Compute `raw/notion/<page_id>.md`.
   - If the file already exists, read the provenance comments near the top and compare `notion_last_edited_time` to the current Notion value.
   - Skip unchanged pages.
   - For new or changed pages, fetch the full page content through the Notion tools and write markdown that preserves the original content faithfully.
   - Collect the raw paths that were newly written or updated so they can be ingested after the snapshot phase finishes.
6. Every synced raw file must begin with these provenance comments:

```md
<!-- source: notion -->
<!-- notion_page_id: <uuid> -->
<!-- notion_page_url: <url> -->
<!-- notion_last_edited_time: <iso8601> -->
<!-- notion_synced_at: <iso8601> -->

# <Title>

<body>
```

7. After the snapshot phase finishes, run this command serially for each new or changed file:

```bash
compile ingest raw/notion/<page_id>.md
```

8. Let `compile ingest` handle source-note creation and refresh. It stores `notion_page_id`, `notion_url`, and `notion_last_edited_time` in source-note frontmatter so unchanged imports are preserved instead of rewritten. If a user has removed `notion_page_id` from the source note frontmatter, treat that note as user-claimed and leave it alone.
9. At the end, after all serial ingest calls finish:
   - Run `compile obsidian refresh`
   - Run `compile health`
   - Report discovered, new, updated, unchanged, stale, and failed items
10. Stale handling:
   - Compare the page IDs returned this run with the existing files in `raw/notion/`
   - Do not delete anything automatically
   - Report files whose page IDs were not seen this run as stale for manual review

Important:

- Preserve Notion content faithfully. Do not summarize or paraphrase while writing raw snapshots.
- Keep attachments and images as links; do not download them automatically.
- Continue on per-page failures and report them at the end.
- If the user wants this automated, suggest scheduling this command in Claude Code after the interactive run works.
