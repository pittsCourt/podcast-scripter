# Notes service

The inbox behind the app's Story Queue, plus the RSS news shown in the editor sidebar. It grew out of x-post-archiver and imports that tool's `posts.json` the first time it starts.

- **X post links** are fetched through X's public oEmbed endpoint, which needs no API key. It only works for public posts, and gives the post date but not the time.
- **Other links** become articles, using the page's Open Graph tags for the title, summary, site name and image.
- **Other text** becomes a note.
- **News** comes from RSS/Atom feeds, refreshed every `FEED_INTERVAL_MINUTES` and kept for 14 days. The defaults are Google News searches for Real Salt Lake (team) and MLS (league).
- **Storage** is SQLite, using Node 24's built-in `node:sqlite`, at `data/notes.db`.

## Run

From the repo root:

```sh
docker compose up -d --build     # http://localhost:3030
docker compose logs -f notes
```

`NOTES_TOKEN` comes from the repo-root `.env` file, which is not committed. When it's set, every `/api` call except `/api/health` needs `Authorization: Bearer <token>`. The inbox web page asks for the token once and remembers it.

## API

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | No auth. `{ ok, version, authRequired }` |
| GET | `/api/items?status=inbox` | `inbox` (default), `used`, `dismissed`, or `all`. Newest first. |
| POST | `/api/items` | `{ "input": "<link or text>", "title"?: "..." }`. Returns 201 if new, or 200 with the existing item if the link was already saved (and moves it back to the inbox). JSON or form-encoded. |
| PATCH | `/api/items/:id` | `{ "status": "used" }`. The Mac app sets this when a story goes into a project. |
| DELETE | `/api/items/:id` | |
| GET | `/api/news?category=team&limit=20` | `team` or `league` |
| GET/POST | `/api/feeds` | POST takes `{ url, title, category }` |
| DELETE | `/api/feeds/:id` | |
| POST | `/api/feeds/refresh` | Fetches all feeds now |

Items are camelCase JSON: `id, kind (x_post|article|note|news), status, title, body, url, source, authorName, handle, imageUrl, mediaLinks, category, postedOn, publishedAt, createdAt, updatedAt`.

Example:

```sh
curl -H "Authorization: Bearer $NOTES_TOKEN" -H "Content-Type: application/json" \
  -d '{"input":"https://x.com/realsaltlake/status/2098189245450264775"}' http://localhost:3030/api/items
```

## Moving to the OptiPlex later

Copy the repo, or just `docker-compose.yml`, `.env` and `services/notes/`, to the server, including `services/notes/data/` to keep the inbox. Then run `docker compose up -d --build` there. Point the Mac app (Settings, ⌘,) and the iPhone Shortcut at `http://192.168.10.135:3030`.
