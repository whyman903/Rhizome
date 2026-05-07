from __future__ import annotations

import json
from pathlib import Path
import re
from typing import Any, Callable
from uuid import uuid4

import click
from rich.console import Console
from rich.table import Table

from compile.config import load_config
from compile.dates import now_frontmatter
from compile.evals import (
    EvalSuiteError,
    build_run_output_path,
    load_eval_suite,
    run_eval_suite,
    write_run_output,
    write_starter_suite,
)
from compile.fetch import fetch_url
from compile.ingest import (
    build_ingest_artifact,
    render_full_text_callout,
    render_source_body,
)
from compile.obsidian import ObsidianConnector
from compile.outputs import generate_canvas, generate_chart, generate_marp
from compile.pdf_artifacts import (
    align_artifact_raw_path,
    build_pdf_artifact,
    compute_sha256,
    extracted_source_from_artifact,
    load_pdf_artifact,
    load_pdf_artifact_path,
    save_pdf_artifact,
)
from compile.resources import resource_path
from compile.search_index import (
    rebuild_search_index,
    search_index_exists,
    search_pdf_index,
    sync_pdf_search_index,
)
from compile.suggest import suggest_map_updates
from compile.text import extract_source, is_url, sanitize_raw_filename, title_from_path
from compile.workspace import (
    append_log_entry,
    collect_pages_by_type,
    get_status,
    init_workspace,
    mark_processed,
    read_schema,
    write_index,
    write_overview,
)

console = Console()
IngestEventCallback = Callable[[dict[str, Any]], None]


def _load_workspace():
    try:
        return load_config()
    except FileNotFoundError:
        console.print("[red]No workspace found. Run 'compile init' first.[/red]")
        raise SystemExit(1)


def _iter_managed_templates(directory: Path) -> list[Path]:
    if not directory.is_dir():
        raise FileNotFoundError(f"Claude template directory not found: {directory}")
    return sorted(path for path in directory.iterdir() if path.is_file())


def _emit_json(payload: dict[str, Any]) -> None:
    click.echo(json.dumps(payload, sort_keys=True))


def _workspace_payload(config, info: dict[str, Any] | None = None) -> dict[str, Any]:
    info = info or get_status(config)
    return {
        "path": info["workspace_root"],
        "topic": info["topic"],
        "description": info["description"],
        "rawFiles": info["raw_files"],
        "processed": info["processed"],
        "unprocessed": info["unprocessed"],
        "needsDocumentReview": info["needs_document_review"],
        "wikiPageCount": info["wiki_pages"],
        "watches": info.get("watches", 0),
        "watchesActive": info.get("watches_active", 0),
        "watchesPaused": info.get("watches_paused", 0),
        "watchesFailing": info.get("watches_failing", 0),
    }


def _emit_ingest_event(event_callback: IngestEventCallback | None, payload: dict[str, Any]) -> None:
    if event_callback is not None:
        event_callback(payload)


def _emit_machine_error(message: str, *, context: str | None = None) -> None:
    payload: dict[str, Any] = {"ok": False, "error": message}
    if context:
        payload["context"] = context
    _emit_json(payload)


def _merge_settings_values(existing, template):
    if isinstance(existing, dict) and isinstance(template, dict):
        merged = dict(existing)
        for key, template_value in template.items():
            if key in merged:
                merged[key] = _merge_settings_values(merged[key], template_value)
            else:
                merged[key] = template_value
        return merged
    if isinstance(existing, list) and isinstance(template, list):
        merged = list(existing)
        seen = {json.dumps(item, sort_keys=True) for item in existing}
        for item in template:
            marker = json.dumps(item, sort_keys=True)
            if marker in seen:
                continue
            merged.append(item)
            seen.add(marker)
        return merged
    return existing


def _find_source_page_by_title(connector: ObsidianConnector, title: str):
    exact_matches = [
        hit for hit in connector.search(title, page_type="source", limit=10)
        if hit.title == title
    ]
    if len(exact_matches) > 1:
        raise ValueError(
            f"Multiple source pages titled '{title}' exist. "
            "Resolve the duplicate titles before ingesting again."
        )
    if exact_matches:
        return connector.get_page(exact_matches[0].relative_path)
    return connector.find_source_page_by_locator(title)


def _humanize_source_label(value: str) -> str:
    cleaned = value.replace("-", " ").replace("_", " ").strip()
    cleaned = re.sub(r"\s+", " ", cleaned)
    return cleaned.title() or "Source"


def _candidate_source_titles(base_title: str, raw_relative: str):
    relative = Path(raw_relative).with_suffix("")
    parts = list(relative.parts)
    if parts and parts[0].lower() == "raw":
        parts = parts[1:]
    parents = parts[:-1]
    labels: list[str] = []
    for parent in reversed(parents):
        labels.insert(0, _humanize_source_label(parent))
        yield f"{base_title} ({' - '.join(labels)})"
    for index in range(2, 100):
        yield f"{base_title} ({index})"


def _resolve_source_title(
    connector: ObsidianConnector,
    *,
    desired_title: str,
    raw_relative: str,
):
    # Primary key: raw source path.  One raw file → one source page.
    existing_by_path = connector.find_source_page_by_raw_path(raw_relative)
    if existing_by_path is not None:
        return desired_title, existing_by_path

    # Fallback: title-based disambiguation (for new sources).
    existing_page = _find_source_page_by_title(connector, desired_title)
    if existing_page is None:
        return desired_title, None

    # Title is taken by a different source — disambiguate.
    for candidate in _candidate_source_titles(desired_title, raw_relative):
        candidate_page = _find_source_page_by_title(connector, candidate)
        if candidate_page is None:
            return candidate, None

    raise ValueError(f"Could not find a unique source title for '{desired_title}'.")


def _should_refresh_existing_source_page(page, *, extra_frontmatter: dict[str, str] | None = None) -> bool:
    notion_page_id = str((extra_frontmatter or {}).get("notion_page_id") or "").strip()
    if not notion_page_id:
        return False
    return str(page.frontmatter.get("notion_page_id") or "").strip() == notion_page_id


