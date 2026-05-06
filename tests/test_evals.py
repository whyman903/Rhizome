from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from compile.cli import main
from compile.evals import (
    EvalSuiteError,
    SCHEMA_VERSION,
    analyze_workflow_flags,
    build_judge_packet,
    build_run_output_path,
    load_eval_suite,
    parse_claude_stream,
    run_eval_query,
    run_eval_suite,
    validate_eval_suite,
    write_run_output,
    write_starter_suite,
)
from compile.workspace import init_workspace


def _write_fake_claude(path: Path, body: str) -> Path:
    script = "#!/bin/sh\nset -eu\n" + body
    path.write_text(script)
    path.chmod(0o755)
    return path


def _small_suite_payload() -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "name": "small",
        "queries": [
            {
                "id": "one",
                "query": "What is in the wiki?",
            }
        ],
    }


def test_starter_suite_is_written_and_loaded(tmp_path: Path) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "A test wiki.")

    path = write_starter_suite(config, "query-quality")
    suite = load_eval_suite(config, "query-quality")

    assert path == tmp_path / ".compile" / "evals" / "suites" / "query-quality.json"
    assert suite.name == "query-quality"
    assert len(suite.queries) == 26
    assert suite.queries[0] == {
        "id": "tcp-udp",
        "query": "what's the difference between TCP and UDP?",
    }


def test_starter_suite_does_not_overwrite_without_force(tmp_path: Path) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    write_starter_suite(config, "query-quality")

    with pytest.raises(EvalSuiteError, match="already exists"):
        write_starter_suite(config, "query-quality")


def test_suite_validation_rejects_duplicate_ids(tmp_path: Path) -> None:
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "name": "bad",
        "queries": [
            {"id": "dup", "query": "first"},
            {"id": "dup", "query": "second"},
        ],
    }

    with pytest.raises(EvalSuiteError, match="Duplicate query id"):
        validate_eval_suite(payload, path=tmp_path / "bad.json")


def test_run_output_path_defaults_to_cwd(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(tmp_path)
    timestamp = datetime(2026, 4, 26, 12, 30, 5, tzinfo=timezone.utc)

    path = build_run_output_path("Query Quality", timestamp)

    assert path == tmp_path / "evals" / "runs" / "20260426T123005Z-query-quality.json"


def test_run_output_path_honors_runs_dir_override(tmp_path: Path) -> None:
    timestamp = datetime(2026, 4, 26, 12, 30, 5, tzinfo=timezone.utc)
    custom = tmp_path / "elsewhere"

    path = build_run_output_path("Query Quality", timestamp, runs_dir=custom)

    assert path == custom / "20260426T123005Z-query-quality.json"


def test_judge_packet_contains_rubric_and_requested_schema() -> None:
    packet = build_judge_packet()

    assert "wiki first" in packet["instructions"].replace("-", " ")
    assert "citationQuality" in packet["dimensions"]
    assert "saveTargetCorrectness" in packet["dimensions"]
    assert "absenceSearchSufficiency" in packet["dimensions"]
    assert "inventorySearchEfficiency" in packet["dimensions"]
    assert "renderSaveConsentConsistency" in packet["dimensions"]
    assert "registerFit" in packet["dimensions"]
    assert "requestedOutputSchema" in packet
    assert packet["scoreScale"]["5"].startswith("Excellent")


def test_static_workflow_flags_catch_save_offer_absence_and_current_gaps() -> None:
    flags = analyze_workflow_flags(
        query="do I have anything in the wiki on my deployment provider's latest pricing?",
        answer=(
            "No pricing content in your wiki. Current state: here is a general knowledge summary.\n\n"
            "Want me to save this as a wiki output page?"
        ),
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile obsidian search "deployment provider latest pricing"'},
            }
        ],
    )

    codes = {flag["code"] for flag in flags}
    assert "trivial_or_absence_save_offer" in codes
    assert "absence_without_raw_or_wiki_grep" in codes
    assert "freshness_claim_without_web" in codes


