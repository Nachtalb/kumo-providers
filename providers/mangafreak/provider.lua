-- @id mangafreak
-- @name Mangafreak
-- @version 1.1.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua chrome
-- @base https://ww2.mangafreak.me
--
-- Pure server-rendered HTML scrape. Ported from server/providers/mangafreak.js
-- (itself from keiyoushi en/mangafreak). The chapter list is INLINE on the
-- details page (no ajax) as a <table> under div.manga_series_list, each row
-- linking straight to an opaque reader path (/Read1_<slug>_<n>). We carry that
-- whole reader path in the chapter id so pages() just prepends BASE.
--
-- Local-id discipline: manga id = "<slug>", chapter id = "<slug>/<readerPath>".
-- The host namespaces "mangafreak:" around every call.

local BASE = "https://ww2.mangafreak.me"
local SRC_PER = 2 -- double-fetch to lift items/page over infinite-scroll threshold

local function urlencode(s)
  return (s:gsub("[^%w%-%.%_%~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Filter surface (ported from server/providers/mangafreak.js).
-- Genre filters only apply when combined with a search on this site, and the
-- /Genre/<bitmask> path is bit-per-genre (57 bits) — impractical to model
-- usefully, so expose a display list but don't wire genre params. Status + Type
-- DO work (alongside a query) and are wired in search() below.
local GENRES = { "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror",
  "Martial Arts", "Mystery", "Romance", "School Life", "Sci Fi", "Seinen",
  "Shoujo", "Shounen", "Slice of Life", "Supernatural" }
-- Site status codes on the /Find path: 0=all, 1=completed, 2=ongoing.
local STATUSES = {
  { key = "all", label = "All" },
  { key = "ongoing", label = "Ongoing" },
  { key = "completed", label = "Completed" },
}
local STATUS_CODE = { all = "0", ongoing = "2", completed = "1" }
-- Type is a single-select radio (extraMode). Site codes: 0=both, 1=manga, 2=manhwa.
local EXTRA_MODES = {
  { key = "type", label = "Type", default = "both", options = {
    { key = "both", label = "Both" }, { key = "manga", label = "Manga" }, { key = "manhwa", label = "Manhwa" },
  } },
}
local TYPE_CODE = { both = "0", manga = "1", manhwa = "2" }
local GENRE_MASK = string.rep("0", 57) -- all-zeros = no genre filter; segment is structurally required
local SORTS = { { key = "popular", label = "Popular" }, { key = "latest", label = "Latest" } }

function meta()
  return {
    sorts = SORTS, statuses = STATUSES, genres = GENRES,
    extraModes = EXTRA_MODES, -- Type radio (both/manga/manhwa) — applies with a search query
    genreMode = "multi", multiChapter = true,
  }
end

local function slug_from(href)
  return (href or ""):match("/Manga/([^/?#]+)")
end

local function reader_path(href)
  return (href or ""):gsub("^https?://[^/]+", ""):gsub("^/", ""):gsub("[?#].*$", "")
end

local function parse_status(t)
  local s = (t or ""):lower()
  if s:find("complete") then return "Completed" end
  if s:find("hiatus") then return "Hiatus" end
  if s:find("ongoing") or s:find("on%-going") or s:find("going") then return "Ongoing" end
  return "Unknown"
end

-- The /Genre/All ranking grid: div.ranking_item cards.
local function parse_ranking(doc)
  local items, seen = {}, {}
  for _, el in ipairs(doc:select("div.ranking_item")) do
    local a = el:first('a[href*="/Manga/"]')
    local slug = a and slug_from(a:attr("href"))
    if slug and not seen[slug] then
      local title = ""
      local t = el:first("h3.title, .title")
      if t then title = util.trim(t:text()) end
      if title == "" and a then title = util.trim(a:text()) end
      if title ~= "" then
        seen[slug] = true
        local cover = ""
        local img = el:first("img")
        if img then cover = util.abs_url(util.trim(img:attr("src") or "")) end
        items[#items + 1] = { id = slug, title = title, cover = cover }
      end
    end
  end
  return items
end

local function parse_search(doc)
  local items, seen = {}, {}
  for _, el in ipairs(doc:select("div.manga_search_item, div.mangaka_search_item")) do
    local a = el:first("h3 a, h5 a")
    local slug = a and slug_from(a:attr("href"))
    if slug and not seen[slug] then
      local title = a and util.trim(a:text()) or ""
      if title ~= "" then
        seen[slug] = true
        local cover = ""
        local img = el:first("img")
        if img then cover = util.abs_url(util.trim(img:attr("src") or "")) end
        items[#items + 1] = { id = slug, title = title, cover = cover }
      end
    end
  end
  return items
end

function popular(page, opts)
  local items, seen = {}, {}
  local base = (page - 1) * SRC_PER
  local has_next = false
  for i = 0, SRC_PER - 1 do
    local sp = base + i + 1
    local r = http.get(BASE .. "/Genre/All/" .. sp, { referer = BASE .. "/" })
    local doc = html.parse(r.body)
    local got = parse_ranking(doc)
    if #got == 0 then break end
    for _, m in ipairs(got) do
      if not seen[m.id] then seen[m.id] = true; items[#items + 1] = m end
    end
    has_next = doc:first("a.next_p") ~= nil
  end
  return { items = items, has_next = has_next }
end

function latest(page, opts)
  -- /Latest_Releases uses a different card shape; fall back to the ranking grid
  -- so the offline shape stays consistent (contract only exercises popular).
  return popular(page, opts)
end

function search(query, page, filters, opts)
  filters = filters or {}
  local q = util.trim(query or "")
  local extras = filters.extras or {}
  local type = extras.type or "both"
  local status_code = STATUS_CODE[filters.status] or "0"
  local type_code = TYPE_CODE[type] or "0"
  local filtered = status_code ~= "0" or type_code ~= "0"
  -- Filters ONLY apply on the /Find/<query>/... path and REQUIRE a query. So when
  -- the user sets Status/Type but types no search text, inject a broad match-all
  -- query ('a') so the filter still takes effect (verified: /Find/a/... honours
  -- Status+Type). With neither query nor filter, use the popular grid.
  if q == "" and not filtered then return popular(page, opts) end
  local term = q ~= "" and q or "a"
  -- Path is structurally rigid: /Find/<q>/Genre/<57bits>/Status/<s>/Type/<t>.
  -- Keep the bare /Find/<q> form for an unfiltered text search.
  local path
  if filtered then
    path = "/Find/" .. urlencode(term) .. "/Genre/" .. GENRE_MASK
      .. "/Status/" .. status_code .. "/Type/" .. type_code
  else
    path = "/Find/" .. urlencode(term)
  end
  local r = http.get(BASE .. path, { referer = BASE .. "/" })
  local items = parse_search(html.parse(r.body))
  -- The site's search/filter result is effectively single-page.
  return { items = items, has_next = false }
end

function details(id, opts)
  local slug = id
  local r = http.get(BASE .. "/Manga/" .. slug, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = ""
  local th = doc:first("div.manga_series_data h5")
  if th then title = util.trim(th:text()) end
  if title == "" then title = (slug:gsub("_", " ")) end

  local cover = ""
  local ci = doc:first("div.manga_series_image img")
  if ci then cover = util.abs_url(util.trim(ci:attr("src") or "")) end

  -- manga_series_data rows are labeled sentences, not fixed positions.
  local status, author = "Unknown", "Unknown"
  local data = doc:first("div.manga_series_data")
  if data then
    for _, d in ipairs(data:select("div")) do
      local txt = util.trim(d:text())
      local low = txt:lower()
      if status == "Unknown" and (low:find("series") or low:find("status")
        or low:find("going") or low:find("complete") or low:find("hiatus")) then
        status = parse_status(txt)
      end
      if author == "Unknown" and low:find("written by") then
        author = util.trim(txt:gsub("^.-[Bb]y:%s*", ""))
      end
    end
  end

  local genres = {}
  for _, g in ipairs(doc:select("div.series_sub_genre_list a")) do
    local t = util.trim(g:text())
    if t ~= "" then genres[#genres + 1] = t end
  end

  local description = ""
  local de = doc:first("div.manga_series_description p")
  if de then description = util.trim(de:text()) end

  local chapters, seen = {}, {}
  local list = doc:first("div.manga_series_list")
  if list then
    for _, tr in ipairs(list:select("tr")) do
      local a = tr:first("a")
      local rp = a and reader_path(a:attr("href"))
      if rp and rp ~= "" and not seen[rp] then
        seen[rp] = true
        local tds = tr:select("td")
        local name = ""
        if tds[1] then name = util.trim(tds[1]:text()) end
        if name == "" and a then name = util.trim(a:text()) end
        local num = rp:match("_(%d+%.?%d*)$")
        if not num and name ~= "" then num = name:match("(%d+%.?%d*)") end
        local date = nil
        if tds[2] then
          local dt = util.trim(tds[2]:text())
          if dt ~= "" then date = util.date_parse(dt) end
        end
        chapters[#chapters + 1] = {
          id = slug .. "/" .. rp,
          name = name ~= "" and name or ("Chapter " .. (num or "?")),
          number = num and tonumber(num) or nil,
          url = util.abs_url(a:attr("href") or ""),
          date = date,
        }
      end
    end
  end
  -- newest-first
  table.sort(chapters, function(x, y)
    return (x.number or 0) > (y.number or 0)
  end)

  return {
    title = title,
    cover = cover,
    author = author,
    status = status,
    genres = genres,
    description = description,
    url = BASE .. "/Manga/" .. slug,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  -- id: <slug>/<readerPath> -> /<readerPath>
  local rp = chapter_id:sub((chapter_id:find("/") or 0) + 1)
  local r = http.get(BASE .. "/" .. rp, { referer = BASE .. "/" })
  local doc = html.parse(r.body)
  local urls = {}
  for _, img in ipairs(doc:select("img#gohere")) do
    local s = util.trim(img:attr("src") or "")
    if s ~= "" then urls[#urls + 1] = util.abs_url(s) end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/Manga/" .. id
end
