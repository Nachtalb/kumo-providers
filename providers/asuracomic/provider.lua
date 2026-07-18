-- @id asuracomic
-- @name Asura Scans
-- @version 1.0.0
-- @langs en
-- @nsfw false
-- @rate 3/1s
-- @ua chrome
-- @base https://asurascans.com
--
-- Astro-rendered HTML scrape. Ported from server/providers/asuracomic.js.
--   listing : /browse?page=N[&search=..&genres=a,b&status=..&order=..]
--   details : /comics/<slug>
--   chapter : /comics/<slug>/chapter/<n>
--   cover   : https://cdn.asurascans.com/asura-images/covers/...
--   pages   : https://cdn.asurascans.com/asura-images/chapters/<slug>/<n>/NNN.webp
--
-- Local ids: manga id = "<slug>", chapter id = "<slug>/chapter/<n>". The host
-- namespaces "asuracomic:" around every call. pages() MUST re-insert /comics/:
-- the chapter id carries only <slug>/chapter/<n>, so the full route is
-- /comics/<slug>/chapter/<n>.

local BASE = "https://asurascans.com"

local function parse_status(t)
  local s = (t or ""):lower()
  if s:find("ongoing") then return "Ongoing"
  elseif s:find("completed") then return "Completed"
  elseif s:find("hiatus") then return "Hiatus"
  elseif s:find("dropped") then return "Cancelled"
  elseif s:find("season end") then return "Ongoing"
  end
  return "Unknown"
end

-- Cards: an <a href="/comics/<slug>"> wrapping the cover <img>. Title is the
-- img alt; skip chapter anchors.
local function parse_browse(doc)
  local items, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/comics/"]')) do
    local href = a:attr("href") or ""
    if not href:find("/chapter/") then
      local slug = href:match("/comics/([^/?#]+)")
      if slug and not seen[slug] then
        local img = a:first("img")
        if img then
          local title = util.trim(img:attr("alt") or "")
          if title ~= "" and not title:lower():find("asura scans") then
            seen[slug] = true
            local cover = img:attr("src") or img:attr("data-src") or ""
            items[#items + 1] = {
              id = slug,
              title = title,
              cover = util.abs_url(cover),
            }
          end
        end
      end
    end
  end
  return items
end

local function fetch_list(query, page, status, order)
  local qs = {}
  if query and query ~= "" then
    qs[#qs + 1] = "search=" .. query:gsub("[^%w%-%.%_%~]", function(c)
      return string.format("%%%02X", c:byte())
    end)
  end
  if status and status ~= "" and status ~= "all" then
    qs[#qs + 1] = "status=" .. status
  end
  if order == "update" then qs[#qs + 1] = "order=update" end
  qs[#qs + 1] = "page=" .. (page or 1)
  local r = http.get(BASE .. "/browse?" .. table.concat(qs, "&"), { referer = BASE .. "/" })
  local items = parse_browse(html.parse(r.body))
  return { items = items, has_next = #items >= 20 }
end

function popular(page, opts)
  return fetch_list("", page, "all", "popular")
end

function latest(page, opts)
  return fetch_list("", page, "all", "update")
end

function search(query, page, filters, opts)
  return fetch_list(query or "", page, "all", "popular")
end

function details(id, opts)
  local url = BASE .. "/comics/" .. id
  local r = http.get(url, { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = util.trim(h1:text()) end
  if title == "" then title = id end

  -- author + artist from /browse?author= / ?artist= anchors
  local authors, seen_a = {}, {}
  for _, e in ipairs(doc:select('a[href*="/browse?author="], a[href*="/browse?artist="]')) do
    local t = util.trim(e:text())
    if t ~= "" and not seen_a[t] then seen_a[t] = true; authors[#authors + 1] = t end
  end
  local author = #authors > 0 and table.concat(authors, ", ") or "Unknown"

  local genres, seen_g = {}, {}
  for _, e in ipairs(doc:select('a[href*="/browse?genres="]')) do
    local t = util.trim(e:text())
    if t ~= "" and not seen_g[t] then seen_g[t] = true; genres[#genres + 1] = t end
  end

  -- status: value sits next to a "Status" label
  local status = "Unknown"
  for _, e in ipairs(doc:select("h3, span, div")) do
    local t = util.trim(e:text())
    if t:lower():match("^status") then status = parse_status(t); break end
  end

  -- cover: prefer the non -400 (full-size) covers image
  local cover = ""
  for _, e in ipairs(doc:select('img[src*="asura-images/covers/"]')) do
    local s = e:attr("src") or ""
    if cover == "" then cover = s end
    if not s:find("%-400%.") then cover = s; break end
  end
  cover = util.abs_url(cover)

  local description = ""
  local md = doc:first('meta[name="description"]')
  if md then description = util.trim(md:attr("content") or "") end

  local chapters, seen_c = {}, {}
  for _, a in ipairs(doc:select('a[href*="/chapter/"]')) do
    local href = a:attr("href") or ""
    local slug, num = href:match("/comics/([^/?#]+)/chapter/([0-9%.]+)")
    if slug and num and not seen_c[num] then
      seen_c[num] = true
      local nm = ""
      local sp = a:first("span")
      if sp then nm = util.trim(sp:text():gsub("%s+", " ")) end
      if nm == "" then nm = "Chapter " .. num end
      local date = nil
      for _, s in ipairs(a:select("span")) do
        local st = s:text()
        if st:match("%d%d%d%d") then date = util.date_parse(util.trim(st)); break end
      end
      chapters[#chapters + 1] = {
        id = slug .. "/chapter/" .. num,
        name = nm,
        number = tonumber(num),
        url = BASE .. "/comics/" .. slug .. "/chapter/" .. num,
        date = date,
      }
    end
  end
  -- ensure newest-first (descending by chapter number)
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
  -- chapter_id: <slug>/chapter/<n>  ->  /comics/<slug>/chapter/<n>
  local rest = chapter_id:gsub("^/", "")
  local url = BASE .. "/comics/" .. rest
  local r = http.get(url, { referer = BASE .. "/" })
  local doc = html.parse(r.body)
  local urls, seen = {}, {}
  for _, img in ipairs(doc:select("img")) do
    local s = img:attr("src") or img:attr("data-src") or ""
    if s ~= "" and s:find("asura%-images/chapters/") then
      s = util.abs_url(s)
      if not seen[s] then seen[s] = true; urls[#urls + 1] = s end
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/comics/" .. id
end

function filters()
  return {}
end
