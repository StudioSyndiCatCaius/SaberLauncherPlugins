-- GOG channel (test): sign in to GOG, browse the games you own with filters on the left, open a
-- game's info page and install it the way Galaxy does (galaxy.lua): the game's files straight from
-- GOG's CDN into APP/games/<Title>/ with a generated _Saber folder, so it plays from GAMES.
--
-- Login: GOG's OAuth page opens in the browser (Galaxy's public client id, like lgogdownloader /
-- Heroic). After signing in, the browser lands on embed.gog.com/on_login_success?code=...; copy that
-- address and the channel picks it up from the clipboard (or paste it into the box). The refresh
-- token is kept in token.txt here, so later starts sign in silently.

local json = dofile(CHANNEL_DIR .. "/json.lua")
local galaxy = dofile(CHANNEL_DIR .. "/galaxy.lua")

local CLIENT_ID = "46899977096215655"
local CLIENT_SECRET = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
local REDIRECT = "https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient"
local LOGIN_URL = "https://auth.gog.com/auth?client_id=" .. CLIENT_ID .. "&redirect_uri=" .. REDIRECT .. "&response_type=code&layout=client2"
local TOKEN_URL = "https://auth.gog.com/token?client_id=" .. CLIENT_ID .. "&client_secret=" .. CLIENT_SECRET
local LIBRARY_URL = "https://embed.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page="
local PRODUCT_URL = "https://api.gog.com/products/%s?expand=downloads,description"
local TOKEN_FILE = CHANNEL_DIR .. "/token.txt"
local COVERS = CHANNEL_DIR .. "/covers"

local state = "start" -- start | offline | signing_in | login | loading | library | error
local message = ""
local access, refresh = nil, nil
local after_token = nil -- what to do once a refreshed token arrives (nil = load the library)
local paste = ""
local last_clip, clip_at = "", 0
local games = {}
local user_tags = {} -- { {id=, name=} } the account's own GOG tags
local page, pages = 0, 0
local covers = {} -- id -> "have" | "pending" | "failed"
local inflight = 0

local detail = nil -- the game whose info page is open
local products = {} -- id -> { state = "loading" | "ok" | "failed", data = <product json>, bg = "have" | "pending" | "failed" }

-- ---------------------------------------------------------------------------
-- helpers

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

local function write_file(path, s)
	local f = io.open(path, "wb")
	if not f then return false end
	f:write(s)
	f:close()
	return true
end

local function fmt_size(n)
	n = tonumber(n) or 0
	if n >= 1024 ^ 3 then return string.format("%.1f GB", n / 1024 ^ 3) end
	if n >= 1024 ^ 2 then return string.format("%d MB", math.floor(n / 1024 ^ 2)) end
	if n >= 1024 then return string.format("%d KB", math.floor(n / 1024)) end
	return n .. " B"
end

-- a name Windows accepts as a folder / file
local function safe_name(s)
	s = (s or ""):gsub('[<>:"/\\|%?%*%c]', ""):gsub("%s+", " ")
	s = s:gsub("^%s+", ""):gsub("[%s%.]+$", "")
	return s ~= "" and s or "game"
end