def _ingest_raw_source(
    config,
    *,
    raw_path: Path,
    title: str | None = None,
    job_id: str | None = None,
    event_callback: IngestEventCallback | None = None,
):
    connector = ObsidianConnector(config.workspace_root)
    raw_relative = str(raw_path.relative_to(config.workspace_root)).replace("\\", "/")
    preloaded_extracted = None
    pdf_artifact = None
    extra_frontmatter = _extract_source_provenance_frontmatter(raw_path)
    if raw_path.suffix.lower() == ".pdf":
        desired_title = title or title_from_path(raw_path)
    else:
        _emit_ingest_event(
            event_callback,
            {
                "event": "extracting",
                "id": job_id,
                "raw_path": raw_relative,
                "source": raw_path.name,
            },
        )
        preloaded_extracted = extract_source(raw_path)
        desired_title = title or preloaded_extracted.title
    effective_title, existing_source_page = _resolve_source_title(
        connector,
        desired_title=desired_title,
        raw_relative=raw_relative,
    )

    if (
        existing_source_page is not None
        and _should_preserve_existing_source_page(existing_source_page)
        and not _should_refresh_existing_source_page(
            existing_source_page,
            extra_frontmatter=extra_frontmatter,
        )
    ):
        if raw_path.suffix.lower() == ".pdf":
            _refresh_pdf_index_for_source_page(
                config,
                raw_path=raw_path,
                raw_relative=raw_relative,
                page=existing_source_page,
            )
        mark_processed(config, raw_path, [existing_source_page.relative_path])
        _emit_ingest_event(
            event_callback,
            {
                "event": "preserved",
                "id": job_id,
                "note_path": existing_source_page.relative_path,
                "raw_path": raw_relative,
                "source": raw_path.name,
            },
        )
        return {
            "status": "preserved",
            "page": existing_source_page,
            "artifact": None,
            "metadata_only": False,
            "needs_document_review": False,
        }

    if preloaded_extracted is not None:
        extracted = preloaded_extracted
    else:
        _emit_ingest_event(
            event_callback,
            {
                "event": "extracting",
                "id": job_id,
                "raw_path": raw_relative,
                "source": raw_path.name,
            },
        )
        extracted, pdf_artifact = _extract_for_ingest(config, raw_path, raw_relative)
    artifact = build_ingest_artifact(
        raw_relative=raw_relative,
        extracted=extracted,
        connector=connector,
        title=effective_title,
    )
    pin_path: str | None = None
    if existing_source_page is not None:
        if effective_title == existing_source_page.title:
            pin_path = existing_source_page.relative_path
        else:
            old_file = config.workspace_root / existing_source_page.relative_path
            if old_file.exists():
                old_file.unlink()
    merged_frontmatter = _source_review_frontmatter(extracted) or {}
    if extra_frontmatter:
        merged_frontmatter.update(extra_frontmatter)
    page = connector.upsert_page(
        title=artifact.title,
        body=render_source_body(artifact),
        page_type="source",
        summary=artifact.page_summary,
        sources=[raw_relative],
        relative_path=pin_path,
        extra_frontmatter=merged_frontmatter or None,
    )
    _emit_ingest_event(
        event_callback,
        {
            "event": "source_note_written",
            "id": job_id,
            "note_path": page.relative_path,
            "raw_path": raw_relative,
            "source": raw_path.name,
            "status": "updated" if existing_source_page is not None else "created",
        },
    )

    if not artifact.metadata_only:
        mark_processed(config, raw_path, [page.relative_path])
    if raw_path.suffix.lower() == ".pdf":
        sync_pdf_search_index(
            config,
            raw_relative=raw_relative,
            artifact=pdf_artifact,
            display_title=page.title,
            display_relative_path=page.relative_path,
            page_type=page.page_type,
            page_summary=str(page.frontmatter.get("summary") or ""),
        )
    pages_by_type = collect_pages_by_type(config)
    write_index(config, pages_by_type)
    write_overview(config, pages_by_type)
    _emit_ingest_event(
        event_callback,
        {
            "event": "navigation_refreshed",
            "id": job_id,
            "source": raw_path.name,
            "index_path": "wiki/index.md",
            "overview_path": "wiki/overview.md",
        },
    )
    log_lines = [
        f"Raw source: {raw_relative}",
        f"Source page: {page.relative_path}",
    ]
    append_log_entry(config, "ingest", artifact.title, log_lines)
    _emit_ingest_event(
        event_callback,
        {
            "event": "completed",
            "id": job_id,
            "note_path": page.relative_path,
            "raw_path": raw_relative,
            "source": raw_path.name,
            "needs_document_review": artifact.needs_document_review,
        },
    )
    return {
        "status": "updated" if existing_source_page is not None else "created",
        "page": page,
        "artifact": artifact,
        "metadata_only": artifact.metadata_only,
        "needs_document_review": artifact.needs_document_review,
    }


@click.group()
def main() -> None:
    """Rhizome — an LLM-maintained wiki workspace."""


@main.command()
@click.argument("topic")
@click.option("--description", "-d", default="", help="Topic description.")
@click.option("--path", "-p", default=".", help="Directory to create workspace in.")
@click.option("--json-output/--no-json-output", default=False)
def init(topic: str, description: str, path: str, json_output: bool) -> None:
    """Create a new wiki workspace."""
    root = Path(path).resolve()
    try:
        config = init_workspace(root, topic, description)
        if json_output:
            _emit_json({"ok": True, "workspace": _workspace_payload(config)})
            return
        console.print(f"[green]Workspace initialized:[/green] {config.topic}")
        console.print(f"  Drop sources into: {config.raw_dir}")
        console.print(f"  Wiki pages at: {config.wiki_dir}")
        console.print(f"  Open in Obsidian: File > Open Vault > {root}")
    except FileExistsError:
        if json_output:
            _emit_machine_error(f"Workspace already exists at {root}", context="init")
            raise SystemExit(1)
        console.print(f"[red]Workspace already exists at {root}[/red]")
        raise SystemExit(1)


@main.command()
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def status(path: str, json_output: bool) -> None:
    """Show workspace status."""
    try:
        config = load_config(Path(path).resolve())
    except FileNotFoundError as exc:
        if json_output:
            _emit_machine_error(str(exc), context="status")
            raise SystemExit(1)
        console.print("[red]No workspace found. Run 'compile init' first.[/red]")
        raise SystemExit(1)
    try:
        info = get_status(config)
    except Exception as exc:
        if json_output:
            _emit_machine_error(str(exc), context="status")
            raise SystemExit(1)
        console.print(f"[red]{exc}[/red]")
        raise SystemExit(1)
    if json_output:
        _emit_json({"ok": True, "workspace": _workspace_payload(config, info)})
        return
    table = Table(title=info["topic"])
    table.add_column("", style="bold")
    table.add_column("")
    for key in (
        "topic",
        "description",
        "workspace_root",
        "raw_files",
        "processed",
        "unprocessed",
        "needs_document_review",
        "wiki_pages",
    ):
        table.add_row(key.replace("_", " ").title(), str(info[key]))
    table.add_row("Watches", _format_watches_summary(info))
    console.print(table)


def _format_watches_summary(info: dict[str, Any]) -> str:
    total = info.get("watches", 0)
    if not total:
        return "0"
    parts: list[str] = []
    active = info.get("watches_active", 0)
    paused = info.get("watches_paused", 0)
    failing = info.get("watches_failing", 0)
    if active:
        parts.append(f"{active} active")
    if paused:
        parts.append(f"{paused} paused")
    if failing:
        parts.append(f"{failing} failing")
    if parts:
        return f"{total} ({', '.join(parts)})"
    return str(total)


