# Craft MCP

A local FastMCP wrapper around [Craft Docs](https://www.craft.do)' Connect REST API. One `server.py` + a per-workspace credentials file gives you a fast, reliable, multi-workspace MCP for Claude Desktop, Cursor, or anything else that speaks streamable HTTP MCP.

## What this fixes vs. Craft's hosted MCP

Craft offers its own hosted MCP at `connect.craft.do`. It works most of the time, but using it heavily over the past few months surfaced several real friction points this repo addresses directly:

- **No more transit Unicode mangling.** The hosted MCP has been intermittently dropping or replacing non-ASCII characters in transit (em-dashes, smart quotes, Greek/Cyrillic letters in tagged content). Running the wrapper locally and talking straight HTTP to `connect.craft.do/links/<linkId>/api/v1` keeps every byte intact end-to-end.
- **Cold-start latency eliminated.** The first user-facing call against a fresh hosted-MCP session pays for DNS + TCP + TLS to Craft's edge plus the Connect API auth round-trip — typically 300–700ms before the model sees a single token. This wrapper fires `GET /connection` from a lifespan hook at server boot, so the httpx pool is hot before any tool call arrives.
- **Multi-workspace, simultaneously.** Craft's hosted MCP is one workspace per chat; switching means reconfiguring. This wrapper runs N independent daemons (one per workspace) on N ports, each with its own launchd job, so Jumbo + Personal + XE Network can all be live in the same Claude Desktop session.
- **Token-efficient reads.** Craft blocks come back as a deeply nested JSON tree with per-block `id`, `type`, `textStyle`, `decorations`, `font`, etc. Reading a 50-block doc through `get_blocks` can be 12–20K tokens of metadata for the model to wade through. The included `craft_read_markdown` tool calls the same endpoint, then flattens the tree to plain markdown — typically 60–80% smaller. Use `get_blocks` when you need block IDs (because you're about to edit one); use `craft_read_markdown` for everything else.
- **Survives reboots and Claude Desktop restarts.** Each workspace runs as a `launchd` service with `RunAtLoad` + `KeepAlive`. Reboot the machine, ⌘Q the client, kill the process — the daemon comes back without intervention. The hosted MCP requires re-handshake every session.
- **Secrets never leave your machine.** This repo is templated: per-workspace credentials live in `~/.mcp-credentials/craft-<workspace>.env`, which is never tracked here. The repo is safe to fork and contribute back to without exposing your Connect API keys.
- **Every Connect endpoint is auto-tooled.** `FastMCP.from_openapi()` reads the bundled OpenAPI spec and generates an MCP tool for each operation, with parameter validation derived from the schema. New Craft API endpoints land as new tools as soon as Craft updates the spec — no manual wrapping per endpoint.

## What's in here

```
craft-mcp/
├── server.py                       # FastMCP wrapper. Reads CRAFT_API_BASE_URL,
│                                   #   CRAFT_API_KEY, CRAFT_MCP_PORT from env.
├── openapi.json                    # Craft Connect API OpenAPI spec.
├── _warmup-deps.py                 # Pre-warms uv's cache so first launchd run
│                                   #   doesn't race the health check.
├── start.sh <workspace>            # Source the env, run server.py.
├── stop.sh <workspace>             # Kill whatever is bound to the port.
├── setup-workspace.sh <workspace>  # Generate launchd plist + load it. Idempotent.
├── uninstall-workspace.sh <ws>     # Bootout + remove plist.
├── templates/
│   └── launchd.plist.template      # __WORKSPACE__, __REPO_ROOT__, __LABEL__
├── README.md
├── CONTRIBUTING.md
├── LICENSE                         # MIT
└── SETUP_NEW_MACHINE.md            # Step-by-step for setting up a fresh machine.
```

The repo holds **no workspace-specific data**. Everything that distinguishes one Craft workspace from another (link ID, API key, port number) lives in `~/.mcp-credentials/craft-<workspace>.env`, which is never tracked here.

## Setup

### Prerequisites

- macOS (the `launchd` integration is macOS-specific; the rest is portable to Linux with systemd substitution).
- [Homebrew](https://brew.sh) and `uv`: `brew install uv`.

### Per-workspace credentials

For each Craft workspace you want to wire up, create `~/.mcp-credentials/craft-<workspace>.env`:

```bash
CRAFT_API_BASE_URL="https://connect.craft.do/links/<your-link-id>/api/v1"
CRAFT_API_KEY="pdk_xxxxxxxxxxxxxxxxxxxxxxxx"
CRAFT_MCP_PORT=8003
```

Get `<your-link-id>` and `CRAFT_API_KEY` from Craft → Settings → AI Bundle → API Access. Pick any free local port for `CRAFT_MCP_PORT`; if you have multiple workspaces, each needs a distinct port (8003, 8004, 8005, …).

### Wire it up

```bash
git clone https://github.com/justinritchie/craft-mcp.git
cd craft-mcp
./setup-workspace.sh jumbo      # or whatever you named the credentials file
```

`setup-workspace.sh` validates the env file, generates `~/Library/LaunchAgents/com.<user>.craft-mcp-<workspace>.plist` from the template, loads the launchd job, and verifies the server is listening on its port. Idempotent — re-run after editing the env file or pulling repo updates.

### Connect Claude Desktop

Add this to `~/Library/Application Support/Claude/claude_desktop_config.json` (replace `8003` with whichever port you chose):

```json
"craft-jumbo": {
  "command": "/opt/homebrew/bin/mcp-remote",
  "args": ["http://localhost:8003/mcp"]
}
```

Then ⌘Q + relaunch Claude Desktop. The new tools will appear in the connector list.

## Adding a new workspace

1. Create `~/.mcp-credentials/craft-<workspace>.env` with that workspace's credentials.
2. `./setup-workspace.sh <workspace>`
3. Add the corresponding entry to `claude_desktop_config.json`.
4. ⌘Q + relaunch Claude Desktop.

## Removing a workspace

```bash
./uninstall-workspace.sh <workspace>
```

This bootouts the launchd job and removes the generated plist. The credentials env file in `~/.mcp-credentials/` is left intact — delete it manually if you want.

## Logs

Each workspace writes to its own log files:

```bash
tail -f /tmp/craft-mcp-<workspace>.out.log
tail -f /tmp/craft-mcp-<workspace>.err.log
```

## Architecture notes

`server.py` reads its config entirely from environment variables and is the **same binary** for every workspace. The OpenAPI spec is loaded once at startup; FastMCP's `from_openapi()` walks every path/operation and registers a tool with parameter validation derived from the spec's schemas. Tool names are the spec's `operationId` values.

The lifespan hook on the FastMCP app does two things:

1. Fires a single `GET /connection` to warm the httpx connection pool. The first request through an `AsyncClient` pays DNS + TCP + TLS to `connect.craft.do` (~150–500ms). Doing it once at boot — in the same event loop uvicorn will use to serve subsequent requests — means the first user-facing tool call hits a hot pool. Practical effect: noticeable snappier first response for the user.
2. Closes the httpx client cleanly on shutdown so `launchctl bootout` doesn't leave dangling sockets.

`_warmup-deps.py` exists for one specific failure mode: on a fresh machine, `uv run --script server.py` has to download + install fastmcp + httpx + their ~68 transitive packages on the first invocation, which can take 5–15s. If launchd starts the server before that's done, the `setup-workspace.sh` health check times out. Running `_warmup-deps.py` once during initial install resolves the cache before launchd ever sees the script. (`setup-workspace.sh` calls it implicitly via `uv run` if you've never used these deps before; running it explicitly first just makes the timing predictable.)

## Contributing

This is meant to be improved. If you hit a bug or add a useful tool (better block-reading shortcuts, additional convenience wrappers around common Craft operations, support for other transports, Linux/systemd port), PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
