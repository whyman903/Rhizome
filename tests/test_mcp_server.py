from __future__ import annotations

from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
from threading import Thread

from click.testing import CliRunner

from compile.cli import main
from compile.mcp_server import RhizomeMcpServer, _McpHttpHandler, run_mcp_server
from compile.obsidian import ObsidianConnector
from compile.workspace import init_workspace


def _workspace_with_pages(tmp_path: Path) -> Path:
    init_workspace(tmp_path, "MCP Test", "A wiki for MCP coverage.")
    connector = ObsidianConnector(tmp_path)
    connector.upsert_page(
        title="Planner Executor Retrieval",
        page_type="article",
        summary="Notes on planner-executor retrieval.",
        body=(
            "Planner executor retrieval uses a planner to decompose the task and "
            "a retrieval worker to gather grounded context.\n\n"
            "See [[Grounding Source]]."
        ),
    )
    connector.upsert_page(
        title="Grounding Source",
        page_type="source",
        summary="Primary source for grounding details.",
        sources=["raw/source.md"],
        body="This source discusses grounded answers and retrieval strategy.",
    )
    return tmp_path


def test_mcp_lists_read_only_tools(tmp_path: Path) -> None:
    server = RhizomeMcpServer(_workspace_with_pages(tmp_path))

    response = server.handle_json_rpc(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        }
    )

    assert isinstance(response, dict)
    tools = response["result"]["tools"]
    names = {tool["name"] for tool in tools}
    assert {
        "wiki_overview",
        "search_wiki",
        "search",
        "read_wiki_page",
        "fetch",
        "page_neighbors",
        "list_wiki_pages",
    } <= names
    assert all(tool["annotations"]["readOnlyHint"] is True for tool in tools)


def test_mcp_search_and_read_page(tmp_path: Path) -> None:
    server = RhizomeMcpServer(_workspace_with_pages(tmp_path))

    search_response = server.handle_json_rpc(
        {
            "jsonrpc": "2.0",
            "id": "search",
            "method": "tools/call",
            "params": {
                "name": "search_wiki",
                "arguments": {"query": "retrieval", "limit": 5},
            },
        }
    )

    assert isinstance(search_response, dict)
    search_payload = search_response["result"]["structuredContent"]
    assert search_payload["ok"] is True
    assert search_payload["hits"][0]["title"] == "Planner Executor Retrieval"

    read_response = server.handle_json_rpc(
        {
            "jsonrpc": "2.0",
            "id": "read",
            "method": "tools/call",
            "params": {
                "name": "read_wiki_page",
                "arguments": {
                    "locator": "Planner Executor Retrieval",
                    "max_chars": 1000,
                },
            },
        }
    )

    assert isinstance(read_response, dict)
    read_payload = read_response["result"]["structuredContent"]
    assert read_payload["page"]["title"] == "Planner Executor Retrieval"
    assert "planner to decompose" in read_payload["page"]["body"]
    assert read_payload["page"]["body_truncated"] is False


def test_mcp_neighbors_and_overview(tmp_path: Path) -> None:
    server = RhizomeMcpServer(_workspace_with_pages(tmp_path))

    neighbors = server.call_tool(
        "page_neighbors",
        {"locator": "Planner Executor Retrieval"},
    )["structuredContent"]
    assert neighbors["ok"] is True
    assert "Grounding Source" in neighbors["neighborhood"]["outbound_pages"]

    overview = server.call_tool("wiki_overview", {})["structuredContent"]
    assert overview["ok"] is True
    assert overview["workspace"]["topic"] == "MCP Test"
    assert overview["vault"]["page_type_counts"]["article"] == 1


def test_mcp_connector_search_and_fetch_aliases(tmp_path: Path) -> None:
    server = RhizomeMcpServer(_workspace_with_pages(tmp_path))

    search_response = server.call_tool("search", {"query": "retrieval"})
    search_payload = json.loads(search_response["content"][0]["text"])
    first_result = search_payload["results"][0]
    assert first_result["id"] == "wiki/articles/Planner Executor Retrieval.md"
    assert first_result["title"] == "Planner Executor Retrieval"
    assert first_result["url"].startswith("file://")

    fetch_response = server.call_tool("fetch", {"id": first_result["id"]})
    fetch_payload = json.loads(fetch_response["content"][0]["text"])
    assert fetch_payload["id"] == first_result["id"]
    assert fetch_payload["title"] == "Planner Executor Retrieval"
    assert "planner to decompose" in fetch_payload["text"]
    assert fetch_payload["metadata"]["page_type"] == "article"


def test_mcp_initialize_negotiates_supported_protocol(tmp_path: Path) -> None:
    server = RhizomeMcpServer(_workspace_with_pages(tmp_path))

    response = server.handle_json_rpc(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-03-26"},
        }
    )

    assert isinstance(response, dict)
    assert response["result"]["protocolVersion"] == "2025-03-26"
    assert response["result"]["capabilities"]["tools"]["listChanged"] is False


