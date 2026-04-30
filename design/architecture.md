# Architecture

The repo is a two-surface product built around one contract: a local Obsidian vault with a strict layout, maintained by an LLM that drives a Python CLI.

## Layered diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                           USER SURFACES                              │
│                                                                      │
│   Claude Code CLI    Rhizome.app     Terminal      Obsidian.app       │
│   (slash commands)   (menu-bar)     (raw CLI)     (vault browser)    │
└────────┬─────────────────┬──────────────┬────────────────┬───────────┘
         │                 │              │                │
         ▼                 ▼              │                │
┌──────────────────────────────────────┐  │                │
│           INTEGRATION GLUE           │  │                │
│                                      │  │                │
│  • slash-command templates           │  │                │
│      ~/.claude/commands/             │  │                │
│      <wiki>/.claude/commands/        │  │                │
│  • compile-bin (PyInstaller sidecar) │  │                │
│  • claude -p (stream-json protocol)  │  │                │
│  • obsidian:// URL scheme  ──────────┼──┼────────────────┤
└───────────────┬──────────────────────┘  │                │
                │                         │                │
                ▼                         ▼                │
┌──────────────────────────────────────────┐               │
│          PYTHON CLI — compile/           │               │
│                                          │               │
│   cli.py  (Click entry)                  │               │
│                                          │               │
│   workspace    obsidian     ingest       │               │
│   text         fetch        outputs      │               │
│   health       verify       suggest      │               │
│   search_index   pdf_artifacts           │               │
│   resources    templates/                │               │
└───────────────┬──────────────────────────┘               │
                │                                          │
                ▼                                          ▼
┌──────────────────────────────────────────────────────────────┐
│            WORKSPACE ON DISK — ~/wiki                        │
│                                                              │
│   raw/              immutable source artifacts               │
│   wiki/                                                      │
│     articles/       durable synthesis                        │
│     sources/        provenance-anchored notes                │
│     maps/           navigation pages                         │
│     outputs/        rendered Marp / chart / canvas           │
│     index.md        catalog                                  │
│     overview.md     landing                                  │
│     log.md          append-only chronology                   │
│   WIKI.md           per-wiki editorial schema                │
│   .compile/         config · state · PDF FTS index           │
│   .claude/          installed slash commands                 │
│   .obsidian/        Obsidian config + plugins                │
└──────────────────────────────────────────────────────────────┘
```

## Swift package — Rhizome.app internals

```
┌──────────────────────────────────────────────────────────────┐
│            Rhizome.app — Swift package                        │
│                                                              │
│   RhizomeApp.swift        Window + MenuBarExtra               │
│        │                                                     │
│        ▼                                                     │
│   AppModel (@Observable)                                     │
│        │                                                     │
│        ├─►  CompileRunner          compile-bin JSON RPC      │
│        ├─►  ClaudeQueryRunner      claude -p stream-json     │
│        ├─►  TerminalDispatcher     Terminal.app + claude     │
│        ├─►  Obsidian.swift         obsidian:// URLs          │
│        ├─►  FeedStore              persisted ingest log      │
│        └─►  QuerySession           streaming query state     │
│                                                              │
│   Views:  LauncherView · QueryDetailView ·                   │
│           MarkdownContentView · SettingsView                 │
└──────────────────────────────────────────────────────────────┘
```

## The system in one paragraph

`compile` is a Python CLI that owns an Obsidian-compatible directory (a "workspace") with a strict layout: immutable `raw/` inputs, LLM-curated `wiki/` pages (sources, articles, maps, outputs), a per-wiki `WIKI.md` editorial schema, and `.compile/` runtime state. The CLI does deterministic work — extraction, page upsert, link scanning, health checks, rich-output rendering — and **never** synthesizes. Synthesis is delegated to Claude Code, which is wired into the workspace via templated slash commands that shell out to `compile`. `Rhizome.app` is a thin Swift menu-bar shell that embeds `compile` as a PyInstaller sidecar (`compile-bin`), streams `claude -p` responses inline for queries, opens the vault in Obsidian via the URL scheme, and hands off heavier work (ingest, Terminal-based Claude sessions) to the CLI.

## The three layers of the contract (from `CLAUDE.md`)

1. **`compile` CLI** — structure, extraction, page writes, health. Deterministic.
2. **Claude** — reads, synthesizes, decides when a chart/canvas/deck is worth saving. Calls the CLI.
3. **Swift app** — dispatcher only. Any new persistent behavior belongs in the CLI.

## Python CLI surface (`compile/cli.py`)

Grouped Click commands:

| Group | Commands |
|---|---|
| top-level | `init`, `status`, `ingest`, `health`, `schema` |
| `obsidian` | `inspect`, `search`, `page`, `neighbors`, `graph`, `cleanup`, `refresh`, `upsert` |
| `suggest` | `maps` |
| `review` | `mark-reviewed` |
| `index` | `rebuild` (SQLite FTS over PDF chunks) |
| `render` | `marp`, `chart`, `canvas` |
| `claude` | `setup` (installs templates into `~/.claude/` and `<wiki>/.claude/`) |

Most commands accept `--json-output` so the Swift layer can parse stable envelopes.

## Two primary workflows

### Ingest (add a source)

```
raw file / URL
   │
   ├─► /ingest slash command  (Claude Code)
   │     ├─ compile ingest <path>    → extracts text, registers provenance, writes first-pass source note
   │     ├─ Claude reads note + raw, rewrites with Themes + Key Claims
   │     ├─ Claude wires source into article/map (Phase B locality guard: ≤3 anchor pages)
   │     ├─ compile obsidian upsert / refresh
   │     └─ compile health
   │
   └─► Rhizome.app "Ingest" panel → TerminalClaudeDispatcher → claude in Terminal (same flow)
