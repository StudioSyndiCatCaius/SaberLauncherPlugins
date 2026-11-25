-- Final Fantasy VII: Advanced UI. While you control the character on a field:
--   * party panels (portrait, HP, MP) in the bottom-right corner
--   * a materia in the top-right corner that turns from green to yellow to red as the next random
--     battle gets closer (the field's own danger counter)
--
-- The game's own: portraits (MENU/*.TIM), font, glyph widths and text colours (INIT/WINDOW.BIN) read
-- from the disc; party / HP / MP from the save data in RAM; shown only while the field's own
-- movement lock is off and no menu / battle / screen transition is running; the materia is the
-- menu's own materia sprite in its own colours (INIT/WINDOW.BIN); drawn in the PlayStation's pixels
-- (on_draw_game) so it scales exactly like the game picture.
--
-- Not yet the game's own: the window gradient uses FF7's default colours (the configured ones
-- aren't located in RAM yet) and the border is redrawn.

----------------------------------------------------------------------------------------------
-- Versions

local VERSIONS = {
	-- savemap = the save data in RAM; danger = the field's random-battle counter (its low half is
	-- the immediate of the field code's store, used to tell that a field is loaded)
	-- lock = the field's movement locks (u16 each, 0 = the player can move; the first is the one
	-- GameShark "Text Box Paralysis Disabled" clears, US 8009AC26)
	-- mode = game module (1 field, 2 battle, 5 menu); trans = field transition (3 fading out,
	-- 1 loading / fading in, 0 done); danger_at = the danger counter itself.
	-- EU values measured in swanstation; US = EU + 0x134 like the save data (mode / trans unverified).
	US = { savemap = 0x8009C6E4, danger = 0x173C, lock = 0x8009AC26, mode = 0x8009C560, trans = 0x8009AC40, danger_at = 0x8007173C },
	EU = { savemap = 0x8009C5B0, danger = 0x1620, lock = 0x8009AAF2, mode = 0x8009C42C, trans = 0x8009AB0C, danger_at = 0x80071620 },
}
local BY_ID = {
	["SCUS-94163"] = "US", ["SCUS-94164"] = "US", ["SCUS-94165"] = "US",
	["SCES-00867"] = "EU", ["SCES-10867"] = "EU", ["SCES-20867"] = "EU",
}
local V = VERSIONS[BY_ID[GAME_ID] or ""]

-- character id -> portrait on the disc / record slot in the save data
local PORTRAITS = {
	[0] = "CLOUD", "BARRE", "TIFA", "EARITH", "RED", "YUFI", "KETC", "BINS", "CIDO", "PCLOUD", "PCEFI",
}
local RECORD = { [9] = 6, [10] = 7 } -- Young Cloud / Sephiroth borrow Cait Sith's / Vincent's slots

-- FF7's default window gradient (top-left, top-right, bottom-right, bottom-left)
local WINDOW = { {0, 88, 176, 255}, {0, 0, 80, 255}, {0, 0, 32, 255}, {0, 0, 128, 255} }

-- font palettes (WINDOW.BIN font CLUT rows): FF7's menu text colours
local PAL = { white = 14, gray = 0, cyan = 10, yellow = 12, red = 4 }

----------------------------------------------------------------------------------------------
-- Disc assets

local function u16(s, o) return (string.unpack("<I2", s, o + 1)) end -- (unpack also returns the next index)
local function u32(s, o) return (string.unpack("<I4", s, o + 1)) end

local function c15(v, opaque_black)
	if v == 0 and not opaque_black then return "\0\0\0\0" end
	local r, g, b = (v & 31) << 3, ((v >> 5) & 31) << 3, ((v >> 10) & 31) << 3
	return string.char(r, g, b, 255)
end

-- PlayStation TIM -> width, height, RGBA (palette row `pal`, 16 colours per row for 4 bpp).
-- The pixel block's length field isn't trusted (WINDOW.BIN's font has a wrong one).
local function tim_rgba(t, pal)
	assert(u32(t, 0) == 0x10, "not a TIM")
	local flags = u32(t, 4)
	local bpp = flags & 3
	local o = 8
	local clut = {}
	if flags & 8 ~= 0 then
		local len = u32(t, o)
		local n = (len - 12) // 2
		local per = bpp == 0 and 16 or 256
		local base = (pal or 0) * per
		for i = 0, per - 1 do
			if base + i < n then clut[i] = c15(u16(t, o + 12 + (base + i) * 2)) end
		end
		o = o + len
	end
	local w16, h = u16(t, o + 8), u16(t, o + 10)
	local px = o + 12
	local w = bpp == 0 and w16 * 4 or bpp == 1 and w16 * 2 or w16
	local out = {}
	local k = 1
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local c
			if bpp == 0 then
				local b = t:byte(px + (y * w + x) // 2 + 1)
				c = clut[(x & 1 == 1) and (b >> 4) or (b & 15)]
			elseif bpp == 1 then
				c = clut[t:byte(px + y * w + x + 1)]
			else
				c = c15(u16(t, px + (y * w + x) * 2))
			end
			out[k] = c or "\0\0\0\0"
			k = k + 1
		end
	end
	return w, h, table.concat(out)
end

-- WINDOW.BIN: [u16 packed size, u16, u16 type] + gzip member, three times
-- (0 = menu icons, 1 = font, 2 = glyph widths)
local function window_bin_chunks(bin)
	local chunks, pos = {}, 0
	while pos + 6 < #bin do
		local size = u16(bin, pos)
		local gz = bin:sub(pos + 7, pos + 6 + size)
		-- gzip header: 10 bytes (+ optional extra / name / comment / crc)
		local flg, o = gz:byte(4), 10
		if flg & 4 ~= 0 then o = o + 2 + u16(gz, o) end
		if flg & 8 ~= 0 then o = gz:find("\0", o + 1, true) end
		if flg & 16 ~= 0 then o = gz:find("\0", o + 1, true) end
		if flg & 2 ~= 0 then o = o + 2 end
		chunks[#chunks + 1] = assert(Inflate(gz:sub(o + 1), true))
		pos = pos + 6 + size
	end
	return chunks
end

local font -- {widths = string, images = {pal name -> image id}}
local icons -- {green, yellow, red, gray = image id} of WINDOW.BIN's icon sheet in that materia colour
local ORB = { 130, 34, 8, 8 } -- the menu's materia sprite on the icon sheet
local ORB_PAL = { gray = 1, green = 4, yellow = 8, red = 10 }
local portraits = {} -- character id -> image id | false (missing)
local load_error

local function load_font()
	local bin, err = Disc_Read("INIT/WINDOW.BIN")
	if not bin then return nil, err end
	local chunks = window_bin_chunks(bin)
	font = { widths = chunks[3], images = {} }
	icons = {}
	for name, row in pairs(ORB_PAL) do
		local w, h, px = tim_rgba(chunks[1], row)
		icons[name] = Image_Create("ff7icons_" .. name, w, h, px)
	end
	for name, row in pairs(PAL) do
		local w, h, px = tim_rgba(chunks[2], row)
		font.images[name] = Image_Create("ff7font_" .. name, w, h, px)
	end
	return true
end

-- half size, each pixel the average of a 2x2 block (transparent pixels left out)
local function half(w, h, px)
	local out, k = {}, 1
	for y = 0, h - 2, 2 do
		for x = 0, w - 2, 2 do
			local r, g, b, a, n = 0, 0, 0, 0, 0
			for _, o in ipairs({ (y * w + x) * 4, (y * w + x + 1) * 4, ((y + 1) * w + x) * 4, ((y + 1) * w + x + 1) * 4 }) do
				local pr, pg, pb, pa = px:byte(o + 1, o + 4)
				if pa > 0 then r, g, b, n = r + pr, g + pg, b + pb, n + 1 end
				a = a + pa
			end
			out[k] = n > 0 and string.char(r // n, g // n, b // n, a // 4) or "\0\0\0\0"
			k = k + 1
		end
	end
	return w // 2, h // 2, table.concat(out)
end

local function portrait(id)
	if portraits[id] == nil then
		portraits[id] = false
		local file = PORTRAITS[id]
		local t = file and Disc_Read("MENU/" .. file .. ".TIM")
		if t then
			portraits[id] = Image_Create("ff7face_" .. id, tim_rgba(t, 0))
		end
	end
	return portraits[id]
end

----------------------------------------------------------------------------------------------
-- Game state

local function party()
	local members = {}
	local ids = Mem_Read(V.savemap + 0x4F8, 3)
	for i = 1, 3 do
		local id = ids:byte(i)
		if id ~= 0xFF and id <= 10 then
			local rec = V.savemap + 0x54 + (RECORD[id] or id) * 0x84
			local r = Mem_Read(rec, 0x84)
			members[#members + 1] = {
				id = id,
				level = r:byte(2),
				name = r:sub(0x11, 0x1C):match("^[^\255]*"),
				-- 0x38 / 0x3A are the real maxima (materia included), refreshed while in the party
				hp = u16(r, 0x2C), max_hp = math.max(u16(r, 0x38), u16(r, 0x2C)),
				mp = u16(r, 0x30), max_mp = math.max(u16(r, 0x3A), u16(r, 0x30)),
			}
		end
	end
	return members
end

----------------------------------------------------------------------------------------------
-- Drawing, in the game's own pixels (on_draw_game)

-- FF7-encoded text (byte = glyph: ' ' = 0, 'A' = 0x21...) from a plain string
local function ff7(s) return (s:gsub(".", function(ch) return string.char(math.max(ch:byte() - 0x20, 0)) end)) end

local function text_width(codes)
	local w = 0
	for i = 1, #codes do
		local b = font.widths:byte(codes:byte(i) + 1) or 0
		w = w + (b & 31) + (b >> 5)
	end
	return w
end

-- Panel layout is in panel units; Z game pixels each. 0.375 keeps the font crisp at the usual
-- 4x screen scale (12 px glyphs -> 18 screen px); 0.5 is larger, 0.25 the font's own size at 4x.
local Z = 0.45
local PANEL_W, PANEL_H, GAP = 96, 38, 3       -- panel units
local PAD_X, PAD_Y = 7, 5                     -- inner padding, panel units
local MARGIN_X, MARGIN_Y = 18, 16             -- game pixels from the picture's edges

local function text(codes, x, y, pal)
	local img = font.images[pal or "white"]
	for i = 1, #codes do
		local c = codes:byte(i)
		local b = font.widths:byte(c + 1) or 0
		local lead = b >> 5
		Draw_Image(img, x + lead * Z, y, 12 * Z, 12 * Z, { src = { (c % 21) * 12, (c // 21) * 12, 12, 12 } })
		x = x + ((b & 31) + lead) * Z
	end
	return x
end

local function window(x, y, w, h)
	Draw_Gradient(x, y, w, h, WINDOW[1], WINDOW[2], WINDOW[3], WINDOW[4])
	local light, mid, dark = {216, 216, 216, 255}, {136, 136, 136, 255}, {24, 24, 24, 255}
	local t = Z -- one panel unit
	Draw_Rect(x, y, w, t, dark) Draw_Rect(x, y + h - t, w, t, dark)
	Draw_Rect(x, y, t, h, dark) Draw_Rect(x + w - t, y, t, h, dark)
	Draw_Rect(x + t, y + t, w - 2 * t, t, light) Draw_Rect(x + t, y + t, t, h - 2 * t, light)
	Draw_Rect(x + t, y + h - 2 * t, w - 2 * t, t, mid) Draw_Rect(x + w - 2 * t, y + t, t, h - 2 * t, mid)
end

local function bar(x, y, w, frac, left, right)
	Draw_Rect(x, y, w, 2 * Z, {8, 8, 32, 255})
	local fw = w * math.max(0, math.min(frac, 1))
	if fw > 0 then Draw_Gradient(x, y, fw, Z, left, right, right, left) end
end

local function number(n, x_right, y, pal)
	local s = ff7(tostring(n))
	text(s, x_right - text_width(s) * Z, y, pal)
end

-- compact panel: portrait, HP and MP with a bar each (u = panel units -> game pixels)
local function panel(m, x, y)
	local function u(v) return v * Z end
	window(x, y, u(PANEL_W), u(PANEL_H))
	local face = portrait(m.id)
	local face_size = PANEL_H - 2 * PAD_Y
	if face then Draw_Image(face, x + u(PAD_X), y + u(PAD_Y), u(face_size), u(face_size)) end
	local tx, right = x + u(PAD_X + face_size + 6), x + u(PANEL_W - PAD_X)
	local top = y + u(PAD_Y - 2) -- glyph cells have 2 empty rows on top
	local hp_pal = m.hp == 0 and "red" or (m.hp * 4 <= m.max_hp and "yellow" or "white")
	text(ff7("HP"), tx, top, "cyan")
	number(m.hp, right, top, hp_pal)
	bar(tx, top + u(12), right - tx, m.max_hp > 0 and m.hp / m.max_hp or 0, {48, 96, 232, 255}, {152, 216, 255, 255})
	text(ff7("MP"), tx, top + u(15), "cyan")
	number(m.mp, right, top + u(15), "white")
	bar(tx, top + u(27), right - tx, m.max_mp > 0 and m.mp / m.max_mp or 0, {32, 136, 56, 255}, {136, 232, 144, 255})
end

----------------------------------------------------------------------------------------------

local SHOW_AFTER = 0.25 -- control must last this long (skips the one-frame gaps between scripts)
local controllable_since
local visible = false

-- The player can move: a field is loaded and none of its movement locks is set.
local function has_control()
	return Mem_Read16(V.mode) == 1 and Mem_Read16(V.trans) == 0
		and Mem_Read16(V.lock) == 0 and Mem_Read16(V.lock + 2) == 0
end

-- Danger counter -> 0..1. A battle starts when a random roll falls under (danger >> 8), so the
-- chance per step grows with the counter; full red at DANGER_RED (one battle in swanstation came
-- at 1407, the counter rises about 1 per frame while walking and resets after a battle).
local DANGER_RED = 2048
local function danger_level()
	return math.min(Mem_Read16(V.danger_at) / DANGER_RED, 1)
end

local ORB_SIZE, ORB_MARGIN = 16, 14 -- game pixels (the sprite is 8 px: keep whole multiples)

-- No random battles right now (the field has none, or they're toggled off): the counter doesn't
-- move while you walk. EU: the "toggle encounters" patch in the field code also says so directly.
local QUIET_FRAMES = 45 -- frames of walking without the counter moving
local DARK_GRAY = { 120, 120, 120, 255 } -- tint over the game's gray materia
local quiet = { walked = 0, last = 0, on = false }

local function encounters_off()
	return BY_ID[GAME_ID] == "EU" and Mem_Read16(0x800ABBD2) == 0xA420
end

local function track_encounters(controlling)
	if Mem_Read16(V.trans) ~= 0 then -- new field: judge it again
		quiet.walked, quiet.on = 0, false
		return
	end
	local d = Mem_Read16(V.danger_at)
	if d ~= quiet.last then
		quiet.walked, quiet.on = 0, false
	elseif controlling and (Pad_Down("up") or Pad_Down("down") or Pad_Down("left") or Pad_Down("right")) then
		quiet.walked = quiet.walked + 1
		if quiet.walked >= QUIET_FRAMES then quiet.on = true end
	end
	quiet.last = d
end

local function materia(game_w)
	local t = danger_level()
	local x, y = game_w - ORB_MARGIN - ORB_SIZE, ORB_MARGIN
	local src = { src = ORB }
	if quiet.on or encounters_off() then
		Draw_Image(icons.gray, x, y, ORB_SIZE, ORB_SIZE, { src = ORB, tint = DARK_GRAY })
		return
	end
	-- cross-fade the game's own green / yellow / red materia
	local a, b, f
	if t < 0.5 then a, b, f = "green", "yellow", t * 2 else a, b, f = "yellow", "red", (t - 0.5) * 2 end
	Draw_Image(icons[a], x, y, ORB_SIZE, ORB_SIZE, src)
	if f > 0 then Draw_Image(icons[b], x, y, ORB_SIZE, ORB_SIZE, { src = ORB, alpha = f }) end
end

return {
	name = "Advanced UI",
	author = "Saber",
	description = "Party panels and an encounter materia while you control the character",

	on_start = function()
		if not V then
			Osd("Advanced UI: unsupported version " .. tostring(GAME_ID))
			return
		end
		local ok, res, msg = pcall(load_font)
		if not ok or not res then
			load_error = tostring(ok and msg or res)
			Osd("Advanced UI: " .. load_error)
		end
	end,

	on_frame = function()
		if not V or not font then return end
		local controlling = has_control()
		track_encounters(controlling)
		if controlling then
			controllable_since = controllable_since or Time()
			visible = Time() - controllable_since >= SHOW_AFTER
		else
			controllable_since, visible = nil, false
		end
	end,

	on_draw_game = function(game_w, game_h)
		if not visible then return end
		materia(game_w)
		local members = party()
		local ph, pw, gap = PANEL_H * Z, PANEL_W * Z, GAP * Z
		local y = game_h - MARGIN_Y - #members * ph - (#members - 1) * gap
		for i, m in ipairs(members) do
			panel(m, game_w - MARGIN_X - pw, y + (i - 1) * (ph + gap))
		end
	end,
}
