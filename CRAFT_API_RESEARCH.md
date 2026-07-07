# Craft API research — comments, publish, custom publish URL

_Research date: 2026-05-21. Sources: local `openapi.json` (the spec our craft-* MCPs are built from), the live Craft Connect API reference, and Craft's Help Center. Links at bottom._

## TL;DR

- **Publishing a document is NOT in the API.** No publish endpoint exists. Publishing, URL customization (custom path / custom Craft domain / custom domain), password protection, expiration, and the comments-on-published-page toggle are **all UI-only** (Share → Publish in the Craft app). There is no programmatic way to publish a doc or set its public URL via the Connect API.
- **Comments are add-only via API.** `POST /comments` adds a comment to a block (flagged experimental). There is **no** GET/resolve/delete-comment endpoint. You _can_ read existing comments indirectly via `GET /blocks?fetchMetadata=true` (block metadata includes comments).
- **`GET /connection`** returns `urlTemplates` — but these are for constructing in-app **deep links** to blocks (e.g. `craftdocs://`-style), **not** public/published web URLs.
- The API is scoped to a "connection" (a selected set of docs or the whole space), authed by either a public link token embedded in the URL or an API key (`pdk_…`). It is a **document-content** API, not a publishing/sharing API.

## What the Craft Connect API actually exposes (authoritative)

Base URL pattern: `https://connect.craft.do/links/<linkId>/api/v1`
Spec title: "Craft – API for All Documents 1.0.0"

| Method | Path | Purpose |
|---|---|---|
| GET | `/blocks` | Fetch blocks (by `id` or daily-note `date`; `maxDepth`; `fetchMetadata=true` → comments, authors, timestamps) |
| POST | `/blocks` | Insert blocks (structured JSON or markdown w/ Craft tokens) |
| PUT | `/blocks` | Update blocks (partial) |
| DELETE | `/blocks` | Delete blocks |
| PUT | `/blocks/move` | Move/reorder blocks across docs |
| GET | `/blocks/search` | Search within a document (RE2 regex, before/after context) |
| GET | `/documents/search` | Search across all docs (relevance, date/location filters) |
| GET | `/documents` | List documents (by location/folder) |
| POST | `/documents` | Create documents (unsorted / templates / folderId) |
| DELETE | `/documents` | Soft-delete (to trash) |
| PUT | `/documents/move` | Move docs between locations / restore from trash |
| GET | `/folders` | List locations + document counts |
| POST | `/folders` | Create folders |
| DELETE | `/folders` | Delete folders |
| PUT | `/folders/move` | Move folders |
| GET | `/collections` | List collections |
| POST | `/collections` | Create collection |
| GET | `/collections/{id}/schema` | Get collection schema |
| PUT | `/collections/{id}/schema` | Update collection schema |
| GET | `/collections/{id}/items` | Get collection items |
| POST | `/collections/{id}/items` | Add items |
| PUT | `/collections/{id}/items` | Update items |
| DELETE | `/collections/{id}/items` | Delete items |
| GET | `/tasks` | Get tasks (scope: inbox/active/upcoming/logbook/document) |
| POST | `/tasks` | Add tasks |
| PUT | `/tasks` | Update tasks (incl. move + state) |
| DELETE | `/tasks` | Delete tasks |
| POST | `/upload` | Upload a file/image/video (experimental) |
| POST | `/comments` | **Add** comments to blocks (experimental) |
| GET | `/connection` | Connection metadata: space id, timezone, current time, deep-link `urlTemplates` (experimental) |
| POST | `/whiteboards` | Create whiteboard |
| GET | `/whiteboards/{id}/elements` | Get whiteboard elements |
| POST | `/whiteboards/{id}/elements` | Add whiteboard elements |
| PUT | `/whiteboards/{id}/elements` | Update whiteboard elements |
| DELETE | `/whiteboards/{id}/elements` | Delete whiteboard elements |

**Conspicuously absent:** anything named publish / share / link / public-url / domain / page-settings. Confirmed against both the local spec and the live API reference.

## Comments — the practical picture

- **Add:** `POST /comments` with `{ "comments": [{ "blockId": "<id>", "content": "..." }] }` → returns `commentId`. Experimental; expect breaking changes. (Our `craft-*` MCPs already expose this as `post_comments_*`.)
- **Read:** no dedicated endpoint, but `GET /blocks?id=<id>&fetchMetadata=true` includes comments in block metadata (alongside createdBy/lastModifiedBy/timestamps). So a "read comments" capability is achievable by fetching blocks with metadata and projecting the comment fields.
- **Resolve / delete / reply:** not exposed. Those are also UI-only today (or via the published-page comment toggle, which is a reader-facing feature, not the API).

## Publishing — confirmed UI-only feature set

From the Help Center "Publishing Documents" page. None of this is reachable via the API:

- **Publish:** Share button → Publish → Create Link. Default URL `craft.me/s/abc123`.
- **URL customization:**
  - Craft Domain — `yourname.craft.me` (default is random like `brave-lion-456.craft.me`). All plans incl. Starter.
  - Custom URL Path — e.g. `/amazing-content` instead of `/s/abc123`.
  - Custom Domain — `blog.yourcompany.com`. Requires Plus or higher.
- **Security:** password protection, email-domain restriction, expiration date.
- **Engagement:** enable/disable reader comments on the published page; TOC visibility, search, print, page navigation.
- **Management:** Remove Link (unpublish); doc stays in workspace.
- **Presentation Mode** + analytics (paid plans) also UI-only.

## Implications for our MCPs

1. **Don't bother adding publish/publish-URL tools** — there's no endpoint to call. If programmatic publishing ever matters, the only paths would be (a) UI automation (chrome-devtools driving the Craft web app), or (b) wait for Craft to ship a publish endpoint. Neither is worth building now.
2. **Comments are worth a small enhancement.** We have add (`post_comments_*`). We could add a thin **read-comments** capability by calling `GET /blocks?fetchMetadata=true` and projecting the comment fields (no new Craft endpoint needed — it's a client-side projection over data we can already fetch). Low effort, genuinely useful.
3. **Deep links, not public links.** `GET /connection` `urlTemplates` give in-app deep links to blocks — handy for "open this block in Craft," but not shareable public URLs.
4. **Auth note:** the Connect API now supports API-key mode (`pdk_…`) in addition to the public-link-token-in-URL mode. Either works; key mode is the more controllable option.

## Sources

- Local spec: `craft-mcp/openapi.json` (servers: `https://connect.craft.do/links/<linkId>/api/v1`)
- Live API reference (All Documents / space): https://connect.craft.do/api-docs/space
- API docs index: https://connect.craft.do/api-docs
- Craft Help — API overview: https://craft-support.mintlify.app/en/integrate/api
- Craft Help — Publishing Documents (UI feature, URL customization): https://craft-support.mintlify.app/en/share-and-publish/publish
- Imagine API guides (enable API, AI bundle): https://www.craft.do/imagine/
- Community references: `pa1ar/craft-cli`, `yigitkonur/n8n-nodes-craft`, Termo "Craft Connect" skill (all confirm the same endpoint surface; CLI notes `fetchMetadata=true` for comments and `pdk_` API keys)
