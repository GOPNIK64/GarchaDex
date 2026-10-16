-- GDXProbe / Probe.lua
-- Read-only capability probe for GarchaDex (WoW: Forever, interface 16001).
-- It answers the questions that decide GarchaDex's data model:
--   C  combat log: registration, reader, restriction flag
--   D  loot: can we tie a corpse's loot window to a creature GUID?
--   E  units: are GUID/name/level secret, in and out of combat?
--   F  casts: do we get the enemy's spell ids and their names?
--   G  SavedVariables persistence across sessions
-- Nothing here changes game state: it only reads, counts and prints.
-- Report: /gdxprobe (chat), /gdxprobe box (copyable), /gdxprobe reset.

local addonName, ns = ...

local DB                     -- SavedVariables, created in ADDON_LOADED
local report = {}            -- ordered { k, v } pairs
local frame
local inCombat = false
local stats = {                -- runtime counters
	cleu = 0, cleuDied = 0, cleuSample = 0,
	lootWindows = 0, lootSlots = 0, lootDetail = 0,
	targets = 0, targetsDetail = 0,
	casts = 0, castDetail = 0, castRegister = 0, castRegisterErr = "",
}
local castSeen = {}          -- spellID -> count
local verboseCleu = false

local MAX_TARGET_SAMPLES = 4
local MAX_CAST_SAMPLES = 10
local MAX_LOOT_SAMPLES = 2

-- ------------------------------------------------------------------ helpers

local function isSecret(v)
	if issecretvalue == nil or v == nil then return false end
	local ok, s = pcall(issecretvalue, v)
	return ok and s == true
end

-- Safe string for anything the client may hand us, secrets included.
local function S(v)
	if v == nil then return "nil" end
	local t = type(v)
	if t == "table" then return "<table>" end
	if t == "function" then return "<function>" end
	if isSecret(v) then return "<SECRET:" .. t .. ">" end
	local ok, s = pcall(tostring, v)
	if not ok then return "<tostring-failed:" .. t .. ">" end
	if #s > 60 then s = string.sub(s, 1, 60) .. "..." end
	return s
end

local function pack(...) return { n = select("#", ...), ... } end

