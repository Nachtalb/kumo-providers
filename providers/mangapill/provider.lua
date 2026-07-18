-- @id mangapill
-- @name Mangapill
-- @version 1.1.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua chrome
-- @base https://mangapill.com
--
-- Pure server-rendered HTML scrape. Ported from server/providers/mangapill.js
-- (itself from keiyoushi src/en/mangapill). Demonstrates the HTML pattern:
--   list/search: /search?q=&type=&status=&page=N   (a[href^="/manga/"] cards)
--   details:     /manga/<id>/<slug>                 (a[href^="/chapters/"])
--   pages:       /chapters/<...>                     (img[data-src])
--
-- Local-id discipline: manga id = "<num>/<slug>", chapter id = "ch/<cslug>".
-- The host namespaces "mangapill:" around every call.

local BASE = "https://mangapill.com"

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Filter surface (ported from server/providers/mangapill.js).
local SORTS = { { key = "", label = "Default" } }
local STATUSES = {
  { key = "", label = "All" },
  { key = "publishing", label = "Publishing" },
  { key = "finished", label = "Finished" },
  { key = "on hiatus", label = "On hiatus" },
  { key = "discontinued", label = "Discontinued" },
}
local GENRES = {
  "action", "adventure", "cars", "comedy", "dementia", "demons", "drama",
  "ecchi", "fantasy", "game", "gender-bender", "harem", "historical", "horror",
  "isekai", "josei", "kids", "magic", "martial-arts", "mecha", "military",
  "music", "mystery", "parody", "police", "psychological", "romance", "samurai",
  "school", "sci-fi", "seinen", "shoujo", "shounen", "slice-of-life", "space",
  "sports", "super-power", "supernatural", "thriller", "tragedy", "vampire",
  "yaoi", "yuri",
}
-- a handful of mangapill genres carry a hyphen / special-case in the on-site name
local GENRE_NAME = {
  ["sci-fi"] = "Sci-Fi", ["super-power"] = "Super Power",
  ["gender-bender"] = "Gender Bender", ["martial-arts"] = "Martial Arts",
  ["slice-of-life"] = "Slice of Life",
}
-- toGenre(g): map slug -> the site's display name (Title-Case each hyphen part).
local function to_genre(g)
  if GENRE_NAME[g] then return GENRE_NAME[g] end
  local parts = {}
  for p in tostring(g):gmatch("[^%-]+") do
    parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2)
  end
  return table.concat(parts, " ")
end

function meta()
  return { sorts = SORTS, statuses = STATUSES, genres = GENRES, genreMode = "multi", multiChapter = true }
end

-- mangapill's cards duplicate the title in the img alt ("Chainsaw Man Chainsaw
-- Man"); collapse an exact "X X" into "X".
local function dedupe_alt(alt)
  local t = util.trim(alt or "")
  local half = util.trim(t:sub(1, math.floor(#t / 2)))
  if half ~= "" and t == (half .. " " .. half) then return half end
  return t
end

local function cover_of(node)
  local img = node:first("img")
  if not img then return "" end
  local c = img:attr("data-src") or img:attr("data-lazy-src") or img:attr("src") or ""
  return util.abs_url(c)
end

-- Parse the search/list grid: each card is an a[href^="/manga/<num>/<slug>"].
local function parse_list(doc)
  local items, seen = {}, {}
  for _, a in ipairs(doc:select('a[href^="/manga/"]')) do
    local href = a:attr("href") or ""
    local num, slug = href:match("^/manga/(%d+)/([^/?#]+)")
    if num and not seen[num .. "/" .. slug] then
      local id = num .. "/" .. slug
      local title = ""
      local t = a:first(".line-clamp-2, div.font-bold")
      if t then title = util.trim(t:text()) end
      if title == "" then
        local img = a:first("img")
        if img then title = dedupe_alt(img:attr("alt") or "") end
      end
      if title ~= "" then
        seen[id] = true
        items[#items + 1] = { id = id, title = title, cover = cover_of(a) }
      end
    end
  end
  return items
end

local function list_page(query, page, status, genres)
  local q = "q=" .. urlencode(query or "")
    .. "&type="
    .. "&status=" .. urlencode(status or "")
    .. "&page=" .. page
  -- tri-state genres: append &genre=<toGenre(g)> for each INCLUDED (mode==1).
  for g, mode in pairs(genres or {}) do
    if mode == 1 then q = q .. "&genre=" .. urlencode(to_genre(g)) end
  end
  local r = http.get(BASE .. "/search?" .. q, { referer = BASE .. "/" })
  local items = parse_list(html.parse(r.body))
  return { items = items, has_next = #items > 0 }
end

function popular(page, opts)
  return list_page("", page, "", nil)
end

function latest(page, opts)
  return list_page("", page, "", nil)
end

function search(query, page, filters, opts)
  filters = filters or {}
  return list_page(query or "", page, filters.status or "", filters.genres)
end

function details(id, opts)
  local r = http.get(BASE .. "/manga/" .. id, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = util.trim(h1:text()) end

  local cover = ""
  local ci = doc:first('img[data-src*="/i/"]')
  if not ci then ci = doc:first("img") end
  if ci then cover = util.abs_url(ci:attr("data-src") or ci:attr("src") or "") end

  local description = ""
  local de = doc:first("p.text-sm")
  if de then description = util.trim(de:text()) end

  local genres = {}
  for _, g in ipairs(doc:select('a[href*="genre="]')) do
    local t = util.trim(g:text())
    if t ~= "" then genres[#genres + 1] = t end
  end

  -- status label sits in a small label/div under a "Status" heading
  local status = ""
  for _, el in ipairs(doc:select("label, div")) do
    local t = util.trim(el:text()):lower()
    if t == "publishing" then status = "Ongoing"; break
    elseif t == "finished" then status = "Completed"; break end
  end

  local chapters = {}
  for _, a in ipairs(doc:select('a[href^="/chapters/"]')) do
    local href = a:attr("href") or ""
    local cslug = href:gsub("^/chapters/", ""):gsub("[?#].*$", "")
    if cslug ~= "" then
      local label = util.trim(a:text())
      local num = label:match("([0-9]+%.?[0-9]*)")
      chapters[#chapters + 1] = {
        id = "ch/" .. cslug,
        name = label ~= "" and label or "Chapter",
        number = num and tonumber(num) or nil,
        url = BASE .. href,
        date = nil,
      }
    end
  end

  return {
    title = title,
    cover = cover,
    author = "Unknown",
    status = status,
    genres = genres,
    description = description,
    url = BASE .. "/manga/" .. id,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local cslug = chapter_id:gsub("^ch/", "")
  local r = http.get(BASE .. "/chapters/" .. cslug, { referer = BASE .. "/" })
  local doc = html.parse(r.body)
  local urls, seen = {}, {}
  for _, img in ipairs(doc:select("img[data-src], picture img")) do
    local src = img:attr("data-src") or img:attr("src") or ""
    if src ~= "" then
      src = util.abs_url(src)
      if (src:match("/file/mangapill/") or src:match("%.jpe?g")
        or src:match("%.png") or src:match("%.webp")) and not seen[src] then
        seen[src] = true
        urls[#urls + 1] = src
      end
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/manga/" .. id
end
