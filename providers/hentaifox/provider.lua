-- @id hentaifox
-- @name HentaiFox
-- @version 1.1.0
-- @langs en,ja,zh,ko
-- @nsfw true
-- @rate 2/1s
-- @ua chrome
-- @base https://hentaifox.com
--
-- ADULT source. Ported from server/providers/hentaifox.js (keiyoushi
-- galleryadults multisrc). Same single-gallery-as-chapter model as imhentai.
-- Thumbs i*.hentaifox.com/.../<n>t.jpg — strip the trailing 't' for full-res.
--   listing: /?page=N        search: /search/?q=<q>&page=N
--   gallery: /gallery/<id>/

local BASE = "https://hentaifox.com"

-- galleryadults language paths (first selected code only).
local LANG_PATHS = { en = "english", ja = "japanese", zh = "chinese", ko = "korean" }
local LANG_LABELS = { en = "English", ja = "Japanese", zh = "Chinese", ko = "Korean" }
local SORTS = {
  { key = "", label = "Popular" },
  { key = "latest", label = "Latest" },
}
local GENRES = {
  "big-breasts", "sole-female", "sole-male", "nakadashi", "anal", "group",
  "stockings", "blowjob", "ahegao", "schoolgirl-uniform", "glasses", "yaoi",
  "yuri", "futanari", "milf", "netorare", "incest", "harem", "full-color",
  "multi-work-series", "comedy", "lolicon", "shotacon", "mind-break",
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
      if img then title = img:attr("alt") or "" end
      if title == "" then
        local t = a:first(".caption, h2, .g_title")
        if t then title = t:text() end
      end
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
  -- galleryadults: /language/<name>/popular/pag/<n>/ when a language is chosen
  local lp = lang_path(opts)
  if lp ~= "" then
    return list_page(BASE .. "/language/" .. lp .. "/popular/" .. (page > 1 and ("pag/" .. page .. "/") or ""))
  end
  return list_page(BASE .. "/?page=" .. page)
end

function latest(page, opts)
  local lp = lang_path(opts)
  if lp ~= "" then
    return list_page(BASE .. "/language/" .. lp .. "/" .. (page > 1 and ("pag/" .. page .. "/") or ""))
  end
  -- home feed is newest-first already; reuse it
  return list_page(BASE .. "/?page=" .. page)
end

function search(query, page, filters, opts)
  filters = filters or {}
  -- single-genre-mode: collect included genre slugs
  local incl = {}
  for g, mode in pairs(filters.genres or {}) do
    if mode == 1 then incl[#incl + 1] = g end
  end
  local lp = lang_path(opts)
  local qt = util.trim(query or "")
  -- one genre chosen, no text, no language -> the /tag/<slug>/ browse path
  if qt == "" and #incl == 1 and lp == "" then
    return list_page(BASE .. "/tag/" .. incl[1] .. "/pag/" .. page .. "/")
  end
  -- otherwise fold text + genres + language into the search terms
  local terms = {}
  local base_term = qt ~= "" and qt or table.concat(incl, " ")
  if base_term ~= "" then terms[#terms + 1] = base_term end
  if lp ~= "" then terms[#terms + 1] = lp end
  local q = urlencode(table.concat(terms, " "))
  return list_page(BASE .. "/search/?q=" .. q .. "&page=" .. page)
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
  local ci = doc:first(".cover img, img.lazy")
  if ci then cover = ci:attr("data-src") or ci:attr("src") or "" end

  local genres = {}
  for _, e in ipairs(doc:select('a[href*="/tag/"]')) do
    local t = util.trim(e:text())
    if t ~= "" and t:lower() ~= "tags" then genres[#genres + 1] = t end
  end
  local artists = {}
  for _, e in ipairs(doc:select('a[href*="/artist/"]')) do
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

function pages(chapter_id, opts)
  local gid = chapter_id
  local r = http.get(BASE .. "/gallery/" .. gid .. "/", { referer = BASE .. "/" })
  local doc = html.parse(r.body or "")
  local urls, seen = {}, {}
  -- thumbnails i*.hentaifox.com/DIR/ID/<n>t.<ext> -> strip trailing 't' for full-res
  for _, e in ipairs(doc:select(".gallery_thumb img, .g_thumb img, img.lazy, .thumb img")) do
    local src = e:attr("data-src") or e:attr("src") or ""
    if src ~= "" then
      if src:match("^//") then src = "https:" .. src end
      if src:lower():match("hentaifox%.com/") and not src:lower():match("/cover%.") then
        local full = src:gsub("(%d+)t(%.[a-z0-9]+)$", "%1%2"):gsub("(%d+)t(%.[a-z0-9]+)%?.*$", "%1%2")
        if not seen[full] then
          seen[full] = true
          urls[#urls + 1] = full
        end
      end
    end
  end
  return { pages = urls, referer = BASE .. "/" }
end

function url_for(id)
  return BASE .. "/gallery/" .. id .. "/"
end
