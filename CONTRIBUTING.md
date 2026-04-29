# Contributing

Bugfixes, new convenience tools, and ports to other platforms (Linux/systemd, Windows) are all welcome.

## Setup for development

```bash
git clone https://github.com/justinritchie/craft-mcp.git
cd craft-mcp
# Have a Craft Connect API key handy. Create:
mkdir -p ~/.mcp-credentials
cat > ~/.mcp-credentials/craft-dev.env <<EOF
CRAFT_API_BASE_URL="https://connect.craft.do/links/<your-link-id>/api/v1"
CRAFT_API_KEY="pdk_xxxxxxxx"
CRAFT_MCP_PORT=8099
EOF
./setup-workspace.sh dev
```

Run the server in the foreground to see logs in real time:

```bash
launchctl bootout gui/$(id -u)/com.$(whoami).craft-mcp-dev   # stop launchd-managed copy
./start.sh dev                                                # foreground run
```

## What's worth submitting

- **Bug reports** with a minimal reproduction. The Craft Connect API has its own quirks; if a tool returns the wrong shape, paste the raw HTTP response too.
- **New convenience tools** that wrap common multi-step Craft operations into a single MCP call. The bar: it should save the model from doing 3+ tool calls and the responses should be more token-efficient.
- **Better defaults / less-leaky abstractions** in `craft_read_markdown` or sibling read tools.
- **Linux/systemd parity** — a `setup-workspace-systemd.sh` that does the launchd equivalent for systemd.
- **Tests** — there's no test suite yet. A smoke test that exercises a few endpoints against a sandbox workspace would be a great first contribution.

## What we won't merge

- Hardcoded credentials, workspace IDs, or anything else that ties the repo to a specific Craft account. Everything user-specific lives in `~/.mcp-credentials/`.
- Telemetry / analytics on the local server.
- Code that requires logging in via username/password (Connect API tokens are the only supported auth path).

## Style

- Match the existing style in `server.py`: PEP 723 inline metadata for deps, single httpx client reused across all tool calls, lifespan hook for warmup + cleanup.
- Tool descriptions should be useful to the LLM, not just to a developer reading the spec. State what the tool does, what to use it for, and which sibling tools it differs from.
- Prefer adding new tools over modifying generated tools' shapes — `from_openapi()` regenerates them when Craft updates the spec, so any patch on top will silently revert.

## Pull requests

- One logical change per PR.
- Update the README's "What's in here" section if you add a new top-level file.
- If your change has security implications (anything touching auth, or that could exfiltrate workspace data), call it out in the PR description.
