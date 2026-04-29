#!/usr/bin/env bash
# Tear down a Craft MCP workspace's launchd job and remove its plist.
#
# Usage: ./uninstall-workspace.sh <workspace-name>
#
# The credentials file at ~/.mcp-credentials/craft-<workspace-name>.env is
# left in place — delete it yourself if you want.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <workspace-name>" >&2
  exit 64
fi

WORKSPACE="$1"
USER_NAME="${USER:-user}"
LABEL="com.${USER_NAME}.craft-mcp-${WORKSPACE}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
GUI_DOMAIN="gui/$(id -u)"

# Bootout silently — fine if the job isn't currently loaded.
if launchctl print "${GUI_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${GUI_DOMAIN}/${LABEL}" || true
  echo "[ok] launchd job booted out: ${LABEL}"
else
  echo "[noop] launchd job ${LABEL} was not loaded"
fi

if [[ -f "$PLIST_PATH" ]]; then
  rm "$PLIST_PATH"
  echo "[ok] removed $PLIST_PATH"
else
  echo "[noop] $PLIST_PATH did not exist"
fi

echo
echo "Note: ~/.mcp-credentials/craft-${WORKSPACE}.env was NOT touched."
echo "      Delete it manually if you want to fully scrub the workspace."
