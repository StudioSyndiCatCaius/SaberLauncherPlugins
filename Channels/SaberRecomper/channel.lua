-- Saber Recomper channel: pick a game, then one of its recomps, find a ROM for it, install it.
--
-- The catalog is the recompiler's, not the user's ROM collection. Games: SaberCustomRecomps
-- <platform>/<Game>/<recomp>/ (roots in custom_recomps.txt): bin/<id> = a game pack (needs that exact
-- ROM), _SaberRecomp/ = game.ini (the game it belongs to + its info) and the recomp's own cover.png /
-- logo.png. Plus bin/packs/ packs (grouped by game.ini title / pack.ini `game`), plus one game per
-- recomp module (CHIP-8: any CHIP-8 game). Art: a game's tile = its platform box art (game.ini
-- boxart, or <Game>/box.png); a recomp = its _SaberRecomp/cover.png, which install copies to the
-- game's _Saber/box.png. For each recomp the channel looks for usable ROMs in the user's ROM Sources by running
-- `SaberRecomper.exe find` in the background (Lua calls are stopped by Saber's 5 s watchdog, so the
-- channel never waits on the recompiler: `start "" /B` + polling files). Installs go to
-- APP/games/<Title>/. Folders and ROM files are picked with a built-in browser (Gui popup), so
-- everything works with a controller.
--
-- UI: Saber's Gui library (SaberLauncher src/GUI.md).

local SEP = package.config:sub(1, 1)
local function path(...) return table.concat({ ... }, SEP) end

local EXE = path(CHANNEL_DIR, "bin", "SaberRecomper.exe")
local PACKS_DIR = path(CHANNEL_DIR, "bin", "packs")
local CUSTOM_RECOMPS = path(CHANNEL_DIR, "custom_recomps.txt") -- SaberCustomRecomps roots (build.bat)
local STATUS = path(CHANNEL_DIR, "status.txt")
local ROM_DIRS = path(CHANNEL_DIR, "rom_dirs.txt")
local LOCAL_ROMS = path(CHANNEL_DIR, "roms")
local GAMES = path(SABER_DIR, "games")

-- recomp modules (keep in sync with src/recomp.odin MODULES); `dirs` = APP/games_roms/<dir>
local MODULES = {
	{ id = "chip8", name = "CHIP-8", exts = { ".ch8", ".c8", ".chip8" }, dirs = { "chip8" }, title = "CHIP-8 Recompiler", art = "thumbnail.glsl",
		info = { genre = "Any CHIP-8 game", year = "1977",
			description = "Turns any CHIP-8 game into a native PC game: the ROM is translated to Odin, built with odin.exe and checked against a reference interpreter. Pick one of the ROMs found below, or choose a file." } },
}
-- platforms of game packs: name + APP/games_roms folders searched
local PLATFORMS = {
	snes = { name = "SNES", dirs = { "snes" } },
	n64 = { name = "N64", dirs = { "n64" } },
}

local STATUS_FILTERS = { "All", "Not installed", "Installed" }

local entries = {}   -- recomps: { kind = "pack"|"module", id, title, name, game, platform, info, done, roms = {paths}, finding }
local games = {}     -- { id, title, platform, info, art, game_dir, recomps = {entries}, done }
local shown = {}     -- games after the filters
local rc_cur = nil   -- the recomp open in the "recomp" popup
local sources = {}   -- { label, dir, custom }
local query, plat, status_f = "", 1, 1
local sel_id, grid_sel = nil, 1
local focus_start = true -- focus the grid's first game on the first frame
local job = nil      -- { entry, title, started, status, finished }
local poll_t = 0
local picking = nil  -- { kind, entry, purpose } while the browser is open
local flash = nil
local source_pick = nil

local function say(text, color, t) flash = { text = text, color = color or "#d8e2ff", t = t or 5 } end

local function exists(p)
	local f = io.open(p, "rb")
	if f then f:close() return true end
	return false
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function base_of(name) return (name:gsub("%.[^%.]+$", "")) end
local function file_of(p) return p:match("[^\\/]+$") or p end
local function dir_of(p) return p:match("^(.*)[\\/][^\\/]*$") or p end

-- same rule as the recompiler's title_from_path: "pong_2 (1990) [PD]" -> "Pong 2"
local function title_of(file)
	local s = base_of(file_of(file))
	s = s:gsub("[%(%[{].*$", "")
	s = s:gsub("[_%-]", " "):gsub("^%s+", ""):gsub("%s+$", "")
	s = s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
	return s
end

local function installed(title) return exists(path(GAMES, title, "_Saber", "saber.ini")) end

-- the `recomp=` of an installed game ("pack:<id>", "chip8", ...), nil when not installed
local function installed_recomp(title)
	local f = io.open(path(GAMES, title, "_Saber", "saber.ini"), "r")
	if not f then return nil end
	local r = ""
	for line in f:lines() do
		local v = line:match("^%s*recomp%s*=%s*(.-)%s*$")
		if v then r = v end
	end
	f:close()
	return r
end

