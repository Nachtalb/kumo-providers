-- @id weebcentral
-- @name Weeb Central
-- @version 1.0.0
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

-- /search/data returns a fragment of series cards when asked via htmx.
local function list_data(opts)
  local q = "limit=" .. PER
    .. "&offset=" .. ((opts.page - 1) * PER)
    .. "&sort=" .. (opts.sort or "Popularity"):gsub(" ", "%%20")
    .. "&order=Descending&official=Any&display_mode=Full%20Display"
  if opts.text and opts.text ~= "" then
    q = q .. "&text=" .. opts.text:gsub("[^%w%-%.%_%~]", function(c)
      return string.format("%%%02X", c:byte())
    end)
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
  return list_data({ page = page, sort = "Popularity" })
end

function latest(page, opts)
  return list_data({ page = page, sort = "Latest Updates" })
end

function search(query, page, filters, opts)
  local sort = "Best Match"
  if query == "" then sort = "Popularity" end
  return list_data({ page = page, sort = sort, text = query })
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

function filters()
  -- site has sort/status/genre filters; declarative schema lands with the
  -- filters()/settings() milestone of #25
  return {}
end
