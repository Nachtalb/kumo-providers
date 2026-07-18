-- @id mangakakalot
-- @name Mangakakalot
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua chrome
-- @base https://www.mangakakalove.com
--
-- Ported from server/providers/mangakakalot.js (keiyoushi mangabox theme).
-- The .gg primary Cloudflare-challenges server clients, so the ported adapter
-- targets the mangakakalove.com mirror the extension lists — same HTML + same
-- /api/manga/<slug>/chapters JSON API.
--   list/search: /manga-list/*  ,  /search/story/<norm>   (cards)
--   details:     /manga/<slug>                            (info block)
--   chapters:    /api/manga/<slug>/chapters?limit=-1       (JSON)
--   pages:       /manga/<slug>/<cslug>                     (img in reader)
--
-- Local-id discipline: manga id = "<slug>", chapter id = "<slug>/<cslug>".

local BASE = "https://www.mangakakalove.com"
local ITEM_SEL = "div.list-truyen-item-wrap, div.list-comic-item-wrap, .panel_story_list .story_item"

local function slug_from(href)
  return (href or ""):match("/manga/([^/?#]+)")
end

local function fix_proto(u)
  u = util.trim(u or "")
  if u:sub(1, 2) == "//" then return "https:" .. u end
  return u
end

local function parse_status(t)
  local s = (t or ""):lower()
  if s:find("ongoing") then return "Ongoing" end
  if s:find("completed") then return "Completed" end
  return "Unknown"
end

local function manga_from(el)
  local a = el:first("h3 a, h3.comic-title a, .comic-title a, a.tooltip")
  if not a then a = el:first('a[href*="/manga/"]') end
  if not a then return nil end
  local slug = slug_from(a:attr("href"))
  local title = util.trim(a:attr("title") or a:text() or "")
  if not slug or title == "" then return nil end
  local cover = ""
  local img = el:first("img")
  if img then cover = fix_proto(img:attr("src") or img:attr("data-src") or "") end
  return { id = slug, title = title, cover = util.abs_url(cover) }
end

local function parse_list(doc)
  local items, seen = {}, {}
  for _, el in ipairs(doc:select(ITEM_SEL)) do
    local m = manga_from(el)
    if m and not seen[m.id] then
      seen[m.id] = true
      items[#items + 1] = m
    end
  end
  return items
end

function popular(page, opts)
  local r = http.get(BASE .. "/manga-list/hot-manga?page=" .. page, { referer = BASE .. "/" })
  return { items = parse_list(html.parse(r.body)), has_next = true }
end

function latest(page, opts)
  local r = http.get(BASE .. "/manga-list/latest-manga?page=" .. page, { referer = BASE .. "/" })
  return { items = parse_list(html.parse(r.body)), has_next = true }
end

function search(query, page, filters, opts)
  local q = util.trim(query or "")
  local path
  if q ~= "" then
    local norm = q:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    path = "/search/story/" .. norm .. "?page=" .. page
  else
    path = "/manga-list/latest-manga?page=" .. page
  end
  local r = http.get(BASE .. path, { referer = BASE .. "/" })
  return { items = parse_list(html.parse(r.body)), has_next = true }
end

-- The mangabox info block labels rows with a leading "Author(s) :" / "Status :"
-- / "Genres :"; scraper has no :contains, so iterate li rows and switch on text.
local function scan_info(doc)
  local author, status, genres = "Unknown", "Unknown", {}
  local info = doc:first("div.manga-info-top, div.panel-story-info")
  if not info then return author, status, genres end
  for _, li in ipairs(info:select("li")) do
    local low = util.trim(li:text()):lower()
    if low:find("author") then
      local names = {}
      for _, a in ipairs(li:select("a")) do
        local t = util.trim(a:text())
        if t ~= "" then names[#names + 1] = t end
      end
      if #names > 0 then author = table.concat(names, ", ") end
    elseif low:find("status") then
      status = parse_status(low)
    elseif low:find("genre") then
      for _, a in ipairs(li:select("a")) do
        local t = util.trim(a:text())
        if t ~= "" then genres[#genres + 1] = t end
      end
    end
  end
  return author, status, genres
end

function details(id, opts)
  local slug = id
  local r = http.get(BASE .. "/manga/" .. slug, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local info = doc:first("div.manga-info-top, div.panel-story-info")
  local title = slug
  if info then
    local h = info:first("h1, h2")
    if h then
      local t = util.trim(h:text())
      if t ~= "" then title = t end
    end
  end

  local cover = ""
  local ci = doc:first("div.manga-info-pic img, span.info-image img")
  if ci then cover = fix_proto(ci:attr("src") or "") end

  local author, status, genres = scan_info(doc)

  local description = ""
  local de = doc:first("div#noidungm, div#panel-story-info-description, div#contentBox")
  if de then
    description = util.trim(de:text())
    description = description:gsub("^" .. title:gsub("[%p%s]", "%%%0") .. "%s*summary:%s*", "")
  end

  -- chapters via the JSON API
  local chapters = {}
  local cr = http.get(BASE .. "/api/manga/" .. slug .. "/chapters?limit=-1", { referer = BASE .. "/" })
  local ok, api = pcall(json.parse, cr.body or "{}")
  if ok and api and api.success and api.data and api.data.chapters then
    for _, c in ipairs(api.data.chapters) do
      local cslug = c.chapter_slug
      if cslug then
        chapters[#chapters + 1] = {
          id = slug .. "/" .. cslug,
          name = c.chapter_name and c.chapter_name ~= "" and c.chapter_name
            or ("Chapter " .. tostring(c.chapter_num)),
          number = c.chapter_num and tonumber(c.chapter_num) or nil,
          url = BASE .. "/manga/" .. slug .. "/" .. cslug,
          date = c.updated_at and util.date_parse(c.updated_at) or nil,
        }
      end
    end
  end

  return {
    title = title,
    cover = util.abs_url(cover),
    author = author,
    status = status,
    genres = genres,
    description = description,
    url = BASE .. "/manga/" .. slug,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local slug = chapter_id:match("^([^/]+)/")
  local cslug = chapter_id:match("/(.+)$")
  local r = http.get(BASE .. "/manga/" .. slug .. "/" .. cslug, { referer = BASE .. "/" })
  local doc = html.parse(r.body)
  local urls = {}
  for _, img in ipairs(doc:select("div.container-chapter-reader img")) do
    local s = fix_proto(img:attr("src") or img:attr("data-src") or "")
    if s ~= "" then urls[#urls + 1] = util.abs_url(s) end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/manga/" .. id
end

function filters()
  return {}
end
