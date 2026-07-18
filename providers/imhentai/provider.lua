-- @id imhentai
-- @name IMHentai
-- @version 1.1.0
-- @langs en,ja,es,fr,ko,de,ru
-- @nsfw true
-- @rate 2/1s
-- @ua chrome
-- @base https://imhentai.xxx
--
-- ADULT source. Ported from server/providers/imhentai.js (keiyoushi
-- galleryadults multisrc). Gallery model: each gallery is ONE "Gallery"
-- chapter. Thumbs live at mXX.imhentai.xxx/.../<n>t.<ext>; strip the trailing
-- 't' before the extension for full-res.
--   listing: /?page=N      search: /search/?key=<q>&page=N
--   gallery: /gallery/<id>/

local BASE = "https://imhentai.xxx"

-- galleryadults language paths (first selected code only).
local LANG_PATHS = { en = "english", ja = "japanese", es = "spanish", fr = "french", ko = "korean", de = "german", ru = "russian" }
local LANG_LABELS = { en = "English", ja = "Japanese", es = "Spanish", fr = "French", ko = "Korean", de = "German", ru = "Russian" }
local SORTS = {
  { key = "", label = "Popular" },
  { key = "latest", label = "Latest" },
}
local GENRES = {
  "big-breasts", "sole-female", "sole-male", "nakadashi", "anal", "group",
  "stockings", "blowjob", "ahegao", "schoolgirl-uniform", "glasses", "yaoi",
  "yuri", "futanari", "milf", "netorare", "incest", "harem", "full-color",
  "ffm-threesome", "comedy", "lolicon", "shotacon", "mind-break", "x-ray",
}
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
    sorts = SORTS, genres = GENRES, genreMode = "single", multiChapter = false,
    languages = languages, defaultLangs = {},
  }
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Parse a listing page body into cards.
local function parse_list(body)
  local doc = html.parse(body)
  local out, seen = {}, {}
  for _, a in ipairs(doc:select('a[href*="/gallery/"]')) do
    local href = a:attr("href") or ""
    local id = href:match("/gallery/(%d+)")
    if id and not seen[id] then
      local img = a:first("img")
      local cover = ""
      if img then cover = img:attr("data-src") or img:attr("src") or "" end
      local title = ""
      local t = a:first(".gallery_title, .caption h2")
      if t then title = t:text() end
      if title == "" and img then title = img:attr("alt") or "" end
      if title == "" then title = a:attr("title") or "" end
      if title ~= "" and cover ~= "" and not cover:match("^data:") then
        seen[id] = true
        out[#out + 1] = {
          id = id,
          title = util.trim(title),
          cover = util.abs_url(cover),
        }
      end
    end
  end
  return out
end

