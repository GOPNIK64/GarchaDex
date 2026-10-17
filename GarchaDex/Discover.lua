-- GarchaDex / Discover.lua
-- The bestiary voice: every time the dex learns something new it says so, in a toast that drops
-- from the top of the screen and can be clicked to open that creature's card.
--
-- Discoveries are detected where the state actually changes (a new entry, the first kill, the
-- first death, the first loot, a drop that was not in the pool before, the first cast), never by
-- polling: a notification must mean a real transition, not a repaint.

local addonName, ns = ...

local S = ns.Skin

local D = {}
ns.Discovery = D

local MAX_TOASTS = 4
local WIDTH = 400           -- starting width (each toast then hugs its own content)
local HEIGHT = 42           -- short: a wide, thin plate reads better than a tall card
local GAP = 6
local HOLD = 6.5            -- seconds a toast stays up
local FADE = 0.35
local TOP_OFFSET = 26       -- px from the top edge for the first toast: kills and loot share the stack
local LOG_MAX = 60

local toasts, queue, live = {}, {}, 0

local KIND = {
	new_enemy   = { head = "nueva entrada",     icon = "Interface\\Icons\\INV_Misc_Book_09" },
	first_kill  = { head = "primer abatido",    icon = "Interface\\Icons\\INV_Sword_04" },
	first_death = { head = "te mato",           icon = "Interface\\Icons\\Ability_Warrior_EndlessRage" },
	new_drop    = { head = "nuevo drop",        icon = "Interface\\Icons\\INV_Misc_QuestionMark" },
	first_cast  = { head = "castea",            icon = "Interface\\Icons\\Spell_Holy_MagicalSentry" },
	pool_done   = { head = "entrada completa",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
}

-- ------------------------------------------------------------------ log (saved, for the News window)

local function remember(rec)
	local db = ns.DB()
	if not db then return end
	db.meta.discoveries = db.meta.discoveries or {}
	table.insert(db.meta.discoveries, rec)
	while #db.meta.discoveries > LOG_MAX do table.remove(db.meta.discoveries, 1) end
end

function ns.DiscoveryText()
	local db = ns.DB()
	local lines = { ns.T("novedades del bestiario:") .. "\n" }
	local log = (db and db.meta.discoveries) or {}
	for i = #log, 1, -1 do
		local r = log[i]
		lines[#lines + 1] = ("  %2d. [%s] %s — %s"):format(#log - i + 1, ns.T(KIND[r.kind] and KIND[r.kind].head or r.kind),
			ns.T(r.name or "?"), ns.T(r.detail or ""))
	end
	if #log == 0 then lines[#lines + 1] = "  " .. ns.T("todavia no descubriste nada") end
	return table.concat(lines, "\n")
end

-- ------------------------------------------------------------------ the toast

local function toastY(index)
	-- how far below the TOP edge this slot sits: measured from the edge, so the first toast is
	-- always TOP_OFFSET px from the top of the screen whatever the UI scale does
	return -(TOP_OFFSET + (index - 1) * (HEIGHT + GAP))
end

local function newToast(index)
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetSize(WIDTH, HEIGHT)
	-- anchored by its TOP edge with x = 0: that is centred on screen, and the y is a plain distance
	-- from the top edge instead of arithmetic around the centre
	f:SetPoint("TOP", UIParent, "TOP", 0, toastY(index))
	f.slot = index
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	local bg = S.tex(f, 0.06, 0.04, 0.03, 0.99, "BACKGROUND")
	bg:SetAllPoints(f)
	f.bg = bg
	S.Trim(f)
	local hl = S.tex(f, S.C.accent[1], S.C.accent[2], S.C.accent[3], 0.10, "HIGHLIGHT")
	hl:SetAllPoints(f)

	-- the creature itself, in 3d, like a bestiary plate: the model replaces the flat icon
	local model = CreateFrame("PlayerModel", nil, f)
	if not model then model = CreateFrame("Model", nil, f) end
	model:SetSize(32, 32)
	model:SetPoint("LEFT", 5, 0)
	model:Hide()
	f.model = model

	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetSize(30, 30)
	icon:SetPoint("LEFT", 6, 0)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	f.icon = icon

	local head = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	head:SetPoint("TOPLEFT", 44, -3)
	head:SetTextColor(S.C.gold[1], S.C.gold[2], S.C.gold[3])
	f.head = head
	local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	name:SetPoint("TOPLEFT", 44, -15)
	name:SetWidth(WIDTH - 52)
	name:SetJustifyH("LEFT")
	f.name = name
	local detail = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detail:SetPoint("TOPLEFT", 44, -27)
	detail:SetWidth(WIDTH - 52)
	detail:SetJustifyH("LEFT")
	f.detail = detail

	f:SetScript("OnEnter", function(self)
		self.bg:SetColorTexture(0.11, 0.08, 0.05, 0.99)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.name:GetText() or "?", 1, 1, 1)
		GameTooltip:AddLine(ns.T("click para abrir la ficha"), 0.6, 0.75, 1)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function(self)
		self.bg:SetColorTexture(0.06, 0.04, 0.03, 0.99)
		GameTooltip:Hide()
	end)
	f:SetScript("OnMouseUp", function(self)
		if self.npcID and ns.UI then ns.UI.Show(self.npcID) end
		self.age = HOLD + FADE
	end)
	f:SetScript("OnUpdate", function(self, elapsed)
		self.age = (self.age or 0) + elapsed
		if self.age < FADE then
			self:SetAlpha(self.age / FADE)
		elseif self.age > HOLD then
			local left = 1 - (self.age - HOLD) / FADE
			if left <= 0 then
				D.Release(self)
			else
				self:SetAlpha(left)
			end
		end
	end)
	return f
