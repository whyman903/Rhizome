from __future__ import annotations

import json
import os
from pathlib import Path
import sqlite3

from compile.config import Config
from compile.markdown import WORD_RE
from compile.obsidian import ObsidianConnector, SearchHit
from compile.pdf_artifacts import (
    ExtractedArtifact,
    align_artifact_raw_path,
    build_pdf_artifact,
    compute_sha256,
    load_pdf_artifact,
    load_pdf_artifact_path,
    save_pdf_artifact,
)
from compile.text import extract_source, is_generated_raw_asset, title_from_path


CHUNK_TARGET_CHARS = 900
CHUNK_MAX_CHARS = 1400
CHUNK_OVERLAP_CHARS = 100


def search_index_exists(config: Config) -> bool:
    return config.search_index_path.exists()


def rebuild_search_index(
    config: Config,
    *,
    connector: ObsidianConnector | None = None,
) -> dict[str, int]:
    connector = connector or ObsidianConnector(config.workspace_root)
    rows: list[tuple[str, str, str, str, str, str, int, int, str]] = []
    live_paths_by_sha: dict[str, set[str]] = {}
    stats = {
        "pdfs_scanned": 0,
        "reused_sidecars": 0,
        "created_sidecars": 0,
        "deleted_orphans": 0,
        "indexed_pages": 0,
        "indexed_chunks": 0,
        "unextractable_pdfs": 0,
    }

    for raw_path in _iter_live_pdf_files(config):
        stats["pdfs_scanned"] += 1
        raw_relative = str(raw_path.relative_to(config.workspace_root)).replace("\\", "/")
        raw_sha256 = compute_sha256(raw_path)
        live_paths_by_sha.setdefault(raw_sha256, set()).add(raw_relative)

        try:
            artifact, reused = _load_or_extract_artifact(
                config,
                raw_path=raw_path,
                raw_relative=raw_relative,
                raw_sha256=raw_sha256,
            )
        except Exception:
            stats["unextractable_pdfs"] += 1
            continue
        if artifact is None:
            stats["unextractable_pdfs"] += 1
            continue
        if reused:
            stats["reused_sidecars"] += 1
        else:
            stats["created_sidecars"] += 1

        page_meta = _page_metadata_for_raw(connector, raw_relative)
        chunk_count = _append_artifact_rows(rows, artifact=artifact, page_meta=page_meta)
        if chunk_count:
            stats["indexed_pages"] += 1
            stats["indexed_chunks"] += chunk_count

    stats["deleted_orphans"] = _delete_orphan_sidecars(config, live_paths_by_sha)
    _write_search_db(config.search_index_path, rows)
    return stats


def search_pdf_index(
    config: Config,
    query: str,
    *,
    limit: int = 10,
    connector: ObsidianConnector | None = None,
) -> list[SearchHit]:
    if not search_index_exists(config):
        return []

    match_query = _fts_match_query(query)
    if not match_query:
        return []

    connection = sqlite3.connect(config.search_index_path)
    connection.row_factory = sqlite3.Row
    try:
        rows = connection.execute(
            """
            SELECT
              display_title,
              display_relative_path,
              page_type,
              page_summary,
              raw_path,
              page_number,
              snippet(chunks, -1, '', '', '...', 18) AS snippet,
              bm25(chunks) AS rank
            FROM chunks
            WHERE chunks MATCH ?
            ORDER BY rank ASC, display_title COLLATE NOCASE ASC
            LIMIT ?
            """,
            (match_query, max(limit, 1) * 6),
        ).fetchall()
    finally:
        connection.close()

    grouped: dict[str, SearchHit] = {}
    ordered_paths: list[str] = []
    for row in rows:
        title, relative_path, page_type, page_summary = _resolve_search_display_metadata(
            connector=connector,
            raw_relative=str(row["raw_path"] or ""),
            fallback_title=str(row["display_title"]),
            fallback_relative_path=str(row["display_relative_path"]),
            fallback_page_type=str(row["page_type"]),
            fallback_summary=str(row["page_summary"] or ""),
        )
        if relative_path in grouped:
            continue
        rank = float(row["rank"] or 0.0)
        score = max(1, int(round(1000 / (1.0 + abs(rank)))))
        grouped[relative_path] = SearchHit(
            title=title,
            relative_path=relative_path,
            page_type=page_type,
            summary=page_summary,
            score=score,
            reasons=["fts5-chunk"],
            snippet=str(row["snippet"] or "").strip(),
        )
        ordered_paths.append(relative_path)
        if len(ordered_paths) >= max(limit, 1):
            break

    return [grouped[path] for path in ordered_paths]


