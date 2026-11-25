-- Saber Styler: download UI shader themes, wallpapers and menu music for Saber, preview and apply them.
--
-- Sources: sources.txt in this folder (same format as the Channel Shop: "owner/repo", "owner/repo@branch"
-- or a GitHub URL). The catalog is each repo's Channels/SaberStyler/styles/ folder (one GitHub tree call per
-- source, the last answer is cached in SAVE_DIR so the catalog also shows offline). info.toml's
-- shop_exclude = "styles" keeps the Channel Shop from installing it along with the channel.
--   styles/themes/<Name>/...     a UI shader theme folder -> THEMES_DIR/<Name>/ (info.toml for name /
--                                description / author / version; thumbnail.glsl|frag|fs or preview.png|jpg as art)
--   styles/wallpapers/<file>     a picture or Shadertoy-style .glsl -> WALLPAPER_DIR (<stem>.toml optional)
--   styles/music/<file>          mp3 / ogg / wav / flac -> MUSIC_DIR (<stem>.toml, <stem>.png|jpg cover optional)
--
-- Installed items are remembered in SAVE_DIR/installed.txt with the git blob shas they came from, so a
-- changed file upstream shows as an update. Things already on this PC that the Styler didn't install
-- (Saber's shipped themes, your own wallpapers) can be applied but are never overwritten or removed.
--
-- Applying goes through Style_Set (saved to Saber.ini). The channel draws Saber's own wallpaper behind its
-- pages and uses the active UI shaders / colours, so what you apply shows up right away.
-- Adding a kind later = one more entry in KINDS.

local DEFAULT_SOURCES = { "StudioSyndiCatCaius/SaberLauncherPlugins@main" }
local ROOT = "Channels/SaberStyler/styles/"
local STAGE = SAVE_DIR .. "/stage"
local ART = SAVE_DIR .. "/art"
local PREVIEW = SAVE_DIR .. "/preview"
local CACHE = SAVE_DIR .. "/cache"
local REGISTRY = SAVE_DIR .. "/installed.txt"
local WORKERS = 4

local function set_of(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end

local IMAGE_EXTS = set_of({ "png", "jpg", "jpeg", "webp", "bmp", "gif" })
local SHADER_EXTS = set_of({ "glsl", "frag", "fs" })
local MUSIC_EXTS = set_of({ "mp3", "ogg", "wav", "flac" })
local WALL_EXTS = set_of({ "png", "jpg", "jpeg", "webp", "bmp", "gif", "glsl", "frag", "fs" })

-- folder = true: every item is a folder (styles/<dir>/<Name>/**); else single files (styles/<dir>/<file>).
-- local_only = true: nothing to download, the list comes from Style_List (built into Saber).
local KINDS = {
	{ id = "themes", tab = "THEMES", dir = "themes", style = "ui_shaders", folder = true,
		dest = THEMES_DIR, noun = "UI theme", cols = 3, aspect = 0.5625 },
	{ id = "wallpapers", tab = "WALLPAPERS", dir = "wallpapers", style = "wallpaper", exts = WALL_EXTS,
		dest = WALLPAPER_DIR, noun = "wallpaper", cols = 4, aspect = 0.5625 },
	{ id = "music", tab = "MUSIC", dir = "music", style = "music", exts = MUSIC_EXTS,
		dest = MUSIC_DIR, noun = "menu music", cols = 4, aspect = 1.0 },
	{ id = "colours", tab = "COLOURS", style = "ui_theme", local_only = true, noun = "colour theme", cols = 4, aspect = 0.4 },
}

local catalog = {}  -- kind id -> list of items
local by_key = {}   -- "kind/id" -> item (first source wins)
local registry = {} -- "kind/id" -> { sig, source }
local state = "idle" -- idle | loading | ready
local message = nil
local pending = 0
local tab = 1
local detail = nil
local jobs = {}     -- item key -> { done, total, failed }
local notice = nil  -- { text, until }
local previewing = nil -- music item key being previewed
local removals = {}    -- files that couldn't be deleted yet (the music stream still holds them): { path, tries }

-- ---------------------------------------------------------------------------
-- helpers

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

local function write_file(path, data)
	local f = io.open(path, "wb")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local function parse_info(text)
	local t = {}
	for line in (text or ""):gmatch("[^\r\n]+") do
		local k, v = line:match('^%s*([%w_]+)%s*=%s*"(.-)"%s*$')
		if not k then k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$") end
		if k then t[k] = v end
	end
	return t
end

local function ext_of(name) return (name:match("%.([%w]+)$") or ""):lower() end
local function stem_of(name) return name:match("^(.*)%.[%w]+$") or name end
local function dir_of(path) return (path:gsub("[/\\][^/\\]*$", "")) end

local function url_encode(s)
	return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function raw_url(src, path)
	return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", src.owner, src.repo, src.branch, url_encode(path))
end

local function safe_name(s) return (s:gsub("[^%w%-_%.]", "_")) end

local function human_size(n)
	if not n or n <= 0 then return nil end
	if n >= 1024 * 1024 then return string.format("%.1f MB", n / 1048576) end
	return string.format("%d KB", math.max(1, math.floor(n / 1024 + 0.5)))
end

local function say(text)
	notice = { text = text, ["until"] = Time() + 4 }
end

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
	local text = read_file(CHANNEL_DIR .. "/sources.txt")
	if text then
		for line in text:gmatch("[^\r\n]+") do
			local s = parse_source(line)
			if s then list[#list + 1] = s end
		end
	end
	if #list == 0 then
		for _, l in ipairs(DEFAULT_SOURCES) do list[#list + 1] = parse_source(l) end
	end
	return list
end

-- os.rename, falling back to a copy (stage and destination can be on different drives in dev setups)
local function move_file(from, to)
	Make_Dir(dir_of(to))
	os.remove(to)
	if os.rename(from, to) then return true end
	local data = read_file(from)
	if not data or not write_file(to, data) then return false, "can't write " .. to end
	os.remove(from)
	return true
end

-- ---------------------------------------------------------------------------
-- registry (what the Styler installed)

local function load_registry()
	registry = {}
	for line in (read_file(REGISTRY) or ""):gmatch("[^\r\n]+") do
		local key, sig, src = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
		if key then registry[key] = { sig = sig, source = src } end
	end
end

local function save_registry()
	local keys = {}
	for k in pairs(registry) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do out[#out + 1] = k .. "\t" .. registry[k].sig .. "\t" .. (registry[k].source or "") end
	write_file(REGISTRY, table.concat(out, "\n") .. "\n")
end

-- ---------------------------------------------------------------------------
-- status

local function local_path(item)
	return item.kind.dest .. "/" .. item.id
end

local function on_disk(item)
	if item.here then return true end
	return Exists(local_path(item))
end

local function style_now(kind)
	local s = Style_Get()
	return s[kind.style] or ""
end

local function is_active(item)
	return style_now(item.kind):lower() == item.id:lower()
end

-- "available" | "installed" | "update" | "local" (on this PC, not from the Styler) | "busy"
local function status(item)
	if jobs[item.key] then return "busy" end
	if item.here then return "local" end
	if not on_disk(item) then return "available" end
	local r = registry[item.key]
	if not r then return "local" end
	if item.sig and item.sig ~= "" and r.sig ~= item.sig then return "update" end
	return "installed"
end

local function badge(item)
	local st = status(item)
	if st == "busy" then return nil end
	if st == "update" then return "Update" end
	if st ~= "available" and is_active(item) then return "Active" end
	if st == "installed" then return "Installed" end
	if st == "local" and not item.kind.local_only then return "On this PC" end
	return nil
end

-- ---------------------------------------------------------------------------
-- art

-- A local path or URL for the item's picture: installed file > cached download > URL.
local function art_for(item)
	if item.art_local and Exists(item.art_local) then return item.art_local end
	local a = item.art
	if not a then return nil end
	if a.url then return a.url end -- pictures: Saber fetches URL images itself (memory only)
	-- shaders have to be on disk to be compiled: cache them by blob sha
	local path = ART .. "/" .. safe_name(a.sha or item.key) .. "." .. a.ext
	if a.state == "have" then return path end
	if a.state == nil then
		if Exists(path) then a.state = "have" return path end
		if Online() then
			a.state = "pending"
			Http_Download(a.fetch, path, function(ok) a.state = ok and "have" or "none" end)
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- catalog

local loading_done -- below: one catalog request finished

local function add_item(item)
	if by_key[item.key] then return end -- an earlier source has it
	by_key[item.key] = item
	local list = catalog[item.kind.id]
	list[#list + 1] = item
end

local function sort_catalog()
	for _, k in ipairs(KINDS) do
		table.sort(catalog[k.id], function(a, b) return a.name:lower() < b.name:lower() end)
	end
end

local function use_meta(item, text)
	local info = parse_info(text)
	item.name = info.name or item.name
	item.description = info.description or item.description
	item.author = info.author or item.author
	item.version = info.version or item.version
end

-- info.toml / <stem>.toml, cached by blob sha (a changed file has a new sha)
local function fetch_meta(item)
	if not item.meta then return end
	local cache = CACHE .. "/meta/" .. safe_name(item.meta.sha) .. ".toml"
	local text = read_file(cache)
	if text then return use_meta(item, text) end
	if not Online() then return end
	pending = pending + 1
	Http_Get(raw_url(item.source, item.meta.path), function(ok, body)
		if ok then
			use_meta(item, body)
			write_file(cache, body)
		end
		loading_done()
	end)
end

-- What's on this PC but not in any catalog (Saber's built-in / shipped themes, your own wallpapers and
-- music, the colour palettes): listed too, so everything can be applied from here. Never removed.
local function add_local_items()
	for _, k in ipairs(KINDS) do
		for _, name in ipairs(Style_List(k.style) or {}) do
			if not by_key[k.id .. "/" .. name] then
				local item = { kind = k, key = k.id .. "/" .. name, id = name, here = true,
					name = k.exts and stem_of(name) or name, description = "", author = "", version = "" }
				if k.id == "wallpapers" then
					item.art_local = k.dest .. "/" .. name
				elseif k.folder then
					for _, fname in ipairs(List_Dir(k.dest .. "/" .. name) or {}) do
						if stem_of(fname:lower()) == "thumbnail" and SHADER_EXTS[ext_of(fname)] then
							item.art_local = k.dest .. "/" .. name .. "/" .. fname
						end
					end
					local info = parse_info(read_file(k.dest .. "/" .. name .. "/info.toml"))
					item.name = info.name or name
					item.description = info.description or (name == "default" and "Saber's built-in liquid glass look." or "")
					item.author = info.author or ""
				end
				add_item(item)
			end
		end
	end
end

function loading_done()
	pending = pending - 1
	if pending > 0 then return end
	add_local_items()
	sort_catalog()
	state = "ready"
end

-- Builds the items of one source from its tree entries.
local function read_tree(src, tree)
	local groups = {} -- kind id -> { name -> { files = {{rel, sha, size}} } }
	for _, e in ipairs(tree) do
		if e.type == "blob" and type(e.path) == "string" and e.path:sub(1, #ROOT) == ROOT then
			local dir, rest = e.path:sub(#ROOT + 1):match("^([^/]+)/(.+)$")
			for _, k in ipairs(KINDS) do
				if dir and k.dir and k.dir:lower() == dir:lower() then
					groups[k.id] = groups[k.id] or {}
					local g = groups[k.id]
					local f = { rel = rest, sha = e.sha or "", size = tonumber(e.size) or 0, path = e.path }
					if k.folder then
						local name, rel = rest:match("^([^/]+)/(.+)$")
						if name then
							f.rel = rel
							g[name] = g[name] or { files = {} }
							table.insert(g[name].files, f)
						end
					elseif not rest:find("/") then
						g[rest] = { files = { f } }
					end
				end
			end
		end
	end

	for _, k in ipairs(KINDS) do
		local g = groups[k.id] or {}
		if k.folder then
			for name, grp in pairs(g) do
				local item = { kind = k, key = k.id .. "/" .. name, id = name, name = name, source = src,
					files = grp.files, description = "", author = "", version = "", size = 0 }
				local shas, thumb, pic = {}, nil, nil
				for _, f in ipairs(grp.files) do
					shas[#shas + 1] = f.rel .. "=" .. f.sha
					item.size = item.size + f.size
					local lower, ext = f.rel:lower(), ext_of(f.rel)
					if lower == "info.toml" then item.meta = f end
					if stem_of(lower) == "thumbnail" and SHADER_EXTS[ext] then thumb = f end
					if (stem_of(lower) == "preview" or stem_of(lower) == "thumbnail") and IMAGE_EXTS[ext] then pic = f end
				end
				table.sort(shas)
				item.sig = table.concat(shas, ";")
				if pic then
					item.art = { url = raw_url(src, pic.path) }
					item.art_local = local_path(item) .. "/" .. pic.rel
				elseif thumb then
					item.art = { fetch = raw_url(src, thumb.path), sha = thumb.sha, ext = ext_of(thumb.rel) }
					item.art_local = local_path(item) .. "/" .. thumb.rel
				end
				add_item(item)
				fetch_meta(item)
			end
		else
			-- sidecars: <stem>.toml (info), and for music <stem>.png|jpg (cover)
			for name, grp in pairs(g) do
				local f = grp.files[1]
				local ext = ext_of(name)
				if k.exts[ext] and not (k.id == "music" and IMAGE_EXTS[ext]) then
					local stem = stem_of(name)
					local item = { kind = k, key = k.id .. "/" .. name, id = name, name = stem, source = src,
						files = { f }, sig = f.sha, size = f.size, description = "", author = "", version = "" }
					if g[stem .. ".toml"] then item.meta = g[stem .. ".toml"].files[1] end
					if k.id == "wallpapers" then
						if SHADER_EXTS[ext] then
							item.art = { fetch = raw_url(src, f.path), sha = f.sha, ext = ext }
						else
							item.art = { url = raw_url(src, f.path) }
						end
						item.art_local = local_path(item)
					else
						for _, ce in ipairs({ "png", "jpg", "jpeg", "webp" }) do
							local cover = g[stem .. "." .. ce]
							if cover then item.art = { url = raw_url(src, cover.files[1].path) } break end
						end
					end
					add_item(item)
					fetch_meta(item)
				end
			end
		end
	end
end

local function fetch_source(src)
	pending = pending + 1
	local cache = CACHE .. "/" .. safe_name(src.id .. "@" .. src.branch) .. ".json"
	local url = string.format("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1", src.owner, src.repo, src.branch)
	local function use(body, from_cache)
		local data = body and Json_Decode(body) or nil
		if type(data) ~= "table" or type(data.tree) ~= "table" then return false end
		if not from_cache then write_file(cache, body) end
		read_tree(src, data.tree)
		return true
	end
	local done = loading_done
	if not Online() then
		if not use(read_file(cache), true) then message = "Turn on Online Mode (Settings) to browse styles." end
		return done()
	end
	Http_Get(url, function(ok, body, code)
		if not (ok and use(body, false)) then
			if use(read_file(cache), true) then
				message = "Couldn't refresh " .. src.id .. " (" .. tostring(code or "no answer") .. "), showing the last catalog."
			else
				message = "Couldn't read " .. src.id .. " (" .. tostring(code or "no answer") .. ")."
			end
		end
		done()
	end)
end

local function refresh()
	if state == "loading" then return end
	catalog, by_key, message, detail = {}, {}, nil, nil
	for _, k in ipairs(KINDS) do catalog[k.id] = {} end
	state = "loading"
	pending = pending + 1 -- held until every source has been started
	for _, src in ipairs(load_sources()) do fetch_source(src) end
	loading_done()
end

-- ---------------------------------------------------------------------------
-- apply / install / remove

local function apply(item)
	local ok, err = Style_Set(item.kind.style, item.id)
	if ok then
		Play_Sfx("start")
		say(item.name .. " is now your " .. item.kind.noun .. ".")
		-- the menu music waits while a channel runs: play the new track here so it can be heard
		if item.kind.id == "music" and Play_Music(local_path(item)) then previewing = item.key end
	else
		say("Couldn't apply " .. item.name .. ": " .. tostring(err))
	end
end

local function finish_install(item, job, apply_after)
	local k = item.kind
	local stage = STAGE .. "/" .. safe_name(item.key)
	jobs[item.key] = nil
	if job.failed > 0 then
		Remove_Dir(stage)
		Dialog_Info("Couldn't download " .. item.name .. " (" .. job.failed .. " file(s) failed).", { "OK" })
		return
	end
	if k.folder then
		-- a Styler theme is replaced whole, so files dropped upstream don't linger
		if registry[item.key] then Remove_Dir(local_path(item)) end
		for _, f in ipairs(item.files) do
			local ok, err = move_file(stage .. "/" .. f.rel, local_path(item) .. "/" .. f.rel)
			if not ok then
				Remove_Dir(stage)
				Dialog_Info("Couldn't install " .. item.name .. ":\n" .. tostring(err), { "OK" })
				return
			end
		end
	else
		local dest = local_path(item)
		if Exists(dest) and not os.remove(dest) then
			Remove_Dir(stage)
			Dialog_Info(item.name .. " is in use (playing?). Switch to another " .. k.noun .. " and try again.", { "OK" })
			return
		end
		local ok, err = move_file(stage .. "/" .. item.files[1].rel, dest)
		if not ok then
			Remove_Dir(stage)
			Dialog_Info("Couldn't install " .. item.name .. ":\n" .. tostring(err), { "OK" })
			return
		end
	end
	Remove_Dir(stage)
	registry[item.key] = { sig = item.sig or "", source = item.source.id .. "@" .. item.source.branch }
	save_registry()
	saber.log("Saber Styler: installed " .. item.key)
	-- re-read the folders; an updated active item reloads, a new one is applied if asked
	if apply_after or is_active(item) then apply(item) else Style_Set(k.style) end
	if not apply_after then say(item.name .. " installed.") end
end

local function install(item, apply_after)
	if jobs[item.key] or item.kind.local_only then return end
	if not Online() then
		Dialog_Info("Turn on Online Mode (Settings) to download styles.", { "OK" })
		return
	end
	if status(item) == "local" then return end -- never overwrite what the Styler didn't put there
	local stage = STAGE .. "/" .. safe_name(item.key)
	Remove_Dir(stage)
	Make_Dir(stage)
	local job = { done = 0, total = #item.files, failed = 0, next = 1, inflight = 0 }
	jobs[item.key] = job
	local function pump()
		while job.inflight < WORKERS and job.next <= job.total do
			local f = item.files[job.next]
			job.next = job.next + 1
			job.inflight = job.inflight + 1
			local to = stage .. "/" .. f.rel
			Make_Dir(dir_of(to))
			Http_Download(raw_url(item.source, f.path), to, function(ok)
				job.inflight = job.inflight - 1
				job.done = job.done + 1
				if not ok then job.failed = job.failed + 1 end
				if job.done == job.total then finish_install(item, job, apply_after) else pump() end
			end)
		end
	end
	if job.total == 0 then finish_install(item, job, apply_after) else pump() end
end

local function stop_preview()
	if previewing then
		previewing = nil
		Play_Music()
	end
end

local function remove(item)
	Dialog_Info("Remove " .. item.name .. "?", { "Remove", "Cancel" }, function(i)
		if i ~= 1 then return end
		local k = item.kind
		if previewing == item.key then stop_preview() end
		if k.folder then
			local ok, err = Remove_Dir(local_path(item))
			if not ok then
				Dialog_Info("Couldn't remove " .. item.name .. ":\n" .. tostring(err), { "OK" })
				return
			end
		else
			local path = local_path(item)
			if is_active(item) and k.style == "music" then
				-- the menu music streams from its file: switch away first, delete once it lets go
				local other
				for _, n in ipairs(Style_List("music") or {}) do
					if n:lower() ~= item.id:lower() then other = n break end
				end
				if not other then
					Dialog_Info("This is your only menu music. Install or pick another track first.", { "OK" })
					return
				end
				Style_Set("music", other)
				removals[#removals + 1] = { path = path, tries = 0, kind = k }
			elseif not os.remove(path) and Exists(path) then
				Dialog_Info("Couldn't remove " .. item.name .. " (in use?).", { "OK" })
				return
			end
		end
		registry[item.key] = nil
		save_registry()
		Style_Set(k.style) -- re-read; falls back if it was the active one
		say(item.name .. " removed.")
	end)
end

-- Retries deletes that waited for the music stream to switch (Style_Set applies after the frame).
local function pump_removals()
	for i = #removals, 1, -1 do
		local r = removals[i]
		r.tries = r.tries + 1
		if os.remove(r.path) or not Exists(r.path) then
			table.remove(removals, i)
			Style_Set(r.kind.style)
		elseif r.tries > 180 then
			table.remove(removals, i)
			saber.log("Saber Styler: couldn't delete " .. r.path)
		end
	end
end

local function preview_music(item)
	if previewing == item.key then return stop_preview() end
	local path = on_disk(item) and local_path(item) or (PREVIEW .. "/" .. safe_name(item.sig or item.id) .. "." .. ext_of(item.id))
	if Exists(path) then
		local ok, err = Play_Music(path)
		if ok then previewing = item.key else say("Can't play " .. item.name .. ": " .. tostring(err)) end
		return
	end
	if not Online() then
		Dialog_Info("Turn on Online Mode (Settings) to preview music.", { "OK" })
		return
	end
	if item.preview_loading then return end
	item.preview_loading = true
	Http_Download(raw_url(item.source, item.files[1].path), path, function(ok)
		item.preview_loading = false
		if ok and (detail == item) then
			local played = Play_Music(path)
			if played then previewing = item.key end
		elseif not ok then
			say("Couldn't download the preview.")
		end
	end)
end

-- ---------------------------------------------------------------------------
-- pages

local function job_frac(item)
	local j = jobs[item.key]
	return j and (j.total > 0 and j.done / j.total or 0) or nil
end

local function draw_notice()
	if notice and Time() < notice["until"] then UI_Text(notice.text, "accent") end
end

local function detail_page()
	local item = detail
	local k = item.kind
	local bits = {}
	if item.author ~= "" then bits[#bits + 1] = "by " .. item.author end
	if item.version ~= "" then bits[#bits + 1] = "v" .. item.version end
	if human_size(item.size) then bits[#bits + 1] = human_size(item.size) end
	if not k.local_only and item.source then bits[#bits + 1] = item.source.id end
	UI_Title(item.name, table.concat(bits, "  ·  "))

	local img = art_for(item)
	if img then UI_Image(img, { height = 300, cover = false }) end
	draw_notice()

	local st = status(item)
	local active = st ~= "available" and is_active(item)
	if st == "busy" then
		local j = jobs[item.key]
		UI_Progress(job_frac(item), "Downloading " .. j.done .. " / " .. j.total .. " files...")
	else
		if active then
			UI_Text("This is your current " .. k.noun .. ".", "accent")
		elseif st == "available" then
			if UI_Button("get_apply", "Download and apply") then install(item, true) end
		else
			if UI_Button("apply", "Apply") then apply(item) end
		end
		if st == "available" then
			if UI_Button("get", "Download") then install(item, false) end
		elseif st == "update" then
			if UI_Button("get", "Update") then install(item, false) end
		elseif st == "installed" then
			if UI_Button("get", "Reinstall") then install(item, false) end
		end
		if k.id == "music" and (st ~= "local" or Exists(local_path(item))) then
			local label = previewing == item.key and "Stop preview" or (item.preview_loading and "Loading preview..." or "Preview")
			if UI_Button("preview", label) then preview_music(item) end
		end
		if st == "installed" or st == "update" then
			if UI_Button("remove", "Remove") then remove(item) end
		end
	end

	if item.description ~= "" then UI_Text(item.description, "text") end
	if st == "local" and not k.local_only and item.id ~= "default" then
		UI_Text("Already on this PC (shipped with Saber or added by you): it can be applied here, but the Styler won't overwrite or remove it.", "muted")
	end
	if k.id == "themes" then
		UI_Text("UI themes change how panels, cards, buttons and the focus ring are drawn. Colours stay in the COLOURS tab.", "muted")
	end
	UI_Hints({ { "A", "Select" }, { "B", "Back" } })
	if UI_Back() then
		if previewing then stop_preview() end
		detail = nil
	end
end

local function list_page()
	local k = KINDS[tab]
	local list = catalog[k.id] or {}

	local sub = #list .. (k.local_only and " built in" or " styles")
	if state == "loading" then sub = sub .. "  ·  loading..." end
	local cur = style_now(k)
	if cur ~= "" then sub = sub .. "  ·  current: " .. (k.local_only and cur or stem_of(cur)) end
	UI_Title("Saber Styler", sub)
	if message and not k.local_only then UI_Text(message, "warn") end
	draw_notice()

	if #list == 0 then
		if state == "loading" then
			UI_Progress(-1, "Loading the catalog...")
		else
			UI_Text("Nothing here yet.", "muted")
		end
	end

	local picked = UI_Grid(k.id, #list, { cols = k.cols, aspect = k.aspect, cover = true }, function(i)
		local item = list[i]
		local t = { title = item.name, image = art_for(item), badge = badge(item) }
		if k.id == "music" and previewing == item.key then t.sub = "Previewing" end
		if item.author ~= "" and not t.sub then t.sub = item.author end
		if jobs[item.key] then t.progress = job_frac(item) end
		return t
	end)
	if picked then
		local item = list[picked]
		if k.local_only then apply(item) else detail = item end
	end
	if not k.local_only then
		if UI_Button("refresh", state == "loading" and "Refreshing..." or "Refresh") then refresh() end
	end
	UI_Hints({ { "A", k.local_only and "Apply" or "Info" }, { "LB / RB", "Category" }, { "B", "Close" } })
end

local function view()
	local labels = {}
	for i, k in ipairs(KINDS) do labels[i] = k.tab end
	local sel, ch = UI_Tabs("tabs", labels, tab)
	if ch then
		tab = sel
		if detail then
			if previewing then stop_preview() end
			detail = nil
		end
	end
	if detail then return detail_page() end
	return list_page()
end

-- ---------------------------------------------------------------------------

return {
	on_start = function()
		for _, d in ipairs({ ART, PREVIEW, CACHE .. "/meta", WALLPAPER_DIR, MUSIC_DIR, THEMES_DIR }) do Make_Dir(d) end
		Remove_Dir(STAGE)
		load_registry()
		refresh()
		UI_Open(view, function() Channel_Close() end)
	end,

	frame = function(_, w, h)
		-- Saber's own wallpaper behind the pages, so an applied one shows at once
		Draw_Wallpaper()
		if #removals > 0 then pump_removals() end
	end,

	on_close = function()
		Remove_Dir(STAGE)
	end,
}