end

local function paint(f, rec)
	local kind = KIND[rec.kind] or {}
	f.npcID = rec.id
	f.kind = rec.kind
	f.baseDetail = rec.detail
	f.count = 1
	-- keep every toast centred, whatever the UI scale did since the frame was created
	f:ClearAllPoints()
	f:SetPoint("TOP", UIParent, "TOP", 0, toastY(f.slot or 1))
	f.head:SetText("|cff3fd15a" .. ns.T(kind.head or rec.kind) .. "|r")
	f.name:SetText(rec.name or ("npc " .. tostring(rec.id)))
	f.detail:SetText(ns.T(rec.detail or ""))
	-- Hug the content. A fixed-width box with left-aligned text inside reads as shifted to the left
	-- on screen, because the empty strip on the right is part of what the eye measures.
	f.name:SetWidth(0)     -- 0 = unconstrained, so the string measures on one line
	f.detail:SetWidth(0)
	local w = math.max(f.head:GetStringWidth() or 0, f.name:GetStringWidth() or 0, f.detail:GetStringWidth() or 0)
	local boxW = math.max(300, math.min(560, math.ceil(w) + 70))
	f:SetWidth(boxW)
	f.name:SetWidth(boxW - 52)
	f.detail:SetWidth(boxW - 52)
	-- a creature discovery shows the creature: its 3d model when the seed knows it, else a portrait
	local drew = false
	if rec.creature and rec.displayID and f.model then
		local mid = tonumber(rec.displayID)
		drew = pcall(function()
			f.model:SetModelByCreatureDisplayID(mid)
			f.model:SetPortraitZoom(1)
			f.model:SetCamDistanceScale(0.9)
			f.model:SetRotation(0.6)
			f.model:Show()
		end)
	end
	if drew then
		f.icon:Hide()
	else
		if f.model then f.model:Hide() end
		f.icon:Show()
		local okTex = rec.icon and pcall(function() f.icon:SetTexture(rec.icon) end)
		if not okTex then pcall(function() f.icon:SetTexture(kind.icon) end) end
		if rec.creature and rec.isTarget then pcall(SetPortraitTexture, f.icon, "target") end
	end
	f.age = 0
	f:SetAlpha(0)
	f:Show()
end

function D.Release(f)
	f:Hide()
	live = math.max(0, live - 1)
	D.Pump()
end

function D.Pump()
	while queue[1] and live < MAX_TOASTS do
		local rec = table.remove(queue, 1)
		live = live + 1
		local f = toasts[live]
		if not f then
			f = newToast(live)
			toasts[live] = f
		end
		paint(f, rec)
	end
end

-- Same discovery twice in a row (two identical drops from the same corpse) is one event with a
-- count, not two toasts: the queue is checked before a new entry is queued.
local function mergeable(rec)
	for i = 1, #queue do
		local q = queue[i]
		if q.kind == rec.kind and q.id == rec.id and q.name == rec.name and q.detail == rec.detail then
			q.count = (q.count or 1) + 1
			q.detail = ("%s  x%d"):format(q.detail, q.count)
			return true
		end
	end
	for i = 1, #toasts do
		local f = toasts[i]
		if f:IsShown() and f.kind == rec.kind and f.npcID == rec.id and f.baseDetail == rec.detail then
			f.count = (f.count or 1) + 1
			f.detail:SetText(ns.T(("%s  x%d"):format(f.baseDetail, f.count)))
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------------ public API

function D.Push(kind, npcID, name, detail, icon, displayID, creature)
	local rec = {
		t = time and time() or 0,
		kind = kind,
		id = npcID and tostring(npcID) or nil,
		name = name,
		detail = detail or "",
		icon = icon,
		displayID = displayID,
		creature = creature and true or false,
		isTarget = (ns.UnitIdentity and npcID and ns.UnitIdentity("target") == tostring(npcID)) or false,
	}
	remember(rec)
	if mergeable(rec) then return end
	if #queue > 40 then table.remove(queue, 1) end
	queue[#queue + 1] = rec
	D.Pump()
end

local function nameFor(npcID, entry)
	return (entry and entry.name) or (ns.SeedNpc(npcID) and string.match(ns.SeedNpc(npcID), "^[^|]+")) or ("npc " .. tostring(npcID))
end

function D.Creature(kind, npcID, detail)
	if not npcID then return end
	local e = ns.Entry and ns.Entry(npcID)
	-- the display id of the creature, straight out of the seed: it is what the 3d model needs
	local displayID
	local meta = ns.SeedNpc(npcID)
	if meta then
		local f = {}
		for part in string.gmatch(meta, "[^|]+") do f[#f + 1] = part end
		displayID = tonumber(f[6])
	end
	D.Push(kind, npcID, nameFor(npcID, e), detail, nil, displayID, true)
end

function D.Drop(npcID, itemID, itemName, chance, discovered, total)
	local detail
	if chance then
		detail = ("%.2f%% %s · %d/%s %s"):format(chance, ns.T("en la base 1.12"),
			discovered or 0, total and tostring(total) or "?", ns.T("descubiertos"))
	else
		detail = ("%d/%s %s"):format(discovered or 0, total and tostring(total) or "?", ns.T("descubiertos"))
	end
	local ic
	if C_Item and C_Item.GetItemIconByID and itemID then
		local ok, v = pcall(C_Item.GetItemIconByID, tonumber(itemID))
		if ok then ic = v end
	end
	D.Push("new_drop", npcID, itemName, detail, ic)
end