def sync_pdf_search_index(
    config: Config,
    *,
    raw_relative: str,
    artifact: ExtractedArtifact | None,
    display_title: str,
    display_relative_path: str,
    page_type: str,
    page_summary: str,
) -> dict[str, int]:
    if artifact is None and not search_index_exists(config):
        return {"deleted_chunks": 0, "indexed_chunks": 0}

    config.index_dir.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(config.search_index_path)
    try:
        _ensure_search_schema(connection)
        delete_cursor = connection.execute(
            "DELETE FROM chunks WHERE raw_path = ?",
            (raw_relative,),
        )
        deleted_chunks = max(int(delete_cursor.rowcount or 0), 0)

        indexed_chunks = 0
        if artifact is not None:
            rows: list[tuple[str, str, str, str, str, str, int, int, str]] = []
            indexed_chunks = _append_artifact_rows(
                rows,
                artifact=artifact,
                page_meta=(display_title, display_relative_path, page_type, page_summary),
            )
            if rows:
                connection.executemany(
                    """
                    INSERT INTO chunks (
                      display_relative_path,
                      display_title,
                      page_type,
                      page_summary,
                      raw_path,
                      raw_sha256,
                      page_number,
                      chunk_index,
                      chunk_text
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    rows,
                )
        connection.commit()
    finally:
        connection.close()

    return {"deleted_chunks": deleted_chunks, "indexed_chunks": indexed_chunks}


def _iter_live_pdf_files(config: Config) -> list[Path]:
    if not config.raw_dir.is_dir():
        return []

    files: list[Path] = []
    for current_root, dirs, filenames in os.walk(config.raw_dir):
        dirs[:] = [name for name in dirs if not name.startswith(".")]
        for filename in filenames:
            if filename.startswith(".") or not filename.lower().endswith(".pdf"):
                continue
            path = Path(current_root) / filename
            if is_generated_raw_asset(path):
                continue
            files.append(path)
    return sorted(files)


def _load_or_extract_artifact(
    config: Config,
    *,
    raw_path: Path,
    raw_relative: str,
    raw_sha256: str,
) -> tuple[ExtractedArtifact | None, bool]:
    try:
        artifact = load_pdf_artifact(config, raw_sha256)
    except (json.JSONDecodeError, ValueError):
        artifact = None
    if artifact is not None:
        return align_artifact_raw_path(config, artifact, raw_relative), True

    extracted = extract_source(raw_path)
    if extracted.metadata_only or not extracted.page_texts:
        return None, False

    artifact = build_pdf_artifact(
        raw_relative=raw_relative,
        raw_sha256=raw_sha256,
        extracted=extracted,
    )
    save_pdf_artifact(config, artifact)
    return artifact, False


def _page_metadata_for_raw(
    connector: ObsidianConnector,
    raw_relative: str,
) -> tuple[str, str, str, str]:
    try:
        source_page = connector.find_source_page_by_raw_path(raw_relative)
    except ValueError:
        source_page = None

    if source_page is not None:
        return (
            source_page.title,
            source_page.relative_path,
            source_page.page_type,
            str(source_page.frontmatter.get("summary") or ""),
        )

    return (
        title_from_path(Path(raw_relative)),
        raw_relative,
        "raw_pdf",
        "",
    )


def _append_artifact_rows(
    rows: list[tuple[str, str, str, str, str, str, int, int, str]],
    *,
    artifact: ExtractedArtifact,
    page_meta: tuple[str, str, str, str],
) -> int:
    display_title, display_relative_path, page_type, page_summary = page_meta
    chunk_count = 0
    for page in artifact.pages:
        for chunk_index, chunk_text in enumerate(_chunk_text(page.text), start=1):
            rows.append(
                (
                    display_relative_path,
                    display_title,
                    page_type,
                    page_summary,
                    artifact.raw_path,
                    artifact.raw_sha256,
                    page.page_number,
                    chunk_index,
                    chunk_text,
                )
            )
            chunk_count += 1
    return chunk_count


def _chunk_text(text: str) -> list[str]:
    compact = " ".join(text.split()).strip()
    if not compact:
        return []
    if len(compact) <= CHUNK_MAX_CHARS:
        return [compact]

    chunks: list[str] = []
    start = 0
    text_length = len(compact)
    while start < text_length:
        target_end = min(text_length, start + CHUNK_TARGET_CHARS)
        hard_end = min(text_length, start + CHUNK_MAX_CHARS)
        if hard_end >= text_length:
            end = text_length
        else:
            end = compact.rfind(" ", target_end, hard_end)
            if end <= start:
                end = hard_end
        chunk = compact[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= text_length:
            break
        next_start = max(0, end - CHUNK_OVERLAP_CHARS)
        if next_start <= start:
            next_start = end
        start = next_start
    return chunks


def _delete_orphan_sidecars(config: Config, live_paths_by_sha: dict[str, set[str]]) -> int:
    if not config.extract_dir.is_dir():
        return 0

    deleted = 0
    for sidecar_path in sorted(config.extract_dir.glob("*.json")):
        try:
            artifact = load_pdf_artifact_path(sidecar_path)
        except (json.JSONDecodeError, ValueError):
            sidecar_path.unlink(missing_ok=True)
            deleted += 1
            continue
        live_paths = live_paths_by_sha.get(artifact.raw_sha256)
        if not live_paths or artifact.raw_path not in live_paths:
            sidecar_path.unlink(missing_ok=True)
            deleted += 1
    return deleted


def _write_search_db(
    search_index_path: Path,
    rows: list[tuple[str, str, str, str, str, str, int, int, str]],
) -> None:
    search_index_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = search_index_path.with_suffix(".tmp")
    temp_path.unlink(missing_ok=True)

    connection = sqlite3.connect(temp_path)
    try:
        _ensure_search_schema(connection)
        if rows:
            connection.executemany(
                """
                INSERT INTO chunks (
                  display_relative_path,
                  display_title,
                  page_type,
                  page_summary,
                  raw_path,
                  raw_sha256,
                  page_number,
                  chunk_index,
                  chunk_text
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
        connection.commit()
    finally:
        connection.close()

    temp_path.replace(search_index_path)


def _ensure_search_schema(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
          display_relative_path UNINDEXED,
          display_title UNINDEXED,
          page_type UNINDEXED,
          page_summary UNINDEXED,
          raw_path UNINDEXED,
          raw_sha256 UNINDEXED,
          page_number UNINDEXED,
          chunk_index UNINDEXED,
          chunk_text
        )
        """
    )


def _fts_match_query(query: str) -> str:
    terms = [term for term in WORD_RE.findall(query) if any(ch.isalnum() for ch in term)]
    return " ".join(f'"{term}"' for term in terms)


def _resolve_search_display_metadata(
    *,
    connector: ObsidianConnector | None,
    raw_relative: str,
    fallback_title: str,
    fallback_relative_path: str,
    fallback_page_type: str,
    fallback_summary: str,
) -> tuple[str, str, str, str]:
    fallback = (fallback_title, fallback_relative_path, fallback_page_type, fallback_summary)
    if connector is None:
        return fallback
    try:
        source_page = connector.find_source_page_by_raw_path(raw_relative)
    except ValueError:
        source_page = None
    if source_page is None:
        return fallback
    return (
        source_page.title,
        source_page.relative_path,
        source_page.page_type,
        str(source_page.frontmatter.get("summary") or ""),
    )
