-- GarchaDex / Capture.lua
-- The live half of the dex: what the client lets an addon see, recorded per creature.
--
-- Measured on build 70425 (see GDXProbe), and every decision below follows from it:
--   * identity (GUID, name, level, creature type, classification) is NOT secret -> capture any time
--   * loot: GetLootSourceInfo(slot) -> corpse GUID -> C_CreatureInfo.GetCreatureID -> npc id
--   * spells: the spellID on UNIT_SPELLCAST_* IS secret. tostring/format stay secret, `==`
--     throws, and a secret cannot be a table key or be compared, so spells CANNOT be deduped
--     or keyed. What we can do: count the cast events, and keep the secret name/icon so a
--     widget can draw them (the same thing the client's own cast bar does).
--   * no combat log at all -> kills are credited by watching the target

local addonName, ns = ...

local watching                 -- the mob we are currently fighting: { id, credited }
local lastKilled               -- the last mob we credited a kill to: { id, at, name, level }
-- The last creature the cursor was over. This is the key to naming group loot: by the time
-- LOOT_OPENED fires, the cursor is already on the loot panel, so mouseover/npc/target are all empty.
-- The corpse you right-clicked a second ago is still here, with its name and level.
local lastMouseover             -- the last creature the cursor touched: { id, name, level, at }
local mouseoverHistory = {}     -- the last few, newest last: the loot matches by id, else by recency
local mouseoverEvents = 0       -- how many times the cursor event fired: tells "no memory" from "no event"
local enrichFromLive           -- forward declaration: onLootClosed (below) needs it, and a local
                               -- declared further down is an invisible nil global inside that closure
local lootWindow               -- { id, isObject, moneyBefore }
local lastCast                 -- { name, icon } secret values, for the render test
local MAX_SPELL_LOG = 12
local POLL_SECONDS = 0.5

local function isSecret(v) return ns.isSecret(v) end

-- ------------------------------------------------------------------ identity

-- Returns the npc id plus the readable fields, or nil when this token is not a creature.
function ns.UnitIdentity(token)
	if type(UnitExists) ~= "function" then return nil end
	local ok, exists = pcall(UnitExists, token)
	if not ok or exists ~= true then return nil end
	local okg, guid = pcall(UnitGUID, token)
	if not okg or guid == nil or isSecret(guid) then return nil end
	if not (C_CreatureInfo and C_CreatureInfo.GetCreatureID) then return nil end
	local okc, cid = pcall(C_CreatureInfo.GetCreatureID, guid)
	if not okc or type(cid) ~= "number" or cid == 0 then return nil end
	local name, level, ctype, class
	local o1, v1 = pcall(UnitName, token)
	if o1 and not isSecret(v1) then name = v1 end
	local o2, v2 = pcall(UnitLevel, token)
	if o2 and not isSecret(v2) then level = v2 end
	local o3, v3 = pcall(UnitCreatureType, token)
	if o3 and not isSecret(v3) then ctype = v3 end
	local o4, v4 = pcall(UnitClassification, token)
	if o4 and not isSecret(v4) then class = v4 end
	-- hostile or not decides whether this is a bestiary entry or just an npc walking around
	local canAttack, reaction
	if type(UnitCanAttack) == "function" then
		local o5, v5 = pcall(UnitCanAttack, "player", token)
		if o5 and not isSecret(v5) then canAttack = v5 end
	end
	-- and the reaction keeps the nuance (hostile / neutral / friendly) for later, if the dex ever
	-- wants three tabs instead of two
	if type(UnitReaction) == "function" then
		local o6, v6 = pcall(UnitReaction, "player", token)
		if o6 and not isSecret(v6) then reaction = v6 end
	end
	return tostring(cid), name, level, ctype, class, canAttack, reaction
end

-- Only plain strings are usable: comparing, hashing or measuring a secret value throws, and the client
-- returns secrets for names and GUIDs of these creatures.
local function plainString(v)
	if v == nil then return nil end
	if isSecret(v) then return nil end
	if type(v) ~= "string" then return nil end
	if #v == 0 then return nil end
	return v
end
ns.plainString = plainString

-- GameTooltip holds what the client refuses to hand over: the name on the first line and "Level N"
-- on the second. Reading a tooltip gives plain text, so this survives a secret name — which is what
-- these custom creatures return from UnitName.
local function tooltipUnit(token, needName, needLevel)
	if not GameTooltip or type(GameTooltip.SetUnit) ~= "function" then return nil, nil end
	local ok = pcall(function()
		GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
		GameTooltip:SetUnit(token)
	end)
	if not ok then return nil, nil end
	local function line(n)
		local fs = _G["GameTooltipTextLeft" .. n]
		return (fs and fs.GetText) and fs:GetText() or nil
	end
	local name, level
	if needName then
		name = plainString(line(1))
	end
	if needLevel then
		-- plainString first: calling a string method on a secret value throws, and the tooltip text of a
		-- creature whose name is secret can be secret too
		local second = plainString(line(2))
		local digits = second and second:match("(%d+)")
		level = digits and tonumber(digits) or nil
	end
	pcall(function() GameTooltip:Hide() end)
	return name, level
end
ns.tooltipUnit = tooltipUnit

-- Identity with this client's two fallbacks: a name or level that comes back secret is read off the
-- tooltip instead. Use this everywhere a live unit is read; UnitIdentity alone loses custom creatures.
function ns.UnitIdentityRich(token)
	local id, name, level, ctype, class, canAttack, reaction = ns.UnitIdentity(token)
	if not id then return nil end
	if not name or not level then
		-- the tooltip first: it is what the client draws, so the text is there
		local tName, tLevel = tooltipUnit(token, not name, not level)
		name = name or tName
		level = level or tLevel
	end
	if not name and type(GetUnitName) == "function" then
		-- last resort: GetUnitName has its own path to the name and sometimes answers when UnitName
		-- refuses (it takes the same token plus a "show realm" flag)
		local ok, v = pcall(GetUnitName, token, false)
		if ok and type(v) == "string" and v ~= "" and not isSecret(v) then name = v end
	end
	return id, name, level, ctype, class, canAttack, reaction
end

-- ------------------------------------------------------------------ kills (no combat log: watch the target)

local function credit(reason)
	if not watching or watching.credited then return end
	watching.credited = true
	local wid = watching.id
	local e = ns.Entry(wid)
	if not e then return end
	local first = (e.kills or 0) == 0
	e.kills = (e.kills or 0) + 1
	e.lastKill = time and time() or nil
	lastKilled = {
		id = watching.id, at = (GetTime and GetTime()) or 0,
		name = watching.name, level = watching.level,
	}
	local ck = ns.CharKey()
	local c = ns.DB().chars[ck]
	if c then c.kills = (c.kills or 0) + 1 end
	ns.OnCapture("kill", e, reason)
	if first and ns.Discovery then
		ns.Discovery.Creature("first_kill", wid, "lo mataste por primera vez")
	end
	watching = nil
end
ns.CreditWatch = credit

-- the last creature this character killed: the dex opens on it, so it lives next to the credit
function ns.LastKilled()
	return lastKilled and lastKilled.id
end

-- Fallback for the corpse identity: if GetLootSourceInfo gives us nothing, the mob we just
-- killed (within a few seconds) is the honest guess, and the row gets tagged as such.
local function recentKill()
	if not lastKilled or not GetTime then return nil end
	if GetTime() - lastKilled.at > 15 then return nil end
	return lastKilled.id, true
end

function ns.PollTarget()
	if not ns.IsInCombat() then return end
	local id, name, level, ctype, class, canAttack, reaction = ns.UnitIdentityRich("target")
	local ok, dead = pcall(UnitIsDead, "target")
	dead = ok and dead == true
	if id and not dead and canAttack ~= false then
		if not watching then
			watching = { id = id, name = name, level = level, ctype = ctype, classification = class }
			ns.Touch(id, { name = name, level = level, creatureType = ctype, classification = class, hostile = canAttack, reaction = reaction })
		elseif watching.id ~= id then
			credit("switched target")
			watching = { id = id }
			ns.Touch(id, { name = name, level = level, creatureType = ctype, classification = class, hostile = canAttack, reaction = reaction })
		end
	elseif watching then
		credit(dead and "died" or "gone")
	end
end

function ns.StartKillWatch()
	if not (C_Timer and C_Timer.NewTicker) then return end
	if ns.ticker then return end
	ns.ticker = C_Timer.NewTicker(POLL_SECONDS, function() pcall(ns.PollTarget) end)
end

-- ------------------------------------------------------------------ loot

local function slotCount()
	if type(GetNumLootItems) ~= "function" then return 0 end
	local ok, n = pcall(GetNumLootItems)
	return (ok and type(n) == "number") and n or 0
end

local function sourceOf(slot)
	if type(GetLootSourceInfo) ~= "function" then return nil end
	local ok, src, extra = pcall(GetLootSourceInfo, slot)
	if not ok or type(src) ~= "string" or isSecret(src) then return nil end
	local amount = (type(extra) == "number" and not isSecret(extra)) and extra or nil
	local head = string.sub(src, 1, 10)
	if head == "GameObject" then return nil, src, true, amount end
	if string.sub(src, 1, 8) ~= "Creature" then return nil end
	if not (C_CreatureInfo and C_CreatureInfo.GetCreatureID) then return nil end
	local ok2, cid = pcall(C_CreatureInfo.GetCreatureID, src)
	if not ok2 or type(cid) ~= "number" or cid == 0 then return nil, src end
	return tostring(cid), src, nil, amount
end

-- The item id travels in the LINK even when the client has no name cache for the item
-- (measured: "Tough Jerky" resolved to nil by name, while the link carries its id).
-- The exact shape of the link differs per client, so several extractions are tried and the
-- raw string is kept for diagnosis.
local function idFromLink(link)
	if type(link) ~= "string" or isSecret(link) then return nil end
	local num = string.match(link, "|Hitem:(%d+)") or string.match(link, "Hitem:(%d+)")
		or string.match(link, "item:(%d+)") or string.match(link, "^(%d+):")
	if num then return tonumber(num) end
	if C_Item and C_Item.GetItemInfoInstant then
		local ok, iid = pcall(C_Item.GetItemInfoInstant, link)
		if ok and type(iid) == "number" then return iid end
	end
	return nil
end

local function slotItem(slot)
	local link
	if type(GetLootSlotLink) == "function" then
		local okl, l = pcall(GetLootSlotLink, slot)
		if okl and type(l) == "string" and not isSecret(l) then link = l end
	end
	local id = idFromLink(link)
	local oks, _icon, name, quantity = pcall(GetLootSlotInfo, slot)
	if not oks or type(name) ~= "string" or isSecret(name) then return nil end
	if not id and C_Item and C_Item.GetItemInfoInstant then
		local oki, iid = pcall(C_Item.GetItemInfoInstant, name)
		if oki and type(iid) == "number" then id = iid end
	end
	return {
		name = name,
		id = id,
		link = link and string.sub(link, 1, 90) or nil,
		qty = (type(quantity) == "number" and quantity) or 1,
	}
end

-- One corpse can open the loot window more than once (measured: 3 slots, then 1 again for the
-- same body), so the denominator counts CORPSES, keyed by the source GUID (a plain string).
local lootSessions = {}
local sessionCount = 0
local MAX_SESSIONS = 240

local function sessionFor(guid)
	if not guid then return nil end
	local s = lootSessions[guid]
	if not s then
		if sessionCount > MAX_SESSIONS then
			lootSessions = {}
			sessionCount = 0
		end
		s = { windows = 0, taken = {}, money = 0 }
		lootSessions[guid] = s
		sessionCount = sessionCount + 1
	end
	return s
end

local function onLootOpened()
	lootWindow = { moneyBefore = (type(GetMoney) == "function" and GetMoney()) or 0 }
	local n = slotCount()
	-- 1. the items and the money (slot type 2: the slot name reads "2 Copper", no link)
	for slot = 1, math.min(n, 30) do
		local slotType
		if type(GetLootSlotType) == "function" then
			local ok, t = pcall(GetLootSlotType, slot)
			if ok and type(t) == "number" then slotType = t end
		end
		if slotType == 2 then
			-- the amount comes in the second return of GetLootSourceInfo, and it is more
			-- reliable than a GetMoney() delta when auto-loot moves money before we look
			local _id, _guid, _obj, amount = sourceOf(slot)
			if amount then lootWindow.moneySlots = (lootWindow.moneySlots or 0) + amount end
		else
			local item = slotItem(slot)
			if item then
				lootWindow.slots = lootWindow.slots or {}
				lootWindow.slots[#lootWindow.slots + 1] = item
			end
		end
	end
	-- 2. the corpse identity: the source GUID is preferred (it is what makes attribution real)
	for slot = 1, math.min(n, 30) do
		local id, guid, isObject = sourceOf(slot)
		if guid and not lootWindow.rawSource then lootWindow.rawSource = guid end
		if isObject then lootWindow.isObject = true end
		if id then
			lootWindow.id = id
			break
		end
	end
	-- 3. fallback: if the client gave us no usable source, attribute to the mob we just killed
	if not lootWindow.id and not lootWindow.isObject then
		local fid, isFallback = recentKill()
		if fid then
			lootWindow.id, lootWindow.fallback = fid, true
		end
	end
	-- 4. name it NOW: the loot source hands over an id and nothing else, and by LOOT_CLOSED the body
	-- is often already gone. Here the corpse is still under the cursor that clicked it.
	if lootWindow.id and not lootWindow.isObject then
		local ok, why = enrichFromLive(lootWindow.id, lootWindow.rawSource)
		lootWindow.enriched = ok
		if not ok then
			-- a corpse you opened is a sighting even when the client refuses to name it, or the card
			-- reads "seen 0 · looted 7" and looks broken
			local e = ns.Entry(lootWindow.id)
			if e and not e.name then
				e.seen = (e.seen or 0) + 1
				e.lastSeen = time and time() or nil
			end
		end
		if ns.Trace then
			local what
			if ok then
				what = ns.T("nombrado por") .. " " .. ns.T(tostring(why))
			else
				what = ns.T("sin nombre") .. " (" .. ns.T(tostring(why)) .. ")"
			end
			ns.Trace(ns.T("looteo") .. " " .. tostring(lootWindow.id) .. " · " .. what .. " · " .. ns.EnrichDebug())
		end
	end
end

local function onLootClosed()
	if not lootWindow then return end
	local db = ns.DB()
	if not db then return end
	-- money: the slot amount first (it is what the corpse actually held), the delta as fallback
	local money = lootWindow.moneySlots or 0
	if money == 0 and type(GetMoney) == "function" then
		local now = GetMoney()
		if type(now) == "number" and now > lootWindow.moneyBefore then money = now - lootWindow.moneyBefore end
	end
	local summary = {}
	for _, s in ipairs(lootWindow.slots or {}) do
		summary[#summary + 1] = ("%s(id=%s%s)"):format(s.name, tostring(s.id),
			s.id == nil and (", link=" .. (s.link or "NO")) or "")
	end
	local e = lootWindow.id and ns.Entry(lootWindow.id)
	-- born from a corpse and nothing else: try to name it while the loot window is still open
	if e and not e.name then enrichFromLive(lootWindow.id) end
	local method = lootWindow.fallback and "fallback-ultimo-kill" or (lootWindow.isObject and "objeto/nodo" or "source-guid")
	-- one line per loot event, kept in the saved variables: this is what /gdx loot prints
	db.meta.lootLog = db.meta.lootLog or {}
	table.insert(db.meta.lootLog, {
		t = time and time() or 0,
		src = lootWindow.rawSource or "nil",
		id = lootWindow.id or "nil",
		method = method,
		money = money,
		items = (#summary > 0) and table.concat(summary, " + ") or "-",
	})
	while #db.meta.lootLog > 10 do table.remove(db.meta.lootLog, 1) end
	if not e and not lootWindow.isObject then
		-- worth knowing about: something was looted and nothing could be attributed
		db.meta.lastLootSource = lootWindow.rawSource or "sin source"
		db.meta.lastLootUnattributed = (db.meta.lastLootUnattributed or 0) + 1
		local ck = ns.CharKey()
		local c = db.chars[ck]
		if c then c.lootUnattributed = (c.lootUnattributed or 0) + 1 end
	end
	if e then
		db.meta.lastLootSource = lootWindow.rawSource or "sin source"
		if lootWindow.fallback then e.lootFallback = (e.lootFallback or 0) + 1 end
		local sess = sessionFor(lootWindow.rawSource)
		local firstWindow = false
		if sess then
			sess.windows = sess.windows + 1
			sess.money = sess.money + money
			firstWindow = sess.windows == 1
		else
			-- no source GUID: we cannot dedupe, so count it and leave a trace of why
			firstWindow = true
			e.lootNoGuid = (e.lootNoGuid or 0) + 1
		end
		if firstWindow then
			e.lootWindows = (e.lootWindows or 0) + 1
			-- no toast for "first loot window": the only loot news worth interrupting for is an item
			-- it had never dropped for this creature (new_drop). One per corpse, not two.
		end
		e.moneyCopper = (e.moneyCopper or 0) + money
		local added = 0
		for _, s in ipairs(lootWindow.slots or {}) do
			local key = s.id and tostring(s.id) or ("name:" .. s.name)
			-- the same body can show the same row twice across windows: count it once per corpse
			if not (sess and sess.taken[key]) then
				if sess then sess.taken[key] = true end
				local d = e.drops[key]
				if not d then
					d = { name = s.name, count = 0, qty = 0, id = s.id }
					e.drops[key] = d
					-- a drop the pool did not show yet: this is the discovery the dex lives for
					if ns.Discovery then
						local own, shared = ns.ParseLoot(ns.SeedLoot(lootWindow.id))
						local iid = tonumber(s.id)
						local chance = iid and (own[iid] or shared[iid]) or nil
						local total = ns.SeedN(lootWindow.id)
						local disc = 0
						for k in pairs(own) do
							if e.drops[tostring(k)] then disc = disc + 1 end
						end
						ns.Discovery.Drop(lootWindow.id, s.id, s.name, chance, disc, total)
						-- and when the last unknown item of the pool falls, the entry is complete
						if total and total > 0 and disc >= total and not e.poolDone then
							e.poolDone = true
							ns.Discovery.Creature("pool_done", lootWindow.id, ("pool completa · %d items"):format(total))
						end
					end
				end
				d.count = d.count + 1
				d.qty = d.qty + s.qty
				d.last = time and time() or nil
				added = added + 1
			end
		end
		local ck = ns.CharKey()
		local c = ns.DB().chars[ck]
		if c then c.loots = (c.loots or 0) + 1 end
		ns.OnCapture("loot", e, ("%d filas nuevas, +%d cobre"):format(added, money))
	elseif lootWindow.isObject then
		local ck = ns.CharKey()
		local c = ns.DB().chars[ck]
		if c then c.nodes = (c.nodes or 0) + 1 end
	end
	lootWindow = nil
end

-- ------------------------------------------------------------------ enemy casts

local CAST_EVENTS = {
	UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_CHANNEL_START = true,
	UNIT_SPELLCAST_SUCCEEDED = true, UNIT_SPELLCAST_INTERRUPTED = true,
}

-- The spell's name and icon are secret values: store them, never compare or print them.
-- Several client paths can hand them over, and which one works is measured, not assumed,
-- so the log entry records WHICH call produced the value (printed by /gdx text as a clue).
local function spellInfoFor(spellID)
	local name, icon, how = nil, nil, nil
	if not C_Spell then return name, icon, "no C_Spell" end
	if C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and type(info) == "table" then
			name, icon, how = info.name, info.iconID, "GetSpellInfo"
		else
			how = ok and ("GetSpellInfo->" .. type(info)) or "GetSpellInfo-BLOQUEADO"
		end
	else
		how = "sin GetSpellInfo"
	end
	if name == nil and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, spellID)
		if ok and n ~= nil then name, how = n, (how or "") .. "+GetSpellName" end
	end
	if icon == nil and C_Spell.GetSpellTexture then
		local ok, t = pcall(C_Spell.GetSpellTexture, spellID)
		if ok and t ~= nil then icon, how = t, (how or "") .. "+GetSpellTexture" end
	end
	-- a spell the client has not cached yet answers with no name (measured on a summon cast):
	-- ask for it, so the next cast of the same spell resolves
	if name == nil and C_Spell.RequestLoadSpellData then
		pcall(C_Spell.RequestLoadSpellData, spellID)
	end
	return name, icon, how
end

function ns.OnCast(event, unit, spellID, isSecretArg)
	local e = watching and ns.Entry(watching.id)
	local name, icon, how = spellInfoFor(spellID)
	if name ~= nil and type(name) == "string" and not isSecret(name) then
		-- readable (non-secret) path: keep it and count per spell
		if e then
			e.spells[name] = (e.spells[name] or 0) + 1
			e.spellIcon = e.spellIcon or {}
			e.spellIcon[name] = icon
		end
	end
	if e then
		local firstCast = (e.casts or 0) == 0
		e.casts = (e.casts or 0) + 1
		e.spellLog = e.spellLog or {}
		table.insert(e.spellLog, { name = name, icon = icon, how = how, at = time and time() or nil })
		while #e.spellLog > MAX_SPELL_LOG do table.remove(e.spellLog, 1) end
		if firstCast and ns.Discovery and watching then
			local refs = 0
			for _ in string.gmatch(ns.SeedSpells(watching.id) or "", "%d+") do refs = refs + 1 end
			ns.Discovery.Creature("first_cast", watching.id,
				refs > 0 and (refs .. " " .. ns.T("hechizos en la base 1.12")) or "le viste castear")
		end
	end
	lastCast = { name = name, icon = icon, how = how, secret = isSecretArg and true or false, spell = spellID }
	local ck = ns.CharKey()
	local c = ns.DB().chars[ck]
	if c then c.spells = (c.spells or 0) + 1 end
end

function ns.LastCast() return lastCast end

-- ------------------------------------------------------------------ wiring

local H = {}

function H.PLAYER_TARGET_CHANGED()
	if ns.IsInCombat() then ns.PollTarget() else
		local id, name, level, ctype, class, canAttack, reaction = ns.UnitIdentityRich("target")
		-- the dex is a bestiary: a creature nobody can attack (a vendor, a guard, a quest npc) is
		-- not an entry, it is scenery. Only untrackable-when-explicitly-friendly.
		if id and canAttack ~= false then
			ns.Touch(id, { name = name, level = level, creatureType = ctype, classification = class, hostile = canAttack, reaction = reaction })
		end
	end
end

-- Remember every creature the cursor touches. Looting is done by right-clicking the corpse, so a
-- moment before LOOT_OPENED this fires with the corpse itself: that is where the name and level of a
-- group kill come from, since by the time the loot panel is up there is no unit under the cursor.
function H.UPDATE_MOUSEOVER_UNIT()
	mouseoverEvents = mouseoverEvents + 1
	-- No GUID and no creature id: both come back secret for these custom creatures, and comparing a
	-- secret throws. So this keeps a short history of *what* was under the cursor and matches the loot
	-- by id when one is readable, or simply by "the last creature the cursor touched" when it is not.
	local name = plainString(select(2, pcall(UnitName, "mouseover")))
	local o2, v2 = pcall(UnitLevel, "mouseover")
	local level = (o2 and type(v2) == "number" and not isSecret(v2) and v2 > 0) and v2 or nil
	if not name or not level then
		local tName, tLevel = tooltipUnit("mouseover", not name, not level)
		name = name or tName
		level = level or tLevel
	end
	if not name then return end
	local id = ns.UnitIdentity("mouseover")
	lastMouseover = { id = id, name = name, level = level, at = (GetTime and GetTime()) or 0 }
	mouseoverHistory[#mouseoverHistory + 1] = lastMouseover
	while #mouseoverHistory > 6 do table.remove(mouseoverHistory, 1) end
end

-- A creature can enter the dex with nothing but its id: in a group you loot corpses of mobs that were
-- never your target, so the loot source gives the id and no name, level or type. The corpse under the
-- cursor is the one chance to name it — mouseover first (that is the corpse you are looting), then the
-- current target. Bumping seen here is honest: you are looking at it.
function enrichFromLive(id, sourceGUID)
	local want = tostring(id)
	local e = ns.Entry(id)
	if not e then return false, "sin entrada" end

	local function apply(name, level, ctype, class, source)
		if not name then return false end
		ns.Touch(id, { name = name, level = level, creatureType = ctype, classification = class })
		e.enrichedFrom = source
		return true, source
	end

	local tried = {}
	-- 0. the offline name table first: no unit, no cursor, no client cooperation needed. This is the
	-- path that should carry almost every custom creature.
	local tName, tLevel, tType = ns.NameFromTable(want)
	if apply(tName, tLevel, tType, nil, "tabla") then return true, "tabla" end
	-- 1. a live unit: the corpse under the cursor, the one we interact with, or the target
	for _, token in ipairs({ "mouseover", "npc", "target" }) do
		local ok, exists = pcall(UnitExists, token)
		if ok and exists then
			local uid, name, level, ctype, class = ns.UnitIdentityRich(token)
			if uid then
				tried[#tried + 1] = token .. "=" .. tostring(uid)
				if uid == want then
					if apply(name, level, ctype, class, token) then return true, token end
				end
			end
		end
	end

	local now = (GetTime and GetTime()) or 0
	-- 2. the cursor memory. No GUID is involved (it is secret and cannot be compared): the newest
	-- recent entry wins, and any recent entry whose readable id matches the loot id wins over it.
	local pick, how
	for k = #mouseoverHistory, 1, -1 do
		local h = mouseoverHistory[k]
		if (now - (h.at or 0)) <= 20 then
			if h.id and h.id == want then
				pick, how = h, "memoria del cursor"
				break
			end
			if not pick then pick, how = h, "memoria reciente" end
		end
	end
	if pick then
		if apply(pick.name, pick.level, nil, nil, how) then return true, how end
		tried[#tried + 1] = "memoria sin nombre"
	else
		tried[#tried + 1] = "sin memoria"
	end
	-- 3. the last mob this character killed, if it is the same one
	if lastKilled and lastKilled.id == want and (now - (lastKilled.at or 0)) <= 30 then
		if apply(lastKilled.name, lastKilled.level, nil, nil, "ultima kill") then return true, "ultima kill" end
	end

	e.enrichTried = (e.enrichTried or 0) + 1
	e.enrichLast = table.concat(tried, " ")
	return false, (e.enrichLast ~= "" and e.enrichLast) or "sin unidad"
end
ns.EnrichFromLive = enrichFromLive

-- What the naming machinery has actually seen, for the trace line and the diagnostic window.
-- Composed label by label: a format string with % cannot travel through the phrase table.
-- What the client actually gives us for the current target. Read-only, one line, so a screenshot of
-- the chat is enough: levels of the custom Forever creatures are reported as missing by every source
-- we have, and this is how we tell "the client hides it" from "we ask wrong".
function ns.LevelProbe()
	local token = "target"
	local out = {}
	local okE, exists = pcall(UnitExists, token)
	out[#out + 1] = "existe=" .. tostring(okE and exists)
	local okL, lv = pcall(UnitLevel, token)
	out[#out + 1] = "UnitLevel=" .. (okL and (isSecret(lv) and "SECRETO" or tostring(lv)) or "error")
	local okN, nm = pcall(UnitName, token)
	out[#out + 1] = "UnitName=" .. (okN and (isSecret(nm) and "SECRETO" or tostring(nm)) or "error")
	pcall(function()
		GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
		GameTooltip:SetUnit(token)
	end)
	for k = 1, 3 do
		local fs = _G["GameTooltipTextLeft" .. k]
		local txt = "-"
		if fs and fs.GetText then
			local okT, t = pcall(fs.GetText, fs)
			txt = okT and (isSecret(t) and "SECRETO" or tostring(t)) or "error"
		end
		out[#out + 1] = "L" .. k .. "=" .. txt
	end
	pcall(function() GameTooltip:Hide() end)
	print("|cff33ff99GarchaDex|r " .. table.concat(out, " · "))
end

function ns.EnrichDebug()
	local parts = { ns.T("cursor") .. ": " .. (mouseoverEvents or 0) .. " " .. ns.T("eventos") }
	local h = mouseoverHistory[#mouseoverHistory]
	if h then
		parts[#parts + 1] = ns.T("ultimo") .. " " .. tostring(h.name) .. " (" .. tostring(h.level or "?") .. ")"
	else
		parts[#parts + 1] = ns.T("sin memoria")
	end
	return table.concat(parts, " · ")
end

function H.LOOT_OPENED(self, ...)
	local ok, err = pcall(onLootOpened)
	if not ok and ns.ReportError then ns.ReportError("loot/opened", err) end
end

function H.LOOT_CLOSED()
	local ok, err = pcall(onLootClosed)
	if not ok and ns.ReportError then ns.ReportError("loot/closed", err) end
end

function H.BOSS_KILL(_, name)
	ns.SetBoss(name)
end

function H.ENCOUNTER_START(_, _id, name)
	ns.SetBoss(name)
end

-- Deaths: with no combat log, whoever we were fighting is the honest attribution.
-- The counter lives in the shared DB, so it accumulates account-wide.
local function creditDeath()
	local id
	if watching then id = watching.id
	elseif lastKilled then id = lastKilled.id
	else id = ns.UnitIdentity("target") end
	if not id then return end
	local e = ns.Entry(id)
	if not e then return end
	local firstDeath = (e.deaths or 0) == 0
	e.deaths = (e.deaths or 0) + 1
	e.lastDeath = time and time() or nil
	local ck = ns.CharKey()
	local c = ns.DB().chars[ck]
	if c then c.deaths = (c.deaths or 0) + 1 end
	ns.OnCapture("death", e, "attributed to the mob you were fighting")
	if firstDeath and ns.Discovery then
		ns.Discovery.Creature("first_death", id, "te mato por primera vez")
	end
end

function H.PLAYER_DEAD()
	pcall(creditDeath)
end

local registered = false
function ns.RegisterCapture(container)
	if registered then return end
	registered = true
	for ev in pairs(CAST_EVENTS) do
		pcall(function() container:RegisterUnitEvent(ev, "target") end)
	end
	for _, ev in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "LOOT_OPENED", "LOOT_CLOSED", "BOSS_KILL", "ENCOUNTER_START", "PLAYER_DEAD" }) do
		pcall(function() container:RegisterEvent(ev) end)
	end
	-- Every handler in this file has to be dispatched explicitly: registering an event on the
	-- frame does nothing by itself (that was the bug that kept lobbing loot on the floor), and
	-- the frame's own OnEvent belongs to Core.
	for _, h in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "LOOT_OPENED", "LOOT_CLOSED", "BOSS_KILL", "ENCOUNTER_START", "PLAYER_DEAD" }) do
		local fn = H[h]
		if fn then
			container:HookScript("OnEvent", function(_, event, ...)
				if event == h then
					local ok, err = pcall(fn, event, ...)
					if not ok and ns.ReportError then ns.ReportError("capture/" .. h, err) end
				end
			end)
		end
	end
	for ev in pairs(CAST_EVENTS) do
		container:HookScript("OnEvent", function(_, event, unit, _castGUID, spellID)
			if event == ev then
				local ok, err = pcall(ns.OnCast, event, unit, spellID, isSecret(spellID))
				if not ok and ns.ReportError then ns.ReportError("cast/" .. tostring(event), err) end
			end
		end)
	end
end
