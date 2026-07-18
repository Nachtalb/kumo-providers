-- @id mangabuddy
-- @name MangaK
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 3/1s
-- @ua chrome
-- @base https://mangak.io
--
-- JSON-API provider (no scraping). Ported from server/providers/mangabuddy.js
-- (keiyoushi src/en/mangabuddy, BuddyComplex CMS -> Next.js backed by
-- api.mangak.io). The internal id stays "mangabuddy" for library continuity;
-- only the display name (MangaK) and site base (mangak.io) changed.
--   list/search : GET /titles/search?q=&sort=&page=&limit=
--   details     : GET /titles/<apiId>            + GET /titles/<apiId>/chapters
--   pages       : GET /titles/<apiId>/chapters/<chId>
-- The API keys everything by opaque short ids; we carry the human slug in our
-- ids and resolve slug->apiId via search at fetch time.
--
-- Local ids: manga id = "<slug>", chapter id = "<slug>/<cslug>". The host
-- namespaces "mangabuddy:" around every call.

local API = "https://api.mangak.io"
local SITE = "https://mangak.io"

local function parse_status(s)
  local t = tostring(s or ""):lower()
  if t == "ongoing" then return "Ongoing"
  elseif t == "completed" then return "Completed"
  elseif t == "hiatus" then return "Hiatus"
  elseif t == "cancelled" or t == "canceled" then return "Cancelled"
  end
  return "Unknown"
end

local HEADERS = { Origin = SITE, Accept = "application/json" }

local function api_get(url)
  local r = http.get(url, { referer = SITE .. "/", headers = HEADERS })
  local ok, j = pcall(json.parse, r.body)
  if ok then return j or {} end
  return {}
end

local function fix_proto(u)
  u = u or ""
  if u:sub(1, 2) == "//" then return "https:" .. u end
  return u
end

-- slug from an item's url (/i-am-the-sorcerer-king) or explicit slug field
local function slug_of(item)
  if item.slug and item.slug ~= "" then return item.slug end
  local u = item.url or ""
  return u:match("/([^/?#]+)/?$") or ""
end

local function item_to_manga(it)
  local slug = slug_of(it)
  if slug == "" then return nil end
  return {
    id = slug,
    title = it.name or slug,
    cover = fix_proto(it.cover),
  }
end

local function list_req(query)
  local j = api_get(API .. "/titles/search?" .. query)
  local data = j.data or {}
  local items = {}
  for _, it in ipairs(data.items or {}) do
    local m = item_to_manga(it)
    if m then items[#items + 1] = m end
  end
  local pg = data.pagination or {}
  local has_next = pg.has_next == true or pg.hasNext == true
  return { items = items, has_next = has_next }
end

function popular(page, opts)
  return list_req("sort=popular&window=week&page=" .. page .. "&limit=24")
end

function latest(page, opts)
  return list_req("sort=latest&page=" .. page .. "&limit=24")
end

function search(query, page, filters, opts)
  local q = ""
  if query and query ~= "" then
    local clean = query:gsub("[^%w%s%-]", ""):sub(1, 50)
    q = "q=" .. clean:gsub(" ", "%%20") .. "&page=" .. page .. "&limit=24"
  else
    q = "sort=latest&page=" .. page .. "&limit=24"
  end
  return list_req(q)
end

-- Build a short search query from a slug's leading words (<=45 chars).
local function slug_query(slug)
  local q = ""
  for w in tostring(slug):gmatch("[^%-]+") do
    if q ~= "" and (#q + 1 + #w) > 45 then break end
    q = q == "" and w or (q .. " " .. w)
  end
  return (q:gsub("[^%w%s]", "")):sub(1, 50)
end

-- Resolve our slug -> the API's opaque title id via search.
local function resolve_id(slug)
  local q = slug_query(slug)
  for page = 1, 3 do
    local j = api_get(API .. "/titles/search?q=" .. q:gsub(" ", "%%20")
      .. "&page=" .. page .. "&limit=24")
    local data = j.data or {}
    local items = data.items or {}
    for _, it in ipairs(items) do
      if (it.slug or slug_of(it)) == slug then return it.id end
    end
    local pg = data.pagination or {}
    if not (pg.has_next == true or pg.hasNext == true) then
      if page == 1 and items[1] then return items[1].id end
      return nil
    end
  end
  return nil
end

function details(id, opts)
  local slug = id
  local api_id = resolve_id(slug)
  if not api_id then
    return {
      title = slug, cover = "", author = "Unknown", status = "Unknown",
      genres = {}, description = "", url = SITE .. "/" .. slug, chapters = {},
    }
  end

  local dj = api_get(API .. "/titles/" .. api_id)
  local t = (dj.data and dj.data.title) or {}

  local genres = {}
  for _, g in ipairs(t.genres or {}) do
    if g.name then genres[#genres + 1] = g.name end
  end
  local authors = {}
  for _, a in ipairs(t.authors or {}) do
    if a.name then authors[#authors + 1] = a.name end
  end

  local cj = api_get(API .. "/titles/" .. api_id .. "/chapters")
  local raw = (cj.data and cj.data.chapters) or {}
  -- API `number` is a sort index; sort descending for newest-first.
  table.sort(raw, function(x, y) return (x.number or 0) > (y.number or 0) end)
  local chapters = {}
  for _, c in ipairs(raw) do
    local cslug = c.slug
    if not cslug or cslug == "" then
      cslug = (c.url or ""):match("/([^/?#]+)/?$") or tostring(c.id)
    end
    chapters[#chapters + 1] = {
      id = slug .. "/" .. cslug,
      name = c.name or ("Chapter " .. tostring(c.number)),
      number = c.number ~= nil and tonumber(c.number) or nil,
      url = SITE .. (c.url or ("/" .. slug .. "/" .. cslug)),
      date = c.updated_at and util.date_parse(c.updated_at) or nil,
    }
  end

  return {
    title = t.name or slug,
    cover = fix_proto(t.cover),
    author = #authors > 0 and table.concat(authors, ", ") or "Unknown",
    status = parse_status(t.status),
    genres = genres,
    description = t.summary or "",
    url = SITE .. "/" .. slug,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local slash = chapter_id:find("/")
  local slug = chapter_id:sub(1, slash - 1)
  local cslug = chapter_id:sub(slash + 1)
  local api_id = resolve_id(slug)
  if not api_id then return { pages = {}, referer = SITE .. "/" } end

  local cj = api_get(API .. "/titles/" .. api_id .. "/chapters")
  local list = (cj.data and cj.data.chapters) or {}
  local ch_id = nil
  for _, c in ipairs(list) do
    local cs = c.slug or ((c.url or ""):match("/([^/?#]+)/?$"))
    if cs == cslug then ch_id = c.id; break end
  end
  if not ch_id then return { pages = {}, referer = SITE .. "/" } end

  local pj = api_get(API .. "/titles/" .. api_id .. "/chapters/" .. ch_id)
  local ch = (pj.data and pj.data.chapter) or {}
  local urls = {}
  for _, u in ipairs(ch.images or {}) do
    if u and u ~= "" then urls[#urls + 1] = fix_proto(u) end
  end
  return { pages = urls, referer = SITE .. "/" }
end

function url_for(id)
  return SITE .. "/" .. id
end

function filters()
  return {}
end
