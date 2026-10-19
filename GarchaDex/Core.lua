-- GarchaDex / Core.lua
-- Framework: namespace, SavedVariables, secret-safe helpers, event dispatcher, slash command.
-- Design notes that come from the capability probe on build 70425 (see GDXProbe):
--   * the combat log is restricted and has no reader  -> kills are counted by polling the target
--   * unit identity (GUID/name/level/type) is NOT secret, in or out of combat
--   * the spellID on UNIT_SPELLCAST_* IS secret        -> never compare or do math on it
--   * loot attribution works: GetLootSourceInfo -> C_CreatureInfo.GetCreatureID gives the npc id

local addonName, ns = ...

ns.VERSION = "0.15.4"
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

-- ------------------------------------------------------------------ offline names (data/gdx_names.lua)
-- The client refuses to name some custom creatures (UnitName returns a secret), so a corpse can leave
-- an entry with nothing but an id. This table, recorded in the beta by warcraftforever.games with the
-- ForeverLog addon, fills that hole as a LAST resort: what the client says always wins.

function ns.NameFromTable(id)
	local row = ns.names and ns.names[tonumber(id)]
	if type(row) ~= "string" then return nil end
	-- plain find/sub splitting: no Lua patterns anywhere, so a stray character in a creature name
	-- cannot make the whole lookup fail the way a pattern would
	local parts, from = {}, 1
	while true do
		local bar = string.find(row, "|", from, true)
		if not bar then
			parts[#parts + 1] = string.sub(row, from)
			break
		end
		parts[#parts + 1] = string.sub(row, from, bar - 1)
		from = bar + 1
	end
	local name = parts[1]
	if not name or name == "" then return nil end
	return name, (parts[2] ~= "" and parts[2] or nil), (parts[3] ~= "" and parts[3] or nil)
end

-- One pass over everything already captured, so the names land at login instead of depending on
-- looting that creature again (or on the client agreeing to name it). Returns how many it filled.
function ns.PatchNames()
	if type(ns.names) ~= "table" then return 0, 0 end
	local filled, total = 0, 0
	for id, e in pairs(DB.seen) do
		total = total + 1
		if type(e) == "table" and not e.name then
			local name, level, ctype = ns.NameFromTable(id)
			if name then
				e.name = name
				e.nameFrom = "tabla"
				if not e.level then
					local hi = string.match(level or "", "^%d+%-(%d+)$")
					e.level = tonumber(hi or level or "")
				end
				if not e.creatureType and ctype then e.creatureType = ctype end
				filled = filled + 1
			end
		end
		-- area: fold a stored subzone into its zone ("Jaggedswine Farm" -> "The Barrens"), and fill the
		-- gap from the table when the entry was captured before the client could tell us, so the index
		-- never has to show "no zone"
		if type(e) == "table" then
			local tableArea = ns.areaOf and ns.areaOf[tonumber(id)]
			if tableArea and ns.areaDungeon and ns.areaDungeon[tableArea] then
				-- an instance always wins over the zone around it: a capture taken in a dungeon whose
				-- client area reads like a city ("Undercity" above the Ruins of Lordaeron) still belongs
				-- to the dungeon, and the index must not merge a dungeon into a capital
				e.zone = tableArea
			else
				if e.zone and not (ns.areaDungeon and ns.areaDungeon[e.zone]) and ns.zoneOfSub and ns.zoneOfSub[e.zone] then
					e.zone = ns.zoneOfSub[e.zone]
				end
				if not e.zone and tableArea then
					e.zone = tableArea
				end
			end
		end
	end
	return filled, total
end

-- Entries neither the client nor the tables could place borrow their area from their id neighbours,
-- but only on a clear majority. Forever handed each of its own instances its own id block (its Ruins
-- of Lordaeron creatures are 2504xx-2507xx and 2560xx), so the ids around an unplaced boss are that
-- dungeon's other creatures. Two independent neighbours must agree before an entry is moved.
function ns.BorrowAreas()
	local seen = DB.seen
	local known = {}
	for id, e in pairs(seen) do
		local n = tonumber(id)
		if n and type(e) == "table" and e.zone then known[#known + 1] = { n = n, area = e.zone } end
	end
	local fixed = 0
	for id, e in pairs(seen) do
		local n = tonumber(id)
		if n and type(e) == "table" and not e.zone then
			local votes, best, total = {}, nil, 0
			for _, other in ipairs(known) do
				if math.abs(other.n - n) <= 1000 then
					votes[other.area] = (votes[other.area] or 0) + 1
					total = total + 1
				end
			end
			for area, count in pairs(votes) do
				if not best or count > votes[best] then best = area end
			end
			if best and total >= 2 and votes[best] / total >= 0.6 then
				e.zone = best
				fixed = fixed + 1
			end
		end
	end
	return fixed
end

-- Manual escape hatch: place every entry that has no area, either under a given name or under the
-- zone the player is standing in. Returns how many it moved.
function ns.AssignZone(name)
	if not name or name == "" then
		local okZone, zone = pcall(GetRealZoneText)
		if okZone and type(zone) == "string" then name = zone end
	end
	if not name or name == "" then return 0 end
	local moved = 0
	for _, e in pairs(DB.seen) do
		if type(e) == "table" and not e.zone then
			e.zone = name
			moved = moved + 1
		end
	end
	return moved, name
end

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
	-- an entry the client could not name: fill it from the offline table, so the index and the card
	-- never show "npc <id>" when the name is known somewhere
	if not e.name then
		local name, level, ctype = ns.NameFromTable(key)
		if name then
			e.name = name
			e.nameFrom = "tabla"
			if not e.level then
				local hi = string.match(level or "", "^%d+%-(%d+)$")
				e.level = tonumber(hi or level or "")
			end
			if not e.creatureType and ctype then e.creatureType = ctype end
		end
	end
	return e
end

function ns.Touch(id, opts)
	local isNew = not DB.seen[id]
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
		-- INVARIANT (account-wide dex, per-faction truth): `hostile` is only ever written from a
		-- creature the current character CAN attack, so it can be true or unset, never false.
		-- A friendly target is never recorded and never flips an existing entry: that is what keeps
		-- two characters of opposite factions from fighting over the same row. Do not "fix" this by
		-- storing false here, and do not filter by it: the index is a list of what is attackable,
		-- and which character met which creature already lives in e.chars.
		if opts.hostile ~= nil then e.hostile = opts.hostile end
		if opts.reaction ~= nil then e.reaction = opts.reaction end
	end
	if not e.zone then
		-- the zone, not the subzone: the index groups "The Barrens" whole, so a creature found at
		-- Jaggedswine Farm files under The Barrens. Instances report their own name, which is what
		-- keeps each dungeon a separate group.
		local okZone, zone = pcall(GetRealZoneText)
		if not (okZone and type(zone) == "string" and zone ~= "") then
			local okFallback, alt = pcall(GetZoneText)
			zone = (okFallback and type(alt) == "string") and alt or nil
		end
		if zone and zone ~= "" then
			-- fold a subzone the client may still hand back under its zone, but never fold a dungeon
			-- into the zone it sits in (Ruins of Lordaeron is not Undercity)
			if not (ns.areaDungeon and ns.areaDungeon[zone]) and ns.zoneOfSub and ns.zoneOfSub[zone] then
				zone = ns.zoneOfSub[zone]
			end
			e.zone = tostringSafe(zone)
		end
	end
	-- the bestiary announces itself: a creature the dex has never recorded before.
	-- A friendly npc is recorded (it has its own tab) but never announced: this is a bestiary.
	if isNew and ns.Discovery and e.hostile ~= false then
		ns.Discovery.Creature("new_enemy", id, e.zone and ("lo viste por primera vez · " .. e.zone) or "lo viste por primera vez")
	end
	return e
end

-- ------------------------------------------------------------------ version stamp (data/gdx_latest.lua)
-- The client has no network and the sandbox has no file IO: the addon can never ask GitHub anything.
-- tools/update.sh does the asking and writes ns.LATEST next to the seed; here we only compare.

local function verNum(v)
	local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
	return (tonumber(a) or 0) * 10000 + (tonumber(b) or 0) * 100 + (tonumber(c) or 0)
end

-- nil when there is nothing newer, or when nobody ever checked. Never a network call, never a guess.
function ns.Outdated()
	if type(ns.LATEST) ~= "string" or ns.LATEST == "" then return nil end
	if verNum(ns.LATEST) <= verNum(ns.VERSION) then return nil end
	return ns.LATEST
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

-- One chat line per capture decision, on by default: naming a group corpse depends on a chain of
-- client calls that fail silently, and watching the chat is faster than any diagnostic window.
-- `/gdx trace off` silences it.
-- Off by default. A line per corpse is useful while chasing a naming bug and unbearable while
-- actually playing a dungeon: `/gdx trace` turns it back on.
local traceOn = false
function ns.Trace(msg)
	if not traceOn then return end
	print("|cff3fd15aGarchaDex|r " .. tostringSafe(msg))
end
function ns.SetTrace(on)
	traceOn = on and true or false
	print("|cff3fd15aGarchaDex|r trace " .. (traceOn and "on" or "off"))
end
function ns.TraceOn() return traceOn end

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
	-- names first: the table fills every entry the client never named, in one pass, before anything
	-- reads them (index, card, toasts)
	local filled, total = ns.PatchNames()
	local borrowed = ns.BorrowAreas()
	local names = 0
	if type(ns.names) == "table" then for _ in pairs(ns.names) do names = names + 1 end end
	-- one line, not three: the chat is for the game, and a dungeon run is loud enough already. The
	-- detail only shows up when it actually did something (names filled, areas borrowed)
	local tail = {}
	if filled > 0 then tail[#tail + 1] = ("nombres %d/%d"):format(filled, total) end
	if borrowed and borrowed > 0 then tail[#tail + 1] = ("zonas %d"):format(borrowed) end
	print(("|cff33ff99GarchaDex|r v%s %s. seed[%s] nombres=%d %s%d%s. |cffffff00/gdx|r %s")
		:format(ns.VERSION, ns.T("cargado"), table.concat(counts, " "), names, ns.T("capturados="), known,
			(#tail > 0 and (" · " .. table.concat(tail, " · ")) or ""), ns.T("para ayuda.")))
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