local function rec(k, v)
	report[#report + 1] = { k = k, v = S(v) }
	if DB then DB.report = report end
end

local function recRaw(k, s)
	report[#report + 1] = { k = k, v = s }
	if DB then DB.report = report end
end

-- Does a global or namespace path exist?
local function cap(path)
	local node = _G
	for part in string.gmatch(path, "[^%.]+") do
		if type(node) ~= "table" then return false end
		local ok, v = pcall(function() return node[part] end)
		if not ok or v == nil then return false end
		node = v
	end
	return true
end

-- Call a global through pcall, return ok + all values as a pack.
local function trycall(fn, ...)
	if type(fn) ~= "function" then return nil end
	local r = pack(pcall(fn, ...))
	if not r[1] then return false, S(r[2]) end
	return true, r
end

-- ------------------------------------------------------------------ A: build

local function testBuild()
	local bi = pack(GetBuildInfo())
	rec("A1 GetBuildInfo version", bi[1])
	rec("A2 build", bi[2])
	rec("A3 date", bi[3])
	rec("A4 interface", bi[4])
	rec("A5 WOW_PROJECT_ID", WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID or "nil")
	rec("A6 WOW_PROJECT_CAMELOT", WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_CAMELOT or "nil")
	rec("A7 locale", GetLocale and GetLocale() or "?")
	rec("A8 addonName global matches", addonName)
end

-- ------------------------------------------------------------------ B: caps

local CAPS = {
	"issecretvalue", "issecrettable", "strsplit", "date", "GetTime", "wipe",
	"GetNumLootItems", "GetLootSlotInfo", "GetLootSlotLink", "GetLootSlotType",
	"GetLootSourceInfo", "LootSlotHasItem", "LootSlot",
	"UnitGUID", "UnitName", "UnitNameFromGUID", "UnitTokenFromGUID", "UnitLevel",
	"UnitCreatureType", "UnitClassification", "UnitExists", "UnitIsDead", "UnitCanAttack",
	"UnitCastingInfo", "UnitChannelInfo", "GetSpellInfo", "GetItemInfo",
	"CombatLogGetCurrentEventInfo", "CombatLog_Object_IsA",
	"C_CreatureInfo.GetCreatureID", "C_CreatureInfo.GetCreatureTypeInfo",
	"C_Spell.GetSpellInfo", "C_Spell.GetSpellName", "C_Spell.GetSpellTexture",
	"C_Spell.GetSpellLink", "C_Spell.RequestLoadSpellData", "C_Spell.IsSpellDataCached",
	"C_Item.GetItemInfo", "C_Item.GetItemInfoInstant", "C_Item.GetItemIconByID",
	"C_Item.GetItemNameByID", "C_Item.RequestLoadItemDataByID",
	"C_CombatLog.IsCombatLogRestricted", "C_CombatLog.GetMessageLimit",
	"C_CombatLogInternal.GetCurrentEventInfo", "C_CombatLogSecure.GetCurrentEventInfo",
	"C_EncodingUtil.SerializeJSON", "C_Timer.NewTicker", "C_Timer.After",
	"C_AddOns.GetAddOnMetadata", "C_AddOns.LoadAddOn",
	"Settings.RegisterAddOnCategory", "Settings.RegisterAddOnSetting", "Settings.OpenToCategory",
	"GetSpellTexture", "GetItemIconByID", "SetPortraitTexture",
	"SetPortraitTextureFromCreatureDisplayID",
}

local function testCaps()
	local have, missing = 0, {}
	for _, path in ipairs(CAPS) do
		if cap(path) then have = have + 1 else table.insert(missing, path) end
	end
	rec("B1 capabilities present", have .. "/" .. #CAPS)
	recRaw("B2 MISSING", table.concat(missing, ", "))
	-- leftover Classic-era globals: if these exist, old code paths would still work
	rec("B3 legacy GetSpellInfo present", cap("GetSpellInfo") and "yes" or "no")
	rec("B4 legacy GetItemInfo present", cap("GetItemInfo") and "yes" or "no")
end

-- APIDocumentation: the load-on-demand addons behind /apiexport.
-- RISKY: calling LoadAddOn on a Blizzard_* addon is a protected action; asking for it
-- from addon code makes the client print "blocked from an action only available to the
-- Blizzard UI" and flag this addon until a FULL RESTART. Command-only, never automatic.
function ns.probeApiDocs()
	DB.docsTested = true
	local loaded = {}
	if cap("C_AddOns.LoadAddOn") then
		for _, name in ipairs({ "Blizzard_APIDocumentation", "Blizzard_APIDocumentationGenerated" }) do
			local ok, res = trycall(C_AddOns.LoadAddOn, name)
			local shown = ok and (type(res) == "table" and res[2] or res) or res
			table.insert(loaded, name .. "=" .. S(shown))
		end
	elseif type(LoadAddOn) == "function" then
		local ok, res = trycall(LoadAddOn, "Blizzard_APIDocumentationGenerated")
		table.insert(loaded, "LoadAddOn(Generated)=" .. S(ok and (type(res) == "table" and res[2] or res) or res))
	end
	local line = table.concat(loaded, " | ")
	local hasDocs = type(APIDocumentation) == "table" and type(APIDocumentation.systems) == "table"
	recRaw("B5 TEST APIDocumentation load", line)
	rec("B6 APIDocumentation.systems", hasDocs and ("present, " .. #APIDocumentation.systems .. " systems") or "ABSENT")
	print("|cff33ff99GDX Probe|r docs: " .. line .. " -> " ..
		(hasDocs and "|cff00ff00cargado|r" or "|cffff4040no disponible|r"))
	print("|cffffff00Si salio el mensaje 'blocked from an action only available to the Blizzard UI',|r queda claro: no se puede desde un addon; cerrá el cliente entero.")
end

-- ------------------------------------------------------------------ C: CLEU

-- Presence checks are safe. REGISTERING CLEU is a protected action on this client
-- family, so it only runs when asked for explicitly (/gdxprobe cleu): a blocked
-- action flags the whole addon until a FULL CLIENT RESTART, /reload does not clear it.
local function testCleuPresence()
	rec("C2 CombatLogGetCurrentEventInfo", cap("CombatLogGetCurrentEventInfo") and "present" or "ABSENT")
	rec("C3 C_CombatLogInternal.GetCurrentEventInfo", cap("C_CombatLogInternal.GetCurrentEventInfo") and "present" or "ABSENT")
	rec("C4 C_CombatLogSecure.GetCurrentEventInfo", cap("C_CombatLogSecure.GetCurrentEventInfo") and "present" or "ABSENT")
	if cap("C_CombatLog.IsCombatLogRestricted") then
		local ok2, v = trycall(C_CombatLog.IsCombatLogRestricted)
		rec("C5 IsCombatLogRestricted (login)", ok2 and S(v[2]) or ("err:" .. S(v)))
	else
		rec("C5 IsCombatLogRestricted (login)", "function ABSENT")
	end
end

function ns.probeCleuRegister()
	DB.cleuTested = true
	local ok, err = pcall(function() frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") end)
	recRaw("C1 TEST RegisterEvent(CLEU)", ok and "accepted" or ("ERROR -> " .. S(err)))
	print("|cff33ff99GDX Probe|r CLEU registrado: " .. (ok and "|cff00ff00aceptado|r" or ("|cffff4040ERROR|r -> " .. S(err))))
	print("|cffffff00Si ahora aparece 'blocked from an action only available to the Blizzard UI',|r la respuesta es NO: cerrá el cliente entero (no /reload) antes de la proxima prueba.")
end
local function readCleu()
	-- three candidate readers, in order of preference
	if type(CombatLogGetCurrentEventInfo) == "function" then
		local r = pack(pcall(CombatLogGetCurrentEventInfo))
		if r[1] then return r, "global CombatLogGetCurrentEventInfo" end
		return nil, "global errored: " .. S(r[2])
	end
	if cap("C_CombatLogInternal.GetCurrentEventInfo") then
		local r = pack(pcall(C_CombatLogInternal.GetCurrentEventInfo))
		if r[1] then return r, "C_CombatLogInternal" end
		return nil, "C_CombatLogInternal errored: " .. S(r[2])
	end
	if cap("C_CombatLogSecure.GetCurrentEventInfo") then
		local r = pack(pcall(C_CombatLogSecure.GetCurrentEventInfo))
		if r[1] then return r, "C_CombatLogSecure" end
		return nil, "C_CombatLogSecure errored: " .. S(r[2])
	end
	return nil, "no reader present"
end

-- ------------------------------------------------------------------ E: units

local function unitReads(token)
	local out = {}
	local function u(label, fn, ...)
		if type(fn) ~= "function" then out[#out + 1] = label .. "=?fn"; return end
		local r = pack(pcall(fn, ...))
		if not r[1] then out[#out + 1] = label .. "=ERR"; return end
		if r.n == 2 then
			-- single return: show value + secret flag
			out[#out + 1] = label .. "=" .. S(r[2]) .. (isSecret(r[2]) and "(secret)" or "")
		else
			local parts = {}
			for i = 2, math.min(r.n, 4) do
				parts[#parts + 1] = S(r[i]) .. (isSecret(r[i]) and "(secret)" or "")
			end
			out[#out + 1] = label .. "=" .. table.concat(parts, "/")
		end
	end
	u("guid", UnitGUID, token)
	u("name", UnitName, token)
	u("level", UnitLevel, token)
	u("type", UnitCreatureType, token)
	u("class", UnitClassification, token)
	u("exists", UnitExists, token)
	u("dead", UnitIsDead, token)
	u("canAttack", UnitCanAttack, "player", token)
	return out
end

local function testTarget(kind)
	local token = "target"
	if not (type(UnitExists) == "function" and UnitExists(token)) then
		recRaw("E" .. stats.targetsDetail .. " " .. kind .. " target", "no target")
		return
	end
	local parts = unitReads(token)
	-- creatureID from the GUID: the key GarchaDex would index by
	local ok, guid = pcall(UnitGUID, token)
	local cid = "n/a"
	if ok and guid and not isSecret(guid) and cap("C_CreatureInfo.GetCreatureID") then
		local ok2, id = pcall(C_CreatureInfo.GetCreatureID, guid)
		cid = ok2 and S(id) or ("err:" .. S(id))
	elseif ok and guid then
		cid = "guid secret or unusable"
	end
	table.insert(parts, "creatureID=" .. cid)
	-- and the name resolved from the GUID
	if ok and guid and not isSecret(guid) and cap("UnitNameFromGUID") then
		local ok3, nm = pcall(UnitNameFromGUID, guid)
		table.insert(parts, "nameFromGUID=" .. (ok3 and S(nm) or "err"))
	end
	recRaw("E" .. stats.targetsDetail .. " " .. kind .. " target" ..
		(inCombat and " [IN COMBAT]" or " [out of combat]"), table.concat(parts, " "))
end

-- ------------------------------------------------------------------ F: casts

local CAST_EVENTS = {
	"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_STOP",
	"UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
}

local function testCastRegistration()
	local okAll, badAll = {}, {}
	for _, ev in ipairs(CAST_EVENTS) do
		local ok, err = pcall(function() frame:RegisterUnitEvent(ev, "target") end)
		if ok then table.insert(okAll, ev) else table.insert(badAll, ev .. "(" .. S(err) .. ")") end
	end
	recRaw("F0 RegisterUnitEvent(target) ok", table.concat(okAll, ", "))
	recRaw("F0b RegisterUnitEvent(target) FAILED", table.concat(badAll, ", "))
end

local function sampleCast(event, unit, argSpellID, argIsSecret)
	stats.castDetail = stats.castDetail + 1
	local parts = { "event=" .. event, "unit=" .. S(unit), "argSpellID=" .. S(argSpellID) .. (argIsSecret and "(SECRET)" or "") }
	-- every field with its secret flag: this is what tells us which of them we can use
	if type(UnitCastingInfo) == "function" then
		local r = pack(pcall(UnitCastingInfo, "target"))
		if r[1] then
			local f = {}
			for i = 2, math.min(r.n, 11) do
				f[#f + 1] = (i - 1) .. ":" .. S(r[i]) .. (isSecret(r[i]) and "(S)" or "")
			end
			parts[#parts + 1] = "castInfo[" .. (r.n - 1) .. "] " .. table.concat(f, " ")
		else
			parts[#parts + 1] = "castInfo ERR=" .. S(r[2])
		end
	end
	if type(UnitChannelInfo) == "function" then
		local r = pack(pcall(UnitChannelInfo, "target"))
		if r[1] then
			local f = {}
			for i = 2, math.min(r.n, 11) do
				f[#f + 1] = (i - 1) .. ":" .. S(r[i]) .. (isSecret(r[i]) and "(S)" or "")
			end
			parts[#parts + 1] = "chanInfo[" .. (r.n - 1) .. "] " .. table.concat(f, " ")
		end
	end
	-- which operations survive on a secret id? decides how the dex can store it
	if argIsSecret then
		local function probe(label, f)
			local ok, v = pcall(f)
			if not ok then
				parts[#parts + 1] = label .. "=BLOCKED"
			elseif isSecret(v) then
				parts[#parts + 1] = label .. "=ok<secret>"
			else
				parts[#parts + 1] = label .. "=ok:" .. S(v)
			end
		end
		local function probeFn(label, fn, ...)
			if type(fn) ~= "function" then
				parts[#parts + 1] = label .. "=AUSENTE"
				return
			end
			probe(label, function() return fn(...) end)
		end
		probe("tostring", function() return tostring(argSpellID) end)
		probe("concat", function() return "" .. argSpellID end)
		probe("format_s", function() return string.format("%s", argSpellID) end)
		probe("format_d", function() return string.format("%d", argSpellID) end)
		probe("eqzero", function() return argSpellID == 0 end)
		-- can a secret STRING be fingerprinted byte by byte? if yes, spells can be deduped
		local secretName
		if C_Spell and C_Spell.GetSpellInfo then
			local ok, info = pcall(C_Spell.GetSpellInfo, argSpellID)
			if ok and type(info) == "table" and isSecret(info.name) then secretName = info.name end
		end
		if secretName then
			probe("name_len", function() return #secretName end)
			probe("name_byte1", function() return string.byte(secretName, 1) end)
			probe("name_sub", function() return string.sub(secretName, 1, 4) end)
			probe("name_find", function() return string.find(secretName, "a") end)
			probe("name_lower", function() return string.lower(secretName) end)
			probe("name_reverse", function() return string.reverse(secretName) end)
		else
			parts[#parts + 1] = "no hay nombre secreto para fingerprintar"
		end
		probe("GetSpellName", function() return C_Spell and C_Spell.GetSpellName(argSpellID) end)
		probe("C_Spell.GetSpellLink", function() return C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(argSpellID) end)
		probe("C_Spell.GetSpellTexture", function() return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(argSpellID) end)
		-- The link carries the spell id ("spell:5262"). If its bytes can be read one at a time,
		-- the id can be rebuilt as PLAIN text and the dex can dedupe exactly.
		local secretLink
		if C_Spell and C_Spell.GetSpellLink then
			local ok, l = pcall(C_Spell.GetSpellLink, argSpellID)
			if ok and isSecret(l) then secretLink = l end
		end
		if secretLink then
			probe("link_len", function() return #secretLink end)
			probe("link_byte1", function() return string.byte(secretLink, 1) end)
			probe("link_sub", function() return string.sub(secretLink, 1, 6) end)
			probe("link_sub_mid", function() return string.sub(secretLink, 11, 20) end)
			probe("link_find_colon", function() return string.find(secretLink, ":") end)
			probe("link_gsub_digits", function() return string.gsub(secretLink, "%D", "") end)
		else
			parts[#parts + 1] = "sin link secreto para fingerprintar"
		end
		-- other per-spell values: any plain one can serve as a fingerprint for dedupe
		probeFn("IsSpellPassive", C_Spell and C_Spell.IsSpellPassive, argSpellID)
		probeFn("IsSpellDataCached", C_Spell and C_Spell.IsSpellDataCached, argSpellID)
		probeFn("GetSpellCastCount", C_Spell and C_Spell.GetSpellCastCount, argSpellID)
		probeFn("GetSpellCooldownDuration", C_Spell and C_Spell.GetSpellCooldownDuration, argSpellID)
		probeFn("GetSpellDisplayCount", C_Spell and C_Spell.GetSpellDisplayCount, argSpellID)
		probeFn("SpellHasRange", C_Spell and C_Spell.SpellHasRange, argSpellID, "target")
		probeFn("GetSpellCharges", C_Spell and C_Spell.GetSpellCharges, argSpellID)
		-- side channel check: if the client's own encoder turns a secret into a plain
		-- string, we could key and dedupe spells after all
		if cap("C_EncodingUtil.SerializeJSON") then
			probe("SerializeJSON", function()
				local out = C_EncodingUtil.SerializeJSON({ s = argSpellID, n = 1 })
				return out
			end)
		end
		if C_Spell and C_Spell.GetSpellInfo then
			local ok, info = pcall(C_Spell.GetSpellInfo, argSpellID)
			if ok and type(info) == "table" then
				parts[#parts + 1] = "spellInfo name=" .. S(info.name) .. " icon=" .. S(info.iconID) ..
					" nameSecret=" .. tostring(isSecret(info.name)) .. " iconSecret=" .. tostring(isSecret(info.iconID))
			else
				parts[#parts + 1] = "GetSpellInfo(secret)=" .. (ok and S(info) or "BLOCKED")
			end
		end
	elseif type(argSpellID) == "number" and cap("C_Spell.GetSpellInfo") then
		local ok, info = pcall(C_Spell.GetSpellInfo, argSpellID)
		if ok and type(info) == "table" then
			parts[#parts + 1] = string.format("GetSpellInfo name=%s icon=%s cast=%s",
				S(info.name), S(info.iconID or info.originalIconID), S(info.castTime))
		elseif ok then
			parts[#parts + 1] = "GetSpellInfo returned " .. S(info) .. " (not cached yet)"
		else
			parts[#parts + 1] = "GetSpellInfo ERR"
		end
	end
	recRaw("F" .. stats.castDetail .. " cast sample", table.concat(parts, " | "))
end

-- ------------------------------------------------------------------ D: loot

local function testLootDetail()
	stats.lootDetail = stats.lootDetail + 1
	local n = "?"
	if type(GetNumLootItems) == "function" then
		local ok, v = pcall(GetNumLootItems)
		n = ok and S(v) or "err"
	end
	recRaw("D" .. stats.lootDetail .. " loot window", "GetNumLootItems=" .. n ..
		(inCombat and " [IN COMBAT]" or " [out of combat]"))
	-- the corpse identity, the thing that decides the data model
	local guid = "n/a"
	if type(GetLootSourceInfo) == "function" and type(n) == "string" and tonumber(n) then
		for slot = 1, math.min(tonumber(n), 10) do
			local r = pack(pcall(GetLootSourceInfo, slot))
			if r[1] then
				local vals = {}
				for i = 2, math.min(r.n, 4) do
					local label = (i == 2 and "src=") or (i == 3 and "extra=") or (i - 1 .. "=")
					vals[#vals + 1] = label .. S(r[i]) .. ":" .. type(r[i])
				end
				recRaw("D" .. stats.lootDetail .. "." .. slot .. " GetLootSourceInfo", table.concat(vals, " / "))
				-- resolve it to a creature id if we can
				local g = r[2]
				if type(g) == "string" and not isSecret(g) and cap("C_CreatureInfo.GetCreatureID") then
					local ok2, id = pcall(C_CreatureInfo.GetCreatureID, g)
					recRaw("D" .. stats.lootDetail .. "." .. slot .. " creatureID(from source)", ok2 and S(id) or "err")
				end
			else
				recRaw("D" .. stats.lootDetail .. "." .. slot .. " GetLootSourceInfo", "ERROR -> " .. S(r[2]))
			end
		end
	end
	-- per slot content
	if type(GetLootSlotInfo) == "function" and type(n) == "string" and tonumber(n) then
		for slot = 1, math.min(tonumber(n), 10) do
			local r = pack(pcall(GetLootSlotInfo, slot))
			local parts = {}
			if r[1] then
				for i = 2, math.min(r.n, 5) do
					parts[#parts + 1] = S(r[i]) .. (isSecret(r[i]) and "(secret)" or "")
				end
			else
				parts[#parts + 1] = "ERROR " .. S(r[2])
			end
			if type(GetLootSlotLink) == "function" then
				local ok2, link = pcall(GetLootSlotLink, slot)
				parts[#parts + 1] = "link=" .. (ok2 and S(link) or "err")
			end
			if cap("GetLootSlotType") then
				local ok3, t = pcall(GetLootSlotType, slot)
				parts[#parts + 1] = "slotType=" .. (ok3 and S(t) or "err")
			end
			-- a slot can be money instead of an item; and the dex needs an item id,
			-- so try to resolve one from the slot's name (works for cached items)
			local slotName
			local r2 = pack(pcall(GetLootSlotInfo, slot))
			if r2[1] and type(r2[3]) == "string" and not isSecret(r2[3]) then slotName = r2[3] end
			if slotName and cap("C_Item.GetItemInfoInstant") then
				local ok4, iid, _ity, _isub, _ieq, iicon = pcall(C_Item.GetItemInfoInstant, slotName)
				parts[#parts + 1] = "itemID=" .. (ok4 and (S(iid) .. " icon=" .. S(iicon)) or "err")
			end
			recRaw("D" .. stats.lootDetail .. ".s" .. slot, table.concat(parts, " | "))
		end
	end
	-- what unit do we believe dropped this? (fallback path if source GUID fails)
	local dead = {}
	for _, token in ipairs({ "target", "mouseover", "focus", "softinteract", "softenemy" }) do
		if type(UnitExists) == "function" then
			local e1 = pcall(UnitExists, token)
			dead[#dead + 1] = token .. ":" .. (select(2, pcall(UnitExists, token)) == true and "exists" or "-") ..
				":" .. (select(2, pcall(UnitIsDead, token)) == true and "dead" or "alive")
		end
	end
	recRaw("D" .. stats.lootDetail .. " unit fallback", table.concat(dead, " "))
end

-- ------------------------------------------------------------------ events

local H = {}

function H.ADDON_LOADED(_, name)
	if name ~= addonName then return end
	GDXProbeDB = type(GDXProbeDB) == "table" and GDXProbeDB or {}
	DB = GDXProbeDB
	DB.loads = (DB.loads or 0) + 1
	local now = (type(date) == "function" and date("%Y-%m-%d %H:%M:%S")) or "no date()"
	rec("G1 SavedVariables loads (this addon)", DB.loads)
	rec("G2 previous session", DB.lastLoad or "none")
	rec("G3 previous build/interface", (DB.iface or "none") .. " / " .. (DB.build or "?"))
	DB.lastLoad = now
	DB.report = report
	recRaw("G4 now", now)
	frame:UnregisterEvent("ADDON_LOADED")
	local evs = {
		"PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED",
		"LOOT_OPENED", "LOOT_CLOSED", "LOOT_READY",
		"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
	}
	for _, ev in ipairs(evs) do pcall(function() frame:RegisterEvent(ev) end) end
end

function H.PLAYER_LOGIN()
	testBuild()
	testCaps()
	testCleuPresence()
	testCastRegistration()
	local bi = pack(GetBuildInfo())
	DB.build = S(bi[1]); DB.iface = S(bi[4])
	print("|cff33ff99GDX Probe|r cargado. Escribi |cffffff00/gdxprobe|r para el reporte (build " ..
		S(bi[1]) .. ", interface " .. S(bi[4]) .. ").")
	frame:UnregisterEvent("PLAYER_LOGIN")
end

function H.PLAYER_ENTERING_WORLD()
	stats.targetsDetail = stats.targetsDetail + 1
	if stats.targetsDetail <= 1 then testTarget("entering-world") end
end

function H.PLAYER_REGEN_DISABLED()
	inCombat = true
	if cap("C_CombatLog.IsCombatLogRestricted") then
		local ok, v = trycall(C_CombatLog.IsCombatLogRestricted)
		recRaw("C6 IsCombatLogRestricted (in combat)", ok and S(v[2]) or "err")
	end
	testTarget("in-combat")
end

function H.PLAYER_REGEN_ENABLED()
	inCombat = false
	if cap("C_CombatLog.IsCombatLogRestricted") then
		local ok, v = trycall(C_CombatLog.IsCombatLogRestricted)
		recRaw("C7 IsCombatLogRestricted (out of combat)", ok and S(v[2]) or "err")
	end
end

function H.PLAYER_TARGET_CHANGED()
	stats.targets = stats.targets + 1
	if stats.targetsDetail < MAX_TARGET_SAMPLES then
		stats.targetsDetail = stats.targetsDetail + 1
		testTarget("target-change #" .. stats.targets)
	end
end

function H.LOOT_READY() end
function H.LOOT_CLOSED() end

function H.LOOT_OPENED(_, autoLoot, isFromItem)
	stats.lootWindows = stats.lootWindows + 1
	if stats.lootDetail < MAX_LOOT_SAMPLES then
		recRaw("D0 LOOT_OPENED", "autoLoot=" .. S(autoLoot) .. " isFromItem=" .. S(isFromItem))
		testLootDetail()
	end
end

function H.COMBAT_LOG_EVENT_UNFILTERED()
	stats.cleu = stats.cleu + 1
	if stats.cleu > 400 then return end -- the probe only needs a sample, not a meter
	if stats.cleuSample < 1 then
		stats.cleuSample = 1
		local r, how = readCleu()
		if r then
			local parts = { "reader=" .. tostring(how), "fields=" .. tostring(r.n - 1) }
			for i = 2, math.min(r.n, 16) do
				parts[#parts + 1] = i - 1 .. ":" .. S(r[i]) .. (isSecret(r[i]) and "(secret)" or "")
			end
			recRaw("C8 first CLEU payload", table.concat(parts, " | "))
		else
			recRaw("C8 first CLEU payload", "reader unavailable: " .. S(how))
		end
	end
	local r2 = readCleu()
	if r2 and r2[3] == "UNIT_DIED" then stats.cleuDied = stats.cleuDied + 1 end
	if verboseCleu and stats.cleu <= 40 then
		local r3 = readCleu()
		if r3 then recRaw("Cv " .. stats.cleu, "subevent=" .. S(r3[3]) .. " src=" .. S(r3[5]) .. " dst=" .. S(r3[9])) end
	end
end

local known = {
	UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_SUCCEEDED = true, UNIT_SPELLCAST_STOP = true,
	UNIT_SPELLCAST_CHANNEL_START = true, UNIT_SPELLCAST_INTERRUPTED = true, UNIT_SPELLCAST_FAILED = true,
}

local function onCast(event, unit, _, spellID)
	stats.casts = stats.casts + 1
	-- FINDING (build 70425): the spellID argument arrives as a SECRET value, so any
	-- comparison on it throws ("attempt to compare"). Never compare, do math on or
	-- print it; the guard below is what keeps the handler alive.
	local isSec = isSecret(spellID)
	if type(spellID) == "number" and not isSec and spellID > 0 then
		castSeen[spellID] = (castSeen[spellID] or 0) + 1
	end
	if stats.castDetail < MAX_CAST_SAMPLES then sampleCast(event, unit, spellID, isSec) end
end

for ev in pairs(known) do
	H[ev] = function(event, unit, castGUID, spellID) onCast(event, unit, castGUID, spellID) end
end

-- ------------------------------------------------------------------ report

local function buildText()
	local out = {}
	local function add(s) out[#out + 1] = s end
	add("GDX Probe report - GarchaDex capability check")
	local bi = pack(GetBuildInfo())
	add(string.format("client: %s (interface %s) - WOW_PROJECT_ID=%s - %s",
		S(bi[1]), S(bi[4]), tostring(WOW_PROJECT_ID), S(bi[3])))
	add(string.format("counters: CLEU=%d (UNIT_DIED=%d) lootWindows=%d slots=%d targets=%d casts=%d",
		stats.cleu, stats.cleuDied, stats.lootWindows, stats.lootDetail, stats.targets, stats.casts))
	local ids = {}
	for id, c in pairs(castSeen) do ids[#ids + 1] = id .. "x" .. c end
	table.sort(ids)
	add("enemy spell ids seen: " .. (table.concat(ids, " ") ~= "" and table.concat(ids, " ") or "(none yet)"))
	add("-----------------------------------------------------------")
	for _, e in ipairs(report) do add(e.k .. ": " .. e.v) end
	add("-----------------------------------------------------------")
	add("How to read it: C=combat log, D=loot attribution, E=unit secrecy, F=casts, G=SavedVariables.")
	if DB.cleuTested then add("C1 test ran: registering CLEU was attempted on demand.") end
	if DB.docsTested then add("B5 test ran: loading Blizzard_APIDocumentation was attempted on demand.") end
	add("Log out and back in to prove G (loads counter must go up).")
	return table.concat(out, "\n")
end

local box
local function showBox(text)
	if not box then
		box = CreateFrame("Frame", "GDXProbeBox", UIParent)
		box:SetSize(780, 540)
		box:SetPoint("CENTER")
		box:SetMovable(true)
		box:EnableMouse(true)
		box:RegisterForDrag("LeftButton")
		box:SetScript("OnDragStart", function(f) f:StartMoving() end)
		box:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
		-- solid background without depending on BackdropTemplate
		local bg = box:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(box)
		bg:SetColorTexture(0, 0, 0, 0.92)
		local edge = box:CreateTexture(nil, "BORDER")
		edge:SetPoint("TOPLEFT", -2, 2)
		edge:SetPoint("BOTTOMRIGHT", 2, -2)
		edge:SetColorTexture(0.4, 0.8, 0.4, 0.6)
		local eb = CreateFrame("EditBox", nil, box)
		eb:SetMultiLine(true)
		eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(740)
		eb:SetHeight(496)
		eb:SetPoint("TOPLEFT", 18, -18)
		eb:SetAutoFocus(false)
		eb:SetScript("OnEscapePressed", function(f) f:ClearFocus(); box:Hide() end)
		box.edit = eb
		local btn = CreateFrame("Button", nil, box)
		btn:SetSize(70, 22)
		btn:SetPoint("BOTTOMRIGHT", -14, 12)
		btn:SetScript("OnClick", function() box:Hide() end)
		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("CENTER")
		fs:SetText("Cerrar")
		btn:SetFontString(fs)
		box.btn = btn
	end
	box.edit:SetText(text)
	box.edit:HighlightText()
	box:Show()
end

SLASH_GDXPROBE1 = "/gdxprobe"
SLASH_GDXPROBE2 = "/gdxp"
SlashCmdList["GDXPROBE"] = function(msg)
	msg = string.lower(msg or "")
	if msg == "box" then
		local ok, err = pcall(showBox, buildText())
		if ok then
			print("|cff33ff99GDX Probe|r reporte en la ventana: seleccionado, Cmd+C para copiar.")
		else
			print("|cffffff00GDX Probe|r la ventana fallo (" .. S(err) .. "), lo mando al chat:")
			for _, line in ipairs({ strsplit("\n", buildText()) }) do print(line) end
		end
	elseif msg == "reset" then
		report = {}
		if DB then DB.report = report end
		stats.cleu, stats.cleuDied, stats.cleuSample = 0, 0, 0
		stats.lootWindows, stats.lootDetail, stats.lootSlots = 0, 0, 0
		stats.targets, stats.targetsDetail = 0, 0
		stats.casts, stats.castDetail = 0, 0
		castSeen = {}
		print("|cff33ff99GDX Probe|r reporte borrado (los SavedVariables quedan).")
	elseif msg == "cleu" then
		ns.probeCleuRegister()
		verboseCleu = true
		print("|cff33ff99GDX Probe|r CLEU verbose: on")
	elseif msg == "docs" then
		ns.probeApiDocs()
	elseif msg == "verbose" then
		verboseCleu = not verboseCleu
		print("|cff33ff99GDX Probe|r CLEU verbose: " .. (verboseCleu and "on" or "off"))
	else
		for _, line in ipairs({ strsplit("\n", buildText()) }) do print(line) end
		print("|cffffff00/gdxprobe box|r ventana copiable - |cffffff00/gdxprobe reset|r limpia")
		print("|cffffff00/gdxprobe cleu|r registra el combat log (accion protegida: puede salir el aviso 'blocked')")
		print("|cffffff00/gdxprobe docs|r intenta cargar Blizzard_APIDocumentation (misma advertencia)")
	end
end

-- ------------------------------------------------------------------ init

frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, ...)
	local h = H[event]
	if h then
		local ok, err = pcall(h, event, ...)
		if not ok then recRaw("!handler error " .. event, S(err)) end
	end
end)
