-- @id mangadex
-- @name MangaDex
-- @version 1.1.0
-- @langs en,ja,ko,zh,es,fr,de,pt,ru,it,id,vi,th,ar,tr,pl,uk
-- @nsfw false
-- @rate 4/1s
-- @ua simple
-- @base https://mangadex.org
--
-- JSON-API provider (no scraping). Full port of server/providers/mangadex.js
-- (itself from keiyoushi src/all/mangadex). Restores the complete filter surface
-- the migration dropped: sorts, status, the four tri-state tag groups
-- (content/format/genre/theme), the extra groups (original language, content
-- rating, demographic), tag include/exclude AND-OR modes, the has-chapters
-- toggle, the ~40-language multi-select, and per-call opts (langs / nsfw / sort).
--
--   list/search -> GET /manga          (cover from includes[]=cover_art rels)
--   details     -> GET /manga/<uuid>   + paginated GET /manga/<uuid>/feed
--   pages       -> GET /at-home/server/<chapterId>
--
-- The @ua simple class is REQUIRED: the MangaDex WAF 400s on browser UAs.
-- Local-id discipline: this script never sees or writes "mangadex:" ids.

local API = "https://api.mangadex.org"
local COVERS = "https://uploads.mangadex.org/covers"
local SITE = "https://mangadex.org"
local PER = 24

-- ---- languages ------------------------------------------------------------
-- Full keiyoushi registration list. UI codes; the MangaDex API wants its own
-- dialect for a few (MangaDex.kt dexLang): zh-Hans->zh, zh-Hant->zh-hk,
-- fil->tl, pt-BR->pt-br, es-419->es-la.
local LANG_CODES = {
  "af", "sq", "ar", "az", "eu", "be", "bn", "bg", "my", "ca", "zh-Hans", "zh-Hant",
  "cv", "hr", "cs", "da", "nl", "en", "eo", "et", "fil", "fi", "fr", "ka", "de", "el",
  "he", "hi", "hu", "ga", "id", "it", "ja", "jv", "kk", "ko", "la", "lt", "ms", "mn",
  "ne", "no", "fa", "pl", "pt-BR", "pt", "ro", "ru", "sr", "sk", "es-419", "es", "sv",
  "ta", "te", "th", "tr", "uk", "ur", "uz", "vi",
}
local LANG_LABELS = {
  af = "Afrikaans", sq = "Albanian", ar = "Arabic", az = "Azerbaijani", eu = "Basque",
  be = "Belarusian", bn = "Bengali", bg = "Bulgarian", my = "Burmese", ca = "Catalan",
  ["zh-Hans"] = "Chinese (Simplified)", ["zh-Hant"] = "Chinese (Traditional)", cv = "Chuvash",
  hr = "Croatian", cs = "Czech", da = "Danish", nl = "Dutch", en = "English", eo = "Esperanto",
  et = "Estonian", fil = "Filipino", fi = "Finnish", fr = "French", ka = "Georgian",
  de = "German", el = "Greek", he = "Hebrew", hi = "Hindi", hu = "Hungarian", ga = "Irish",
  id = "Indonesian", it = "Italian", ja = "Japanese", jv = "Javanese", kk = "Kazakh",
  ko = "Korean", la = "Latin", lt = "Lithuanian", ms = "Malay", mn = "Mongolian",
  ne = "Nepali", no = "Norwegian", fa = "Persian", pl = "Polish", ["pt-BR"] = "Portuguese (Br)",
  pt = "Portuguese", ro = "Romanian", ru = "Russian", sr = "Serbian", sk = "Slovak",
  ["es-419"] = "Spanish (LatAm)", es = "Spanish", sv = "Swedish", ta = "Tamil", te = "Telugu",
  th = "Thai", tr = "Turkish", uk = "Ukrainian", ur = "Urdu", uz = "Uzbek", vi = "Vietnamese",
}
local API_LANG = { ["zh-Hans"] = "zh", ["zh-Hant"] = "zh-hk", fil = "tl", ["pt-BR"] = "pt-br", ["es-419"] = "es-la" }
local function api_lang(c) return API_LANG[c] or c end

