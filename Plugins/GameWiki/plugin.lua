-- GameWiki: shows the Wikipedia summary of the games that are inserted right now.
-- Uses Wikipedia's public REST API (text is CC BY-SA, attributed in the dialog):
--   https://en.wikipedia.org/w/api.php?action=opensearch   (title -> article)
--   https://en.wikipedia.org/api/rest_v1/page/summary/<article>
-- Summaries are cached in <plugin>/cache/ so they also show offline later.
-- Needs Online Mode (Settings) for the first lookup of each game.

local API = "https://en.wikipedia.org"
local cache = {} -- key -> summary text (this session)

local function urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Minimal JSON string decoding for the few fields we read.
local function unescape(s)
    s = s:gsub("\\u(%x%x%x%x)", function(h)
        local n = tonumber(h, 16)
        if n < 0x80 then return string.char(n) end
        if n < 0x800 then return string.char(0xC0 | (n >> 6), 0x80 | (n & 0x3F)) end
        return string.char(0xE0 | (n >> 12), 0x80 | ((n >> 6) & 0x3F), 0x80 | (n & 0x3F))
    end)
    s = s:gsub('\\(["\\/bfnrt])', { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "", f = "", n = "\n", r = "", t = " " })
    return s
end

local function json_field(body, field)
    local v = body:match('"' .. field .. '"%s*:%s*"(.-[^\\])"')
    return v and unescape(v)
end

local function cache_path(key) return PLUGIN_DIR .. "/cache/" .. key:gsub("[^%w%-]", "_") .. ".txt" end

local function read_cache(key)
    if cache[key] then return cache[key] end
    local f = io.open(cache_path(key), "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    cache[key] = text
    return text
end

local function write_cache(key, text)
    cache[key] = text
    local f = io.open(cache_path(key), "w")
    if f then f:write(text) f:close() end
end

local function game_key(g) return g.serial ~= "" and g.serial or g.title end

local PLATFORM_HINT = {
    ps1 = "PlayStation", ps2 = "PlayStation 2", psp = "PSP", dc = "Dreamcast", nes = "NES", snes = "SNES",
    gb = "Game Boy", gbc = "Game Boy Color", gba = "Game Boy Advance", n64 = "Nintendo 64", nds = "Nintendo DS",
    md = "Genesis", sms = "Master System", gg = "Game Gear", pce = "TurboGrafx-16", a2600 = "Atari 2600",
}

-- Cleans a disc title for searching: drops "(USA)", "[!]", "Disc 1" and the like.
local function search_title(title)
    title = title:gsub("%b()", ""):gsub("%b[]", ""):gsub("[Dd]isc %d+", "")
    return (title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function show(g, text)
    Dialog_Info(string.format("%s\n\n%s\n\n(From Wikipedia, CC BY-SA)", g.title, text))
end

local function search(query, cb)
    Http_Get(API .. "/w/api.php?action=opensearch&limit=1&namespace=0&format=json&search=" .. urlencode(query),
        function(ok, body)
            -- opensearch: ["query", ["Article"], [""], ["https://..."]]
            local article = ok and body:match('^%[%s*".-"%s*,%s*%[%s*"(.-[^\\])"')
            cb(article and unescape(article))
        end)
end

-- title -> opensearch (with, then without the platform hint) -> summary; calls done(text | nil, err)
local function lookup(g, done)
    local q = search_title(g.title)
    if q == "" then return done(nil, "This game has no title to look up") end
    local function summary(article)
        if not article then return done(nil, "No Wikipedia article found for " .. q) end
        Http_Get(API .. "/api/rest_v1/page/summary/" .. urlencode(article:gsub(" ", "_")), function(ok, body)
            local extract = ok and json_field(body, "extract")
            if not extract then return done(nil, "No summary for " .. article) end
            done(extract)
        end)
    end
    search(q .. " " .. (PLATFORM_HINT[g.platform] or "") .. " video game", function(article)
        if article then return summary(article) end
        search(q, summary)
    end)
end

local function about(g)
    local key = game_key(g)
    local text = read_cache(key)
    if text then return show(g, text) end
    if not Online() then return "Turn on Online Mode to look this game up" end
    lookup(g, function(extract, err)
        if not extract then
            Dialog_Info(err)
            return
        end
        write_cache(key, extract)
        show(g, extract)
    end)
    return "Looking up " .. g.title .. "..."
end

local prefetching = {}

return {
    name = "GameWiki",
    version = "1.0",
    author = "Saber",
    description = "Shows what Wikipedia says about the games you have inserted. " ..
        "Summaries are cached so they still show offline. Text from Wikipedia (CC BY-SA).",

    settings = {
        prefetch = {
            name = "Fetch On Insert",
            description = "Look up summaries in the background when a game is inserted (Online Mode)",
            type = "boolean",
            default = true,
            order = 1,
        },
    },

    actions = {
        about = {
            name = "About Inserted Games",
            description = "Pick an inserted game to read its Wikipedia summary",
            Do = function()
                local games = Disc_Games()
                if #games == 0 then return "No identified games are inserted" end
                if #games == 1 then return about(games[1]) end
                local items = {}
                for _, g in ipairs(games) do
                    table.insert(items, {
                        name = g.title,
                        description = (g.platform or ""):upper() .. " " .. g.serial ..
                            (read_cache(game_key(g)) and "  (cached)" or ""),
                        Do = function() return about(g) end,
                    })
                end
                Dialog_Menu("Which game?", items)
            end,
        },
        clear = {
            name = "Clear Cache",
            description = "Forget downloaded summaries",
            Do = function()
                local n = 0
                for _, f in ipairs(List_Dir("cache")) do
                    if f:match("%.txt$") and os.remove(PLUGIN_DIR .. "/cache/" .. f) then n = n + 1 end
                end
                cache = {}
                return string.format("Removed %d cached summaries", n)
            end,
        },
    },

    on_disc = function(game)
        if not Setting("prefetch") or not Online() then return end
        local key = game_key(game)
        if read_cache(key) or prefetching[key] then return end
        prefetching[key] = true
        lookup(game, function(extract, err)
            prefetching[key] = nil
            if extract then write_cache(key, extract) else saber.log(tostring(err)) end
        end)
    end,
}
