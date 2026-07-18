-- @id mangaread
-- @name MangaRead
-- @version 1.1.0
-- @langs en
-- @nsfw false
-- @rate 4/1s
-- @ua chrome
-- @base https://www.mangaread.org
--
-- Madara WordPress theme. Ported from server/providers/mangaread.js.
--   list/search: POST /wp-admin/admin-ajax.php (action=madara_load_more) -> card fragment
--   details:     GET  /manga/<slug>/            -> info + numeric post id
--   chapters:    POST /wp-admin/admin-ajax.php (action=manga_get_chapters, manga=<postId>)
--   pages:       GET  /manga/<slug>/<cslug>/     -> img.wp-manga-chapter-img
--
-- The details page carries the numeric WP post id (in #manga-chapters-holder
-- data-id, a shortlink ?p=, or an input[name=manga_id]); the admin-ajax chapter
-- endpoint keys on it. Local ids: manga = "<slug>", chapter = "<slug>/<cslug>".

local BASE = "https://www.mangaread.org"
local AJAX = BASE .. "/wp-admin/admin-ajax.php"

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Filter surface (ported from server/providers/mangaread.js).
local SORTS = {
  { key = "views", label = "Popularity" },
  { key = "latest", label = "Latest" },
  { key = "alphabet", label = "Title (A\u{2013}Z)" },
  { key = "new-manga", label = "Recently added" },
  { key = "rating", label = "Rating" },
}
local STATUSES = {
  { key = "all", label = "All" },
  { key = "on-going", label = "Ongoing" },
  { key = "completed", label = "Completed" },
  { key = "canceled", label = "Cancelled" },
  { key = "on-hold", label = "On hold" },
}
local GENRES = {
  "action", "adventure", "comedy", "drama", "fantasy", "harem", "historical",
  "horror", "isekai", "josei", "martial-arts", "mature", "mystery",
  "psychological", "romance", "school-life", "sci-fi", "seinen", "shoujo",
  "shounen", "slice-of-life", "sports", "supernatural", "tragedy", "webtoons",
  "manhua", "manhwa", "adult", "ecchi", "yaoi", "yuri", "smut",
}
local function is_sort(k)
  for _, s in ipairs(SORTS) do if s.key == k then return true end end
  return false
end

function meta()
  return { sorts = SORTS, statuses = STATUSES, genres = GENRES, genreMode = "multi", multiChapter = true }
end

local function slug_from(href)
  return (href or ""):match("/manga/([^/?#]+)")
end

local function fix_proto(u)
  u = util.trim(u or "")
  u = u:gsub("%s.*$", "") -- strip srcset noise
  if u:sub(1, 2) == "//" then return "https:" .. u end
  return u
end

local function parse_status(t)
  local s = (t or ""):lower()
  if s:find("complete") then return "Completed" end
  if s:find("cancel") then return "Cancelled" end
  if s:find("hold") or s:find("hiatus") then return "Hiatus" end
  if s:find("going") or s:find("ongoing") then return "Ongoing" end
  return "Unknown"
end

