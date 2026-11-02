-- SaveVault: snapshots Saber's emulator saves (memory cards + save states) so a bad save,
-- a corrupted card or an accidental overwrite can be rolled back.
--   source: APP/libretro/saves/<platform>/
--   backups: <plugin>/backups/<stamp>__<platform>__<file>   (flat, List_Dir only lists files)
-- Works offline. PS2 (LRPS2) keeps its cards in libretro/system/pcsx2/memcards, also backed up.

local SAVES_DIR = SABER_DIR .. "/libretro/saves"
local BACKUP_DIR = PLUGIN_DIR .. "/backups"

local SOURCES = {}
for _, p in ipairs({ "ps1", "ps2", "psp", "dc", "nes", "snes", "gb", "gbc", "gba", "n64", "nds", "md", "sms", "gg", "pce", "a2600" }) do
    table.insert(SOURCES, { key = p, dir = SAVES_DIR .. "/" .. p })
end
table.insert(SOURCES, { key = "pcsx2cards", dir = SABER_DIR .. "/libretro/system/pcsx2/memcards" })

local KEEP_OPTIONS = { "5", "10", "25", "Unlimited" }

local function copy(src, dst)
    local i = io.open(src, "rb")
    if not i then return false end
    local data = i:read("a")
    i:close()
    local o = io.open(dst, "wb")
    if not o then return false end
    o:write(data)
    o:close()
    return true
end

-- Makes sure the backups folder exists (it ships with a .keep file; recreated if deleted).
local function ensure_dir()
    local probe = io.open(BACKUP_DIR .. "/.keep", "ab")
    if probe then probe:close() return true end
    -- folder missing: recreate it (may flash a console window once)
    os.execute('mkdir "' .. BACKUP_DIR:gsub("/", "\\") .. '" 2>nul')
    probe = io.open(BACKUP_DIR .. "/.keep", "ab")
    if probe then probe:close() return true end
    return false
end

-- stamps sorted newest first, each { stamp, files = { {platform, name, path} } }
local function list_backups()
    local by_stamp, order = {}, {}
    for _, f in ipairs(List_Dir(BACKUP_DIR)) do
        local stamp, platform, name = f:match("^(%d+%-%d+)__([%w]+)__(.+)$")
        if stamp then
            if not by_stamp[stamp] then
                by_stamp[stamp] = { stamp = stamp, files = {} }
                table.insert(order, stamp)
            end
            table.insert(by_stamp[stamp].files, { platform = platform, name = name, path = BACKUP_DIR .. "/" .. f })
        end
    end
    table.sort(order, function(a, b) return a > b end)
    local list = {}
    for _, s in ipairs(order) do table.insert(list, by_stamp[s]) end
    return list
end

local function pretty(stamp)
    local y, mo, d, h, mi, s = stamp:match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)$")
    if not y then return stamp end
    return string.format("%s-%s-%s %s:%s:%s", y, mo, d, h, mi, s)
end

local function prune()
    local keep = tonumber(Setting("keep") or "")
    if not keep then return 0 end
    local removed = 0
    for i, b in ipairs(list_backups()) do
        if i > keep then
            for _, f in ipairs(b.files) do os.remove(f.path) end
            removed = removed + 1
        end
    end
    return removed
end

local function backup(reason)
    if not ensure_dir() then return "Could not create " .. BACKUP_DIR end
    local stamp = os.date("%Y%m%d-%H%M%S")
    local count = 0
    for _, src in ipairs(SOURCES) do
        for _, name in ipairs(List_Dir(src.dir)) do
            if copy(src.dir .. "/" .. name, string.format("%s/%s__%s__%s", BACKUP_DIR, stamp, src.key, name)) then
                count = count + 1
            end
        end
    end
    if count == 0 then return "No saves found yet" end
    local pruned = prune()
    saber.log(string.format("backup %s (%s): %d files, pruned %d", stamp, reason, count, pruned))
    return string.format("Backed up %d save files", count)
end

local function source_dir(key)
    for _, s in ipairs(SOURCES) do
        if s.key == key then return s.dir end
    end
end

local function restore(b)
    -- safety net: snapshot the current saves before overwriting them
    backup("before restore")
    local ok, failed = 0, 0
    for _, f in ipairs(b.files) do
        local dir = source_dir(f.platform)
        if dir and copy(f.path, dir .. "/" .. f.name) then ok = ok + 1 else failed = failed + 1 end
    end
    local msg = string.format("Restored %d files from %s", ok, pretty(b.stamp))
    if failed > 0 then msg = msg .. string.format(" (%d failed: is the platform's save folder there?)", failed) end
    Dialog_Info(msg)
end

local function choose_restore()
    local list = list_backups()
    if #list == 0 then return "No backups yet" end
    local items = {}
    for _, b in ipairs(list) do
        local platforms, seen = {}, {}
        for _, f in ipairs(b.files) do
            if not seen[f.platform] then seen[f.platform] = true table.insert(platforms, f.platform) end
        end
        table.insert(items, {
            name = pretty(b.stamp),
            description = string.format("%d files: %s", #b.files, table.concat(platforms, ", ")),
            Do = function()
                Dialog_Info("Restore the saves from " .. pretty(b.stamp) .. "?\nYour current saves are backed up first.",
                    { "Restore", "Cancel" }, function(index)
                        if index == 1 then restore(b) end
                    end)
            end,
        })
    end
    Dialog_Menu("Pick a backup to restore.", items)
end

local last_auto = 0

return {
    name = "SaveVault",
    version = "1.0",
    author = "Saber",
    description = "Snapshots your memory cards and save states so you can roll back a broken save. " ..
        "Backups are kept in this plugin's backups folder. Works offline.",

    settings = {
        auto = {
            name = "Back Up On Disc Insert",
            description = "Take a snapshot whenever a game is inserted (at most once every 10 minutes)",
            type = "boolean",
            default = true,
            order = 1,
        },
        keep = {
            name = "Backups To Keep",
            description = "Oldest snapshots are deleted past this number",
            type = "enum",
            options = KEEP_OPTIONS,
            default = 2,
            order = 2,
        },
    },

    actions = {
        backup = {
            name = "Back Up Now",
            description = "Copy every memory card and save state into a new snapshot",
            Do = function() return backup("manual") end,
        },
        restore = {
            name = "Restore a Backup...",
            description = "Pick a snapshot; current saves are backed up first",
            Do = choose_restore,
        },
        info = {
            name = "Backup Info",
            description = "How many snapshots exist and when the last one was taken",
            Do = function()
                local list = list_backups()
                if #list == 0 then return "No backups yet" end
                local files = 0
                for _, b in ipairs(list) do files = files + #b.files end
                return string.format("%d snapshots (%d files), newest %s", #list, files, pretty(list[1].stamp))
            end,
        },
    },

    on_disc = function(game)
        if not Setting("auto") then return end
        local now = os.time()
        if now - last_auto < 600 then return end
        last_auto = now
        backup("disc " .. (game.serial ~= "" and game.serial or game.title))
    end,
}
