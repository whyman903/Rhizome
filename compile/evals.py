from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any, Callable
from uuid import uuid4

from compile.config import Config
from compile.workspace import get_status


SCHEMA_VERSION = 1
DEFAULT_MODEL = "sonnet"
ALLOWED_TOOLS = "Read,Grep,Glob,LS,Bash,Task,WebSearch,WebFetch"
DISALLOWED_TOOLS = "AskUserQuestion,Monitor,Edit,Write,NotebookEdit,MultiEdit"
RESEARCH_TOOL_NAMES = {
    "Bash",
    "Glob",
    "Grep",
    "Read",
    "Task",
    "WebFetch",
    "WebSearch",
}
MAX_TOOL_INPUT_CHARS = 1_500
MAX_TOOL_RESULT_PREVIEW_CHARS = 1_500
MAX_STDERR_CHARS = 8_000
MAX_UNPARSED_STDOUT_CHARS = 8_000


# Each query is shaped to probe a distinct *pattern* of question, not just a
# distinct topic. The set spans short factual lookups, casual chat tone,
# explicit format triggers (table / canvas / mermaid / marp / chart),
# brief callbacks, quote retrieval, yes/no existence checks, counting and
# temporal-recency inventory, false-premise hallucination probes, multi-hop
# reasoning over the wiki graph, applied drafting tasks, editorial judgment
# under the wiki's own rules, out-of-domain-but-answerable refusal bait,
# absence-with-fallback, and formatting-rule probes (LaTeX-not-Unicode).
STARTER_QUERIES: list[dict[str, Any]] = [
    {
        "id": "tcp-udp",
        "query": "what's the difference between TCP and UDP?",
    },
    {
        "id": "codebleu-side",
        "query": "what's the difference between CodeBLEU and SIDE? What does CodeBLEU change from normal BLEU?",
    },
    {
        "id": "four-moral-theories-table",
        "query": (
            "compare the four moral theories from my ethics course "
            "(consequentialism, Kantian deontology, contractualism, "
            "objective-list / hybrid well-being) on what makes an act right "
            "and one representative thinker for each"
        ),
    },
    {
        "id": "inference-bottlenecks-table",
        "query": (
            "compare vLLM, DFlash, and MinerU2.5: what serial bottleneck does "
            "each one attack, and what is the architectural fix?"
        ),
    },
    {
        "id": "bullshitters-paper-canvas",
        "query": (
            "lay out how the LLM bullshitters paper argument hangs together: "
            "Frankfurt, Nguyen, Anderson, Farkas and Shou, and 'epistemic "
            "pollution' — show which sources support which moves and which "
            "sources push against the framing"
        ),
    },
    {
        "id": "migration-typology-canvas",
        "query": (
            "Sanjek lays out seven migration processes — show me how they "
            "relate as a typology, and which ones layer onto the contemporary "
            "United States"
        ),
    },
    {
        "id": "dl4se-course-arc-mermaid",
        "query": (
            "walk me through the DL4SE lecture sequence from MSR (lecture 2) "
            "through RAG (lecture 10): what builds on what?"
        ),
    },
    {
        "id": "prevention-through-deterrence-mermaid",
        "query": (
            "trace McGuire's causal argument that the US 'Prevention Through "
            "Deterrence' policy turns the Sonoran Desert itself into an agent "
            "of state violence — step through the chain"
        ),
    },
    {
        "id": "frankfurt-teaching-deck",
        "query": (
            "I'm giving a 10-minute talk explaining Frankfurt's notion of "
            "bullshit and why it matters for thinking about LLMs — build me "
            "the deck"
        ),
    },
    {
        "id": "luders-correlations-chart",
        "query": (
            "what correlations does the Lüders 2023 attitude-networks paper "
            "report between partisan identity and attitude positions, and how "
            "should I visualize them at a glance?"
        ),
    },
    {
        "id": "paged-attention-casual",
        "query": "what's the deal with PagedAttention?",
    },
    {
        "id": "chamber-callback",
        "query": "remind me what an epistemic chamber is, in a couple sentences",
    },
    {
        "id": "frankfurt-bullshit-quote",
        "query": (
            "what's Frankfurt's actual definition of bullshit, in his own "
            "words? I want a real quote, not a paraphrase."
        ),
    },
    {
        "id": "future-like-ours-yesno",
        "query": "do I have anything on Marquis's 'future like ours' argument?",
    },
    {
        "id": "recent-ingests-grouped",
        "query": (
            "what did I add to the wiki in the last two weeks? group it by "
            "topic so I can see what I've been focused on."
        ),
    },
    {
        "id": "contractualism-source-count",
        "query": (
            "how many source notes do I have that engage contractualism — "
            "Hobbes, Locke, Rachels, Carruthers, Scanlon, anything in that "
            "family? give me the count and the list."
        ),
    },
    {
        "id": "quantum-computing-false-premise",
        "query": "summarize my notes on quantum computing",
    },
    {
        "id": "biggest-cluster-disagreement",
        "query": (
            "for whichever topic I have the most source notes on, find the "
            "two sources that push hardest against each other and tell me "
            "what the disagreement actually is."
        ),
    },
    {
        "id": "bullshitters-thesis-draft",
        "query": (
            "draft a one-sentence thesis statement for my LLM bullshitters "
            "paper, using only what's already in the wiki"
        ),
    },
    {
        "id": "memory-trick-exam",
        "query": (
            "give me a memory trick for keeping the four moral theories "
            "straight before my ethics exam tomorrow"
        ),
    },
    {
        "id": "likely-duplicate-notes",
        "query": (
            "are there likely-duplicate notes in my philosophy or truth and "
            "post-truth materials? name the pairs and say which one to keep."
        ),
    },
    {
        "id": "stable-articles-honest-audit",
        "query": (
            "list every article currently marked status: stable in my wiki, "
            "and tell me — using my own Status Discipline rules in CLAUDE.md "
            "— whether each one actually meets the bar"
        ),
    },
    {
        "id": "hobbes-locke-state-of-nature",
        "query": (
            "compare Hobbes and Locke on the state of nature, and explain "
            "how their different premises drive opposite conclusions about "
            "the limits of sovereign power"
        ),
    },
    {
        "id": "system-design-prep-plan",
        "query": (
            "I have a system design interview tomorrow morning. Using only "
            "what's already in my wiki, build me a high-leverage prep plan "
            "— what to review, in what order, and why."
        ),
    },
    {
        "id": "grpo-absence",
        "query": (
            "do I have anything in the wiki on GRPO (Group Relative Policy "
            "Optimization)? If not, say what you searched for and then "
            "explain GRPO from general knowledge."
        ),
    },
    {
        "id": "attention-formula-latex",
        "query": (
            "explain how scaled dot-product attention is computed, including "
            "the formula. Use proper LaTeX math, not Unicode."
        ),
    },
]


