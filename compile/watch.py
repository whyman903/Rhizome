"""Personalized automated pulls — periodic fetch + claude synthesis into wiki pages.

A watch is a wiki page (page_type=watch) plus a row in `.compile/watches.json`. The
page frontmatter is the source of truth for config; the JSON state file is a fast
scheduler index that can be rebuilt from frontmatter at any time.

Public surface:
    add_watch / list_watches / get_watch / pause_watch / resume_watch / remove_watch
    run_watch                       — synthesize a single watch right now
    tick                            — synthesize every watch whose next_run is due
    parse_frequency / next_fire_time — frequency vocabulary
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, asdict
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from pathlib import Path
import json
import os
import re
import subprocess
from typing import Any, Iterator
from uuid import uuid4

from compile.config import Config
from compile.fetch import fetch_url
from compile.obsidian import ObsidianConnector, VaultPage
from compile.page_types import WATCH_LIFECYCLE_STATES
from compile.text import slugify

WATCHES_DIR_NAME = "watches"
WATCH_RAW_DIR = "raw/watches"
DEFAULT_FREQUENCY = "daily"
ALLOWED_FREQUENCIES = {"hourly", "daily", "weekly"}
AUTO_PAUSE_FAILURES = 3
DEFAULT_CLAUDE_TIMEOUT = 300.0
DEFAULT_CLAUDE_EXECUTABLE = "claude"


# --------- Frequency parsing -----------------------------------------------------


@dataclass
class Frequency:
    """Normalized representation of a watch frequency."""
    kind: str            # "hourly" | "daily" | "weekly" | "cron"
    cron: str | None = None

    def serialize(self) -> str:
        if self.kind == "cron":
            return f"cron: {self.cron}"
        return self.kind


def parse_frequency(value: str) -> Frequency:
    text = (value or "").strip().lower()
    if not text:
        raise ValueError("frequency is required")
    if text in ALLOWED_FREQUENCIES:
        return Frequency(kind=text)
    if text.startswith("cron:"):
        cron = text[len("cron:"):].strip()
        if not cron:
            raise ValueError("cron frequency must include an expression after 'cron:'")
        _validate_cron_floor(cron)
        return Frequency(kind="cron", cron=cron)
    raise ValueError(
        f"unsupported frequency '{value}'. Use one of: hourly, daily, weekly, "
        "or 'cron: <expression>' (minimum cadence is hourly)."
    )


def _validate_cron_floor(cron: str) -> None:
    """Reject cron expressions that would fire more than once per hour.

    We only enforce the minute field — anything other than a fixed minute
    means the user is asking for sub-hour cadence (e.g. ``*/15``). We do not
    do full cron arithmetic; we just refuse the obvious sub-hour patterns.
    """
    fields = cron.split()
    if len(fields) < 5:
        raise ValueError(f"cron expression '{cron}' is incomplete (need 5 fields)")
    minute = fields[0]
    if minute == "*" or minute.startswith("*/") or "," in minute or "-" in minute:
        raise ValueError(
            f"cron minute field '{minute}' would fire more than once per hour. "
            "Watches run at most hourly — use a fixed minute (e.g. '0' for top of hour)."
        )


def next_fire_time(frequency: Frequency, *, after: datetime) -> datetime:
    """When should the next run happen, strictly after *after*."""
    if frequency.kind == "hourly":
        return _next_aligned(after, hours=1)
    if frequency.kind == "daily":
        return _next_aligned(after, days=1)
    if frequency.kind == "weekly":
        return _next_aligned(after, days=7)
    if frequency.kind == "cron":
        return _next_cron(after, frequency.cron or "")
    raise ValueError(f"unknown frequency kind: {frequency.kind}")


def _next_aligned(after: datetime, *, hours: int = 0, days: int = 0) -> datetime:
    base = after.astimezone(timezone.utc).replace(microsecond=0, second=0)
    if hours:
        base = base.replace(minute=0)
        return base + timedelta(hours=hours)
    if days:
        base = base.replace(minute=0, hour=0)
        return base + timedelta(days=days)
    return after + timedelta(hours=1)


def _next_cron(after: datetime, cron: str) -> datetime:
    """Minimal cron evaluator: handles 'M H DOM MON DOW' with M as a fixed integer.

    For fields beyond minute we honor lists (1,2,3), ranges (1-5), and '*'. This
    covers the realistic watch cron use cases ("every weekday at 9am",
    "every Monday at 8") without pulling in a full cron parser.
    """
    fields = cron.split()
    if len(fields) < 5:
        raise ValueError(f"cron expression '{cron}' is incomplete")
    minute = int(fields[0])
    hour_set = _cron_set(fields[1], 0, 23)
    dom_set = _cron_set(fields[2], 1, 31)
    mon_set = _cron_set(fields[3], 1, 12)
    dow_set = _cron_set(fields[4], 0, 6)  # cron Sunday=0; Python weekday() Monday=0
    candidate = after.astimezone(timezone.utc).replace(second=0, microsecond=0)
    candidate += timedelta(minutes=1)
    for _ in range(60 * 24 * 366):  # search up to a year
        if (
            candidate.minute == minute
            and candidate.hour in hour_set
            and candidate.day in dom_set
            and candidate.month in mon_set
            and ((candidate.weekday() + 1) % 7) in dow_set
        ):
            return candidate
        candidate += timedelta(minutes=1)
    raise ValueError(f"cron expression '{cron}' has no firing time within a year")


def _cron_set(field: str, lo: int, hi: int) -> set[int]:
    if field == "*":
        return set(range(lo, hi + 1))
    values: set[int] = set()
    for chunk in field.split(","):
        if "-" in chunk:
            start_s, end_s = chunk.split("-", 1)
            values.update(range(int(start_s), int(end_s) + 1))
        elif chunk.startswith("*/"):
            step = int(chunk[2:])
            values.update(range(lo, hi + 1, step))
        else:
            values.add(int(chunk))
    return {v for v in values if lo <= v <= hi}


# --------- Watch records ---------------------------------------------------------


@dataclass
class Watch:
    """User-facing watch summary; serialized for the CLI / Swift layer."""
    watch_id: str
    title: str
    relative_path: str
    url: str
    frequency: str
    intent: str
    watch_status: str            # active | paused | error
    last_status: str | None      # ok | failed | unchanged
    last_run: str | None
    next_run: str | None
    run_count: int
    consecutive_failures: int
    last_error: str | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _isoformat(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        text = str(value).strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except ValueError:
        return None


# --------- Public API ------------------------------------------------------------


def add_watch(
    config: Config,
    *,
    url: str,
    frequency: str,
    intent: str,
    title: str | None = None,
    tags: list[str] | None = None,
) -> Watch:
    """Create a new watch page and register it. Returns the Watch record."""
    url = url.strip()
    if not url:
        raise ValueError("url is required")
    intent = intent.strip()
    if not intent:
        raise ValueError("intent is required")
    frequency_obj = parse_frequency(frequency)

    resolved_title = (title or _title_from_url(url)).strip()
    connector = ObsidianConnector(config.workspace_root)
    if connector.find_upsert_target(title=resolved_title, page_type="watch"):
        # disambiguate by appending a counter
        for n in range(2, 100):
            candidate = f"{resolved_title} ({n})"
            if not connector.find_upsert_target(title=candidate, page_type="watch"):
                resolved_title = candidate
                break

    watch_id = str(uuid4())
    now = _utcnow()
    next_run = next_fire_time(frequency_obj, after=now)

    extra: dict[str, Any] = {
        "watch_id": watch_id,
        "watch_url": url,
        "watch_frequency": frequency_obj.serialize(),
        "watch_intent": intent,
        "watch_status": "active",
        "watch_last_run": None,
        "watch_next_run": _isoformat(next_run),
        "watch_run_count": 0,
        "watch_consecutive_failures": 0,
        "watch_last_status": None,
        "watch_last_error": None,
        "watch_last_content_hash": None,
    }

    body = _initial_body(intent=intent, url=url, frequency=frequency_obj.serialize())
    page = connector.upsert_page(
        title=resolved_title,
        body=body,
        page_type="watch",
        tags=sorted({"watch", *(tags or [])}),
        summary=_summary_from_intent(intent),
        extra_frontmatter=extra,
        ensure_title_heading=True,
    )
    _sync_state_from_pages(config)
    return _watch_from_page(page)


def list_watches(config: Config) -> list[Watch]:
    connector = ObsidianConnector(config.workspace_root)
    watches = [_watch_from_page(p) for p in connector.scan() if p.page_type == "watch"]
    watches.sort(key=lambda w: w.title.lower())
    return watches


def get_watch(config: Config, locator: str) -> Watch:
    page = _get_watch_page(config, locator)
    return _watch_from_page(page)


def pause_watch(config: Config, locator: str) -> Watch:
    return _set_status(config, locator, "paused")


def resume_watch(config: Config, locator: str) -> Watch:
    page = _get_watch_page(config, locator)
    frequency = parse_frequency(str(page.frontmatter.get("watch_frequency") or DEFAULT_FREQUENCY))
    next_run = next_fire_time(frequency, after=_utcnow())
    return _update_frontmatter(
        config,
        page,
        {
            "watch_status": "active",
            "watch_next_run": _isoformat(next_run),
            "watch_consecutive_failures": 0,
            "watch_last_error": None,
        },
    )


def remove_watch(config: Config, locator: str, *, keep_page: bool = False) -> str:
    page = _get_watch_page(config, locator)
    abs_path = config.workspace_root / page.relative_path
    if not keep_page and abs_path.exists():
        abs_path.unlink()
    _sync_state_from_pages(config)
    return page.relative_path


def run_watch(
    config: Config,
    locator: str,
    *,
    force: bool = False,
    claude_executable: str = DEFAULT_CLAUDE_EXECUTABLE,
    claude_timeout: float = DEFAULT_CLAUDE_TIMEOUT,
    now: datetime | None = None,
) -> dict[str, Any]:
    page = _get_watch_page(config, locator)
    return _run_one(
        config,
        page,
        force=force,
        claude_executable=claude_executable,
        claude_timeout=claude_timeout,
        now=now or _utcnow(),
    )


def tick(
    config: Config,
    *,
    claude_executable: str = DEFAULT_CLAUDE_EXECUTABLE,
    claude_timeout: float = DEFAULT_CLAUDE_TIMEOUT,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    """Run every active watch whose next_run is due. Returns one event per attempt."""
    moment = now or _utcnow()
    events: list[dict[str, Any]] = []
    connector = ObsidianConnector(config.workspace_root)
    watch_pages = [p for p in connector.scan() if p.page_type == "watch"]
    for page in watch_pages:
        watch = _watch_from_page(page)
        if watch.watch_status != "active":
            continue
        next_run = _parse_iso(watch.next_run)
        if next_run is not None and next_run > moment:
            continue
        events.append(
            _run_one(
                config,
                page,
                force=False,
                claude_executable=claude_executable,
                claude_timeout=claude_timeout,
                now=moment,
            )
        )
    return events


# --------- Internals -------------------------------------------------------------


def _run_one(
    config: Config,
    page: VaultPage,
    *,
    force: bool,
    claude_executable: str,
    claude_timeout: float,
    now: datetime,
) -> dict[str, Any]:
    watch = _watch_from_page(page)
    event: dict[str, Any] = {
        "watch_id": watch.watch_id,
        "title": watch.title,
        "relative_path": watch.relative_path,
        "started_at": _isoformat(now),
    }

    lock_path = _lockfile_for(config, watch.watch_id)
    with _watch_lock(lock_path) as acquired:
        if not acquired:
            event["status"] = "skipped"
            event["reason"] = "locked"
            return event

        try:
            raw_path, content_hash, fetch_skipped = _fetch_step(config, watch, force=force)
        except Exception as exc:  # noqa: BLE001 — surface any fetch failure to the user
            return _record_failure(config, page, event, str(exc), now=now)

        frequency = parse_frequency(watch.frequency)
        if fetch_skipped:
            update = {
                "watch_last_run": _isoformat(now),
                "watch_next_run": _isoformat(next_fire_time(frequency, after=now)),
                "watch_run_count": watch.run_count + 1,
                "watch_last_status": "unchanged",
                "watch_consecutive_failures": 0,
                "watch_last_error": None,
            }
            _update_frontmatter(config, page, update)
            event["status"] = "unchanged"
            event["raw_path"] = None
            return event

        try:
            digest = _synthesize_step(
                config,
                watch,
                raw_path=raw_path,
                claude_executable=claude_executable,
                claude_timeout=claude_timeout,
            )
        except Exception as exc:  # noqa: BLE001 — synthesis failures must auto-pause
            return _record_failure(config, page, event, str(exc), now=now)

        date_label = now.astimezone(timezone.utc).strftime("%Y-%m-%d")
        new_body = _prepend_digest_section(
            page.body,
            heading=f"## {date_label} — {watch.title}",
            digest=digest,
            raw_relative=str(raw_path.relative_to(config.workspace_root)).replace("\\", "/"),
            timestamp=_isoformat(now),
        )

        update = {
            "watch_last_run": _isoformat(now),
            "watch_next_run": _isoformat(next_fire_time(frequency, after=now)),
            "watch_run_count": watch.run_count + 1,
            "watch_last_status": "ok",
            "watch_consecutive_failures": 0,
            "watch_last_error": None,
            "watch_last_content_hash": content_hash,
        }
        _rewrite_page(config, page, body=new_body, extra_frontmatter=update)

        event["status"] = "ok"
        event["raw_path"] = str(raw_path.relative_to(config.workspace_root)).replace("\\", "/")
        return event


def _fetch_step(
    config: Config,
    watch: Watch,
    *,
    force: bool,
) -> tuple[Path, str, bool]:
    """Fetch the URL into raw/watches/<slug>/. Returns (path, hash, skipped).

    ``skipped`` is True when the fetched body hashes to the previously-stored
    hash and the user did not pass ``--force`` — saves Claude tokens.
    """
    slug = slugify(watch.title) or watch.watch_id[:8]
    target_dir = config.workspace_root / WATCH_RAW_DIR / slug
    target_dir.mkdir(parents=True, exist_ok=True)
    saved_path, _ = fetch_url(watch.url, target_dir)
    body_hash = sha256(saved_path.read_bytes()).hexdigest()
    page = _get_watch_page_by_id(config, watch.watch_id)
    previous_hash = str(page.frontmatter.get("watch_last_content_hash") or "")
    if not force and previous_hash and previous_hash == body_hash:
        # Drop the redundant copy so raw/watches/ does not balloon with duplicates.
        try:
            saved_path.unlink()
        except OSError:
            pass
        return saved_path, body_hash, True
    return saved_path, body_hash, False


def _synthesize_step(
    config: Config,
    watch: Watch,
    *,
    raw_path: Path,
    claude_executable: str,
    claude_timeout: float,
) -> str:
    fetched_text = raw_path.read_text(errors="replace")
    prompt = _build_synthesis_prompt(watch=watch, fetched_text=fetched_text)
    args = [
        claude_executable,
        "-p",
        "--output-format",
        "json",
        "--add-dir",
        str(config.wiki_dir),
        prompt,
    ]
    env = _claude_env(config)
    completed = subprocess.run(
        args,
        cwd=str(config.workspace_root),
        env=env,
        stdin=subprocess.DEVNULL,
        text=True,
        capture_output=True,
        timeout=claude_timeout,
        check=False,
    )
    if completed.returncode != 0:
        tail = (completed.stderr or "").strip().splitlines()[-1:] or [""]
        raise RuntimeError(f"claude exited with code {completed.returncode}: {tail[0]}")
    digest = _extract_claude_answer(completed.stdout)
    if not digest.strip():
        raise RuntimeError("claude returned an empty digest")
    return digest.strip()


def _build_synthesis_prompt(*, watch: Watch, fetched_text: str) -> str:
    truncated = fetched_text
    max_chars = 80_000
    if len(truncated) > max_chars:
        truncated = truncated[:max_chars] + "\n\n[truncated]"
    return (
        "You are running a recurring watch for a personal Obsidian wiki.\n\n"
        f"Source URL: {watch.url}\n"
        f"Watch title: {watch.title}\n\n"
        "User intent (verbatim — this is what they asked you to extract):\n"
        f"{watch.intent}\n\n"
        "Use [[wikilinks]] when a claim corresponds to an existing wiki page in "
        "the directory you have access to. Do not invent wikilinks for pages that "
        "do not already exist.\n\n"
        "Output ONLY the digest body in markdown — no frontmatter, no greeting, "
        "no meta-commentary, no surrounding code fence. Start with prose or a "
        "bullet list. The caller prepends a date heading; do not add one.\n\n"
        "--- BEGIN FETCHED CONTENT ---\n"
        f"{truncated}\n"
        "--- END FETCHED CONTENT ---\n"
    )


def _extract_claude_answer(stdout: str) -> str:
    """Pull the answer text out of `claude --output-format json` stdout."""
    text = stdout.strip()
    if not text:
        return ""
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        # Some claude versions emit an extra envelope; try the last JSON object.
        for chunk in reversed(text.split("\n")):
            chunk = chunk.strip()
            if chunk.startswith("{"):
                try:
                    payload = json.loads(chunk)
                    break
                except json.JSONDecodeError:
                    continue
        else:
            return text
    if isinstance(payload, dict):
        for key in ("result", "answer", "text", "output"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value
        message = payload.get("message")
        if isinstance(message, dict):
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and isinstance(block.get("text"), str):
                        return block["text"]
    return text


def _claude_env(config: Config) -> dict[str, str]:
    env = os.environ.copy()
    existing_path = env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    env["PATH"] = os.pathsep.join(
        [
            str(config.workspace_root / ".compile" / "rhizome-bin"),
            str(Path.home() / ".claude" / "local"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existing_path,
        ]
    )
    return env


def _record_failure(
    config: Config,
    page: VaultPage,
    event: dict[str, Any],
    error: str,
    *,
    now: datetime,
) -> dict[str, Any]:
    watch = _watch_from_page(page)
    consecutive = watch.consecutive_failures + 1
    update: dict[str, Any] = {
        "watch_last_run": _isoformat(now),
        "watch_last_status": "failed",
        "watch_last_error": error[:500],
        "watch_consecutive_failures": consecutive,
    }
    if consecutive >= AUTO_PAUSE_FAILURES:
        update["watch_status"] = "paused"
        update["watch_next_run"] = None
        event["auto_paused"] = True
    else:
        frequency = parse_frequency(watch.frequency)
        update["watch_next_run"] = _isoformat(next_fire_time(frequency, after=now))
    _update_frontmatter(config, page, update)
    event["status"] = "failed"
    event["error"] = error
    return event


def _set_status(config: Config, locator: str, status: str) -> Watch:
    if status not in WATCH_LIFECYCLE_STATES:
        raise ValueError(f"unknown watch status '{status}'")
    page = _get_watch_page(config, locator)
    update: dict[str, Any] = {"watch_status": status}
    if status == "paused":
        update["watch_next_run"] = None
    return _update_frontmatter(config, page, update)


def _update_frontmatter(
    config: Config,
    page: VaultPage,
    update: dict[str, Any],
) -> Watch:
    return _rewrite_page(config, page, body=page.body, extra_frontmatter=update)


def _rewrite_page(
    config: Config,
    page: VaultPage,
    *,
    body: str,
    extra_frontmatter: dict[str, Any],
) -> Watch:
    connector = ObsidianConnector(config.workspace_root)
    new_page = connector.upsert_page(
        title=page.title,
        body=body,
        page_type="watch",
        tags=page.tags,
        sources=[],
        aliases=page.aliases,
        summary=str(page.frontmatter.get("summary") or "").strip() or None,
        relative_path=page.relative_path,
        extra_frontmatter=extra_frontmatter,
        ensure_title_heading=False,
    )
    _sync_state_from_pages(config)
    return _watch_from_page(new_page)


def _initial_body(*, intent: str, url: str, frequency: str) -> str:
    return (
        "> [!note] Automated watch\n"
        f"> Pulls from {url} on a {frequency} schedule and synthesizes against the intent below.\n\n"
        "## Intent\n\n"
        f"{intent}\n\n"
        "## Digests\n\n"
        "_No runs yet. Use `compile watch run \"this watch\"` to fire one now._\n"
    )


def _summary_from_intent(intent: str) -> str:
    cleaned = re.sub(r"\s+", " ", intent.strip())
    return cleaned[:160]


def _title_from_url(url: str) -> str:
    """Best-effort title for a freshly-added watch when the user did not supply one."""
    cleaned = url
    cleaned = re.sub(r"^https?://(www\.)?", "", cleaned)
    cleaned = cleaned.strip("/")
    if not cleaned:
        return "Watch"
    return f"Watch: {cleaned[:80]}"


def _prepend_digest_section(
    existing_body: str,
    *,
    heading: str,
    digest: str,
    raw_relative: str,
    timestamp: str,
) -> str:
    """Insert the new digest entry directly under the ``## Digests`` heading.

    Keeps reverse-chronological order — newest first — and strips the placeholder
    "no runs yet" line on first run.
    """
    digest_block = (
        f"{heading}\n\n"
        f"{digest.rstrip()}\n\n"
        f"— Source: [{raw_relative}]({raw_relative}) · synthesized {timestamp}\n"
    )
    body = existing_body or ""
    digests_marker = "## Digests"
    if digests_marker in body:
        before, _, after_marker = body.partition(digests_marker)
        # Drop the line break that immediately follows the heading and any
        # placeholder paragraph, then prepend the new block.
        after_lines = after_marker.lstrip("\n").splitlines()
        # the first non-empty line after the heading might be the placeholder
        rebuilt: list[str] = []
        skipped_placeholder = False
        for line in after_lines:
            if not skipped_placeholder and line.strip().startswith("_No runs yet"):
                skipped_placeholder = True
                continue
            rebuilt.append(line)
        tail = "\n".join(rebuilt).lstrip("\n")
        suffix = ("\n\n" + tail).rstrip() + "\n" if tail.strip() else "\n"
        return f"{before}{digests_marker}\n\n{digest_block.rstrip()}{suffix}"
    return f"{body.rstrip()}\n\n{digests_marker}\n\n{digest_block}"


def _watch_from_page(page: VaultPage) -> Watch:
    fm = page.frontmatter
    return Watch(
        watch_id=str(fm.get("watch_id") or ""),
        title=page.title,
        relative_path=page.relative_path,
        url=str(fm.get("watch_url") or ""),
        frequency=str(fm.get("watch_frequency") or DEFAULT_FREQUENCY),
        intent=str(fm.get("watch_intent") or ""),
        watch_status=str(fm.get("watch_status") or "active"),
        last_status=(str(fm.get("watch_last_status")) if fm.get("watch_last_status") else None),
        last_run=(str(fm.get("watch_last_run")) if fm.get("watch_last_run") else None),
        next_run=(str(fm.get("watch_next_run")) if fm.get("watch_next_run") else None),
        run_count=int(fm.get("watch_run_count") or 0),
        consecutive_failures=int(fm.get("watch_consecutive_failures") or 0),
        last_error=(str(fm.get("watch_last_error")) if fm.get("watch_last_error") else None),
    )


def _get_watch_page(config: Config, locator: str) -> VaultPage:
    """Resolve a watch by title, watch_id, slug, or relative path."""
    connector = ObsidianConnector(config.workspace_root)
    pages = [p for p in connector.scan() if p.page_type == "watch"]
    needle = locator.strip()
    for page in pages:
        if str(page.frontmatter.get("watch_id")) == needle:
            return page
    for page in pages:
        if page.title == needle or page.relative_path == needle:
            return page
    # fall back to the connector's fuzzy locator, restricted to watches
    try:
        candidate = connector.get_page(locator)
    except (FileNotFoundError, ValueError) as exc:
        raise FileNotFoundError(f"no watch matched '{locator}'") from exc
    if candidate.page_type != "watch":
        raise FileNotFoundError(f"page '{locator}' is not a watch")
    return candidate


def _get_watch_page_by_id(config: Config, watch_id: str) -> VaultPage:
    connector = ObsidianConnector(config.workspace_root)
    for page in connector.scan():
        if page.page_type == "watch" and str(page.frontmatter.get("watch_id")) == watch_id:
            return page
    raise FileNotFoundError(f"no watch with id '{watch_id}'")


def _lockfile_for(config: Config, watch_id: str) -> Path:
    lock_dir = config.compile_dir / "watches"
    lock_dir.mkdir(parents=True, exist_ok=True)
    return lock_dir / f"{watch_id}.lock"


@contextmanager
def _watch_lock(lock_path: Path) -> Iterator[bool]:
    """Best-effort exclusive lock for a single watch run."""
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        yield False
        return
    try:
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        yield True
    finally:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


def _sync_state_from_pages(config: Config) -> None:
    """Rebuild .compile/watches.json from frontmatter. Source of truth is the page."""
    state_path = config.compile_dir / "watches.json"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    watches = [w.to_dict() for w in list_watches(config)]
    state_path.write_text(json.dumps({"watches": watches}, indent=2, sort_keys=True))


def state_path(config: Config) -> Path:
    return config.compile_dir / "watches.json"