def test_compile_mcp_command_exposes_help() -> None:
    runner = CliRunner()

    result = runner.invoke(main, ["mcp", "--help"])

    assert result.exit_code == 0
    assert "Run the read-only Rhizome MCP server" in result.output


def test_compile_mcp_command_reports_missing_path(tmp_path: Path) -> None:
    runner = CliRunner()

    result = runner.invoke(main, ["mcp", "--path", str(tmp_path / "missing")])

    assert result.exit_code == 1
    assert "No path found" in result.output


def test_compile_mcp_command_rejects_unauthenticated_nonlocalhost_http(tmp_path: Path) -> None:
    _workspace_with_pages(tmp_path)
    runner = CliRunner()

    result = runner.invoke(
        main,
        [
            "mcp",
            "--path",
            str(tmp_path),
            "--transport",
            "http",
            "--host",
            "0.0.0.0",
        ],
    )

    assert result.exit_code == 1
    assert "Refusing to start unauthenticated HTTP MCP server" in result.output


def test_mcp_transport_rejects_unauthenticated_nonlocalhost_http(tmp_path: Path) -> None:
    _workspace_with_pages(tmp_path)

    try:
        run_mcp_server(
            workspace_root=tmp_path,
            transport="http",
            host="0.0.0.0",
            port=8765,
        )
    except ValueError as exc:
        assert "Refusing to start unauthenticated HTTP MCP server" in str(exc)
    else:
        raise AssertionError("Expected unauthenticated non-localhost HTTP to fail")


def test_mcp_can_read_generic_markdown_folder(tmp_path: Path) -> None:
    (tmp_path / "wiki").mkdir()
    generic_root = tmp_path / "generic"
    (generic_root / "notes").mkdir(parents=True)
    (generic_root / "notes" / "Alpha.md").write_text(
        "# Alpha\n\nA generic markdown page about search adapters."
    )

    server = RhizomeMcpServer(generic_root)
    search_payload = server.call_tool(
        "search_wiki",
        {"query": "search adapters", "limit": 5},
    )["structuredContent"]
    overview = server.call_tool("wiki_overview", {})["structuredContent"]

    assert search_payload["hits"][0]["title"] == "Alpha"
    assert overview["workspace"]["root"] == str(generic_root.resolve())
    assert overview["workspace"]["topic"] == generic_root.name
    assert overview["workspace"]["processed"] is None


def test_mcp_stdio_json_lines(tmp_path: Path) -> None:
    server = RhizomeMcpServer(_workspace_with_pages(tmp_path))
    response = server.handle_json_rpc(
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "ping",
            },
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            },
        ]
    )

    assert json.loads(json.dumps(response)) == [
        {"jsonrpc": "2.0", "id": 1, "result": {}}
    ]


def test_mcp_http_endpoint_serves_json_rpc(tmp_path: Path) -> None:
    server = RhizomeMcpServer(
        _workspace_with_pages(tmp_path),
        allowed_origins={"https://chatgpt.com"},
        http_token="secret-token",
    )
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _McpHttpHandler)
    httpd.rhizome_mcp_server = server  # type: ignore[attr-defined]
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        connection = HTTPConnection("127.0.0.1", httpd.server_port, timeout=5)
        connection.request(
            "POST",
            "/mcp",
            body=json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/list",
                }
            ),
            headers={
                "Authorization": "Bearer secret-token",
                "Content-Type": "application/json",
                "Origin": "https://chatgpt.com",
            },
        )
        response = connection.getresponse()
        body = json.loads(response.read().decode("utf-8"))
        connection.close()
    finally:
        httpd.shutdown()
        thread.join(timeout=5)

    assert response.status == 200
    assert response.getheader("Access-Control-Allow-Origin") == "https://chatgpt.com"
    assert body["result"]["tools"][0]["name"] == "wiki_overview"


def test_mcp_http_endpoint_rejects_bad_origin_and_token(tmp_path: Path) -> None:
    server = RhizomeMcpServer(
        _workspace_with_pages(tmp_path),
        allowed_origins={"https://chatgpt.com"},
        http_token="secret-token",
    )
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _McpHttpHandler)
    httpd.rhizome_mcp_server = server  # type: ignore[attr-defined]
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        bad_origin = HTTPConnection("127.0.0.1", httpd.server_port, timeout=5)
        bad_origin.request(
            "POST",
            "/mcp",
            body=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}),
            headers={
                "Authorization": "Bearer secret-token",
                "Content-Type": "application/json",
                "Origin": "https://example.invalid",
            },
        )
        bad_origin_response = bad_origin.getresponse()
        bad_origin_response.read()
        bad_origin.close()

        bad_token = HTTPConnection("127.0.0.1", httpd.server_port, timeout=5)
        bad_token.request(
            "POST",
            "/mcp",
            body=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}),
            headers={
                "Authorization": "Bearer wrong",
                "Content-Type": "application/json",
                "Origin": "https://chatgpt.com",
            },
        )
        bad_token_response = bad_token.getresponse()
        bad_token_response.read()
        bad_token.close()
    finally:
        httpd.shutdown()
        thread.join(timeout=5)

    assert bad_origin_response.status == 403
    assert bad_token_response.status == 403