def test_static_workflow_flags_do_not_treat_topics_as_freshness() -> None:
    flags = analyze_workflow_flags(
        query="do I have anything in the wiki on quantum computing?",
        answer="Your wiki has no notes on quantum computing. Here's a general knowledge summary.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile obsidian search "quantum computing"'},
            },
            {
                "name": "Bash",
                "input": {"command": 'rg -ni "quantum computing|qubit" wiki raw'},
            },
        ],
    )

    assert "freshness_claim_without_web" not in {flag["code"] for flag in flags}


def test_static_workflow_flags_catch_render_save_contradiction() -> None:
    flags = analyze_workflow_flags(
        query="build me the deck",
        answer=(
            "The deck is built and saved to the wiki at `wiki/outputs/Talk.md`.\n\n"
            "Want me to save this as a wiki output page?"
        ),
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile render marp "Talk" --body-file /tmp/deck.md'},
            }
        ],
    )

    codes = {flag["code"] for flag in flags}
    assert "artifact_saved_then_save_offer" in codes
    assert "false_or_unverified_save_claim" not in codes


def test_static_workflow_flags_do_not_treat_output_page_status_as_save_offer() -> None:
    flags = analyze_workflow_flags(
        query="build me the deck",
        answer="Created: wiki/outputs/Talk.md. The output page is ready.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile render marp "Talk" --body-file /tmp/deck.md'},
            }
        ],
    )

    assert flags == []


def test_static_workflow_flags_require_direct_search_to_target_wiki_or_raw() -> None:
    flags = analyze_workflow_flags(
        query="summarize my notes on quantum computing",
        answer="No notes in your wiki cover quantum computing.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile obsidian search "quantum computing"'},
            },
            {
                "name": "Grep",
                "input": {"pattern": "quantum", "path": "/tmp"},
            },
        ],
    )

    assert "absence_without_raw_or_wiki_grep" in {flag["code"] for flag in flags}


def test_static_workflow_flags_refresh_does_not_verify_save_claim() -> None:
    flags = analyze_workflow_flags(
        query="save that answer",
        answer="Saved to the wiki at wiki/outputs/Talk.md.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": "compile obsidian refresh"},
            }
        ],
    )

    assert {
        flag["code"] for flag in flags
    } == {"false_or_unverified_save_claim"}


def test_static_workflow_flags_catch_inventory_search_thrash() -> None:
    flags = analyze_workflow_flags(
        query="how many source notes do I have that engage contractualism?",
        answer="I found 11 source notes.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": f'compile obsidian search "contractualism {index}"'},
            }
            for index in range(11)
        ],
    )

    codes = {flag["code"] for flag in flags}
    assert "inventory_search_budget_exceeded" in codes
    assert "inventory_without_aggregation" in codes


def test_static_workflow_flags_inventory_query_uses_word_boundaries() -> None:
    flags = analyze_workflow_flags(
        query="what are the source notes about discounted account encounters?",
        answer="Here are the relevant source notes.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": f'compile obsidian search "pricing {index}"'},
            }
            for index in range(11)
        ],
    )

    codes = {flag["code"] for flag in flags}
    assert "inventory_search_budget_exceeded" not in codes
    assert "inventory_without_aggregation" not in codes


def test_static_workflow_flags_ls_aggregation_requires_ls_command() -> None:
    flags = analyze_workflow_flags(
        query="how many source notes do I have that engage contractualism?",
        answer="I found several source notes.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": f"compile tools inspect {index}"},
            }
            for index in range(6)
        ],
    )

    assert "inventory_without_aggregation" in {flag["code"] for flag in flags}


def test_static_workflow_flags_catch_source_accounting_without_named_reads() -> None:
    flags = analyze_workflow_flags(
        query="show which sources support which moves: Frankfurt, Nguyen, Anderson, and Farkas",
        answer="Here is the source accounting.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile obsidian search "LLM bullshitters epistemic pollution"'},
            },
            {
                "name": "Bash",
                "input": {"command": 'compile obsidian page "LLM Bullshitters Paper"'},
            },
        ],
    )

    assert {
        flag["code"] for flag in flags
    } == {"source_accounting_missing_named_sources"}


def test_static_workflow_flags_general_sources_support_query_is_not_source_accounting() -> None:
    flags = analyze_workflow_flags(
        query="what sources support Marx's account of alienation?",
        answer="Here are the sources.",
        tool_calls=[
            {
                "name": "Bash",
                "input": {"command": 'compile obsidian search "Marx alienation"'},
            }
        ],
    )

    assert "source_accounting_missing_named_sources" not in {flag["code"] for flag in flags}


