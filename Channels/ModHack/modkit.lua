-- ModHack helpers: files, chunked copies, CRC32, IPS / BPS patching, ini edits.
--
-- Everything slow (copies, hashing, patching) calls K.step(), which yields when the current slice of
-- work has run long enough. ModHack runs installs inside a coroutine resumed once per frame, so a
-- big copy or patch never blocks Saber (or trips its 5 s Lua watchdog). Outside a coroutine
-- K.step() does nothing.

local K = {}

local CHUNK = 4 * 1024 * 1024 -- copy block
local SLICE = 0.025            -- seconds of work per frame

-- ---------------------------------------------------------------------------
-- time slicing

local slice_start = os.clock()

function K.step()
	if os.clock() - slice_start < SLICE then return end
	if coroutine.isyieldable() then coroutine.yield() end
	slice_start = os.clock()
end

function K.slice_begin() slice_start = os.clock() end

-- ---------------------------------------------------------------------------
-- paths and files

function K.dir_of(path) return (path:gsub("[/\\][^/\\]*$", "")) end
function K.base_of(path) return path:match("([^/\\]+)[/\\]*$") or path end
function K.ext_of(name) return (name:match("%.([%w]+)$") or ""):lower() end
function K.stem_of(name) return name:match("^(.*)%.[%w]+$") or name end

-- A name that's safe as a file / folder name on Windows.
function K.clean_name(s)
	s = (s or ""):gsub('[<>:"/\\|%?%*%c]', ""):gsub("^%s+", ""):gsub("[%s%.]+$", "")
	return s
end

function K.read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("a")
	f:close()
	return s
end

function K.write(path, data)
	Make_Dir(K.dir_of(path))
	local f = io.open(path, "wb")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

