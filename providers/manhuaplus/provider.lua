-- @id manhuaplus
-- @name Manhua Plus
-- @version 1.1.0
-- @langs en
-- @nsfw false
-- @rate 3/1s
-- @ua chrome
-- @base https://manhuaplus.top
--
-- Astro rewrite of the old .com Madara site. Server-rendered HTML for listing/
-- detail/chapters + a JSON ajax endpoint for page images. Ported from
-- server/providers/manhuaplus.js.
--   listing : GET /all-manga/<page>/?sort=views          cards a[href*=/manga/]
--   search  : GET /?q=<query>                            (same card shape)
--   detail  : GET /manga/<slug>                          a[href*=/chapter-]
--   pages   : GET /manga/<slug>/<cslug>  -> CHAPTER_ID in a JS var, then
--             GET /ajax/image/list/chap/<id>?mode=vertical&quality=high -> {html}
-- Local-id discipline: script uses <slug> and <slug>/<cslug>; host namespaces.

local BASE = "https://manhuaplus.top"

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Filter surface (ported from server/providers/manhuaplus.js module.exports).
-- ?sort= values verified live on /all-manga.
local SORTS = {
  { key = "views", label = "Popularity" },
  { key = "latest-updated", label = "Latest" },
  { key = "views_day", label = "Popular (day)" },
  { key = "views_week", label = "Popular (week)" },
  { key = "views_month", label = "Popular (month)" },
  { key = "score", label = "Rating" },
  { key = "bookmarks", label = "Bookmarks" },
  { key = "release-date", label = "Recently added" },
}
local STATUSES = {
  { key = "all", label = "All" },
  { key = "on-going", label = "Ongoing" },
  { key = "completed", label = "Completed" },
  { key = "on-hold", label = "On Hold" },
  { key = "canceled", label = "Cancelled" },
}
-- Site status codes for the /filter route (empty = all). /genres/<slug> ignores
-- status, so status filtering always routes through /filter.
local STATUS_CODE = {
  ["all"] = "", ["on-going"] = "on-going", ["completed"] = "completed",
  ["on-hold"] = "on-hold", ["canceled"] = "canceled",
}
local GENRES = {
  "action", "adaptation", "adult", "adventure", "comedy", "cooking",
  "crime", "drama", "ecchi", "fantasy", "fighting", "harem", "historical",
  "horror", "isekai", "martial-arts", "mature", "mystery", "romance",
  "school-life", "sci-fi", "seinen", "shounen", "slice-of-life", "supernatural",
}
local function is_sort(k)
  for _, s in ipairs(SORTS) do if s.key == k then return true end end
  return false
end

function meta()
  return {
    sorts = SORTS,
    statuses = STATUSES,
    genres = GENRES,
    genreMode = "single",
    multiChapter = true,
  }
end

local function slug_from(href)
  return (href or ""):match("/manga/([^/?#]+)")
end

