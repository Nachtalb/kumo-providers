-- @id flamecomics
-- @name Flame Comics
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 2/1s
-- @ua chrome
-- @base https://flamecomics.xyz
--
-- Next.js provider. Ported from server/providers/flamecomics.js (keiyoushi
-- src/en/flamecomics). Rather than track a rotating _next/data buildId we fetch
-- the human pages and parse the embedded <script id="__NEXT_DATA__"> JSON:
--   /browse       -> pageProps.series[]   (full catalog, one payload)
--   /series/<id>  -> pageProps.series + pageProps.chapters[]
--   /series/<id>/<token> -> pageProps.chapter{ images:{idx:{name}} }
-- The full /browse catalog is fetched ONCE and cached via store.set/get so
-- popular/latest/search all page a single client-side list.

local BASE = "https://flamecomics.xyz"
local CDN = "https://cdn.flamecomics.xyz"
local REFERER = BASE .. "/"
local PER = 24

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Extract and parse the __NEXT_DATA__ payload from a page body.
local function next_data(body)
  local doc = html.parse(body)
  local node = doc:first("script#__NEXT_DATA__")
  if not node then return nil end
  local raw = node:text()
  if not raw or raw == "" then return nil end
  local ok, j = pcall(json.parse, raw)
  if not ok then return nil end
  return j
end

local function page_props(body)
  local d = next_data(body)
  if d and d.props and d.props.pageProps then return d.props.pageProps end
  return {}
end

local function cover_url(s)
  if not s or not s.cover or s.series_id == nil then return "" end
  local q = ""
  if s.last_edit then q = "?" .. tostring(s.last_edit) end
  return CDN .. "/uploads/images/series/" .. tostring(s.series_id)
    .. "/" .. urlencode(s.cover) .. q
end

local function series_to_item(s)
  if s.series_id == nil then return nil end
  return {
    id = tostring(s.series_id),
    title = s.title or ("Series " .. tostring(s.series_id)),
    cover = cover_url(s),
  }
end

-- Fetch /browse once, cache the raw series JSON in the provider store.
local function fetch_browse_series()
  local cached = store.get("browse")
  if cached then
    local ok, arr = pcall(json.parse, cached)
    if ok and arr then return arr end
  end
  local r = http.get(BASE .. "/browse", { referer = REFERER })
  local pp = page_props(r.body or "")
  local series = pp.series or {}
  local out = {}
  for _, s in ipairs(series) do
    if s and s.series_id ~= nil then out[#out + 1] = s end
  end
  store.set("browse", json.stringify(out))
  return out
end

local function sort_series(list, sort)
  local arr = {}
  for i, v in ipairs(list) do arr[i] = v end
  if sort == "title" then
    table.sort(arr, function(a, b) return (a.title or "") < (b.title or "") end)
  elseif sort == "likes" then
    table.sort(arr, function(a, b) return (a.likes or 0) > (b.likes or 0) end)
  elseif sort == "latest" then
    table.sort(arr, function(a, b)
      return (a.last_edit or a.time or 0) > (b.last_edit or b.time or 0)
    end)
  end
  return arr
end

local function paginate(list, page)
  local p = math.max(1, page or 1)
  local start = (p - 1) * PER
  local items = {}
  for i = start + 1, math.min(start + PER, #list) do
    local it = series_to_item(list[i])
    if it then items[#items + 1] = it end
  end
  return { items = items, has_next = (start + PER) < #list }
end

function popular(page, opts)
  return paginate(sort_series(fetch_browse_series(), "likes"), page)
end

function latest(page, opts)
  return paginate(sort_series(fetch_browse_series(), "latest"), page)
end

function search(query, page, filters, opts)
  local series = fetch_browse_series()
  local q = (query or ""):lower():gsub("[^a-z0-9]+", "")
  if q ~= "" then
    local filtered = {}
    for _, s in ipairs(series) do
      local names = { s.title }
      if type(s.altTitles) == "table" then
        for _, n in ipairs(s.altTitles) do names[#names + 1] = n end
      end
      for _, n in ipairs(names) do
        if n and (n:lower():gsub("[^a-z0-9]+", "")):find(q, 1, true) then
          filtered[#filtered + 1] = s
          break
        end
      end
    end
    series = filtered
  end
  return paginate(series, page)
end

function details(id, opts)
  local sid = id
  local r = http.get(BASE .. "/series/" .. sid, { referer = REFERER })
  local pp = page_props(r.body or "")
  local s = pp.series or {}
  local chapters_raw = pp.chapters or {}

  local genres = {}
  if s.type then genres[#genres + 1] = s.type end
  for _, c in ipairs(s.categories or {}) do genres[#genres + 1] = c end
  for _, t in ipairs(s.tags or {}) do genres[#genres + 1] = t end

  local authors = {}
  for _, a in ipairs(s.author or {}) do authors[#authors + 1] = a end
  for _, a in ipairs(s.artist or {}) do authors[#authors + 1] = a end

  local chapters = {}
  for _, c in ipairs(chapters_raw) do
    local num = tonumber(c.chapter)
    local num_label = tostring(c.chapter):gsub("%.0+$", "")
    local name = "Chapter " .. num_label
    if c.title and c.title ~= "" then name = name .. " - " .. c.title end
    chapters[#chapters + 1] = {
      id = sid .. "/" .. tostring(c.token),
      name = name,
      number = num,
      url = BASE .. "/series/" .. sid .. "/" .. tostring(c.token),
      date = c.release_date and util.date_parse(tostring(c.release_date)) or nil,
    }
  end
  table.sort(chapters, function(a, b)
    return (a.number or 0) > (b.number or 0)
  end)

  local desc = s.description or ""
  if desc ~= "" then
    local dn = html.parse("<div>" .. desc .. "</div>"):first("div")
    desc = dn and util.trim(dn:text()) or util.trim(desc)
  end

  return {
    title = s.title or ("Series " .. sid),
    cover = cover_url(s),
    author = authors[1] or "Unknown",
    status = s.status or "",
    genres = genres,
    description = desc,
    url = BASE .. "/series/" .. sid,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local sid, token = chapter_id:match("^(.-)/(.+)$")
  local r = http.get(BASE .. "/series/" .. sid .. "/" .. token, { referer = REFERER })
  local pp = page_props(r.body or "")
  local ch = pp.chapter or {}
  local series_id = ch.series_id ~= nil and ch.series_id or sid
  local tok = ch.token or token
  local rel = ch.release_date and ("?" .. tostring(ch.release_date)) or ""

  local imgs = ch.images or {}
  local keys = {}
  for k in pairs(imgs) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)

  local urls = {}
  for _, k in ipairs(keys) do
    local nm = imgs[k] and imgs[k].name
    if nm then
      urls[#urls + 1] = CDN .. "/uploads/images/series/" .. tostring(series_id)
        .. "/" .. tostring(tok) .. "/" .. urlencode(nm) .. rel
    end
  end
  return { pages = urls, referer = REFERER }
end

function url_for(id)
  return BASE .. "/series/" .. id
end

function filters()
  return {}
end
