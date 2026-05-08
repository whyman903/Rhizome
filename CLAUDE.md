# Rhizome Developer Contract

This repository builds two things:

1. **`compile`** — a Python CLI for maintaining an Obsidian-backed wiki with LLM assistance.
2. **`Rhizome.app`** — a macOS menu-bar companion that wraps the CLI as a PyInstaller sidecar.

Both share the same templates under `compile/templates/` and the same workspace contract.

## Product Boundary

- `compile` manages workspace structure, source registration, best-effort plain-text extraction, Obsidian page maintenance, and explicit rich-output commands.
- Claude handles interpretation, synthesis, figure description, and deciding when a chart, canvas, or deck is worth saving.
- Do not reintroduce automatic figure extraction, managed figure blocks, `source packet`, or separate enrich flows unless there is a very strong product reason.
- The Mac app is a thin dispatcher: it shells out to the bundled `compile-bin` sidecar and routes Obsidian / Claude Code. Any new persistent behavior belongs in the CLI, not the Swift layer.

## Key Commands

```bash
# CLI
uv sync
uv run pytest
uv run compile --help
uv run compile init "Test Wiki" -p /tmp/test-wiki
uv run compile claude setup /tmp/test-wiki
uv run compile ingest example.md -p /tmp/test-wiki

# macOS app
./scripts/build.sh                        # produces dist/Rhizome.app and launches it
./scripts/build.sh --update               # also runs `compile claude setup --force`
                                          # against $RHIZOME_DEV_WORKSPACE (default ~/wiki)
swift test --package-path Rhizome         # Swift test suite
```

Set `RHIZOME_SKIP_LAUNCH=1` (or run under `CI`) to skip the post-build app launch.

## Module Map

### Python CLI (`compile/`)

- `cli.py` — Click command surface (`init`, `status`, `ingest`, `health`, `schema`, plus `obsidian`, `suggest`, `review`, `index`, `render`, `eval`, `watch`, `claude` subgroups).
- `config.py` — workspace config loader (`config.yaml`, `.env`, env-var overrides).
- `dates.py` — frontmatter / machine timestamp formatting.
- `text.py` — source extraction and normalization.
- `markdown.py` — wikilink, fence, callout, and frontmatter helpers shared across modules.
- `page_types.py` — canonical page-type, maturity, and output-format vocabularies.
- `ingest.py` — source-note artifact assembly and rendering.
- `pdf_artifacts.py` — cached PDF page extraction artifacts (`raw/.extracted/`).
- `obsidian.py` — vault scanning, search, upsert, and graph helpers.
- `workspace.py` — workspace state, status, processing, and generated files.
- `outputs.py` — explicit renderers for Marp, chart, and canvas outputs.
- `fetch.py` — URL ingestion and optional image download for web sources.
- `watch.py` — recurring URL pulls: frequency parsing, change-detection, claude synthesis, append-digest body editor, auto-pause on repeated failure. Page frontmatter is the source of truth; `.compile/watches.json` is a rebuilt scheduler index.
- `health.py` / `verify.py` — structural and editorial health reporting.
- `search_index.py` — SQLite FTS index for PDF chunks.
- `suggest.py` — map-page suggestion heuristics.
- `evals.py` — headless `claude -p` eval harness used by `compile eval init|run`.
- `resources.py` — resolves template paths in both `uv tool` installs and the PyInstaller bundle.
- `templates/global/` — installed into `~/.claude/commands/` (cross-wiki commands).
- `templates/workspace/` — installed into each wiki (`CLAUDE.md`, `.claude/commands/*.md`, `.claude/settings.local.json`).

### macOS app (`Rhizome/`)

- `Package.swift` — SwiftPM package (macOS 14+, depends on `swift-cmark` for the markdown renderer).
- `Sources/RhizomeApp/` — SwiftUI menu-bar app:
  - `RhizomeApp.swift`, `MenuBarIcon.swift`, `LauncherView.swift`, `SettingsView.swift`, `QueryDetailView.swift` — UI surface.
  - `MarkdownRenderer.swift`, `MarkdownContentView.swift`, `MarkdownHTMLPostprocessor.swift`, `MarkdownMathProtector.swift`, `EditorialTheme.swift`, `BundleAssetSchemeHandler.swift` — markdown → HTML pipeline served to a `WKWebView` with bundled KaTeX, Mermaid, and DOMPurify under `Resources/web/`.