-- Cards: <a href="/manga/slug"> wrapping the cover <img>. Skip chapter links.
local function parse_cards(doc)
  local out, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/manga/"]')) do
    local href = a:attr("href") or ""
    if not href:match("/chapter%-") then
      local slug = slug_from(href)
      local img = a:first("img")
      if slug and not seen[slug] and img then
        local cover = util.trim(img:attr("data-src") or img:attr("src") or "")
        if cover:match("^data:") then cover = util.trim(img:attr("data-src") or "") end
        local title = util.trim(a:attr("title") or img:attr("alt") or "")
        if cover ~= "" and title ~= "" and not title:lower():match("^manhua ?plus$") then
          seen[slug] = true
          out[#out + 1] = { id = slug, title = title, cover = util.abs_url(cover) }
        end
      end
    end
  end
  return out
end

-- Listing builder, mirrors the old JS listing(). One selected genre routes to
-- /genres/<slug> (the only route that filters by genre; /filter?genres= is
-- ignored by the site). A status filter with no genre routes to /filter (the
-- only route that honours status). Neither -> /all-manga.
local function listing(page, sort, status, genres)
  page = page or 1
  local key = is_sort(sort) and sort or "views"
  local status_code = STATUS_CODE[status]
  if status_code == nil then status_code = "" end
  local gslug = nil
  if genres then
    for g, mode in pairs(genres) do
      if mode == 1 or mode == true then gslug = g; break end
    end
  end
  local path
  if gslug then
    path = "/genres/" .. urlencode(gslug) .. "/" .. page .. "/?sort=" .. key
  elseif status_code ~= "" then
    path = "/filter/" .. page .. "/?genres=&notGenres=&sex=All&chapter_count=0&status=" .. status_code .. "&sort=" .. key
  else
    path = "/all-manga/" .. page .. "/?sort=" .. key
  end
  local r = http.get(BASE .. path, { referer = BASE .. "/" })
  local doc = html.parse(r.body or "")
  local items = parse_cards(doc)
  -- has_next: any listing/genre/filter/pagination link with a higher page number
  local has_next = false
  for _, a in ipairs(doc:select('a[href*="/all-manga/"], a[href*="/genres/"], a[href*="/filter/"], .pagination a')) do
    local href = a:attr("href") or ""
    local n = tonumber(href:match("/all%-manga/(%d+)"))
      or tonumber(href:match("/filter/(%d+)"))
      or tonumber(href:match("/genres/[^/]+/(%d+)"))
    if n and n > page then has_next = true end
  end
  return { items = items, has_next = has_next }
end

function popular(page, opts)
  local sort = (opts and is_sort(opts.sort)) and opts.sort or "views"
  return listing(page, sort)
end

function latest(page, opts)
  return listing(page, "latest-updated")
end

function search(query, page, filters, opts)
  local q = util.trim(query or "")
  if q ~= "" then
    local r = http.get(BASE .. "/?q=" .. urlencode(q), { referer = BASE .. "/" })
    local doc = html.parse(r.body or "")
    return { items = parse_cards(doc), has_next = false }
  end
  filters = filters or {}
  -- sort precedence: filters.sort, else opts.sort, else the old JS default 'views'.
  local sort = filters.sort
  if not (sort and is_sort(sort)) then sort = opts and opts.sort end
  if not (sort and is_sort(sort)) then sort = "views" end
  return listing(page, sort, filters.status, filters.genres)
end

local function parse_status(t)
  local s = (t or ""):lower()
  if s:match("complete") then return "Completed" end
  if s:match("on[%s%-]?going") or s:match("ongoing") then return "Ongoing" end
  if s:match("hiatus") then return "Hiatus" end
  if s:match("drop") or s:match("cancel") then return "Cancelled" end
  return "Unknown"
end

function details(id, opts)
  local slug = id
  local url = BASE .. "/manga/" .. slug
  local r = http.get(url, { referer = BASE .. "/" })
  local doc = html.parse(r.body or "")

  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = util.trim(h1:text()) end
  if title == "" then title = (slug:gsub("%-", " ")) end

  -- real cover lives under /uploads/covers/ (hero img is a lazy placeholder)
  local cover = ""
  for _, e in ipairs(doc:select("img")) do
    local s = util.trim(e:attr("data-src") or e:attr("src") or "")
    if s:match("/uploads/covers/") and cover == "" then cover = s end
  end

  local author = "Unknown"
  local aa = doc:first('a[href*="/authors/"], a[href*="/author/"]')
  if aa then
    local t = util.trim(aa:text())
    if t ~= "" and not t:lower():match("^updating$") then author = t end
  end

  local genres = {}
  local gseen = {}
  for _, e in ipairs(doc:select('a[href*="/genres/"]')) do
    local t = util.trim(e:text())
    if t ~= "" and not gseen[t] then gseen[t] = true; genres[#genres + 1] = t end
  end

  -- status: a node whose own text is "Status", value in the same row
  local status = "Unknown"
  local st = doc:first('span.status, .status-value, a[href*="/status/"]')
  if st then status = parse_status(st:text()) end

  local chapters, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/chapter-"]')) do
    local href = a:attr("href") or ""
    local cslug = href:match("/manga/[^/]+/(chapter%-[0-9%.]+)")
    if cslug and not seen[cslug] then
      local label = util.trim((a:text():gsub("%s+", " ")))
      if label:lower():match("chapter") then
        seen[cslug] = true
        local num = cslug:match("chapter%-([0-9%.]+)")
        chapters[#chapters + 1] = {
          id = slug .. "/" .. cslug,
          name = label:gsub("%s%s+.*$", ""),
          number = num and tonumber(num) or nil,
          url = util.abs_url(href),
          date = nil,
        }
      end
    end
  end
  -- newest-first
  table.sort(chapters, function(a, b) return (a.number or 0) > (b.number or 0) end)

  return {
    title = title,
    cover = util.abs_url(cover),
    author = author,
    status = status,
    genres = genres,
    description = "",
    url = url,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local slug, cslug = chapter_id:match("^(.-)/(chapter%-.+)$")
  if not slug then return { pages = {}, referer = BASE .. "/" } end
  -- 1) reader page resolves the numeric CHAPTER_ID
  local r = http.get(BASE .. "/manga/" .. slug .. "/" .. cslug,
    { referer = BASE .. "/manga/" .. slug })
  local body = r.body or ""
  local chap_id = body:match('CHAPTER_ID%s*=%s*["\']?(%d+)') or body:match('chapterId%s*=%s*["\']?(%d+)')
  local urls = {}
  if chap_id then
    -- 2) ajax image list -> JSON { html } with the page <img>s
    local ar = http.get(BASE .. "/ajax/image/list/chap/" .. chap_id .. "?mode=vertical&quality=high",
      { referer = BASE .. "/manga/" .. slug .. "/" .. cslug,
        headers = { ["X-Requested-With"] = "XMLHttpRequest" } })
    local ok, j = pcall(json.parse, ar.body or "{}")
    if ok and j and j.html then
      local jd = html.parse(j.html)
      for _, e in ipairs(jd:select("img")) do
        local s = util.trim(e:attr("data-src") or e:attr("data-original") or e:attr("src") or "")
        if s ~= "" and not s:lower():match("logo") then urls[#urls + 1] = util.abs_url(s) end
      end
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/manga/" .. id
end