```

### Query (ask the wiki)

```
question
   │
   ├─► /query
   │     └─ compile obsidian search → page → neighbors → answer with [[wikilinks]] → optional render/upsert
   │
   └─► Rhizome.app query window
         └─ ClaudeQueryRunner runs `claude -p --output-format stream-json`
            with a wiki system-prompt addendum, streams events into QuerySession
```

## Template system

`compile/templates/` is the seam between CLI and Claude:

- `global/*.md` → copied into `~/.claude/commands/` (context-aware commands: `capture`, `query`, `context`)
- `workspace/commands/*.md` → copied into `<wiki>/.claude/commands/`
- `workspace/CLAUDE.md` → copied into `<wiki>/CLAUDE.md` (the Wiki Maintainer Contract)
- `workspace/settings.local.json` → merged, not overwritten

`compile claude setup --force` is the refresh path; `resources.py` resolves templates from either a `uv tool` install or inside the PyInstaller bundle.

## macOS app internals

- `RhizomeApp.swift` — declares a `Window` (query UI) + `MenuBarExtra` (LauncherView) Scene.
- `AppModel` — `@Observable` state holder; owns workspace info, query session, query history, feed store, theme/font prefs.
- `CompileRunner` — runs `compile-bin` with `--json-output`, decodes typed envelopes (`WorkspaceEnvelope`, `SearchEnvelope`, `PageEnvelope`).
- `ClaudeQueryRunner` — spawns `claude -p --output-format stream-json`, parses events into `ClaudeQueryEvent` cases (assistantText, toolCall, toolResult, finished, failed).
- `TerminalClaudeDispatcher` — for non-streaming flows, launches Terminal.app in the vault directory with `claude` and ⌘V-pastes a pending prompt.
- `Obsidian.swift` — reads `~/Library/Application Support/obsidian/obsidian.json`, installs the Advanced URI plugin on demand, opens notes / graph via `obsidian://` URLs.
- `FeedStore` — persisted log of dispatched ingest items.
- `scripts/build-rhizome-app.sh` — PyInstaller → `swift build -c release` → assemble `dist/Rhizome.app` → ad-hoc sign.

## Key design invariants

- `raw/` is immutable; Claude reads but never writes.
- The CLI never makes interpretive judgments — Claude decides *when* a Marp deck, chart, or canvas is worth saving; `outputs.py` is just the executor that runs once Claude invokes `compile render …` with prepared content.
- Nothing is generated unsolicited. Automatic figure extraction, `source packet`, and background enrich passes are intentionally absent (the CLAUDE.md flags them as removed).
- JSON envelopes between Swift and the sidecar are a versioned contract — the dev rules require grepping `RhizomeCore/` before changing them.
- Status (`seed`/`emerging`/`stable`) is prompt-judged by Claude, not machine-enforced — `compile health` just flags egregious violations.
