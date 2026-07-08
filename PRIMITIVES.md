# merjs Primitives Reference

Complete reference for all public primitives exported by `src/mer.zig`.

---

## Routing

merjs uses **file-based routing**. Files in `app/` become pages; files in `api/` become API endpoints.

| File | URL |
|------|-----|
| `app/index.zig` | `/` |
| `app/about.zig` | `/about` |
| `app/users/[id].zig` | `/users/:id` (dynamic) |
| `api/hello.zig` | `/api/hello` |

Run `zig build codegen` after adding/removing routes.

---

## Request (`mer.Request`)

| Field / Method | Type | Description |
|----------------|------|-------------|
| `.method` | `mer.Method` | HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS) |
| `.path` | `[]const u8` | Request path (`/users/42`) |
| `.query_string` | `[]const u8` | Raw query string (after `?`) |
| `.body` | `[]const u8` | Raw request body bytes |
| `.cookies_raw` | `[]const u8` | Raw `Cookie:` header |
| `.params` | `[]const Param` | Dynamic route params |
| `.allocator` | `std.mem.Allocator` | Per-request arena allocator |
| `.param(name)` | `?[]const u8` | Get a dynamic route parameter |
| `.queryParam(name)` | `?[]const u8` | Get a query parameter |
| `.queryParams()` | `StringHashMap` | All query params as a map |
| `.cookie(name)` | `?[]const u8` | Get a cookie value |

---

## Response (`mer.Response`)

| Field | Type | Description |
|-------|------|-------------|
| `.status` | `std.http.Status` | HTTP status code |
| `.content_type` | `mer.ContentType` | Response content type |
| `.body` | `[]const u8` | Response body |
| `.cookies` | `[]const SetCookie` | Cookies to set |

### Response Helpers

| Function | Description |
|----------|-------------|
| `mer.html(body)` | 200 OK, `text/html` |
| `mer.json(body)` | 200 OK, `application/json` |
| `mer.typedJson(alloc, value)` | Serialize struct to JSON response |
| `mer.text(status, body)` | Custom status, `text/plain` |
| `mer.notFound()` | 404 Not Found |
| `mer.internalError(msg)` | 500 Internal Server Error |
| `mer.badRequest(msg)` | 400 Bad Request |
| `mer.redirect(location, status)` | HTTP redirect (302, 303, 301) |
| `mer.withCookies(response, cookies)` | Attach Set-Cookie headers |

---

## Streaming SSR (`mer.StreamWriter`)

Export `renderStream(req, stream)` from a page to enable shell-first streaming.

| Method | Description |
|--------|-------------|
| `stream.write(html)` | Write HTML to the chunked stream |
| `stream.flush()` | Flush buffer to browser immediately |
| `stream.placeholder(id, fallback)` | Register a placeholder with skeleton HTML |
| `stream.resolve(id, content)` | Swap a placeholder with real content |

### StreamParts

Returned by `layout.streamWrap()`:

| Field | Description |
|-------|-------------|
| `.head` | HTML from `<!DOCTYPE>` through `<header>` — flushed immediately |
| `.tail` | Footer + closing tags — sent after page body |

---

## Data Fetching

### `mer.fetch(allocator, opts) !FetchResponse`

Single HTTP request during SSR.

### `mer.fetchAll(allocator, requests) []?FetchResponse`

Parallel HTTP requests. Uses OS threads on native; two-phase JS bridge on Workers.

### FetchRequest

| Field | Default | Description |
|-------|---------|-------------|
| `.url` | required | URL to fetch |
| `.method` | `.GET` | HTTP method |
| `.body` | `null` | Request body |
| `.headers` | `&.{}` | Extra headers |

### FetchResponse

| Field | Description |
|-------|-------------|
| `.status` | `std.http.Status` |
| `.body` | `[]u8` — call `.deinit(allocator)` when done |

---

## Meta / SEO (`mer.Meta`)

Export `pub const meta: mer.Meta` from any page.

| Field | Default | Description |
|-------|---------|-------------|
| `.title` | `""` | Page title |
| `.description` | `""` | Meta description |
| `.og_title` | `null` | Open Graph title |
| `.og_description` | `null` | OG description |
| `.og_image` | `null` | OG image URL |
| `.og_url` | `null` | Canonical OG URL |
| `.og_type` | `"website"` | OG type |
| `.og_site_name` | `"merjs"` | OG site name |
| `.twitter_card` | `"summary_large_image"` | Twitter card type |
| `.twitter_title` | `null` | Twitter title |
| `.twitter_description` | `null` | Twitter description |
| `.twitter_image` | `null` | Twitter image |
| `.twitter_site` | `null` | Twitter @handle |
| `.canonical` | `null` | Canonical URL |
| `.robots` | `null` | Robots directive |
| `.extra_head` | `null` | Extra `<head>` HTML |

---

## Sessions

HMAC-SHA256 signed tokens. Requires `MULTICLAW_SESSION_SECRET` env var.

| Function | Description |
|----------|-------------|
| `mer.signSession(alloc, user_id, ttl_secs)` | Create a signed session token |
| `mer.verifySession(token)` | Verify and decode a session token. Returns `?Session` |
| `mer.SESSION_DEFAULT_TTL` | 7 days (604800 seconds) |

### Session struct

| Field | Type | Description |
|-------|------|-------------|
| `.user_id` | `[]const u8` | Authenticated user ID |
| `.expires_at` | `i64` | Unix expiry timestamp |

---

## Validation — dhi (`mer.dhi`)

Pydantic-style comptime schemas.