def test_parse_claude_stream_captures_tool_call_inputs_and_results() -> None:
    stdout = "\n".join(
        [
            '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Grep","input":{"pattern":"TCP","path":"wiki"}}]}}',
            '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"wiki/sources/System design.md: TCP"}]}}',
            '{"type":"result","result":"Answer from [[System design]].","total_cost_usd":0.01,"duration_ms":123,"permission_denials":[],"session_id":"session-1"}',
        ]
    )

    parsed = parse_claude_stream(stdout)

    assert parsed.finished is True
    assert parsed.result_text == "Answer from [[System design]]."
    assert parsed.saw_research_tool is True
    assert parsed.tool_calls == [
        {
            "name": "Grep",
            "id": "tool-1",
            "input": {"pattern": "TCP", "path": "wiki"},
            "resultPreview": "wiki/sources/System design.md: TCP",
        }
    ]


def test_run_eval_suite_parallel_preserves_order(tmp_path: Path) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    queries = [{"id": f"q{i}", "query": f"question {i}"} for i in range(8)]
    suite = validate_eval_suite(
        {"schemaVersion": SCHEMA_VERSION, "name": "parallel", "queries": queries},
        path=tmp_path / "parallel.json",
    )
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
prompt="${@: -1}"
# Sleep a varying short time so completion order != submission order.
case "$prompt" in
  *q0*) sleep 0.30 ;;
  *q1*) sleep 0.05 ;;
  *q2*) sleep 0.20 ;;
  *q3*) sleep 0.10 ;;
  *q4*) sleep 0.25 ;;
  *q5*) sleep 0.02 ;;
  *q6*) sleep 0.15 ;;
  *q7*) sleep 0.08 ;;
esac
slug=$(echo "$prompt" | tr -dc 'a-zA-Z0-9' | tail -c 4)
cat <<JSON
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t-$slug","name":"Grep","input":{"pattern":"x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t-$slug","content":"hit"}]}}
{"type":"result","result":"answer-$slug","permission_denials":[],"session_id":"s-$slug"}
JSON
""",
    )

    payload = run_eval_suite(
        config,
        suite,
        claude_executable=str(fake_claude),
        timeout_seconds=5,
        concurrency=4,
    )

    assert payload["runner"]["concurrency"] == 4
    assert [r["id"] for r in payload["results"]] == [q["id"] for q in queries]
    assert payload["summary"] == {"completed": 8, "failed": 0}


def test_run_eval_suite_success_with_fake_claude(tmp_path: Path) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    suite = validate_eval_suite(_small_suite_payload(), path=tmp_path / "small.json")
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Grep","input":{"pattern":"wiki"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"wiki hit"}]}}
{"type":"result","result":"Found [[Wiki Page]].","total_cost_usd":0.02,"duration_ms":456,"permission_denials":[],"session_id":"session-ok"}
JSON
""",
    )

    payload = run_eval_suite(
        config,
        suite,
        claude_executable=str(fake_claude),
        timeout_seconds=5,
    )

    result = payload["results"][0]
    assert payload["runner"]["claudeVersion"] == "fake claude 1.0"
    assert payload["summary"] == {"completed": 1, "failed": 0}
    assert result["status"] == "completed"
    assert result["answer"] == "Found [[Wiki Page]]."
    assert result["costUSD"] == 0.02
    assert result["durationMs"] == 456
    assert result["sessionID"] == "session-ok"
    assert result["toolCalls"][0]["name"] == "Grep"


