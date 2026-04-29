#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastmcp>=2.5.0",
#   "httpx>=0.27.0",
# ]
# ///
"""
Craft MCP server — local FastMCP wrapper around Craft's REST API.

Why this exists: the hosted Craft MCP has been intermittently flaky and
occasionally drops Unicode characters in transit. This wrapper runs locally,
talks straight to https://connect.craft.do/links/<linkId>/api/v1, and exposes
every endpoint in the OpenAPI spec as an MCP tool via FastMCP.from_openapi —
plus a handful of token-efficient convenience tools that strip the heavy
block-tree metadata when you only need to read content.

Reads two env vars (set by start.sh from a per-workspace credentials file):
  CRAFT_API_BASE_URL  — e.g. https://connect.craft.do/links/<linkId>/api/v1
  CRAFT_API_KEY       — Bearer token of the form pdk_xxxxxxxx

Run with:
  uv run --script server.py     # uv handles deps + venv automatically
"""

from __future__ import annotations

import json
import os
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastmcp import FastMCP


HERE = Path(__file__).resolve().parent

API_BASE = os.environ.get("CRAFT_API_BASE_URL", "").rstrip("/")
API_KEY = os.environ.get("CRAFT_API_KEY", "")
PORT = int(os.environ.get("CRAFT_MCP_PORT", "8003"))
SERVER_NAME = os.environ.get("CRAFT_MCP_SERVER_NAME", "craft")
SPEC_PATH = Path(os.environ.get("CRAFT_OPENAPI_PATH", HERE / "openapi.json"))

# CRAFT_MCP_TOOL_SUFFIX: appended to every registered tool's MCP-facing name.
# Lets multiple instances of this server (one per Craft workspace) coexist
# in the same MCP client without tool-name collisions across connectors.
# Applied to both the auto-generated OpenAPI tools (via operationId rewrite)
# and the hand-written convenience tool below. Empty (default) preserves
# upstream behavior bit-for-bit.
TOOL_SUFFIX = os.environ.get("CRAFT_MCP_TOOL_SUFFIX", "")

if not API_BASE:
    sys.exit("ERROR: CRAFT_API_BASE_URL is not set")
if not API_KEY:
    sys.exit("ERROR: CRAFT_API_KEY is not set")
if not SPEC_PATH.exists():
    sys.exit(f"ERROR: OpenAPI spec not found at {SPEC_PATH}")


# Single httpx client reused across all tool calls. Bearer auth, 30s timeout,
# follow redirects (Craft sometimes 307s). Connection pooling is automatic.
client = httpx.AsyncClient(
    base_url=API_BASE,
    timeout=httpx.Timeout(30.0, connect=10.0),
    follow_redirects=True,
    headers={
        "Authorization": f"Bearer {API_KEY}",
        "Accept": "application/json",
    },
)


with SPEC_PATH.open("r", encoding="utf-8") as f:
    openapi_spec = json.load(f)

# Override the spec's hardcoded server URL with whatever's configured at runtime
# (lets us point at a different Craft space without rewriting the JSON).
openapi_spec["servers"] = [{"url": API_BASE}]


def _generate_operation_id(method: str, path: str) -> str:
    """Derive a short, snake_case operationId from HTTP method + path.

    Craft's OpenAPI spec ships without operationIds, so FastMCP normally
    auto-generates tool names. When TOOL_SUFFIX is set we need to control
    the names ourselves so we can append the suffix predictably.

    Path parameters are dropped (rather than emitted as `by_<param>`) to
    keep names short — FastMCP/MCP truncates tool names beyond ~56 chars,
    and Craft's longest path with its longest user suffix (e.g. _personal)
    overflows otherwise. None of Craft's paths collide once parameters
    are dropped, so the disambiguation isn't needed here. Examples:

        GET /blocks                                     -> get_blocks
        PUT /blocks/move                                -> put_blocks_move
        DELETE /collections/{collectionId}/items        -> delete_collections_items
    """
    parts = [method.lower()]
    for segment in path.strip("/").split("/"):
        if not segment:
            continue
        # Skip path parameter placeholders — they balloon name length
        # without disambiguating Craft's actual path set.
        if segment.startswith("{") and segment.endswith("}"):
            continue
        parts.append(segment.replace("-", "_"))
    return "_".join(parts)


# If a tool suffix is configured, set operationIds for every operation so
# FastMCP.from_openapi names the tools predictably (and we can append the
# suffix). Empty suffix leaves the spec untouched — FastMCP uses its own
# auto-derivation.
if TOOL_SUFFIX:
    HTTP_METHODS = ("get", "post", "put", "delete", "patch", "head", "options")
    for path, path_item in openapi_spec.get("paths", {}).items():
        if not isinstance(path_item, dict):
            continue
        for method, operation in path_item.items():
            if method.lower() not in HTTP_METHODS:
                continue
            if not isinstance(operation, dict):
                continue
            base = operation.get("operationId") or _generate_operation_id(method, path)
            operation["operationId"] = base + TOOL_SUFFIX


