from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from hashlib import sha256
import json
from pathlib import Path
from typing import Any

from compile.config import Config
from compile.dates import now_machine
from compile.text import ExtractedPageText, ExtractedSource, source_from_pdf_pages, title_from_path


EXTRACTED_ARTIFACT_SCHEMA_VERSION = 1
PDF_MEDIA_TYPE = "application/pdf"
PDF_EXTRACTOR_NAME = "pymupdf_text"
PDF_EXTRACTION_MODE = "text"


@dataclass(frozen=True)
class ExtractedArtifact:
    schema_version: int
    raw_path: str
    raw_sha256: str
    media_type: str
    extractor_name: str
    extractor_version: str
    extracted_at: str
    extraction_mode: str
    requires_document_review: bool
    warnings: tuple[str, ...]
    pages: tuple[ExtractedPageText, ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def compute_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sidecar_path_for_sha(config: Config, raw_sha256: str) -> Path:
    return config.extract_dir / f"{raw_sha256}.json"


def load_pdf_artifact(config: Config, raw_sha256: str) -> ExtractedArtifact | None:
    path = sidecar_path_for_sha(config, raw_sha256)
    if not path.exists():
        return None
    return load_pdf_artifact_path(path)


def load_pdf_artifact_path(path: Path) -> ExtractedArtifact:
    payload = json.loads(path.read_text())
    if int(payload.get("schema_version") or 0) != EXTRACTED_ARTIFACT_SCHEMA_VERSION:
        raise ValueError(f"Unsupported extracted artifact schema: {payload.get('schema_version')}")

    try:
        pages = tuple(
            ExtractedPageText(
                page_number=int(page["page_number"]),
                text=str(page["text"]),
            )
            for page in payload.get("pages") or []
            if str(page.get("text") or "").strip()
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"Malformed extracted artifact: {path}") from exc
    if not pages:
        raise ValueError(f"Extracted artifact has no pages: {path}")

    return ExtractedArtifact(
        schema_version=EXTRACTED_ARTIFACT_SCHEMA_VERSION,
        raw_path=str(payload.get("raw_path") or ""),
        raw_sha256=str(payload.get("raw_sha256") or ""),
        media_type=str(payload.get("media_type") or PDF_MEDIA_TYPE),
        extractor_name=str(payload.get("extractor_name") or PDF_EXTRACTOR_NAME),
        extractor_version=str(payload.get("extractor_version") or ""),
        extracted_at=str(payload.get("extracted_at") or ""),
        extraction_mode=str(payload.get("extraction_mode") or PDF_EXTRACTION_MODE),
        requires_document_review=bool(payload.get("requires_document_review", True)),
        warnings=tuple(str(item) for item in payload.get("warnings") or []),
        pages=pages,
    )


def save_pdf_artifact(config: Config, artifact: ExtractedArtifact) -> Path:
    config.extract_dir.mkdir(parents=True, exist_ok=True)
    path = sidecar_path_for_sha(config, artifact.raw_sha256)
    path.write_text(json.dumps(artifact.to_dict(), indent=2, sort_keys=False))
    return path


def align_artifact_raw_path(
    config: Config,
    artifact: ExtractedArtifact,
    raw_relative: str,
) -> ExtractedArtifact:
    if artifact.raw_path == raw_relative:
        return artifact
    updated = replace(artifact, raw_path=raw_relative)
    save_pdf_artifact(config, updated)
    return updated


def build_pdf_artifact(
    *,
    raw_relative: str,
    raw_sha256: str,
    extracted: ExtractedSource,
) -> ExtractedArtifact:
    if extracted.metadata_only or not extracted.page_texts:
        raise ValueError("Cannot build a PDF artifact from metadata-only extraction.")
    return ExtractedArtifact(
        schema_version=EXTRACTED_ARTIFACT_SCHEMA_VERSION,
        raw_path=raw_relative,
        raw_sha256=raw_sha256,
        media_type=PDF_MEDIA_TYPE,
        extractor_name=PDF_EXTRACTOR_NAME,
        extractor_version=_extractor_version(),
        extracted_at=now_machine(),
        extraction_mode=PDF_EXTRACTION_MODE,
        requires_document_review=extracted.requires_document_review,
        warnings=tuple(extracted.warnings),
        pages=tuple(extracted.page_texts),
    )


def extracted_source_from_artifact(artifact: ExtractedArtifact) -> ExtractedSource:
    return source_from_pdf_pages(
        title_from_path(Path(artifact.raw_path)),
        tuple(artifact.pages),
        warnings=tuple(artifact.warnings),
        requires_document_review=artifact.requires_document_review,
    )


def _extractor_version() -> str:
    try:
        import fitz
    except ModuleNotFoundError:
        return ""
    return str(getattr(fitz, "VersionBind", "") or "")