def test_no_research_answer_is_retried_once(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    count_file = tmp_path / "count"
    args_file = tmp_path / "args.txt"
    monkeypatch.setenv("FAKE_CLAUDE_COUNT", str(count_file))
    monkeypatch.setenv("FAKE_CLAUDE_ARGS", str(args_file))
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--help" ]; then
  exit 0
fi
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
for arg in "$@"; do
  printf '%s\\n---ARG---\\n' "$arg" >> "$FAKE_CLAUDE_ARGS"
done
count=0
if [ -f "$FAKE_CLAUDE_COUNT" ]; then
  count=$(cat "$FAKE_CLAUDE_COUNT")
fi
count=$((count + 1))
echo "$count" > "$FAKE_CLAUDE_COUNT"
if [ "$count" = "1" ]; then
  cat <<'JSON'
{"type":"result","result":"general answer","permission_denials":[],"session_id":"session-1"}
JSON
else
  cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-2","name":"Read","input":{"file_path":"wiki/page.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-2","content":"page text"}]}}
{"type":"result","result":"researched answer","permission_denials":[],"session_id":"session-2"}
JSON
fi
""",
    )

    result = run_eval_query(
        config,
        {"id": "retry", "query": "answer this"},
        claude_executable=str(fake_claude),
        timeout_seconds=5,
    )

    assert result["status"] == "completed"
    assert result["answer"] == "researched answer"
    assert [attempt["retryReason"] for attempt in result["attempts"]] == [
        None,
        "answered_without_research",
    ]
    assert result["attempts"][0]["sawResearchTool"] is False
    assert result["attempts"][1]["sawResearchTool"] is True
    args_text = args_file.read_text()
    assert "/query answer this" in args_text
    assert "/query Your previous answer was discarded" in args_text
    assert "--append-system-prompt" not in args_text


def test_interrupted_after_tool_use_is_retried_for_final_answer(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    count_file = tmp_path / "count"
    monkeypatch.setenv("FAKE_CLAUDE_COUNT", str(count_file))
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--help" ]; then
  exit 0
fi
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
count=0
if [ -f "$FAKE_CLAUDE_COUNT" ]; then
  count=$(cat "$FAKE_CLAUDE_COUNT")
fi
count=$((count + 1))
echo "$count" > "$FAKE_CLAUDE_COUNT"
if [ "$count" = "1" ]; then
  cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Grep","input":{"pattern":"metric"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"metric hit"}]}}
JSON
else
  cat <<'JSON'
{"type":"result","result":"final researched answer","permission_denials":[],"session_id":"session-final"}
JSON
fi
""",
    )

    result = run_eval_query(
        config,
        {"id": "interrupted", "query": "compare metrics"},
        claude_executable=str(fake_claude),
        timeout_seconds=5,
    )

    assert result["status"] == "completed"
    assert result["answer"] == "final researched answer"
    assert [attempt["retryReason"] for attempt in result["attempts"]] == [
        None,
        "interrupted_after_research",
    ]
    assert result["attempts"][0]["retryableIncompleteAnswerFailure"] is True
    assert "exited after a tool result" in result["attempts"][0]["error"]


def test_timeout_is_captured_as_failed_query(tmp_path: Path) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--help" ]; then
  exit 0
fi
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
sleep 2
""",
    )

    result = run_eval_query(
        config,
        {"id": "timeout", "query": "slow query"},
        claude_executable=str(fake_claude),
        timeout_seconds=0.05,
    )

    assert result["status"] == "timeout"
    assert "timed out" in result["error"]


def test_write_run_output_defaults_to_cwd_eval_dir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.chdir(tmp_path)
    payload = {
        "suite": {"name": "small"},
        "results": [],
    }

    path = write_run_output(payload)

    assert path.parent == tmp_path / "evals" / "runs"
    assert json.loads(path.read_text())["suite"]["name"] == "small"


def test_write_run_output_honors_runs_dir_override(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.chdir(tmp_path)
    project_runs = tmp_path / "project" / "evals" / "runs"
    payload = {"suite": {"name": "small"}, "results": []}

    path = write_run_output(payload, runs_dir=project_runs)

    assert path.parent == project_runs
    assert path.with_suffix(".md").exists()
    assert not (tmp_path / "evals").exists()


def test_eval_run_cli_uses_runs_dir_env_var(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config = init_workspace(tmp_path / "wiki", "Eval Wiki", "")
    suite_path = config.workspace_root / ".compile" / "evals" / "suites" / "small.json"
    suite_path.parent.mkdir(parents=True)
    suite_path.write_text(json.dumps(_small_suite_payload()))
    project_runs = tmp_path / "project" / "evals" / "runs"
    cwd_runs = tmp_path / "cwd-evals"
    monkeypatch.chdir(cwd_runs.parent)
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--help" ]; then
  exit 0
fi
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Grep","input":{"pattern":"x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"hit"}]}}
{"type":"result","result":"answer","permission_denials":[],"session_id":"s"}
JSON
""",
    )
    monkeypatch.setenv("COMPILE_EVAL_RUNS_DIR", str(project_runs))
    runner = CliRunner()

    result = runner.invoke(
        main,
        [
            "eval", "run", "small",
            "--path", str(config.workspace_root),
            "--claude", str(fake_claude),
        ],
    )

    assert result.exit_code == 0, result.output
    written = list(project_runs.glob("*.json"))
    assert len(written) == 1
    assert written[0].with_suffix(".md").exists()
    assert not (config.workspace_root / "evals").exists()
    assert not (cwd_runs.parent / "evals").exists()