@main.command()
@click.argument("source")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--title", default=None, help="Optional override title for the generated source note.")
@click.option("--images/--no-images", default=False, help="Download referenced images when ingesting a URL.")
@click.option("--json-stream/--no-json-stream", default=False)
@click.option("--job-id", default=None, hidden=True)
def ingest(source: str, path: str, title: str | None, images: bool, json_stream: bool, job_id: str | None) -> None:
    """Create a source note for a raw artifact or URL."""
    job_id = job_id or uuid4().hex
    raw_path: Path | None = None

    def emit_event(payload: dict[str, Any]) -> None:
        _emit_json({key: value for key, value in payload.items() if value is not None})

    try:
        config = load_config(Path(path).resolve())
    except FileNotFoundError as exc:
        if json_stream:
            emit_event(
                {
                    "event": "failed",
                    "id": job_id,
                    "source": source,
                    "message": str(exc),
                }
            )
            raise SystemExit(1)
        console.print("[red]No workspace found. Run 'compile init' first.[/red]")
        raise SystemExit(1)

    if json_stream:
        emit_event(
            {
                "event": "started",
                "id": job_id,
                "kind": "ingest",
                "source": source,
                "workspace": str(config.workspace_root),
            }
        )

    if is_url(source):
        try:
            raw_path, fetched_title = fetch_url(
                source, config.raw_dir, download_images=images,
            )
        except Exception as exc:
            if json_stream:
                emit_event(
                    {
                        "event": "failed",
                        "id": job_id,
                        "source": source,
                        "message": f"Failed to fetch URL: {exc}",
                    }
                )
                raise SystemExit(1)
            console.print(f"[red]Failed to fetch URL:[/red] {exc}")
            raise SystemExit(1)
        if title is None and fetched_title:
            title = fetched_title
        if json_stream:
            emit_event(
                {
                    "event": "fetched",
                    "id": job_id,
                    "source": source,
                    "raw_path": str(raw_path.relative_to(config.workspace_root)).replace("\\", "/"),
                    "title": fetched_title or title,
                }
            )
        else:
            console.print(f"[green]Fetched URL → [/green]{raw_path.relative_to(config.workspace_root)}")
    else:
        raw_path = _resolve_raw_source(config.workspace_root, source)
        if not raw_path.exists() or not raw_path.is_file():
            if json_stream:
                emit_event(
                    {
                        "event": "failed",
                        "id": job_id,
                        "source": source,
                        "message": f"Raw source not found: {raw_path}",
                    }
                )
                raise SystemExit(1)
            console.print(f"[red]Raw source not found:[/red] {raw_path}")
            raise SystemExit(1)
        try:
            raw_path.relative_to(config.workspace_root)
        except ValueError:
            if json_stream:
                emit_event(
                    {
                        "event": "failed",
                        "id": job_id,
                        "source": source,
                        "message": "Raw source must live inside the workspace root.",
                    }
                )
                raise SystemExit(1)
            console.print("[red]Raw source must live inside the workspace root.[/red]")
            raise SystemExit(1)
        try:
            raw_path.relative_to(config.raw_dir)
        except ValueError:
            if json_stream:
                emit_event(
                    {
                        "event": "failed",
                        "id": job_id,
                        "source": source,
                        "message": "Source files must be in the raw/ directory.",
                    }
                )
                raise SystemExit(1)
            console.print("[red]Source files must be in the raw/ directory.[/red]")
            console.print(f"  Move the file to {config.raw_dir} and retry.")
            raise SystemExit(1)
        safe_name = sanitize_raw_filename(raw_path.name)
        if safe_name != raw_path.name:
            target = raw_path.with_name(safe_name)
            counter = 2
            while target.exists() and target.resolve() != raw_path.resolve():
                target = raw_path.with_name(f"{Path(safe_name).stem}-{counter}{Path(safe_name).suffix}")
                counter += 1
            raw_path.rename(target)
            raw_path = target
            renamed_relative = str(raw_path.relative_to(config.workspace_root)).replace("\\", "/")
            if json_stream:
                emit_event(
                    {
                        "event": "renamed",
                        "id": job_id,
                        "source": source,
                        "raw_path": renamed_relative,
                        "message": f"Renamed raw source to remove unsafe characters: {raw_path.name}",
                    }
                )
            else:
                console.print(
                    f"[yellow]Renamed raw source → [/yellow]{renamed_relative}"
                )
    try:
        result = _ingest_raw_source(
            config,
            raw_path=raw_path,
            title=title,
            job_id=job_id,
            event_callback=emit_event if json_stream else None,
        )
    except ValueError as exc:
        if json_stream:
            emit_event(
                {
                    "event": "failed",
                    "id": job_id,
                    "source": source,
                    "raw_path": (
                        str(raw_path.relative_to(config.workspace_root)).replace("\\", "/")
                        if raw_path is not None and raw_path.exists()
                        else None
                    ),
                    "message": str(exc),
                }
            )
            raise SystemExit(1)
        console.print(f"[red]{exc}[/red]")
        raise SystemExit(1)
    except Exception as exc:
        if json_stream:
            emit_event(
                {
                    "event": "failed",
                    "id": job_id,
                    "source": source,
                    "raw_path": (
                        str(raw_path.relative_to(config.workspace_root)).replace("\\", "/")
                        if raw_path is not None and raw_path.exists()
                        else None
                    ),
                    "message": str(exc),
                }
            )
            raise SystemExit(1)
        raise

    if json_stream:
        return

    if result["status"] == "preserved":
        console.print(f"[yellow]Source already enriched:[/yellow] {result['page'].relative_path}")
        console.print("  Marked as processed. Skipping re-ingest.")
        return
    page = result["page"]
    artifact = result["artifact"]
    console.print(f"[green]Source note created:[/green] {page.relative_path}")
    if result["metadata_only"]:
        console.print("  Source content could not be extracted. Read the raw file and replace this note.")
    elif result["needs_document_review"]:
        console.print("  Built from local PDF text extraction. Review the raw document before treating it as complete.")


@main.command("health")
@click.option("--path", "-p", default=".", help="Workspace or vault path.")
@click.option("--json-output/--no-json-output", default=False)
def health(path: str, json_output: bool) -> None:
    """Run workspace health report."""
    from compile.health import build_health_report
    report = build_health_report(Path(path).resolve())

    if json_output:
        click.echo(json.dumps(report, indent=2))
        return

    console.print(f"\n[bold]{report['overall_status']}[/bold]")
    console.print(f"  {report['summary']}")
    for section in ("obsidian_readiness", "graph_health", "content_health"):
        data = report[section]
        counts = ", ".join(f"{k}={v}" for k, v in data["counts"].items())
        console.print(f"  {section}: {data['status']} ({counts})")

    metrics = report.get("metrics", {})
    if "knowledge_page_count" in metrics:
        console.print(
            f"  editorial: knowledge_pages={metrics['knowledge_page_count']}, "
            f"pages={metrics.get('pages', 0)}, "
            f"source_to_knowledge_page_ratio={metrics.get('source_to_knowledge_page_ratio', 0)}, "
            f"unanchored_sources={metrics.get('source_notes_without_topic_anchors', 0)}"
        )
        console.print("  (use --json-output for machine-readable issues and full metrics)")

    if report["issues"]:
        console.print()
        for issue in report["issues"][:15]:
            console.print(f"  [{issue.get('severity', '')}] {issue.get('code', '')}: {issue.get('message', '')}")


@main.command("schema")
def schema_show() -> None:
    """Print the current WIKI.md schema."""
    config = _load_workspace()
    content = read_schema(config)
    if not content:
        console.print("[dim]No WIKI.md found.[/dim]")
        return
    from rich.markdown import Markdown
    console.print(Markdown(content))


# --- Obsidian vault inspection ---

@main.group()
def obsidian() -> None:
    """Inspect Obsidian vault metadata and graph quality."""


@obsidian.command("inspect")
@click.option("--path", "-p", default=".")
@click.option("--json-output/--no-json-output", default=False)
def obsidian_inspect(path: str, json_output: bool) -> None:
    """Full vault audit."""
    connector = ObsidianConnector(Path(path).resolve())
    report = connector.inspect()

    if json_output:
        click.echo(json.dumps(report.to_dict(), indent=2))
        return

    console.print(f"\n[bold]{report.layout}[/bold] ({report.total_pages} pages)")
    table = Table(title="Vault Summary")
    table.add_column("Metric", style="bold")
    table.add_column("Value")
    for label, value in [
        ("Pages", report.total_pages),
        ("Types", ", ".join(f"{k}={v}" for k, v in report.page_type_counts.items()) or "none"),
        ("Resolved links", report.resolved_link_count),
        ("Unresolved links", report.unresolved_link_count),
        ("Orphan pages", report.orphan_page_count),
        ("Thin pages", len(report.thin_pages)),
    ]:
        table.add_row(label, str(value))
    console.print(table)

    if report.issues:
        console.print()
        for issue in report.issues[:15]:
            console.print(f"  [{issue.severity}] {issue.code}: {issue.message}")


@obsidian.command("search")
@click.argument("query")
@click.option("--path", "-p", default=".")
@click.option("--limit", "-n", default=10)
@click.option("--json-output/--no-json-output", default=False)
def obsidian_search(query: str, path: str, limit: int, json_output: bool) -> None:
    """Search wiki pages."""
    root = Path(path).resolve()
    connector = ObsidianConnector(root)
    if connector.layout == "compile_workspace":
        config = load_config(connector.root)
        if search_index_exists(config):
            hits = _merge_search_hits(
                primary=search_pdf_index(config, query, limit=limit, connector=connector),
                secondary=connector.search(query, limit=limit),
                limit=limit,
            )
        else:
            hits = connector.search(query, limit=limit)
    else:
        hits = connector.search(query, limit=limit)
    if not hits:
        if json_output:
            _emit_json({"ok": True, "hits": []})
            return
        console.print(f"[yellow]No matches:[/yellow] {query}")
        return
    if json_output:
        _emit_json({"ok": True, "hits": [hit.to_dict() for hit in hits]})
        return
    for hit in hits:
        console.print(f"  {hit.title} ({hit.page_type}) — {hit.snippet[:80]}")