local function read_ini(p)
	local f = io.open(p, "r")
	if not f then return nil end
	local t, section = { info = {} }, ""
	for line in f:lines() do
		line = trim(line)
		local s = line:match("^%[(.-)%]$")
		if s then section = s
		elseif line ~= "" and line:sub(1, 1) ~= ";" and line:sub(1, 1) ~= "#" then
			local k, v = line:match("^([^=]+)=(.*)$")
			if k and section == "info" then t.info[trim(k)] = trim(v)
			elseif k and (section == "pack" or section == "game") then t[trim(k)] = trim(v) end
		end
	end
	f:close()
	return t
end

local function read_lines(p)
	local out = {}
	local f = io.open(p, "r")
	if not f then return out end
	for line in f:lines() do
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then out[#out + 1] = line end
	end
	f:close()
	return out
end

-- list may have holes (nil entries), so it's walked by index, not ipairs
local function first_existing(list)
	for i = 1, 16 do
		local p = list[i]
		if p and exists(p) then return p end
	end
end

local function q(s) return '"' .. s .. '"' end

-- ---------------------------------------------------------------------------
-- ROM sources

local function load_sources()
	sources = { { label = "Channel roms folder", dir = LOCAL_ROMS } }
	for _, d in ipairs(read_lines(ROM_DIRS)) do sources[#sources + 1] = { label = d, dir = d, custom = true } end
	local seen = {}
	local function games_roms(d)
		if seen[d] then return end
		seen[d] = true
		sources[#sources + 1] = { label = "Saber games_roms\\" .. d, dir = path(SABER_DIR, "games_roms", d) }
	end
	for _, m in ipairs(MODULES) do for _, d in ipairs(m.dirs) do games_roms(d) end end
	for _, p in pairs(PLATFORMS) do for _, d in ipairs(p.dirs) do games_roms(d) end end
end

local function save_rom_dirs(list)
	local f = io.open(ROM_DIRS, "w")
	if not f then return say("Couldn't write rom_dirs.txt", "#ff8080") end
	f:write("# extra ROM folders for Saber Recomper, one per line (searched with subfolders)\n")
	for _, d in ipairs(list) do f:write(d, "\n") end
	f:close()
end

local function add_source(dir)
	local list = read_lines(ROM_DIRS)
	for _, d in ipairs(list) do if d:lower() == dir:lower() then return false end end
	list[#list + 1] = dir
	save_rom_dirs(list)
	load_sources()
	return true
end

local function open_in_explorer(p) os.execute(string.format('start "" explorer "%s"', p)) end

-- ---------------------------------------------------------------------------
-- finding ROMs: one background `find` per entry, results in find_<id>.txt

local function find(e, dirs)
	if not exists(EXE) then return end
	if not dirs then
		dirs = {}
		for _, s in ipairs(sources) do dirs[#dirs + 1] = q(s.dir) end
	end
	e.out = path(CHANNEL_DIR, "find_" .. e.id .. ".txt")
	os.remove(e.out)
	os.execute(string.format('start "" /B "%s" find --out "%s" --%s %s %s', EXE, e.out, e.kind, e.id, table.concat(dirs, " ")))
	e.finding = Time()
end

local function poll_find(e)
	local f = io.open(e.out, "r")
	if not f then
		if Time() - e.finding > 120 then e.finding = nil end
		return
	end
	local found = {}
	for line in f:lines() do if trim(line) ~= "" then found[#found + 1] = trim(line) end end
	f:close()
	os.remove(e.out)
	e.finding = nil
	-- merge with what we already know (a picked folder adds to the sources' results)
	local have = {}
	for _, p in ipairs(e.roms) do have[p:lower()] = true end
	for _, p in ipairs(found) do if not have[p:lower()] then e.roms[#e.roms + 1] = p; have[p:lower()] = true end end
	table.sort(e.roms, function(a, b) return file_of(a):lower() < file_of(b):lower() end)
	if e.on_found then
		local cb = e.on_found
		e.on_found = nil
		cb(found)
	end
end

-- ---------------------------------------------------------------------------
-- catalog

-- a game's tile: its platform box art (not a recomp's custom art)
local function art_for(g)
	local p = first_existing({
		g.game_dir and path(g.game_dir, "box.png") or nil,
		path(CHANNEL_DIR, "art", (g.id:gsub("[:]", "_")) .. ".png"),
	})
	if p then return p end
	local b = g.info.boxart
	if b and b ~= "" then
		if b:match("^https?://") then return b end
		if g.info_dir then return path(g.info_dir, b) end
	end
	return g.base_art
end

local function build_catalog()
	local keep = {}
	for _, e in ipairs(entries) do keep[e.id] = e end
	entries, games = {}, {}
	local by_game = {}
	local function game_for(key, title, platform, info, info_dir, game_dir)
		local g = by_game[key]
		if g and not next(g.info) and info then g.info, g.info_dir = info, info_dir end
		if not g then
			g = { id = key, title = title, platform = platform, info = info or {}, info_dir = info_dir, game_dir = game_dir, recomps = {} }
			by_game[key] = g
			games[#games + 1] = g
		end
		return g
	end
	-- same order as the recompiler's packs_dirs (first id wins): SaberCustomRecomps, then bin/packs
	local roots, seen = {}, {}
	for _, r in ipairs(read_lines(CUSTOM_RECOMPS)) do
		for _, pl in ipairs(List_Dirs(r) or {}) do
			for _, g in ipairs(List_Dirs(path(r, pl)) or {}) do
				local gd = path(r, pl, g)
				for _, rc in ipairs(List_Dirs(gd) or {}) do
					roots[#roots + 1] = { dir = path(gd, rc, "bin"), game = gd, recomp = path(gd, rc) }
				end
			end
		end
	end
	roots[#roots + 1] = { dir = PACKS_DIR }
	for _, root in ipairs(roots) do
		for _, id in ipairs(List_Dirs(root.dir) or {}) do
			local pdir = path(root.dir, id)
			local ini = read_ini(path(pdir, "pack.ini"))
			if ini and ini.id and not seen[ini.id] then
				seen[ini.id] = true
				-- _SaberRecomp/: in the recomp folder (dev), else shipped in the pack
				local rdir = first_existing({ root.recomp and path(root.recomp, "_SaberRecomp", "game.ini") or nil, path(pdir, "_SaberRecomp", "game.ini") })
				rdir = rdir and dir_of(rdir) or nil
				local gini = rdir and read_ini(path(rdir, "game.ini")) or nil
				root = { dir = root.dir, game = root.game, gini = gini }
				local gtitle = (root.gini and root.gini.title) or ini.game or ini.title or ini.id
				local plat_id = (root.gini and root.gini.platform) or ini.platform or ""
				local pl = PLATFORMS[plat_id] or { name = (plat_id ~= "" and plat_id or "?"):upper() }
				-- game info: game.ini [info], else the first pack's [info]
				local g = game_for("game:" .. gtitle:lower(), gtitle, pl.name,
					root.gini and root.gini.info or ini.info, pdir, root.game)
				local e = { kind = "pack", id = ini.id, title = gtitle, name = ini.name or ini.id, platform = pl.name,
					info = ini.info, pack = ini, roms = {}, pack_dir = pdir, game = g,
					art = rdir and first_existing({ path(rdir, "cover.png") }) or nil }
				-- the recomp's own text, with game-level fallbacks
				e.rom_name = ini.info.rom_name or g.info.rom_name
				entries[#entries + 1] = e
				g.recomps[#g.recomps + 1] = e
			end
		end
	end
	for _, m in ipairs(MODULES) do
		local g = game_for("module:" .. m.id, m.name .. " games", m.name, m.info, nil, nil)
		g.base_art = m.art
		local e = { kind = "module", id = m.id, title = m.title, name = m.title, platform = m.name, info = m.info, roms = {}, game = g }
		entries[#entries + 1] = e
		g.recomps[#g.recomps + 1] = e
	end
	for _, e in ipairs(entries) do
		local old = keep[e.id]
		if old then e.roms, e.finding, e.out, e.on_found = old.roms, old.finding, old.out, old.on_found end
		if e.kind == "pack" then e.done = installed_recomp(e.title) == "pack:" .. e.id end
	end
	for _, g in ipairs(games) do
		g.done = false
		for _, e in ipairs(g.recomps) do if e.done then g.done = true end end
		g.art = art_for(g)
	end
	table.sort(games, function(a, b)
		local am, bm = a.id:sub(1, 7) == "module:", b.id:sub(1, 7) == "module:"
		if am ~= bm then return bm end
		return a.title:lower() < b.title:lower()
	end)
	if rc_cur then
		for _, e in ipairs(entries) do if e.id == rc_cur.id then rc_cur = e end end
	end
end

local function platforms()
	local l, seen = { "All" }, {}
	for _, e in ipairs(games) do
		if not seen[e.platform] then seen[e.platform] = true; l[#l + 1] = e.platform end
	end
	return l
end

local function apply_filters()
	shown = {}
	local ql = query:lower()
	local pl = platforms()[plat]
	for _, e in ipairs(games) do
		local ok = plat == 1 or e.platform == pl
		if ok and ql ~= "" then
			ok = e.title:lower():find(ql, 1, true) or (e.info.genre and e.info.genre:lower():find(ql, 1, true))
				or (e.info.developer and e.info.developer:lower():find(ql, 1, true))
		end
		if ok and status_f == 2 then ok = not e.done end
		if ok and status_f == 3 then ok = e.done end
		if ok then shown[#shown + 1] = e end
	end
	grid_sel = 1
	for i, e in ipairs(shown) do if e.id == sel_id then grid_sel = i end end
end

local function refresh(search)
	load_sources()
	build_catalog()
	apply_filters()
	if search then
		for _, e in ipairs(entries) do e.roms = {}; find(e) end
	end
end

-- ---------------------------------------------------------------------------
-- install job

local function read_status()
	local f = io.open(STATUS, "r")
	if not f then return nil end
	local st = {}
	for line in f:lines() do
		local k, v = line:match("^(%w+)=(.*)$")
		if k then st[k] = v end
	end
	f:close()
	st.progress = tonumber(st.progress or "0") or 0
	return st
end

-- e = catalog entry, rom = ROM path; module recomps are titled after the ROM
local function install(e, rom)
	if not exists(EXE) then return say("bin/SaberRecomper.exe is missing: run build.bat in the SaberRecomps repo", "#ff8080", 6) end
	local title = e.kind == "pack" and e.title or title_of(rom)
	os.remove(STATUS)
	local which = e.kind == "pack" and ("--pack " .. e.id) or ("--module " .. e.id)
	local cmd = string.format('start "" /B "%s" recomp "%s" %s --out "%s" --title "%s" --status "%s"', EXE, rom, which, GAMES, title, STATUS)
	Gui_Close("recomp")
	os.execute(cmd)
	job = { entry = e, title = title, started = Time(), status = { state = "running", progress = 0, message = "Starting the recompiler..." } }
	Gui_Open("job")
	saber.log("Saber Recomper: " .. cmd)
end

local function poll_job(dt)
	poll_t = poll_t - dt
	if poll_t > 0 then return end
	poll_t = 0.2
	local st = read_status()
	if st then job.status = st end
	if not st and Time() - job.started > 15 then
		st = { state = "error", progress = 0, message = "The recompiler didn't start (no status file)." }
		job.status = st
	end
	if st and (st.state == "done" or st.state == "error") then
		job.finished = true
		if st.state == "done" then
			Rescan_Library()
			Play_Sfx("over")
			build_catalog()
			apply_filters()
		end
	end
end

-- ---------------------------------------------------------------------------
-- built-in file browser (controller friendly): br = { mode = "folder"|"file", dir (nil = places),
-- exts, title, items }. Picking calls on_picked(path); closing cancels.

local br = nil
local on_picked

local function ext_ok(name, exts)
	local e = (name:match("(%.[^%.]+)$") or ""):lower()
	for _, x in ipairs(exts or {}) do if x == e then return true end end
	return false
end

local function br_load(dir)
	br.dir = dir
	local items = {}
	if not dir then
		-- places: your ROM sources, common folders, drives
		for _, s in ipairs(sources) do items[#items + 1] = { text = s.label, sub = s.dir, path = s.dir, kind = "dir" } end
		local home = os.getenv("USERPROFILE")
		if home then
			for _, d in ipairs({ "Desktop", "Downloads", "Documents" }) do
				items[#items + 1] = { text = d, sub = path(home, d), path = path(home, d), kind = "dir" }
			end
		end
		for c = string.byte("A"), string.byte("Z") do
			local root = string.char(c) .. ":\\"
			if List_Dirs(root) or List_Dir(root) then
				local d = (List_Dirs(root) or {})
				if #d > 0 or #(List_Dir(root) or {}) > 0 then items[#items + 1] = { text = "Drive " .. string.char(c) .. ":", sub = root, path = root, kind = "dir" } end
			end
		end
	else
		local parent = dir:match("^(.*)[\\/][^\\/]+[\\/]?$")
		if parent and parent:match("^%a:$") then parent = parent .. "\\" end
		items[#items + 1] = { text = "..", sub = parent or "Places", path = parent, kind = "up" }
		local dirs = List_Dirs(dir) or {}
		table.sort(dirs, function(a, b) return a:lower() < b:lower() end)
		for _, d in ipairs(dirs) do
			if not d:match("^[%.%$]") then items[#items + 1] = { text = d .. "\\", path = path((dir:gsub("[\\/]$", "")), d), kind = "dir" } end
		end
		if br.mode == "file" then
			local files = List_Dir(dir) or {}
			table.sort(files, function(a, b) return a:lower() < b:lower() end)
			for _, f in ipairs(files) do
				if ext_ok(f, br.exts) then items[#items + 1] = { text = f, sub = "ROM", path = path((dir:gsub("[\\/]$", "")), f), kind = "file" } end
			end
		end
	end
	br.items = items
end

local function entry_exts(e)
	if not e then return {} end
	if e.kind == "pack" then
		local t = {}
		for x in (e.pack.exts or ""):gmatch("%S+") do t[#t + 1] = x:lower() end
		return t
	end
	for _, m in ipairs(MODULES) do if m.id == e.id then return m.exts end end
	return {}
end

local function pick(kind, e, purpose)
	picking = { kind = kind, entry = e, purpose = purpose }
	br = { mode = kind == "folder" and "folder" or "file", exts = entry_exts(e),
		title = purpose == "source" and "Add a ROM folder" or (kind == "folder" and ("Search a folder for " .. e.title) or ("Choose a ROM for " .. e.title)) }
	br_load(nil)
	Gui_Open("browser")
	Gui_Select("br_list", 1)
end

local function draw_browser()
	if not br then return end
	local open, c = Gui_Popup("browser", Gui_Center(Gui_Screen(), 900, 640), { title = br.title })
	if not open then br = nil; picking = nil; return end
	local top
	top, c = Gui_Cut(c, "top", 24, 8)
	Draw_Text_Fit(br.dir or "Places: your ROM sources, common folders and drives", top.x, top.y, top.w, 16, "#9aa8c8")
	local foot
	foot, c = Gui_Cut(c, "bottom", 52, 12)
	local picked = Gui_List("br_list", c, #br.items, 52, function(i)
		local it = br.items[i]
		return { text = it.text, sub = it.sub, color = it.kind == "file" and "#8ef0a8" or nil }
	end)
	local function go(p) br_load(p); Gui_Select("br_list", 1) end
	if picked then
		local it = br.items[picked]
		if it.kind == "file" then
			local p = it.path
			br = nil
			Gui_Close("browser")
			on_picked(p)
			return
		end
		go(it.path)
	end
	local b = Gui_Split(foot, "h", 2, 10)
	if br and br.mode == "folder" then
		if Gui_Button("br_use", b[1], br.dir and "Use this folder" or "Open a folder first", { disabled = not br.dir }) then
			local p = br.dir
			br = nil
			Gui_Close("browser")
			on_picked(p)
			return
		end
	else
		Gui_Label(b[1], "Showing folders and " .. table.concat(br.exts, " ") .. " files", { size = 15, color = "#9aa8c8", valign = "center" })
	end
	if Gui_Button("br_close", b[2], "Cancel") then br = nil; picking = nil; Gui_Close("browser"); Gui_Popup_End(); return end
	-- B goes up a folder; at Places it closes
	if Gui_Back() then
		if br.dir then
			local up = br.items[1] and br.items[1].kind == "up" and br.items[1].path or nil
			go(up)
		else
			br = nil; picking = nil; Gui_Close("browser")
		end
	end
	Gui_Popup_End()
end

function on_picked(p)
	local pk = picking
	picking = nil
	if p == "" then return say("Cancelled.", "#9aa8c8", 2) end
	local e = pk.entry
	if pk.purpose == "source" then
		if add_source(p) then say("Added ROM folder " .. p .. ", searching it...", "#8ef0a8") else say("That folder is already a ROM source.", "#ffb070") end
		for _, x in ipairs(entries) do find(x, { q(p) }) end
		Gui_Open("sources")
	elseif pk.kind == "folder" then
		-- search one folder for this recomp; keep it as a source when it had a ROM
		say("Searching " .. p .. " for " .. e.title .. "...", "#b8c4e0", 30)
		e.on_found = function(found)
			if #found == 0 then return say("No usable ROM for " .. e.title .. " in " .. p, "#ffb070", 8) end
			add_source(p)
			say("Found " .. #found .. " ROM(s) for " .. e.title .. "; " .. p .. " was added to your ROM Sources", "#8ef0a8", 8)
		end
		find(e, { q(p) })
	else
		-- a single file: a module takes any ROM; a pack checks it with `find` on its folder first
		if e.kind == "module" then return install(e, p) end
		say("Checking " .. file_of(p) .. "...", "#b8c4e0", 30)
		e.on_found = function(found)
			for _, f in ipairs(found) do
				if f:lower() == p:lower() then flash = nil; return install(e, p) end
			end
			say(file_of(p) .. " isn't the ROM this pack needs: " .. (e.rom_name or "the exact ROM it was made for"), "#ff8080", 10)
		end
		find(e, { q(dir_of(p)) })
	end
end

-- ---------------------------------------------------------------------------
-- drawing

local function initials(r, title, size)
	Draw_Rect(r.x, r.y, r.w, r.h, { 40, 52, 92, 255 }, 10)
	local s = title:gsub("[^%w ]", ""):gsub("(%w)%w*%s*", "%1"):sub(1, 3):upper()
	Draw_Text(s, r.x + r.w / 2, r.y + r.h / 2 - size / 2, size, "#d8e2ff", "center")
end

local function art(r, e, fit)
	if not (e.art and Gui_Image(r, e.art, { fit = fit or "cover", radius = 10 })) then
		initials(r, e.title, math.floor(math.min(r.w, r.h) * 0.28))
	end
end

local function badge(x, y, text, bg)
	local tw = Text_Width(text, 14) + 18
	Draw_Rect(x - tw, y, tw, 22, bg, 11)
	Draw_Text(text, x - tw / 2, y + 3, 14, "#ffffff", "center")
	return x - tw - 6
end

local function rom_state(e)
	if e.finding and #e.roms == 0 then return "Looking for ROMs...", "#b8c4e0" end
	if #e.roms == 0 then return e.kind == "pack" and "ROM not found" or "No ROMs found", "#ffb070" end
	if e.kind == "pack" then return "ROM found", "#8ef0a8" end
	return #e.roms .. " ROMs found", "#8ef0a8"
end

-- a game's ROM summary over its recomps
local function game_state(g)
	local finding, roms = false, 0
	for _, e in ipairs(g.recomps) do
		if e.finding then finding = true end
		roms = roms + #e.roms
	end
	return finding, roms
end

local function draw_tile(i, r, st)
	local e = shown[i]
	-- st.focused / st.t belong to the whole grid (true for every tile while it has focus), so only the
	-- selected tile is highlighted: bright + lifted while the grid has focus, dim otherwise.
	local active = st.selected and st.focused
	local lift = active and st.t * 6 or 0
	local ar = { x = r.x, y = r.y - lift, w = r.w, h = r.h - 40 }
	art(ar, e)
	if st.selected then
		Draw_Outline(ar.x - 3, ar.y - 3, ar.w + 6, ar.h + 6, active and { 140, 190, 255, 255 } or { 140, 190, 255, 90 }, active and 4 or 2, 12)
	elseif st.hovered then
		Draw_Outline(ar.x - 2, ar.y - 2, ar.w + 4, ar.h + 4, { 255, 255, 255, 50 }, 2, 12)
	end
	if not st.selected then Draw_Rect(ar.x, ar.y, ar.w, ar.h, { 10, 14, 30, 70 }, 10) end
	local bx = ar.x + ar.w - 8
	local finding, roms = game_state(e)
	if e.done then badge(bx, ar.y + 8, "Installed", { 40, 140, 80, 230 })
	elseif roms == 0 and not finding and not e.base_art then badge(bx, ar.y + 8, "Needs ROM", { 200, 140, 40, 230 })
	elseif roms > 0 then badge(bx, ar.y + 8, "ROM found", { 60, 110, 200, 230 }) end
	local n = #e.recomps
	Draw_Text_Fit(e.title, r.x + 2, r.y + r.h - 36 - lift, r.w - 4, 17, "#ffffff")
	Draw_Text_Fit(e.platform .. "  ·  " .. n .. (n == 1 and " recomp" or " recomps"), r.x + 2, r.y + r.h - 16 - lift, r.w - 4, 13, "#9aa8c8")
end

local function recomp_state(e)
	if e.done then return "Installed", "#8ef0a8" end
	return rom_state(e)
end

local function open_recomp(e)
	rc_cur = e
	e.focus_default = true
	Gui_Open("recomp")
end

-- the game: art, info, and its recomps (pick one -> the recomp popup)
local function draw_details(r, g)
	Gui_Panel(r)
	local c = Gui_Inset(r, 20)
	local hero
	hero, c = Gui_Cut(c, "top", math.floor(c.h * 0.28), 12)
	art(hero, g, "contain")

	local col = Gui_Column(c, 4)
	Gui_Label(col:next(32), g.title, { size = 26, color = "#ffffff" })
	local meta = { g.platform }
	for _, k in ipairs({ "year", "developer", "genre" }) do if g.info[k] then meta[#meta + 1] = g.info[k] end end
	if g.info.players then meta[#meta + 1] = g.info.players .. " players" end
	Gui_Label(col:next(22), table.concat(meta, "  ·  "), { size = 16, color = "#9aa8c8" })
	col:skip(4)

	local n = #g.recomps
	local ROW = 96
	local list_h = math.min(n, 3) * (ROW + 4)
	local recomps_r, body = Gui_Cut(col:rest(), "bottom", list_h + 30, 12)

	local sc = Gui_Scroll("about", body)
	local bc = Gui_Column(sc, 6)
	local function para(text, size, color)
		local lines = Text_Wrap(text, size, sc.w)
		Gui_Label(bc:next(#lines * math.floor(size * 1.4)), text, { size = size, color = color, wrap = true })
	end
	if g.info.description then para(g.info.description, 16, "#e4eaff") end
	if g.done then para("Installed: on the GAMES tab", 14, "#8ef0a8") end
	Gui_Scroll_End(bc:used())

	local head, lr = Gui_Cut(recomps_r, "top", 22, 8)
	Gui_Label(head, n == 1 and "RECOMP  ·  pick it to install" or (n .. " RECOMPS  ·  pick one to install"), { size = 15, color = "#9aa8c8" })
	-- rows drawn by hand: the recomp's own cover (its box art once installed), name, state, source
	local picked = Gui_List("recomps", lr, n, ROW, function(i, rr, st)
		local e = g.recomps[i]
		local state, color = recomp_state(e)
		local src = e.kind == "pack" and (e.pack.source or "game pack") or "recompiles any ROM"
		local active = st.selected and st.focused
		Draw_Rect(rr.x, rr.y, rr.w, rr.h, active and { 70, 110, 220, 150 } or (st.hovered and { 255, 255, 255, 22 } or { 0, 0, 0, 50 }), 10)
		if active then Draw_Outline(rr.x, rr.y, rr.w, rr.h, { 140, 190, 255, 255 }, 2, 10) end
		local th = { x = rr.x + 8, y = rr.y + 8, w = math.floor((rr.h - 16) * 0.72), h = rr.h - 16 }
		if not (e.art and Gui_Image(th, e.art, { fit = "cover", radius = 6 })) then
			if e.base_art or e.game.base_art then
				if not Gui_Image(th, e.base_art or e.game.base_art, { fit = "cover", radius = 6 }) then initials(th, e.name, 18) end
			else initials(th, e.name, 18) end
		end
		local tx = th.x + th.w + 14
		local tw = rr.x + rr.w - tx - 10
		Draw_Text_Fit(e.name, tx, rr.y + 14, tw, 19, "#ffffff")
		Draw_Text_Fit(state, tx, rr.y + 42, tw, 15, color)
		Draw_Text_Fit(src, tx, rr.y + 64, tw, 13, "#9aa8c8")
	end)
	if picked then open_recomp(g.recomps[picked]) end
end

-- one recomp: what it is, its ROM, Install (or its ROM list), ways to find a ROM
local function draw_recomp_popup()
	if not rc_cur then return end
	local e = rc_cur
	local open, c = Gui_Popup("recomp", Gui_Center(Gui_Screen(), 760, 560), { title = e.title .. "  ·  " .. e.name })
	if not open then rc_cur = nil; return end

	local actions, body = Gui_Cut(c, "bottom", e.kind == "pack" and 140 or 260, 12)
	if e.art then
		local cover
		cover, body = Gui_Cut(body, "left", math.floor(body.h * 0.72), 16)
		Gui_Image(cover, e.art, { fit = "contain", radius = 10 })
	end
	local sc = Gui_Scroll("rc_about", body)
	local bc = Gui_Column(sc, 6)
	local function para(text, size, color)
		local lines = Text_Wrap(text, size, sc.w)
		Gui_Label(bc:next(#lines * math.floor(size * 1.4)), text, { size = size, color = color, wrap = true })
	end
	local about = e.info.about or (e.kind == "module" and e.info.description)
	if about then para(about, 16, "#e4eaff") end
	if e.kind == "pack" then
		if e.pack.source then para("Port: " .. e.pack.source .. (e.pack.license and ("  ·  " .. e.pack.license) or ""), 14, "#b8c4e0") end
		para("Needs: " .. (e.rom_name or "the exact ROM the pack was made for"), 14, "#b8c4e0")
		if e.art then para("This recomp's cover becomes the game's box art on the GAMES tab.", 14, "#b8c4e0") end
		if e.done then para("Installed: this recomp is the one on the GAMES tab", 14, "#8ef0a8")
		elseif e.game.done then para("Installing replaces the other recomp of " .. e.title .. " on the GAMES tab", 14, "#ffb070") end
	end
	Gui_Scroll_End(bc:used())

	local acol = Gui_Column(actions, 8)
	local state, scol = rom_state(e)
	if e.kind == "pack" then
		local rom = e.roms[1]
		local lr = acol:next(20)
		Draw_Text_Fit(state .. (rom and (": " .. rom) or (e.finding and "" or "  ·  add its folder in ROM Sources or search one below")), lr.x, lr.y, lr.w, 15, scol)
		local label = e.done and "Reinstall" or "Install"
		if Gui_Button("install", acol:next(56), rom and label or (label .. ": find the ROM first"),
			{ sub = rom and "Ready in seconds, no compiler needed" or nil, disabled = not rom }) then
			install(e, rom)
		end
	else
		local lr = acol:next(20)
		Draw_Text_Fit(state .. (#e.roms > 0 and "  ·  pick one to recompile it" or ""), lr.x, lr.y, lr.w, 15, scol)
		local box = acol:next(150)
		if #e.roms == 0 then
			Gui_Panel(box)
			Gui_Label(Gui_Inset(box, 14), "Search a folder or choose a ROM file below, or add your ROM folders in ROM Sources so they're always searched.", { size = 15, color = "#9aa8c8", wrap = true })
		else
			local picked = Gui_List("module_roms", box, #e.roms, 46, function(i)
				local p = e.roms[i]
				return { text = title_of(p), sub = installed(title_of(p)) and ("Installed  ·  " .. file_of(p)) or file_of(p) }
			end)
			if picked then install(e, e.roms[picked]) end
		end
	end
	local b = Gui_Split(acol:next(48), "h", 3, 8)
	if Gui_Button("find_again", b[1], e.finding and "Searching..." or "Search again", { disabled = e.finding ~= nil }) then
		e.roms = {}; find(e)
	end
	if Gui_Button("find_folder", b[2], "Search a folder...") then pick("folder", e, "entry") end
	if Gui_Button("pick_file", b[3], "Choose ROM file...") then pick("rom", e, "entry") end
	-- default focus: Install / the ROM list when there's a ROM, else a folder search
	if e.focus_default then
		e.focus_default = nil
		if #e.roms > 0 then Gui_Focus(e.kind == "pack" and "install" or "module_roms") else Gui_Focus("find_folder") end
	end
	Gui_Popup_End()
end

local function draw_sources_popup()
	local open, c = Gui_Popup("sources", Gui_Center(Gui_Screen(), 760, 540), { title = "ROM Sources" })
	if not open then return end
	local foot
	foot, c = Gui_Cut(c, "bottom", 52, 12)
	local hint
	hint, c = Gui_Cut(c, "top", 26, 6)
	Gui_Label(hint, "Folders searched (with subfolders) for ROMs the recomps can use.", { size = 15, color = "#9aa8c8" })
	local picked = Gui_List("source_list", c, #sources, 58, function(i)
		local s = sources[i]
		return { text = s.label, sub = s.custom and "Your folder" or s.dir }
	end)
	if picked then source_pick = sources[picked]; Gui_Open("source_menu") end
	local b = Gui_Split(foot, "h", 2, 10)
	if Gui_Button("add_folder", b[1], "Add folder...") then Gui_Close("sources"); pick("folder", nil, "source") end
	if Gui_Button("rescan", b[2], "Search all again") then refresh(true); say("Searching your ROM Sources...", "#b8c4e0", 3) end
	Gui_Popup_End()

	if source_pick then
		local s = source_pick
		local items = { "Open in Explorer" }
		if s.custom then items[#items + 1] = "Remove this folder" end
		local m = Gui_Menu("source_menu", items, { title = s.label, width = 520 })
		if m == 1 then open_in_explorer(s.dir)
		elseif m == 2 then
			local list = {}
			for _, d in ipairs(read_lines(ROM_DIRS)) do if d ~= s.dir then list[#list + 1] = d end end
			save_rom_dirs(list)
			refresh(true)
			say("Removed ROM folder " .. s.dir .. " (no files were deleted)", "#b8c4e0")
		end
		if m or not Gui_Is_Open("source_menu") then source_pick = nil end
	end
end

local function draw_job_popup()
	if not job then return end
	local busy = not job.finished
	if busy and not Gui_Is_Open("job") then Gui_Open("job") end -- can't be dismissed while working
	local open, c = Gui_Popup("job", Gui_Center(Gui_Screen(), 640, 300), { title = job.title, close_outside = false })
	if not open then job = nil; return end
	local st = job.status
	local col_c = st.state == "error" and "#ff8080" or (st.state == "done" and "#8ef0a8" or "#7fb2ff")
	local col = Gui_Column(c, 12)
	Gui_Progress(col:next(14), st.state == "done" and 1 or st.progress, nil, { color = col_c })
	local msg = st.message or ""
	if st.state == "done" then msg = "Installed! Find " .. job.title .. " on the GAMES tab." end
	if busy then msg = msg .. string.rep(".", math.floor(Time() * 3) % 4) end
	Gui_Label(col:next(140), msg, { size = 18, color = st.state == "error" and "#ffb0b0" or "#d8e2ff", wrap = true })
	if not busy then
		if Gui_Button("job_close", col:rest(), "OK") or Gui_Back() then Gui_Close("job"); job = nil end
	else
		Gui_Back() -- swallow B while working
	end
	Gui_Popup_End()
end

return {
	on_start = function()
		Gui_Style({ accent = "#5d8dff", panel = { 0, 0, 0, 80 }, panel_hi = { 70, 110, 220, 120 }, popup = { 24, 30, 58, 250 }, radius = 12 })
		refresh(true)
	end,

	frame = function(dt, w, h)
		for _, e in ipairs(entries) do if e.finding then poll_find(e) end end
		if job and not job.finished then poll_job(dt) end

		Draw_Gradient(0, 0, w, h, "#16203a", "#2a1846")
		local t = Time()
		for i = 0, 5 do
			Draw_Circle(w * (0.15 + 0.17 * i) + math.sin(t * 0.3 + i) * 40, h * 0.85 + math.cos(t * 0.4 + i) * 30, h * (0.25 + 0.05 * i), { 90, 140, 255, 10 })
		end

		local screen = Gui_Inset(Gui_Screen(), math.floor(w * 0.04), 24, math.floor(w * 0.04), 64)

		local head, body = Gui_Cut(screen, "top", 56, 14)
		local title_r, rest = Gui_Cut(head, "left", 300, 20)
		Gui_Label(title_r, "SABER RECOMP", { size = 34, color = "#ffffff", valign = "center" })
		local src_r, search_r = Gui_Cut(rest, "right", 220, 12)
		local nq, changed = Gui_TextInput("search", search_r, query, "Search games by title, genre or developer")
		if changed then query = nq; apply_filters() end
		if Gui_Button("sources_btn", src_r, "ROM Sources", { sub = #sources .. " folders" }) then Gui_Open("sources") end

		local bar
		bar, body = Gui_Cut(body, "top", 46, 14)
		local status_r, tabs_r = Gui_Cut(bar, "right", 260, 12)
		local np, pc = Gui_Tabs("platform", tabs_r, platforms(), plat)
		if pc then plat = np; apply_filters() end
		if Gui_Button("status_btn", status_r, "Show: " .. STATUS_FILTERS[status_f]) then
			status_f = status_f % #STATUS_FILTERS + 1
			apply_filters()
		end

		local line
		line, body = Gui_Cut(body, "top", 22, 10)
		if flash then
			flash.t = flash.t - dt
			Draw_Text_Fit(flash.text, line.x, line.y, line.w, 17, flash.color)
			if flash.t <= 0 then flash = nil end
		else
			Draw_Text_Fit(#shown .. " of " .. #games .. " games  ·  pick a game, then one of its recomps  ·  set up your ROM folders in ROM Sources", line.x, line.y, line.w, 17, "#9aa8c8")
		end

		local detail_r, grid_r = Gui_Cut(body, "right", math.floor(body.w * 0.40), 20)
		if #shown == 0 then
			Gui_Panel(grid_r)
			local c = Gui_Center(grid_r, math.min(grid_r.w - 40, 520), 140)
			local top, bottom = Gui_Cut(c, "top", 40, 40)
			Gui_Label(top, "No games match", { size = 24, color = "#ffffff", align = "center" })
			if Gui_Button("clear_filters", bottom, "Clear search and filters") then
				query, plat, status_f = "", 1, 1
				apply_filters()
			end
			Gui_Panel(detail_r)
		else
			local cols = math.max(2, math.floor(grid_r.w / 200))
			if focus_start then focus_start = false; Gui_Focus("catalog") end
			local gpicked, gsel = Gui_Grid("catalog", grid_r, #shown, { cols = cols, aspect = 0.68, gap = 18, sel = grid_sel }, draw_tile)
			if gsel and shown[gsel] then sel_id = shown[gsel].id end
			local cur = shown[1]
			for _, e in ipairs(shown) do if e.id == sel_id then cur = e end end
			-- A / click on a game: go to its list of recomps
			if gpicked and shown[gpicked] then
				local g = shown[gpicked]
				Gui_Focus("recomps"); Gui_Select("recomps", 1)
			end
			draw_details(detail_r, cur)
		end

		draw_recomp_popup()
		draw_sources_popup()
		draw_browser()
		draw_job_popup()

		if Gui_Back() then Channel_Close() end
		if job and not job.finished then
			Gui_Hints({ { "", "Working..." } })
		else
			Gui_Hints({ { "A", "Select" }, { "LB/RB", "Platform" }, { "B", "Close" } })
		end
	end,

	on_close = function() end,
}