def test_write_run_output_emits_markdown_companion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.chdir(tmp_path)
    payload = {
        "suite": {"name": "small"},
        "runner": {"concurrency": 4, "model": "sonnet", "claudeVersion": "1.0"},
        "summary": {"completed": 1, "failed": 0},
        "startedAt": "2026-04-27T15:30:00Z",
        "finishedAt": "2026-04-27T15:31:00Z",
        "results": [
            {
                "id": "q1",
                "query": "what is X?",
                "status": "completed",
                "answer": "X is Y.",
                "durationMs": 12345,
                "costUSD": 0.05,
                "toolCalls": [{"name": "Grep"}],
                "workflowFlags": [
                    {
                        "code": "trivial_or_absence_save_offer",
                        "message": "Save offer was noisy.",
                    }
                ],
            }
        ],
    }

    json_path = write_run_output(payload)
    md_path = json_path.with_suffix(".md")

    assert md_path.exists()
    text = md_path.read_text()
    assert "# Eval run — small" in text
    assert "## 1. `q1`" in text
    assert "what is X?" in text
    assert "X is Y." in text
    assert "Workflow flags" in text
    assert "trivial_or_absence_save_offer" in text
    assert "Concurrency: 4" in text


def test_eval_init_and_dry_run_cli(tmp_path: Path) -> None:
    init_workspace(tmp_path, "Eval Wiki", "")
    runner = CliRunner()

    init_result = runner.invoke(main, ["eval", "init", "query-quality", "--path", str(tmp_path)])
    assert init_result.exit_code == 0
    assert (tmp_path / ".compile" / "evals" / "suites" / "query-quality.json").exists()

    dry_run = runner.invoke(main, ["eval", "run", "query-quality", "--path", str(tmp_path), "--dry-run", "--limit", "2"])
    assert dry_run.exit_code == 0
    assert "query-quality" in dry_run.output
    assert "tcp-udp" in dry_run.output
    assert "codebleu-side" in dry_run.output
    assert "philosophy-topic-count" not in dry_run.output


def test_eval_run_cli_uses_fake_claude_and_writes_json(tmp_path: Path) -> None:
    config = init_workspace(tmp_path, "Eval Wiki", "")
    suite_path = tmp_path / ".compile" / "evals" / "suites" / "small.json"
    suite_path.parent.mkdir(parents=True)
    suite_path.write_text(json.dumps(_small_suite_payload()))
    output_path = tmp_path / ".compile" / "evals" / "runs" / "out.json"
    fake_claude = _write_fake_claude(
        tmp_path / "claude",
        """
if [ "${1:-}" = "--help" ]; then
  exit 0
fi
if [ "${1:-}" = "--version" ]; then
  echo "fake claude 1.0"
  exit 0
fi
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Grep","input":{"pattern":"wiki"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"wiki hit"}]}}
{"type":"result","result":"CLI answer","permission_denials":[],"session_id":"cli-session"}
JSON
""",
    )
    runner = CliRunner()

    result = runner.invoke(
        main,
        [
            "eval",
            "run",
            "small",
            "--path",
            str(config.workspace_root),
            "--claude",
            str(fake_claude),
            "--output",
            str(output_path),
        ],
    )

    assert result.exit_code == 0
    payload = json.loads(output_path.read_text())
    assert payload["results"][0]["answer"] == "CLI answer"
    assert payload["results"][0]["toolCalls"][0]["name"] == "Grep"