@obsidian.command("page")
@click.argument("locator")
@click.option("--path", "-p", default=".")
@click.option("--json-output/--no-json-output", default=False)
def obsidian_page(locator: str, path: str, json_output: bool) -> None:
    """Show page metadata and body."""
    connector = ObsidianConnector(Path(path).resolve())
    try:
        page = connector.get_page(locator)
    except (FileNotFoundError, ValueError) as e:
        if json_output:
            _emit_machine_error(str(e), context="obsidian_page")
            raise SystemExit(1)
        console.print(f"[red]{e}[/red]")
        raise SystemExit(1)

    if json_output:
        _emit_json({"ok": True, "page": page.to_dict(include_body=True)})
        return

    console.print(f"\n[bold]{page.title}[/bold] ({page.page_type}, {page.word_count} words)")
    if page.resolved_outbound_links:
        console.print(f"  Links to: {', '.join(page.resolved_outbound_links[:10])}")
    if page.inbound_links:
        console.print(f"  Linked from: {', '.join(page.inbound_links[:10])}")
    if page.body:
        from rich.markdown import Markdown
        console.print()
        console.print(Markdown(page.body))


@obsidian.command("neighbors")
@click.argument("locator")
@click.option("--path", "-p", default=".")
@click.option("--json-output/--no-json-output", default=False)
def obsidian_neighbors(locator: str, path: str, json_output: bool) -> None:
    """Show page connections."""
    connector = ObsidianConnector(Path(path).resolve())
    try:
        n = connector.get_neighborhood(locator)
    except (FileNotFoundError, ValueError) as e:
        if json_output:
            _emit_machine_error(str(e), context="obsidian_neighbors")
            raise SystemExit(1)
        console.print(f"[red]{e}[/red]")
        raise SystemExit(1)

    if json_output:
        _emit_json({"ok": True, "neighborhood": n.to_dict()})
        return

    console.print(f"\n[bold]{n.page.title}[/bold]")
    for label, items in [
        ("Backlinks", n.backlinks),
        ("Outbound", n.outbound_pages),
        ("Sources", n.supporting_source_pages),
        ("Related", n.related_pages),
    ]:
        if items:
            console.print(f"  {label}: {', '.join(items)}")


@obsidian.command("graph")
@click.option("--path", "-p", default=".")
def obsidian_graph(path: str) -> None:
    """Graph structure summary."""
    connector = ObsidianConnector(Path(path).resolve())
    graph = connector.graph()
    console.print(f"\n{len(graph.nodes)} nodes, {len(graph.edges)} edges")
    top = sorted(graph.nodes, key=lambda n: n.inbound_count + n.outbound_count, reverse=True)[:10]
    for node in top:
        console.print(f"  {node.title} ({node.page_type}) — {node.inbound_count} in, {node.outbound_count} out")


@obsidian.command("cleanup")
@click.option("--path", "-p", default=".")
def obsidian_cleanup(path: str) -> None:
    """Remove empty stub markdown files created by Obsidian."""
    connector = ObsidianConnector(Path(path).resolve())
    moved = connector.cleanup_empty_auxiliary_markdown_files()
    if not moved:
        console.print("[dim]No empty files to clean up.[/dim]")
        return
    console.print(f"[green]Quarantined {len(moved)} empty file(s).[/green]")
    for p in moved[:10]:
        console.print(f"  - {p}")


@obsidian.command("refresh")
@click.option("--path", "-p", default=".")
def obsidian_refresh(path: str) -> None:
    """Refresh index and overview pages from the current wiki."""
    connector = ObsidianConnector(Path(path).resolve())
    if connector.layout != "compile_workspace":
        console.print("[red]Refresh is only supported for compile workspaces.[/red]")
        raise SystemExit(1)

    config = load_config(connector.root)
    pages_by_type = collect_pages_by_type(config)
    write_index(config, pages_by_type)
    write_overview(config, pages_by_type)
    console.print("[green]Refreshed[/green] wiki/index.md and wiki/overview.md")


@obsidian.command("upsert")
@click.argument("title")
@click.option("--path", "-p", default=".")
@click.option("--page-type", required=True, help="Page type, for example article, source, map, or output.")
@click.option("--body", default=None, help="Markdown body for the page.")
@click.option(
    "--body-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Read markdown body from a UTF-8 file.",
)
@click.option("--summary", default=None, help="Optional frontmatter summary.")
@click.option(
    "--status",
    type=click.Choice(["seed", "emerging", "stable"]),
    default=None,
    help="Set the page status (seed, emerging, stable). Overrides the existing frontmatter value.",
)
@click.option(
    "--clear-review-status/--keep-review-status",
    default=None,
    help=(
        "Clear or preserve the review_status frontmatter flag. "
        "Default: clear it automatically when --body-file supplies a substantive non-shell rewrite."
    ),
)
@click.option("--relative-path", default=None, help="Optional target path relative to the vault root.")
@click.option("--tag", "tags", multiple=True, help="Repeat to add tags.")
@click.option("--source", "sources", multiple=True, help="Repeat to add supporting sources.")
@click.option("--alias", "aliases", multiple=True, help="Repeat to add aliases.")
def obsidian_upsert(
    title: str,
    path: str,
    page_type: str,
    body: str | None,
    body_file: Path | None,
    summary: str | None,
    status: str | None,
    clear_review_status: bool | None,
    relative_path: str | None,
    tags: tuple[str, ...],
    sources: tuple[str, ...],
    aliases: tuple[str, ...],
) -> None:
    """Create or update a maintained page."""
    if body is not None and body_file is not None:
        console.print("[red]Use either --body or --body-file, not both.[/red]")
        raise SystemExit(1)

    root = Path(path).resolve()
    connector = ObsidianConnector(root)

    # Resolve the exact page that upsert will overwrite, so body preservation
    # and shell detection both operate on the right target (not just any page
    # that shares the title).
    try:
        existing = connector.find_upsert_target(
            title=title, page_type=page_type, relative_path=relative_path,
        )
    except ValueError as exc:
        console.print(f"[red]{exc}[/red]")
        raise SystemExit(1)

    if body_file is not None:
        try:
            body_text = body_file.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            console.print(f"[red]Failed to read body file as UTF-8:[/red] {body_file}")
            raise SystemExit(1)
        except OSError as exc:
            console.print(f"[red]Failed to read body file:[/red] {exc}")
            raise SystemExit(1)
    elif body is not None:
        body_text = body
    elif existing is not None:
        body_text = existing.body
    else:
        console.print(
            "[red]No body provided and no existing page to preserve.[/red] "
            "Pass --body or --body-file to create a new page."
        )
        raise SystemExit(1)

    existing_was_shell = (
        existing is not None
        and existing.page_type == "source"
        and page_type == "source"
        and "This is a registration shell." in existing.body
    )

    extra_frontmatter: dict[str, Any] = {}
    if status:
        extra_frontmatter["status"] = status

    existing_review_flag = (
        str(existing.frontmatter.get("review_status") or "").strip()
        if existing is not None
        else ""
    )
    body_is_substantive_rewrite = (
        body_file is not None
        and "This is a registration shell." not in body_text
        and len(body_text.strip()) >= 500
    )
    should_clear_review = (
        clear_review_status is True
        or (
            clear_review_status is None
            and existing_review_flag == "needs_document_review"
            and body_is_substantive_rewrite
        )
    )
    if should_clear_review and existing_review_flag:
        extra_frontmatter["review_status"] = None

    page = connector.upsert_page(
        title=title,
        body=body_text,
        page_type=page_type,
        tags=list(tags),
        sources=list(sources),
        aliases=list(aliases),
        summary=summary,
        relative_path=relative_path,
        extra_frontmatter=extra_frontmatter or None,
    )

    # When a registration shell is replaced with real content, mark raw sources processed.
    if existing_was_shell and "This is a registration shell." not in body_text:
        try:
            config = load_config(root)
            raw_sources = page.frontmatter.get("sources", [])
            for raw_rel in raw_sources:
                raw_path = root / raw_rel
                if raw_path.exists():
                    mark_processed(config, raw_path, [page.relative_path])
                    console.print(f"[green]Marked processed:[/green] {raw_rel}")
        except Exception:
            pass  # non-fatal: source tracking is best-effort

    console.print(f"[green]Upserted[/green] {page.relative_path}")


@main.group()
def suggest() -> None:
    """Surface non-mutating editorial suggestions."""


