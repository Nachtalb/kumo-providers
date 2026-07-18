-- @id mangapill
-- @name Mangapill
-- @version 1.0.0
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

local function list_page(query, page, status)
  local q = "q=" .. (query or "") .. "&type=&status=" .. (status or "")
    .. "&page=" .. page
  local r = http.get(BASE .. "/search?" .. q, { referer = BASE .. "/" })
  local items = parse_list(html.parse(r.body))
  return { items = items, has_next = #items > 0 }
end

function popular(page, opts)
  return list_page("", page, "")
end

function latest(page, opts)
  return list_page("", page, "")
end

function search(query, page, filters, opts)
  return list_page(query or "", page, "")
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

function filters()
  return {}
end