-- ---- sorts & statuses -----------------------------------------------------
local SORTS = {
  { key = "followedCount", label = "Popularity" },
  { key = "latestUploadedChapter", label = "Latest" },
  { key = "relevance", label = "Relevance" },
  { key = "rating", label = "Rating" },
  { key = "title", label = "Title (A-Z)" },
  { key = "createdAt", label = "Recently added" },
  { key = "updatedAt", label = "Recently updated" },
  { key = "year", label = "Year" },
}
local function is_sort(k)
  for _, s in ipairs(SORTS) do if s.key == k then return true end end
  return false
end
local STATUSES = {
  { key = "all", label = "All" },
  { key = "ongoing", label = "Ongoing" },
  { key = "completed", label = "Completed" },
  { key = "hiatus", label = "Hiatus" },
  { key = "cancelled", label = "Cancelled" },
}

-- ---- tag catalog (slug -> UUID) -------------------------------------------
local TAG_IDS = {
  ["gore"] = "b29d6a3d-1569-4e7a-8caf-7557bc92cd5d", ["sexual-violence"] = "97893a4c-12af-4dac-b6be-0dffb353568e",
  ["4-koma"] = "b11fda93-8f1d-4bef-b2ed-8803d3733170", ["adaptation"] = "f4122d1c-3b44-44d0-9936-ff7502c39ad3",
  ["anthology"] = "51d83883-4103-437c-b4b1-731cb73d786c", ["award-winning"] = "0a39b5a1-b235-4886-a747-1d05d216532d",
  ["doujinshi"] = "b13b2a48-c720-44a9-9c77-39c9979373fb", ["fan-colored"] = "7b2ce280-79ef-4c09-9b58-12b7c23a9b78",
  ["full-color"] = "f5ba408b-0e7a-484d-8d49-4e9125ac96de", ["long-strip"] = "3e2b8dae-350e-4ab8-a8ce-016e844b9f0d",
  ["official-colored"] = "320831a8-4026-470b-94f6-8353740e6f04", ["oneshot"] = "0234a31e-a729-4e28-9d6a-3f87c4966b9e",
  ["self-published"] = "891cf039-b895-47f0-9229-bef4c96eccd4", ["web-comic"] = "e197df38-d0e7-43b5-9b09-2842d0c326dd",
  ["action"] = "391b0423-d847-456f-aff0-8b0cfc03066b", ["adventure"] = "87cc87cd-a395-47af-b27a-93258283bbc6",
  ["boys-love"] = "5920b825-4181-4a17-beeb-9918b0ff7a30", ["comedy"] = "4d32cc48-9f00-4cca-9b5a-a839f0764984",
  ["crime"] = "5ca48985-9a9d-4bd8-be29-80dc0303db72", ["drama"] = "b9af3a63-f058-46de-a9a0-e0c13906197a",
  ["fantasy"] = "cdc58593-87dd-415e-bbc0-2ec27bf404cc", ["girls-love"] = "a3c67850-4684-404e-9b7f-c69850ee5da6",
  ["historical"] = "33771934-028e-4cb3-8744-691e866a923e", ["horror"] = "cdad7e68-1419-41dd-bdce-27753074a640",
  ["isekai"] = "ace04997-f6bd-436e-b261-779182193d3d", ["magical-girls"] = "81c836c9-914a-4eca-981a-560dad663e73",
  ["mecha"] = "50880a9d-5440-4732-9afb-8f457127e836", ["medical"] = "c8cbe35b-1b2b-4a3f-9c37-db84c4514856",
  ["mystery"] = "ee968100-4191-4968-93d3-f82d72be7e46", ["philosophical"] = "b1e97889-25b4-4258-b28b-cd7f4d28ea9b",
  ["psychological"] = "3b60b75c-a2d7-4860-ab56-05f391bb889c", ["romance"] = "423e2eae-a7a2-4a8b-ac03-a8351462d71d",
  ["sci-fi"] = "256c8bd9-4904-4360-bf4f-508a76d67183", ["slice-of-life"] = "e5301a23-ebd9-49dd-a0cb-2add944c7fe9",
  ["sports"] = "69964a64-2f90-4d33-beeb-f3ed2875eb4c", ["superhero"] = "7064a261-a137-4d3a-8848-2d385de3a99c",
  ["thriller"] = "07251805-a27e-4d59-b488-f0bfbec15168", ["tragedy"] = "f8f62932-27da-4fe4-8ee1-6779a8c5edba",
  ["wuxia"] = "acc803a4-c95a-4c22-86fc-eb6b582d82a2", ["aliens"] = "e64f6742-c834-471d-8d72-dd51fc02b835",
  ["animals"] = "3de8c75d-8ee3-48ff-98ee-e20a65c86451", ["cooking"] = "ea2bc92d-1c26-4930-9b7c-d5c0dc1b6869",
  ["crossdressing"] = "9ab53f92-3eed-4e9b-903a-917c86035ee3", ["delinquents"] = "da2d50ca-3018-4cc0-ac7a-6b7d472a29ea",
  ["demons"] = "39730448-9a5f-48a2-85b0-a70db87b1233", ["genderswap"] = "2bd2e8d0-f146-434a-9b51-fc9ff2c5fe6a",
  ["ghosts"] = "3bb26d85-09d5-4d2e-880c-c34b974339e9", ["gyaru"] = "fad12b5e-68ba-460e-b933-9ae8318f5b65",
  ["harem"] = "aafb99c1-7f60-43fa-b75f-fc9502ce29c7", ["incest"] = "5bd0e105-4481-44ca-b6e7-7544da56b1a3",
  ["loli"] = "2d1f5d56-a1e5-4d0d-a961-2193588b08ec", ["mafia"] = "85daba54-a71c-4554-8a28-9901a8b0afad",
  ["magic"] = "a1f53773-c69a-4ce5-8cab-fffcd90b1565", ["mahjong"] = "cb562697-929f-4d28-9d66-6d3995bf2592",
  ["martial-arts"] = "799c202e-7daa-44eb-9cf7-8a3c0441531e", ["military"] = "ac72833b-c4e9-4878-b9db-6c8a4a99444a",
  ["monster-girls"] = "dd1f77c5-dea9-4e2b-97ae-224af09caf99", ["monsters"] = "36fd93ea-e8b8-445e-b836-358f02b3d33d",
  ["music"] = "f42fbf9e-188a-447b-9fdc-f19dc1e4d685", ["ninja"] = "489dd859-9b61-4c37-af75-5b18e88daafc",
  ["office-workers"] = "92d6d951-ca5e-429c-ac78-451071cbf064", ["police"] = "df33b754-73a3-4c54-80e6-1a74a8058539",
  ["post-apocalyptic"] = "9467335a-1b83-4497-9231-765337a00b96", ["reincarnation"] = "0bc90acb-ccc1-44ca-a34a-b9f3a73259d0",
  ["reverse-harem"] = "65761a2a-415e-47f3-bef2-a9dababba7a6", ["samurai"] = "81183756-1453-4c81-aa9e-f6e1b63be016",
  ["school-life"] = "caaa44eb-cd40-4177-b930-79d3ef2afe87", ["shota"] = "ddefd648-5140-4e5f-ba18-4eca4071d19b",
  ["supernatural"] = "eabc5b4c-6aff-42f3-b657-3e90cbd00b75", ["survival"] = "5fff9cde-849c-4d78-aab0-0d52b2ee1d25",
  ["time-travel"] = "292e862b-2d17-4062-90a2-0356caa4ae27", ["traditional-games"] = "31932a7e-5b8e-49a6-9f12-2afa39dc544c",
  ["vampires"] = "d7d1730f-6eb0-4ba6-9437-602cac38664c", ["video-games"] = "9438db5a-7e2a-4ac0-b39e-e0d95a34b8a8",
  ["villainess"] = "d14322ac-4d6f-4e9b-afd9-629d5f4d8a41", ["virtual-reality"] = "8c86611e-fab7-4986-9dec-d1a2f44acdd5",
  ["zombies"] = "631ef465-9aba-4afb-b0fc-ea10efe274a8",
}
local TAG_GROUPS = {
  { key = "content", label = "Content", tags = { "gore", "sexual-violence" } },
  { key = "format", label = "Format", tags = { "4-koma", "adaptation", "anthology", "award-winning", "doujinshi", "fan-colored", "full-color", "long-strip", "official-colored", "oneshot", "self-published", "web-comic" } },
  { key = "genre", label = "Genre", tags = { "action", "adventure", "boys-love", "comedy", "crime", "drama", "fantasy", "girls-love", "historical", "horror", "isekai", "magical-girls", "mecha", "medical", "mystery", "philosophical", "psychological", "romance", "sci-fi", "slice-of-life", "sports", "superhero", "thriller", "tragedy", "wuxia" } },
  { key = "theme", label = "Theme", tags = { "aliens", "animals", "cooking", "crossdressing", "delinquents", "demons", "genderswap", "ghosts", "gyaru", "harem", "incest", "loli", "mafia", "magic", "mahjong", "martial-arts", "military", "monster-girls", "monsters", "music", "ninja", "office-workers", "police", "post-apocalyptic", "reincarnation", "reverse-harem", "samurai", "school-life", "shota", "supernatural", "survival", "time-travel", "traditional-games", "vampires", "video-games", "villainess", "virtual-reality", "zombies" } },
}
local EXTRAS = {
  { key = "originalLanguage", label = "Original language", options = {
    { key = "ja", label = "Japanese (Manga)" }, { key = "zh", label = "Chinese (Manhua)" }, { key = "ko", label = "Korean (Manhwa)" },
  } },
  { key = "contentRating", label = "Content rating", options = {
    { key = "safe", label = "Safe" }, { key = "suggestive", label = "Suggestive" },
    { key = "erotica", label = "Erotica" }, { key = "pornographic", label = "Pornographic" },
  } },
  { key = "demographic", label = "Demographic", options = {
    { key = "none", label = "None" }, { key = "shounen", label = "Shounen" }, { key = "shoujo", label = "Shoujo" },
    { key = "seinen", label = "Seinen" }, { key = "josei", label = "Josei" },
  } },
}
local EXTRA_TOGGLES = { { key = "hasChapters", label = "Has available chapters", default = true } }
local EXTRA_MODES = {
  { key = "includedTagsMode", label = "Included tags mode", default = "AND", options = { { key = "AND", label = "And" }, { key = "OR", label = "Or" } } },
  { key = "excludedTagsMode", label = "Excluded tags mode", default = "OR", options = { { key = "AND", label = "And" }, { key = "OR", label = "Or" } } },
}

