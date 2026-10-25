-- Author photos for the Authors view, found online and kept on the device.
--
-- Only ever user-initiated (an author's hold menu, or the Authors view's
-- "Find missing author images"): no request leaves the device on its own.
--
-- Sources, in order:
--
--   1. Open Library. /search/authors.json finds the author; among the results
--      whose name matches, the one with the most works is taken, which picks
--      the novelist over the namesake with one pamphlet. Its photo is
--      covers.openlibrary.org's /a/olid/<id>-L.jpg, asked for with
--      default=false so a missing photo is a 404 rather than a placeholder.
--   2. Wikipedia, when Open Library has the author but no photo, or does not
--      have them. The lead image of the page titled with the name (or "<name>
--      (writer)" and so on), and only when the page's short description says
--      the person writes: never a footballer of the same name.
--
-- Photos are saved as <data dir>/zen-author-images/<author>.jpg. A picture
-- placed there by hand (jpg, jpeg or png) is used the same way.
--
-- Placeholder names (Anonymous, Various, Unknown) are never looked up: both
-- sources have records for them, and none of those is a person.

local Http = require("modules/filebrowser/metadata/http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("common/zen_logger").new("author_images")

local M = {}

local OL_HOST = "openlibrary.org"
local OL_SEARCH = "https://openlibrary.org/search/authors.json?limit=10"
    .. "&fields=key,name,alternate_names,work_count&q="
local OL_PHOTO = "https://covers.openlibrary.org/a/olid/%s-L.jpg?default=false"
local WP_HOST = "en.wikipedia.org"
local WP_API = "https://en.wikipedia.org/w/api.php?action=query&format=json"
    .. "&formatversion=2&redirects=1&prop=pageimages%7Cdescription%7Cpageprops"
    .. "&ppprop=disambiguation&piprop=thumbnail&pithumbsize=500&titles="
-- Hosts Wikipedia serves lead-image thumbnails from.
local WP_IMAGE_HOSTS = { "thumb.wikimedia.org", "upload.wikimedia.org" }
local JSON_HEADERS = { ["Accept"] = "application/json" }
local IMAGE_HEADERS = { ["Accept"] = "image/jpeg, image/png, image/webp, image/gif" }

-- A photo smaller than this is an error page or a 1px placeholder.
local MIN_BYTES = 2000
-- Lookup order for a saved or hand-placed picture.
local EXTENSIONS = { "jpg", "jpeg", "png" }
-- Every extension removed before a new photo is saved, so the old one cannot
-- shadow it.
local OTHER_EXTS = { "jpg", "jpeg", "png", "gif", "webp" }
local LISTING_TTL_S = 2

-- ---------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------

-- Latin letters with diacritics, folded to their base letter so that a
-- library's "Stanislaw Lem" matches Open Library's "Stanisław Lem".
local FOLD = {
    ["à"]="a", ["á"]="a", ["â"]="a", ["ã"]="a", ["ä"]="a", ["å"]="a", ["ā"]="a", ["ă"]="a", ["ą"]="a",
    ["ç"]="c", ["ć"]="c", ["č"]="c",
    ["ď"]="d", ["đ"]="d",
    ["è"]="e", ["é"]="e", ["ê"]="e", ["ë"]="e", ["ē"]="e", ["ė"]="e", ["ę"]="e", ["ě"]="e",
    ["ğ"]="g",
    ["ì"]="i", ["í"]="i", ["î"]="i", ["ï"]="i", ["ī"]="i", ["ı"]="i",
    ["ł"]="l", ["ľ"]="l",
    ["ñ"]="n", ["ń"]="n", ["ň"]="n",
    ["ò"]="o", ["ó"]="o", ["ô"]="o", ["õ"]="o", ["ö"]="o", ["ø"]="o", ["ō"]="o", ["ő"]="o",
    ["ř"]="r",
    ["ś"]="s", ["š"]="s", ["ş"]="s", ["ß"]="ss",
    ["ť"]="t", ["ţ"]="t",
    ["ù"]="u", ["ú"]="u", ["û"]="u", ["ü"]="u", ["ū"]="u", ["ů"]="u", ["ű"]="u",
    ["ý"]="y", ["ÿ"]="y",
    ["ź"]="z", ["ż"]="z", ["ž"]="z",
    ["æ"]="ae", ["œ"]="oe",
}
-- Upper-case forms Lua's lower() leaves alone (it only knows ASCII).
local UPPER = {
    ["À"]="à", ["Á"]="á", ["Â"]="â", ["Ã"]="ã", ["Ä"]="ä", ["Å"]="å", ["Ā"]="ā", ["Ą"]="ą",
    ["Ç"]="ç", ["Ć"]="ć", ["Č"]="č", ["Ď"]="ď", ["Đ"]="đ",
    ["È"]="è", ["É"]="é", ["Ê"]="ê", ["Ë"]="ë", ["Ę"]="ę", ["Ě"]="ě",
    ["Ì"]="ì", ["Í"]="í", ["Î"]="î", ["Ï"]="ï", ["İ"]="i",
    ["Ł"]="ł", ["Ñ"]="ñ", ["Ń"]="ń", ["Ň"]="ň",
    ["Ò"]="ò", ["Ó"]="ó", ["Ô"]="ô", ["Õ"]="õ", ["Ö"]="ö", ["Ø"]="ø", ["Ő"]="ő",
    ["Ř"]="ř", ["Ś"]="ś", ["Š"]="š", ["Ş"]="ş", ["Ť"]="ť",
    ["Ù"]="ù", ["Ú"]="ú", ["Û"]="û", ["Ü"]="ü", ["Ů"]="ů", ["Ű"]="ű",
    ["Ý"]="ý", ["Ź"]="ź", ["Ż"]="ż", ["Ž"]="ž", ["Æ"]="æ", ["Œ"]="œ",
}

-- fold(s) -> a comparison key: lower case, diacritics folded, every run of
-- anything that is not a letter or digit turned into one space.
function M.fold(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[\xC3-\xC5][\x80-\xBF]", function(c) return UPPER[c] or c end)
    s = s:lower()
    s = s:gsub("[\xC3-\xC5][\x80-\xBF]", function(c) return FOLD[c] or c end)
    s = s:gsub("[%c%p%s]+", " ")
    return (s:gsub("^ +", ""):gsub(" +$", ""))
end

-- fold() with the spaces removed too, so initials match however they are
-- spaced ("H. P." / "H.P." / "HP").
local function match_key(s) return (M.fold(s):gsub(" ", "")) end
M.matchKey = match_key

local PLACEHOLDERS = {
    anonymous = true, anon = true, various = true, ["various authors"] = true,
    unknown = true, ["unknown author"] = true, ["author unknown"] = true,
    ["n a"] = true, none = true, ["no author"] = true,
}

function M.isPlaceholder(name)
    local folded = M.fold(name)
    return folded == "" or PLACEHOLDERS[folded] == true
end

-- queryName(name) -> how to search for it. "Osman, Richard" is searched as
-- "Richard Osman"; with more than one comma the name is left alone.
function M.queryName(name)
    if type(name) ~= "string" then return "" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local last, first = name:match("^([^,]+),%s*([^,]+)$")
    if last and first then return first .. " " .. last end
    return name
end

-- ---------------------------------------------------------------------
-- Picking from what the sources return
-- ---------------------------------------------------------------------

-- pickOpenLibrary(docs, name) -> the doc whose name or alternate name is the
-- author's, with the most works; nil when none matches.
function M.pickOpenLibrary(docs, name)
    if type(docs) ~= "table" then return nil end
    local want = match_key(M.queryName(name))
    if want == "" then return nil end
    local best, best_n
    for _i, doc in ipairs(docs) do
        if type(doc) == "table" and type(doc.key) == "string" then
            local hit = match_key(doc.name) == want
            if not hit and type(doc.alternate_names) == "table" then
                for _j, alternate in ipairs(doc.alternate_names) do
                    if match_key(alternate) == want then hit = true; break end
                end
            end
            local works = tonumber(doc.work_count) or 0
            if hit and works > 0 and (not best_n or works > best_n) then
                best, best_n = doc, works
            end
        end
    end
    return best
end

-- Words in a Wikipedia short description that mean the person writes.
local WRITER_WORDS = {
    "writer", "novelist", "author", "poet", "playwright", "dramatist",
    "essayist", "journalist", "historian", "philosopher", "screenwriter",
    "illustrator", "cartoonist", "humorist", "humourist", "satirist",
    "critic", "scholar", "storyteller", "fabulist", "diarist", "memoirist",
    "biographer", "lyricist", "librettist", "translator", "comics",
}

local function is_writer(description)
    if type(description) ~= "string" or description == "" then return false end
    local words = " " .. description:lower():gsub("[^%a]+", " ") .. " "
    for _i, word in ipairs(WRITER_WORDS) do
        if words:find(" " .. word .. "s? ") then return true end
    end
    return false
end
M.isWriterDescription = is_writer

-- wikimediaHost(url) -> the Wikimedia image host the url is on, or nil.
local function wikimedia_host(url)
    if type(url) ~= "string" then return nil end
    for _i, host in ipairs(WP_IMAGE_HOSTS) do
        if url:sub(1, #host + 9) == "https://" .. host .. "/" then return host end
    end
    return nil
end

-- pickWikipedia(response) -> thumbnail url, page title | nil. The page must
-- exist, not be a disambiguation page, describe a writer, and have a lead
-- image served from Wikimedia.
function M.pickWikipedia(response)
    local pages = type(response) == "table" and type(response.query) == "table"
        and response.query.pages
    if type(pages) ~= "table" then return nil end
    for _i, page in ipairs(pages) do
        if type(page) == "table" and not page.missing and not page.invalid
                and not (type(page.pageprops) == "table"
                    and page.pageprops.disambiguation ~= nil)
                and is_writer(page.description)
                and type(page.thumbnail) == "table"
                and wikimedia_host(page.thumbnail.source) then
            return page.thumbnail.source, page.title
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Where photos live
-- ---------------------------------------------------------------------

local dir_override

function M.dir()
    if dir_override then return dir_override end
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/zen-author-images"
end

-- For specs: point the store somewhere disposable.
function M._setDir(dir)
    dir_override = dir
    M.invalidate()
end

-- Characters FAT and exFAT refuse in a file name.
local function safe_stem(s)
    if type(s) ~= "string" or s == "" then return nil end
    if s:find('[%c/\\:%*%?"<>|]') then return nil end
    if s:match("^%.") or s:match("[%. ]$") then return nil end
    return s
end

-- fileStem(name) -> the file name (without extension) for an author: the
-- name as shown when that is a valid file name, otherwise a slug of it.
function M.fileStem(name)
    local exact = safe_stem(name)
    if exact then return exact end
    if type(name) ~= "string" then return nil end
    local slug = name:lower():gsub("[,;:./%s_\\]+", "-")
    slug = slug:gsub('[%c%*%?"<>|]', "")
    slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
    return safe_stem(slug)
end

-- Lower-cased file name -> real file name, refreshed when the folder changes.
-- Tiles ask for every visible author on every repaint; one listing answers
-- them all.
local listing = { names = nil, modification = nil, checked_at = nil }

function M.invalidate()
    listing.names, listing.modification, listing.checked_at = nil, nil, nil
end

local function names_in_dir(dir)
    local modification = lfs.attributes(dir, "modification")
    if not modification then return {} end
    local now = os.time()
    if listing.names and listing.modification == modification
            and listing.dir == dir
            and now - listing.checked_at < LISTING_TTL_S then
        return listing.names
    end
    local names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok and type(iter) == "function" then
        for file in iter, dir_obj do
            if file:sub(1, 1) ~= "." then names[file:lower()] = file end
        end
    end
    listing.names, listing.modification = names, modification
    listing.checked_at, listing.dir = now, dir
    return names
end

-- path(name) -> the saved photo for an author, or nil.
function M.path(name)
    if type(name) ~= "string" or name == "" then return nil end
    local stem = M.fileStem(name)
    if not stem then return nil end
    local dir = M.dir()
    local names = names_in_dir(dir)
    local lower = stem:lower()
    for _i, extension in ipairs(EXTENSIONS) do
        local file = names[lower .. "." .. extension]
        if file then return dir .. "/" .. file end
    end
    return nil
end

function M.has(name)
    return M.path(name) ~= nil
end

-- remove(name) -> true when a photo was removed.
function M.remove(name)
    local stem = M.fileStem(name)
    if not stem then return false end
    local dir = M.dir()
    local removed = false
    for _i, extension in ipairs(OTHER_EXTS) do
        if os.remove(dir .. "/" .. stem .. "." .. extension) then removed = true end
    end
    M.invalidate()
    return removed
end

-- missing(names) -> the names worth looking up: not a placeholder, no photo.
function M.missing(names)
    local result = {}
    for _i, name in ipairs(names or {}) do
        if type(name) == "string" and not M.isPlaceholder(name) and not M.has(name) then
            result[#result + 1] = name
        end
    end
    return result
end

-- ---------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------

local function escape(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- A source "answered" when a server replied at all, even with an error
-- status: only no reply means the connection is gone.
local function answered(data, err)
    return data ~= nil or (type(err) == "table" and err.status ~= nil)
end

-- findOpenLibrary(name, transport) -> url | nil, answered. The url may still
-- 404: Open Library knows many authors it has no photo of.
function M.findOpenLibrary(name, transport)
    local data, err = Http.getJson(OL_SEARCH .. escape(M.queryName(name)),
        OL_HOST, JSON_HEADERS, transport)
    if type(data) ~= "table" then return nil, answered(data, err) end
    local doc = M.pickOpenLibrary(data.docs, name)
    local olid = doc and doc.key:match("([^/]+)$")
    if olid and olid:match("^OL%d+A$") then
        return string.format(OL_PHOTO, olid), true
    end
    return nil, true
end

-- findWikipedia(name, transport) -> url | nil, answered. Each suffixed title
-- is tried only when the one before found nothing that describes a writer.
function M.findWikipedia(name, transport)
    local query = M.queryName(name)
    local any_answer = false
    for _i, title in ipairs({ query, query .. " (writer)", query .. " (author)",
            query .. " (novelist)" }) do
        local data, err = Http.getJson(WP_API .. escape(title), WP_HOST,
            JSON_HEADERS, transport)
        any_answer = any_answer or answered(data, err)
        if type(data) == "table" then
            local url = M.pickWikipedia(data)
            if url then return url, true end
            -- The page is this writer, just without a picture: the suffixed
            -- titles would only find someone else.
            local page = type(data.query) == "table" and type(data.query.pages) == "table"
                and data.query.pages[1]
            if type(page) == "table" and not page.missing and is_writer(page.description) then
                break
            end
        end
    end
    return nil, any_answer
end

-- What the bytes are, whatever the URL said.
local function sniff(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local head = file:read(12) or ""
    file:close()
    if head:sub(1, 3) == "\xFF\xD8\xFF" then return "jpg" end
    if head:sub(1, 8) == "\x89PNG\r\n\x1A\n" then return "png" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return "webp" end
    if head:sub(1, 3) == "GIF" then return "gif" end
    return nil
end

local function size(path)
    return lfs.attributes(path, "size") or 0
end

-- A JPEG this size or smaller is kept as it came. Open Library's are 15-90 KB.
M.KEEP_JPEG_BYTES = 150 * 1024
M.JPEG_QUALITY = 85

-- maxSide() -> the longest side worth keeping: half the screen's long side,
-- never below 600. Both sources top out near 500 px.
function M.maxSide()
    local ok, Device = pcall(require, "device")
    local screen = ok and Device and Device.screen
    local w = screen and screen.getWidth and screen:getWidth() or 0
    local h = screen and screen.getHeight and screen:getHeight() or 0
    return math.max(600, math.ceil(math.max(w, h) / 2))
end

-- compact(path, ext) -> the file's new extension, rewriting it in place as a
-- JPEG when that is worth it: any PNG, WebP or GIF, a large JPEG, or anything
-- bigger than maxSide(). Keeps what it was given whenever decoding or
-- encoding fails, or the JPEG would not be smaller.
local function compact(path, ext)
    local bytes = size(path)
    local cap = M.maxSide()
    local ok_render, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_render and RenderImage) then return ext end
    local bb = RenderImage:renderImageFile(path, false)
    if not bb then return ext end
    local w, h = bb:getWidth(), bb:getHeight()
    if ext == "jpg" and bytes <= M.KEEP_JPEG_BYTES and math.max(w, h) <= cap then
        bb:free()
        return ext
    end
    if math.max(w, h) > cap then
        local factor = cap / math.max(w, h)
        bb = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(w * factor + 0.5)),
            math.max(1, math.floor(h * factor + 0.5)), true)
        w, h = bb:getWidth(), bb:getHeight()
    end
    -- Flatten onto white first: a JPEG has no alpha. The blend must go onto
    -- RGB32: KOReader's C blitter has no alpha blit into RGB24 and aborts the
    -- whole process on one, which no pcall catches. A plain blit then makes
    -- the RGB24 copy the encoder is given.
    local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
    local out = bb
    local bb_type = ok_bb and Blitbuffer and bb.getType and bb:getType()
    if bb_type == Blitbuffer.TYPE_BB8A then
        -- Grayscale with alpha (a black-and-white portrait cut out on
        -- transparency): onto white grayscale, gray to gray.
        out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        out:fill(Blitbuffer.COLOR_WHITE)
        if out.pmulalphablitFrom then out:pmulalphablitFrom(bb, 0, 0, 0, 0, w, h)
        else out:alphablitFrom(bb, 0, 0, 0, 0, w, h) end
        bb:free()
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        local flat = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        flat:fill(Blitbuffer.COLOR_WHITE)
        if flat.pmulalphablitFrom then flat:pmulalphablitFrom(bb, 0, 0, 0, 0, w, h)
        else flat:alphablitFrom(bb, 0, 0, 0, 0, w, h) end
        bb:free()
        out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB24)
        out:blitFrom(flat, 0, 0, 0, 0, w, h)
        flat:free()
    end
    local tmp = path .. ".jpg"
    local ok_write = out:writeToFile(tmp, "jpg", M.JPEG_QUALITY)
    out:free()
    if ok_write and sniff(tmp) == "jpg" and size(tmp) >= MIN_BYTES and size(tmp) < bytes then
        if os.rename(tmp, path) then return "jpg" end
    end
    pcall(os.remove, tmp)
    return ext
end
M._compact = compact

local function download(url, destination, transport)
    if url:sub(1, #"https://covers.openlibrary.org/") == "https://covers.openlibrary.org/" then
        return require("modules/filebrowser/metadata/open_library")
            .downloadCover(url, destination, transport)
    end
    local host = wikimedia_host(url)
    if not host then return nil, Http.failure("malformed") end
    return Http.download(url, destination, host, IMAGE_HEADERS, transport)
end

-- save(url, dir, stem, transport) -> path | nil. Downloads beside the
-- destination, checks what arrived, compacts it, and only then replaces
-- whatever was saved under the stem before.
local function save(url, dir, stem, transport)
    local tmp = dir .. "/." .. stem .. ".download"
    local got = download(url, tmp, transport)
    local ext = got and sniff(tmp)
    if not got or not ext or size(tmp) < MIN_BYTES then
        pcall(os.remove, tmp)
        return nil
    end
    local ok_compact, new_ext = pcall(compact, tmp, ext)
    if ok_compact and new_ext then ext = new_ext end
    if ext ~= "jpg" and ext ~= "png" then
        -- Only what the tiles can show is kept.
        pcall(os.remove, tmp)
        return nil
    end
    for _i, extension in ipairs(OTHER_EXTS) do
        pcall(os.remove, dir .. "/" .. stem .. "." .. extension)
    end
    local destination = dir .. "/" .. stem .. "." .. ext
    if not os.rename(tmp, destination) then
        pcall(os.remove, tmp)
        return nil
    end
    return destination
end

local function ensure_dir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and lfs.attributes(parent, "mode") ~= "directory" then
        ensure_dir(parent)
    end
    lfs.mkdir(dir)
    return lfs.attributes(dir, "mode") == "directory"
end

-- fetch(name, opts) -> path, source | nil, reason
-- Finds a photo and saves it, replacing any photo already saved for the
-- author. opts.transport / opts.download_transport stub the network (specs).
--   source: "openlibrary" | "wikipedia"
--   reason: "placeholder", "bad name", "no storage", "none" (asked, and
--           there is no photo), or "unreachable" (no source answered at all)
function M.fetch(name, opts)
    opts = opts or {}
    if M.isPlaceholder(name) then return nil, "placeholder" end
    local stem = M.fileStem(name)
    if not stem then return nil, "bad name" end
    local dir = M.dir()
    if not ensure_dir(dir) then return nil, "no storage" end

    local url, ol_answered = M.findOpenLibrary(name, opts.transport)
    if url then
        local path = save(url, dir, stem, opts.download_transport)
        if path then
            M.invalidate()
            return path, "openlibrary"
        end
    end
    local wp_url, wp_answered = M.findWikipedia(name, opts.transport)
    if wp_url then
        local path = save(wp_url, dir, stem, opts.download_transport)
        if path then
            M.invalidate()
            return path, "wikipedia"
        end
    end
    logger.dbg("no photo found answered=", tostring(ol_answered or wp_answered))
    return nil, (ol_answered or wp_answered) and "none" or "unreachable"
end

return M
