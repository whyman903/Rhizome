from __future__ import annotations

import argparse
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
from typing import Any
from urllib.parse import urlparse

from compile.config import Config, load_config
from compile.obsidian import ObsidianConnector, SearchHit
from compile.search_index import search_index_exists, search_pdf_index
from compile.workspace import get_status


JSONRPC_VERSION = "2.0"
LATEST_PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = {
    "2024-11-05",
    "2025-03-26",
    LATEST_PROTOCOL_VERSION,
}
LOCAL_HTTP_HOSTS = {"127.0.0.1", "localhost", "::1"}


class McpError(Exception):
    def __init__(self, code: int, message: str, data: Any | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


@dataclass(frozen=True)
class ToolDefinition:
    name: str
    description: str
    input_schema: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": self.input_schema,
            "annotations": {"readOnlyHint": True},
        }


def _integer_schema(*, default: int, minimum: int, maximum: int) -> dict[str, Any]:
    return {
        "type": "integer",
        "default": default,
        "minimum": minimum,
        "maximum": maximum,
    }


TOOLS: tuple[ToolDefinition, ...] = (
    ToolDefinition(
        name="wiki_overview",
        description=(
            "Return high-level Rhizome workspace status, page counts, graph health, "
            "and recent issue summaries."
        ),
        input_schema={
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="search_wiki",
        description=(
            "Search the Rhizome wiki by title, summary, body text, tags, aliases, "
            "and indexed PDF chunks when available."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search terms or a page title.",
                },
                "limit": _integer_schema(default=10, minimum=1, maximum=25),
                "page_type": {
                    "type": "string",
                    "description": (
                        "Optional page type filter such as article, source, map, "
                        "output, watch, overview, index, or log."
                    ),
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="search",
        description=(
            "OpenAI connector-compatible alias for search_wiki. Searches wiki "
            "content and returns result objects with id, title, and url."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search terms or a page title.",
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="read_wiki_page",
        description=(
            "Read one wiki page by title, alias, wikilink, file name, or relative "
            "path. Returns page metadata, links, and a bounded markdown body. "
            "When the body is truncated, body_truncated is true."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "locator": {
                    "type": "string",
                    "description": "Page title, alias, wikilink text, file name, or path.",
                },
                "max_chars": _integer_schema(default=20000, minimum=1000, maximum=80000),
            },
            "required": ["locator"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="fetch",
        description=(
            "OpenAI connector-compatible alias for read_wiki_page. Fetches a page "
            "by id from search results and returns id, title, text, url, and metadata."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "id": {
                    "type": "string",
                    "description": "Document id returned by search, usually a relative path.",
                },
            },
            "required": ["id"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="page_neighbors",
        description=(
            "Return backlinks, outbound links, supporting sources, related pages, "
            "and unresolved targets for a wiki page."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "locator": {
                    "type": "string",
                    "description": "Page title, alias, wikilink text, file name, or path.",
                },
            },
            "required": ["locator"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="list_wiki_pages",
        description="List wiki pages, optionally filtered by page type.",
        input_schema={
            "type": "object",
            "properties": {
                "page_type": {
                    "type": "string",
                    "description": "Optional page type filter.",
                },
                "limit": _integer_schema(default=100, minimum=1, maximum=500),
            },
            "additionalProperties": False,
        },
    ),
)


def _coerce_arguments(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise McpError(-32602, "Tool arguments must be an object.")
    return value


def _coerce_limit(value: Any, *, default: int, minimum: int, maximum: int) -> int:
    if value is None:
        return default
    try:
        coerced = int(value)
    except (TypeError, ValueError) as exc:
        raise McpError(-32602, "limit must be an integer.") from exc
    return min(max(coerced, minimum), maximum)


def _required_string(args: dict[str, Any], name: str) -> str:
    value = str(args.get(name) or "").strip()
    if not value:
        raise McpError(-32602, f"Missing required string argument: {name}")
    return value


def _json_result(payload: dict[str, Any]) -> dict[str, Any]:
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    return {
        "content": [{"type": "text", "text": text}],
        "structuredContent": payload,
    }


def _error_tool_result(message: str) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": f"Error: {message}"}],
        "isError": True,
    }


def _truncate_text(value: str, max_chars: int) -> tuple[str, bool]:
    if len(value) <= max_chars:
        return value, False
    suffix = "\n\n[Truncated by MCP server. Increase max_chars to read more.]"
    return value[: max(0, max_chars - len(suffix))].rstrip() + suffix, True


def _merge_search_hits(
    *,
    primary: list[SearchHit],
    secondary: list[SearchHit],
    limit: int,
    page_type: str | None = None,
) -> list[SearchHit]:
    merged: list[SearchHit] = []
    seen: set[str] = set()
    for collection in (primary, secondary):
        for hit in collection:
            if page_type and hit.page_type != page_type:
                continue
            if hit.relative_path in seen:
                continue
            seen.add(hit.relative_path)
            merged.append(hit)
            if len(merged) >= limit:
                return merged
    return merged


class RhizomeMcpServer:
    def __init__(
        self,
        workspace_root: Path,
        *,
        allowed_origins: set[str] | None = None,
        http_token: str | None = None,
    ) -> None:
        workspace_root = workspace_root.resolve()
        if not workspace_root.exists():
            raise FileNotFoundError(f"No path found at {workspace_root}.")
        try:
            self.config: Config | None = load_config(workspace_root)
        except FileNotFoundError:
            self.config = None
        self.connector = ObsidianConnector(
            self.config.workspace_root if self.config is not None else workspace_root,
            discover_root=self.config is not None,
        )
        self.allowed_origins = allowed_origins or set()
        self.http_token = http_token
        self.tools_by_name = {tool.name: tool for tool in TOOLS}

    @property
    def server_info(self) -> dict[str, str]:
        return {"name": "rhizome", "version": "0.2.0"}

    def initialize(self, params: dict[str, Any] | None = None) -> dict[str, Any]:
        requested = str((params or {}).get("protocolVersion") or "").strip()
        protocol_version = (
            requested if requested in SUPPORTED_PROTOCOL_VERSIONS else LATEST_PROTOCOL_VERSION
        )
        return {
            "protocolVersion": protocol_version,
            "capabilities": {
                "tools": {"listChanged": False},
                "resources": {},
                "prompts": {},
            },
            "serverInfo": self.server_info,
        }

    def list_tools(self) -> dict[str, Any]:
        return {"tools": [tool.to_dict() for tool in TOOLS]}

    def call_tool(self, name: str, arguments: Any | None = None) -> dict[str, Any]:
        if name not in self.tools_by_name:
            raise McpError(-32602, f"Unknown tool: {name}")

        args = _coerce_arguments(arguments)
        try:
            if name == "wiki_overview":
                return _json_result(self.wiki_overview())
            if name == "search_wiki":
                query = _required_string(args, "query")
                limit = _coerce_limit(args.get("limit"), default=10, minimum=1, maximum=25)
                page_type = str(args.get("page_type") or "").strip() or None
                return _json_result(self.search_wiki(query, limit=limit, page_type=page_type))
            if name == "search":
                query = _required_string(args, "query")
                return self.connector_search(query)
            if name == "read_wiki_page":
                locator = _required_string(args, "locator")
                max_chars = _coerce_limit(
                    args.get("max_chars"), default=20000, minimum=1000, maximum=80000
                )
                return _json_result(self.read_wiki_page(locator, max_chars=max_chars))
            if name == "fetch":
                document_id = _required_string(args, "id")
                return self.connector_fetch(document_id)
            if name == "page_neighbors":
                locator = _required_string(args, "locator")
                return _json_result(self.page_neighbors(locator))
            if name == "list_wiki_pages":
                page_type = str(args.get("page_type") or "").strip() or None
                limit = _coerce_limit(args.get("limit"), default=100, minimum=1, maximum=500)
                return _json_result(self.list_wiki_pages(page_type=page_type, limit=limit))
        except (FileNotFoundError, ValueError) as exc:
            return _error_tool_result(str(exc))

        raise McpError(-32602, f"Unhandled tool: {name}")

    def wiki_overview(self) -> dict[str, Any]:
        report = self.connector.inspect()
        graph = self.connector.graph()
        if self.config is not None:
            status = get_status(self.config)
            workspace = {
                "root": str(self.config.workspace_root),
                "topic": self.config.topic,
                "description": self.config.description,
                "raw_files": status["raw_files"],
                "processed": status["processed"],
                "unprocessed": status["unprocessed"],
                "needs_document_review": status["needs_document_review"],
                "wiki_pages": status["wiki_pages"],
                "watches": status.get("watches", 0),
                "watches_active": status.get("watches_active", 0),
                "watches_paused": status.get("watches_paused", 0),
                "watches_failing": status.get("watches_failing", 0),
            }
        else:
            workspace = {
                "root": str(self.connector.root),
                "topic": self.connector.root.name,
                "description": "",
                "raw_files": report.raw_file_count,
                "processed": None,
                "unprocessed": None,
                "needs_document_review": None,
                "wiki_pages": report.total_pages,
                "watches": report.page_type_counts.get("watch", 0),
                "watches_active": None,
                "watches_paused": None,
                "watches_failing": None,
            }
        top_pages = sorted(
            graph.nodes,
            key=lambda node: (node.inbound_count + node.outbound_count, node.inbound_count),
            reverse=True,
        )[:10]
        return {
            "ok": True,
            "workspace": workspace,
            "vault": {
                "layout": report.layout,
                "obsidian_enabled": report.obsidian_enabled,
                "page_type_counts": report.page_type_counts,
                "raw_file_count": report.raw_file_count,
                "resolved_link_count": report.resolved_link_count,
                "unresolved_link_count": report.unresolved_link_count,
                "orphan_page_count": report.orphan_page_count,
                "knowledge_page_count": report.knowledge_page_count,
            },
            "top_connected_pages": [
                {
                    "title": node.title,
                    "relative_path": node.relative_path,
                    "page_type": node.page_type,
                    "inbound_count": node.inbound_count,
                    "outbound_count": node.outbound_count,
                }
                for node in top_pages
            ],
            "issues": [issue.to_dict() for issue in report.issues[:10]],
        }

    def search_wiki(
        self,
        query: str,
        *,
        limit: int = 10,
        page_type: str | None = None,
    ) -> dict[str, Any]:
        primary: list[SearchHit] = []
        if self.connector.layout == "compile_workspace" and self.config is not None:
            if search_index_exists(self.config):
                primary = search_pdf_index(
                    self.config,
                    query,
                    limit=limit,
                    connector=self.connector,
                )
        secondary = self.connector.search(query, limit=limit, page_type=page_type)
        hits = _merge_search_hits(
            primary=primary,
            secondary=secondary,
            limit=limit,
            page_type=page_type,
        )
        return {
            "ok": True,
            "query": query,
            "limit": limit,
            "page_type": page_type,
            "hits": [hit.to_dict() for hit in hits],
        }

    def connector_search(self, query: str) -> dict[str, Any]:
        hits = self.search_wiki(query, limit=10)["hits"]
        results = [
            {
                "id": hit["relative_path"],
                "title": hit["title"],
                "url": self._document_url(hit["relative_path"]),
            }
            for hit in hits
        ]
        return self._connector_json_result({"results": results})

    def read_wiki_page(self, locator: str, *, max_chars: int = 20000) -> dict[str, Any]:
        page = self.connector.get_page(locator)
        payload = page.to_dict(include_body=True)
        body, truncated = _truncate_text(str(payload.get("body") or ""), max_chars)
        payload["body"] = body
        payload["body_truncated"] = truncated
        payload["max_chars"] = max_chars
        return {"ok": True, "page": payload}

    def connector_fetch(self, document_id: str) -> dict[str, Any]:
        page_payload = self.read_wiki_page(document_id, max_chars=80000)["page"]
        document = {
            "id": page_payload["relative_path"],
            "title": page_payload["title"],
            "text": page_payload["body"],
            "url": self._document_url(page_payload["relative_path"]),
            "metadata": {
                "page_type": page_payload["page_type"],
                "tags": page_payload["tags"],
                "aliases": page_payload["aliases"],
                "summary": str(page_payload["frontmatter"].get("summary") or ""),
                "word_count": page_payload["word_count"],
                "body_truncated": page_payload["body_truncated"],
                "relative_path": page_payload["relative_path"],
            },
        }
        return self._connector_json_result(document)

    def page_neighbors(self, locator: str) -> dict[str, Any]:
        neighborhood = self.connector.get_neighborhood(locator)
        return {"ok": True, "neighborhood": neighborhood.to_dict(include_body=False)}

    def list_wiki_pages(
        self,
        *,
        page_type: str | None = None,
        limit: int = 100,
    ) -> dict[str, Any]:
        pages = [
            page for page in self.connector.scan()
            if page_type is None or page.page_type == page_type
        ]
        pages = sorted(
            pages,
            key=lambda page: (page.page_type, page.title.lower(), page.relative_path),
        )
        selected = pages[:limit]
        return {
            "ok": True,
            "page_type": page_type,
            "limit": limit,
            "total_matches": len(pages),
            "pages": [
                {
                    "title": page.title,
                    "relative_path": page.relative_path,
                    "page_type": page.page_type,
                    "summary": page.summary_text,
                    "word_count": page.word_count,
                    "inbound_count": len(page.inbound_links),
                    "outbound_count": len(page.resolved_outbound_links),
                }
                for page in selected
            ],
        }

    def _connector_json_result(self, payload: dict[str, Any]) -> dict[str, Any]:
        return {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                }
            ]
        }

    def _document_url(self, relative_path: str) -> str:
        return (self.connector.root / relative_path).resolve().as_uri()

    def handle_json_rpc(self, message: Any) -> dict[str, Any] | list[Any] | None:
        if isinstance(message, list):
            responses = [self._handle_single_json_rpc(item) for item in message]
            return [response for response in responses if response is not None] or None
        return self._handle_single_json_rpc(message)

    def _handle_single_json_rpc(self, message: Any) -> dict[str, Any] | None:
        request_id: Any | None = None
        try:
            if not isinstance(message, dict):
                raise McpError(-32600, "Invalid JSON-RPC request.")
            request_id = message.get("id")
            method = str(message.get("method") or "")
            params = message.get("params")
            if not method:
                raise McpError(-32600, "Missing JSON-RPC method.")

            result = self._dispatch_method(method, params)
            if request_id is None:
                return None
            return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "result": result}
        except McpError as exc:
            if request_id is None:
                return None
            error: dict[str, Any] = {"code": exc.code, "message": exc.message}
            if exc.data is not None:
                error["data"] = exc.data
            return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "error": error}
        except Exception as exc:
            if request_id is None:
                return None
            return {
                "jsonrpc": JSONRPC_VERSION,
                "id": request_id,
                "error": {"code": -32603, "message": str(exc)},
            }

    def _dispatch_method(self, method: str, params: Any) -> dict[str, Any]:
        if method == "initialize":
            if params is not None and not isinstance(params, dict):
                raise McpError(-32602, "initialize params must be an object.")
            return self.initialize(params)
        if method == "ping":
            return {}
        if method == "tools/list":
            return self.list_tools()
        if method == "tools/call":
            if not isinstance(params, dict):
                raise McpError(-32602, "tools/call params must be an object.")
            name = _required_string(params, "name")
            return self.call_tool(name, params.get("arguments"))
        if method == "resources/list":
            return {"resources": []}
        if method == "prompts/list":
            return {"prompts": []}
        if method.startswith("notifications/"):
            return {}
        raise McpError(-32601, f"Method not found: {method}")


def serve_stdio(server: RhizomeMcpServer) -> None:
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            response = {
                "jsonrpc": JSONRPC_VERSION,
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {exc}"},
            }
        else:
            response = server.handle_json_rpc(message)
        if response is None:
            continue
        sys.stdout.write(
            json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n"
        )
        sys.stdout.flush()


class _McpHttpHandler(BaseHTTPRequestHandler):
    server_version = "RhizomeMCP/0.2.0"

    @property
    def rhizome_server(self) -> RhizomeMcpServer:
        return self.server.rhizome_mcp_server  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), format % args)
        )

    def do_OPTIONS(self) -> None:
        if not self._authorize_request(require_token=False):
            return
        self.send_response(204)
        self._send_common_headers()
        self.end_headers()

    def do_GET(self) -> None:
        if not self._authorize_request():
            return
        if self._request_path().rstrip("/") not in {"", "/mcp"}:
            self.send_error(404, "Not found")
            return
        payload = {
            "name": "rhizome",
            "transport": "streamable-http",
            "endpoint": "/mcp",
            "tools": [tool.name for tool in TOOLS],
        }
        self._send_json(payload)

    def do_POST(self) -> None:
        if not self._authorize_request():
            return
        if self._request_path().rstrip("/") != "/mcp":
            self.send_error(404, "Not found")
            return
        length = int(self.headers.get("content-length") or "0")
        raw_body = self.rfile.read(length)
        try:
            message = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            response = {
                "jsonrpc": JSONRPC_VERSION,
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {exc}"},
            }
        else:
            response = self.rhizome_server.handle_json_rpc(message)

        if response is None:
            self.send_response(202)
            self._send_common_headers()
            self.end_headers()
            return

        accept = self.headers.get("accept", "")
        if "text/event-stream" in accept:
            self._send_sse(response)
        else:
            self._send_json(response)

    def _send_common_headers(self) -> None:
        origin = self.headers.get("Origin")
        if origin and origin in self.rhizome_server.allowed_origins:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header(
            "Access-Control-Allow-Headers",
            "authorization, content-type, accept, mcp-session-id",
        )
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Cache-Control", "no-store")

    def _request_path(self) -> str:
        return urlparse(self.path).path

    def _authorize_request(self, *, require_token: bool = True) -> bool:
        origin = self.headers.get("Origin")
        if origin and origin not in self.rhizome_server.allowed_origins:
            self._send_forbidden("Forbidden origin.")
            return False

        token = self.rhizome_server.http_token
        if require_token and token:
            expected = f"Bearer {token}"
            if self.headers.get("Authorization") != expected:
                self._send_forbidden("Missing or invalid bearer token.")
                return False
        return True

    def _send_forbidden(self, message: str) -> None:
        payload = {
            "jsonrpc": JSONRPC_VERSION,
            "id": None,
            "error": {"code": -32001, "message": message},
        }
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(403)
        self._send_common_headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self._send_common_headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_sse(self, payload: Any) -> None:
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        body = f"event: message\ndata: {data}\n\n".encode("utf-8")
        self.send_response(200)
        self._send_common_headers()
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve_http(server: RhizomeMcpServer, *, host: str, port: int) -> None:
    httpd = ThreadingHTTPServer((host, port), _McpHttpHandler)
    httpd.rhizome_mcp_server = server  # type: ignore[attr-defined]
    print(f"Rhizome MCP listening on http://{host}:{port}/mcp", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("Rhizome MCP stopped.", file=sys.stderr)
    finally:
        httpd.server_close()


def run_mcp_server(
    *,
    workspace_root: Path,
    transport: str = "stdio",
    host: str = "127.0.0.1",
    port: int = 8765,
    allowed_origins: set[str] | None = None,
    http_token: str | None = None,
) -> None:
    if transport == "http":
        normalized_host = host.strip().lower()
        if http_token is None and normalized_host not in LOCAL_HTTP_HOSTS:
            raise ValueError(
                "Refusing to start unauthenticated HTTP MCP server on a non-localhost "
                "interface. Pass --http-token or bind to 127.0.0.1."
            )
        if http_token is None:
            print(
                "Warning: HTTP MCP server has no bearer token; keep it bound to localhost.",
                file=sys.stderr,
            )
    server = RhizomeMcpServer(
        workspace_root,
        allowed_origins=allowed_origins,
        http_token=http_token,
    )
    if transport == "stdio":
        serve_stdio(server)
        return
    if transport == "http":
        serve_http(server, host=host, port=port)
        return
    raise ValueError(f"Unsupported MCP transport: {transport}")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Rhizome MCP server.")
    parser.add_argument(
        "--workspace",
        "--path",
        "-p",
        dest="workspace_root",
        default=".",
        help="Rhizome workspace root.",
    )
    parser.add_argument(
        "--transport",
        choices=("stdio", "http"),
        default="stdio",
        help="Transport to serve.",
    )
    parser.add_argument("--host", default="127.0.0.1", help="HTTP host.")
    parser.add_argument("--port", type=int, default=8765, help="HTTP port.")
    parser.add_argument(
        "--allow-origin",
        action="append",
        default=[],
        help=(
            "Allowed HTTP Origin. Repeat for multiple origins. Also accepts "
            "comma-separated RHIZOME_MCP_ALLOWED_ORIGINS."
        ),
    )
    parser.add_argument(
        "--http-token",
        default=None,
        help="Optional bearer token required by HTTP transport. Can also use RHIZOME_MCP_HTTP_TOKEN.",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_arg_parser().parse_args(argv)
    env_origins = [
        origin.strip()
        for origin in os.environ.get("RHIZOME_MCP_ALLOWED_ORIGINS", "").split(",")
        if origin.strip()
    ]
    try:
        run_mcp_server(
            workspace_root=Path(args.workspace_root).resolve(),
            transport=args.transport,
            host=args.host,
            port=args.port,
            allowed_origins=set(args.allow_origin) | set(env_origins),
            http_token=args.http_token or os.environ.get("RHIZOME_MCP_HTTP_TOKEN") or None,
        )
    except (FileNotFoundError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
