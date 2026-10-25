local JSON = require("json")

local JPEG = "\xFF\xD8\xFF\xE0" .. string.rep("j", 4000)
local PNG = "\x89PNG\r\n\x1A\n" .. string.rep("p", 4000)
local HTML = "<!DOCTYPE html>" .. string.rep("h", 4000)
local OL = "https://openlibrary.org/search/authors.json"
local WP = "https://en.wikipedia.org/w/api.php"

local function ol_photo(id)
    return "https://covers.openlibrary.org/a/olid/" .. id .. "-L.jpg?default=false"
end

local function wp_page(page) return { query = { pages = { page } } } end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

local function write(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

describe("author images", function()
    local AuthorImages, dir
    local json_by_prefix, files, requests

    -- Answers a JSON request from the first registered prefix it starts with.
    local function transport(url)
        requests[#requests + 1] = url
        for prefix, data in pairs(json_by_prefix) do
            if url:sub(1, #prefix) == prefix then
                return { status = 200, headers = {}, body = JSON.encode(data) }
            end
        end
        return { status = 404, headers = {}, body = "" }
    end

    local function download_transport(url, destination)
        requests[#requests + 1] = url
        if not files[url] then return nil, { kind = "no_match", status = 404 } end
        write(destination, files[url])
        return destination
    end

    local function fetch(name, override)
        return AuthorImages.fetch(name, {
            transport = override or transport,
            download_transport = download_transport,
        })
    end

    before_each(function()
        ZenSpec.unload("modules/filebrowser/metadata/author_images")
        AuthorImages = require("modules/filebrowser/metadata/author_images")
        dir = os.tmpname()
        os.remove(dir)
        AuthorImages._setDir(dir)
        json_by_prefix, files, requests = {}, {}, {}
    end)

    after_each(function()
        os.execute("rm -rf '" .. dir .. "'")
        AuthorImages._setDir(nil)
    end)

    it("compares names without case, punctuation, spacing or diacritics", function()
        assert.are.equal(AuthorImages.matchKey("Stanislaw Lem"),
            AuthorImages.matchKey("Stanisław Lem"))
        assert.are.equal(AuthorImages.matchKey("H.P. Lovecraft"),
            AuthorImages.matchKey("H. P. Lovecraft"))
        assert.are.equal("emilezola", AuthorImages.matchKey("ÉMILE ZOLA"))
        assert.are_not.equal(AuthorImages.matchKey("Richard Osman"),
            AuthorImages.matchKey("Richard W. Osman"))
    end)

    it("searches Last, First as First Last and skips placeholders", function()
        assert.are.equal("Richard Osman", AuthorImages.queryName("Osman, Richard"))
        assert.are.equal("Smith, Jr., John", AuthorImages.queryName("Smith, Jr., John"))
        for _i, name in ipairs({ "Anonymous", "Various", "Unknown Author", "N/A", "" }) do
            assert.is_true(AuthorImages.isPlaceholder(name), name)
        end
        assert.is_false(AuthorImages.isPlaceholder("Saki"))
    end)

    it("picks the matching Open Library author with the most works", function()
        local docs = {
            { key = "OL9233779A", name = "Becky Chambers BS.MEd.", work_count = 5 },
            { key = "OL16276782A", name = "Becky Chambers", work_count = 1 },
            { key = "OL7387940A", name = "Becky Chambers", work_count = 25 },
        }
        assert.are.equal("OL7387940A", AuthorImages.pickOpenLibrary(docs, "Chambers, Becky").key)
        assert.is_nil(AuthorImages.pickOpenLibrary({
            { key = "OL1A", name = "Becky Chambers", work_count = 0 } }, "Becky Chambers"))
        assert.are.equal("OL3A", AuthorImages.pickOpenLibrary({
            { key = "OL3A", name = "Hector Munro", alternate_names = { "Saki" },
              work_count = 300 } }, "Saki").key)
    end)

    it("accepts only Wikipedia pages that describe a writer with a Wikimedia image", function()
        local thumb = { source = "https://upload.wikimedia.org/x.jpg" }
        assert.are.equal("https://upload.wikimedia.org/x.jpg", AuthorImages.pickWikipedia(
            wp_page{ title = "Saki", description = "British writer (1870-1916)", thumbnail = thumb }))
        assert.is_nil(AuthorImages.pickWikipedia(
            wp_page{ title = "John Smith", description = "English footballer", thumbnail = thumb }))
        assert.is_nil(AuthorImages.pickWikipedia(wp_page{
            title = "John Smith", description = "English writer",
            pageprops = { disambiguation = "" }, thumbnail = thumb }))
        assert.is_nil(AuthorImages.pickWikipedia(wp_page{
            title = "Saki", description = "British writer",
            thumbnail = { source = "https://evil.example/x.jpg" } }))
        assert.is_false(AuthorImages.isWriterDescription("Authority figure"))
    end)

    it("names files after the author, or a slug when that is not a valid file name", function()
        assert.are.equal("Osman, Richard", AuthorImages.fileStem("Osman, Richard"))
        assert.are.equal("ac-dc", AuthorImages.fileStem("AC/DC"))
        assert.is_nil(AuthorImages.fileStem("..."))
    end)

    it("saves Open Library's photo without asking Wikipedia", function()
        json_by_prefix[OL] = { docs = {
            { key = "/authors/OL25712A", name = "Terry Pratchett", work_count = 232 } } }
        files[ol_photo("OL25712A")] = JPEG
        local path, source = fetch("Terry Pratchett")
        assert.are.equal(dir .. "/Terry Pratchett.jpg", path)
        assert.are.equal("openlibrary", source)
        assert.are.equal(path, AuthorImages.path("Terry Pratchett"))
        for _i, url in ipairs(requests) do
            assert.is_nil(url:find(WP, 1, true))
        end
    end)

    it("falls back to Wikipedia when Open Library has no photo", function()
        json_by_prefix[OL] = { docs = { { key = "OL591204A", name = "Saki", work_count = 354 } } }
        json_by_prefix[WP] = wp_page{ title = "Saki", description = "British writer",
            thumbnail = { source = "https://thumb.wikimedia.org/saki.png" } }
        files["https://thumb.wikimedia.org/saki.png"] = PNG
        local path, source = fetch("Saki")
        assert.are.equal(dir .. "/Saki.png", path)
        assert.are.equal("wikipedia", source)
    end)

    it("keeps nothing that is not an image and leaves no partial download", function()
        json_by_prefix[OL] = { docs = { { key = "OL1A", name = "Mick Herron", work_count = 55 } } }
        files[ol_photo("OL1A")] = HTML
        local path, why = fetch("Mick Herron")
        assert.is_nil(path)
        assert.are.equal("none", why)
        assert.is_false(exists(dir .. "/.Mick Herron.download"))
    end)

    it("replaces an older photo in any format, and keeps it when nothing is found", function()
        os.execute("mkdir -p '" .. dir .. "'")
        write(dir .. "/Ann Leckie.png", PNG)
        json_by_prefix[OL] = { docs = { { key = "OL5A", name = "Ann Leckie", work_count = 26 } } }
        files[ol_photo("OL5A")] = JPEG
        assert.are.equal(dir .. "/Ann Leckie.jpg", fetch("Ann Leckie"))
        assert.is_false(exists(dir .. "/Ann Leckie.png"))

        json_by_prefix[OL] = { docs = {} }
        json_by_prefix[WP] = wp_page{ title = "Ann Leckie", description = "American author" }
        local path, why = fetch("Ann Leckie")
        assert.is_nil(path)
        assert.are.equal("none", why)
        assert.is_true(exists(dir .. "/Ann Leckie.jpg"))
    end)

    it("tries '(writer)' only when the plain title is someone else", function()
        files["https://upload.wikimedia.org/js.jpg"] = JPEG
        local wikipedia_calls = 0
        local path, source = fetch("John Smith", function(url)
            if url:find(OL, 1, true) then
                return { status = 200, headers = {}, body = JSON.encode({ docs = {} }) }
            end
            wikipedia_calls = wikipedia_calls + 1
            local data = url:find("%%28writer%%29")
                and wp_page{ title = "John Smith (writer)", description = "English writer",
                    thumbnail = { source = "https://upload.wikimedia.org/js.jpg" } }
                or wp_page{ title = "John Smith", description = "English footballer" }
            return { status = 200, headers = {}, body = JSON.encode(data) }
        end)
        assert.are.equal(dir .. "/John Smith.jpg", path)
        assert.are.equal("wikipedia", source)
        assert.are.equal(2, wikipedia_calls)
    end)

    it("reports unreachable when no source answers, and never looks up placeholders", function()
        local path, why = fetch("Naomi Novik", function() return nil, { kind = "offline" } end)
        assert.is_nil(path)
        assert.are.equal("unreachable", why)

        requests = {}
        path, why = fetch("Anonymous")
        assert.is_nil(path)
        assert.are.equal("placeholder", why)
        assert.are.equal(0, #requests)
    end)

    it("lists authors without a photo and removes saved photos", function()
        os.execute("mkdir -p '" .. dir .. "'")
        write(dir .. "/Saki.jpg", JPEG)
        AuthorImages.invalidate()
        assert.are.same({ "Mick Herron" },
            AuthorImages.missing({ "Saki", "Anonymous", "Mick Herron" }))
        assert.is_true(AuthorImages.remove("Saki"))
        assert.is_nil(AuthorImages.path("Saki"))
    end)
end)
