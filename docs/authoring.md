# Writing a Kumo provider

A **provider** teaches Kumo how to browse and read one manga source. It is a
single, self-contained **Lua 5.4** script that runs inside a **sandbox** — no
`io`, no `os`, no `load`, no filesystem, no network except through the host API
below, and a hard per-call **instruction budget** that kills runaway loops. You
get pure Lua plus the host functions documented here; that is the whole world.

A provider lives at `providers/<id>/provider.lua`. The directory name **must**
equal the script's `-- @id`. Ship a square `icon.avif` and a short `readme.md`
next to it, then regenerate the manifest with `node scripts/build-index.mjs`.

---

## 1. Metadata header

The script begins with a block of `-- @key value` comment lines. Parsing stops
at the first non-comment line (blank `--` lines are allowed and skipped). These
keys populate `index.json` and configure the host.

| Key         | Required | Example                     | Meaning                                                   |
| ----------- | :------: | --------------------------- | --------------------------------------------------------- |
| `@id`       |    ✅    | `weebcentral`               | Stable local id. Equals the directory name. `[a-z0-9_]+`. |
| `@name`     |    ✅    | `Weeb Central`              | Display name.                                             |
| `@version`  |    ✅    | `1.0.0`                     | Semver. Bump on any behavioural change.                   |
| `@langs`    |    ✅    | `en,de`                     | Comma-separated language codes.                           |
| `@nsfw`     |    ✅    | `false`                     | `true`/`false`. Gates the source behind the NSFW toggle.  |
| `@rate`     |    ✅    | `4/1s`                      | Politeness budget: N requests per window. Host-enforced.  |
| `@ua`       |    ✅    | `chrome`                    | Preferred User-Agent family the host should send.         |
| `@base`     |    ✅    | `https://weebcentral.com`   | Canonical site origin. Absolute https.                    |
| `@verify`   |    –     | (present = true)            | Marks the provider as requiring manual verification. Sets `requires_verification` in the manifest. Omit for normal sources. |

```lua
-- @id weebcentral
-- @name Weeb Central
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua chrome
-- @base https://weebcentral.com
```

---

## 2. Id-namespacing discipline

**Scripts work in LOCAL ids. The host does the namespacing.** This is the single
most important contract rule.

- Every id your script **emits** (`item.id`, `chapter.id`) is a bare
  source-local id — `01J76XYD...`, a slug, whatever the site uses. **Never**
  prefix it with your provider id.
- Every id your script **receives** (`details(id)`, `pages(chapter_id)`,
  `url_for(id)`) has already been **stripped** of the `provider:` prefix by the
  host. You get the bare local id.
- The host adds/removes the `weebcentral:` (globally `provider:slug`,
  `provider:slug/chapter`) prefix at the boundary. A script that emits a
  namespaced id, or that fails to resolve a bare one, breaks routing.
- If a foreign id ever reaches your provider, the host rejects it **before** your
  code runs (`ForeignId`) — you never have to defend against it.

---

## 3. Contract functions

### MUST implement

| Function                          | Returns                    | Notes                                     |
| --------------------------------- | -------------------------- | ----------------------------------------- |
| `popular(page, opts)`             | list result                | Page 1-indexed.                           |
| `latest(page, opts)`              | list result                | Newest updates first.                     |
| `search(query, page, filters, opts)` | list result             | `filters` is a table (may be empty).      |
| `details(id, opts)`               | details result             | `id` is the bare local manga id.          |
| `pages(chapter_id, opts)`         | pages result               | `chapter_id` is the bare local chapter id.|

### MAY implement

| Function          | Returns          | Notes                                                     |
| ----------------- | ---------------- | -------------------------------------------------------- |
| `url_for(id)`     | string           | Canonical web URL for a manga id (for "open in browser").|
| `filters()`       | filter schema    | Declarative search filters. Return `{}` if none.         |
| `settings()`      | settings schema  | User-configurable options; values arrive in `opts.settings` on every call and are validated by the host against the schema (typed defaults, rejected bad values). |

`opts` is a table the host threads through every call. It carries at least
`opts.settings` (the resolved user settings for this provider, seeded from the
`settings()` defaults) and may carry more in future — treat unknown keys as
opaque and forward-compatible.

---

## 4. Output schemas

All URLs (`cover`, `url`, `pages[]`) **must be absolute https**. Use
`util.abs_url(...)` — protocol-relative `//host/...` gets an `https:` prefix.

### List result — `popular` / `latest` / `search`

```lua
{
  items = {
    { id = "<local>", title = "…", cover = "https://…" },
    -- …
  },
  has_next = true,   -- is there another page?
}
```

### Details result — `details`

```lua
{
  title       = "…",
  cover       = "https://…",
  author      = "…",          -- "" if unknown
  status      = "Ongoing",    -- see vocab below
  genres      = { "Action", "Sports" },
  description = "…",
  url         = "https://…",  -- canonical series page
  chapters    = {             -- NEWEST-FIRST
    { id = "<local>", name = "Chapter 281", number = 281, url = "https://…", date = "2024-08-01T00:00:00Z" },
    -- …
  },
}
```

