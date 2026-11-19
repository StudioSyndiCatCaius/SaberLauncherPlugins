-- Homebrew Hub channel: browse the homebrew database of hh.gbdev.io (Game Boy, Game Boy Color, GBA,
-- NES), download a game's ROM into this channel's roms/<platform>/ (kept apart from Saber's own games) and
-- play it in Saber's libretro host.
--
-- The API (hh3.gbdev.io/api/search?page=N) has no usable text search, so the whole catalog (~165
-- pages of 10) is fetched once, a few pages at a time, and cached in catalog.txt; search and filters
-- run locally. "Refresh catalog" on the sidebar fetches it again. Screenshots are cached in shots/.
--
-- Downloaded games are kept in library.txt with their full record, so PLAY never depends on the
-- catalog (works offline, before the catalog loads, and keeps the ROM you have when a refresh
-- points the entry at a newer file). Every start / PLAY visit re-reads roms/ and re-adopts any
-- catalog game whose ROM is there (e.g. a download that finished after the channel was closed).

local API = "https://hh3.gbdev.io/api/search?page="
local STATIC = "https://hh3.gbdev.io/static/"
local SITE = "https://hh.gbdev.io/game/"
local CATALOG = CHANNEL_DIR .. "/catalog.txt"
local LIBRARY = CHANNEL_DIR .. "/library.txt" -- the games you downloaded (same format, kept apart from the catalog)
local SHOTS = CHANNEL_DIR .. "/shots"
local ROMS = CHANNEL_DIR .. "/roms"
local OLD_ROMS = SABER_DIR .. "/games_roms" -- where earlier versions put them (moved on start)
local PAGE_WORKERS = 4
local MAX_SHOT_REQUESTS = 6

local EXT_PLATFORM = { gb = "gb", gbc = "gbc", gba = "gba", nes = "nes" }
local PLATFORMS = { { "gb", "Game Boy" }, { "gbc", "Game Boy Color" }, { "gba", "Game Boy Advance" }, { "nes", "NES" } }
local PLATFORM_NAME = {}
for _, p in ipairs(PLATFORMS) do PLATFORM_NAME[p[1]] = p[2] end

local games = {}      -- { slug, title, platform, typetag, dev, date, base, file, shot, tags, desc, key }
local shown = {}
local query = ""
local f_platform = nil -- nil = all
local f_type = nil
local tab = "browse" -- play | browse

local state = "idle"  -- idle | loading | ready | error
local message = nil
local load = nil      -- { next, total, done, pages = {}, inflight, failed }

local shots = {}      -- slug -> "have" | "pending" | "none"
local shot_requests = 0
local owned = {}      -- slug -> library record (downloaded games)
local on_disk = nil   -- "platform/file" (lowercase) -> true, from List_Dir; nil = not scanned yet
local dl = {}         -- slug -> true while downloading
local detail = nil

-- ---------------------------------------------------------------------------
-- helpers

local function clean(s)
	s = tostring(s or "")
	return (s:gsub("[\t\r]", " "):gsub("\n", "\\n"))
end

local function unclean(s)
	return (s:gsub("\\n", "\n"))
end

local function ext_of(name)
	return (name:match("%.([%w]+)$") or ""):lower()
end

local function rom_path(g)
	return ROMS .. "/" .. g.platform .. "/" .. g.file
end

local function disk_key(g)
	return g.platform .. "/" .. g.file:lower()
end

local function rom_present(g)
	if on_disk then return on_disk[disk_key(g)] == true end
	return Exists(rom_path(g))
end

-- the downloaded copy of a game (its library record), if its ROM is still on disk
local function downloaded(g)
	local r = owned[g.slug]
	if r and rom_present(r) then return r end
	return nil
end

local function is_saved(g)
	return downloaded(g) ~= nil
end

local function shot_path(g)
	return SHOTS .. "/" .. g.slug .. "." .. ext_of(g.shot)
end

local function url_encode(s)
	return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function entry_url(g, name)
	return STATIC .. g.base .. "/entries/" .. url_encode(g.slug) .. "/" .. url_encode(name)
end

-- ---------------------------------------------------------------------------
-- catalog

local FIELDS = { "slug", "title", "platform", "typetag", "dev", "date", "base", "file", "shot", "tags", "desc" }

local function keyed(g)
	g.key = (g.title .. " " .. g.dev .. " " .. g.tags):lower()
	return g
end

local function add_game(g)
	games[#games + 1] = keyed(g)
end

local function copy_record(g)
	local r = {}
	for _, k in ipairs(FIELDS) do r[k] = g[k] or "" end
	return keyed(r)
end

local function read_records(path)
	local out = {}
	local f = io.open(path, "rb")
	if not f then return out end
	for line in f:lines() do
		local g, i = {}, 1
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do
			if FIELDS[i] then g[FIELDS[i]] = field end
			i = i + 1
		end
		if g.slug and g.slug ~= "" and g.file and g.file ~= "" and EXT_PLATFORM[g.platform or ""] then
			for _, k in ipairs(FIELDS) do g[k] = g[k] or "" end
			g.desc = unclean(g.desc)
			out[#out + 1] = keyed(g)
		end
	end
	f:close()
	return out
end

-- written to <path>.tmp first, so a crash mid-write never loses the old file
local function write_records(path, list)
	local lines = {}
	for _, g in ipairs(list) do
		local row = {}
		for i, k in ipairs(FIELDS) do row[i] = clean(g[k]) end
		lines[#lines + 1] = table.concat(row, "\t")
	end
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "wb")
	if not f then return false end
	f:write(table.concat(lines, "\n"))
	f:close()
	os.remove(path)
	return os.rename(tmp, path) ~= nil
end

local function load_catalog()
	games = read_records(CATALOG)
	return #games > 0
end

local function save_catalog()
	write_records(CATALOG, games)
end

local function load_library()
	owned = {}
	for _, r in ipairs(read_records(LIBRARY)) do owned[r.slug] = r end
	-- a crash between remove and rename leaves only the .tmp
	if next(owned) == nil then
		for _, r in ipairs(read_records(LIBRARY .. ".tmp")) do owned[r.slug] = r end
	end
end

local function save_library()
	local list = {}
	for _, r in pairs(owned) do list[#list + 1] = r end
	table.sort(list, function(a, b) return a.slug < b.slug end)
	write_records(LIBRARY, list)
end

-- re-reads roms/ (one List_Dir per platform) and adopts catalog games whose ROM is there
local function scan_saved()
	on_disk = {}
	for _, p in ipairs(PLATFORMS) do
		for _, f in ipairs(List_Dir(ROMS .. "/" .. p[1]) or {}) do on_disk[p[1] .. "/" .. f:lower()] = true end
	end
	local changed = false
	for _, g in ipairs(games) do
		if not owned[g.slug] and on_disk[disk_key(g)] then
			owned[g.slug] = copy_record(g)
			changed = true
		end
	end
	if changed then save_library() end
end

-- Earlier versions downloaded into Saber's games_roms/<platform>/: move those ROMs (+ their art)
-- into roms/, for every library game and every catalog game found there.
local function migrate_old_roms()
	local moved = false
	local function try(r)
		local from = OLD_ROMS .. "/" .. r.platform .. "/" .. r.file
		local to = rom_path(r)
		if not Exists(from) or Exists(to) then return end
		Make_Dir(ROMS .. "/" .. r.platform)
		if os.rename(from, to) then
			moved = true
			if not owned[r.slug] then owned[r.slug] = copy_record(r) end
			local fb = from:gsub("%.[^%./\\]+$", "")
			local tb = to:gsub("%.[^%./\\]+$", "")
			for _, x in ipairs({ ".png", ".jpg", ".jpeg" }) do
				if Exists(fb .. x) then os.rename(fb .. x, tb .. x) end
			end
		end
	end
	for _, r in pairs(owned) do try(r) end
	for _, g in ipairs(games) do try(g) end
	if moved then
		save_library()
		Rescan_Library() -- they left the GAMES tab
	end
end

-- PLAY: the library's games whose ROM is on disk, by title
local function play_list()
	local list = {}
	for _, r in pairs(owned) do
		if rom_present(r) then list[#list + 1] = r end
	end
	table.sort(list, function(a, b) return a.title:lower() < b.title:lower() end)
	return list
end

local function refilter()
	shown = {}
	local words = {}
	for w in query:lower():gmatch("%S+") do words[#words + 1] = w end
	local list = tab == "play" and play_list() or games
	for _, g in ipairs(list) do
		local ok = (not f_platform or g.platform == f_platform) and (tab == "play" or not f_type or g.typetag == f_type)
		if ok then
			for _, w in ipairs(words) do
				if not g.key:find(w, 1, true) then ok = false break end
			end
		end
		if ok then shown[#shown + 1] = g end
	end
end

-- An API entry -> a game, or nil when it has no ROM Saber can play.
local function from_entry(e)
	if type(e) ~= "table" or type(e.files) ~= "table" or not e.slug then return nil end
	local file, platform = nil, nil
	for _, fl in ipairs(e.files) do
		if type(fl) == "table" and fl.filename and fl.playable then
			local p = EXT_PLATFORM[ext_of(fl.filename)]
			if p and (not file or fl.default) then file, platform = fl.filename, p end
		end
	end
	if not file then return nil end
	local shot = ""
	if type(e.screenshots) == "table" then
		for _, s in ipairs(e.screenshots) do
			local x = ext_of(s)
			if x == "png" or x == "jpg" or x == "jpeg" then shot = s break end
		end
	end
	local dev = ""
	if type(e.developer) == "table" then
		dev = e.developer.name or (e.developer[1] and e.developer[1].name) or ""
	elseif type(e.developer) == "string" then
		dev = e.developer
	end
	local tags = type(e.tags) == "table" and table.concat(e.tags, ", ") or ""
	return {
		slug = e.slug, title = e.title or e.slug, platform = platform, typetag = e.typetag or "game",
		dev = dev, date = e.date or "", base = e.basepath or ("database-" .. platform), file = file,
		shot = shot, tags = tags, desc = e.description or "",
	}
end

local function finish_load()
	games = {}
	for p = 1, load.total do
		for _, e in ipairs(load.pages[p] or {}) do
			local g = from_entry(e)
			if g then add_game(g) end
		end
	end
	local failed = load.failed
	load = nil
	if #games == 0 then
		state, message = "error", "Couldn't load the catalog."
		return
	end
	save_catalog()
	scan_saved()
	state = "ready"
	message = failed > 0 and (failed .. " pages couldn't be loaded; Refresh catalog to retry.") or nil
	refilter()
end

local fetch_page
local switch_tab

local function pump()
	if not load then return end
	while load.inflight < PAGE_WORKERS and load.next <= load.total do
		fetch_page(load.next)
		load.next = load.next + 1
	end
	if load.inflight == 0 and load.next > load.total then finish_load() end
end

fetch_page = function(p)
	load.inflight = load.inflight + 1
	local my = load
	Http_Get(API .. p, function(ok, body)
		if load ~= my then return end
		load.inflight = load.inflight - 1
		local data = ok and Json_Decode(body) or nil
		if type(data) == "table" and type(data.entries) == "table" then
			load.pages[p] = data.entries
			if p == 1 and tonumber(data.page_total) then load.total = tonumber(data.page_total) end
		else
			load.failed = load.failed + 1
		end
		load.done = load.done + 1
		pump()
	end)
end

local function fetch_catalog()
	if load then return end
	if not Online() then
		state, message = (#games > 0) and "ready" or "error", "Turn on Online Mode (Settings) to load the catalog."
		return
	end
	state, message = "loading", nil
	-- page 1 first: it tells how many pages there are
	load = { next = 2, total = 1, done = 0, pages = {}, inflight = 0, failed = 0 }
	fetch_page(1)
end

-- ---------------------------------------------------------------------------
-- screenshots / downloads

local function shot_for(g)
	if g.shot == "" then return nil end
	local s = shots[g.slug]
	if s == nil then
		s = Exists(shot_path(g)) and "have" or false
		shots[g.slug] = s
	end
	if s == "have" then return shot_path(g) end
	if s == false and Online() and shot_requests < MAX_SHOT_REQUESTS then
		shots[g.slug] = "pending"
		shot_requests = shot_requests + 1
		Http_Download(entry_url(g, g.shot), shot_path(g), function(ok)
			shot_requests = shot_requests - 1
			shots[g.slug] = ok and "have" or "none"
		end)
	end
	return nil
end

-- Box art: Saber uses "<rom stem>.png|.jpg" next to a ROM as its cover (launch splash, GAMES
-- tab), so the game's hub art is placed there.
local function side_art_base(r)
	return (rom_path(r):gsub("%.[^%./\\]+$", ""))
end

local function has_side_art(r)
	local base = side_art_base(r)
	return Exists(base .. ".png") or Exists(base .. ".jpg") or Exists(base .. ".jpeg")
end

local function side_art_path(r)
	local x = ext_of(r.shot)
	return side_art_base(r) .. "." .. (x == "jpeg" and "jpg" or x)
end

local function copy_file(from, to)
	local f = io.open(from, "rb")
	if not f then return false end
	local data = f:read("a")
	f:close()
	local o = io.open(to, "wb")
	if not o then return false end
	o:write(data)
	o:close()
	return true
end

-- Places the art next to the ROM if it isn't there yet (from the screenshot cache, else downloaded),
-- then calls done(). Never overwrites art that's already there (e.g. your own).
local function ensure_art(r, done)
	done = done or function() end
	if r.shot == "" or has_side_art(r) then return done() end
	if Exists(shot_path(r)) and copy_file(shot_path(r), side_art_path(r)) then return done() end
	if not Online() then return done() end
	Http_Download(entry_url(r, r.shot), side_art_path(r), function() done() end)
end

local function play(g)
	local have = downloaded(g)
	if have then
		if has_side_art(have) then
			Play_Rom(rom_path(have), have.platform)
		else
			ensure_art(have, function()
				Play_Rom(rom_path(have), have.platform)
			end)
		end
		return
	end
	if dl[g.slug] then return end
	if not Online() then
		Dialog_Info("Turn on Online Mode (Settings) to download " .. g.title .. ".", { "OK" })
		return
	end
	Make_Dir(ROMS .. "/" .. g.platform)
	dl[g.slug] = true
	Http_Download(entry_url(g, g.file), rom_path(g), function(ok, err)
		dl[g.slug] = nil
		if ok then
			owned[g.slug] = copy_record(g)
			save_library()
			if on_disk then on_disk[disk_key(g)] = true end
			refilter()
			local rec = owned[g.slug]
			ensure_art(rec, function()
				Play_Rom(rom_path(rec), rec.platform)
			end)
		else
			Dialog_Info("Couldn't download " .. g.file .. ":\n" .. tostring(err), { "OK" })
		end
	end)
end

local function delete_rom(g)
	Dialog_Info("Delete " .. g.title .. " ?", { "Delete", "Cancel" }, function(i)
		if i ~= 1 then return end
		local r = owned[g.slug] or g
		os.remove(rom_path(r))
		local base = side_art_base(r)
		for _, x in ipairs({ ".png", ".jpg", ".jpeg" }) do os.remove(base .. x) end
		if on_disk then on_disk[disk_key(r)] = nil end
		owned[g.slug] = nil
		save_library()
		refilter()
	end)
end

-- ---------------------------------------------------------------------------
-- pages

local function game_sub(g)
	local s = PLATFORM_NAME[g.platform] or g.platform
	if g.dev ~= "" then s = g.dev .. "  ·  " .. s end
	return s
end

local function detail_page()
	local g = detail
	local sub = game_sub(g)
	if g.date ~= "" then sub = sub .. "  ·  " .. g.date end
	if g.typetag ~= "game" then sub = sub .. "  ·  " .. g.typetag end
	UI_Title(g.title, sub)
	local img = shot_for(g)
	if img then UI_Image(img, { height = 300, cover = false }) end

	if dl[g.slug] then
		UI_Progress(-1, "Downloading " .. g.file .. "...")
	elseif UI_Button("play", is_saved(g) and "Play" or "Download and Play") then
		play(g)
	end
	if UI_Button("site", "Open on hh.gbdev.io") then Open_Url(SITE .. g.slug) end
	if is_saved(g) and UI_Button("delete", "Delete ROM") then delete_rom(g) end

	if g.tags ~= "" then UI_Text("Tags: " .. g.tags, "accent") end
	if g.desc ~= "" then UI_Text(g.desc, "text") end
	local have = downloaded(g)
	UI_Text("File: " .. (have and (have.platform .. "/" .. have.file .. "  (downloaded)") or g.file), "muted")

	UI_Hints({ { "A", "Select" }, { "B", "Back" } })
	if UI_Back() then detail = nil end
end

local function count(pred)
	local n = 0
	for _, g in ipairs(games) do if pred(g) then n = n + 1 end end
	return n
end

switch_tab = function(t)
	if tab == t then return end
	tab = t
	if t == "play" then scan_saved() end
	refilter()
end

local counts = nil
local function sidebar_rows()
	if not counts or counts.n ~= #games then
		counts = { n = #games, plat = {}, type = {} }
		for _, p in ipairs(PLATFORMS) do
			counts.plat[p[1]] = count(function(g) return g.platform == p[1] end)
		end
		for _, t in ipairs({ "game", "demo", "tool", "music" }) do
			counts.type[t] = count(function(g) return g.typetag == t end)
		end
	end
	local rows, acts = {}, {}
	local function add(row, act) rows[#rows + 1] = row; acts[#rows] = act end

	add({ text = "Platform", header = true })
	add({ text = "All", radio = true, checked = f_platform == nil }, function() f_platform = nil end)
	for _, p in ipairs(PLATFORMS) do
		local id = p[1]
		local n = counts.plat[id]
		if tab == "play" then
			n = 0
			for _, r in pairs(owned) do if r.platform == id and rom_present(r) then n = n + 1 end end
		end
		add({ text = p[2], radio = true, checked = f_platform == id, count = n }, function() f_platform = id end)
	end
	if tab == "play" then return rows, acts end

	add({ text = "Type", header = true })
	add({ text = "All", radio = true, checked = f_type == nil }, function() f_type = nil end)
	for _, t in ipairs({ { "game", "Games" }, { "demo", "Demos" }, { "tool", "Tools" }, { "music", "Music" } }) do
		local id = t[1]
		if counts.type[id] > 0 then
			add({ text = t[2], radio = true, checked = f_type == id, count = counts.type[id] }, function() f_type = id end)
		end
	end
	add({ text = "Catalog", header = true })
	add({ text = load and "Refreshing..." or "Refresh catalog" }, function() fetch_catalog() end)
	return rows, acts
end

local TABS = { "play", "browse" }

local function view()
	local sel, changed = UI_Tabs("tabs", { "PLAY", "BROWSE" }, tab == "play" and 1 or 2)
	if changed then
		detail = nil
		switch_tab(TABS[sel])
	end

	if detail then return detail_page() end

	if tab == "browse" and state == "loading" and #games == 0 then
		UI_Title("Homebrew Hub", "hh.gbdev.io")
		local total = load and load.total or 1
		local done = load and load.done or 0
		UI_Progress(total > 1 and done / total or -1, string.format("Loading the catalog... %d / %d pages", done, total))
		UI_Hints({ { "B", "Close" } })
		return
	end
	if tab == "browse" and state == "error" and #games == 0 then
		UI_Title("Homebrew Hub", "hh.gbdev.io")
		UI_Text(message or "Couldn't load the catalog.", "warn")
		if UI_Button("retry", "Try again") then fetch_catalog() end
		UI_Hints({ { "A", "Select" }, { "B", "Close" } })
		return
	end

	local sub
	if tab == "play" then
		sub = #shown .. " downloaded games"
	else
		sub = #shown .. " of " .. #games .. " homebrews  ·  hh.gbdev.io"
		if load then sub = sub .. string.format("  ·  refreshing %d / %d", load.done, load.total) end
	end
	UI_Title(tab == "play" and "Play" or "Browse", sub)

	local rows, acts = sidebar_rows()
	local picked_row = UI_Sidebar("filters", rows, { width = 320 })
	if picked_row and acts[picked_row] then
		acts[picked_row]()
		refilter()
	end

	local text, changed = UI_SearchBar("search", query, "Search titles, developers, tags")
	if changed then
		query = text
		refilter()
	end
	if message and tab == "browse" then UI_Text(message, "warn") end
	if #shown == 0 then
		if tab == "play" and query == "" and not f_platform then
			UI_Text("No downloaded games yet. Find some on the BROWSE tab (RB).", "muted")
		else
			UI_Text("Nothing matches these filters.", "muted")
		end
	end

	local picked = UI_Grid("games", #shown, { cols = 5, aspect = 0.9, cover = true }, function(i)
		local g = shown[i]
		local t = { title = g.title, sub = game_sub(g), image = shot_for(g) }
		if dl[g.slug] then
			t.progress = 0
		elseif tab == "play" then
			t.sub = PLATFORM_NAME[g.platform]
		elseif is_saved(g) then
			t.badge = "Downloaded"
		elseif g.typetag ~= "game" then
			t.badge = g.typetag:sub(1, 1):upper() .. g.typetag:sub(2)
		end
		return t
	end)
	if picked then
		if tab == "play" then play(shown[picked]) else detail = shown[picked] end
	end
	UI_Hints({ { "A", tab == "play" and "Play" or "Info" }, { "LB / RB", "Tabs" }, { "Left", "Filters" }, { "B", "Close" } })
end

-- ---------------------------------------------------------------------------

return {
	on_start = function()
		Make_Dir(SHOTS)
		load_library()
		local have_catalog = load_catalog()
		migrate_old_roms()
		scan_saved()
		local added = false
		for _, r in ipairs(play_list()) do
			if r.shot ~= "" and not has_side_art(r) and Exists(shot_path(r)) then
				added = copy_file(shot_path(r), side_art_path(r)) or added
			end
		end
		if #play_list() > 0 then tab = "play" end
		if have_catalog then
			state = "ready"
		else
			fetch_catalog()
		end
		refilter()
		UI_Open(view, function() Channel_Close() end)
	end,

	frame = function(_, w, h)
		-- bkg.glsl, else (older Saber / shader didn't compile) a plain gradient
		if not (Draw_Shader and Draw_Shader("bkg.glsl", 0, 0, w, h)) then
			Draw_Gradient(0, 0, w, h, "#1d3b2a", "#0b1710")
		end
	end,

	on_close = function()
		load = nil
	end,
}
