# Rhizome

**Rhizome** is an LLM-maintained personal wiki for Obsidian. You feed it raw sources — PDFs, Notion pages, URLs, stray notes — and Claude does the reading, summarizing, cross-linking, and maintenance. Over time the wiki compounds: every ingested source and every saved answer makes it richer and better connected.

## Rhizome.app — the front door

The primary way to use Rhizome is **Rhizome.app**, a native macOS menu-bar companion. It gives you:

- **A query window.** Ask a question in plain English; Claude searches your wiki first, cites your own notes with `[[wikilinks]]`, and fills gaps from general knowledge when needed. Answers stream back as markdown tables, mermaid diagrams, and Obsidian callouts — not just paragraphs.
- **Follow-ups with session memory.** Each query thread is a resumable Claude session.
- **One-click shortcuts** to open the vault in Obsidian, jump to the Obsidian graph view, reveal the workspace in Finder, or drop into a Terminal at the workspace root.
- **A bundled CLI sidecar** (`compile-bin`, built with PyInstaller) that handles ingest, synthesis, rendering, and health checks — no separate Python install needed.
- **Auto-installed slash commands** (`/capture`, `/query`, `/context`, `/ingest`, `/lint`, `/synthesize`, `/notion-sync`, …) that Claude Code can invoke from any terminal session against your wiki.

Under the hood, Rhizome runs `claude -p` as an agentic research session against your workspace. In-app queries allow Bash, local search/read tools, Task subagents, and web search; direct edit/write tools are blocked. Query mode is answer-first: it searches the wiki by default, and it may save or render through `compile` only when you explicitly ask for an artifact or confirm a follow-up save/integration action.

## The Python CLI

`compile` is the tool Claude drives to do the actual work. You can also use it standalone from any terminal:

- `compile init` — scaffold a workspace
- `compile ingest <file>` — register a raw source and create a source note
- `compile obsidian search | page | neighbors` — programmatic wiki reads
- `compile render canvas | marp | chart` — explicit rich-output renderers
- `compile eval init | run` — manual headless query eval suites with judge-ready JSON output
- `compile health`, `compile obsidian refresh` — lint and reindex

---

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| [Obsidian](https://obsidian.md) | Browsing the vault | Download from obsidian.md |
| [Claude Code](https://docs.claude.com/en/docs/claude-code) | Slash commands (`/capture`, `/query`, `/context`, …) | `npm i -g @anthropic-ai/claude-code` |
| Xcode Command Line Tools | Swift 6 toolchain for the build | `xcode-select --install` |
| [`uv`](https://docs.astral.sh/uv/) | Bundles the Python CLI into the app | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

Claude Code must be authenticated (run `claude` once in any terminal) before the slash commands work.

---

## Build and install

```bash
git clone <this-repo>
cd rhizome
./scripts/build-rhizome-app.sh
cp -R dist/Rhizome.app /Applications/
open /Applications/Rhizome.app
```

The build is arm64-only and ad-hoc signed. If Gatekeeper blocks the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Rhizome.app
open /Applications/Rhizome.app
```

On first launch, Rhizome creates a default workspace at `~/wiki` called "Rhizome" and installs the Claude Code commands that target it. Rebuild and replace the app to pick up new changes.

---

## How it works

Three layers, one contract:

- **`raw/`** — your source documents. Immutable. Claude reads but never edits. PDFs, Notion exports, fetched URLs, pasted notes — all live here.
- **`wiki/`** — the LLM-maintained layer: source notes, articles, maps, outputs. Every page here is grounded in something from `raw/`.
- **`WIKI.md`** — the schema telling Claude how this wiki is structured, what status levels mean, and how to link pages together.

Pages are one of four types: `source` (provenance-anchored, one per raw file), `article` (cross-source synthesis), `map` (navigation hubs), `output` (saved answer, deck, chart, or canvas).

When you ingest a source, the source note embeds the full extracted text in a collapsed `> [!abstract]- Full extracted text` callout, so future queries can grep the real content — not just a synopsis.

### Slash commands

Use these from Rhizome.app or from a Claude Code session launched by the app:

| Command | What it does |
|---|---|
| `/capture` | Drop a thought or snippet into `~/wiki/raw/` and ingest it. Always targets the configured wiki. |
| `/query` | Search the wiki first, then answer any remaining gaps from general knowledge with citations where available. Uses the current workspace, or falls back to the configured wiki. |
| `/context` | Load wiki status, index, overview, and schema into the session. |
| `/ingest [source]` | Register a raw file or URL as a source note. Run from inside the workspace. |
| `/lint` | Audit: broken links, status honesty, dead-end notes, coverage gaps. |
| `/synthesize [theme]` | Connect accumulated sources into articles or maps. |
| `/notion-setup`, `/notion-sync` | Save a Notion scope, then pull matching pages into `raw/notion/`. |

You can hand-edit any of these at `<workspace>/.claude/commands/*.md` or `~/.claude/commands/*.md` — open them from Rhizome's Settings → Claude Commands. Your edits survive app restarts.

---

## Troubleshooting

- **Rhizome.app won't open** — `xattr -dr com.apple.quarantine /Applications/Rhizome.app`.
- **"Unable to locate bundled compile-bin"** — rebuild with `./scripts/build-rhizome-app.sh`.
- **"Obsidian is not installed"** — install from [obsidian.md](https://obsidian.md) and reopen.
- **Graph button is disabled** — install the Advanced URI plugin when prompted, then relaunch Obsidian.
- **`compile: command not found` from a slash command** — you ran Claude Code from a terminal Rhizome didn't launch. Start it from the app, or install the CLI standalone: `uv tool install /path/to/this/repo`.

---

## Development

```bash
uv sync
uv run pytest
uv run compile --help
swift test --package-path Rhizome
```

Set `RHIZOME_DEV_WORKSPACE=~/wiki` before running the build script to auto-sync template changes into your wiki on each build.

See [`CLAUDE.md`](CLAUDE.md) for the developer contract (product boundary, module map, release standard).