-- The descriptor the frontend filter sheet renders. Mirrors the old JS module
-- exports (sorts / statuses / tagGroups / genres / extras / modes / toggles /
-- languages / defaultLangs). Merged into providers_meta by the engine.
function meta()
  local languages = {}
  for _, c in ipairs(LANG_CODES) do
    languages[#languages + 1] = { code = c, label = LANG_LABELS[c] or c }
  end
  local genres = TAG_GROUPS[3].tags   -- flat genre list (compat)
  return {
    sorts = SORTS,
    statuses = STATUSES,
    genres = genres,
    genreMode = "multi",
    tagGroups = TAG_GROUPS,
    extras = EXTRAS,
    extraToggles = EXTRA_TOGGLES,
    extraModes = EXTRA_MODES,
    languages = languages,
    defaultLangs = { "en" },
    langFilter = true,
    supportsExcludeNsfw = true,
    multiChapter = true,
  }
end

-- ---- helpers --------------------------------------------------------------
local function urlencode(s)
  return (s:gsub("[^%w%-%.%_%~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function first_val(t)
  for _, v in pairs(t or {}) do return v end
  return nil
end
local function pick_title(attr)
  attr = attr or {}
  local main = attr.title or {}
  local alts = attr.altTitles or {}
  local function pick(lang)
    if main[lang] then return main[lang] end
    for _, a in ipairs(alts) do if a[lang] then return a[lang] end end
    return nil
  end
  return pick("en") or pick("ja-ro") or first_val(main) or "Untitled"
end
local function cover_url(m)
  for _, rel in ipairs(m.relationships or {}) do
    if rel.type == "cover_art" and rel.attributes and rel.attributes.fileName then
      return COVERS .. "/" .. m.id .. "/" .. rel.attributes.fileName .. ".512.jpg"
    end
  end
  return ""
end
local function api_get(url)
  local r = http.get(url, { headers = { Accept = "application/json" } })
  local j = json.parse(r.body)
  if not j or j.result == "error" then error("mangadex: api error") end
  return j
end
local function parse_list(url)
  local j = api_get(url)
  local items = {}
  for _, m in ipairs(j.data or {}) do
    items[#items + 1] = { id = m.id, title = pick_title(m.attributes), cover = cover_url(m) }
  end
  local off, lim, total = j.offset or 0, j.limit or 0, j.total or 0
  return { items = items, has_next = (off + lim) < total }
end

-- Effective selected languages from opts.langs (a list). Empty/absent = all.
local function eff_langs(opts)
  local l = opts and opts.langs
  if type(l) == "table" and #l > 0 then return l end
  return {}
end
-- Content-rating gate. Default safe+suggestive; opts.nsfw adds erotica+porn.
local function ratings_qs(opts)
  if opts and opts.nsfw then
    return "&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica&contentRating[]=pornographic"
  end
  return "&contentRating[]=safe&contentRating[]=suggestive"
end
-- "Has available chapters" gate (see the empty-mangas note): BOTH params are
-- needed — hasAvailableChapters alone keeps external-only titles that then show
-- zero readable chapters. Off when the caller unchecks it (filters.extras.hasChapters=false).
local function has_ch_qs(has_chapters)
  if has_chapters == false then return "" end
  return "&hasAvailableChapters=true&hasUnavailableChapters=false"
end
local function langs_qs(opts)
  local out = ""
  for _, l in ipairs(eff_langs(opts)) do
    out = out .. "&availableTranslatedLanguage[]=" .. urlencode(api_lang(l))
  end
  return out
end

local function list_base(page, opts, has_chapters)
  return API .. "/manga?limit=" .. PER
    .. "&offset=" .. ((page - 1) * PER)
    .. "&includes[]=cover_art"
    .. ratings_qs(opts)
    .. has_ch_qs(has_chapters)
    .. langs_qs(opts)
end

function popular(page, opts)
  local sort = (opts and opts.sort and is_sort(opts.sort)) and opts.sort or "followedCount"
  return parse_list(list_base(page, opts, true) .. "&order[" .. sort .. "]=desc")
end

function latest(page, opts)
  return parse_list(list_base(page, opts, true) .. "&order[latestUploadedChapter]=desc")
end

function search(query, page, filters, opts)
  filters = filters or {}
  local extras = filters.extras or {}
  local has_chapters = extras.hasChapters
  local url = list_base(page, opts, has_chapters)

  -- sort: explicit filter sort, else opts.sort, else followedCount. Title=asc.
  local sort = filters.sort
  if not (sort and is_sort(sort)) then sort = (opts and opts.sort) end
  if not (sort and is_sort(sort)) then sort = "followedCount" end
  local dir = (sort == "title") and "asc" or "desc"
  if query and query ~= "" then
    url = url .. "&title=" .. urlencode(query)
  end
  url = url .. "&order[" .. sort .. "]=" .. dir

  -- status
  if filters.status and filters.status ~= "" and filters.status ~= "all" then
    url = url .. "&status[]=" .. urlencode(filters.status)
  end

  -- content rating override (EXTRAS.contentRating narrows the default gate)
  if type(extras.contentRating) == "table" and #extras.contentRating > 0 then
    -- rebuild url without the default ratings by appending the chosen ones;
    -- MangaDex takes the LAST-specified set when repeated, but to be safe we
    -- only add the explicit ones here (the default gate stays but is widened).
    for _, r in ipairs(extras.contentRating) do
      url = url .. "&contentRating[]=" .. urlencode(r)
    end
  end
  -- original language (manhua splits across zh + zh-hk)
  if type(extras.originalLanguage) == "table" then
    for _, l in ipairs(extras.originalLanguage) do
      url = url .. "&originalLanguage[]=" .. urlencode(l)
      if l == "zh" then url = url .. "&originalLanguage[]=zh-hk" end
    end
  end
  -- demographic
  if type(extras.demographic) == "table" then
    for _, d in ipairs(extras.demographic) do
      url = url .. "&publicationDemographic[]=" .. urlencode(d)
    end
  end
  -- tag include/exclude AND-OR modes
  if extras.includedTagsMode == "OR" or extras.includedTagsMode == "AND" then
    url = url .. "&includedTagsMode=" .. extras.includedTagsMode
  end
  if extras.excludedTagsMode == "OR" or extras.excludedTagsMode == "AND" then
    url = url .. "&excludedTagsMode=" .. extras.excludedTagsMode
  end
  -- tri-state tag selections: genres[slug] = 1 (include) / -1 (exclude)
  for slug, mode in pairs(filters.genres or {}) do
    local id = TAG_IDS[slug]
    if id then
      if mode == 1 then url = url .. "&includedTags[]=" .. id
      elseif mode == -1 then url = url .. "&excludedTags[]=" .. id end
    end
  end
  return parse_list(url)
end

function details(id, opts)
  local j = api_get(API .. "/manga/" .. id
    .. "?includes[]=cover_art&includes[]=author&includes[]=artist")
  local m = j.data
  local a = m.attributes or {}

  local authors = {}
  for _, rel in ipairs(m.relationships or {}) do
    if (rel.type == "author" or rel.type == "artist") and rel.attributes and rel.attributes.name then
      authors[#authors + 1] = rel.attributes.name
    end
  end
  local genres = {}
  for _, t in ipairs(a.tags or {}) do
    local n = t.attributes and t.attributes.name and t.attributes.name.en
    if n then genres[#genres + 1] = n end
  end
  local desc = ""
  if a.description then desc = a.description.en or first_val(a.description) or "" end

  -- Chapter feed: selected languages (opts.langs; empty = all). When more than
  -- one language is in play (multi-select OR the all-languages default) tag each
  -- entry with its language and de-dup per language.
  local wanted = eff_langs(opts)
  local many = (#wanted ~= 1)   -- 0 (=all) or >1 both mean multi-language
  local lang_qs = ""
  for _, l in ipairs(wanted) do lang_qs = lang_qs .. "&translatedLanguage[]=" .. urlencode(api_lang(l)) end

  local chapters = {}
  local offset = 0
  local limit = 100
  for _ = 1, 20 do
    local furl = API .. "/manga/" .. id .. "/feed?limit=" .. limit
      .. "&offset=" .. offset
      .. lang_qs
      .. "&order[chapter]=desc"
      .. "&contentRating[]=safe&contentRating[]=suggestive"
      .. "&contentRating[]=erotica&contentRating[]=pornographic"
      .. "&includes[]=scanlation_group"
    local fj = api_get(furl)
    for _, c in ipairs(fj.data or {}) do
      local ca = c.attributes or {}
      if not ca.externalUrl then
        local num = ca.chapter
        local grp = nil
        for _, rel in ipairs(c.relationships or {}) do
          if rel.type == "scanlation_group" and rel.attributes then grp = rel.attributes.name end
        end
        local name
        if num and num ~= "" then name = "Chapter " .. num else name = ca.title or "Oneshot" end
        if ca.title and ca.title ~= "" and num and num ~= "" then name = name .. " - " .. ca.title end
        if many and ca.translatedLanguage then name = name .. " [" .. ca.translatedLanguage .. "]" end
        if grp then name = name .. "  \u{00b7} " .. grp end
        chapters[#chapters + 1] = {
          id = c.id,
          name = name,
          number = num and tonumber(num) or nil,
          url = SITE .. "/chapter/" .. c.id,
          date = ca.publishAt and util.date_parse(ca.publishAt) or nil,
          lang = ca.translatedLanguage or nil,
        }
      end
    end
    offset = offset + limit
    if offset >= (fj.total or 0) then break end
  end

  -- de-dup by chapter number + language, keeping the first (newest group).
  local seen = {}
  local uniq = {}
  for _, c in ipairs(chapters) do
    local k = (c.number == nil and c.id or ("n" .. tostring(c.number))) .. "|" .. (c.lang or "")
    if not seen[k] then seen[k] = true; uniq[#uniq + 1] = c end
  end

  return {
    title = pick_title(a),
    cover = cover_url(m),
    author = authors[1] or "Unknown",
    status = a.status or "",
    genres = genres,
    description = desc,
    url = SITE .. "/title/" .. id,
    chapters = uniq,
  }
end

function pages(chapter_id, opts)
  local j = api_get(API .. "/at-home/server/" .. chapter_id)
  local base = j.baseUrl
  local hash = j.chapter and j.chapter.hash
  local data = (j.chapter and j.chapter.data) or {}
  local urls = {}
  for _, f in ipairs(data) do urls[#urls + 1] = base .. "/data/" .. hash .. "/" .. f end
  return { pages = urls, referer = SITE .. "/" }
end

function url_for(id)
  return SITE .. "/title/" .. id
end