local function strip_html(s)
	s = (s or ""):gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</?[Pp]>", "\n"):gsub("<[^>]->", "")
	s = s:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#0?39;", "'"):gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
	s = s:gsub("[ \t]+", " "):gsub("\n%s*\n+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

local function shorten(s, n)
	if #s <= n then return s end
	local cut = s:sub(1, n):match("^(.*)%s") or s:sub(1, n)
	return cut .. "…"
end

-- GOG's release dates come as { date = "2015-05-18 00:00:00.000000" }, a string, or a unix time
local function year_of(rd)
	if type(rd) == "table" then rd = rd.date end
	if type(rd) == "number" then
		if rd > 100000 then return tonumber(os.date("!%Y", math.floor(rd))) end
		return nil
	end
	if type(rd) == "string" then return tonumber(rd:match("^(%d%d%d%d)")) end
	return nil
end

local function platforms_of(g)
	local t = {}
	if g.win then t[#t + 1] = "Windows" end
	if g.mac then t[#t + 1] = "Mac" end
	if g.linux then t[#t + 1] = "Linux" end
	return table.concat(t, ", ")
end

-- ---------------------------------------------------------------------------
-- filters: groups of options; OR inside a group, AND between groups

local sort_by = "title"
local query = ""
local active = {} -- group key -> { [option id] = true }
local shown = {} -- indices into games
local counts = {} -- "group/option" -> games matching with that option (other groups applied)
local groups = {}
local focused_game = nil
local sign_out -- forward

local SORTS = {
	{ id = "title", text = "Title A-Z" },
	{ id = "newest", text = "Newest first" },
	{ id = "oldest", text = "Oldest first" },
	{ id = "rating", text = "Highest rated" },
}

local function add_option(list, seen, id, text, match)
	if seen[id] then return end
	seen[id] = true
	list[#list + 1] = { id = id, text = text, match = match }
end

-- builds the filter groups from what the library actually contains
local function build_groups()
	groups = {}

	local plat = {}
	local any_mac, any_linux = false, false
	for _, g in ipairs(games) do
		any_mac = any_mac or g.mac
		any_linux = any_linux or g.linux
	end
	plat[#plat + 1] = { id = "win", text = "Windows", match = function(g) return g.win end }
	if any_mac then plat[#plat + 1] = { id = "mac", text = "Mac", match = function(g) return g.mac end } end
	if any_linux then plat[#plat + 1] = { id = "linux", text = "Linux", match = function(g) return g.linux end } end
	groups[#groups + 1] = { key = "platform", name = "Platform", options = plat }

	local genres, seen = {}, {}
	for _, g in ipairs(games) do
		if g.genre ~= "" then
			local genre = g.genre
			add_option(genres, seen, genre, genre, function(x) return x.genre == genre end)
		end
	end
	table.sort(genres, function(a, b) return a.text < b.text end)
	if #genres > 0 then groups[#groups + 1] = { key = "genre", name = "Genre", options = genres } end

	local decades
	decades, seen = {}, {}
	for _, g in ipairs(games) do
		if g.year then
			local d = g.year - g.year % 10
			add_option(decades, seen, tostring(d), d .. "s", function(x) return x.year and x.year - x.year % 10 == d end)
		end
	end
	table.sort(decades, function(a, b) return a.id > b.id end)
	if #decades > 0 then groups[#groups + 1] = { key = "decade", name = "Released", options = decades } end

	local tags = {}
	for _, t in ipairs(user_tags) do
		local id = t.id
		tags[#tags + 1] = { id = id, text = t.name, match = function(x) return x.tags[id] end }
	end
	if #tags > 0 then groups[#groups + 1] = { key = "tag", name = "My Tags", options = tags } end

	local status = {}
	status[#status + 1] = { id = "installed", text = "Installed", match = function(g) return galaxy.installed[g.id] ~= nil end }
	status[#status + 1] = { id = "new", text = "New in library", match = function(g) return g.is_new end }
	status[#status + 1] = { id = "updates", text = "Has updates", match = function(g) return g.updates > 0 end }
	status[#status + 1] = { id = "dlc", text = "Has DLC", match = function(g) return g.dlcs > 0 end }
	groups[#groups + 1] = { key = "status", name = "Status", options = status }
end

local function passes_group(g, grp, skip)
	if grp.key == skip then return true end
	local sel = active[grp.key]
	if not sel or next(sel) == nil then return true end
	for _, o in ipairs(grp.options) do
		if sel[o.id] and o.match(g) then return true end
	end
	return false
end

local function passes(g, skip)
	if query ~= "" and not g.lower:find(query:lower(), 1, true) then return false end
	for _, grp in ipairs(groups) do
		if not passes_group(g, grp, skip) then return false end
	end
	return true
end

local function refilter()
	shown = {}
	for i, g in ipairs(games) do
		if passes(g) then shown[#shown + 1] = i end
	end
	local cmp
	if sort_by == "newest" then
		cmp = function(a, b) return (games[a].year or 0) > (games[b].year or 0) or ((games[a].year or 0) == (games[b].year or 0) and games[a].lower < games[b].lower) end
	elseif sort_by == "oldest" then
		cmp = function(a, b) return (games[a].year or 9999) < (games[b].year or 9999) or ((games[a].year or 0) == (games[b].year or 0) and games[a].lower < games[b].lower) end
	elseif sort_by == "rating" then
		cmp = function(a, b) return games[a].rating > games[b].rating or (games[a].rating == games[b].rating and games[a].lower < games[b].lower) end
	else
		cmp = function(a, b) return games[a].lower < games[b].lower end
	end
	table.sort(shown, cmp)

	-- facet counts: how many games each option would show, given every other group's choice
	counts = {}
	for _, grp in ipairs(groups) do
		for _, o in ipairs(grp.options) do
			local n = 0
			for _, g in ipairs(games) do
				if o.match(g) and passes(g, grp.key) then n = n + 1 end
			end
			counts[grp.key .. "/" .. o.id] = n
		end
	end
end

local function any_filter()
	for _, sel in pairs(active) do
		if next(sel) then return true end
	end
	return false
end

-- the sidebar rows, plus what each one does
local function sidebar_rows()
	local rows, acts = {}, {}
	local function add(row, act)
		rows[#rows + 1] = row
		acts[#acts + 1] = act or false
	end
	add({ text = "Sort", header = true })
	for _, s in ipairs(SORTS) do
		add({ text = s.text, radio = true, checked = sort_by == s.id }, function() sort_by = s.id end)
	end
	if any_filter() then
		add({ text = "", header = true })
		add({ text = "Clear all filters" }, function() active = {} end)
	end
	for _, grp in ipairs(groups) do
		add({ text = grp.name, header = true })
		local sel = active[grp.key] or {}
		for _, o in ipairs(grp.options) do
			add({ text = o.text, checked = sel[o.id] == true, count = counts[grp.key .. "/" .. o.id] }, function()
				active[grp.key] = active[grp.key] or {}
				active[grp.key][o.id] = not active[grp.key][o.id] or nil
			end)
		end
	end
	add({ text = "Account", header = true })
	add({ text = "Sign out" }, function() sign_out() end)
	return rows, acts
end

-- ---------------------------------------------------------------------------
-- sign in + library

sign_out = function()
	os.remove(TOKEN_FILE)
	access, refresh, games, shown, state, message, detail = nil, nil, {}, {}, "login", "", nil
end

local load_page -- forward

local function got_token(ok, body, status)
	local t = ok and json.decode(body)
	if not t or not t.access_token then
		saber.log("GOG token failed: " .. tostring(status) .. " " .. tostring(body))
		after_token = nil
		sign_out()
		message = ok and "GOG didn't accept that code. Sign in again." or ("Sign-in failed: " .. tostring(body))
		return
	end
	access, refresh = t.access_token, t.refresh_token
	write_file(TOKEN_FILE, refresh)
	local k = after_token
	after_token = nil
	if k then return k() end
	games, page, pages = {}, 0, 0
	state = "loading"
	load_page(1)
end

local function exchange_code(code)
	state = "signing_in"
	message = ""
	Http_Get(TOKEN_URL .. "&grant_type=authorization_code&code=" .. code .. "&redirect_uri=" .. REDIRECT, got_token)
end

-- k: what to do with the fresh token (nil = sign in and load the library)
local function refresh_login(k)
	after_token = k
	if not k then state = "signing_in" end
	Http_Get(TOKEN_URL .. "&grant_type=refresh_token&refresh_token=" .. refresh, got_token)
end

-- a GET with the account's token; an expired token is refreshed once and the call retried
local function authed_get(url, cb, retried)
	Http_Get(url, function(ok, body, status)
		if status == 401 and refresh and not retried then
			return refresh_login(function() authed_get(url, cb, true) end)
		end
		cb(ok, body, status)
	end, { Authorization = "Bearer " .. (access or "") })
end

-- galaxy.lua's HTTP: auth = with the account's token
galaxy.get = function(url, cb, auth)
	if auth then return authed_get(url, cb) end
	Http_Get(url, cb)
end

-- the code from a pasted on_login_success address, or a bare code
local function code_from(text)
	text = (text or ""):gsub("%s", "")
	local code = text:match("on_login_success.-[?&]code=([%w%-_%.]+)")
	if code then return code end
	if #text >= 30 and text:match("^[%w%-_%.]+$") then return text end
	return nil
end

load_page = function(n)
	authed_get(LIBRARY_URL .. n, function(ok, body)
		local t = ok and json.decode(body)
		if not t or not t.products then
			state = "error"
			message = "Couldn't load your library: " .. tostring(ok and "unexpected reply" or body)
			return
		end
		if n == 1 then
			user_tags = {}
			for _, tg in ipairs(t.tags or {}) do
				if tg.id and tg.name then user_tags[#user_tags + 1] = { id = tostring(tg.id), name = tg.name } end
			end
		end
		for _, p in ipairs(t.products) do
			local works = p.worksOn or {}
			local tags = {}
			for _, id in ipairs(p.tags or {}) do tags[tostring(id)] = true end
			local title = p.title or "?"
			games[#games + 1] = {
				id = tostring(math.tointeger(p.id) or p.id),
				title = title,
				lower = title:lower(),
				image = p.image,
				url = p.url,
				genre = type(p.category) == "string" and p.category or "",
				year = year_of(p.releaseDate),
				win = works.Windows == true,
				mac = works.Mac == true,
				linux = works.Linux == true,
				rating = tonumber(p.rating) or 0,
				is_new = p.isNew == true,
				updates = tonumber(p.updates) or 0,
				dlcs = tonumber(p.dlcCount) or 0,
				tags = tags,
			}
		end
		page, pages = n, t.totalPages or n
		if n < pages then
			load_page(n + 1)
		else
			build_groups()
			refilter()
			state = "library"
		end
	end)
end

-- cover path once downloaded; starts a few downloads at a time for the tiles on screen
local function cover_for(g)
	local path = COVERS .. "/" .. g.id .. ".jpg"
	local st = covers[g.id]
	if st == "have" then return path end
	if st or not g.image or inflight >= 6 then return nil end
	covers[g.id] = "pending"
	inflight = inflight + 1
	Http_Download("https:" .. g.image .. "_392.jpg", path, function(ok)
		inflight = inflight - 1
		covers[g.id] = ok and "have" or "failed"
	end)
	return nil
end

local function game_sub(g)
	local parts = {}
	if g.genre ~= "" then parts[#parts + 1] = g.genre end
	if g.year then parts[#parts + 1] = tostring(g.year) end
	return table.concat(parts, "  ·  ")
end

-- ---------------------------------------------------------------------------
-- product info + download

local function load_product(g)
	if products[g.id] then return products[g.id] end
	local p = { state = "loading" }
	products[g.id] = p
	authed_get(PRODUCT_URL:format(g.id), function(ok, body)
		local t = ok and json.decode(body)
		if t and t.id then
			p.state, p.data = "ok", t
		else
			p.state = "failed"
			p.error = ok and "unexpected reply" or tostring(body)
		end
	end)
	return p
end

-- the product's banner (images.background), downloaded once
local function product_banner(g, p)
	local path = COVERS .. "/" .. g.id .. "_bg.jpg"
	if p.bg == "have" then return path end
	if p.bg then return nil end
	local img = p.data and p.data.images and p.data.images.background
	if type(img) ~= "string" then
		p.bg = "failed"
		return nil
	end
	local f = io.open(path, "rb")
	if f then
		f:close()
		p.bg = "have"
		return path
	end
	p.bg = "pending"
	Http_Download((img:sub(1, 2) == "//" and "https:" or "") .. img, path, function(ok) p.bg = ok and "have" or "failed" end)
	return nil
end

-- Windows installer, English if there is one
local function pick_installer(data)
	local list = data and data.downloads and data.downloads.installers or {}
	local first = nil
	for _, inst in ipairs(list) do
		if inst.os == "windows" then
			if inst.language == "en" then return inst end
			first = first or inst
		end
	end
	return first
end

-- ---------------------------------------------------------------------------
-- pages (Saber's UI widgets)

local function detail_page(g)
	if UI_Back() then
		detail = nil
		return
	end
	local p = load_product(g)
	local info = { platforms_of(g) }
	if g.genre ~= "" then table.insert(info, 1, g.genre) end
	if g.year then table.insert(info, 2, tostring(g.year)) end
	UI_Title(g.title, table.concat(info, "  ·  "))

	local _, sh = Screen_Size()
	local banner = p.state == "ok" and product_banner(g, p) or nil
	UI_Image(banner or cover_for(g) or "", { height = math.floor(math.min(300, sh * 0.26)) })

	if p.state == "loading" then
		UI_Progress(-1, "Loading game info…")
	elseif p.state == "failed" then
		UI_Text("Couldn't load the game info: " .. tostring(p.error), "warn")
	else
		local d = p.data
		local lead = strip_html(d.description and (d.description.lead ~= "" and d.description.lead or d.description.full) or "")
		if lead ~= "" then UI_Text(shorten(lead:gsub("\n", "  "), 420), "text") end
		local inst = pick_installer(d)
		if inst then
			local lang = inst.language_full or inst.language or ""
			local ver = (inst.version and inst.version ~= "") and ("v" .. inst.version .. "  ·  ") or ""
			UI_Text("Windows  ·  " .. ver .. fmt_size(inst.total_size) .. "  ·  " .. lang, "muted")
		else
			UI_Text("No Windows build on GOG for this game.", "warn")
		end
	end

	-- install state + actions
	local st = galaxy.status(g.id, g.title)
	local s = st and st.state or "none"
	if s == "installed" then
		UI_Text("Installed in " .. st.folder .. "  ·  play it from GAMES", "accent")
	elseif s == "preparing" then
		UI_Progress(-1, "Preparing install…  reading GOG's manifests")
	elseif s == "queued" then
		UI_Progress(-1, "Waiting for another download to finish…")
	elseif s == "finishing" then
		UI_Progress(-1, "Finishing…")
	elseif s == "downloading" then
		local frac = (st.total or 0) > 0 and st.got / st.total or -1
		local label = "Installing"
		if frac >= 0 then label = string.format("Installing  ·  %d%%  ·  %s of %s", math.floor(frac * 100), fmt_size(st.got), fmt_size(st.total)) end
		UI_Progress(frac, label)
		if UI_Button("pause", "Pause install") then galaxy.pause(g.id) end
	elseif s == "failed" or s == "partial" then
		if st.error then UI_Text(st.error, st.error == "Paused" and "muted" or "warn") end
		if UI_Button("resume", s == "partial" and "Resume install" or "Retry install") then
			galaxy.install(g.id, { title = g.title, cover = COVERS .. "/" .. g.id .. ".jpg" })
		end
	elseif g.win then
		local inst = p.state == "ok" and pick_installer(p.data)
		local size = inst and ("  (about " .. fmt_size(inst.total_size) .. ")") or ""
		if UI_Button("install", "Install" .. size) then
			galaxy.install(g.id, { title = g.title, cover = COVERS .. "/" .. g.id .. ".jpg" })
		end
	else
		UI_Text("This game has no Windows version.", "warn")
	end
	if UI_Button("gogcom", "Open on GOG.com") and g.url then Open_Url("https://www.gog.com" .. g.url) end
	if UI_Button("back", "Back to library") then detail = nil end
	UI_Hints({ { "A", "Select" }, { "B", "Back" } })
end

local function view()
	galaxy.poll()
	if state == "offline" then
		UI_Title("Good Old Games", "Online Mode is off")
		UI_Text("This channel needs the internet. Turn on Online Mode in Settings, then open it again.", "warn")
		if UI_Button("close", "Close") then UI_Close() end
		return
	end

	if state == "signing_in" or state == "start" then
		UI_Title("Good Old Games", "Signing in…")
		UI_Progress(-1)
		return
	end

	if state == "login" then
		UI_Title("Sign in to GOG", "Connect your GOG account to see your games")
		UI_Text("1.  Open the GOG sign-in page and log in.", "text")
		UI_Text("2.  The browser ends on a blank page (embed.gog.com/on_login_success…). Copy its address: Ctrl+L, then Ctrl+C.", "text")
		UI_Text("3.  Come back here: the channel picks it up from the clipboard by itself (or paste it below with Ctrl+V).", "text")
		if message ~= "" then UI_Text(message, "warn") end
		if UI_Button("open", "Open GOG sign-in page") then Open_Url(LOGIN_URL) end
		local text, _, submitted = UI_SearchBar("paste", paste, "Paste the address or code here")
		paste = text
		if submitted and paste ~= "" then
			local code = code_from(paste)
			if code then
				exchange_code(code)
			else
				message = "That doesn't look like the on_login_success address."
			end
		end
		-- watch the clipboard twice a second
		if Time() - clip_at > 0.5 then
			clip_at = Time()
			local clip = Clipboard()
			if clip ~= last_clip then
				last_clip = clip
				local code = code_from(clip)
				if code and clip:find("on_login_success", 1, true) then exchange_code(code) end
			end
		end
		UI_Hints({ { "A", "Select" }, { "B", "Close" } })
		return
	end

	if state == "loading" then
		UI_Title("Good Old Games", pages > 0 and ("Loading your library…  page " .. page .. " of " .. pages) or "Loading your library…")
		UI_Progress(pages > 0 and page / pages or -1, #games .. " games so far")
		return
	end

	if state == "error" then
		UI_Title("Good Old Games", "Something went wrong")
		UI_Text(message, "warn")
		if UI_Button("retry", "Try again") then
			games = {}
			state = "loading"
			load_page(1)
		end
		if UI_Button("signout", "Sign out") then sign_out() end
		return
	end

	if detail then return detail_page(detail) end

	-- library: title, filters on the left, search + grid on the right
	local sub = #games .. " games"
	if #shown ~= #games then sub = #shown .. " of " .. sub end
	if focused_game then
		local g = focused_game
		sub = sub .. "     ·     " .. g.title .. "  ·  " .. platforms_of(g)
	end
	UI_Title("Your GOG Library", sub)

	local rows, acts = sidebar_rows()
	local picked_row = UI_Sidebar("filters", rows, { width = 330 })
	if picked_row and acts[picked_row] then
		acts[picked_row]()
		if state == "library" then refilter() end
	end
	if state ~= "library" then return end -- signed out from the sidebar

	local text, changed = UI_SearchBar("search", query, "Search your games")
	if changed then
		query = text
		refilter()
	end

	if #shown == 0 then
		UI_Text("No games match these filters.", "muted")
	end
	local picked, focused = UI_Grid("games", #shown, { cols = 4, aspect = 0.5625, cover = true }, function(i)
		local g = games[shown[i]]
		local badge = nil
		if galaxy.installed[g.id] then
			badge = "Installed"
		elseif galaxy.jobs[g.id] and galaxy.jobs[g.id].phase ~= "failed" then
			badge = "Installing"
		elseif g.is_new then
			badge = "New"
		elseif g.updates > 0 then
			badge = "Update"
		end
		return { title = g.title, sub = game_sub(g), image = cover_for(g), badge = badge, progress = covers[g.id] == "pending" and 0 or nil }
	end)
	focused_game = focused and games[shown[focused]] or nil
	if picked then
		detail = games[shown[picked]]
		load_product(detail)
	end
	UI_Hints({ { "A", "Info" }, { "Left / Right", "Filters" }, { "B", "Close" } })
end

return {
	on_start = function()
		for _, f in ipairs(List_Dir(COVERS)) do
			local id = f:match("^(%d+)%.jpg$")
			if id then covers[id] = "have" end
		end
		galaxy.scan_installed()
		galaxy.recover()
		if not Online() then
			state = "offline"
		else
			refresh = read_file(TOKEN_FILE)
			if refresh and refresh ~= "" then
				refresh_login()
			else
				state = "login"
			end
		end
		-- closing the page (B on the library) closes the channel
		UI_Open(view, function() Channel_Close() end)
	end,

	frame = function(_, w, h)
		-- the background is bkg.glsl (info.toml background = true), drawn by Saber before frame()
		Draw_Text("GOG", 44, 20, 46, "#e2ccff")
		Draw_Text("Good Old Games", 44 + Text_Width("GOG", 46) + 16, 36, 22, "#b9a2e0")
	end,
}