@suggest.command("maps")
@click.option("--path", "-p", default=".")
@click.option("--limit", default=10, show_default=True, type=int)
@click.option("--json-output/--no-json-output", default=False)
def suggest_maps(path: str, limit: int, json_output: bool) -> None:
    """Suggest existing map pages that should absorb unanchored source notes."""
    connector = ObsidianConnector(Path(path).resolve())
    suggestions, unanchored_sources = suggest_map_updates(connector, limit=max(limit, 1))

    if json_output:
        _emit_json(
            {
                "ok": True,
                "suggestions": [suggestion.to_dict() for suggestion in suggestions],
                "unanchored_sources": [
                    {"title": page.title, "relative_path": page.relative_path}
                    for page in unanchored_sources
                ],
            }
        )
        return

    if suggestions:
        console.print("[bold]Suggested map updates[/bold]")
        for suggestion in suggestions:
            console.print(
                f"  {suggestion.map_title} ({suggestion.map_path}) — "
                f"{len(suggestion.source_notes)} source note(s), score {suggestion.score}"
            )
            for source_page in suggestion.source_notes:
                console.print(f"    - {source_page.title} ({source_page.relative_path})")
            console.print(f"    Reason: {suggestion.reason}")
    else:
        console.print("[dim]No obvious existing map updates found.[/dim]")

    if unanchored_sources:
        console.print("\n[bold]Unanchored source notes[/bold]")
        for page in unanchored_sources:
            console.print(f"  - {page.title} ({page.relative_path})")


@main.group()
def review() -> None:
    """Review and lifecycle commands for source pages."""


@review.command("mark-reviewed")
@click.argument("locator")
@click.option("--path", "-p", default=".")
def review_mark_reviewed(locator: str, path: str) -> None:
    """Mark a source page as document-reviewed."""
    connector = ObsidianConnector(Path(path).resolve())
    try:
        page = connector.get_page(locator)
    except (FileNotFoundError, ValueError) as exc:
        console.print(f"[red]{exc}[/red]")
        raise SystemExit(1)

    if page.page_type != "source":
        console.print("[red]Only source pages can be marked reviewed.[/red]")
        raise SystemExit(1)

    updated = connector.upsert_page(
        title=page.title,
        body=page.body,
        page_type=page.page_type,
        tags=list(page.tags),
        sources=_coerce_frontmatter_list(page.frontmatter.get("sources")),
        aliases=list(page.aliases),
        summary=str(page.frontmatter.get("summary") or "") or None,
        relative_path=page.relative_path,
        extra_frontmatter={
            "review_status": "reviewed",
            "reviewed_at": now_frontmatter(),
        },
        ensure_title_heading=False,
    )
    console.print(f"[green]Marked reviewed:[/green] {updated.relative_path}")


@main.group()
def index() -> None:
    """Build and maintain local retrieval indexes."""


@index.command("rebuild")
@click.option("--path", "-p", default=".")
def index_rebuild(path: str) -> None:
    """Rebuild PDF extraction sidecars and the local search index."""
    config = load_config(Path(path).resolve())
    stats = rebuild_search_index(config)
    relative_db = str(config.search_index_path.relative_to(config.workspace_root)).replace("\\", "/")
    console.print(f"[green]Rebuilt search index:[/green] {relative_db}")
    console.print(f"  PDFs scanned: {stats['pdfs_scanned']}")
    console.print(f"  Reused sidecars: {stats['reused_sidecars']}")
    console.print(f"  Created sidecars: {stats['created_sidecars']}")
    console.print(f"  Deleted orphan sidecars: {stats['deleted_orphans']}")
    console.print(f"  Indexed pages: {stats['indexed_pages']}")
    console.print(f"  Indexed chunks: {stats['indexed_chunks']}")
    if stats["unextractable_pdfs"]:
        console.print(f"  PDFs with no usable text: {stats['unextractable_pdfs']}")


# --- Rich output rendering ---