local function parse_cards(doc)
  local items, seen = {}, {}
  for _, el in ipairs(doc:select(".page-item-detail, .c-tabs-item__content, .manga")) do
    local a = el:first('a[href*="/manga/"]')
    local slug = a and slug_from(a:attr("href"))
    if slug and not seen[slug] then
      local img = el:first("img")
      local cover = ""
      if img then
        cover = fix_proto(img:attr("data-src") or img:attr("src") or img:attr("data-lazy-src") or "")
      end
      local title = a and util.trim(a:attr("title") or "") or ""
      if title == "" then
        local t = el:first(".post-title, h3, h5")
        if t then title = util.trim(t:text()) end
      end
      if title == "" and img then title = util.trim(img:attr("alt") or "") end
      if title ~= "" then
        seen[slug] = true
        items[#items + 1] = { id = slug, title = title, cover = util.abs_url(cover) }
      end
    end
  end
  return items
end

-- Listing via the Madara search archive (GET). The card container is shared by
-- the archive + search-results pages, so one parse handles both. (The chapter
-- list — not this — is the piece that goes through admin-ajax.)
-- Mirrors the old JS loadMore(): sort -> m_orderby, status -> &status[]=<key>
-- (WP-manga meta status), genres -> &genre[]=<slug> for each INCLUDED (mode==1).
local function listing(page, query, sort, status, genres)
  if not is_sort(sort) then sort = "views" end
  local url = BASE .. "/page/" .. page .. "/?s=" .. urlencode(query or "")
    .. "&post_type=wp-manga&m_orderby=" .. sort
  if status and status ~= "" and status ~= "all" then
    url = url .. "&status[]=" .. urlencode(status)
  end
  for g, mode in pairs(genres or {}) do
    if mode == 1 then url = url .. "&genre[]=" .. urlencode(tostring(g)) end
  end
  local r = http.get(url, { referer = BASE .. "/" })
  local items = parse_cards(html.parse(r.body))
  return { items = items, has_next = #items >= 12 }
end

function popular(page, opts)
  local sort = (opts and opts.sort and is_sort(opts.sort)) and opts.sort or "views"
  return listing(page, "", sort, "all", nil)
end

function latest(page, opts)
  return listing(page, "", "latest", "all", nil)
end

function search(query, page, filters, opts)
  filters = filters or {}
  -- sort precedence: filters.sort, else opts.sort, else old JS default "views".
  local sort = filters.sort
  if not is_sort(sort) then sort = opts and opts.sort end
  if not is_sort(sort) then sort = "views" end
  return listing(page, util.trim(query or ""), sort, filters.status or "all", filters.genres)
end

-- Pull the numeric WP post id off the details page (Madara stashes it in a few
-- interchangeable spots).
local function post_id(doc)
  local h = doc:first("#manga-chapters-holder[data-id], [id=manga-chapters-holder]")
  if h then
    local id = h:attr("data-id")
    if id and id ~= "" then return id end
  end
  local inp = doc:first('input[name="manga_id"], input.rating-post-id, .rating-post-id')
  if inp then
    local id = inp:attr("value") or inp:attr("data-post-id")
    if id and id ~= "" then return id end
  end
  local sl = doc:first('link[rel="shortlink"]')
  if sl then
    local id = (sl:attr("href") or ""):match("[?&]p=(%d+)")
    if id then return id end
  end
  return nil
end

local function parse_chapters(doc, slug)
  local out, seen = {}, {}
  for _, li in ipairs(doc:select("li.wp-manga-chapter")) do
    local a = li:first('a[href*="/manga/"]')
    if a then
      local href = a:attr("href") or ""
      local cslug = href:match("/manga/" .. slug:gsub("[%p]", "%%%0") .. "/([^/?#]+)")
      if cslug and cslug:find("%d") and not seen[cslug] then
        seen[cslug] = true
        local label = util.trim(a:text())
        local num = label:match("(%d+%.?%d*)") or cslug:match("(%d+%.?%d*)")
        local date = nil
        local dnode = li:first(".chapter-release-date a")
        local raw = dnode and dnode:attr("title") or nil
        if not raw then
          local di = li:first(".chapter-release-date i, .chapter-release-date")
          if di then raw = util.trim(di:text()) end
        end
        if raw and raw ~= "" then date = util.date_parse(raw) end
        out[#out + 1] = {
          id = slug .. "/" .. cslug,
          name = label ~= "" and label or cslug,
          number = num and tonumber(num) or nil,
          url = BASE .. "/manga/" .. slug .. "/" .. cslug .. "/",
          date = date,
        }
      end
    end
  end
  return out
end

function details(id, opts)
  local slug = id
  local r = http.get(BASE .. "/manga/" .. slug .. "/", { referer = BASE .. "/" })
  local doc = html.parse(r.body)

  local title = slug
  local th = doc:first(".post-title h1")
  if th then
    local t = util.trim(th:text())
    if t ~= "" then title = t end
  end

  local cover = ""
  local ci = doc:first(".summary_image img")
  if ci then cover = fix_proto(ci:attr("data-src") or ci:attr("src") or "") end

  local author_names = {}
  for _, a in ipairs(doc:select(".author-content a, .manga-authors a")) do
    local t = util.trim(a:text())
    if t ~= "" then author_names[#author_names + 1] = t end
  end
  local author = #author_names > 0 and table.concat(author_names, ", ") or "Unknown"

  -- status: label row ".post-status .summary-content"
  local status = "Unknown"
  local sc = doc:first(".post-status .summary-content")
  if sc then status = parse_status(util.trim(sc:text())) end

  local genres = {}
  for _, g in ipairs(doc:select(".genres-content a, .wp-manga-genre a")) do
    local t = util.trim(g:text())
    if t ~= "" then genres[#genres + 1] = t end
  end

  local description = ""
  local de = doc:first(".description-summary .summary__content, .manga-excerpt, div.summary__content")
  if de then description = util.trim(de:text()) end

  -- chapters: admin-ajax manga_get_chapters keyed on the numeric post id
  local chapters = {}
  local pid = post_id(doc)
  if pid then
    local cr = http.post_form(AJAX, { action = "manga_get_chapters", manga = pid },
      { referer = BASE .. "/manga/" .. slug .. "/" })
    chapters = parse_chapters(html.parse(cr.body), slug)
  end
  if #chapters == 0 then chapters = parse_chapters(doc, slug) end

  return {
    title = title,
    cover = util.abs_url(cover),
    author = author,
    status = status,
    genres = genres,
    description = description,
    url = BASE .. "/manga/" .. slug .. "/",
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local slug = chapter_id:match("^([^/]+)/")
  local cslug = chapter_id:match("/(.+)$")
  local r = http.get(BASE .. "/manga/" .. slug .. "/" .. cslug .. "/",
    { referer = BASE .. "/manga/" .. slug .. "/" })
  local doc = html.parse(r.body)
  local urls = {}
  for _, img in ipairs(doc:select("img.wp-manga-chapter-img")) do
    local src = fix_proto(img:attr("data-src") or img:attr("src") or img:attr("data-lazy-src") or "")
    if src ~= "" then urls[#urls + 1] = util.abs_url(src) end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/manga/" .. id .. "/"
end
