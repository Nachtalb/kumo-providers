-- @id dynasty
-- @name Dynasty Scans
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 3/1s
-- @ua chrome
-- @base https://dynasty-scans.com
--
-- HTML scrape. Ported from server/providers/dynasty.js.
--   listing/search : /search?q=&classes[]=Series&sort=&page=N  (a[href^="/series/"])
--   details        : /series/<slug>   (h2.tag-title, img.thumbnail, a.name[href^="/chapters/"])
--   pages          : /chapters/<cslug>  (embedded `var pages = [{"image":..}]`)
--
-- Site quirk: covers live ONLY on the series page (img.thumbnail, lazy-loaded
-- with data-src before src), so the listing enriches each item by fetching its
-- series page. Chapters render OLDEST-first; we reverse to newest-first.
-- Local ids: manga id = "<slug>", chapter id = "<cslug>".

local BASE = "https://dynasty-scans.com"

local function parse_status(t)
  local s = (t or ""):lower()
  if s:find("ongoing") then return "Ongoing"
  elseif s:find("completed") then return "Completed"
  elseif s:find("hiatus") then return "Hiatus"
  end
  return "Unknown"
end

-- Series {slug,title} from a search/listing page.
local function parse_series_list(doc)
  local out, seen = {}, {}
  for _, a in ipairs(doc:select('a[href^="/series/"]')) do
    local href = a:attr("href") or ""
    local slug = href:match("^/series/([^/?#]+)")
    if slug and not seen[slug] then
      local title = util.trim((a:text() or ""):gsub("^#", ""))
      if title ~= "" then
        seen[slug] = true
        out[#out + 1] = { slug = slug, title = title }
      end
    end
  end
  return out
end

-- Covers are lazy (data-src before src).
local function cover_of(doc)
  local img = doc:first("img.thumbnail")
  if not img then img = doc:first(".tags img") end
  if not img then return "" end
  return util.abs_url(img:attr("data-src") or img:attr("src") or "")
end

local function cover_for(slug)
  local r = http.get(BASE .. "/series/" .. slug, { referer = BASE .. "/" })
  return cover_of(html.parse(r.body))
end

local function to_items(series)
  local items = {}
  for _, s in ipairs(series) do
    items[#items + 1] = {
      id = s.slug,
      title = s.title,
      cover = cover_for(s.slug),
    }
  end
  return items
end

local function browse(query, page)
  local q = (query or ""):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end)
  local url = BASE .. "/search?q=" .. q .. "&classes%5B%5D=Series&sort=&page=" .. (page or 1)
  local r = http.get(url, { referer = BASE .. "/" })
  local doc = html.parse(r.body)
  local series = parse_series_list(doc)
  -- next control is an <a rel="next"> present on every page but the last
  local has_next = doc:first('.pagination a[rel="next"]') ~= nil
  return { items = to_items(series), has_next = has_next }
end

function popular(page, opts)
  return browse("", page)
end

function latest(page, opts)
  return browse("", page)
end

function search(query, page, filters, opts)
  return browse(query or "", page)
end

function details(id, opts)
  local url = BASE .. "/series/" .. id
  local r = http.get(url, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local head = doc:first("h2.tag-title")
  local title = id
  if head then
    local b = head:first("b")
    title = util.trim((b and b:text()) or head:text() or id)
  end

  local author = "Unknown"
  if head then
    local authors = {}
    for _, a in ipairs(head:select('a[href^="/authors/"]')) do
      authors[#authors + 1] = util.trim(a:text())
    end
    if #authors > 0 then author = table.concat(authors, ", ") end
  end

  local status = "Unknown"
  if head then
    local sm = head:first("small")
    if sm then status = parse_status(sm:text()) end
  end

  local cover = cover_of(doc)

  local genres, seen_g = {}, {}
  for _, a in ipairs(doc:select(".tags a.label, .tag-tags a.label")) do
    local t = util.trim(a:text())
    if t ~= "" and not seen_g[t] then seen_g[t] = true; genres[#genres + 1] = t end
  end

  local description = ""
  local de = doc:first(".description")
  if de then description = util.trim(de:text()) end

  -- Chapters — each <dd> row holds <a class="name" href="/chapters/<cslug>">
  -- plus a <small>released <date></small>. Site is OLDEST-first; reverse.
  local chapters, seen_c = {}, {}
  for _, row in ipairs(doc:select("dl.chapter-list dd, .chapter-list li")) do
    local a = row:first('a.name[href^="/chapters/"]')
    if a then
      local href = a:attr("href") or ""
      local cslug = href:match("^/chapters/([^/?#]+)")
      if cslug and not seen_c[cslug] then
        seen_c[cslug] = true
        local name = util.trim(a:text())
        local nummatch = name:match("[Cc]h[ap]*%.?%s*(%d+%.?%d*)") or name:match("(%d+%.?%d*)")
        local number = nummatch and tonumber(nummatch) or nil
        local date = nil
        local sm = row:first("small")
        if sm then
          local dt = util.trim((sm:text() or ""):gsub("^[Rr]eleased%s*", ""))
          if dt ~= "" then date = util.date_parse(dt) end
        end
        chapters[#chapters + 1] = {
          id = cslug,
          name = name ~= "" and name or cslug,
          number = number,
          url = BASE .. "/chapters/" .. cslug,
          date = date,
        }
      end
    end
  end
  -- reverse to newest-first
  local rev = {}
  for i = #chapters, 1, -1 do rev[#rev + 1] = chapters[i] end

  return {
    title = title,
    cover = cover,
    author = author,
    status = status,
    genres = genres,
    description = description,
    url = url,
    chapters = rev,
  }
end

function pages(chapter_id, opts)
  local r = http.get(BASE .. "/chapters/" .. chapter_id, { referer = BASE .. "/" })
  local body = r.body or ""
  local urls = {}
  -- Primary: `var pages = [{"image":"/system/releases/...","name":"001"},...]`
  local arr = body:match("var%s+pages%s*=%s*(%[.-%]);")
  if arr then
    local ok, parsed = pcall(json.parse, arr)
    if ok and parsed then
      for _, p in ipairs(parsed) do
        if p.image then urls[#urls + 1] = util.abs_url(p.image) end
      end
    end
  end
  if #urls == 0 then
    local doc = html.parse(body)
    for _, img in ipairs(doc:select(".image-container img, #image img, .page img")) do
      local s = img:attr("src") or img:attr("data-src") or ""
      if s ~= "" then urls[#urls + 1] = util.abs_url(s) end
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/series/" .. id
end

function filters()
  return {}
end
