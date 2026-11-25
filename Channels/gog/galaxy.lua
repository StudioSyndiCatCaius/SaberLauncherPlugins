-- galaxy.lua: installs GOG games the way Galaxy does (content system v2), on Saber's generic
-- Batch_Download engine. No installer exe: the game's files come chunk by chunk from GOG's CDN,
-- md5-checked, into APP/games/<Title>.part/, which becomes APP/games/<Title>/ with a generated
-- _Saber folder (the exe / args / working dir of GOG's primary play task) so it shows in GAMES.
--
--   builds    content-system.gog.com/products/<id>/os/windows/builds?generation=2  -> newest public build
--   manifest  build.link (zlib JSON): depots per language, offlineDepot, products
--   depots    gog-cdn-fastly.gog.com/content-system/v2/meta/ab/cd/<hash> (zlib JSON): files -> chunks
--   links     content-system.gog.com/products/<id>/secure_link?generation=2&path=/&_version=2
--   chunks    <secure link>/ab/cd/<compressedMd5> (zlib, md5 of the unpacked data)
--
-- Small files may live in a depot's smallFilesContainer (sfcRef = offset + size): the container is
-- downloaded like a file, then sliced. The plan for finishing (slices, empty files, exe hint) is
-- saved in the .part folder (.saber_plan), so an install stopped or left running while the channel
-- was closed finishes the next time the channel looks at it.

local M = {}

local GAMES = SABER_DIR .. "/games"
local PLAN = ".saber_plan"
local JOURNAL = ".saber_chunks"

M.get = nil -- function(url, cb(ok, body, status), auth) set by the channel
M.jobs = {} -- id -> { phase = preparing | downloading | finishing | failed, error, title, part, folder }
M.installed = {} -- id -> folder

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

local function safe_name(s)
	-- ASCII only: Lua's io.open is fopen (ANSI codepage) on Windows, so a folder named with ™ / ® / é
	-- is created by Make_Dir but can't be written into ("Can't write to the GAMES folder")
	s = (s or ""):gsub("\226\128[\152\153]", "'"):gsub("\195[\128-\133]", "A"):gsub("\195[\160-\165]", "a")
		:gsub("\195[\136-\139]", "E"):gsub("\195[\168-\171]", "e"):gsub("[\128-\255]", "")
	s = s:gsub('[<>:"/\\|%?%*%c]', ""):gsub("%s+", " ")
	s = s:gsub("^%s+", ""):gsub("[%s%.]+$", "")
	return s ~= "" and s or "GOG Game"
end

function M.folder(title) return GAMES .. "/" .. safe_name(title) end
function M.part(title) return M.folder(title) .. ".part" end
local function batch_id(id) return "gog-" .. id end

-- manifests come zlib-compressed (sometimes plain)
local function decode(body)
	if not body then return nil, "empty reply" end
	local first = body:sub(1, 1)
	if first ~= "{" and first ~= "[" then
		local plain, err = Inflate(body)
		if not plain then return nil, err end
		body = plain
	end
	return Json_Decode(body)
end

local function fail(id, msg)
	local job = M.jobs[id]
	if job then
		job.phase = "failed"
		job.error = msg
	end
	saber.log("GOG install " .. id .. ": " .. tostring(msg))
end

-- windows-safe relative path, "/" separated; nil for anything escaping the folder
local function safe_rel(p)
	p = (p or ""):gsub("\\", "/"):gsub("^/+", "")
	if p == "" or p:find(":", 1, true) then return nil end
	for part in p:gmatch("[^/]+") do
		if part == ".." then return nil end
	end
	return p
end

local function lang_ok(langs, want)
	for _, l in ipairs(langs or {}) do
		if l == "*" or l:lower() == want:lower() or l:lower():sub(1, #want + 1) == want:lower() .. "-" then return true end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- installed games: GAMES folders whose saber.ini has gog_id=

function M.scan_installed()
	M.installed = {}
	for _, d in ipairs(List_Dirs(GAMES)) do
		if not d:match("%.part$") then
			local s = read_file(GAMES .. "/" .. d .. "/_Saber/saber.ini")
			local id = s and s:match('gog_id%s*=%s*"?(%d+)')
			if id then M.installed[id] = GAMES .. "/" .. d end
		end
	end
end

-- ---------------------------------------------------------------------------
-- install

-- opts: { title, language = "en", cover = <fallback box image path> }
function M.install(id, opts)
	if M.jobs[id] and M.jobs[id].phase ~= "failed" then return end
	local title = opts.title
	local job = { phase = "preparing", title = title, part = M.part(title), folder = M.folder(title), cover = opts.cover }
	M.jobs[id] = job
	if Exists(job.folder) then return fail(id, safe_name(title) .. " already exists in GAMES") end
	local lang = opts.language or "en"

	M.get("https://content-system.gog.com/products/" .. id .. "/os/windows/builds?generation=2", function(ok, body)
		local builds = ok and decode(body)
		if not builds then return fail(id, "Couldn't get the game's builds: " .. tostring(ok and "bad reply" or body)) end
		local build = nil
		for _, b in ipairs(builds.items or {}) do
			if b.generation == 2 and (b.branch == nil or b.branch == "") and b.public ~= false then
				build = b
				break
			end
		end
		if not build then return fail(id, "This game only has an older (generation 1) build, which isn't supported yet") end

		M.get(build.link, function(ok2, body2)
			local manifest = ok2 and decode(body2)
			if not manifest then return fail(id, "Couldn't read the build manifest") end
			local base = tostring(manifest.baseProductId or id)

			-- the base game's depots in the language (else English), plus language-neutral ones
			local depots = {}
			for pass = 1, 2 do
				local want = pass == 1 and lang or "en"
				depots = {}
				local has_lang = false
				for _, d in ipairs(manifest.depots or {}) do
					if tostring(d.productId) == base and lang_ok(d.languages, want) then
						depots[#depots + 1] = d
						for _, l in ipairs(d.languages or {}) do
							if l ~= "*" then has_lang = true end
						end
					end
				end
				if has_lang then break end
			end
			-- the offline depot (support files of GOG's offline installers): nice to have, never required
			if manifest.offlineDepot and tostring(manifest.offlineDepot.productId) == base then
				manifest.offlineDepot.saber_optional = true
				depots[#depots + 1] = manifest.offlineDepot
			end
			if #depots == 0 then return fail(id, "No Windows files in this build") end

			local exe_hint = nil
			for _, p in ipairs(manifest.products or {}) do
				if p.temp_executable and p.temp_executable ~= "" then exe_hint = p.temp_executable end
			end

			-- every depot manifest, then a secure link per product, then the batch
			local metas, pending = {}, #depots
			for k, d in ipairs(depots) do
				local h = d.manifest or ""
				M.get("https://gog-cdn-fastly.gog.com/content-system/v2/meta/" .. h:sub(1, 2) .. "/" .. h:sub(3, 4) .. "/" .. h, function(ok3, body3)
					metas[k] = ok3 and decode(body3) or false
					metas[k] = metas[k] and { data = metas[k], product = tostring(d.productId), manifest = h, optional = d.saber_optional } or false
					pending = pending - 1
					if pending > 0 then return end
					for i = 1, #depots do
						if not metas[i] then return fail(id, "Couldn't read a depot manifest") end
					end
					M._links(id, metas, function(links, mirrors)
						M._queue(id, job, build, lang, metas, links, exe_hint, mirrors)
					end)
				end)
			end
		end, false)
	end, true)
end

-- secure links per product: every server that serves generation 2 content, GOG's preferred first;
-- each url_format is split around {path} so chunk URLs are one concatenation. The first server is
-- the chunks' own; the others become Batch_Download mirrors (tried when a chunk 404s / fails).
local function split_link(u)
	if not (u.url_format and u.parameters) then return nil end
	local fmt = u.url_format
	for k, v in pairs(u.parameters) do
		if k ~= "path" then fmt = fmt:gsub("{" .. k .. "}", function() return tostring(v) end) end
	end
	local at = fmt:find("{path}", 1, true)
	if not at then return nil end
	return { before = fmt:sub(1, at - 1), path = u.parameters.path or "", after = fmt:sub(at + 6), name = u.endpoint_name }
end

function M._links(id, metas, done)
	local products, list = {}, {}
	for _, m in ipairs(metas) do
		if not products[m.product] then
			products[m.product] = true
			list[#list + 1] = m.product
		end
	end
	local links, mirrors, pending = {}, {}, #list
	for _, product in ipairs(list) do
		M.get("https://content-system.gog.com/products/" .. product .. "/secure_link?generation=2&path=/&_version=2", function(ok, body)
			local t = ok and decode(body)
			local servers = {}
			for _, cand in ipairs(t and t.urls or {}) do
				local gen2 = cand.supports_generation == nil
				for _, g in ipairs(cand.supports_generation or {}) do
					if g == 2 then gen2 = true end
				end
				local l = gen2 and split_link(cand)
				if l then
					l.priority = tonumber(cand.priority) or 0
					servers[#servers + 1] = l
				end
			end
			table.sort(servers, function(a, b) return a.priority > b.priority end)
			if servers[1] then
				links[product] = servers[1]
				local names = {}
				for i, s in ipairs(servers) do
					names[#names + 1] = tostring(s.name)
					if i > 1 then
						mirrors[#mirrors + 1] = {
							from_prefix = servers[1].before .. servers[1].path, from_suffix = servers[1].after,
							to_prefix = s.before .. s.path, to_suffix = s.after,
						}
					end
				end
				saber.log("GOG install " .. id .. ": product " .. product .. " via " .. table.concat(names, ", "))
			end
			pending = pending - 1
			if pending > 0 then return end
			for _, p in ipairs(list) do
				if not links[p] then return fail(id, "Couldn't get a download link from GOG") end
			end
			done(links, mirrors)
		end, true)
	end
end

function M._queue(id, job, build, lang, metas, links, exe_hint, mirrors)
	local part = job.part
	local tasks, plan, total = {}, {}, 0
	local function chunk_url(link, cmd5)
		return link.before .. link.path .. "/" .. cmd5:sub(1, 2) .. "/" .. cmd5:sub(3, 4) .. "/" .. cmd5 .. link.after
	end
	plan[#plan + 1] = "I|" .. id
	plan[#plan + 1] = "T|" .. job.title
	if exe_hint then plan[#plan + 1] = "X|" .. exe_hint end
	M.chunk_owner = {} -- compressedMd5 -> where it belongs, for the log when a chunk fails
	for n, m in ipairs(metas) do
		local depot = m.data.depot or {}
		local link = links[m.product]
		local container = nil
		if depot.smallFilesContainer then
			container = ".saber_sfc_" .. n
			local off = 0
			for _, ch in ipairs(depot.smallFilesContainer.chunks or {}) do
				tasks[#tasks + 1] = { url = chunk_url(link, ch.compressedMd5), path = part .. "/" .. container, offset = off, size = ch.size, md5 = ch.md5, zlib = true, optional = m.optional }
				M.chunk_owner[ch.compressedMd5] = "product " .. m.product .. ", depot " .. m.manifest .. ", small files container"
				off = off + ch.size
			end
			plan[#plan + 1] = "C|" .. container
		end
		for _, item in ipairs(depot.items or {}) do
			local rel = item.type == "DepotFile" and safe_rel(item.path)
			if rel then
				for _, fl in ipairs(item.flags or {}) do
					if fl == "support" then rel = "gog-support/" .. m.product .. "/" .. rel end
				end
				if item.sfcRef and container then
					plan[#plan + 1] = "S|" .. container .. "|" .. math.floor(item.sfcRef.offset) .. "|" .. math.floor(item.sfcRef.size) .. "|" .. rel
				elseif not item.chunks or #item.chunks == 0 then
					plan[#plan + 1] = "E|" .. rel
				else
					local off = 0
					for _, ch in ipairs(item.chunks) do
						tasks[#tasks + 1] = { url = chunk_url(link, ch.compressedMd5), path = part .. "/" .. rel, offset = off, size = ch.size, md5 = ch.md5, zlib = true, optional = m.optional }
						M.chunk_owner[ch.compressedMd5] = "product " .. m.product .. ", depot " .. m.manifest .. (m.optional and " (offline depot)" or "") .. ", " .. rel
						off = off + ch.size
					end
				end
			end
		end
	end
	for _, t in ipairs(tasks) do total = total + t.size end
	job.total = total
	Make_Dir(part)
	if not Exists(part .. "/_Saber/box.jpg") then M.fetch_art(id, part, job.cover) end
	if not write_file(part .. "/" .. PLAN, table.concat(plan, "\n") .. "\n") then return fail(id, "Can't write to the GAMES folder") end
	local ok, err = Batch_Download(batch_id(id), tasks, {
		title = job.title,
		journal = part .. "/" .. JOURNAL,
		resume_key = tostring(build.build_id) .. "|" .. lang .. "|" .. #tasks,
		workers = 6,
		mirrors = mirrors,
	})
	if not ok then return fail(id, err) end
	job.phase = "downloading"
end

-- ---------------------------------------------------------------------------
-- finish: slices, empty files, _Saber, rename

local function find_info(dir, id, depth)
	local p = dir .. "/goggame-" .. id .. ".info"
	if Exists(p) then return p, "" end
	if depth <= 0 then return nil end
	for _, d in ipairs(List_Dirs(dir)) do
		local found, sub = find_info(dir .. "/" .. d, id, depth - 1)
		if found then return found, d .. (sub ~= "" and ("/" .. sub) or "") end
	end
	return nil
end

local function win(p) return ((p or ""):gsub("/", "\\")) end

local function join(dir, p)
	p = win(p):gsub("^\\+", "")
	if dir == "" or dir == "." then return p end
	return win(dir) .. "\\" .. p
end

local function dirname(p)
	return p:match("^(.*)\\[^\\]*$") or ""
end

local function ini_quote(s) return '"' .. tostring(s or ""):gsub('"', "'") .. '"' end

function M.finish(id, part)
	local plan_text = read_file(part .. "/" .. PLAN)
	if not plan_text then return false, "The install plan is missing" end
	local title, exe_hint = id, nil
	local containers = {}
	local handles = {}
	for line in plan_text:gmatch("[^\r\n]+") do
		local kind, rest = line:match("^(%u)|(.*)$")
		if kind == "T" then
			title = rest
		elseif kind == "X" then
			exe_hint = rest
		elseif kind == "C" then
			containers[#containers + 1] = rest
		elseif kind == "E" then
			local target = part .. "/" .. rest
			Make_Dir(target:match("^(.*)/[^/]*$") or part)
			if not Exists(target) then write_file(target, "") end
		elseif kind == "S" then
			local c, off, size, rel = rest:match("^([^|]+)|(%d+)|(%d+)|(.*)$")
			local h = handles[c]
			if not h then
				h = io.open(part .. "/" .. c, "rb")
				if not h then return false, "A small-files container is missing" end
				handles[c] = h
			end
			h:seek("set", tonumber(off))
			local target = part .. "/" .. rel
			Make_Dir(target:match("^(.*)/[^/]*$") or part)
			if not write_file(target, h:read(tonumber(size)) or "") then return false, "Couldn't write " .. rel end
		end
	end
	for _, h in pairs(handles) do h:close() end
	for _, c in ipairs(containers) do os.remove(part .. "/" .. c) end

	-- the exe the GOG shortcut starts: goggame-<id>.info's primary FileTask
	local exe, args, workdir = nil, "", nil
	local info_path, info_dir = find_info(part, id, 3)
	local info = info_path and Json_Decode(read_file(info_path) or "")
	if info then
		local best = nil
		for _, t in ipairs(info.playTasks or {}) do
			if t.type == "FileTask" then
				best = best or t
				if t.isPrimary then
					best = t
					break
				end
			end
		end
		if best and best.path then
			exe = join(info_dir, best.path)
			args = best.arguments or ""
			workdir = (best.workingDir and best.workingDir ~= "") and join(info_dir, best.workingDir) or dirname(exe)
		end
	end
	if not exe and exe_hint then
		exe = win(exe_hint)
		workdir = dirname(exe)
	end
	if not exe then return false, "Couldn't find the game's exe (no goggame info)" end

	local saber = part .. "/_Saber"
	Make_Dir(saber)
	local ini = {
		"title=" .. ini_quote(title),
		"exe=" .. ini_quote(exe),
	}
	if args ~= "" then ini[#ini + 1] = "args=" .. ini_quote(args) end
	if workdir and workdir ~= "" then ini[#ini + 1] = "workdir=" .. ini_quote(workdir) end
	ini[#ini + 1] = 'tags="GOG"'
	if Exists(saber .. "/box.jpg") then ini[#ini + 1] = 'box="box.jpg"' end
	if Exists(saber .. "/logo.png") then ini[#ini + 1] = 'logo="logo.png"' end
	ini[#ini + 1] = "gog_id=" .. ini_quote(id)
	if not write_file(saber .. "/saber.ini", table.concat(ini, "\n") .. "\n") then return false, "Couldn't write _Saber/saber.ini" end

	os.remove(part .. "/" .. JOURNAL)
	os.remove(part .. "/" .. PLAN)
	local folder = part:gsub("%.part$", "")
	local ok, err = os.rename(part, folder)
	if not ok then return false, "Couldn't rename the folder: " .. tostring(err) end
	M.installed[id] = folder
	Rescan_Library()
	return true
end

-- box art + logo for _Saber, from GOG's games database (what Galaxy shows); falls back to the cover
function M.fetch_art(id, part, cover)
	local saber = part .. "/_Saber"
	Make_Dir(saber)
	Http_Get("https://gamesdb.gog.com/platforms/gog/external_releases/" .. id, function(ok, body)
		local t = ok and Json_Decode(body)
		local game = t and t.game
		local function url_of(img, ext)
			local f = img and img.url_format
			if not f then return nil end
			return (f:gsub("_?{formatter}", ""):gsub("{ext}", ext))
		end
		local box = game and url_of(game.vertical_cover, "jpg")
		local logo = game and url_of(game.logo, "png")
		if box then
			Http_Download(box, saber .. "/box.jpg", function() end)
		elseif cover and Exists(cover) then
			write_file(saber .. "/box.jpg", read_file(cover) or "")
		end
		if logo then Http_Download(logo, saber .. "/logo.png", function() end) end
	end)
end

-- ---------------------------------------------------------------------------
-- per-frame: move downloads to finishing; pick up installs from earlier sessions

function M.poll()
	for id, job in pairs(M.jobs) do
		if job.phase == "downloading" then
			local st = Batch_Status(batch_id(id))
			if not st then
				job.phase = "failed"
				job.error = job.error or "Stopped. Press Resume to continue"
			elseif st.state == "done" then
				job.phase = "finishing"
				local ok, err = M.finish(id, job.part)
				if ok then
					M.jobs[id] = nil
					saber.log("GOG install " .. id .. ": done")
				else
					fail(id, err)
				end
			elseif st.state == "failed" then
				local md5 = st.url and st.url:match("/%x%x/%x%x/(%x+)")
				if md5 and M.chunk_owner and M.chunk_owner[md5] then saber.log("GOG install " .. id .. ": failed chunk " .. md5 .. " belongs to " .. M.chunk_owner[md5]) end
				fail(id, st.error or "Download failed")
			end
		end
	end
end

-- after the channel (re)opens: installs still running in Saber, or finished while it was closed
function M.recover()
	for _, d in ipairs(List_Dirs(GAMES)) do
		if d:match("%.part$") then
			local part = GAMES .. "/" .. d
			local plan = read_file(part .. "/" .. PLAN)
			local id = plan and plan:match("I|(%d+)")
			local title = plan and plan:match("T|([^\r\n]+)")
			if id and not M.jobs[id] then
				local st = Batch_Status(batch_id(id))
				if st and (st.state == "running" or st.state == "queued" or st.state == "done") then
					M.jobs[id] = { phase = "downloading", title = title or id, part = part, folder = part:gsub("%.part$", "") }
				end
			end
		end
	end
end

-- one state for the UI: nil | installed | preparing | downloading | finishing | failed | partial
function M.status(id, title)
	if M.installed[id] then return { state = "installed", folder = M.installed[id] } end
	local job = M.jobs[id]
	if job then
		if job.phase == "downloading" then
			local st = Batch_Status(batch_id(id)) or {}
			return { state = st.state == "queued" and "queued" or "downloading", got = st.got or 0, total = st.total or job.total or 0 }
		end
		return { state = job.phase, error = job.error }
	end
	if title and Exists(M.part(title) .. "/" .. PLAN) then return { state = "partial" } end
	return nil
end

function M.pause(id)
	Batch_Cancel(batch_id(id))
	local job = M.jobs[id]
	if job then
		job.phase = "failed"
		job.error = "Paused"
	end
end

return M
