-- @id nhentai
-- @name nhentai
-- @version 1.1.0
-- @langs en,ja,zh
-- @nsfw true
-- @rate 2/1s
-- @ua chrome
-- @base https://nhentai.net
--
-- ADULT source. Ported from server/providers/nhentai.js — the official v2 JSON
-- API (the old /api/galleries/* now 403 with "Use new API"):
--   popular : GET /api/v2/search?query=*&sort=popular&page=N
--   latest  : GET /api/v2/galleries?page=N&per_page=25
--   search  : GET /api/v2/search?query=<q>&sort=<s>&page=N
--   details : GET /api/v2/galleries/<id>  (tags[] + pages[] inline)
--   pages   : same detail call — pages[].path are ready image paths
-- Single-gallery model: details() returns ONE "Gallery" chapter whose id is the
-- gallery id; pages() reads that gallery's images. Page images live on i* CDN,
-- covers/thumbnails on t*.

local API = "https://nhentai.net/api/v2"
local IMG = "https://i1.nhentai.net"
local THUMB = "https://t1.nhentai.net"
local SITE = "https://nhentai.net"
local PER = 25

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- nhentai's search grammar uses the language NAME (language:english), not an ISO
-- code. Map our codes across. Only these three are real content languages.
local LANG_NAME = { en = "english", ja = "japanese", zh = "chinese" }
local SORTS = {
  { key = "popular", label = "Popular" },
  { key = "popular-week", label = "Popular (week)" },
  { key = "popular-month", label = "Popular (month)" },
  { key = "popular-today", label = "Popular (today)" },
  { key = "date", label = "Latest" },
}
local GENRES = {
  "ahegao", "anal", "big-breasts", "blowjob", "comedy", "defloration",
  "full-color", "futanari", "glasses", "group", "harem", "incest", "lolicon",
  "milf", "mind-break", "nakadashi", "netorare", "schoolgirl-uniform", "shotacon",
  "sole-female", "sole-male", "stockings", "x-ray", "yaoi", "yuri",
}
local TEXT_FILTERS = {
  { key = "tags", label = "Tags", field = "tag", multi = true, hint = "Comma-separated, e.g. big breasts, glasses. Prefix a term with - to exclude." },
  { key = "artist", label = "Artist", field = "artist", multi = false, hint = "One artist name" },
  { key = "characters", label = "Characters", field = "character", multi = true, hint = "Comma-separated character names" },
  { key = "parody", label = "Parody", field = "parody", multi = false, hint = "One series / parody" },
}
local LANGUAGES = {
  { code = "en", label = "English" }, { code = "ja", label = "Japanese" }, { code = "zh", label = "Chinese" },
}
local function is_sort(k)
  for _, s in ipairs(SORTS) do if s.key == k then return true end end
  return false
end

function meta()
  return {
    sorts = SORTS, genres = GENRES, genreMode = "multi", multiChapter = false,
    languages = LANGUAGES, defaultLangs = {}, textFilters = TEXT_FILTERS, langFilter = true,
  }
end

-- A search qualifier: nhentai tags read with SPACES (slugs use hyphens); a
-- multi-word value must be quoted. e.g. tag:"big breasts" or artist:santa.
local function qualifier(field, value)
  local v = util.trim((tostring(value or "")):gsub("%-", " "))
  if v == "" then return "" end
  if v:find("%s") then return field .. ':"' .. v .. '"' end
  return field .. ":" .. v
end

-- Build the effective nhentai query string from all filter inputs (matches the
-- old JS buildQuery). langCode: extras.lang override, else the single global
-- opts.langs entry. Genres are tri-state (include tag: / exclude -tag:). Typed
-- text filters (tag/artist/character/parody) each become qualifiers.
local function build_query(query, filters, opts)
  filters = filters or {}
  local extras = filters.extras or {}
  local parts = {}
  local lang_code = ""
  if extras.lang and LANG_NAME[extras.lang] then
    lang_code = extras.lang
  else
    local langs = opts and opts.langs
    if type(langs) == "table" and #langs == 1 and LANG_NAME[langs[1]] then lang_code = langs[1] end
  end
  if lang_code ~= "" then parts[#parts + 1] = "language:" .. LANG_NAME[lang_code] end

  if query and util.trim(query) ~= "" then parts[#parts + 1] = util.trim(query) end

  for g, mode in pairs(filters.genres or {}) do
    if mode == 1 then
      local q = qualifier("tag", g); if q ~= "" then parts[#parts + 1] = q end
    elseif mode == -1 then
      local q = qualifier("tag", g); if q ~= "" then parts[#parts + 1] = "-" .. q end
    end
  end

  for _, f in ipairs(TEXT_FILTERS) do
    local raw = util.trim(tostring(extras[f.key] or ""))
    if raw ~= "" then
      local terms
      if f.multi then
        terms = {}
        for t in raw:gmatch("[^,]+") do terms[#terms + 1] = util.trim(t) end
      else
        terms = { raw }
      end
      for _, t in ipairs(terms) do
        if t ~= "" then
          local neg = t:sub(1, 1) == "-"
          local q = qualifier(f.field, neg and t:sub(2) or t)
          if q ~= "" then parts[#parts + 1] = (neg and "-" or "") .. q end
        end
      end
    end
  end

  if #parts == 0 then return "*" end
  return table.concat(parts, " ")
end

local function img(path)
  if not path or path == "" then return "" end
  return IMG .. "/" .. (tostring(path):gsub("^/", ""))
end
local function thumb(path)
  if not path or path == "" then return "" end
  return THUMB .. "/" .. (tostring(path):gsub("^/", ""))
end

local function pick_title(o)
  if not o then return "" end
  if type(o) == "string" then return o end
  return util.trim(o.english or o.pretty or o.japanese or "")
end

local function api_get(url)
  local r = http.get(url, { referer = SITE .. "/", headers = { Accept = "application/json" } })
  local ok, j = pcall(json.parse, r.body)
  if not ok then return nil end
  return j
end

-- Map a listing item (search/galleries) to a card.
local function to_card(it)
  if not it or it.blacklisted then return nil end
  local id = it.id
  if not id then return nil end
  local title = pick_title(it.english_title)
  if title == "" then title = pick_title(it.title) end
  if title == "" then title = pick_title(it.japanese_title) end
  if title == "" then title = "Gallery " .. tostring(id) end
  local tpath = ""
  if type(it.thumbnail) == "table" then tpath = it.thumbnail.path or ""
  elseif type(it.thumbnail) == "string" then tpath = it.thumbnail end
  if tpath == "" and type(it.cover) == "table" then tpath = it.cover.path or "" end
  local cover = thumb(tpath)
  if cover == "" then cover = img(tpath) end
  return { id = tostring(id), title = title, cover = cover }
end

local function map_list(arr)
  local out, seen = {}, {}
  for _, it in ipairs(arr or {}) do
    local c = to_card(it)
    if c and not seen[c.id] then
      seen[c.id] = true
      out[#out + 1] = c
    end
  end
  return out
end

local function run_search(q, sort, page)
  local url = API .. "/search?query=" .. urlencode(q)
    .. "&sort=" .. sort .. "&page=" .. page
  local j = api_get(url) or {}
  local items = map_list(j.result)
  local total = j.num_pages
  local has_next
  if total ~= nil then has_next = page < total else has_next = #items >= PER end
  return { items = items, has_next = has_next }
end

function popular(page, opts)
  -- "popular" is a search with an empty text term + active language/filters,
  -- ordered by the chosen sort. build_query yields '*' when nothing constrains.
  local sort = (opts and opts.sort and is_sort(opts.sort)) and opts.sort or "popular"
  local q = build_query("", nil, opts)
  return run_search(q, sort, page)
end

function latest(page, opts)
  -- With any active language filter, route through search (sort=date) so it
  -- applies; otherwise the plain galleries feed.
  local q = build_query("", nil, opts)
  if q ~= "*" then return run_search(q, "date", page) end
  local j = api_get(API .. "/galleries?page=" .. page .. "&per_page=" .. PER) or {}
  local items = map_list(j.result or j.galleries)
  local total = j.num_pages
  local has_next
  if total ~= nil then has_next = page < total else has_next = #items >= PER end
  return { items = items, has_next = has_next }
end

function search(query, page, filters, opts)
  local sort = filters and filters.sort
  if not (sort and is_sort(sort)) then sort = (opts and opts.sort) end
  if not (sort and is_sort(sort)) then sort = "popular" end
  local q = build_query(query, filters, opts)
  return run_search(q, sort, page)
end

-- Names of a given tag type.
local function tags_of_type(tags, ty)
  local out = {}
  for _, t in ipairs(tags or {}) do
    if t.type == ty and t.name then out[#out + 1] = t.name end
  end
  table.sort(out)
  return out
end

function details(id, opts)
  local gid = id
  local g = api_get(API .. "/galleries/" .. gid) or {}
  local title = pick_title(g.title)
  if title == "" then title = "Gallery " .. gid end
  local cover = thumb((g.cover and g.cover.path) or (g.thumbnail and g.thumbnail.path) or "")
  local artists = tags_of_type(g.tags, "artist")
  local groups = tags_of_type(g.tags, "group")
  local genres = tags_of_type(g.tags, "tag")
  for _, c in ipairs(tags_of_type(g.tags, "category")) do genres[#genres + 1] = c end

  local desc_parts = {}
  if g.num_pages then desc_parts[#desc_parts + 1] = tostring(g.num_pages) .. " pages" end
  if #artists > 0 then desc_parts[#desc_parts + 1] = "Artists: " .. table.concat(artists, ", ") end
  if #groups > 0 then desc_parts[#desc_parts + 1] = "Groups: " .. table.concat(groups, ", ") end

  local date = g.upload_date and util.date_parse(tostring(g.upload_date)) or nil
  local chapters = {
    { id = gid, name = "Gallery", number = 1, url = SITE .. "/g/" .. gid .. "/", date = date },
  }
  return {
    title = title,
    cover = cover,
    author = artists[1] or groups[1] or "Unknown",
    status = "Completed",
    genres = genres,
    description = table.concat(desc_parts, "\n"),
    url = SITE .. "/g/" .. gid .. "/",
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local gid = chapter_id
  local g = api_get(API .. "/galleries/" .. gid) or {}
  local list = {}
  for _, p in ipairs(g.pages or {}) do list[#list + 1] = p end
  table.sort(list, function(a, b) return (a.number or 0) < (b.number or 0) end)
  local urls = {}
  for _, p in ipairs(list) do
    local u = img(p.path)
    if u ~= "" then urls[#urls + 1] = u end
  end
  return { pages = urls, referer = SITE .. "/" }
end

function url_for(id)
  return SITE .. "/g/" .. id .. "/"
end
