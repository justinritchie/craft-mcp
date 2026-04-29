#!/usr/bin/env bash
# Wire up one Craft workspace as a launchd-managed service.
#
# Usage: ./setup-workspace.sh <workspace-name>
#
# Prerequisites:
#   1. Homebrew + uv installed: `brew install uv`
#   2. Credentials file at ~/.mcp-credentials/craft-<workspace-name>.env with:
#        CRAFT_API_BASE_URL="https://connect.craft.do/links/<linkId>/api/v1"
#        CRAFT_API_KEY="pdk_xxxxxxxx"
#        CRAFT_MCP_PORT=8003
#
# What this does:
#   1. Validates the credentials env file exists and has the required keys
#   2. Generates ~/Library/LaunchAgents/com.<user>.craft-mcp-<workspace>.plist
#      from templates/launchd.plist.template
#   3. Loads the launchd job (which sets RunAtLoad + KeepAlive — the MCP starts
#      now and survives reboots)
#   4. Verifies the server is listening on its port
#
# Idempotent: re-running this script bootouts the existing job and reloads.
# Safe to run on a new machine after `git clone`.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <workspace-name>" >&2
  echo "  e.g. $0 jumbo" >&2
  exit 64
fi

WORKSPACE="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HOME}/.mcp-credentials/craft-${WORKSPACE}.env"
TEMPLATE="$HERE/templates/launchd.plist.template"

# launchd label uses the current user's short name so multi-user installs
# don't collide. Falls back to "user" if $USER is somehow unset.
USER_NAME="${USER:-user}"
LABEL="com.${USER_NAME}.craft-mcp-${WORKSPACE}"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
GUI_DOMAIN="gui/$(id -u)"

# --- Pre-flight checks ------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: credentials not found at $ENV_FILE" >&2
  echo "" >&2
  echo "Create it with the credentials for the '$WORKSPACE' workspace:" >&2
  echo "  CRAFT_API_BASE_URL=\"https://connect.craft.do/links/<linkId>/api/v1\"" >&2
  echo "  CRAFT_API_KEY=\"pdk_xxxxxxxx\"" >&2
  echo "  CRAFT_MCP_PORT=8003" >&2
  echo "" >&2
  echo "If you store credentials in a private repo cloned to ~/.mcp-credentials/," >&2
  echo "make sure it includes craft-${WORKSPACE}.env." >&2
  exit 65
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: launchd template not found at $TEMPLATE" >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: 'uv' not found in PATH. Install with: brew install uv" >&2
  exit 1
fi

# Validate required vars in env file
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${CRAFT_API_BASE_URL:?must be set in $ENV_FILE}"
: "${CRAFT_API_KEY:?must be set in $ENV_FILE}"
: "${CRAFT_MCP_PORT:?must be set in $ENV_FILE}"

# Make sure start.sh and stop.sh are executable (we expect the user to have
# clone'd the repo, in which case git preserves the +x bit, but be defensive).
chmod +x "$HERE/start.sh" "$HERE/stop.sh"

# --- Generate plist from template -------------------------------------------

mkdir -p "${HOME}/Library/LaunchAgents"

# Use sed substitutions; pipe through a temp file so we never leave a partial
# plist if any step fails. Use a sentinel char that won't appear in paths.
TMP_PLIST="$(mktemp)"
trap 'rm -f "$TMP_PLIST"' EXIT

sed -e "s|__LABEL__|${LABEL}|g" \
    -e "s|__REPO_ROOT__|${HERE}|g" \
    -e "s|__WORKSPACE__|${WORKSPACE}|g" \
    "$TEMPLATE" > "$TMP_PLIST"

# Atomic move into LaunchAgents
mv "$TMP_PLIST" "$PLIST_DEST"
trap - EXIT

echo "[ok] wrote $PLIST_DEST"

# --- Load (or reload) the launchd job ---------------------------------------

# bootout silently if the job is already loaded (don't fail on first install).
launchctl bootout "${GUI_DOMAIN}/${LABEL}" 2>/dev/null || true

# Bootstrap loads it AND respects RunAtLoad — so the server starts immediately.
launchctl bootstrap "${GUI_DOMAIN}" "$PLIST_DEST"

echo "[ok] launchd job loaded: ${LABEL}"

# --- Wait for port to come up -----------------------------------------------

echo -n "Waiting for craft-${WORKSPACE} to start on port ${CRAFT_MCP_PORT}"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if lsof -i ":${CRAFT_MCP_PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo
    echo "[ok] craft-${WORKSPACE} is listening on http://localhost:${CRAFT_MCP_PORT}/mcp"
    echo
    echo "Logs (in case of trouble):"
    echo "  tail -f /tmp/craft-mcp-${WORKSPACE}.out.log"
    echo "  tail -f /tmp/craft-mcp-${WORKSPACE}.err.log"
    echo
    echo "To wire into Claude Desktop, add this to claude_desktop_config.json:"
    echo "  \"craft-${WORKSPACE}\": {"
    echo "    \"command\": \"npx\","
    echo "    \"args\": [\"-y\", \"mcp-remote\", \"http://localhost:${CRAFT_MCP_PORT}/mcp\", \"--allow-http\"]"
    echo "  }"
    echo
    echo "Note: uses npx so mcp-remote is fetched on demand — no global install"
    echo "needed. --allow-http is required because the local MCP listens on plain HTTP."
    exit 0
  fi
  echo -n "."
  sleep 1
done

echo
echo "WARNING: server didn't come up within 10s. Check logs:"
echo "  tail -100 /tmp/craft-mcp-${WORKSPACE}.err.log"
exit 2