- `Sources/RhizomeCore/` — headless logic:
  - `CompileRunning.swift` (protocol), `CompileRunner.swift` (sidecar RPC), `CompileEvent.swift` (streamed ingest events), `WorkspaceInfo.swift`, `WikiSearch.swift`, `WikilinkParser.swift`.
  - `ClaudeQueryRunner.swift` (streaming `claude -p`), `QuerySession.swift` (resumable threads), `ClaudeDispatcher.swift` (Terminal hand-off).
  - `AppModel.swift`, `FeedStore.swift`, `Obsidian.swift` (URL scheme opener), `TerminalLauncher.swift`, `AppLogger.swift`.
  - `WatchSidecar.swift` (RPC for `compile watch ...`), `WatchScheduler.swift` (registers the bundled `Contents/Library/LaunchAgents/app.rhizome.watch-tick.plist` via `SMAppService` and writes `~/Library/Application Support/Rhizome/active-workspace` so the static plist can locate the current workspace), `WatchRecord.swift` (Codable contract for the watch JSON envelopes).
- `Tests/RhizomeCoreTests/` and `Tests/RhizomeAppTests/` — Swift Testing suites covering the sidecar contract, query sessions, markdown rendering, and Obsidian/Terminal launch.
- `support/compile-bin.spec` — PyInstaller spec for the `compile-bin` sidecar.
- `support/Info.plist` / `AppIcon.icns` — bundle metadata.
- `support/LaunchAgents/app.rhizome.watch-tick.plist` — static SMAppService agent plist; copied into `Rhizome.app/Contents/Library/LaunchAgents/` by `scripts/build.sh`. Uses `BundleProgram` so launchd resolves `compile-bin` relative to the bundle, and reads the active workspace from the pointer file (no `--path` baked in).
- `scripts/build.sh` — builds sidecar + Swift product, assembles and ad-hoc signs `dist/Rhizome.app`.

## Development Rules

- Prefer simple synchronous code and direct data flow over extra abstraction.
- Keep CLI behavior explicit. If a workflow is optional or lossy, document that honestly.
- Preserve backward compatibility only where it protects existing workspaces with low complexity.
- When you add a CLI command that needs Claude Code integration, add a template under `compile/templates/workspace/commands/` (or `global/` for cross-wiki commands) — the `compile claude setup` flow installs every file in those directories automatically.
- When you change a template, bump the matching behavior tests under `tests/test_claude_setup.py` and verify `compile claude setup --force` refreshes existing workspaces cleanly.
- The Swift layer assumes the sidecar emits stable JSON envelopes (`--json-output` / `--json-stream`). Before changing a command's JSON shape, grep `Rhizome/Sources/RhizomeCore/` for the matching decoder (typically in `CompileRunner.swift`, `WorkspaceInfo.swift`, `WikiSearch.swift`, or `CompileEvent.swift`).

## Release Standard

Before finishing a change:

1. Run `uv run pytest`.
2. Run `swift test --package-path Rhizome` if the change touches Swift code or CLI JSON envelopes.
3. Smoke-test the start workflow in a scratch dir:
   ```bash
   uv run compile init "Smoke" -p /tmp/smoke
   uv run compile claude setup /tmp/smoke
   uv run compile status -p /tmp/smoke
   uv run compile health -p /tmp/smoke
   ```
4. If templates changed, confirm `compile claude setup <existing-wiki> --force` produces the expected diff (no stray files, settings merged).
5. If the Mac app changed, rebuild with `./scripts/build.sh` and verify the bundle launches (`open dist/Rhizome.app`).
6. Confirm `README.md`, this file, and `compile/templates/workspace/CLAUDE.md` still reflect actual behavior.
