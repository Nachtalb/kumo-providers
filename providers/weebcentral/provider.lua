-- @id weebcentral
-- @name Weeb Central
-- @version 1.1.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua chrome
-- @base https://weebcentral.com
--
-- Reference provider: server-rendered HTML + htmx fragment endpoints.
-- Ported from server/providers/weebcentral.js (itself from keiyoushi).
-- Demonstrates: HX-Request fragments, label→value detail scraping, and the
-- local-id discipline — this script NEVER sees or writes "weebcentral:" ids;
-- the host namespaces around every call.

local BASE = "https://weebcentral.com"
local PER = 24

local function urlencode(s)
  return (s:gsub("[^%w%-%.%_%~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Filter surface (ported from server/providers/weebcentral.js).
local SORTS = {
  { key = "Popularity", label = "Popularity" },
  { key = "Latest Updates", label = "Latest" },
  { key = "Alphabet", label = "Title (A-Z)" },
  { key = "Best Match", label = "Best match" },
}
local STATUSES = {
  { key = "all", label = "All" },
  { key = "Ongoing", label = "Ongoing" },
  { key = "Complete", label = "Completed" },
  { key = "Hiatus", label = "Hiatus" },
  { key = "Canceled", label = "Cancelled" },
}
local GENRES = {
  "action", "adventure", "comedy", "drama", "ecchi", "fantasy", "harem",
  "horror", "isekai", "josei", "mecha", "mystery", "psychological", "romance",
  "school-life", "sci-fi", "seinen", "shoujo", "shounen", "slice-of-life",
  "sports", "supernatural", "thriller", "tragedy", "yaoi", "yuri",
}
local function is_sort(k)
  for _, s in ipairs(SORTS) do if s.key == k then return true end end
  return false
end

function meta()
  return { sorts = SORTS, statuses = STATUSES, genres = GENRES, genreMode = "multi", multiChapter = true }
end

-- /search/data returns a fragment of series cards when asked via htmx. Applies
-- sort, text, status (included_status) and tri-state genres (included_tag /
-- excluded_tag), matching the old JS listData().
local function list_data(o)
  o = o or {}
  local q = "limit=" .. PER
    .. "&offset=" .. (((o.page or 1) - 1) * PER)
    .. "&sort=" .. urlencode(o.sort or "Popularity")
    .. "&order=Descending&official=Any&display_mode=" .. urlencode("Full Display")
  if o.text and o.text ~= "" then q = q .. "&text=" .. urlencode(o.text) end
  if o.status and o.status ~= "" and o.status ~= "all" then
    q = q .. "&included_status=" .. urlencode(o.status)
  end
  for g, mode in pairs(o.genres or {}) do
    local name = (g:gsub("%-", " "))
    if mode == 1 then q = q .. "&included_tag=" .. urlencode(name)
    elseif mode == -1 then q = q .. "&excluded_tag=" .. urlencode(name) end
  end
  local r = http.get(BASE .. "/search/data?" .. q, {
    referer = BASE .. "/",
    headers = { ["HX-Request"] = "true" },
  })

  local doc = html.parse(r.body)
  local items, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/series/"]')) do
    local href = a:attr("href") or ""
    local id = href:match("/series/(%w+)")
    if id and not seen[id] then
      local img = a:first("img")
      local title = ""
      local t = a:first(".series-title, .line-clamp-1, .truncate")
      if t then title = t:text() end
      if title == "" and img then
        title = (img:attr("alt") or ""):gsub("%s+cover$", "")
      end
      local cover = ""
      if img then cover = img:attr("src") or img:attr("data-src") or "" end
      if title ~= "" then
        seen[id] = true
        items[#items + 1] = {
          id = id,
          title = util.trim(title),
          cover = util.abs_url(cover),
        }
      end
    end
  end
  return { items = items, has_next = #items >= PER }
end

function popular(page, opts)
  local sort = (opts and opts.sort and is_sort(opts.sort)) and opts.sort or "Popularity"
  return list_data({ page = page, sort = sort })
end

function latest(page, opts)
  return list_data({ page = page, sort = "Latest Updates" })
end

function search(query, page, filters, opts)
  filters = filters or {}
  -- sort precedence: explicit filter sort, else opts.sort, else Best Match for a
  -- query / Popularity for an empty browse.
  local sort = filters.sort
  if not (sort and is_sort(sort)) then sort = (opts and opts.sort) end
  if not (sort and is_sort(sort)) then sort = (query ~= "" and "Best Match" or "Popularity") end
  return list_data({
    page = page, sort = sort, text = query,
    status = filters.status, genres = filters.genres,
  })
end

function details(id, opts)
  local r = http.get(BASE .. "/series/" .. id, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = h1:text() end

  -- cover img carries alt="<title> cover"; don't grab the site logo
  local cover = ""
  local ci = doc:first('img[alt$="cover"]')
  if ci then cover = ci:attr("src") or "" end

  local author = ""
  local aa = doc:first('a[href*="author="]')
  if aa then author = aa:text() end

  -- status value sits in a search link, not in the <strong> label
  local status = ""
  local st = doc:first('a[href*="included_status"]')
  if st then status = st:text() end

  local genres = {}
  for _, g in ipairs(doc:select('a[href*="included_tag"]')) do
    genres[#genres + 1] = g:text()
  end

  local description = ""
  local de = doc:first("p.whitespace-pre-wrap, li.whitespace-pre-wrap p")
  if de then description = de:text() end

  -- chapters live in an htmx fragment
  local cr = http.get(BASE .. "/series/" .. id .. "/full-chapter-list", {
    referer = BASE .. "/series/" .. id,
    headers = { ["HX-Request"] = "true" },
  })
  local cdoc = html.parse(cr.body)
  local chapters = {}
  for _, a in ipairs(cdoc:select('a[href*="/chapters/"]')) do
    local cid = (a:attr("href") or ""):match("/chapters/(%w+)")
    if cid then
      -- the label is the first plain span inside span.grow; a:text() would
      -- drag in hidden "Last Read"/"NEW" badges and inline <style> text
      local label = ""
      local sp = a:first("span.grow > span")
      if sp then label = sp:text() end
      if label == "" then label = a:text() end
      local num = label:match("([0-9]+%.?[0-9]*)")
      local date = nil
      local tm = a:first("time")
      if tm then date = util.date_parse(tm:attr("datetime") or tm:text()) end
      chapters[#chapters + 1] = {
        id = cid,
        name = util.trim(label),
        number = num and tonumber(num) or nil,
        url = BASE .. "/chapters/" .. cid,
        date = date,
      }
    end
  end

  return {
    title = util.trim(title),
    cover = util.abs_url(cover),
    author = util.trim(author),
    status = status,
    genres = genres,
    description = util.trim(description),
    url = BASE .. "/series/" .. id,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local r = http.get(BASE .. "/chapters/" .. chapter_id .. "/images?is_prev=False&reading_style=long_strip", {
    referer = BASE .. "/chapters/" .. chapter_id,
    headers = { ["HX-Request"] = "true" },
  })
  local doc = html.parse(r.body)
  local urls = {}
  for _, img in ipairs(doc:select("img")) do
    local src = img:attr("src") or img:attr("data-src") or ""
    if src ~= "" and src:match("%.jpe?g") or src:match("%.png") or src:match("%.webp") then
      urls[#urls + 1] = util.abs_url(src)
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/series/" .. id
end