def _read_utf8_text_file(path: Path, *, label: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        console.print(f"[red]Failed to read {label} file as UTF-8:[/red] {path}")
        raise SystemExit(1)
    except OSError as exc:
        console.print(f"[red]Failed to read {label} file:[/red] {exc}")
        raise SystemExit(1)


def _resolve_inline_or_file(
    *,
    inline_value: str | None,
    file_value: Path | None,
    inline_flag: str,
    file_flag: str,
    label: str,
) -> str:
    if inline_value is not None and file_value is not None:
        console.print(f"[red]Use either {inline_flag} or {file_flag}, not both.[/red]")
        raise SystemExit(1)
    if file_value is not None:
        return _read_utf8_text_file(file_value, label=label)
    if inline_value is not None:
        return inline_value
    console.print(f"[red]Provide either {inline_flag} or {file_flag}.[/red]")
    raise SystemExit(1)


@main.group()
def render() -> None:
    """Generate rich output formats (Marp slides, charts, canvas)."""


@render.command("marp")
@click.argument("title")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--body", default=None, help="Slide markdown (use --- for slide separators).")
@click.option(
    "--body-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Read slide markdown from a UTF-8 file.",
)
@click.option("--theme", default="default", help="Marp theme name.")
@click.option("--summary", default=None, help="Frontmatter summary.")
@click.option("--tag", "tags", multiple=True)
def render_marp(
    title: str,
    path: str,
    body: str | None,
    body_file: Path | None,
    theme: str,
    summary: str | None,
    tags: tuple[str, ...],
) -> None:
    """Generate a Marp slide deck and save as a wiki output page."""
    root = Path(path).resolve()
    config = load_config(root)
    connector = ObsidianConnector(root)
    body_text = _resolve_inline_or_file(
        inline_value=body,
        file_value=body_file,
        inline_flag="--body",
        file_flag="--body-file",
        label="body",
    )
    marp_body, marp_fm = generate_marp(title, body_text, theme=theme)
    page = connector.upsert_page(
        title=title,
        body=marp_body,
        page_type="output",
        summary=summary or f"Marp slide deck: {title}",
        tags=list(tags),
        extra_frontmatter=marp_fm,
        ensure_title_heading=False,
    )
    pages_by_type = collect_pages_by_type(config)
    write_index(config, pages_by_type)
    write_overview(config, pages_by_type)
    append_log_entry(config, "render", title, ["Format: marp", f"Page: {page.relative_path}"])
    console.print(f"[green]Marp deck created:[/green] {page.relative_path}")


@render.command("chart")
@click.argument("title")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--script", default=None, help="Python matplotlib script.")
@click.option(
    "--script-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Read the matplotlib script from a UTF-8 file.",
)
@click.option("--summary", default=None, help="Frontmatter summary.")
@click.option("--tag", "tags", multiple=True)
def render_chart(
    title: str,
    path: str,
    script: str | None,
    script_file: Path | None,
    summary: str | None,
    tags: tuple[str, ...],
) -> None:
    """Execute a matplotlib script and save the chart as a wiki output page."""
    root = Path(path).resolve()
    config = load_config(root)
    connector = ObsidianConnector(root)
    output_dir = config.wiki_dir / "outputs"
    script_text = _resolve_inline_or_file(
        inline_value=script,
        file_value=script_file,
        inline_flag="--script",
        file_flag="--script-file",
        label="script",
    )
    try:
        image_path = generate_chart(title, script_text, output_dir)
    except RuntimeError as exc:
        console.print(f"[red]Chart generation failed:[/red] {exc}")
        raise SystemExit(1)
    rel_image = str(image_path.relative_to(config.workspace_root)).replace("\\", "/")
    body = f"![[{rel_image}]]\n\n## Script\n\n```python\n{script_text}\n```\n"
    page = connector.upsert_page(
        title=title,
        body=body,
        page_type="output",
        summary=summary or f"Chart: {title}",
        tags=list(tags),
    )
    pages_by_type = collect_pages_by_type(config)
    write_index(config, pages_by_type)
    write_overview(config, pages_by_type)
    append_log_entry(config, "render", title, ["Format: chart", f"Image: {rel_image}", f"Page: {page.relative_path}"])
    console.print(f"[green]Chart created:[/green] {image_path.name} → {page.relative_path}")


@render.command("canvas")
@click.argument("title")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--nodes", default=None, help='JSON array of node objects (each with "text" key).')
@click.option(
    "--nodes-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Read node JSON from a UTF-8 file.",
)
@click.option("--edges", default=None, help='Optional JSON array of edge objects (each with "from" and "to" keys).')
@click.option(
    "--edges-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Read edge JSON from a UTF-8 file.",
)
@click.option("--summary", default=None, help="Frontmatter summary.")
def render_canvas(
    title: str,
    path: str,
    nodes: str | None,
    nodes_file: Path | None,
    edges: str | None,
    edges_file: Path | None,
    summary: str | None,
) -> None:
    """Generate an Obsidian Canvas file and a companion wiki output page."""
    root = Path(path).resolve()
    config = load_config(root)
    connector = ObsidianConnector(root)
    nodes_text = _resolve_inline_or_file(
        inline_value=nodes,
        file_value=nodes_file,
        inline_flag="--nodes",
        file_flag="--nodes-file",
        label="nodes",
    )
    if edges is not None and edges_file is not None:
        console.print("[red]Use either --edges or --edges-file, not both.[/red]")
        raise SystemExit(1)
    edge_text = _read_utf8_text_file(edges_file, label="edges") if edges_file is not None else edges
    try:
        node_list = json.loads(nodes_text)
        edge_list = json.loads(edge_text) if edge_text else []
    except json.JSONDecodeError as exc:
        console.print(f"[red]Invalid JSON:[/red] {exc}")
        raise SystemExit(1)
    try:
        canvas_json = generate_canvas(title, node_list, edge_list)
    except ValueError as exc:
        console.print(f"[red]Invalid canvas payload:[/red] {exc}")
        raise SystemExit(1)

    # Write the .canvas file
    from compile.text import slugify
    slug = slugify(title) or "canvas"
    canvas_path = config.wiki_dir / "outputs" / f"{slug}.canvas"
    canvas_path.parent.mkdir(parents=True, exist_ok=True)
    canvas_path.write_text(canvas_json)

    # Create a companion markdown page
    rel_canvas = str(canvas_path.relative_to(config.workspace_root)).replace("\\", "/")
    body = f"Canvas file: [[{rel_canvas}]]\n\nNodes: {len(node_list)} | Edges: {len(edge_list)}\n"
    page = connector.upsert_page(
        title=title,
        body=body,
        page_type="output",
        summary=summary or f"Canvas: {title}",
    )
    pages_by_type = collect_pages_by_type(config)
    write_index(config, pages_by_type)
    write_overview(config, pages_by_type)
    append_log_entry(config, "render", title, ["Format: canvas", f"Canvas: {rel_canvas}", f"Page: {page.relative_path}"])
    console.print(f"[green]Canvas created:[/green] {rel_canvas} → {page.relative_path}")


# --- Query evals ---

@main.group("eval")
def eval_group() -> None:
    """Manual headless query evals for a wiki workspace."""


@eval_group.command("init")
@click.argument("name", default="query-quality")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--force", is_flag=True, help="Overwrite an existing eval suite.")
def eval_init(name: str, path: str, force: bool) -> None:
    """Create a starter prompt-only eval suite."""
    try:
        config = load_config(Path(path).expanduser().resolve())
        suite_path = write_starter_suite(config, name, force=force)
    except (FileNotFoundError, EvalSuiteError) as exc:
        console.print(f"[red]{exc}[/red]")
        raise SystemExit(1)
    console.print(f"[green]Eval suite created:[/green] {suite_path}")


@eval_group.command("run")
@click.argument("suite")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--dry-run", is_flag=True, help="Validate and print the suite without calling Claude.")
@click.option("--limit", type=click.IntRange(min=1), default=None, help="Run only the first N queries.")
@click.option(
    "--timeout-seconds",
    type=click.FloatRange(min=0.001),
    default=600.0,
    show_default=True,
    help="Per-query Claude timeout.",
)
@click.option("--claude", "claude_executable", default="claude", show_default=True, help="Claude executable to run.")
@click.option(
    "--concurrency",
    type=click.IntRange(min=1),
    default=4,
    show_default=True,
    help="Maximum number of queries to run in parallel.",
)
@click.option(
    "--runs-dir",
    type=click.Path(file_okay=False, path_type=Path),
    envvar="COMPILE_EVAL_RUNS_DIR",
    default=None,
    help=(
        "Directory for run JSON + markdown reports. "
        "Defaults to ./evals/runs/ (relative to the current working directory). "
        "Falls back to the COMPILE_EVAL_RUNS_DIR env var."
    ),
)
@click.option(
    "--output",
    type=click.Path(dir_okay=False, path_type=Path),
    default=None,
    help=(
        "Explicit run JSON output path. Overrides --runs-dir. "
        "Defaults to ./evals/runs/<timestamp>-<suite>.json."
    ),
)
def eval_run(
    suite: str,
    path: str,
    dry_run: bool,
    limit: int | None,
    timeout_seconds: float,
    claude_executable: str,
    concurrency: int,
    runs_dir: Path | None,
    output: Path | None,
) -> None:
    """Run a prompt-only eval suite through headless Claude Code."""
    try:
        config = load_config(Path(path).expanduser().resolve())
        eval_suite = load_eval_suite(config, suite)
    except (FileNotFoundError, EvalSuiteError) as exc:
        console.print(f"[red]{exc}[/red]")
        raise SystemExit(1)

    queries = eval_suite.queries[:limit] if limit is not None else eval_suite.queries
    runs_dir_resolved = runs_dir.expanduser().resolve() if runs_dir is not None else None
    if dry_run:
        console.print(f"[bold]{eval_suite.name}[/bold] — {len(queries)} query(ies)")
        console.print(f"Suite: {eval_suite.path}")
        if output is not None:
            console.print(f"Output: {output.expanduser().resolve()}")
        else:
            console.print(
                f"Default output: "
                f"{build_run_output_path(eval_suite.name, runs_dir=runs_dir_resolved)}"
            )
        for index, item in enumerate(queries, start=1):
            console.print(f"{index:>2}. {item['id']}: {item['query']}")
        return

    def progress(
        completed: int,
        total: int,
        item: dict[str, Any],
        result: dict[str, Any],
    ) -> None:
        duration_ms = result.get("durationMs")
        seconds = (
            f"{duration_ms / 1000:.1f}s"
            if isinstance(duration_ms, int)
            else "?"
        )
        console.print(
            f"[cyan]eval {completed}/{total}[/cyan] {item['id']}: "
            f"{result['status']} in {seconds}"
        )

    payload = run_eval_suite(
        config,
        eval_suite,
        limit=limit,
        timeout_seconds=timeout_seconds,
        claude_executable=claude_executable,
        concurrency=concurrency,
        progress=progress,
    )
    output_path = output.expanduser().resolve() if output is not None else None
    run_path = write_run_output(
        payload, output_path, runs_dir=runs_dir_resolved,
    )
    summary = payload["summary"]
    console.print(
        f"[green]Eval run written:[/green] {run_path} "
        f"({summary['completed']} completed, {summary['failed']} failed)"
    )
    console.print(f"[green]Readable report:[/green] {run_path.with_suffix('.md')}")


# --- Watches: personalized automated pulls ---


@main.group()
def watch() -> None:
    """Recurring URL pulls synthesized by Claude into a wiki page."""


def _watch_payload(record) -> dict[str, Any]:
    return record.to_dict()


@watch.command("add")
@click.argument("url")
@click.option("--frequency", "-f", default="daily", show_default=True, help="hourly, daily, weekly, or 'cron: <expr>' (hourly minimum)")
@click.option("--intent", "-i", required=True, help="Plain-language description of what to pull and synthesize.")
@click.option("--title", default=None, help="Optional title override (default derived from URL).")
@click.option("--tag", "tags", multiple=True, help="Repeat to add tags.")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def watch_add(
    url: str,
    frequency: str,
    intent: str,
    title: str | None,
    tags: tuple[str, ...],
    path: str,
    json_output: bool,
) -> None:
    """Register a new watch and create its wiki page."""
    from compile.watch import add_watch
    config = load_config(Path(path).resolve())
    try:
        record = add_watch(
            config,
            url=url,
            frequency=frequency,
            intent=intent,
            title=title,
            tags=list(tags),
        )
    except ValueError as exc:
        if json_output:
            _emit_machine_error(str(exc), context="watch add")
        else:
            console.print(f"[red]{exc}[/red]")
        raise SystemExit(1) from exc
    if json_output:
        _emit_json({"ok": True, "watch": _watch_payload(record)})
        return
    console.print(f"[green]Watch created:[/green] {record.relative_path}")
    console.print(f"  next_run: {record.next_run}")


@watch.command("list")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def watch_list(path: str, json_output: bool) -> None:
    from compile.watch import list_watches
    config = load_config(Path(path).resolve())
    records = list_watches(config)
    if json_output:
        _emit_json({"ok": True, "watches": [_watch_payload(r) for r in records]})
        return
    if not records:
        console.print("[dim]No watches registered.[/dim]")
        return
    table = Table(title="Watches")
    table.add_column("Title")
    table.add_column("Status")
    table.add_column("Frequency")
    table.add_column("Next run")
    table.add_column("Last status")
    for r in records:
        table.add_row(r.title, r.watch_status, r.frequency, r.next_run or "-", r.last_status or "-")
    console.print(table)


@watch.command("show")
@click.argument("locator")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def watch_show(locator: str, path: str, json_output: bool) -> None:
    from compile.watch import get_watch
    config = load_config(Path(path).resolve())
    try:
        record = get_watch(config, locator)
    except FileNotFoundError as exc:
        if json_output:
            _emit_machine_error(str(exc), context="watch show")
        else:
            console.print(f"[red]{exc}[/red]")
        raise SystemExit(1) from exc
    if json_output:
        _emit_json({"ok": True, "watch": _watch_payload(record)})
        return
    console.print(json.dumps(_watch_payload(record), indent=2, sort_keys=True))


@watch.command("pause")
@click.argument("locator")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def watch_pause(locator: str, path: str, json_output: bool) -> None:
    from compile.watch import pause_watch
    config = load_config(Path(path).resolve())
    record = pause_watch(config, locator)
    if json_output:
        _emit_json({"ok": True, "watch": _watch_payload(record)})
        return
    console.print(f"[yellow]Paused:[/yellow] {record.title}")


@watch.command("resume")
@click.argument("locator")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def watch_resume(locator: str, path: str, json_output: bool) -> None:
    from compile.watch import resume_watch
    config = load_config(Path(path).resolve())
    record = resume_watch(config, locator)
    if json_output:
        _emit_json({"ok": True, "watch": _watch_payload(record)})
        return
    console.print(f"[green]Resumed:[/green] {record.title} (next_run {record.next_run})")


@watch.command("remove")
@click.argument("locator")
@click.option("--keep-page/--no-keep-page", default=False, help="Leave the wiki page in place; just unregister the watch.")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--json-output/--no-json-output", default=False)
def watch_remove(locator: str, keep_page: bool, path: str, json_output: bool) -> None:
    from compile.watch import remove_watch
    config = load_config(Path(path).resolve())
    try:
        relative = remove_watch(config, locator, keep_page=keep_page)
    except FileNotFoundError as exc:
        if json_output:
            _emit_machine_error(str(exc), context="watch remove")
        else:
            console.print(f"[red]{exc}[/red]")
        raise SystemExit(1) from exc
    if json_output:
        _emit_json({"ok": True, "removed": relative, "keep_page": keep_page})
        return
    if keep_page:
        console.print(f"[yellow]Unregistered (page kept):[/yellow] {relative}")
    else:
        console.print(f"[red]Removed:[/red] {relative}")


@watch.command("run")
@click.argument("locator")
@click.option("--force/--no-force", default=False, help="Synthesize even if the fetched content is unchanged.")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--claude", "claude_executable", default="claude", show_default=True, help="Claude executable to run.")
@click.option("--timeout-seconds", type=click.FloatRange(min=1.0), default=300.0, show_default=True)
@click.option("--json-output/--no-json-output", default=False)
def watch_run(
    locator: str,
    force: bool,
    path: str,
    claude_executable: str,
    timeout_seconds: float,
    json_output: bool,
) -> None:
    """Run one watch right now."""
    from compile.watch import run_watch
    config = load_config(Path(path).resolve())
    try:
        event = run_watch(
            config,
            locator,
            force=force,
            claude_executable=claude_executable,
            claude_timeout=timeout_seconds,
        )
    except FileNotFoundError as exc:
        if json_output:
            _emit_machine_error(str(exc), context="watch run")
        else:
            console.print(f"[red]{exc}[/red]")
        raise SystemExit(1) from exc
    if json_output:
        _emit_json({"ok": event.get("status") != "failed", "event": event})
        return
    status = event.get("status")
    if status == "ok":
        console.print(f"[green]Watch ran:[/green] {event['title']}")
    elif status == "unchanged":
        console.print(f"[dim]Unchanged (skipped synthesis):[/dim] {event['title']}")
    elif status == "skipped":
        console.print(f"[yellow]Skipped (locked):[/yellow] {event['title']}")
    else:
        console.print(f"[red]Failed:[/red] {event.get('error') or status}")


@watch.command("tick")
@click.option("--path", "-p", default=".", help="Workspace root.")
@click.option("--claude", "claude_executable", default="claude", show_default=True, help="Claude executable to run.")
@click.option("--timeout-seconds", type=click.FloatRange(min=1.0), default=300.0, show_default=True)
@click.option("--json-stream/--no-json-stream", default=False, help="Emit one JSON event per processed watch (for the Mac app).")
@click.option("--json-output/--no-json-output", default=False, help="Emit a single JSON summary at the end.")
def watch_tick(
    path: str,
    claude_executable: str,
    timeout_seconds: float,
    json_stream: bool,
    json_output: bool,
) -> None:
    """Run every active watch whose next_run is due now."""
    from compile.watch import tick
    config = load_config(Path(path).resolve())
    events = tick(
        config,
        claude_executable=claude_executable,
        claude_timeout=timeout_seconds,
    )
    if json_stream:
        for event in events:
            _emit_json({"event": event})
    if json_output:
        _emit_json({"ok": True, "count": len(events), "events": events})
    if not json_output and not json_stream:
        if not events:
            console.print("[dim]No watches due.[/dim]")
        for event in events:
            status = event.get("status")
            console.print(f"  {status:>9}  {event.get('title')}")


# --- Claude Code integration ---

@main.group()
def claude() -> None:
    """Claude Code integration — install commands and workspace files."""


@claude.command("setup")
@click.argument("path", default=".")
@click.option("--force", is_flag=True, help="Overwrite existing files without prompting.")
def claude_setup(path: str, force: bool) -> None:
    """Install Claude Code commands for a wiki workspace.

    PATH is the wiki workspace directory (default: current directory).

    Installs context-aware global commands (~/.claude/commands/) so the wiki is
    accessible from any Claude Code session, and workspace-local commands
    so the wiki itself has the full editing toolset.
    """
    wiki_path = Path(path).expanduser().resolve()
    config_path = wiki_path / ".compile" / "config.yaml"
    if not config_path.exists():
        console.print(f"[red]No compile workspace at {wiki_path}[/red]")
        console.print("Run 'compile init' in that directory first.")
        raise SystemExit(1)

    result = install_claude_files(wiki_path, Path.home(), force)

    if result["installed"]:
        console.print(f"[green]Installed {len(result['installed'])} file(s):[/green]")
        for f in result["installed"]:
            console.print(f"  + {f}")
    if result["mispointed"]:
        console.print(f"[red]Warning: {len(result['mispointed'])} global command(s) point at a different wiki:[/red]")
        for f in result["mispointed"]:
            console.print(f"  ! {f}")
        console.print("[red]Use --force to rebind them to this workspace.[/red]")
    if result["skipped"]:
        console.print(f"[yellow]Skipped {len(result['skipped'])} existing file(s) (use --force to overwrite):[/yellow]")
        for f in result["skipped"]:
            console.print(f"  ~ {f}")
    if (
        not result["installed"]
        and not result["skipped"]
        and not result["mispointed"]
    ):
        console.print("[dim]Nothing to install.[/dim]")


def install_claude_files(
    wiki_path: Path, home: Path, force: bool,
) -> dict[str, list[str]]:
    """Install Claude Code commands for a wiki workspace.

    Returns a dict with keys: installed, skipped, mispointed.
    """
    templates = resource_path("templates")
    if not templates.is_dir():
        raise FileNotFoundError(
            f"Template directory not found at {templates}. "
            "This may indicate a packaging or installation problem."
        )
    wiki_path_str = str(wiki_path)
    installed: list[str] = []
    skipped: list[str] = []
    mispointed: list[str] = []

    # --- Context-aware global commands ---
    global_dir = home / ".claude" / "commands"
    global_dir.mkdir(parents=True, exist_ok=True)

    for template_file in _iter_managed_templates(templates / "global"):
        dest = global_dir / template_file.name
        if dest.exists() and not force:
            existing = dest.read_text()
            marker = f"My wiki lives at: {wiki_path_str}\n"
            if marker not in existing:
                mispointed.append(str(dest))
            else:
                skipped.append(str(dest))
            continue
        content = template_file.read_text().replace("{{wiki_path}}", wiki_path_str)
        dest.write_text(content)
        installed.append(str(dest))

    # --- Workspace-local files ---
    workspace_claude_dir = wiki_path / ".claude" / "commands"
    workspace_claude_dir.mkdir(parents=True, exist_ok=True)

    # CLAUDE.md
    claude_md_src = templates / "workspace" / "CLAUDE.md"
    claude_md_dest = wiki_path / "CLAUDE.md"
    if claude_md_dest.exists() and not force:
        skipped.append(str(claude_md_dest))
    else:
        claude_md_dest.write_text(claude_md_src.read_text())
        installed.append(str(claude_md_dest))

    # settings.local.json
    settings_src = templates / "workspace" / "settings.local.json"
    settings_dest = wiki_path / ".claude" / "settings.local.json"
    if settings_dest.exists():
        try:
            existing_settings = json.loads(settings_dest.read_text())
            template_settings = json.loads(settings_src.read_text())
        except json.JSONDecodeError:
            if force:
                settings_dest.write_text(settings_src.read_text())
                installed.append(str(settings_dest))
            else:
                skipped.append(str(settings_dest))
        else:
            merged_settings = _merge_settings_values(existing_settings, template_settings)
            merged_text = json.dumps(merged_settings, indent=2) + "\n"
            if force or merged_text != settings_dest.read_text():
                settings_dest.write_text(merged_text)
                installed.append(str(settings_dest))
            else:
                skipped.append(str(settings_dest))
    else:
        settings_dest.write_text(settings_src.read_text())
        installed.append(str(settings_dest))

    # Workspace commands
    for template_file in _iter_managed_templates(templates / "workspace" / "commands"):
        dest = workspace_claude_dir / template_file.name
        if dest.exists() and not force:
            skipped.append(str(dest))
            continue
        dest.write_text(template_file.read_text())
        installed.append(str(dest))

    _sync_existing_pdf_full_text_callouts(load_config(wiki_path))

    return {
        "installed": installed,
        "skipped": skipped,
        "mispointed": mispointed,
    }


def _resolve_raw_source(workspace_root: Path, source: str) -> Path:
    candidate = Path(source)
    if candidate.is_absolute():
        return candidate.resolve()

    direct = (workspace_root / candidate).resolve()
    if direct.exists():
        return direct

    raw_relative = (workspace_root / "raw" / candidate).resolve()
    return raw_relative


def _extract_for_ingest(config, raw_path: Path, raw_relative: str):
    if raw_path.suffix.lower() != ".pdf":
        return extract_source(raw_path), None

    raw_sha256 = compute_sha256(raw_path)
    try:
        artifact = load_pdf_artifact(config, raw_sha256)
    except (json.JSONDecodeError, ValueError):
        artifact = None
    if artifact is not None:
        artifact = align_artifact_raw_path(config, artifact, raw_relative)
        return extracted_source_from_artifact(artifact), artifact

    extracted = extract_source(raw_path)
    artifact = None
    if not extracted.metadata_only and extracted.page_texts:
        artifact = build_pdf_artifact(
            raw_relative=raw_relative,
            raw_sha256=raw_sha256,
            extracted=extracted,
        )
        save_pdf_artifact(config, artifact)
    return extracted, artifact


def _source_review_frontmatter(extracted) -> dict[str, str] | None:
    if extracted.requires_document_review and extracted.extraction_method:
        return {"review_status": "needs_document_review"}
    return None


def _extract_source_provenance_frontmatter(raw_path: Path) -> dict[str, str] | None:
    if raw_path.suffix.lower() not in {".md", ".markdown", ".txt"}:
        return None
    try:
        content = raw_path.read_text()
    except OSError:
        return None
    matches = re.findall(r"<!--\s*([a-zA-Z0-9_]+)\s*:\s*(.*?)\s*-->", content)
    if not matches:
        return None
    comments = {key.strip(): value.strip() for key, value in matches}
    if comments.get("source") != "notion":
        return None
    frontmatter: dict[str, str] = {}
    # Only persist the keys that something actually reads:
    # - notion_page_id: used by `_should_refresh_existing_source_page` to recognize
    #   a re-sync of the same Notion page.
    # - notion_url: clickable backlink to the Notion source from Obsidian.
    # The skip-if-unchanged logic reads `notion_last_edited_time` from the raw
    # file's HTML comments, so duplicating it (or `notion_synced_at`) into
    # frontmatter just clutters every Notion-sourced page.
    mapping = {
        "notion_page_id": "notion_page_id",
        "notion_page_url": "notion_url",
    }
    for comment_key, frontmatter_key in mapping.items():
        value = comments.get(comment_key, "").strip()
        if value:
            frontmatter[frontmatter_key] = value
    return frontmatter or None


def _should_preserve_existing_source_page(page) -> bool:
    if "This is a registration shell." in page.body:
        return False
    return str(page.frontmatter.get("review_status") or "").strip() != "needs_document_review"


def _refresh_pdf_index_for_source_page(config, *, raw_path: Path, raw_relative: str, page) -> None:
    _, pdf_artifact = _extract_for_ingest(config, raw_path, raw_relative)
    if pdf_artifact is not None:
        _ensure_source_note_full_text_callout(config, page, pdf_artifact)
    sync_pdf_search_index(
        config,
        raw_relative=raw_relative,
        artifact=pdf_artifact,
        display_title=page.title,
        display_relative_path=page.relative_path,
        page_type=page.page_type,
        page_summary=str(page.frontmatter.get("summary") or ""),
    )


def _sync_existing_pdf_full_text_callouts(config) -> int:
    if not config.extract_dir.is_dir():
        return 0

    connector = ObsidianConnector(config.workspace_root)
    updated = 0
    for artifact_path in sorted(config.extract_dir.glob("*.json")):
        try:
            artifact = load_pdf_artifact_path(artifact_path)
        except (json.JSONDecodeError, ValueError, OSError):
            continue
        try:
            source_page = connector.find_source_page_by_raw_path(artifact.raw_path)
        except ValueError:
            source_page = None
        if source_page is not None:
            if _ensure_source_note_full_text_callout(config, source_page, artifact):
                updated += 1
    return updated


def _ensure_source_note_full_text_callout(config, page, artifact) -> bool:
    note_path = config.workspace_root / page.relative_path
    try:
        text = note_path.read_text()
    except OSError:
        return False

    marker = "> [!abstract]- Full extracted text"
    if any(line == marker for line in text.splitlines()):
        return False

    extracted = extracted_source_from_artifact(artifact)
    full_text = extracted.normalized_text.strip()
    if not full_text:
        return False

    note_path.write_text(
        text.rstrip() + "\n\n" + render_full_text_callout(full_text) + "\n"
    )
    return True


def _coerce_frontmatter_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]


def _merge_search_hits(*, primary, secondary, limit: int):
    merged = []
    seen: set[str] = set()
    for collection in (primary, secondary):
        for hit in collection:
            if hit.relative_path in seen:
                continue
            seen.add(hit.relative_path)
            merged.append(hit)
            if len(merged) >= max(limit, 1):
                return merged
    return merged

if __name__ == "__main__":
    main()
