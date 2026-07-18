-- @id mangageko
-- @name MangaGeko
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 3/1s
-- @ua chrome
-- @base https://www.mgeko.cc
--
-- HTML scrape with a JSON-wrapped listing. Ported from server/providers/
-- mangageko.js (keiyoushi en/mangarawclub -> mgeko.cc).
--   listing : GET /browse-comics/data/?page=N&sort=<s>&safe_mode=0
--             -> JSON { results_html, num_pages, page } ; results_html has .comic-card
--   search  : GET /search/?search=<q>&results=<page>   -> .novel-item
--   detail  : GET /manga/<slug>/                        -> .novel-header
--   chapters: GET /manga/<slug>/all-chapters/           -> ul.chapter-list li
--   pages   : GET /reader/en/<readerSlug>/              -> #chapter-reader img
-- Chapter links point at an opaque reader slug; we carry it in the chapter id so
-- pages() rebuilds /reader/en/<readerSlug>/.
--
-- Local ids: manga id = "<slug>", chapter id = "<slug>/<readerSlug>". Covers are
-- lazy (data-src before src). The host namespaces "mangageko:" around each call.

local BASE = "https://www.mgeko.cc"

local function slug_from(href)
  return (href or ""):match("/manga/([^/?#]+)")
end

local function cover_of(img)
  if not img then return "" end
  return util.abs_url(img:attr("data-src") or img:attr("src") or "")
end

local function parse_comic_cards(doc)
  local out, seen = {}, {}
  for _, el in ipairs(doc:select(".comic-card")) do
    local a = el:first(".comic-card__title a")
    if not a then a = el:first(".comic-card__cover a") end
    local slug = a and slug_from(a:attr("href")) or nil
    if slug and not seen[slug] then
      local tnode = el:first(".comic-card__title a")
      local title = tnode and util.trim(tnode:text()) or ""
      if title ~= "" then
        seen[slug] = true
        local img = el:first(".comic-card__cover img")
        if not img then img = el:first("img") end
        out[#out + 1] = { id = slug, title = title, cover = cover_of(img) }
      end
    end
  end
  return out
end

local function browse(page, sort)
  local url = BASE .. "/browse-comics/data/?page=" .. (page or 1)
    .. "&sort=" .. (sort or "popular_all_time") .. "&safe_mode=0"
  local r = http.get(url, { referer = BASE .. "/browse-comics/" })
  local ok, data = pcall(json.parse, r.body)
  if not ok or not data then data = {} end
  local doc = html.parse(data.results_html or "")
  local items = parse_comic_cards(doc)
  local has_next
  if data.num_pages ~= nil then
    has_next = (data.page or page or 1) < data.num_pages
  else
    has_next = #items >= 12
  end
  return { items = items, has_next = has_next }
end

function popular(page, opts)
  return browse(page, "popular_all_time")
end

function latest(page, opts)
  return browse(page, "latest")
end

function search(query, page, filters, opts)
  if query and query ~= "" then
    local q = query:gsub("[^%w%-%.%_%~]", function(c)
      return string.format("%%%02X", c:byte())
    end)
    local r = http.get(BASE .. "/search/?search=" .. q .. "&results=" .. (page or 1),
      { referer = BASE .. "/" })
    local doc = html.parse(r.body)
    local out, seen = {}, {}
    for _, el in ipairs(doc:select(".novel-item")) do
      local a = el:first("a")
      local slug = a and slug_from(a:attr("href")) or nil
      if slug and not seen[slug] then
        local tnode = el:first(".novel-title")
        local title = tnode and util.trim(tnode:text()) or ""
        if title ~= "" then
          seen[slug] = true
          local img = el:first(".novel-cover img")
          if not img then img = el:first("img") end
          out[#out + 1] = { id = slug, title = title, cover = cover_of(img) }
        end
      end
    end
    local has_next = doc:first('nav.paging a:contains("Next")') ~= nil
    return { items = out, has_next = has_next }
  end
  return browse(page, "popular_all_time")
end

function details(id, opts)
  local slug = id
  local url = BASE .. "/manga/" .. slug .. "/"
  local r = http.get(url, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = ""
  local tnode = doc:first(".novel-title")
  if tnode then title = util.trim(tnode:text()) end
  if title == "" then title = (slug:gsub("%-", " ")) end

  local img = doc:first(".cover img")
  local cover = cover_of(img)

  local author = "Unknown"
  local anode = doc:first(".author a")
  if anode then
    author = util.trim(anode:attr("title") or anode:text() or "Unknown")
    if author == "" then author = "Unknown" end
  end

  local genres = {}
  for _, e in ipairs(doc:select('.categories a[href*="genre"]')) do
    local t = util.trim(e:text())
    if t ~= "" then genres[#genres + 1] = t end
  end

  local status = "Unknown"
  if doc:first("div.header-stats strong.completed") then status = "Completed"
  elseif doc:first("div.header-stats strong.ongoing") then status = "Ongoing"
  end

  local description = ""
  local de = doc:first(".description")
  if de then
    description = util.trim(de:text())
    description = util.trim((description:gsub("^.-Summary is%s*", "")))
    if description == "" and de then description = util.trim(de:text()) end
  end

  -- chapters live on the separate all-chapters page
  local chapters, seen = {}, {}
  local cr = http.get(url .. "all-chapters/", { referer = url })
  local cdoc = html.parse(cr.body)
  for _, li in ipairs(cdoc:select("ul.chapter-list > li")) do
    local a = li:first("a")
    local href = a and a:attr("href") or ""
    local reader_slug = href:match("/reader/[^/]+/([^/?#]+)")
    if reader_slug and not seen[reader_slug] then
      seen[reader_slug] = true
      local raw_no = util.trim(li:attr("data-chapterno") or "")
      local tel = li:first(".chapter-title")
      if not tel then tel = li:first(".chapter-number") end
      local ch_title = tel and util.trim((tel:text() or ""):gsub("%-eng%-li", "")) or ""
      local num = nil
      if raw_no ~= "" and tonumber(raw_no) then
        num = tonumber(raw_no)
      else
        local m = ch_title:match("([0-9]+%.?[0-9]*)")
        if m then num = tonumber(m) end
      end
      local date = nil
      local upd = li:first(".chapter-update")
      if upd then
        local dt = upd:attr("datetime") or upd:text() or ""
        if dt ~= "" then date = util.date_parse(util.trim(dt)) end
      end
      chapters[#chapters + 1] = {
        id = slug .. "/" .. reader_slug,
        name = ch_title ~= "" and ("Chapter " .. ch_title)
          or ("Chapter " .. (num ~= nil and tostring(num) or "?")),
        number = num,
        url = util.abs_url(href),
        date = date,
      }
    end
  end
  table.sort(chapters, function(x, y) return (x.number or 0) > (y.number or 0) end)

  return {
    title = title,
    cover = cover,
    author = author,
    status = status,
    genres = genres,
    description = description,
    url = url,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  -- id: <slug>/<readerSlug>  ->  /reader/en/<readerSlug>/
  local reader_slug = chapter_id:sub(chapter_id:find("/") + 1)
  local r = http.get(BASE .. "/reader/en/" .. reader_slug .. "/", { referer = BASE .. "/" })
  local doc = html.parse(r.body)
  local urls = {}
  for _, el in ipairs(doc:select("#chapter-reader img")) do
    local s = util.trim(el:attr("src") or el:attr("data-src") or "")
    if s ~= "" then urls[#urls + 1] = util.abs_url(s) end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/manga/" .. id .. "/"
end

function filters()
  return {}
end
