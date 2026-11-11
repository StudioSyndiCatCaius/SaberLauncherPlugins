-- PlayLog: remembers every game you insert (discs and ROMs) with a timestamp, and shows
-- your recent history and most-played games. Stored as plain text in <plugin>/history.txt
-- (one "time<TAB>platform<TAB>serial<TAB>title" line per insert). Works offline.

local HISTORY = PLUGIN_DIR .. "/history.txt"
local startup = true -- on_disc also fires for discs already in at startup

local function load()
    local rows = {}
    local f = io.open(HISTORY, "r")
    if not f then return rows end
    for line in f:lines() do
        local t, platform, serial, title = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if t then table.insert(rows, { time = tonumber(t), platform = platform, serial = serial, title = title }) end
    end
    f:close()
    return rows
end

local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]", " ")) end

local function record(game)
    local f = io.open(HISTORY, "a")
    if not f then return end
    local title = game.title ~= "" and game.title or (game.file or game.serial or "?")
    f:write(string.format("%d\t%s\t%s\t%s\n", os.time(), clean(game.platform), clean(game.serial), clean(title)))
    f:close()
end

local function key(r) return r.serial ~= "" and r.serial or r.title end

local function ago(t)
    local d = os.time() - t
    if d < 3600 then return string.format("%d min ago", d // 60) end
    if d < 86400 then return string.format("%d h ago", d // 3600) end
    if d < 86400 * 60 then return string.format("%d days ago", d // 86400) end
    return os.date("%Y-%m-%d", t)
end

local function show_recent()
    local rows = load()
    if #rows == 0 then return "Nothing played yet" end
    local items, seen = {}, {}
    for i = #rows, 1, -1 do
        local r = rows[i]
        if not seen[key(r)] then
            seen[key(r)] = true
            table.insert(items, {
                name = r.title,
                description = string.format("%s %s - %s", r.platform:upper(), r.serial, ago(r.time)),
            })
            if #items >= 25 then break end
        end
    end
    Dialog_Menu("Recently played", items)
end

local function show_top()
    local rows = load()
    if #rows == 0 then return "Nothing played yet" end
    local counts, list = {}, {}
    for _, r in ipairs(rows) do
        local k = key(r)
        if not counts[k] then
            counts[k] = { title = r.title, platform = r.platform, n = 0, last = 0 }
            table.insert(list, counts[k])
        end
        counts[k].n = counts[k].n + 1
        counts[k].last = math.max(counts[k].last, r.time)
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.last > b.last
    end)
    local items = {}
    for i = 1, math.min(#list, 15) do
        local c = list[i]
        table.insert(items, {
            name = string.format("%d. %s", i, c.title),
            description = string.format("%s - inserted %d time%s, last %s", c.platform:upper(), c.n, c.n == 1 and "" or "s", ago(c.last)),
        })
    end
    Dialog_Menu("Most played", items)
end

local function stats()
    local rows = load()
    if #rows == 0 then return "Nothing played yet" end
    local games, platforms = {}, {}
    local ngames = 0
    for _, r in ipairs(rows) do
        if not games[key(r)] then games[key(r)] = true ngames = ngames + 1 end
        platforms[r.platform] = (platforms[r.platform] or 0) + 1
    end
    local parts = {}
    for p, n in pairs(platforms) do table.insert(parts, string.format("%s: %d", p ~= "" and p:upper() or "Other", n)) end
    table.sort(parts)
    Dialog_Info(string.format("%d inserts of %d different games since %s.\n\n%s",
        #rows, ngames, os.date("%Y-%m-%d", rows[1].time), table.concat(parts, "\n")))
end

return {
    name = "PlayLog",
    version = "1.0",
    author = "Saber",
    description = "Keeps a history of the games you insert and shows your recently and most played games. Works offline.",

    settings = {
        startup = {
            name = "Count Discs At Startup",
            description = "Also log games that are already inserted when Saber starts",
            type = "boolean",
            default = false,
            order = 1,
        },
    },

    actions = {
        recent = { name = "Recently Played", description = "The last 25 different games", Do = show_recent },
        top = { name = "Most Played", description = "Your top 15 by number of inserts", Do = show_top },
        stats = { name = "Statistics", description = "Totals per platform", Do = stats },
        clear = {
            name = "Clear History",
            description = "Delete the play log",
            Do = function()
                Dialog_Info("Delete the whole play history?", { "Delete", "Cancel" }, function(index)
                    if index == 1 then
                        os.remove(HISTORY)
                        saber.log("history cleared")
                    end
                end)
            end,
        },
    },

    on_scan = function()
        -- the first scan's on_disc calls are the startup ones; after it, inserts are real
        startup = false
    end,

    on_disc = function(game)
        if startup and not Setting("startup") then return end
        record(game)
    end,
}
