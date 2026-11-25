-- ModHack: download game mods and ROM hacks.
--
-- Catalog: each source repo's Channels/ModHack/mods/ folder (sources.txt, same format as the Channel
-- Shop; one GitHub tree call per source, cached in SAVE_DIR/cache so the catalog also shows offline).
-- info.toml's shop_exclude = "mods" keeps the Channel Shop from installing the catalog with the channel.
-- The layout mirrors Saber's own mods folder (APP/mods), see MODS.md:
--
--   mods/<platform>/<Game>/gameids.txt      serials / ROM names / CRC32s / titles the game matches
--   mods/<platform>/<Game>/game.ini         optional: name, description, image (web URL, fetched on demand, never saved)
--   mods/<platform>/<Game>/thumbnail.*      optional art (also cover.*)
--   mods/<platform>/<Game>/<Mod>/mod.ini    name, author, version, description, type = soft | hard,
--                                           url (external download), file, homepage, crc
--   mods/<platform>/<Game>/<Mod>/install.lua  optional install script (MODS.md)
--   mods/<platform>/<Game>/<Mod>/...        any other files (a soft mod's mod.lua, a patch...)
--
-- SOFT mods live apart from the game, in APP/mods/<platform>/<Game>/<Mod>/, and Saber loads them when
-- the game starts (the game's Mods menu turns them on / off). HARD mods change the game's own files
-- (ROM patches, files dropped into a PC game folder); ModHack recommends a full copy of the game,
-- under another name, before one is installed, and keeps backups of what it changes in place.
--
-- Installs run as a coroutine resumed once per frame (modkit.lua's K.step() yields), so downloads,
-- copies and patches never freeze Saber. What ModHack installed is in SAVE_DIR/installed.txt.

local K = dofile(CHANNEL_DIR .. "/modkit.lua")

local DEFAULT_SOURCES = { "StudioSyndiCatCaius/SaberLauncherPlugins@main" }
local ROOT = "Channels/ModHack/mods/"
local MODS_DIR = SABER_DIR .. "/mods"
local STAGE = SAVE_DIR .. "/stage"
local CACHE = SAVE_DIR .. "/cache"
local SCRIPTS = SAVE_DIR .. "/scripts"   -- install.lua of installed mods, for Remove
local BACKUPS = SAVE_DIR .. "/backups"   -- files a hard mod replaced in place
local REGISTRY = SAVE_DIR .. "/installed.txt"
local COPYING = SAVE_DIR .. "/copying.txt" -- a game copy in progress (removed on the next start if left)
local WORKERS = 4

local PLATFORMS = {
	pc = "PC", ps1 = "PlayStation", ps2 = "PlayStation 2", ps3 = "PlayStation 3", psp = "PSP",
	nes = "NES", snes = "Super Nintendo", n64 = "Nintendo 64", gc = "GameCube", wii = "Wii",
	gb = "Game Boy", gbc = "Game Boy Color", gba = "Game Boy Advance", nds = "Nintendo DS",
	["3ds"] = "Nintendo 3DS", md = "Mega Drive", sms = "Master System", gg = "Game Gear",
	dc = "Dreamcast", pce = "PC Engine", a2600 = "Atari 2600",
}

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, webp = true, bmp = true, gif = true }
local HIDDEN_FILES = { ["install.lua"] = true } -- repo files that don't get copied into a soft mod

local games = {}     -- catalog games, sorted by name
local mods_by = {}   -- mod key -> mod
local registry = {}  -- mod key -> record (installed.txt)
local library = {}   -- Library_Games()
local state = "idle" -- idle | loading | ready
local message = nil
local pending = 0
local notice = nil

local tab = 1
local platform = nil -- sidebar filter (nil = all)
local query = ""
local game_page = nil
local mod_page = nil
local copy_page = nil -- { mod, target, name, size }
local job = nil       -- the running install / remove: { mod, co, phase, frac, title }

local has_library = Library_Games ~= nil

-- ---------------------------------------------------------------------------
-- helpers

local function say(text) notice = { text = text, ["until"] = Time() + 5 } end

local function safe(s) return (s:gsub("[^%w%-_%.]", "_")) end

local function url_encode(s)
	return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function raw_url(src, path)
	return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", src.owner, src.repo, src.branch, url_encode(path))
end

local function human_size(n)
	if not n or n <= 0 then return nil end
	if n >= 1024 ^ 3 then return string.format("%.1f GB", n / 1024 ^ 3) end
	if n >= 1024 ^ 2 then return string.format("%.1f MB", n / 1024 ^ 2) end
	return string.format("%d KB", math.max(1, math.floor(n / 1024 + 0.5)))
end

local function platform_name(p) return PLATFORMS[p] or p:upper() end

local function parse_source(line)
	line = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
	if line == "" then return nil end
	local branch = line:match("@([%w%-%._/]+)$")
	line = line:gsub("@[%w%-%._/]+$", "")
	line = line:gsub("^https?://github%.com/", ""):gsub("%.git$", ""):gsub("/+$", "")
	local owner, repo, rest = line:match("^([^/]+)/([^/]+)(.*)$")
	if not owner then return nil end
	branch = branch or rest:match("^/tree/(.+)$") or "main"
	return { owner = owner, repo = repo, branch = branch, id = owner .. "/" .. repo }
end

local function load_sources()
	local list = {}
	for line in (K.read(CHANNEL_DIR .. "/sources.txt") or ""):gmatch("[^\r\n]+") do
		local s = parse_source(line)
		if s then list[#list + 1] = s end
	end
	if #list == 0 then
		for _, l in ipairs(DEFAULT_SOURCES) do list[#list + 1] = parse_source(l) end
	end
	return list
end

-- Waits (yielding frames) until fn() returns something.
local function wait_for(fn)
	while true do
		local v = fn()
		if v ~= nil then return v end
		coroutine.yield()
		K.slice_begin()
	end
end

-- ---------------------------------------------------------------------------
-- registry: key \t sig \t type \t target \t copy \t game title \t mod name \t made_game_dir

local REG_FIELDS = { "sig", "type", "target", "copy", "title", "name", "made_dir" }

local function load_registry()
	registry = {}
	for line in (K.read(REGISTRY) or ""):gmatch("[^\r\n]+") do
		local parts = {}
		for f in (line .. "\t"):gmatch("([^\t]*)\t") do parts[#parts + 1] = f end
		if parts[1] and parts[1] ~= "" then
			local r = {}
			for i, k in ipairs(REG_FIELDS) do r[k] = parts[i + 1] or "" end
			registry[parts[1]] = r
		end
	end
end

local function save_registry()
	local keys = {}
	for k in pairs(registry) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local row = { k }
		for _, f in ipairs(REG_FIELDS) do row[#row + 1] = (registry[k][f] or ""):gsub("[\t\r\n]", " ") end
		out[#out + 1] = table.concat(row, "\t")
	end
	K.write(REGISTRY, table.concat(out, "\n") .. "\n")
end

-- ---------------------------------------------------------------------------
-- library

local function refresh_library()
	library = has_library and (Library_Games() or {}) or {}
end

local function matches(g, e)
	if g.platform == "pc" then
		if e.platform ~= "" or e.kind == "rom" then return false end
	elseif e.platform ~= g.platform then
		return false
	end
	local keys = { e.serial, e.file, e.crc, e.title, K.base_of(e.root or "") } -- may hold nils: no ipairs
	for i = 1, 5 do
		local v = keys[i]
		if v and v ~= "" and g.ids[v:lower()] then return true end
	end
	return false
end

-- The library games a catalog game matches.
local function owned(g)
	local out = {}
	for _, e in ipairs(library) do
		if matches(g, e) then out[#out + 1] = e end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- status

-- The APP/mods/<platform>/<Game> folder soft mods of g go to: an existing one whose gameids.txt lists
-- the game (so mods merge with a hand-made folder and Saber doesn't load two copies), else a new one.
local soft_dirs = {}

local function soft_game_dir(g)
	if soft_dirs[g.key] then return soft_dirs[g.key] end
	local base = MODS_DIR .. "/" .. g.platform
	for _, d in ipairs(List_Dirs(base) or {}) do
		for line in (K.read(base .. "/" .. d .. "/gameids.txt") or ""):gmatch("[^\r\n]+") do
			local id = line:match("^%s*(.-)%s*$")
			if id ~= "" and not id:match("^#") and g.ids[id:lower()] then
				soft_dirs[g.key] = base .. "/" .. d
				return soft_dirs[g.key]
			end
		end
	end
	return base .. "/" .. K.clean_name(g.name) -- not cached: the ids may still be loading
end

local function soft_dir(m)
	local r = registry[m.key]
	if r and r.target ~= "" then return r.target end
	return soft_game_dir(m.game) .. "/" .. m.folder
end

-- available | installed | update | local (in APP/mods but not from ModHack) | busy
local function status(m)
	if job and job.mod == m then return "busy" end
	local r = registry[m.key]
	if m.type == "soft" then
		local here = Exists(soft_dir(m))
		if here and not r then return "local" end
		if not here then return "available" end
	elseif not r then
		return "available"
	end
	if m.sig ~= "" and r.sig ~= m.sig then return "update" end
	return "installed"
end

local function badge(m)
	local st = status(m)
	if st == "update" then return "Update" end
	if st == "installed" then return "Installed" end
	if st == "local" then return "On this PC" end
	return m.type == "hard" and "HARD" or "SOFT"
end

local function installed_count(g)
	local n = 0
	for _, m in ipairs(g.mods) do
		local st = status(m)
		if st == "installed" or st == "update" then n = n + 1 end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- catalog

local loading_done

local function use_meta(target, text, kind)
	if kind == "ids" then
		for line in (text or ""):gmatch("[^\r\n]+") do
			local id = line:match("^%s*(.-)%s*$")
			if id ~= "" and not id:match("^#") then target.ids[id:lower()] = true end
		end
		return
	end
	local t = K.ini_parse(text)
	target.name = t.name or target.name
	target.description = t.description or target.description
	-- game.ini image = a web picture: Saber fetches URL images on demand, in memory only (never saved)
	if kind == "game" and t.image and t.image:match("^https?://") then target.art = t.image end
	if kind == "mod" then
		target.author = t.author or ""
		target.version = t.version or ""
		target.url = t.url
		target.file = t.file
		target.homepage = t.homepage
		target.crc = t.crc and t.crc:lower():gsub("^0x", "") or nil
		target.dl_size = tonumber(t.size)
	end
end

-- A small catalog file, cached by its blob sha (a changed file has a new sha).
local function fetch_meta(src, f, target, kind)
	local cache = CACHE .. "/meta/" .. safe(f.sha) .. ".txt"
	local text = K.read(cache)
	if text then return use_meta(target, text, kind) end
	if not Online() then return end
	pending = pending + 1
	Http_Get(raw_url(src, f.path), function(ok, body)
		if ok then
			use_meta(target, body, kind)
			K.write(cache, body)
		end
		loading_done()
	end)
end

function loading_done()
	pending = pending - 1
	if pending > 0 then return end
	table.sort(games, function(a, b) return a.name:lower() < b.name:lower() end)
	for _, g in ipairs(games) do
		table.sort(g.mods, function(a, b) return a.name:lower() < b.name:lower() end)
	end
	state = "ready"
end

local function art_of(src, files)
	for _, want in ipairs({ "thumbnail", "preview", "cover" }) do
		for _, f in ipairs(files) do
			if not f.rel:find("/") and K.stem_of(f.rel):lower() == want and IMAGE_EXTS[K.ext_of(f.rel)] then
				return raw_url(src, f.path)
			end
		end
	end
	return nil
end

local function read_tree(src, tree)
	local by_game = {} -- "plat/Game" -> { plat, folder, files, mods = { folder -> files } }
	for _, e in ipairs(tree) do
		if e.type == "blob" and type(e.path) == "string" and e.path:sub(1, #ROOT) == ROOT then
			local plat, gfolder, rest = e.path:sub(#ROOT + 1):match("^([^/]+)/([^/]+)/(.+)$")
			if plat and not plat:match("^[_%.]") and not gfolder:match("^[_%.]") then
				plat = plat:lower()
				local gk = plat .. "/" .. gfolder
				local g = by_game[gk]
				if not g then
					g = { plat = plat, folder = gfolder, files = {}, mods = {} }
					by_game[gk] = g
				end
				local f = { path = e.path, sha = e.sha or "", size = tonumber(e.size) or 0 }
				local kind, mfolder, rel = rest:match("^([^/]+)/([^/]+)/(.+)$")
				kind = kind and kind:lower()
				if not rest:find("/") then
					f.rel = rest
					g.files[#g.files + 1] = f
				elseif (kind == "soft" or kind == "hard") and not mfolder:match("^[_%.]") then
					f.rel = rel
					local mk = kind .. "/" .. mfolder
					g.mods[mk] = g.mods[mk] or { type = kind, folder = mfolder, files = {} }
					table.insert(g.mods[mk].files, f)
				end
			end
		end
	end

	for gk, gt in pairs(by_game) do
		local g = nil
		for _, have in ipairs(games) do if have.key == gk then g = have end end
		if not g then
			g = { key = gk, platform = gt.plat, folder = gt.folder, name = gt.folder, description = "",
				ids = {}, mods = {}, files = gt.files, source = src, art = art_of(src, gt.files) }
			games[#games + 1] = g
			for _, f in ipairs(gt.files) do
				local lower = f.rel:lower()
				if lower == "gameids.txt" then fetch_meta(src, f, g, "ids") end
				if lower == "game.ini" then fetch_meta(src, f, g, "game") end
			end
		end
		for mk, mt in pairs(gt.mods) do
			local key = gk .. "/" .. mk
			local files = mt.files
			if not mods_by[key] then -- an earlier source has it
				local m = { key = key, game = g, folder = mt.folder, name = mt.folder, author = "", version = "",
					description = "", type = mt.type, files = files, source = src, size = 0,
					art = art_of(src, files) }
				local shas = {}
				for _, f in ipairs(files) do
					shas[#shas + 1] = f.rel .. "=" .. f.sha
					m.size = m.size + f.size
					local lower = f.rel:lower()
					if lower == "mod.ini" then fetch_meta(src, f, m, "mod") end
					if lower == "install.lua" then m.script = f end
				end
				table.sort(shas)
				m.sig = table.concat(shas, ";")
				mods_by[key] = m
				g.mods[#g.mods + 1] = m
			end
		end
	end
end

local function fetch_source(src)
	pending = pending + 1
	local cache = CACHE .. "/" .. safe(src.id .. "@" .. src.branch) .. ".json"
	local url = string.format("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1", src.owner, src.repo, src.branch)
	local function use(body, from_cache)
		local data = body and Json_Decode(body) or nil
		if type(data) ~= "table" or type(data.tree) ~= "table" then return false end
		if not from_cache then K.write(cache, body) end
		read_tree(src, data.tree)
		return true
	end
	if not Online() then
		if not use(K.read(cache), true) then message = "Turn on Online Mode (Settings) to browse mods." end
		return loading_done()
	end
	Http_Get(url, function(ok, body, code)
		if not (ok and use(body, false)) then
			if use(K.read(cache), true) then
				message = "Couldn't refresh " .. src.id .. " (" .. tostring(code or "no answer") .. "), showing the last catalog."
			else
				message = "Couldn't read " .. src.id .. " (" .. tostring(code or "no answer") .. ")."
			end
		end
		loading_done()
	end)
end

local function refresh()
	if state == "loading" then return end
	games, mods_by, message, game_page, mod_page = {}, {}, nil, nil, nil
	state = "loading"
	pending = pending + 1 -- held until every source has been started
	for _, src in ipairs(load_sources()) do fetch_source(src) end
	loading_done()
end

-- ---------------------------------------------------------------------------
-- copying a game (hard mods)

-- Files a disc image refers to (.cue / .gdi tracks, .m3u discs), names relative to its folder.
local function image_files(path, out, seen)
	out, seen = out or {}, seen or {}
	local name = K.base_of(path)
	if seen[name:lower()] then return out end
	seen[name:lower()] = true
	out[#out + 1] = name
	local ext = K.ext_of(name)
	local dir = K.dir_of(path)
	local text = (ext == "cue" or ext == "gdi" or ext == "m3u") and K.read(path) or nil
	for line in (text or ""):gmatch("[^\r\n]+") do
		local ref
		if ext == "cue" then
			ref = line:match('^%s*FILE%s+"(.-)"') or line:match("^%s*FILE%s+(%S+)")
		elseif ext == "gdi" then
			ref = line:match('^%s*%d+%s+%d+%s+%d+%s+%d+%s+"(.-)"') or line:match("^%s*%d+%s+%d+%s+%d+%s+%d+%s+(%S+)")
		elseif not line:match("^%s*#") then
			ref = line:match("^%s*(.-)%s*$")
		end
		if ref and ref ~= "" and not ref:find("[/\\]") then image_files(dir .. "/" .. ref, out, seen) end
	end
	return out
end

-- Where a copy of game e named `name` goes (and how it's made).
local function copy_plan(e, name)
	local clean = K.clean_name(name)
	if clean == "" then return nil, "Type a name for the copy." end
	if e.saber ~= "" then
		local dest = K.dir_of(e.root) .. "/" .. clean
		return { kind = "folder", from = e.root, dest = dest, name = clean }
	end
	local ext = K.ext_of(e.rom)
	local dir = K.dir_of(e.rom)
	if ext == "cue" or ext == "gdi" or ext == "m3u" then
		return { kind = "image", files = image_files(e.rom), from = dir, dest = dir .. "/" .. clean, name = clean }
	end
	return { kind = "rom", from = e.rom, dest = dir .. "/" .. clean .. "." .. ext, name = clean }
end

local function plan_size(plan)
	if plan.kind == "image" then
		local n = 0
		for _, f in ipairs(plan.files) do n = n + (K.size(plan.from .. "/" .. f) or 0) end
		return n
	end
	return K.tree_size(plan.from)
end

-- Makes the copy (in the install coroutine) and returns the copy as a library game table.
local function copy_game(e, plan, progress)
	if Exists(plan.dest) then error("\"" .. plan.name .. "\" already exists. Pick another name.") end
	local total = math.max(1, plan_size(plan))
	local done = 0
	local function on_bytes(n)
		done = done + n
		progress(done / total)
	end
	local part = plan.dest .. ".part"
	K.remove(part)
	K.write(COPYING, part)
	local ok, err
	local copy = { title = plan.name, platform = e.platform, kind = e.kind, serial = "", disc = 0 }
	if plan.kind == "folder" then
		ok, err = K.copy(plan.from, part, {
			progress = on_bytes,
			skip = function(rel) return rel:lower() == "_saber/records.ini" end,
		})
		if ok then
			K.ini_set(part .. "/_Saber/saber.ini", "title", plan.name)
			K.ini_set(part .. "/_Saber/saber.ini", "mod", "")
		end
		copy.root, copy.saber = plan.dest, plan.dest .. "/_Saber"
		if e.rom and e.rom:sub(1, #e.root + 1) == e.root .. "/" then copy.rom = plan.dest .. e.rom:sub(#e.root + 1) end
		if e.rom and not copy.rom then copy.rom = e.rom end
	elseif plan.kind == "image" then
		for _, f in ipairs(plan.files) do
			ok, err = K.copy_file(plan.from .. "/" .. f, part .. "/" .. f, on_bytes)
			if not ok then break end
		end
		if ok then
			K.write(part .. "/_Saber/saber.ini", "title=" .. plan.name .. "\r\nplatform=" .. e.platform ..
				"\r\nrom=" .. plan.files[1] .. "\r\n")
			local base = e.rom:gsub("%.[%w]+$", "")
			for _, ce in ipairs({ "png", "jpg", "jpeg", "webp" }) do
				if Exists(base .. "." .. ce) then K.copy_file(base .. "." .. ce, part .. "/_Saber/box." .. ce) break end
			end
		end
		copy.root, copy.saber, copy.rom = plan.dest, plan.dest .. "/_Saber", plan.dest .. "/" .. plan.files[1]
	else
		ok, err = K.copy_file(plan.from, part, on_bytes)
		local base = e.rom:gsub("%.[%w]+$", "")
		for _, ce in ipairs({ "png", "jpg", "jpeg", "webp" }) do
			if ok and Exists(base .. "." .. ce) then K.copy_file(base .. "." .. ce, K.dir_of(plan.dest) .. "/" .. plan.name .. "." .. ce) break end
		end
		copy.root, copy.saber, copy.rom = plan.dest, "", plan.dest
		copy.file, copy.crc = plan.name, e.crc -- same bytes until the mod changes them
	end
	if not ok then
		K.remove(part)
		os.remove(COPYING)
		error("Couldn't copy the game: " .. tostring(err))
	end
	if not os.rename(part, plan.dest) then
		K.remove(part)
		os.remove(COPYING)
		error("Couldn't rename the copy to " .. plan.name)
	end
	os.remove(COPYING)
	return copy
end

-- ---------------------------------------------------------------------------
-- install / remove

-- The table install.lua gets (MODS.md documents it).
local function make_ctx(m, stage, target, extra)
	local ctx = {
		mod = { name = m.name, author = m.author, version = m.version, type = m.type, url = m.url, key = m.key },
		repo = stage .. "/repo",
		files = stage .. "/files",
		download = extra.download,
		game = target,
		mod_dir = m.type == "soft" and soft_dir(m) or nil,
		is_copy = extra.is_copy or false,
		backups = {},
	}
	local bdir = BACKUPS .. "/" .. safe(m.key)
	-- file helpers raise on failure, so a script can't half-install without noticing
	local function must(fn, what)
		return function(...)
			local ok, err = fn(...)
			if not ok then error(what .. ": " .. tostring(err or select(1, ...))) end
			return ok
		end
	end
	ctx.copy = must(K.copy, "couldn't copy")
	ctx.write = must(K.write, "couldn't write")
	ctx.remove = must(K.remove, "couldn't remove")
	ctx.unzip = must(Unzip, "couldn't unpack")
	ctx.ini_set = must(K.ini_set, "couldn't edit")
	ctx.read, ctx.walk, ctx.size, ctx.is_dir, ctx.exists = K.read, K.walk, K.size, K.is_dir, Exists
	ctx.crc32 = K.crc32
	ctx.step = K.step
	ctx.log = function(text) saber.log("ModHack: " .. m.key .. ": " .. tostring(text)) end
	ctx.progress = function(frac, text)
		if job then job.frac, job.phase = frac, text or job.phase end
		K.step()
	end
	-- Saves a game file before the mod changes it (only when working on the original: a copy can just
	-- be deleted). Remove puts every backed-up file back.
	ctx.backup = function(path)
		if ctx.is_copy or not Exists(path) or ctx.backups[path] then return true end
		local saved = bdir .. "/" .. (#ctx.backups + 1) .. "_" .. safe(K.base_of(path))
		local ok, err = K.copy_file(path, saved)
		if not ok then error("Couldn't back up " .. path .. ": " .. tostring(err)) end
		ctx.backups[path] = saved
		ctx.backups[#ctx.backups + 1] = path
		return true
	end
	-- Patches a file with an .ips / .bps (backs it up first).
	ctx.patch = function(file, patch, out)
		ctx.backup(out or file)
		local crc = (file == (target and target.rom) and target.crc and target.crc ~= "") and tonumber(target.crc, 16) or nil
		local ok, err = K.apply_patch(file, patch, out, { crc = crc })
		if not ok then error(err) end
		return true
	end
	-- Downloads another file (waits for it).
	ctx.fetch = function(url, path)
		local ok, err = Download(url, path)
		if not ok then error("Couldn't download " .. url .. ": " .. tostring(err)) end
		local st = wait_for(function()
			local s = Download_Status(path)
			if not s or s.state == "done" or s.state == "failed" then return s or false end
		end)
		if not st or st.state ~= "done" then error("Couldn't download " .. url .. ": " .. tostring(st and st.error or "cancelled")) end
		return path
	end
	-- Asks the player (waits for the answer): returns the picked option's index, nil if dismissed.
	ctx.ask = function(text, options)
		local answer = false
		Dialog_Info(text, options or { "OK" }, function(i) answer = i or 0 end)
		local i = wait_for(function() return answer or nil end)
		return i ~= 0 and i or nil
	end
	ctx.patches = function(dir)
		local out = {}
		for _, rel in ipairs(K.walk(dir or ctx.files)) do
			local ext = K.ext_of(rel)
			if ext == "ips" or ext == "bps" then out[#out + 1] = (dir or ctx.files) .. "/" .. rel end
		end
		return out
	end
	return ctx
end

local function load_script(path)
	if not Exists(path) then return nil end
	local fn, err = loadfile(path)
	if not fn then error("install.lua: " .. tostring(err)) end
	local s = fn()
	if type(s) ~= "table" then error("install.lua must return a table") end
	return s
end

local function save_backups(m, ctx)
	local lines = {}
	for _, path in ipairs(ctx.backups) do lines[#lines + 1] = path .. "\t" .. ctx.backups[path] end
	local f = BACKUPS .. "/" .. safe(m.key) .. "/manifest.txt"
	if #lines > 0 then K.write(f, table.concat(lines, "\n") .. "\n") end
end

-- Hard mod with no install.lua: apply its one .ips / .bps to the game's ROM.
local function default_hard(m, ctx)
	local g = ctx.game
	if not g.rom then error("this mod has no install.lua, and " .. g.title .. " isn't a ROM it could patch") end
	local ext = K.ext_of(g.rom)
	if ext == "cue" or ext == "gdi" or ext == "m3u" then
		error("patching disc images needs an install.lua (which track to patch)")
	end
	local list = ctx.patches(ctx.files)
	if #list == 0 then list = ctx.patches(ctx.repo) end
	if #list == 0 then error("no .ips / .bps patch found in the mod") end
	if #list > 1 then error("the mod has " .. #list .. " patches; it needs an install.lua to pick one") end
	if m.crc and g.crc and g.crc ~= "" and g.crc:lower() ~= m.crc then
		local i = ctx.ask(m.name .. " was made for a different dump of " .. m.game.name .. " (CRC32 " .. m.crc ..
			", yours is " .. g.crc:lower() .. "). Patching it will probably break the game.", { "Patch anyway", "Cancel" })
		if i ~= 1 then error("cancelled") end
	end
	ctx.progress(-1, "Patching " .. K.base_of(g.rom) .. "...")
	ctx.patch(g.rom, list[1])
end

local function install_job(m, target, plan)
	local stage = STAGE .. "/" .. safe(m.key)
	K.remove(stage)
	Make_Dir(stage .. "/repo")
	Make_Dir(stage .. "/files")
	local made_copy = nil
	local function cleanup() K.remove(stage) end

	local ok, err = pcall(function()
		-- 1. the mod's own files from the repo (+ a soft mod's gameids.txt / presets.ini)
		job.phase, job.frac = "Downloading the mod...", 0
		local list = {}
		for _, f in ipairs(m.files) do list[#list + 1] = { src = m.source, path = f.path, to = stage .. "/repo/" .. f.rel } end
		if m.type == "soft" then
			for _, f in ipairs(m.game.files) do
				local lower = f.rel:lower()
				if lower == "gameids.txt" or lower == "presets.ini" then
					list[#list + 1] = { src = m.game.source, path = f.path, to = stage .. "/game/" .. f.rel }
				end
			end
		end
		local left, failed = #list, 0
		local nexti, inflight = 1, 0
		while left > 0 do
			while inflight < WORKERS and nexti <= #list do
				local f = list[nexti]
				nexti, inflight = nexti + 1, inflight + 1
				Make_Dir(K.dir_of(f.to))
				Http_Download(raw_url(f.src, f.path), f.to, function(dl_ok)
					inflight, left = inflight - 1, left - 1
					if not dl_ok then failed = failed + 1 end
				end)
			end
			job.frac = (#list - left) / math.max(1, #list)
			coroutine.yield()
		end
		if failed > 0 then error(failed .. " file(s) of the mod couldn't be downloaded") end

		-- 2. the external download
		local download
		if m.url and m.url ~= "" then
			local name = K.clean_name(m.file or m.url:gsub("[?#].*$", ""):match("([^/]+)$") or "download")
			download = stage .. "/dl/" .. (name ~= "" and name or "download")
			Make_Dir(stage .. "/dl")
			job.phase, job.frac = "Downloading " .. K.base_of(download) .. "...", -1
			local dl_ok, dl_err = Download(m.url, download)
			if not dl_ok then error("Couldn't start the download: " .. tostring(dl_err)) end
			local st = wait_for(function()
				local s = Download_Status(download)
				if s and s.total and s.total > 0 then job.frac = s.got / s.total end
				if not s or s.state == "done" or s.state == "failed" then return s or false end
			end)
			if not st or st.state ~= "done" then error("The download failed: " .. tostring(st and st.error or "cancelled")) end
			if K.ext_of(download) == "zip" then
				job.phase, job.frac = "Unpacking...", -1
				coroutine.yield()
				local z_ok, z_err = Unzip(download, stage .. "/files")
				if not z_ok then error("Couldn't unpack " .. K.base_of(download) .. ": " .. tostring(z_err)) end
			else
				K.copy_file(download, stage .. "/files/" .. K.base_of(download))
			end
		end

		-- 3. the copy of the game
		if plan then
			job.phase, job.frac = "Copying " .. target.title .. "...", 0
			made_copy = copy_game(target, plan, function(f) job.frac = f end)
			target = made_copy
		end

		-- 4. install
		local script = load_script(stage .. "/repo/install.lua")
		local ctx = make_ctx(m, stage, target, { download = download, is_copy = made_copy ~= nil })
		local made_dir = false
		if m.type == "soft" then
			job.phase, job.frac = "Installing...", -1
			local gdir = K.dir_of(ctx.mod_dir)
			made_dir = not Exists(gdir)
			-- a reinstall replaces the folder, so files dropped upstream don't linger
			if registry[m.key] then K.remove(ctx.mod_dir) end
			for _, f in ipairs(m.files) do
				if not HIDDEN_FILES[f.rel:lower()] then
					local c_ok, c_err = K.copy_file(stage .. "/repo/" .. f.rel, ctx.mod_dir .. "/" .. f.rel)
					if not c_ok then error(c_err) end
				end
			end
			-- the game's gameids.txt (how Saber finds the mods) and presets.ini, unless the folder has its own
			for _, name in ipairs({ "gameids.txt", "presets.ini" }) do
				local from = stage .. "/game/" .. name
				if Exists(from) and not Exists(gdir .. "/" .. name) then K.copy_file(from, gdir .. "/" .. name) end
			end
			if not Exists(gdir .. "/gameids.txt") then
				local ids = {}
				for id in pairs(m.game.ids) do ids[#ids + 1] = id end
				table.sort(ids)
				K.write(gdir .. "/gameids.txt", table.concat(ids, "\r\n") .. "\r\n")
			end
			if script and script.install then
				script.install(ctx)
			elseif download then
				K.copy(ctx.files, ctx.mod_dir)
			end
		else
			job.phase, job.frac = "Installing...", -1
			K.remove(BACKUPS .. "/" .. safe(m.key))
			if script and script.install then script.install(ctx) else default_hard(m, ctx) end
			save_backups(m, ctx)
		end

		if script then K.copy_file(stage .. "/repo/install.lua", SCRIPTS .. "/" .. safe(m.key) .. ".lua") end
		local old = registry[m.key]
		registry[m.key] = {
			sig = m.sig, type = m.type, copy = made_copy and "1" or "",
			target = m.type == "soft" and ctx.mod_dir or (target and target.root or ""),
			title = target and target.title or m.game.name, name = m.name,
			made_dir = (made_dir or (old and old.made_dir == "1")) and "1" or "",
		}
		save_registry()
		saber.log("ModHack: installed " .. m.key .. (target and (" on " .. target.root) or ""))
	end)

	cleanup()
	if not ok then
		if made_copy then K.remove(made_copy.root) end
		err = tostring(err):gsub("^.-:%d+: ", "")
		if err ~= "cancelled" then Dialog_Info("Couldn't install " .. m.name .. ":\n" .. err, { "OK" }) end
		return
	end
	if m.type == "hard" then Rescan_Library() end
	refresh_library()
	Play_Sfx("start")
	if made_copy then
		say(m.name .. " installed on the copy \"" .. made_copy.title .. "\" (GAMES tab).")
	elseif m.type == "soft" then
		say(m.name .. " installed. Turn it on / off from the game's Mods menu.")
	else
		say(m.name .. " installed on " .. (target and target.title or m.game.name) .. ".")
	end
end

local function remove_job(m, how)
	local r = registry[m.key]
	local ok, err = pcall(function()
		job.phase, job.frac = "Removing...", -1
		local script = load_script(SCRIPTS .. "/" .. safe(m.key) .. ".lua")
		local target = nil
		for _, e in ipairs(library) do if r and e.root == r.target then target = e end end
		target = target or (r and r.target ~= "" and { root = r.target, title = r.title }) or nil
		local ctx = make_ctx(m, STAGE .. "/" .. safe(m.key), target, {})
		if script and script.uninstall then script.uninstall(ctx) end
		if m.type == "soft" then
			local rm_ok, rm_err = K.remove(soft_dir(m))
			if not rm_ok then error(rm_err) end
			local gdir = K.dir_of(soft_dir(m))
			soft_dirs[m.game.key] = nil
			if r and r.made_dir == "1" and #(List_Dirs(gdir) or {}) == 0 then K.remove(gdir) end
		elseif how == "delete_copy" then
			local rm_ok, rm_err = K.remove(r.target)
			if not rm_ok then error(rm_err) end
			local base = r.target:gsub("%.[%w]+$", "")
			for _, ce in ipairs({ "png", "jpg", "jpeg", "webp" }) do os.remove(base .. "." .. ce) end
		elseif how == "restore" then
			local manifest = BACKUPS .. "/" .. safe(m.key) .. "/manifest.txt"
			for line in (K.read(manifest) or ""):gmatch("[^\r\n]+") do
				local orig, saved = line:match("^(.-)\t(.+)$")
				if orig then
					local c_ok, c_err = K.copy_file(saved, orig .. ".modhack")
					if not c_ok then error(c_err) end
					os.remove(orig)
					if not os.rename(orig .. ".modhack", orig) then error("couldn't restore " .. orig) end
				end
			end
		end
		K.remove(BACKUPS .. "/" .. safe(m.key))
		os.remove(SCRIPTS .. "/" .. safe(m.key) .. ".lua")
		registry[m.key] = nil
		save_registry()
	end)
	if not ok then
		Dialog_Info("Couldn't remove " .. m.name .. ":\n" .. tostring(err):gsub("^.-:%d+: ", ""), { "OK" })
		return
	end
	if m.type == "hard" then Rescan_Library() end
	refresh_library()
	say(m.name .. " removed.")
end

local function start_job(m, fn, ...)
	local args = { ... }
	job = { mod = m, phase = "Starting...", frac = -1 }
	job.co = coroutine.create(function() fn(m, table.unpack(args)) end)
end

local function pump_job()
	if not job then return end
	K.slice_begin()
	local ok, err = coroutine.resume(job.co)
	if not ok then
		saber.log("ModHack: " .. tostring(err))
		Dialog_Info("ModHack hit an error:\n" .. tostring(err), { "OK" })
		job = nil
	elseif coroutine.status(job.co) == "dead" then
		job = nil
	end
end

-- ---------------------------------------------------------------------------
-- flows

local function busy()
	if job then
		say("Wait for " .. job.mod.name .. " to finish.")
		return true
	end
	return false
end

local function confirm_original(m, e)
	Dialog_Info("Install " .. m.name .. " on your original " .. e.title .. "?\n\n" ..
		"ModHack backs up the files the mod replaces so Remove can try to put them back, " ..
		"but a hard mod can't always be undone cleanly.", { "Install on the original", "Cancel" }, function(i)
		if i == 1 and not busy() then start_job(m, install_job, e, nil) end
	end)
end

local function hard_warning(m, e)
	Dialog_Info("HARD MOD\n\n" .. m.name .. " changes " .. e.title .. "'s files directly.\n\n" ..
		"We recommend making a full copy of the game, under a different name, first and installing " ..
		"the mod on the copy: the original stays untouched and both show up in GAMES.",
		{ "Make a copy first (recommended)", "Install on the original", "Cancel" }, function(i)
		if i == 1 then
			local plan = copy_plan(e, e.title .. " - " .. m.name)
			copy_page = { mod = m, target = e, name = plan and plan.name or e.title, size = plan and plan_size(plan) }
		elseif i == 2 then
			confirm_original(m, e)
		end
	end)
end

local function install(m)
	if busy() then return end
	if not Online() then
		Dialog_Info("Turn on Online Mode (Settings) to download mods.", { "OK" })
		return
	end
	if status(m) == "local" then return end
	if m.type == "soft" then return start_job(m, install_job, nil, nil) end
	if not has_library then
		Dialog_Info("Hard mods need a newer Saber (Library_Games). Update Saber and try again.", { "OK" })
		return
	end
	local targets = owned(m.game)
	if #targets == 0 then
		Dialog_Info(m.name .. " is a hard mod: it changes the game itself, so " .. m.game.name ..
			" has to be in your library (GAMES tab) first. Install it from its disc or drive, then come back.", { "OK" })
	elseif #targets == 1 then
		hard_warning(m, targets[1])
	else
		local items = {}
		for _, e in ipairs(targets) do
			items[#items + 1] = { name = e.title, description = e.rom or e.root, Do = function() hard_warning(m, e) end }
		end
		Dialog_Menu("Install " .. m.name .. " on which game?", items)
	end
end

local function remove(m)
	if busy() then return end
	local r = registry[m.key]
	if not r then return end
	if m.type == "soft" then
		Dialog_Info("Remove " .. m.name .. "?", { "Remove", "Cancel" }, function(i)
			if i == 1 and not busy() then start_job(m, remove_job, "soft") end
		end)
		return
	end
	local has_backup = Exists(BACKUPS .. "/" .. safe(m.key) .. "/manifest.txt")
	local has_script = Exists(SCRIPTS .. "/" .. safe(m.key) .. ".lua")
	if r.copy == "1" then
		Dialog_Info("Remove " .. m.name .. "?\n\nIt was installed on the copy \"" .. r.title ..
			"\". Deleting the copy removes the mod; your original game isn't affected.",
			{ "Delete the copy", "Only forget it", "Cancel" }, function(i)
			if busy() then return end
			if i == 1 then start_job(m, remove_job, "delete_copy") end
			if i == 2 then start_job(m, remove_job, "forget") end
		end)
	elseif has_backup or has_script then
		Dialog_Info("Remove " .. m.name .. " from " .. r.title .. "? The original files are put back.",
			{ "Remove", "Cancel" }, function(i)
			if i == 1 and not busy() then start_job(m, remove_job, "restore") end
		end)
	else
		Dialog_Info(m.name .. " changed " .. r.title .. " directly and left no backup, so ModHack can't undo it. " ..
			"Reinstall the game to get the original back.", { "Forget it", "Cancel" }, function(i)
			if i == 1 and not busy() then start_job(m, remove_job, "forget") end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- pages

local function draw_notice()
	if notice and Time() < notice["until"] then UI_Text(notice.text, "accent") end
end

local function draw_job()
	if not job then return end
	UI_Progress(job.frac or -1, job.mod.name .. ": " .. (job.phase or ""))
end

local function mod_bits(m)
	local bits = { m.type == "hard" and "HARD MOD" or "SOFT MOD" }
	if m.author ~= "" then bits[#bits + 1] = "by " .. m.author end
	if m.version ~= "" then bits[#bits + 1] = "v" .. m.version end
	local size = m.dl_size or (not m.url and m.size) or nil
	if human_size(size) then bits[#bits + 1] = human_size(size) end
	return table.concat(bits, "  ·  ")
end

local function copy_view()
	local c = copy_page
	UI_Title("Copy " .. c.target.title, "before installing " .. c.mod.name)
	UI_Text("The copy is a separate game in GAMES with its own saves. " .. c.mod.name ..
		" is installed on the copy; your original stays as it is.", "text")
	local text, _, submitted = UI_SearchBar("copy_name", c.name, "Name of the copy")
	c.name = text
	local plan, err = copy_plan(c.target, c.name)
	if plan and Exists(plan.dest) then plan, err = nil, "\"" .. plan.name .. "\" already exists. Pick another name." end
	if err then UI_Text(err, "warn") end
	if c.size and human_size(c.size) then UI_Text("The copy takes " .. human_size(c.size) .. ".", "muted") end
	if UI_Button("copy_go", "Copy and install") or (submitted and plan) then
		if plan and not busy() then
			start_job(c.mod, install_job, c.target, plan)
			copy_page = nil
		end
	end
	if UI_Button("copy_cancel", "Cancel") then copy_page = nil end
	UI_Hints({ { "A", "Select" }, { "B", "Back" } })
	if UI_Back() then copy_page = nil end
end

local function mod_view()
	local m = mod_page
	UI_Title(m.name, m.game.name .. "  ·  " .. mod_bits(m))
	if m.art then UI_Image(m.art, { height = 280, cover = false }) end
	draw_notice()
	local st = status(m)
	if st == "busy" then
		draw_job()
	elseif st == "local" then
		UI_Text("A mod with this folder name is already in Saber's mods folder (not installed by ModHack), so ModHack leaves it alone.", "muted")
	else
		if st == "available" then
			if UI_Button("install", m.type == "hard" and "Install..." or "Install") then install(m) end
		elseif st == "update" then
			if UI_Button("install", "Update") then install(m) end
		else
			if UI_Button("install", "Reinstall") then install(m) end
		end
		if st == "installed" or st == "update" then
			if UI_Button("remove", "Remove") then remove(m) end
		end
	end
	if m.homepage and m.homepage ~= "" then
		if UI_Button("web", "Open web page") then Open_Url(m.homepage) end
	end
	if m.description ~= "" then UI_Text(m.description, "text") end
	local r = registry[m.key]
	if r and m.type == "hard" and r.title ~= "" then
		UI_Text("Installed on " .. (r.copy == "1" and "the copy " or "") .. "\"" .. r.title .. "\".", "accent")
	end
	if m.type == "soft" then
		UI_Text("Soft mod: kept in Saber's mods folder, apart from the game, and loaded when the game starts. " ..
			"Turn it on or off from the game's Mods menu (X on its card > Mods).", "muted")
	else
		UI_Text("Hard mod: changes the game's own files. ModHack recommends installing it on a full copy of the game.", "warn")
	end
	if m.url then UI_Text("Downloads from " .. (m.url:match("^https?://([^/]+)") or m.url), "muted") end
	UI_Hints({ { "A", "Select" }, { "B", "Back" } })
	if UI_Back() then mod_page = nil end
end

local function game_view()
	local g = game_page
	UI_Title(g.name, platform_name(g.platform) .. "  ·  " .. #g.mods .. (#g.mods == 1 and " mod" or " mods"))
	draw_notice()
	draw_job()
	local mine = owned(g)
	if #mine > 0 then
		local names = {}
		for _, e in ipairs(mine) do names[#names + 1] = e.title end
		UI_Text("In your library: " .. table.concat(names, ", "), "accent")
	else
		UI_Text("Not in your library. Soft mods can be installed now and load when you play the game; hard mods need it in GAMES.", "muted")
	end
	if g.description ~= "" then UI_Text(g.description, "text") end
	local picked = UI_Grid("mods_" .. g.key, #g.mods, { cols = 3, aspect = 0.5625, cover = true }, function(i)
		local m = g.mods[i]
		local t = { title = m.name, image = m.art, badge = badge(m) }
		t.sub = (m.type == "hard" and "Hard" or "Soft") .. (m.author ~= "" and ("  ·  " .. m.author) or "")
		if job and job.mod == m then t.progress = job.frac and job.frac >= 0 and job.frac or nil end
		return t
	end)
	if picked then mod_page = g.mods[picked] end
	UI_Hints({ { "A", "Open" }, { "B", "Back" } })
	if UI_Back() then game_page = nil end
end

local function shown_games()
	local out = {}
	local q = query:lower()
	for _, g in ipairs(games) do
		if (not platform or g.platform == platform)
			and (q == "" or g.name:lower():find(q, 1, true))
			and (tab ~= 1 or #owned(g) > 0) then
			out[#out + 1] = g
		end
	end
	return out
end

local function platform_rows(list_for)
	local counts, order = {}, {}
	for _, g in ipairs(list_for) do
		if not counts[g.platform] then order[#order + 1] = g.platform end
		counts[g.platform] = (counts[g.platform] or 0) + 1
	end
	table.sort(order, function(a, b) return platform_name(a) < platform_name(b) end)
	local rows = { { text = "All", radio = true, checked = platform == nil, count = #list_for } }
	for _, p in ipairs(order) do
		rows[#rows + 1] = { text = platform_name(p), radio = true, checked = platform == p, count = counts[p], id = p }
	end
	return rows
end

local function installed_list()
	local out = {}
	for key, r in pairs(registry) do out[#out + 1] = { key = key, r = r, m = mods_by[key] } end
	table.sort(out, function(a, b) return (a.r.name or a.key):lower() < (b.r.name or b.key):lower() end)
	return out
end

local function list_view()
	local sub
	if tab == 3 then
		local n = 0
		for _ in pairs(registry) do n = n + 1 end
		sub = n .. " installed"
	else
		sub = #games .. " games"
	end
	if state == "loading" then sub = sub .. "  ·  loading..." end
	UI_Title("ModHack", sub)
	if message then UI_Text(message, "warn") end
	if not has_library then UI_Text("This Saber can't list your library: hard mods need a newer Saber.", "warn") end
	draw_notice()
	draw_job()

	if tab == 3 then
		local list = installed_list()
		if #list == 0 then UI_Text("Nothing installed yet.", "muted") end
		local picked = UI_Grid("installed", #list, { cols = 3, aspect = 0.5625, cover = true }, function(i)
			local it = list[i]
			local m = it.m
			return {
				title = m and m.name or it.r.name, image = m and m.art,
				sub = it.r.title .. "  ·  " .. (it.r.type == "hard" and "Hard" or "Soft"),
				badge = m and status(m) == "update" and "Update" or nil,
			}
		end)
		if picked then
			local it = list[picked]
			if it.m then
				mod_page = it.m
			else
				say("This mod isn't in the catalog anymore" .. (state == "loading" and " (still loading)." or "."))
			end
		end
		UI_Hints({ { "A", "Open" }, { "LB / RB", "Tabs" }, { "B", "Close" } })
		return
	end

	local base = {}
	for _, g in ipairs(games) do if tab ~= 1 or #owned(g) > 0 then base[#base + 1] = g end end
	local rows = platform_rows(base)
	local side = UI_Sidebar("platforms", rows, { width = 280 })
	if side then platform = rows[side].id end

	local q = UI_SearchBar("search", query, "Search games")
	query = q
	local list = shown_games()
	if #list == 0 then
		if state == "loading" then
			UI_Progress(-1, "Loading the catalog...")
		elseif tab == 1 and #games > 0 then
			UI_Text("None of the games in your library have mods in the catalog yet. Look in ALL GAMES.", "muted")
		else
			UI_Text("No games here.", "muted")
		end
	end
	local picked = UI_Grid("games_" .. tab, #list, { cols = 3, aspect = 0.5625, cover = true }, function(i)
		local g = list[i]
		local n = installed_count(g)
		local t = { title = g.name, image = g.art }
		t.sub = platform_name(g.platform) .. "  ·  " .. #g.mods .. (#g.mods == 1 and " mod" or " mods")
		if n > 0 then t.badge = n .. " installed" elseif tab ~= 1 and #owned(g) > 0 then t.badge = "In library" end
		return t
	end)
	if picked then game_page = list[picked] end
	if UI_Button("refresh", state == "loading" and "Refreshing..." or "Refresh catalog") then
		refresh_library()
		refresh()
	end
	UI_Hints({ { "A", "Open" }, { "LB / RB", "Tabs" }, { "B", "Close" } })
end

local function view()
	local sel, changed = UI_Tabs("tabs", { "MY GAMES", "ALL GAMES", "INSTALLED" }, tab)
	if changed then
		tab, game_page, mod_page, copy_page = sel, nil, nil, nil
	end
	if copy_page then return copy_view() end
	if mod_page then return mod_view() end
	if game_page then return game_view() end
	return list_view()
end

-- ---------------------------------------------------------------------------

return {
	on_start = function()
		for _, d in ipairs({ CACHE .. "/meta", SCRIPTS, BACKUPS, MODS_DIR }) do Make_Dir(d) end
		-- a game copy the last session didn't finish
		local left = K.read(COPYING)
		if left and left ~= "" then K.remove(left) end
		os.remove(COPYING)
		K.remove(STAGE)
		load_registry()
		refresh_library()
		refresh()
		UI_Open(view, function() Channel_Close() end)
	end,

	frame = function()
		pump_job()
	end,

	on_close = function()
		K.remove(STAGE)
	end,
}