function K.size(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local n = f:seek("end")
	f:close()
	return n
end

-- A folder (io.open can't open one on Windows).
function K.is_dir(path)
	if not Exists(path) then return false end
	local f = io.open(path, "rb")
	if f then f:close() return false end
	return true
end

-- Every file below dir, as paths relative to it ("a/b.txt").
function K.walk(dir, out, prefix)
	out = out or {}
	prefix = prefix or ""
	for _, name in ipairs(List_Dir(dir) or {}) do out[#out + 1] = prefix .. name end
	for _, name in ipairs(List_Dirs(dir) or {}) do K.walk(dir .. "/" .. name, out, prefix .. name .. "/") end
	return out
end

-- Total bytes of a file or a folder tree.
function K.tree_size(path)
	if not K.is_dir(path) then return K.size(path) or 0 end
	local n = 0
	for _, rel in ipairs(K.walk(path)) do n = n + (K.size(path .. "/" .. rel) or 0) end
	return n
end

-- Copies one file in blocks. progress(bytes) is called after every block.
function K.copy_file(from, to, progress)
	local src = io.open(from, "rb")
	if not src then return nil, "can't read " .. from end
	Make_Dir(K.dir_of(to))
	local dst = io.open(to, "wb")
	if not dst then src:close() return nil, "can't write " .. to end
	while true do
		local block = src:read(CHUNK)
		if not block then break end
		if not dst:write(block) then
			src:close() dst:close()
			return nil, "can't write " .. to .. " (disk full?)"
		end
		if progress then progress(#block) end
		K.step()
	end
	src:close()
	dst:close()
	return true
end

-- Copies a file or a whole folder. opts: { skip = function(rel) -> true to leave out, progress(bytes) }
function K.copy(from, to, opts)
	opts = opts or {}
	if not K.is_dir(from) then return K.copy_file(from, to, opts.progress) end
	Make_Dir(to)
	for _, rel in ipairs(K.walk(from)) do
		if not (opts.skip and opts.skip(rel)) then
			local ok, err = K.copy_file(from .. "/" .. rel, to .. "/" .. rel, opts.progress)
			if not ok then return nil, err end
		end
	end
	return true
end

-- Deletes a file or a folder (folders only below Saber's APP folder: Remove_Dir's rule).
function K.remove(path)
	if K.is_dir(path) then return Remove_Dir(path) end
	if not Exists(path) then return true end
	local ok, err = os.remove(path)
	if not ok then return nil, err end
	return true
end

-- Replaces a file through a temp file next to it, so a failed write never leaves half a file.
function K.replace(path, data)
	local tmp = path .. ".modhack"
	if not K.write(tmp, data) then os.remove(tmp) return nil, "can't write " .. tmp end
	os.remove(path)
	if not os.rename(tmp, path) then return nil, "can't replace " .. path end
	return true
end

-- ---------------------------------------------------------------------------
-- ini files (key = value lines; repeated keys allowed)

function K.ini_parse(text)
	local t, list = {}, {}
	for line in (text or ""):gmatch("[^\r\n]+") do
		if not line:match("^%s*[;#%[]") then
			local k, v = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
			if k then
				k = k:lower()
				v = v:match('^"(.*)"$') or v
				list[#list + 1] = { k, v }
				if t[k] and k == "description" then t[k] = t[k] .. "\n" .. v else t[k] = v end
			end
		end
	end
	return t, list
end

-- Sets key = value in an ini file (adds the line when missing, keeps everything else).
function K.ini_set(path, key, value)
	local text = K.read(path) or ""
	local out, done = {}, false
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		local k = line:match("^%s*([%w_%.%-]+)%s*=")
		if k and k:lower() == key:lower() then
			if not done then out[#out + 1] = key .. "=" .. value end
			done = true
		else
			out[#out + 1] = line
		end
	end
	while #out > 0 and out[#out] == "" do out[#out] = nil end
	if not done then out[#out + 1] = key .. "=" .. value end
	return K.write(path, table.concat(out, "\r\n") .. "\r\n")
end

-- ---------------------------------------------------------------------------
-- CRC32

local CRC = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
	end
	CRC[i] = c
end

-- CRC32 of a string, as a number.
function K.crc32(s)
	local byte = string.byte
	local c = 0xFFFFFFFF
	local n = #s
	local i = 1
	while i <= n do
		local last = math.min(i + 65535, n)
		for j = i, last do c = CRC[(c ~ byte(s, j)) & 0xFF] ~ (c >> 8) end
		i = last + 1
		K.step()
	end
	return c ~ 0xFFFFFFFF
end

function K.crc_hex(n) return string.format("%08x", n) end

-- ---------------------------------------------------------------------------
-- patch buffers

local CH = 65536

-- An editable copy of a string, kept as 64 KB pieces so writes only rebuild what they touch.
local function chunks_new(s)
	local b = { parts = {}, n = #s }
	for i = 1, #s, CH do b.parts[#b.parts + 1] = s:sub(i, i + CH - 1) end
	return b
end

local function chunks_grow(b, n)
	local zero = "\0"
	while b.n < n do
		local last = b.parts[#b.parts]
		if last and #last < CH then
			local add = math.min(CH - #last, n - b.n)
			b.parts[#b.parts] = last .. zero:rep(add)
			b.n = b.n + add
		else
			local add = math.min(CH, n - b.n)
			b.parts[#b.parts + 1] = zero:rep(add)
			b.n = b.n + add
		end
	end
end

local function chunks_write(b, off, data)
	if off + #data > b.n then chunks_grow(b, off + #data) end
	local pos, i = off, 1
	while i <= #data do
		local ci = pos // CH
		local c = b.parts[ci + 1]
		local at = pos - ci * CH
		local take = math.min(#data - i + 1, #c - at)
		b.parts[ci + 1] = c:sub(1, at) .. data:sub(i, i + take - 1) .. c:sub(at + take + 1)
		pos, i = pos + take, i + take
	end
end

local function chunks_string(b, len)
	local s = table.concat(b.parts)
	if len and len < #s then s = s:sub(1, len) end
	return s
end

-- An append-only output that can read back what it already wrote (BPS TargetCopy).
local function out_new()
	return { done = {}, cur = {}, curlen = 0, total = 0 }
end

local function out_write(o, s)
	if #s == 0 then return end
	o.cur[#o.cur + 1] = s
	o.curlen = o.curlen + #s
	o.total = o.total + #s
	if o.curlen >= CH then
		local all = table.concat(o.cur)
		local i = 1
		while #all - i + 1 >= CH do
			o.done[#o.done + 1] = all:sub(i, i + CH - 1)
			i = i + CH
		end
		local rest = all:sub(i)
		o.cur = { rest }
		o.curlen = #rest
	end
end

local function out_read(o, pos, n)
	local pieces = {}
	while n > 0 do
		local ci = pos // CH
		local c
		if ci < #o.done then
			c = o.done[ci + 1]
		else
			if #o.cur > 1 then o.cur = { table.concat(o.cur) } end
			c = o.cur[1] or ""
		end
		local at = pos - ci * CH
		local take = math.min(n, #c - at)
		if take <= 0 then error("BPS: read past the end of the output") end
		pieces[#pieces + 1] = c:sub(at + 1, at + take)
		pos, n = pos + take, n - take
	end
	return table.concat(pieces)
end

local function out_string(o)
	return table.concat(o.done) .. table.concat(o.cur)
end

-- ---------------------------------------------------------------------------
-- IPS

local function u24(s, i) local a, b, c = s:byte(i, i + 2) return (a << 16) | (b << 8) | c end
local function u16(s, i) local a, b = s:byte(i, i + 1) return (a << 8) | b end
local function u32le(s, i) local a, b, c, d = s:byte(i, i + 3) return a | (b << 8) | (c << 16) | (d << 24) end

function K.ips(src, p)
	if p:sub(1, 5) ~= "PATCH" then return nil, "not an IPS patch" end
	local b = chunks_new(src)
	local pos, records = 6, 0
	while true do
		if pos + 2 > #p then return nil, "IPS patch ends early" end
		if p:sub(pos, pos + 2) == "EOF" and (pos + 3 > #p or #p - (pos + 2) == 3) then
			pos = pos + 3
			break
		end
		if pos + 4 > #p then return nil, "IPS patch ends early" end
		local off, size = u24(p, pos), u16(p, pos + 3)
		pos = pos + 5
		local data
		if size == 0 then
			local count, val = u16(p, pos), p:sub(pos + 2, pos + 2)
			data = val:rep(count)
			pos = pos + 3
		else
			data = p:sub(pos, pos + size - 1)
			if #data < size then return nil, "IPS patch ends early" end
			pos = pos + size
		end
		chunks_write(b, off, data)
		records = records + 1
		if records % 64 == 0 then K.step() end
	end
	local truncate = (#p - pos + 1 == 3) and u24(p, pos) or nil
	return chunks_string(b, truncate)
end

-- ---------------------------------------------------------------------------
-- BPS

-- opts.crc: the source's CRC32 when already known (skips hashing it again)
function K.bps(src, p, opts)
	opts = opts or {}
	if p:sub(1, 4) ~= "BPS1" then return nil, "not a BPS patch" end
	local pos = 5
	local function num()
		local data, shift = 0, 1
		while true do
			local x = p:byte(pos)
			if not x then error("BPS patch ends early") end
			pos = pos + 1
			data = data + (x & 0x7f) * shift
			if x & 0x80 ~= 0 then break end
			shift = shift << 7
			data = data + shift
		end
		return data
	end
	local ok, res = pcall(function()
		local src_size, tgt_size, meta = num(), num(), num()
		pos = pos + meta
		local want_src, want_tgt = u32le(p, #p - 11), u32le(p, #p - 7)
		-- a SNES ROM with a 512-byte copier header the patch wasn't made for
		if #src ~= src_size and #src == src_size + 512 then src = src:sub(513) end
		if #src ~= src_size then
			return { err = string.format("this patch is for a different file (%d bytes, yours is %d)", src_size, #src) }
		end
		local crc = opts.crc or K.crc32(src)
		if crc ~= want_src then
			return { err = string.format("this patch is for a different version of the game (CRC %08x, yours is %08x)", want_src, crc) }
		end
		local o = out_new()
		local src_rel, tgt_rel, ops = 0, 0, 0
		local stop = #p - 12
		while pos <= stop do
			local data = num()
			local cmd, len = data & 3, (data >> 2) + 1
			if cmd == 0 then -- SourceRead
				out_write(o, src:sub(o.total + 1, o.total + len))
			elseif cmd == 1 then -- TargetRead
				out_write(o, p:sub(pos, pos + len - 1))
				pos = pos + len
			elseif cmd == 2 then -- SourceCopy
				local d = num()
				src_rel = src_rel + ((d & 1 == 1) and -(d >> 1) or (d >> 1))
				out_write(o, src:sub(src_rel + 1, src_rel + len))
				src_rel = src_rel + len
			else -- TargetCopy (may overlap what it writes: repeats the pattern)
				local d = num()
				tgt_rel = tgt_rel + ((d & 1 == 1) and -(d >> 1) or (d >> 1))
				local dist = o.total - tgt_rel
				if dist <= 0 then error("bad TargetCopy") end
				if dist >= len then
					out_write(o, out_read(o, tgt_rel, len))
				else
					local pattern = out_read(o, tgt_rel, dist)
					out_write(o, pattern:rep(len // dist + 1):sub(1, len))
				end
				tgt_rel = tgt_rel + len
			end
			ops = ops + 1
			if ops % 256 == 0 then K.step() end
		end
		local out = out_string(o)
		if #out ~= tgt_size then return { err = "the patched file has the wrong size" } end
		if K.crc32(out) ~= want_tgt then return { err = "the patched file doesn't check out (CRC mismatch)" } end
		return { out = out }
	end)
	if not ok then return nil, tostring(res) end
	if res.err then return nil, res.err end
	return res.out
end

-- ---------------------------------------------------------------------------

-- Patches a file with an .ips or .bps (picked by the patch's header). out defaults to the file
-- itself. opts.crc = the file's known CRC32 (number), skips hashing it for BPS.
function K.apply_patch(file, patch, out, opts)
	local src = K.read(file)
	if not src then return nil, "can't read " .. file end
	local p = K.read(patch)
	if not p then return nil, "can't read " .. patch end
	local data, err
	if p:sub(1, 5) == "PATCH" then
		data, err = K.ips(src, p)
	elseif p:sub(1, 4) == "BPS1" then
		data, err = K.bps(src, p, opts)
	else
		return nil, K.base_of(patch) .. " isn't an IPS or BPS patch (xdelta / UPS need an install.lua)"
	end
	if not data then return nil, err end
	return K.replace(out or file, data)
end

return K
