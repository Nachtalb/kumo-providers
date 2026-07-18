-- @id mangadex
-- @name MangaDex
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua simple
-- @base https://mangadex.org
--
-- JSON-API provider (no scraping). Ported from server/providers/mangadex.js
-- (itself from keiyoushi src/all/mangadex). Demonstrates the pure-API pattern:
--   list/search -> GET /manga            (cover from includes[]=cover_art rels)
--   details     -> GET /manga/<uuid>     + paginated GET /manga/<uuid>/feed
--   pages       -> GET /at-home/server/<chapterId>  (baseUrl + hash + data[])
--
-- The @ua simple class is REQUIRED: the MangaDex WAF 400s on browser UAs.
-- Local-id discipline: this script never sees or writes "mangadex:" ids; the
-- host namespaces around every call.

local API = "https://api.mangadex.org"
local COVERS = "https://uploads.mangadex.org/covers"
local SITE = "https://mangadex.org"
local PER = 24

local function urlencode(s)
  return (s:gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- first value of a map-like table (title fallbacks); order is undefined but the
-- English/romaji picks run first so this is only a last resort.
local function first_val(t)
  for _, v in pairs(t or {}) do return v end
  return nil
end

-- Title preference: English, then Japanese romaji, then the primary title,
-- then any alt. (User pref: English default, romaji secondary.)
local function pick_title(attr)
  attr = attr or {}
  local main = attr.title or {}
  local alts = attr.altTitles or {}
  local function pick(lang)
    if main[lang] then return main[lang] end
    for _, a in ipairs(alts) do
      if a[lang] then return a[lang] end
    end
    return nil
  end
  return pick("en") or pick("ja-ro") or first_val(main) or "Untitled"
end

-- Cover from the cover_art relationship (present only with includes[]=cover_art).
local function cover_url(m)
  for _, rel in ipairs(m.relationships or {}) do
    if rel.type == "cover_art" and rel.attributes and rel.attributes.fileName then
      return COVERS .. "/" .. m.id .. "/" .. rel.attributes.fileName .. ".512.jpg"
    end
  end
  return ""
end

local function api_get(url)
  local r = http.get(url, { headers = { Accept = "application/json" } })
  local j = json.parse(r.body)
  if not j or j.result == "error" then
    error("mangadex: api error")
  end
  return j
end

local function parse_list(url)
  local j = api_get(url)
  local items = {}
  for _, m in ipairs(j.data or {}) do
    items[#items + 1] = {
      id = m.id,
      title = pick_title(m.attributes),
      cover = cover_url(m),
    }
  end
  local off = j.offset or 0
  local lim = j.limit or 0
  local total = j.total or 0
  return { items = items, has_next = (off + lim) < total }
end

-- NSFW gate = content RATING, not tags. Show safe+suggestive by default; the
-- nsfw switch (deferred to settings()) would add erotica+pornographic.
local RATINGS = "&contentRating[]=safe&contentRating[]=suggestive"

-- "Has available chapters" gate. hasAvailableChapters=true ALONE is not enough:
-- MangaDex counts EXTERNAL/linked chapters (hosted off-site, e.g. Solo Leveling's
-- official localisations) as "available", so licensed/external-only titles still
-- pass and then show ZERO readable chapters in details (the "empty mangas" bug).
-- hasUnavailableChapters=false is what drops titles whose only chapters are
-- external/DMCA'd. BOTH are required to match Mihon's behaviour (regression fix,
-- ported from server/providers/mangadex.js commit 7ccddc5).
local HAS_CH = "&hasAvailableChapters=true&hasUnavailableChapters=false"

local function list_url(order, page)
  return API .. "/manga?limit=" .. PER
    .. "&offset=" .. ((page - 1) * PER)
    .. "&includes[]=cover_art"
    .. RATINGS
    .. HAS_CH
    .. "&order[" .. order .. "]=desc"
end

function popular(page, opts)
  return parse_list(list_url("followedCount", page))
end

function latest(page, opts)
  return parse_list(list_url("latestUploadedChapter", page))
end

function search(query, page, filters, opts)
  local url = API .. "/manga?limit=" .. PER
    .. "&offset=" .. ((page - 1) * PER)
    .. "&includes[]=cover_art" .. RATINGS .. HAS_CH
  if query and query ~= "" then
    url = url .. "&title=" .. urlencode(query) .. "&order[relevance]=desc"
  else
    url = url .. "&order[followedCount]=desc"
  end
  return parse_list(url)
end

function details(id, opts)
  local j = api_get(API .. "/manga/" .. id
    .. "?includes[]=cover_art&includes[]=author&includes[]=artist")
  local m = j.data
  local a = m.attributes or {}

  local authors = {}
  for _, rel in ipairs(m.relationships or {}) do
    if (rel.type == "author" or rel.type == "artist")
      and rel.attributes and rel.attributes.name then
      authors[#authors + 1] = rel.attributes.name
    end
  end

  local genres = {}
  for _, t in ipairs(a.tags or {}) do
    local n = t.attributes and t.attributes.name and t.attributes.name.en
    if n then genres[#genres + 1] = n end
  end

  local desc = ""
  if a.description then desc = a.description.en or first_val(a.description) or "" end

  -- Chapters via the feed (paginate, English, newest-first). Request ALL four
  -- content ratings on the feed itself: omitting them DEFAULTS to excluding
  -- pornographic, which silently hides every chapter of a pornographic title.
  local chapters = {}
  local offset = 0
  local limit = 100
  for _ = 1, 20 do
    local furl = API .. "/manga/" .. id .. "/feed?limit=" .. limit
      .. "&offset=" .. offset
      .. "&translatedLanguage[]=en&order[chapter]=desc"
      .. "&contentRating[]=safe&contentRating[]=suggestive"
      .. "&contentRating[]=erotica&contentRating[]=pornographic"
      .. "&includes[]=scanlation_group"
    local fj = api_get(furl)
    for _, c in ipairs(fj.data or {}) do
      local ca = c.attributes or {}
      if not ca.externalUrl then           -- off-site chapters have no readable pages
        local num = ca.chapter
        local grp = nil
        for _, rel in ipairs(c.relationships or {}) do
          if rel.type == "scanlation_group" and rel.attributes then
            grp = rel.attributes.name
          end
        end
        local name
        if num and num ~= "" then name = "Chapter " .. num else name = ca.title or "Oneshot" end
        if ca.title and ca.title ~= "" and num and num ~= "" then
          name = name .. " - " .. ca.title
        end
        if grp then name = name .. "  \u{00b7} " .. grp end
        chapters[#chapters + 1] = {
          id = c.id,
          name = name,
          number = num and tonumber(num) or nil,
          url = SITE .. "/chapter/" .. c.id,
          date = ca.publishAt and util.date_parse(ca.publishAt) or nil,
        }
      end
    end
    offset = offset + limit
    if offset >= (fj.total or 0) then break end
  end

  return {
    title = pick_title(a),
    cover = cover_url(m),
    author = authors[1] or "Unknown",
    status = a.status or "",           -- host normalizes to the closed vocab
    genres = genres,
    description = desc,
    url = SITE .. "/title/" .. id,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local j = api_get(API .. "/at-home/server/" .. chapter_id)
  local base = j.baseUrl
  local hash = j.chapter and j.chapter.hash
  local data = (j.chapter and j.chapter.data) or {}
  local urls = {}
  for _, f in ipairs(data) do
    urls[#urls + 1] = base .. "/data/" .. hash .. "/" .. f
  end
  return { pages = urls, referer = SITE .. "/" }
end

function url_for(id)
  return SITE .. "/title/" .. id
end

function filters()
  -- MangaDex has a rich tag/status/sort/language filter set; the declarative
  -- schema (and the language multi-select) land with the filters()/settings()
  -- milestone of #25.
  return {}
end
