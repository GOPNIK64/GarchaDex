-- GarchaDex / Core.lua
-- Framework: namespace, SavedVariables, secret-safe helpers, event dispatcher, slash command.
-- Design notes that come from the capability probe on build 70425 (see GDXProbe):
--   * the combat log is restricted and has no reader  -> kills are counted by polling the target
--   * unit identity (GUID/name/level/type) is NOT secret, in or out of combat
--   * the spellID on UNIT_SPELLCAST_* IS secret        -> never compare or do math on it
--   * loot attribution works: GetLootSourceInfo -> C_CreatureInfo.GetCreatureID gives the npc id

local addonName, ns = ...

ns.VERSION = "0.4.0"
ns.DB_VERSION = 1
ns.BOSS_KILL_WINDOW = 5

local DB                      -- GarchaDexDB, built in ADDON_LOADED
local frame
local inCombat = false
local lastBoss = { name = nil, at = 0 }
local watch = nil             -- the mob we are fighting: { guid, id, name, credited }
local ticker

-- ------------------------------------------------------------------ secret-safe helpers

local function isSecret(v)
	if issecretvalue == nil or v == nil then return false end
	local ok, s = pcall(issecretvalue, v)
	return ok and s == true
end
ns.isSecret = isSecret

local function tostringSafe(v)
	if v == nil then return "nil" end
	if isSecret(v) then return "<secret>" end
	local ok, s = pcall(tostring, v)
	return (ok and s) or "<unprintable>"
end
ns.tostringSafe = tostringSafe

-- A secret value can be stored, passed around and handed to a widget, but not compared,
-- indexed, printed or used as a table key. Build a key when the client lets us, and fall
-- back to "no key" (the entry keeps the opaque value in a list) when it does not.
function ns.SpellKey(spellID)
	if spellID == nil then return nil end
	if not isSecret(spellID) then
		local t = type(spellID)
		if t == "number" and spellID > 0 then return tostring(spellID) end
		return nil
	end
	local ok, s = pcall(string.format, "%s", spellID)
	if ok and type(s) == "string" and not isSecret(s) and #s > 0 then
		return s, spellID
	end
	return nil, spellID
end

local function num(v, fallback)
	if type(v) == "number" and not isSecret(v) then return v end
	return fallback
end
ns.num = num

-- ------------------------------------------------------------------ account and character

local function CharKey()
	local name = type(UnitName) == "function" and (select(1, UnitName("player"))) or "unknown"
	local realm = type(GetRealmName) == "function" and GetRealmName() or ""
	if isSecret(name) then name = "unknown" end
	return (realm ~= "" and (realm .. "-" .. tostringSafe(name)) or tostringSafe(name))
end
ns.CharKey = CharKey

local function DefaultDB()
	return {
		version = ns.DB_VERSION,
		seen = {},        -- creatureID -> entry
		chars = {},       -- "Realm-Name" -> per-character counters
		meta = { source = "cmangos classic-db z2815 (vanilla 1.12 reference)", created = nil },
	}
end

-- ------------------------------------------------------------------ entry access

function ns.Entry(id)
	if id == nil then return nil end
	local key = tostringSafe(id)
	if key == "nil" or key == "" then return nil end
	local e = DB.seen[key]
	if not e then
		e = {
			id = key, seen = 0, kills = 0, lootWindows = 0, moneyCopper = 0,
			drops = {}, spells = {}, spellList = {}, chars = {},
		}
		DB.seen[key] = e
	end
	return e
end

function ns.Touch(id, opts)
	local e = ns.Entry(id)
	if not e then return nil end
	e.seen = e.seen + 1
	e.lastSeen = time and time() or nil
	e.firstSeen = e.firstSeen or e.lastSeen
	local ck = CharKey()
	e.chars[ck] = true
	if opts then
		if opts.name and not e.name then e.name = opts.name end
		if opts.level then e.level = opts.level end
		if opts.creatureType and not e.creatureType then e.creatureType = opts.creatureType end
		if opts.classification then e.classification = opts.classification end
	end
	if not e.zone and type(GetRealZoneText) == "function" then e.zone = tostringSafe(GetRealZoneText()) end
	return e
end

-- ------------------------------------------------------------------ seed access (static reference layer)
-- The generated file defines the tables at the namespace root (ns.npc, ns.loot, ns.lootn,
-- ns.spell, ns.wgrp, ns.wloot) and keeps only the provenance in ns.SEED.

function ns.SeedNpc(id)
	local s = ns.npc
	return s and s[tonumber(id)]
end

function ns.SeedLoot(id)
	local s = ns.loot
	return s and s[tonumber(id)]
end

function ns.SeedN(id)
	local s = ns.lootn
	return s and s[tonumber(id)]
