#!/usr/bin/env bash
# Start a Craft MCP wrapper for one workspace.
#
# Usage: ./start.sh <workspace-name>
#
# Reads credentials from ~/.mcp-credentials/craft-<workspace-name>.env which
# must define:
#   CRAFT_API_BASE_URL  — e.g. https://connect.craft.do/links/<linkId>/api/v1
#   CRAFT_API_KEY       — Bearer token of the form pdk_xxxxxxxx
#   CRAFT_MCP_PORT      — local port (e.g. 8003)
#
# Optional in the env file:
#   CRAFT_MCP_TOOL_SUFFIX  — appended to every registered tool name (e.g. "_jumbo")
#                             so multiple instances of this server can run in the
#                             same MCP client without colliding tool names. Empty
#                             (default) preserves upstream behavior.
#
# CRAFT_MCP_SERVER_NAME defaults to "craft-<workspace-name>" if unset in the env file.
#
# This script is what the launchd plist invokes; it's also fine to run directly
# in a foreground terminal for debugging.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <workspace-name>" >&2
  echo "  e.g. $0 jumbo" >&2
  exit 64
fi

WORKSPACE="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HOME}/.mcp-credentials/craft-${WORKSPACE}.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: credentials not found at $ENV_FILE" >&2
  echo "       create it with CRAFT_API_BASE_URL, CRAFT_API_KEY, CRAFT_MCP_PORT" >&2
  exit 65
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${CRAFT_API_BASE_URL:?must be set in $ENV_FILE}"
: "${CRAFT_API_KEY:?must be set in $ENV_FILE}"
: "${CRAFT_MCP_PORT:?must be set in $ENV_FILE}"
export CRAFT_MCP_SERVER_NAME="${CRAFT_MCP_SERVER_NAME:-craft-${WORKSPACE}}"
export CRAFT_OPENAPI_PATH="${CRAFT_OPENAPI_PATH:-$HERE/openapi.json}"

# Refuse to start if port is already bound.
if lsof -i ":$CRAFT_MCP_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "Port $CRAFT_MCP_PORT is already in use. PID(s):"
  lsof -i ":$CRAFT_MCP_PORT" -sTCP:LISTEN
  echo
  echo "Stop the older instance with: ./stop.sh $WORKSPACE"
  exit 1
fi

echo "Starting craft-${WORKSPACE} MCP (FastMCP/streamable-http) on http://localhost:${CRAFT_MCP_PORT}/mcp"
echo "OpenAPI:    $CRAFT_OPENAPI_PATH"
echo "Craft API:  $CRAFT_API_BASE_URL"
echo

# uv run --script handles dep install + venv on first execution.
exec uv run --script "$HERE/server.py"