local function list_page(url)
  local r = http.get(url, { referer = BASE .. "/" })
  local items = parse_list(r.body or "")
  return { items = items, has_next = #items > 0 }
end

function popular(page, opts)
  -- galleryadults: /language/<name>/popular/?page=N when a language is chosen
  local lp = lang_path(opts)
  if lp ~= "" then
    return list_page(BASE .. "/language/" .. lp .. "/popular/?page=" .. page)
  end
  return list_page(BASE .. "/?page=" .. page)
end

function latest(page, opts)
  local lp = lang_path(opts)
  if lp ~= "" then
    return list_page(BASE .. "/language/" .. lp .. "/?page=" .. page)
  end
  return list_page(BASE .. "/?page=" .. page)
end

function search(query, page, filters, opts)
  filters = filters or {}
  -- imhentai's reliable filter is the free-text `key` param; fold a selected
  -- genre into it as a keyword (the /tags/ browse path is inconsistent).
  -- Language also joins the terms (IMHentai.kt buildQueryString adds mangaLang).
  local terms = {}
  local qt = util.trim(query or "")
  if qt ~= "" then terms[#terms + 1] = qt end
  for g, mode in pairs(filters.genres or {}) do
    if mode == 1 then terms[#terms + 1] = (g:gsub("%-", " ")) end
  end
  local lp = lang_path(opts)
  if lp ~= "" then terms[#terms + 1] = lp end
  local key = table.concat(terms, " ")
  if key == "" then return popular(page, opts) end
  return list_page(BASE .. "/search/?key=" .. urlencode(key) .. "&page=" .. page)
end

function details(id, opts)
  local gid = id
  local r = http.get(BASE .. "/gallery/" .. gid .. "/", { referer = BASE .. "/" })
  local doc = html.parse(r.body or "")
  local title = ""
  local h1 = doc:first("h1")
  if h1 then title = h1:text() end
  if title == "" then title = "Gallery " .. gid end

  local cover = ""
  local ci = doc:first(".left_cover img, .cover img, img.lazyload")
  if ci then cover = ci:attr("data-src") or ci:attr("src") or "" end

  local genres = {}
  for _, e in ipairs(doc:select('a[href*="/tag/"], a[href*="/tags/"]')) do
    local t = util.trim(e:text())
    if t ~= "" and not t:lower():match("^tags?$") then genres[#genres + 1] = t end
  end
  local artists = {}
  for _, e in ipairs(doc:select('a[href*="/artist"]')) do
    local t = util.trim(e:text())
    if t ~= "" then artists[#artists + 1] = t end
  end

  local chapters = {
    { id = gid, name = "Gallery", number = 1, url = BASE .. "/gallery/" .. gid .. "/", date = nil },
  }
  return {
    title = util.trim(title),
    cover = util.abs_url(cover),
    author = artists[1] or "Unknown",
    status = "Completed",
    genres = genres,
    description = (#artists > 0) and ("Artists: " .. table.concat(artists, ", ")) or "",
    url = BASE .. "/gallery/" .. gid .. "/",
    chapters = chapters,
  }
end

local EXT = { j = "jpg", p = "png", w = "webp", g = "gif" }

function pages(chapter_id, opts)
  local gid = chapter_id
  local r = http.get(BASE .. "/gallery/" .. gid .. "/", { referer = BASE .. "/" })
  local body = r.body or ""
  local doc = html.parse(body)
  local urls = {}

  -- Server base + gallery dir come from a thumbnail; the per-page extension is
  -- encoded in `var g_th = $.parseJSON('{"1":"w,W,H",...}')` (w=webp,j=jpg,p=png).
  local dir
  for _, e in ipairs(doc:select('img[data-src*="imhentai.xxx"]')) do
    local src = e:attr("data-src") or ""
    local d = src:match("^(https://m%d+%.imhentai%.xxx/[^?#]+/)%d+t%.[a-z]+$")
    if d then dir = d; break end
  end
  local map_raw = body:match("g_th%s*=%s*%$%.parseJSON%('(%b{})'%)")
  if dir and map_raw then
    local ok, map = pcall(json.parse, map_raw)
    if ok and map then
      local keys = {}
      for k in pairs(map) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
      for _, k in ipairs(keys) do
        local code = tostring(map[k]):match("^([^,]+)")
        code = code and code:lower():gsub("%s", "") or "j"
        urls[#urls + 1] = dir .. k .. "." .. (EXT[code] or "jpg")
      end
    end
  end

  if #urls == 0 then                       -- fallback: strip 't' (jpg galleries)
    for _, e in ipairs(doc:select('img[data-src*="imhentai.xxx"]')) do
      local src = e:attr("data-src") or ""
      if src ~= "" and not src:lower():match("/cover%.") then
        local full = src:gsub("(%d+)t(%.[a-z0-9]+)$", "%1%2")
        local seen = false
        for _, u in ipairs(urls) do if u == full then seen = true end end
        if not seen then urls[#urls + 1] = util.abs_url(full) end
      end
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/gallery/" .. id .. "/"
end