end

function ns.SeedSpells(id)
	local s = ns.spell
	return s and s[tonumber(id)]
end

-- seed loot: "item:chance,item:chance|item:chance" (own | shared groups)
function ns.ParseLoot(str)
	local own, shared = {}, {}
	if not str then return own, shared end
	local part = 1
	for chunk in string.gmatch(str, "[^|]+") do
		local t = part == 1 and own or shared
		for item, chance in string.gmatch(chunk, "(%d+):([%-%d%.]+)") do
			t[tonumber(item)] = tonumber(chance)
		end
		part = part + 1
	end
	return own, shared
end

function ns.IsInCombat() return inCombat end
function ns.DB() return DB end

-- A swallowed error is a bug you cannot see. Every capture handler reports through here,
-- once per distinct message, so a broken path shows up in chat instead of staying invisible.
local reportedErrors = {}
function ns.ReportError(where, err)
	local key = tostring(where) .. "|" .. tostring(err)
	if reportedErrors[key] then return end
	reportedErrors[key] = true
	print(("|cffff4040GarchaDex|r error en %s: %s"):format(tostring(where), ns.tostringSafe(err)))
end

-- ------------------------------------------------------------------ events

local H = {}

function H.ADDON_LOADED(_, name)
	if name ~= addonName then return end
	GarchaDexDB = type(GarchaDexDB) == "table" and GarchaDexDB or DefaultDB()
	DB = GarchaDexDB
	DB.version = DB.version or ns.DB_VERSION
	DB.meta = DB.meta or { source = "cmangos classic-db z2815 (vanilla 1.12 reference)" }
	DB.meta.created = DB.meta.created or (time and time() or nil)
	DB.seen = DB.seen or {}
	DB.chars = DB.chars or {}
	if DB.meta.lang and ns.SetLang then ns.SetLang(DB.meta.lang) end
	local ck = CharKey()
	DB.chars[ck] = DB.chars[ck] or { kills = 0, loots = 0, spells = 0 }
	if not DB.meta.interface then
		local bi = { GetBuildInfo() }
		DB.meta.interface = bi[4]
		DB.meta.build = bi[2]
	end
	frame:UnregisterEvent("ADDON_LOADED")
	for _, ev in ipairs({
		"PLAYER_LOGIN", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_DEAD",
	}) do
		pcall(function() frame:RegisterEvent(ev) end)
	end
	if ns.RegisterCapture then ns.RegisterCapture(frame) end
end

function H.PLAYER_LOGIN()
	local counts = {}
	for _, name in ipairs({ "npc", "loot", "lootn", "spell" }) do
		local t = ns[name]
		if type(t) == "table" then
			local n = 0
			for _ in pairs(t) do n = n + 1 end
			counts[#counts + 1] = name .. "=" .. n
		else
			counts[#counts + 1] = name .. "=AUSENTE"
		end
	end
	local known = 0
	for _ in pairs(DB.seen) do known = known + 1 end
	print(("|cff33ff99GarchaDex|r v%s %s. seed[%s] %s%d. |cffffff00/gdx|r %s")
		:format(ns.VERSION, ns.T("cargado"), table.concat(counts, " "), ns.T("capturados="), known, ns.T("para ayuda.")))
	if type(ns.lootn) ~= "table" or type(ns.spell) ~= "table" then
		print("|cffff4040GarchaDex|r " .. ns.T("el seed NO se cargo: revisá que GarchaDex/data/gdx_seed.lua exista (el .toc lo lista como data\\gdx_seed.lua) y mirá si hubo un error de Lua al iniciar."))
	end
	ns.StartKillWatch()
	if ns.UI and ns.UI.BuildBar then pcall(ns.UI.BuildBar) end
	frame:UnregisterEvent("PLAYER_LOGIN")
end

function H.PLAYER_REGEN_DISABLED()
	inCombat = true
	ns.StartKillWatch()
end

function H.PLAYER_REGEN_ENABLED()
	inCombat = false
	if ns.CreditWatch then ns.CreditWatch("combat-end") end
end

frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, ...)
	local h = H[event]
	if h then
		local ok, err = pcall(h, event, ...)
		if not ok then print("|cffff4040GarchaDex|r error en " .. event .. ": " .. tostringSafe(err)) end
	end
end)
ns.frame = frame
ns.OnCapture = ns.OnCapture or function() end
ns.SetBoss = function(name, at) lastBoss.name, lastBoss.at = name, at or (GetTime and GetTime() or 0) end
ns.RecentBoss = function()
	if not lastBoss.name or not GetTime then return nil end
	if GetTime() - lastBoss.at > ns.BOSS_KILL_WINDOW then return nil end
	return lastBoss.name
end