class EvalSuiteError(ValueError):
    pass


@dataclass(frozen=True)
class EvalSuite:
    name: str
    path: Path
    queries: list[dict[str, Any]]
    description: str = ""


def suite_dir(config: Config) -> Path:
    # Suite definitions are config-shaped: tooling state, not user-facing.
    # They live in the hidden runtime directory inside the workspace.
    return config.compile_dir / "evals" / "suites"


def run_dir() -> Path:
    # Run output is a deliberately produced artifact the user reads. It
    # follows the user's current working directory so results land wherever
    # they're working from (typically the project they invoke the CLI in),
    # not buried in the wiki workspace.
    return Path.cwd() / "evals" / "runs"


def default_suite_path(config: Config, name: str) -> Path:
    return suite_dir(config) / f"{_slugify(name)}.json"


def build_run_output_path(
    suite_name: str,
    timestamp: datetime | None = None,
    *,
    runs_dir: Path | None = None,
) -> Path:
    timestamp = timestamp or datetime.now(timezone.utc)
    stamp = timestamp.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = runs_dir if runs_dir is not None else run_dir()
    return base / f"{stamp}-{_slugify(suite_name)}.json"


def write_starter_suite(config: Config, name: str = "query-quality", *, force: bool = False) -> Path:
    path = default_suite_path(config, name)
    if path.exists() and not force:
        raise EvalSuiteError(f"Eval suite already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "name": name,
        "description": (
            "Prompt-only query-quality suite covering format-trigger fit "
            "(table / canvas / mermaid / marp / chart / callout / prose), "
            "wiki-first research, citation quality, partial-coverage and "
            "absence handling, synthesis of disagreement, save-flow "
            "correctness, and avoidance of refusals, knowledge-cutoff "
            "excuses, or false save claims."
        ),
        "queries": STARTER_QUERIES,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return path


def resolve_suite_path(config: Config, suite: str) -> Path:
    candidate = Path(suite).expanduser()
    if candidate.suffix == ".json" or candidate.parent != Path(".") or candidate.exists():
        return candidate.resolve()
    return default_suite_path(config, suite).resolve()


def load_eval_suite(config: Config, suite: str) -> EvalSuite:
    path = resolve_suite_path(config, suite)
    try:
        payload = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise EvalSuiteError(f"Eval suite not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise EvalSuiteError(f"Eval suite is not valid JSON: {path}: {exc}") from exc
    return validate_eval_suite(payload, path=path)


def validate_eval_suite(payload: dict[str, Any], *, path: Path) -> EvalSuite:
    if not isinstance(payload, dict):
        raise EvalSuiteError("Eval suite must be a JSON object.")
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise EvalSuiteError(f"Eval suite schemaVersion must be {SCHEMA_VERSION}.")

    name = str(payload.get("name") or path.stem).strip()
    if not name:
        raise EvalSuiteError("Eval suite must have a non-empty name.")

    raw_queries = payload.get("queries")
    if not isinstance(raw_queries, list) or not raw_queries:
        raise EvalSuiteError("Eval suite must contain a non-empty queries array.")

    queries: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for index, item in enumerate(raw_queries, start=1):
        if not isinstance(item, dict):
            raise EvalSuiteError(f"Query {index} must be an object.")
        query_id = str(item.get("id") or "").strip()
        query = str(item.get("query") or "").strip()
        if not query_id:
            raise EvalSuiteError(f"Query {index} must have a non-empty id.")
        if query_id in seen_ids:
            raise EvalSuiteError(f"Duplicate query id: {query_id}")
        if not query:
            raise EvalSuiteError(f"Query {query_id} must have a non-empty query.")
        seen_ids.add(query_id)
        queries.append({"id": query_id, "query": query})

    return EvalSuite(
        name=name,
        path=path,
        description=str(payload.get("description") or ""),
        queries=queries,
    )


def run_eval_suite(
    config: Config,
    suite: EvalSuite,
    *,
    limit: int | None = None,
    timeout_seconds: float = 600,
    claude_executable: str = "claude",
    concurrency: int = 4,
    progress: Callable[[int, int, dict[str, Any], dict[str, Any]], None] | None = None,
) -> dict[str, Any]:
    queries = suite.queries[:limit] if limit is not None else suite.queries
    effective_concurrency = max(1, min(concurrency, max(len(queries), 1)))
    started = _utc_now()
    run_id = uuid4().hex
    workspace_info = get_status(config)

    results = _execute_eval_queries(
        config,
        queries,
        timeout_seconds=timeout_seconds,
        claude_executable=claude_executable,
        concurrency=effective_concurrency,
        progress=progress,
    )

    finished = _utc_now()
    completed = sum(1 for result in results if result["status"] == "completed")
    failed = len(results) - completed
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "compile.query-eval.run",
        "runID": run_id,
        "suite": {
            "name": suite.name,
            "path": str(suite.path),
            "description": suite.description,
            "queryCount": len(suite.queries),
            "executedQueryCount": len(queries),
        },
        "workspace": _workspace_payload(config, workspace_info),
        "runner": {
            "profile": "mywiki-headless-query-command",
            "queryCommand": "/query",
            "model": DEFAULT_MODEL,
            "claudeExecutable": claude_executable,
            "claudeVersion": claude_version(claude_executable),
            "allowedTools": ALLOWED_TOOLS.split(","),
            "disallowedTools": DISALLOWED_TOOLS.split(","),
            "timeoutSeconds": timeout_seconds,
            "concurrency": effective_concurrency,
            "researchGuard": {
                "retryAnswerWithoutResearch": True,
                "retryInterruptedFinalAnswer": True,
                "researchTools": sorted(RESEARCH_TOOL_NAMES),
            },
        },
        "startedAt": started,
        "finishedAt": finished,
        "summary": {
            "completed": completed,
            "failed": failed,
        },
        "results": results,
        "judgePacket": build_judge_packet(),
    }


def _execute_eval_queries(
    config: Config,
    queries: list[dict[str, Any]],
    *,
    timeout_seconds: float,
    claude_executable: str,
    concurrency: int,
    progress: Callable[[int, int, dict[str, Any], dict[str, Any]], None] | None,
) -> list[dict[str, Any]]:
    total = len(queries)

    def _execute(item: dict[str, Any]) -> dict[str, Any]:
        return run_eval_query(
            config,
            item,
            timeout_seconds=timeout_seconds,
            claude_executable=claude_executable,
        )

    if concurrency <= 1 or total <= 1:
        results: list[dict[str, Any]] = []
        for item in queries:
            result = _execute(item)
            results.append(result)
            if progress is not None:
                progress(len(results), total, item, result)
        return results

    results_by_index: dict[int, dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        future_to_index = {
            pool.submit(_execute, item): index
            for index, item in enumerate(queries)
        }
        for future in as_completed(future_to_index):
            index = future_to_index[future]
            result = future.result()
            results_by_index[index] = result
            if progress is not None:
                progress(len(results_by_index), total, queries[index], result)

    return [results_by_index[index] for index in range(total)]


def run_eval_query(
    config: Config,
    item: dict[str, Any],
    *,
    timeout_seconds: float,
    claude_executable: str,
) -> dict[str, Any]:
    attempts: list[dict[str, Any]] = []

    first = run_claude_attempt(
        config,
        query_command_prompt(item["query"]),
        timeout_seconds=timeout_seconds,
        claude_executable=claude_executable,
        attempt_number=1,
    )
    attempts.append(first)

    final = first
    if first["status"] == "completed" and not first["sawResearchTool"]:
        retry_prompt = research_required_retry_prompt(item["query"])
        second = run_claude_attempt(
            config,
            query_command_prompt(retry_prompt),
            timeout_seconds=timeout_seconds,
            claude_executable=claude_executable,
            attempt_number=2,
            retry_reason="answered_without_research",
        )
        attempts.append(second)
        final = second
        if second["retryableIncompleteAnswerFailure"]:
            third = run_claude_attempt(
                config,
                query_command_prompt(final_answer_required_retry_prompt(retry_prompt)),
                timeout_seconds=timeout_seconds,
                claude_executable=claude_executable,
                attempt_number=3,
                retry_reason="interrupted_after_research",
            )
            attempts.append(third)
            final = third
    elif first["retryableIncompleteAnswerFailure"]:
        second = run_claude_attempt(
            config,
            query_command_prompt(final_answer_required_retry_prompt(item["query"])),
            timeout_seconds=timeout_seconds,
            claude_executable=claude_executable,
            attempt_number=2,
            retry_reason="interrupted_after_research",
        )
        attempts.append(second)
        final = second

    all_tool_calls: list[dict[str, Any]] = []
    for attempt in attempts:
        for tool_call in attempt["toolCalls"]:
            combined = dict(tool_call)
            combined["attempt"] = attempt["attempt"]
            all_tool_calls.append(combined)

    return {
        "id": item["id"],
        "query": item["query"],
        "status": final["status"],
        "answer": final.get("answer") or "",
        "error": final.get("error"),
        "durationMs": final.get("durationMs"),
        "costUSD": final.get("costUSD"),
        "sessionID": final.get("sessionID"),
        "permissionDenials": final.get("permissionDenials", []),
        "attempts": attempts,
        "toolCalls": all_tool_calls,
    }


def run_claude_attempt(
    config: Config,
    prompt: str,
    *,
    timeout_seconds: float,
    claude_executable: str,
    attempt_number: int,
    retry_reason: str | None = None,
) -> dict[str, Any]:
    started = _utc_now()
    args = _claude_args(claude_executable, prompt)
    env = _claude_env(config)
    try:
        completed = subprocess.run(
            args,
            cwd=config.workspace_root,
            env=env,
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = _decode_timeout_output(exc.stdout)
        stderr = _decode_timeout_output(exc.stderr)
        parsed = parse_claude_stream(stdout)
        return _attempt_payload(
            attempt_number=attempt_number,
            prompt=prompt,
            retry_reason=retry_reason,
            started_at=started,
            status="timeout",
            answer="",
            error=f"claude timed out after {timeout_seconds:g}s",
            exit_code=None,
            stderr=stderr,
            parsed=parsed,
        )
    except OSError as exc:
        return _attempt_payload(
            attempt_number=attempt_number,
            prompt=prompt,
            retry_reason=retry_reason,
            started_at=started,
            status="failed",
            answer="",
            error=str(exc),
            exit_code=None,
            stderr="",
            parsed=parse_claude_stream(""),
        )

    parsed = parse_claude_stream(completed.stdout)
    if completed.returncode != 0:
        message = _nonzero_exit_message(completed.returncode, completed.stderr, completed.stdout)
        status = "failed"
        answer = ""
        error = message
    elif parsed.finished:
        status = "completed"
        answer = parsed.result_text or parsed.last_assistant_text
        error = None
    else:
        status = "failed"
        answer = ""
        error = _empty_success_message(parsed)

    return _attempt_payload(
        attempt_number=attempt_number,
        prompt=prompt,
        retry_reason=retry_reason,
        started_at=started,
        status=status,
        answer=answer,
        error=error,
        exit_code=completed.returncode,
        stderr=completed.stderr,
        parsed=parsed,
    )


@dataclass
class ParsedClaudeStream:
    finished: bool
    result_text: str
    last_assistant_text: str
    cost_usd: float | None
    duration_ms: int | None
    permission_denials: list[str]
    session_id: str | None
    tool_calls: list[dict[str, Any]]
    saw_research_tool: bool
    last_tool_result_preview: str | None
    unparsed_stdout_tail: str


def parse_claude_stream(stdout: str) -> ParsedClaudeStream:
    finished = False
    result_text = ""
    last_assistant_text = ""
    cost_usd: float | None = None
    duration_ms: int | None = None
    permission_denials: list[str] = []
    session_id: str | None = None
    tool_calls: list[dict[str, Any]] = []
    calls_by_id: dict[str, dict[str, Any]] = {}
    last_tool_result_preview: str | None = None
    unparsed_lines: list[str] = []

    for line in stdout.splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            unparsed_lines.append(line)
            continue
        if not isinstance(payload, dict):
            continue
        session_id = payload.get("session_id") or session_id
        event_type = payload.get("type")
        if event_type == "assistant":
            content = _message_content(payload)
            texts = [
                str(block.get("text") or "")
                for block in content
                if isinstance(block, dict) and block.get("type") == "text"
            ]
            tool_blocks = [
                block
                for block in content
                if isinstance(block, dict) and block.get("type") == "tool_use"
            ]
            if texts and not tool_blocks:
                last_assistant_text = "".join(texts)
            for block in tool_blocks:
                name = str(block.get("name") or "")
                call_id = str(block.get("id") or "")
                tool_call = {
                    "name": name,
                    "id": call_id or None,
                    "input": _bounded_json_value(block.get("input")),
                    "resultPreview": None,
                }
                tool_calls.append(tool_call)
                if call_id:
                    calls_by_id[call_id] = tool_call
        elif event_type == "user":
            content = _message_content(payload)
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                preview = _tool_result_preview(block.get("content"))
                if not preview:
                    continue
                last_tool_result_preview = preview
                call_id = str(block.get("tool_use_id") or "")
                target = calls_by_id.get(call_id) if call_id else None
                if target is None and tool_calls:
                    target = tool_calls[-1]
                if target is not None:
                    target["resultPreview"] = preview
        elif event_type == "result":
            finished = True
            result_text = str(payload.get("result") or "")
            cost = payload.get("total_cost_usd")
            if isinstance(cost, int | float):
                cost_usd = float(cost)
            duration = payload.get("duration_ms")
            if isinstance(duration, int):
                duration_ms = duration
            session_id = payload.get("session_id") or session_id
            permission_denials = _permission_denials(payload.get("permission_denials"))

    unparsed_tail = "\n".join(unparsed_lines)[-MAX_UNPARSED_STDOUT_CHARS:]
    return ParsedClaudeStream(
        finished=finished,
        result_text=result_text,
        last_assistant_text=last_assistant_text,
        cost_usd=cost_usd,
        duration_ms=duration_ms,
        permission_denials=permission_denials,
        session_id=session_id,
        tool_calls=tool_calls,
        saw_research_tool=any(call["name"] in RESEARCH_TOOL_NAMES for call in tool_calls),
        last_tool_result_preview=last_tool_result_preview,
        unparsed_stdout_tail=unparsed_tail,
    )


def build_judge_packet() -> dict[str, Any]:
    return {
        "instructions": (
            "You are judging query quality for a personal Obsidian wiki assistant. "
            "For each result, inspect the original query, final answer, attempts, tool calls, "
            "tool inputs, and result previews. Score whether the assistant answered directly, "
            "searched the wiki first, cited wiki-backed claims with [[wikilinks]], handled absent "
            "or partial wiki coverage honestly, stayed factually consistent with evidence, chose "
            "a useful format, and avoided false refusals, knowledge-cutoff excuses, or claims that "
            "it saved or modified files."
        ),
        "scoreScale": {
            "1": "Poor: misses the query, fails to research, fabricates, or refuses incorrectly.",
            "2": "Weak: partially useful but has major grounding, citation, or completeness problems.",
            "3": "Adequate: answers the query with some wiki grounding but leaves clear gaps.",
            "4": "Good: well-grounded, direct, cited, and mostly complete.",
            "5": "Excellent: thorough, well-formatted, evidence-sensitive, and clearly wiki-first.",
        },
        "dimensions": [
            "directnessAndCompleteness",
            "wikiFirstResearchBehavior",
            "citationQuality",
            "absenceOrPartialCoverageHandling",
            "factualConsistencyWithEvidence",
            "formatUsefulness",
            "avoidanceOfRefusalsAndFalseSaveClaims",
        ],
        "requestedOutputSchema": {
            "overallSummary": "string",
            "results": [
                {
                    "id": "string",
                    "score": "integer 1-5",
                    "dimensionScores": {
                        "directnessAndCompleteness": "integer 1-5",
                        "wikiFirstResearchBehavior": "integer 1-5",
                        "citationQuality": "integer 1-5",
                        "absenceOrPartialCoverageHandling": "integer 1-5",
                        "factualConsistencyWithEvidence": "integer 1-5",
                        "formatUsefulness": "integer 1-5",
                        "avoidanceOfRefusalsAndFalseSaveClaims": "integer 1-5",
                    },
                    "strengths": ["string"],
                    "issues": ["string"],
                    "recommendedPromptOrProcessFixes": ["string"],
                }
            ],
        },
    }


def write_run_output(
    payload: dict[str, Any],
    output_path: Path | None = None,
    *,
    runs_dir: Path | None = None,
) -> Path:
    if output_path is None:
        path = build_run_output_path(
            payload["suite"]["name"], runs_dir=runs_dir,
        )
    else:
        path = output_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")
    path.with_suffix(".md").write_text(render_run_markdown(payload))
    return path


def render_run_markdown(payload: dict[str, Any]) -> str:
    """Render an eval-run payload as a human-readable markdown report."""
    suite = payload.get("suite") or {}
    runner = payload.get("runner") or {}
    summary = payload.get("summary") or {}
    results = payload.get("results") or []

    lines: list[str] = [f"# Eval run — {suite.get('name', 'unknown')}", ""]
    if payload.get("runID"):
        lines.append(f"- Run ID: `{payload['runID']}`")
    if payload.get("startedAt"):
        lines.append(f"- Started: {payload['startedAt']}")
    if payload.get("finishedAt"):
        lines.append(f"- Finished: {payload['finishedAt']}")
    if "concurrency" in runner:
        lines.append(f"- Concurrency: {runner['concurrency']}")
    if runner.get("model"):
        version = runner.get("claudeVersion") or ""
        lines.append(f"- Model: {runner['model']} (`{version}`)")
    lines.append(
        f"- Summary: {summary.get('completed', 0)} completed, "
        f"{summary.get('failed', 0)} failed"
    )

    total_cost = sum((r.get("costUSD") or 0) for r in results)
    total_dur_ms = sum((r.get("durationMs") or 0) for r in results)
    if results:
        lines.append(f"- Total cost: ${total_cost:.3f}")
        lines.append(f"- Sum of per-query durations: {total_dur_ms / 1000:.0f}s")
    lines.extend(["", "---", ""])

    for index, result in enumerate(results, start=1):
        dur = (result.get("durationMs") or 0) / 1000
        cost = result.get("costUSD") or 0
        tools = result.get("toolCalls") or []
        tool_names = [t.get("name") for t in tools if isinstance(t, dict)]
        lines.append(f"## {index}. `{result.get('id', '')}`")
        lines.append("")
        lines.append(f"**Query:** {result.get('query', '')}")
        lines.append("")
        lines.append(
            f"**Status:** {result.get('status', '')} · "
            f"**Duration:** {dur:.1f}s · "
            f"**Cost:** ${cost:.3f} · "
            f"**Tools:** {len(tools)}"
            + (f" ({', '.join(filter(None, tool_names))})" if tool_names else "")
        )
        lines.append("")
        if result.get("error"):
            lines.append(f"> [!warning] Error: {result['error']}")
            lines.append("")
        lines.append("**Answer:**")
        lines.append("")
        lines.append(result.get("answer") or "_(empty)_")
        lines.extend(["", "---", ""])

    return "\n".join(lines)


def claude_version(claude_executable: str) -> str:
    try:
        completed = subprocess.run(
            [claude_executable, "--version"],
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
    except Exception as exc:
        return f"unavailable: {exc}"
    text = (completed.stdout or completed.stderr).strip()
    if completed.returncode != 0:
        return f"unavailable: {text or f'exit {completed.returncode}'}"
    return text or "unknown"


def research_required_retry_prompt(prompt: str) -> str:
    return (
        "Your previous answer was discarded because it did not use any research tools. "
        "Retry the request below.\n\n"
        "Before answering, use at least one content research tool: Bash, Grep, Glob, Read, "
        "Task, WebSearch, or WebFetch. LS is allowed for navigation, but it does not count "
        "by itself. Search the local wiki first unless the request is explicitly about "
        "external or current information. Keep Bash output focused with search excerpts or "
        "bounded page reads instead of dumping long files unless the full text is essential. "
        "If you conclude the topic is not in the wiki, briefly state what you searched.\n\n"
        f"Request:\n{prompt}"
    )


def final_answer_required_retry_prompt(prompt: str) -> str:
    return (
        "Your previous research run used tools but Claude Code exited before producing a "
        "final answer. Retry the request below.\n\n"
        "Use research tools as needed, keep Bash output focused with search excerpts or "
        "bounded page reads, and then produce the final answer. Search the local wiki first "
        "unless the request is explicitly about external or current information. If you "
        "conclude the topic is not in the wiki, briefly state what you searched.\n\n"
        f"Request:\n{prompt}"
    )


def query_command_prompt(prompt: str) -> str:
    return f"/query {prompt}"


def _attempt_payload(
    *,
    attempt_number: int,
    prompt: str,
    retry_reason: str | None,
    started_at: str,
    status: str,
    answer: str,
    error: str | None,
    exit_code: int | None,
    stderr: str,
    parsed: ParsedClaudeStream,
) -> dict[str, Any]:
    return {
        "attempt": attempt_number,
        "retryReason": retry_reason,
        "prompt": prompt,
        "status": status,
        "answer": answer,
        "error": error,
        "startedAt": started_at,
        "finishedAt": _utc_now(),
        "exitCode": exit_code,
        "durationMs": parsed.duration_ms,
        "costUSD": parsed.cost_usd,
        "sessionID": parsed.session_id,
        "permissionDenials": parsed.permission_denials,
        "sawResearchTool": parsed.saw_research_tool,
        "retryableIncompleteAnswerFailure": bool(
            error
            and parsed.saw_research_tool
            and (
                "Claude exited before producing an answer" in error
                or "Claude exited after a tool result without producing an answer" in error
            )
        ),
        "toolCalls": parsed.tool_calls,
        "stderrTail": stderr[-MAX_STDERR_CHARS:] if stderr else "",
        "unparsedStdoutTail": parsed.unparsed_stdout_tail,
    }


def _claude_args(claude_executable: str, prompt: str) -> list[str]:
    return [
        claude_executable,
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--allowedTools",
        ALLOWED_TOOLS,
        "--disallowedTools",
        DISALLOWED_TOOLS,
        "--model",
        DEFAULT_MODEL,
        prompt,
    ]


def _claude_env(config: Config) -> dict[str, str]:
    env = os.environ.copy()
    existing_path = env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    env["PATH"] = os.pathsep.join(
        [
            str(config.workspace_root / ".compile" / "mywiki-bin"),
            str(Path.home() / ".claude" / "local"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existing_path,
        ]
    )
    return env


def _message_content(payload: dict[str, Any]) -> list[Any]:
    message = payload.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    return content if isinstance(content, list) else []


def _permission_denials(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    denials: list[str] = []
    for item in value:
        if isinstance(item, dict):
            name = item.get("tool") or item.get("name")
            if name:
                denials.append(str(name))
    return denials


def _bounded_json_value(value: Any) -> Any:
    text = json.dumps(value, sort_keys=True, ensure_ascii=False)
    if len(text) <= MAX_TOOL_INPUT_CHARS:
        return value
    return {
        "truncated": True,
        "preview": text[:MAX_TOOL_INPUT_CHARS],
    }


def _tool_result_preview(content: Any) -> str:
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
        text = "".join(parts)
    else:
        text = ""
    return text[:MAX_TOOL_RESULT_PREVIEW_CHARS]


def _empty_success_message(parsed: ParsedClaudeStream) -> str:
    if parsed.last_tool_result_preview:
        return (
            "Claude exited after a tool result without producing an answer; please retry. "
            f"Last tool result preview: {parsed.last_tool_result_preview}"
        )
    return "Claude exited before producing an answer; please retry."


def _nonzero_exit_message(returncode: int, stderr: str, stdout: str) -> str:
    stderr = stderr.strip()
    if stderr:
        return stderr[-MAX_STDERR_CHARS:]
    stdout = stdout.strip()
    if stdout:
        return stdout[-MAX_STDERR_CHARS:]
    return f"claude -p exited with code {returncode}"


def _decode_timeout_output(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def _workspace_payload(config: Config, info: dict[str, Any]) -> dict[str, Any]:
    return {
        "path": info["workspace_root"],
        "topic": info["topic"],
        "description": info["description"],
        "rawFiles": info["raw_files"],
        "processed": info["processed"],
        "unprocessed": info["unprocessed"],
        "needsDocumentReview": info["needs_document_review"],
        "wikiPageCount": info["wiki_pages"],
        "configPath": str(config.config_path),
    }


def _slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip()).strip("-").lower()
    return slug or "suite"


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