- **Chapters are ordered newest-first** (first element has the highest number).
- `number` is a Lua number or `nil` when unparseable.
- `date` is ISO-8601 (run raw dates through `util.date_parse`) or `nil`.

**Status vocabulary** — normalize to exactly one of:
`Ongoing` · `Completed` · `Hiatus` · `Cancelled` · `Unknown`.

### Pages result — `pages`

```lua
{
  pages   = { "https://…/1.jpg", "https://…/2.jpg" },  -- ordered, absolute https
  referer = "https://weebcentral.com/",                 -- sent when the host fetches images
}
```

---

## 5. Host API

Everything the sandbox exposes. There is no other I/O.

### `http` — network (the only way out)

```lua
http.get(url, { referer = "…", headers = { ["HX-Request"] = "true" } })
  -> { status = 200, body = "…", url = "<final url after redirects>" }

http.post(url, body, { headers = {…}, referer = "…" })         -- raw body
http.post_form(url, { key = value, … }, { … })                 -- urlencoded form
http.get_all({ url1, url2, … }, { … })                         -- batched, host-paced
  -> { {status,body,url}, {status,body,url}, … }
```

The host enforces your `@rate` budget and the `@ua` family; you do not set the
User-Agent yourself. `http.get_all` lets the host parallelise/pace a batch for
you — prefer it over a manual loop of `http.get`.

### `html` — HTML parsing (CSS selectors)

```lua
local doc = html.parse(body)      -- parse into a document
doc:select("a.card")              -- -> list of nodes (array; use ipairs)
doc:first("h1")                   -- -> first matching node or nil

node:text()                       -- concatenated text content
node:attr("href")                 -- attribute value or nil
node:first("img")                 -- first descendant matching a selector
node:select("li")                 -- descendants matching a selector
```

### `json`

```lua
json.parse(str)   -- -> Lua table
json.encode(v)    -- -> string
```

### `util`

```lua
util.abs_url(href)          -- resolve against @base
util.abs_url(base, href)    -- resolve against an explicit base
util.trim(s)                -- strip surrounding whitespace
util.date_parse(str)        -- best-effort -> ISO-8601 string (or nil)
```

### `store` — per-provider key/value cache (catalog TTL caching)

```lua
store.get(key)          -- -> previously stored value or nil
store.set(key, value)   -- persist across calls
```

Use for catalog TTL caching — e.g. the flamecomics pattern where the full
series list is fetched once and reused for search/browse until it expires.
Storage is scoped to your provider; do not assume cross-provider visibility.

---

## 6. Worked example — `weebcentral.lua`, annotated

The reference provider. Server-rendered HTML plus **htmx fragment** endpoints
(the site returns partial HTML when you send `HX-Request: true`). It demonstrates
htmx fragments, label→value detail scraping, and the local-id discipline.

```lua
-- @id weebcentral
-- @name Weeb Central
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 4/1s          -- host limits us to 4 requests/second
-- @ua chrome
-- @base https://weebcentral.com

local BASE = "https://weebcentral.com"
local PER = 24          -- page size the site's htmx endpoint uses
```

**Shared list fetch.** `/search/data` returns a fragment of series cards when
asked via htmx. One helper backs popular/latest/search — only the `sort` (and
optional `text`) differs. Note the manual percent-encoding: the sandbox has no
`os`, so query values are escaped in pure Lua.

```lua
local function list_data(opts)
  local q = "limit=" .. PER
    .. "&offset=" .. ((opts.page - 1) * PER)          -- page is 1-indexed
    .. "&sort=" .. (opts.sort or "Popularity"):gsub(" ", "%%20")
    .. "&order=Descending&official=Any&display_mode=Full%20Display"
  if opts.text and opts.text ~= "" then
    q = q .. "&text=" .. opts.text:gsub("[^%w%-%.%_%~]", function(c)
      return string.format("%%%02X", c:byte())        -- percent-encode by hand
    end)
  end
  local r = http.get(BASE .. "/search/data?" .. q, {
    referer = BASE .. "/",
    headers = { ["HX-Request"] = "true" },             -- ask for the htmx fragment
  })

  local doc = html.parse(r.body)
  local items, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/series/"]')) do
    local href = a:attr("href") or ""
    local id = href:match("/series/(%w+)")             -- LOCAL id — no prefix
    if id and not seen[id] then
      local img = a:first("img")
      local title = ""
      local t = a:first(".series-title, .line-clamp-1, .truncate")
      if t then title = t:text() end
      if title == "" and img then
        title = (img:attr("alt") or ""):gsub("%s+cover$", "")
      end
      local cover = ""
      if img then cover = img:attr("src") or img:attr("data-src") or "" end
      if title ~= "" then
        seen[id] = true                                -- de-dupe repeated cards
        items[#items + 1] = {
          id = id,
          title = util.trim(title),
          cover = util.abs_url(cover),                 -- always absolute https
        }
      end
    end
  end
  return { items = items, has_next = #items >= PER }   -- full page => assume more
end
```

