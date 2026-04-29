#!/usr/bin/env bash
# Stop a Craft MCP wrapper for one workspace.
#
# Usage: ./stop.sh <workspace-name>
#
# Looks up the port from ~/.mcp-credentials/craft-<workspace-name>.env and
# kills whatever is bound to that port. If the launchd job is loaded, it'll
# be auto-restarted by KeepAlive — use `launchctl bootout` (uninstall-workspace.sh)
# if you want to actually stop it.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <workspace-name>" >&2
  exit 64
fi

WORKSPACE="$1"
ENV_FILE="${HOME}/.mcp-credentials/craft-${WORKSPACE}.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: credentials not found at $ENV_FILE" >&2
  exit 65
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${CRAFT_MCP_PORT:?must be set in $ENV_FILE}"

PIDS=$(lsof -i ":$CRAFT_MCP_PORT" -sTCP:LISTEN -t 2>/dev/null || true)
if [[ -z "$PIDS" ]]; then
  echo "Nothing listening on port $CRAFT_MCP_PORT for craft-${WORKSPACE}."
  exit 0
fi

echo "Stopping craft-${WORKSPACE} (PIDs: $PIDS)"
# shellcheck disable=SC2086
kill $PIDS
sleep 1

# Verify
if lsof -i ":$CRAFT_MCP_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "Still bound. Sending SIGKILL."
  # shellcheck disable=SC2086
  kill -9 $PIDS || true
fi

echo "Done. (If launchd has the job loaded with KeepAlive, it will respawn — use uninstall-workspace.sh to fully unload.)"