@asynccontextmanager
async def lifespan(app):
    """Pre-fetch /connection at server boot to warm the httpx connection pool.

    The first request through an AsyncClient pays for DNS resolution + TCP
    handshake + TLS handshake (~150–500ms to connect.craft.do). Doing it once
    here, in the same event loop uvicorn will use to serve requests, means
    the first user-facing tool call hits a hot pool. Subsequent calls reuse
    the persistent HTTPS connection automatically.

    Also responsible for closing the httpx client cleanly at shutdown so
    launchctl unload doesn't leave dangling sockets.
    """
    try:
        r = await client.get("/connection")
        elapsed_ms = r.elapsed.total_seconds() * 1000
        print(
            f"[craft-mcp] warmup: GET /connection -> {r.status_code} "
            f"({elapsed_ms:.0f}ms cold; pool now hot)",
            flush=True,
        )
    except Exception as e:
        # Don't block startup on a warmup failure — server can still serve
        # requests, the first one will just pay the connection cost.
        print(f"[craft-mcp] warmup failed (non-fatal): {e}", flush=True)
    yield
    # Shutdown: close httpx client gracefully
    try:
        await client.aclose()
    except Exception:
        pass


# Build the MCP server. FastMCP.from_openapi reads each path/operation and
# auto-generates a tool with parameter validation derived from the OpenAPI
# schemas. operationId from the spec becomes the tool name.
mcp = FastMCP.from_openapi(
    openapi_spec=openapi_spec,
    client=client,
    name=SERVER_NAME,
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Hand-written convenience tools (added on top of from_openapi)
# ---------------------------------------------------------------------------
#
# These wrap the auto-generated tools to strip the heavy per-block metadata
# (id, type, textStyle, styling, font, decorations, lineStyle, etc.) when you
# only need to READ content. The standard get_blocks tool returns the full
# JSON tree, which is necessary for editing (you need block IDs) but expensive
# in token terms when reading. craft_read_markdown returns just the
# flattened markdown text — typically 60–80% smaller than the raw JSON.


def _flatten_block_to_markdown(node: Any) -> str:
    """Recursively walk a block tree, concatenating each block's `markdown`
    field with blank-line separators. Drops all metadata (ids, types, styling,
    font, decorations). Preserves nested-page hierarchy via inline newlines.

    Handles three input shapes the API hands us:
      - dict: a single block (page/text/line/etc.) with optional `content` array
      - list: an array of blocks
      - anything else: treated as empty (defensive)
    """
    if isinstance(node, list):
        return "\n\n".join(
            chunk for chunk in (_flatten_block_to_markdown(n) for n in node) if chunk
        )
    if not isinstance(node, dict):
        return ""

    parts: list[str] = []
    md = node.get("markdown")
    if md:
        parts.append(md)
    children = node.get("content")
    if children:
        sub = _flatten_block_to_markdown(children)
        if sub:
            parts.append(sub)
    return "\n\n".join(parts)


@mcp.tool(
    name="craft_read_markdown" + TOOL_SUFFIX,
    description=(
        "Read a Craft document or block subtree as flattened markdown text "
        "ONLY — no block IDs, types, styling, decorations, or other JSON "
        "metadata. Token-efficient alternative to get_blocks: typically "
        "60–80% smaller than the raw JSON tree.\n"
        "\n"
        "Use this when you only need to READ content (skim a doc, summarize, "
        "extract quotes). Use the standard get_blocks tool when you need to "
        "know specific block IDs (e.g. before editing a particular block).\n"
        "\n"
        "Args:\n"
        "  id: Document ID (same as root block ID) or any block ID. UUID-like "
        "      string. Required.\n"
        "  date: Alternative to id — fetch a daily-note block by ISO date "
        "      (YYYY-MM-DD). Mutually exclusive with id.\n"
        "  include_title: If True (default), keep the document/page title at "
        "      the top of the output. Set False to drop the title.\n"
        "\n"
        "Returns: Plain markdown string. Empty string if the block has no "
        "content."
    ),
)
async def craft_read_markdown(
    id: str | None = None,
    date: str | None = None,
    include_title: bool = True,
) -> str:
    if not id and not date:
        return "ERROR: must specify either `id` or `date`"
    if id and date:
        return "ERROR: specify exactly one of `id` or `date`, not both"

    params: dict[str, str] = {}
    if id:
        params["id"] = id
    if date:
        params["date"] = date

    try:
        resp = await client.get("/blocks", params=params)
        resp.raise_for_status()
    except httpx.HTTPStatusError as e:
        return f"ERROR: HTTP {e.response.status_code} from Craft: {e.response.text[:500]}"
    except httpx.HTTPError as e:
        return f"ERROR: network error: {e}"

    data = resp.json()

    # If error envelope rather than a block, surface it
    if isinstance(data, dict) and "error" in data and "code" in data:
        return f"ERROR: {data.get('error')} ({data.get('code')}): {data.get('details')}"

    if not include_title and isinstance(data, dict):
        # Drop only the top-level page's title; keep child markdown intact
        return _flatten_block_to_markdown(data.get("content", []))

    return _flatten_block_to_markdown(data)


if __name__ == "__main__":
    # streamable-http on 0.0.0.0 so mcp-remote on localhost can connect, and
    # so anything else on the box (a Cowork bridge, a curl probe) can hit it.
    print(
        f"[craft-mcp] starting {SERVER_NAME} on http://localhost:{PORT}/mcp",
        flush=True,
    )
    print(f"[craft-mcp] base URL: {API_BASE}", flush=True)
    print(f"[craft-mcp] spec:     {SPEC_PATH}", flush=True)
    mcp.run(transport="http", host="0.0.0.0", port=PORT)
