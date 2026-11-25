-- Final Fantasy VII: press L3 + R3 together to toggle random encounters.
--
-- USA (SCUS-94163/4/5): the "danger" counters that trigger a random battle are held at 0
--   (GameShark 8007173C 0000 field, 8011627C 0000 world map) - plain RAM writes.
-- Europe, English (SCES-00867/10867/20867): the field code's store to the danger counter is
--   patched out (libretro-database "No random battles": D00ABBD2 A422 / 800ABBD2 A420).
--   That's a code patch, so it goes through the core's cheat engine, and turning encounters
--   back on briefly applies the reverse patch until the original instruction is back.

local US = {
	field = 0x8007173C, -- field / dungeons
	world = 0x8011627C, -- world map
}
local EU = {
	off     = "D00ABBD2+A422+800ABBD2+A420",
	restore = "D00ABBD2+A420+800ABBD2+A422",
}
local VERSIONS = {
	["SCUS-94163"] = US, ["SCUS-94164"] = US, ["SCUS-94165"] = US,
	["SCES-00867"] = EU, ["SCES-10867"] = EU, ["SCES-20867"] = EU,
}

local CHEAT = 0 -- cheat slot this mod uses
local RESTORE_FRAMES = 30

local v = VERSIONS[GAME_ID]
local off = false
local changed_at = -10
local restoring = 0

local function apply()
	if v == EU then
		Cheat_Set(CHEAT, true, off and EU.off or EU.restore)
		restoring = off and 0 or RESTORE_FRAMES
	end
end

return {
	name = "Toggle Encounters",
	author = "Saber",
	description = "L3 + R3 toggles random battles on / off",

	on_start = function()
		if not v then Osd("Toggle Encounters: unsupported version " .. tostring(GAME_ID)) end
	end,

	on_frame = function()
		if not v then return end
		if Pad_Down("L3") and Pad_Down("R3") and (Pad_Pressed("L3") or Pad_Pressed("R3")) then
			off = not off
			changed_at = Time()
			apply()
			Osd(off and "Random encounters OFF" or "Random encounters ON")
		end
		if v == US and off then
			Mem_Write16(US.field, 0)
			Mem_Write16(US.world, 0)
		end
		if restoring > 0 then
			restoring = restoring - 1
			if restoring == 0 then Cheat_Set(CHEAT, false, EU.restore) end
		end
	end,

	-- save states: remember the toggle with the state (Saber keeps it in <state>.mods)
	on_save_state = function()
		return off and "off" or "on"
	end,

	on_load_state = function(saved)
		if not v then return end
		local was = off
		if saved then
			off = saved == "off"
		elseif v == EU then
			-- a state made without this hook: the patched field code tells (only while a field is loaded)
			off = Mem_Read16(0x800ABBD2) == 0xA420
		end
		if off ~= was then
			changed_at = Time()
			apply()
		elseif off then
			apply() -- re-arm the cheat for the loaded memory
		end
	end,

	on_draw = function(w, h)
		if not off then return end
		-- small badge in the top-right corner (pops a little bigger right after toggling)
		local s = h / 1080
		local pop = math.max(0, 1 - (Time() - changed_at) * 3)
		local size = (44 + 12 * pop) * s
		local x, y = w - size - 24 * s, 24 * s
		if not Draw_Image("icon.png", x, y, size, size, 0.9) then
			Draw_Rect(x, y, size, size, {0, 0, 0, 170}, size * 0.3)
			local ts = size * 0.55
			Draw_Text("!", x + (size - Text_Width("!", ts)) / 2, y + size * 0.2, ts, {255, 210, 80, 255})
			-- strike-through: encounters are off
			Draw_Rect(x + size * 0.15, y + size * 0.47, size * 0.7, size * 0.07, {255, 80, 80, 230}, 2)
		end
	end,
}
