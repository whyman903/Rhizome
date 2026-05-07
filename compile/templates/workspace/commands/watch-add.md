Set up a recurring "watch" that pulls a URL on a schedule and synthesizes it against a user-supplied intent.

Argument: $ARGUMENTS (a free-form description of the watch the user wants — may include the URL, frequency, and intent in any order)

Use this command when the user asks for an "automated pull", "alert me", "watch this page", or "every day check X". The watch is implemented as a `watch`-type wiki page plus a recurring run via `compile watch tick`. Each successful run prepends a dated digest section to the page body and stores the raw fetched content under `raw/watches/<slug>/`.

Workflow:

1. Parse the user's request into three fields:
   - **URL** — the page or feed to fetch. If the user gave you a domain or fragment, ask them to confirm the exact URL before continuing. Do not invent or auto-correct URLs.
   - **Frequency** — `hourly`, `daily`, `weekly`, or a cron expression in the form `cron: <minute> <hour> <dom> <mon> <dow>`. The minimum cadence is hourly; reject anything sub-hour.
   - **Intent** — the user's plain-language description of *what to extract or synthesize* on each run. This is sent to Claude verbatim, so reflect the user's wording faithfully and ask a follow-up if it is ambiguous (e.g. "summarize for me" vs "give me 3 bullets ranked by significance"). Do not paraphrase a vague request into a confident instruction.

2. Confirm the parsed fields back to the user in one short sentence and ask any necessary follow-up. Avoid a long checklist — one or two questions is plenty. If the user already gave a complete spec, skip confirmation and proceed.

3. Run `compile watch add <url> --frequency <freq> --intent "<intent>"` (add `--title "..."` if the user gave one explicitly, otherwise let the CLI derive a title from the URL). The CLI will create the watch page under `wiki/watches/` with a UUID and the next-run timestamp.

4. Optionally run `compile watch run "<title>"` once to do an immediate first pull so the user can see what the synthesis looks like — only do this if the user agrees, since it consumes one Claude run.

5. Report:
   - The relative path of the new watch page so the user can open it in Obsidian.
   - The `next_run` timestamp.
   - A note that the watch will fire automatically (via the Mac app's launchd agent or the user's cron — see `README.md`) and that they can edit the URL/frequency/intent directly in the page frontmatter.

Do not create separate notes, tags, or maps for the watch unless the user asks. The watch page is self-contained.
