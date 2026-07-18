-- @id hentai3
-- @name Hentai3
-- @version 1.1.0
-- @langs en,ja,ko,zh,mo,es,pt,id,jv,tl,vi,th,my,tr,ru,uk,pl,fi,de,it,fr,nl,cs,hu,bg,is,la,ar
-- @nsfw true
-- @rate 2/1s
-- @ua chrome
-- @base https://3hentai.net
--
-- ADULT source. Ported from server/providers/hentai3.js (keiyoushi
-- src/all/hentai3). Galleries live at /d/<id>; listing pages return anchors
-- with href*=/d/. Single-gallery-as-chapter model: details() returns one
-- "Gallery" chapter (id = gallery id) and pages() reads that gallery's images
-- at s2.3hentai.net/d<id>/<n>t.jpg — full-res is the same path without the
-- trailing 't'.
--   popular/latest: /search?q=pages:>0&page=N     gallery: /d/<id>

local BASE = "https://3hentai.net"
local REFERER = BASE .. "/"

-- Language support (Hentai3.kt searchLang): browse one language at a time via
-- /language/<name>/ paths and language:<name> search terms.
local LANG_PATHS = {
  en = "english", ja = "japanese", ko = "korean", zh = "chinese", mo = "mongolian",
  es = "spanish", pt = "portuguese", id = "indonesian", jv = "javanese", tl = "tagalog",
  vi = "vietnamese", th = "thai", my = "burmese", tr = "turkish", ru = "russian",
  uk = "ukrainian", pl = "polish", fi = "finnish", de = "german", it = "italian",
  fr = "french", nl = "dutch", cs = "czech", hu = "hungarian", bg = "bulgarian",
  is = "icelandic", la = "latin", ar = "arabic",
}
local LANG_LABELS = {
  en = "English", ja = "Japanese", ko = "Korean", zh = "Chinese", mo = "Mongolian",
  es = "Spanish", pt = "Portuguese", id = "Indonesian", jv = "Javanese", tl = "Tagalog",
  vi = "Vietnamese", th = "Thai", my = "Burmese", tr = "Turkish", ru = "Russian",
  uk = "Ukrainian", pl = "Polish", fi = "Finnish", de = "German", it = "Italian",
  fr = "French", nl = "Dutch", cs = "Czech", hu = "Hungarian", bg = "Bulgarian",
  is = "Icelandic", la = "Latin", ar = "Arabic",
}
local SORTS = {
  { key = "", label = "Recent" },
  { key = "popular", label = "Popular: All Time" },
  { key = "popular-7d", label = "Popular: Week" },
  { key = "popular-24h", label = "Popular: Today" },
}
local GENRES = {
  "big-breasts", "sole-female", "sole-male", "nakadashi", "anal", "group",
  "schoolgirl-uniform", "glasses", "stockings", "blowjob", "ahegao", "yuri",
  "futanari", "vanilla", "romance", "milf", "netorare", "incest", "harem",
  "full-color", "story-arc", "comedy", "fantasy",
}

-- single-language site: use the first selected code (opts.langs)
local function lang_path(opts)
  local langs = opts and opts.langs
  if type(langs) == "table" and #langs > 0 then return LANG_PATHS[langs[1]] or "" end
  return ""
end