**The three list entry points** are thin sort selectors over the helper:

```lua
function popular(page, opts) return list_data({ page = page, sort = "Popularity" }) end
function latest(page, opts)  return list_data({ page = page, sort = "Latest Updates" }) end

function search(query, page, filters, opts)
  local sort = "Best Match"
  if query == "" then sort = "Popularity" end          -- empty query => browse
  return list_data({ page = page, sort = sort, text = query })
end
```

**Details.** `id` arrives already stripped to the bare local id. Scrape the main
page, then fetch the chapter list from a second htmx fragment. Watch the
site-specific traps called out in the comments — grabbing the logo instead of the
cover, or dragging hidden badge text into the chapter label.

```lua
function details(id, opts)
  local r = http.get(BASE .. "/series/" .. id, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = h1:text() end

  -- cover img carries alt="<title> cover"; this avoids grabbing the site logo
  local cover = ""
  local ci = doc:first('img[alt$="cover"]')
  if ci then cover = ci:attr("src") or "" end

  local author = ""
  local aa = doc:first('a[href*="author="]')            -- author is a search link
  if aa then author = aa:text() end

  -- status text also lives in a search link, not in the <strong> label
  local status = ""
  local st = doc:first('a[href*="included_status"]')
  if st then status = st:text() end                     -- host maps to the vocab

  local genres = {}
  for _, g in ipairs(doc:select('a[href*="included_tag"]')) do
    genres[#genres + 1] = g:text()
  end

  local description = ""
  local de = doc:first("p.whitespace-pre-wrap, li.whitespace-pre-wrap p")
  if de then description = de:text() end

  -- chapters live in an htmx fragment
  local cr = http.get(BASE .. "/series/" .. id .. "/full-chapter-list", {
    referer = BASE .. "/series/" .. id,
    headers = { ["HX-Request"] = "true" },
  })
  local cdoc = html.parse(cr.body)
  local chapters = {}
  for _, a in ipairs(cdoc:select('a[href*="/chapters/"]')) do
    local cid = (a:attr("href") or ""):match("/chapters/(%w+)")   -- LOCAL id
    if cid then
      -- take the first plain span, not a:text(): the latter drags in hidden
      -- "Last Read"/"NEW" badges and inline <style> text
      local label = ""
      local sp = a:first("span.grow > span")
      if sp then label = sp:text() end
      if label == "" then label = a:text() end
      local num = label:match("([0-9]+%.?[0-9]*)")
      local date = nil
      local tm = a:first("time")
      if tm then date = util.date_parse(tm:attr("datetime") or tm:text()) end
      chapters[#chapters + 1] = {
        id = cid,
        name = util.trim(label),
        number = num and tonumber(num) or nil,
        url = BASE .. "/chapters/" .. cid,
        date = date,
      }
    end
  end

  return {
    title = util.trim(title),
    cover = util.abs_url(cover),
    author = util.trim(author),
    status = status,
    genres = genres,
    description = util.trim(description),
    url = BASE .. "/series/" .. id,
    chapters = chapters,          -- site already serves newest-first
  }
end
```

**Pages.** Rebuild the full image endpoint from the bare chapter id, then filter
to real image URLs.

```lua
function pages(chapter_id, opts)
  local r = http.get(BASE .. "/chapters/" .. chapter_id .. "/images?is_prev=False&reading_style=long_strip", {
    referer = BASE .. "/chapters/" .. chapter_id,
    headers = { ["HX-Request"] = "true" },
  })
  local doc = html.parse(r.body)
  local urls = {}
  for _, img in ipairs(doc:select("img")) do
    local src = img:attr("src") or img:attr("data-src") or ""
    if src ~= "" and src:match("%.jpe?g") or src:match("%.png") or src:match("%.webp") then
      urls[#urls + 1] = util.abs_url(src)
    end
  end
  return { pages = urls, referer = BASE .. "/" }        -- referer used to fetch images
end
```

**Optional functions.** `url_for` reconstructs the canonical series URL from an
id; `filters` returns an empty schema for now (declarative sort/status/genre
filters land with the `filters()`/`settings()` milestone).

```lua
function url_for(id)
  return BASE .. "/series/" .. id
end

function filters()
  return {}
end
```

---

## 7. Checklist before you open a PR

- [ ] `providers/<id>/provider.lua` — directory name equals `-- @id`.
- [ ] Full metadata header (`@id @name @version @langs @nsfw @rate @ua @base`).
- [ ] `popular` / `latest` / `search` / `details` / `pages` implemented.
- [ ] All emitted ids are **local** (no `provider:` prefix).
- [ ] Chapters newest-first; `status` in the fixed vocab; dates ISO via `util.date_parse`.
- [ ] Every `cover` / `url` / `pages[]` is absolute https (via `util.abs_url`).
- [ ] `providers/<id>/icon.avif` (square) and `providers/<id>/readme.md`.
- [ ] Ran `node scripts/build-index.mjs` and committed the updated `index.json`.
