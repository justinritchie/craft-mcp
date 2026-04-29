# Setting up a new machine

End-to-end runbook for bringing a fresh Mac up to speed with Craft MCP across N workspaces.

## 1. Install prerequisites

```bash
# Homebrew (skip if already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# uv (Python project + script runner)
brew install uv

# mcp-remote (only needed for Claude Desktop integration)
npm install -g mcp-remote
```

## 2. Get the code

```bash
mkdir -p ~/justinritchie-mcp-servers
cd ~/justinritchie-mcp-servers
git clone https://github.com/justinritchie/craft-mcp.git
```

## 3. Place credentials

For each Craft workspace, create `~/.mcp-credentials/craft-<workspace>.env`:

```bash
mkdir -p ~/.mcp-credentials
chmod 700 ~/.mcp-credentials

cat > ~/.mcp-credentials/craft-jumbo.env <<EOF
CRAFT_API_BASE_URL="https://connect.craft.do/links/<jumbo-link-id>/api/v1"
CRAFT_API_KEY="pdk_xxxxxxxxxxxxxxxxxxxxxxxx"
CRAFT_MCP_PORT=8003
EOF
chmod 600 ~/.mcp-credentials/craft-jumbo.env

# Repeat for each additional workspace, with a unique port each:
#   craft-personal.env  → port 8004
#   craft-xe.env        → port 8005
```

If you keep credentials in a private GitHub repo, just clone it to that location:

```bash
git clone git@github.com:youruser/mcp-credentials.git ~/.mcp-credentials
```

That repo would contain the `craft-*.env` files (plus any other MCP credentials you sync between machines).

## 4. Install each workspace as a launchd service

```bash
cd ~/justinritchie-mcp-servers/craft-mcp
./setup-workspace.sh jumbo
./setup-workspace.sh personal
./setup-workspace.sh xe
```

Each invocation:
- Validates the env file
- Generates `~/Library/LaunchAgents/com.<user>.craft-mcp-<workspace>.plist`
- Loads the launchd job (which sets `RunAtLoad` + `KeepAlive` — starts now, survives reboots)
- Verifies the server is listening on its port

Expected output ends with the listening URL and a Claude Desktop snippet to paste into your config.

## 5. Wire Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` and add an entry per workspace:

```json
"mcpServers": {
  "craft-jumbo":    { "command": "/opt/homebrew/bin/mcp-remote", "args": ["http://localhost:8003/mcp"] },
  "craft-personal": { "command": "/opt/homebrew/bin/mcp-remote", "args": ["http://localhost:8004/mcp"] },
  "craft-xe":       { "command": "/opt/homebrew/bin/mcp-remote", "args": ["http://localhost:8005/mcp"] }
}
```

⌘Q + relaunch Claude Desktop. The `craft-jumbo`, `craft-personal`, `craft-xe` connectors should appear as healthy.

## 6. Verify

```bash
# Check each port
for port in 8003 8004 8005; do
  curl -s "http://localhost:$port/mcp" -o /dev/null -w "$port: HTTP %{http_code}\n"
done

# Check launchd jobs
launchctl list | grep craft-mcp

# Tail logs if any of the above looked off
tail -50 /tmp/craft-mcp-jumbo.err.log
```

## Updating

```bash
cd ~/justinritchie-mcp-servers/craft-mcp
git pull
# Reload all workspaces — picks up updated server.py / openapi.json:
for ws in jumbo personal xe; do
  ./setup-workspace.sh $ws
done
```

The `setup-workspace.sh` script is idempotent — running it on an already-installed workspace bootouts the existing job and reloads with the same plist content (regenerated from the latest template).

## Troubleshooting

**Port already in use.** Some other process is bound — check with `lsof -i :<port>`. Either change the port in the env file and re-run `setup-workspace.sh`, or kill the conflicting process.

**Server didn't come up within 10s.** Almost always uv is installing dependencies for the first time. Run `uv run --script ~/justinritchie-mcp-servers/craft-mcp/_warmup-deps.py` once to populate the cache, then re-run `setup-workspace.sh`.

**`launchctl bootstrap` errors with "input/output error".** The plist already exists with a different definition. Run `./uninstall-workspace.sh <workspace>` first, then `./setup-workspace.sh <workspace>` again.

**Claude Desktop says "MCP server disconnected" right after attaching.** Tail `/tmp/craft-mcp-<workspace>.err.log` — usually a missing or wrong-format env file value.