function meta()
  local languages = {}
  for code, _ in pairs(LANG_PATHS) do languages[#languages + 1] = { code = code, label = LANG_LABELS[code] or code } end
  table.sort(languages, function(a, b) return a.label < b.label end)
  return {
    sorts = SORTS, genres = GENRES, genreMode = "multi", multiChapter = false,
    languages = languages, defaultLangs = {},
  }
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function list_to_mangas(body)
  local doc = html.parse(body)
  local out, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/d/"]')) do
    local href = a:attr("href") or ""
    local id = href:match("/d/(%d+)")
    if id and not seen[id] then
      local title = ""
      local t = a:first("div.title")
      if t then title = t:text() end
      if title == "" then title = a:attr("title") or ("Gallery " .. id) end
      local img = a:first("img")
      local cover = ""
      if img then cover = img:attr("src") or img:attr("data-src") or "" end
      if cover:match("^//") then cover = "https:" .. cover end
      if title ~= "" and cover ~= "" then
        seen[id] = true
        out[#out + 1] = { id = id, title = util.trim(title), cover = util.abs_url(cover) }
      end
    end
  end
  return out
end

local function list_page(url)
  local r = http.get(url, { referer = REFERER })
  local body = r.body or ""
  local items = list_to_mangas(body)
  local has_next = body:match('rel=["\']?next') ~= nil
  return { items = items, has_next = has_next }
end

function popular(page, opts)
  local sort = (opts and opts.sort) or "popular"
  local lp = lang_path(opts)
  local url
  if lp ~= "" then
    url = BASE .. "/language/" .. lp .. "/" .. (page > 1 and page or "") .. "?sort=" .. urlencode(sort)
  else
    url = BASE .. "/search?q=" .. urlencode("pages:>0") .. "&page=" .. page .. "&sort=" .. urlencode(sort)
  end
  return list_page(url)
end

function latest(page, opts)
  local lp = lang_path(opts)
  local url
  if lp ~= "" then
    url = BASE .. "/language/" .. lp .. "/" .. page
  else
    url = BASE .. "/search?q=" .. urlencode("pages:>0") .. "&page=" .. page
  end
  return list_page(url)
end

function search(query, page, filters, opts)
  filters = filters or {}
  -- build tag terms with -exclude prefix (Hentai3.kt searchMangaRequest). 3hentai
  -- tags are searched by their human name with SPACES, not the hyphen slug.
  local terms = {}
  for g, mode in pairs(filters.genres or {}) do
    local name = (g:gsub("%-", " "))
    if mode == 1 then terms[#terms + 1] = "tag:'" .. name .. "'"
    elseif mode == -1 then terms[#terms + 1] = "-tag:'" .. name .. "'" end
  end
  -- language folds into the query string (Hentai3.kt: "$query $language $tags")
  local lp = lang_path(opts)
  if lp ~= "" then table.insert(terms, 1, "language:" .. lp) end
  local q_parts = {}
  local qt = util.trim(query or "")
  if qt ~= "" then q_parts[#q_parts + 1] = qt end
  for _, t in ipairs(terms) do q_parts[#q_parts + 1] = t end
  local q = #q_parts > 0 and table.concat(q_parts, " ") or "pages:>0"
  local sort = filters.sort or (opts and opts.sort)
  local url = BASE .. "/search?q=" .. urlencode(q) .. "&page=" .. page
  if sort and sort ~= "" then url = url .. "&sort=" .. urlencode(sort) end
  return list_page(url)
end

function details(id, opts)
  local gid = id
  local r = http.get(BASE .. "/d/" .. gid, { referer = REFERER })
  local doc = html.parse(r.body or "")
  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = h1:text() end
  local short = ""
  local sp = doc:first("h1 > span")
  if sp then short = sp:text() end
  if short == "" then short = title end
  if short == "" then short = "Gallery " .. gid end

  local artists = {}
  for _, e in ipairs(doc:select('a[href*="/artists/"]')) do
    local t = util.trim(e:text()); if t ~= "" then artists[#artists + 1] = t end
  end
  local groups = {}
  for _, e in ipairs(doc:select('a[href*="/groups/"]')) do
    local t = util.trim(e:text()); if t ~= "" then groups[#groups + 1] = t end
  end
  local genres = {}
  for _, e in ipairs(doc:select('a[href*="/tags/"]')) do
    local t = util.trim(e:text()); if t ~= "" then genres[#genres + 1] = t end
  end

  local cover = ""
  local ci = doc:first('img[src*="cover"]')
  if ci then cover = ci:attr("src") or "" end
  if cover:match("^//") then cover = "https:" .. cover end

  local desc = (#groups > 0) and ("Groups: " .. table.concat(groups, ", ")) or ""

  local chapters = {
    { id = gid, name = "Gallery", number = 1, url = BASE .. "/d/" .. gid, date = nil },
  }
  return {
    title = util.trim(short),
    cover = util.abs_url(cover),
    author = artists[1] or groups[1] or "Unknown",
    status = "Completed",
    genres = genres,
    description = desc,
    url = BASE .. "/d/" .. gid,
    chapters = chapters,
  }
end

function pages(chapter_id, opts)
  local gid = chapter_id
  local r = http.get(BASE .. "/d/" .. gid, { referer = REFERER })
  local doc = html.parse(r.body or "")
  local urls, seen = {}, {}
  for _, e in ipairs(doc:select("img")) do
    local src = e:attr("src") or e:attr("data-src") or ""
    if src ~= "" then
      if src:match("^//") then src = "https:" .. src end
      if src:match("/d%d+/") then
        local is_gallery_thumb = src:match("/d%d+/%d+t%.")
        local is_cover_or_thumb = src:lower():match("cover") or src:lower():match("thumb")
        if is_gallery_thumb or not is_cover_or_thumb then
          local full = src:gsub("(%d+)t(%.[a-z0-9]+)$", "%1%2"):gsub("(%d+)t(%.[a-z0-9]+)%?.*$", "%1%2")
          if not seen[full] then
            seen[full] = true
            urls[#urls + 1] = full
          end
        end
      end
    end
  end
  return { pages = urls, referer = REFERER }
end

function url_for(id)
  return BASE .. "/d/" .. id
end