| Type | Description |
|------|-------------|
| `mer.dhi.Model(name, fields)` | Define a validated model |
| `mer.dhi.Str(opts)` | String with min/max length |
| `mer.dhi.Int(T, opts)` | Integer with gt/lt/ge/le bounds |
| `mer.dhi.Float(T, opts)` | Float with bounds |
| `mer.dhi.Bool(opts)` | Boolean |
| `mer.dhi.EmailStr` | Email validation |
| `mer.dhi.HttpUrl` | URL validation |
| `mer.dhi.Uuid` | UUID format |
| `mer.dhi.IsoDate` | ISO 8601 date |
| `mer.dhi.IsoDatetime` | ISO 8601 datetime |

Also: `mer.parseJson(T, req)` and `mer.formParam(body, name)`.

---

## Environment (`mer.env`)

| Function | Description |
|----------|-------------|
| `mer.env(name)` | Read env var. Returns `?[]const u8` |
| `mer.loadDotenv()` | Load `.env` file (called at startup) |

---

## HTML Builder (`mer.h`)

Type-safe HTML DSL for building pages programmatically.

```zig
const h = mer.h;
h.div(.{ .class = "card" }, .{
    h.h2(.{}, "Title"),
    h.p(.{}, "Body text."),
});
h.document(.{ h.charset("UTF-8") }, .{ h.h1(.{}, "Hello") });
```

---

## HTML Linter (`mer.lint`)

Comptime HTML structural validator. Use `mer.lint.check(node)`.

---

## Layout (`app/layout.zig`)

| Export | Signature | Description |
|--------|-----------|-------------|
| `wrap` | `(alloc, path, body, meta) []u8` | Wrap non-streaming pages |
| `streamWrap` | `(alloc, path, meta) StreamParts` | Streaming layout (head/tail split) |

---

## SSR Shell (client-side navigation, `X-Mer-Shell`)

Progressive enhancement for SSR pages: same-origin link clicks and back/forward
navigation are intercepted and fetched as fragments instead of triggering a
full page reload. The server remains the single source of truth for
rendering — there is no client-side router or virtual DOM, only a DOM swap.

### Opt in

1. Give your layout's swappable region an id of `mer-shell`:

    ```zig
    // app/layout.zig
    w.writeAll("<main id=\"mer-shell\">") catch return body;
    w.writeAll(body) catch return body;
    w.writeAll("</main><script src=\"/mer-shell.js\" defer></script>") catch return body;
    ```

2. Copy `public/mer-shell.js` into your project (included by default in
   projects scaffolded with `mer init`).

### How it works

- The client script listens for clicks on same-origin `<a>` links (skipping
  `target="_blank"`, `download`, `data-mer-reload`, and hash links) and for
  `popstate`.
- Instead of a normal navigation, it does `fetch(url, { headers: { 'X-Mer-Shell': '1' } })`.
- The server detects that header and calls the route's `render()` directly,
  **skipping layout wrapping**, returning
  `{"title": "...", "body": "...html...", "extraHead": "...css..."}` as JSON
  instead of a full document. `extraHead` is the page's `meta.extra_head`
  (normally injected by the layout, which shell-nav skips) — the client
  swaps it into a dedicated, reused container in `<head>` so each page's own
  CSS applies and replaces the previous page's, instead of never loading or
  piling up forever. If the route also exports `renderStream`, that is
  buffered into the fragment instead — otherwise pages whose real content
  lives in `renderStream` (streaming demos, live data) would show whatever
  placeholder their required `render()` returns.
- Before swapping, `document` fires `mer:before-navigate` — pages with their
  own inline scripts (polling loops, timers, listeners) should listen for
  this and clean up (`clearInterval`, abort fetches, etc.), since shell-nav
  doesn't destroy the JS realm the way a full page load would; anything left
  running will throw trying to touch DOM nodes that are about to be removed.
- The client swaps `data.body` into `#mer-shell` and sets `document.title`,
  then pushes the new URL via `history.pushState`.
- **`<script>` tags in the swapped fragment are recreated (not just inserted)**
  so the browser actually executes them — `innerHTML` never runs embedded
  `<script>` tags per the HTML spec, so without this, any page relying on
  inline scripts (streaming resolve/skeleton swaps, live polling) would
  silently do nothing after a shell-nav.
- A custom `mer:navigate` event fires after the swap and script execution
  (`document.addEventListener('mer:navigate', e => ...)`, `e.detail.url` is
  the new URL) so page-specific JS can re-initialize after content changes.

### Safe fallbacks

- No `#mer-shell` element on the page → the script does nothing (plain SSR).
- Non-JSON response (e.g. a prerendered/static `dist/` page) → falls back to
  a full `location.href` navigation.
- Any fetch/network error → falls back to a full navigation.
- Redirects (`mer.redirect(...)`) are followed transparently by `fetch`.
- Cookies set by the route (`mer.withCookies(...)`) are still emitted as
  `Set-Cookie` headers on shell responses.

### When to use it

- ✅ Multi-page SSR apps where you want SPA-like snappy navigation without a
  client framework or Wasm DOM renderer.
- ❌ Not a replacement for real interactivity — pair with small hand-written
  JS (or WASM modules) for anything beyond navigation.

---

## CLI (`mer`)

```
mer init <name>      Scaffold a new project
mer dev [--port N]   Codegen + dev server with hot reload
mer build            Production build (ReleaseSmall + prerender)
mer --version        Print version
```

---

## Deployment

- **Native**: `zig build -Doptimize=ReleaseSmall` → single static binary
- **Workers**: `zig build worker` → WASM + `wrangler deploy`
- **SSG**: `pub const prerender = true` + `zig build prerender` → static HTML in `dist/`
