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
./scripts/build-rhizome-app.sh            # produces dist/Rhizome.app
swift test --package-path Rhizome         # Swift test suite
```

## Module Map

### Python CLI

- `compile/cli.py` — command surface and Claude setup/install logic.
- `compile/text.py` — source extraction and normalization.
- `compile/ingest.py` — source-note artifact assembly and rendering.
- `compile/obsidian.py` — vault scanning, search, upsert, and graph helpers.
- `compile/workspace.py` — workspace state, status, processing, and generated files.
- `compile/outputs.py` — explicit renderers for Marp, chart, and canvas outputs.
- `compile/fetch.py` — URL ingestion and optional image download for web sources.
- `compile/health.py` / `compile/verify.py` — structural and editorial health reporting.
- `compile/search_index.py` — SQLite FTS index for PDF chunks.
- `compile/templates/global/` — installed into `~/.claude/commands/` (context-aware commands available from any session).
- `compile/templates/workspace/` — installed into each wiki (`CLAUDE.md`, `.claude/commands/*.md`, `.claude/settings.local.json`).
- `compile/resources.py` — resolves template paths in both `uv tool` installs and the PyInstaller bundle.

### macOS app

- `Rhizome/Package.swift` — SwiftPM package definition (macOS 14+, arm64).
- `Rhizome/Sources/RhizomeApp/` — SwiftUI app (menu-bar extra + query window).
- `Rhizome/Sources/RhizomeCore/` — headless logic: `CompileRunner` (sidecar RPC), `ClaudeQueryRunner` (streaming `claude -p`), `AppModel`, `FeedStore`, `Obsidian` (URL scheme opener).
- `Rhizome/support/compile-bin.spec` — PyInstaller spec for the `compile-bin` sidecar.
- `Rhizome/support/Info.plist` / `AppIcon.icns` — bundle metadata.
- `scripts/build-rhizome-app.sh` — builds sidecar + Swift product, assembles and ad-hoc signs `dist/Rhizome.app`.

## Development Rules

- Prefer simple synchronous code and direct data flow over extra abstraction.
- Keep CLI behavior explicit. If a workflow is optional or lossy, document that honestly.
- Preserve backward compatibility only where it protects existing workspaces with low complexity.
- When you add a CLI command that needs Claude Code integration, add a template under `compile/templates/workspace/commands/` (or `global/` for cross-wiki commands) — the `compile claude setup` flow installs every file in those directories automatically.
- When you change a template, bump the matching behavior tests under `tests/test_claude_setup.py` and verify `compile claude setup --force` refreshes existing workspaces cleanly.
- The Swift layer assumes the sidecar emits stable JSON envelopes (`--json-output` / `--json-stream`). Before changing a command's JSON shape, grep `Rhizome/Sources/RhizomeCore/` for the matching decoder.

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
4. If templates changed, confirm `compile claude setup <existing-wiki> --force` produces the expected diff (no stray files, obsolete templates removed, settings merged).
5. If the Mac app changed, rebuild with `./scripts/build-rhizome-app.sh` and verify the bundle launches (`open dist/Rhizome.app`).
6. Confirm `README.md`, this file, and `compile/templates/workspace/CLAUDE.md` still reflect actual behavior.
