-- Minimal JSON decoder (objects, arrays, strings with \u escapes, numbers, true/false/null).
local M = {}

local function utf8char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
	if cp < 0x10000 then return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)) end
	return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

function M.decode(s)
	local i = 1
	local value

	local function fail(msg) error(("json: %s at %d"):format(msg, i), 0) end
	local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end

	local function str()
		i = i + 1
		local out = {}
		while true do
			local j = s:find('["\\]', i)
			if not j then fail("unterminated string") end
			out[#out + 1] = s:sub(i, j - 1)
			if s:sub(j, j) == '"' then
				i = j + 1
				break
			end
			local c = s:sub(j + 1, j + 1)
			if c == "u" then
				local cp = tonumber(s:sub(j + 2, j + 5), 16) or fail("bad \\u")
				i = j + 6
				if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
					local lo = tonumber(s:sub(i + 2, i + 5), 16)
					if lo and lo >= 0xDC00 and lo <= 0xDFFF then
						cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
						i = i + 6
					end
				end
				out[#out + 1] = utf8char(cp)
			else
				out[#out + 1] = ESC[c] or fail("bad escape")
				i = j + 2
			end
		end
		return table.concat(out)
	end

	value = function()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			local t = {}
			i = i + 1
			ws()
			if s:sub(i, i) == "}" then
				i = i + 1
				return t
			end
			while true do
				ws()
				if s:sub(i, i) ~= '"' then fail("expected key") end
				local k = str()
				ws()
				if s:sub(i, i) ~= ":" then fail("expected ':'") end
				i = i + 1
				t[k] = value()
				ws()
				local d = s:sub(i, i)
				i = i + 1
				if d == "}" then return t end
				if d ~= "," then fail("expected ',' or '}'") end
			end
		elseif c == "[" then
			local t = {}
			i = i + 1
			ws()
			if s:sub(i, i) == "]" then
				i = i + 1
				return t
			end
			while true do
				t[#t + 1] = value()
				ws()
				local d = s:sub(i, i)
				i = i + 1
				if d == "]" then return t end
				if d ~= "," then fail("expected ',' or ']'") end
			end
		elseif c == '"' then
			return str()
		elseif s:sub(i, i + 3) == "true" then
			i = i + 4
			return true
		elseif s:sub(i, i + 4) == "false" then
			i = i + 5
			return false
		elseif s:sub(i, i + 3) == "null" then
			i = i + 4
			return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
			if not num or num == "" then fail("unexpected '" .. c .. "'") end
			i = i + #num
			return tonumber(num)
		end
	end

	local ok, res = pcall(value)
	if not ok then return nil, res end
	return res
end

return M
