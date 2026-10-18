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
local HOLD = 3.4            -- seconds a toast stays up
local FADE = 0.22
local SLIDE = 0.12          -- seconds a toast takes to rise into its new slot
local TOP_OFFSET = 26       -- px from the top edge for the first toast: kills and loot share the stack
local LOG_MAX = 60

local toasts, queue, live = {}, {}, 0
local pool = {}              -- frames free to reuse: a toast that leaves hands its frame back
-- forward declared: the OnUpdate inside newToast calls them, and they are defined further down
local slideTo, relayout, leaveStack

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

-- Where the player parked the stack. The toasts are anchored TOP with an x offset plus a lift on the
-- y, both saved account-wide; 0/0 is the default that centres them under the top edge.
local GRID = 16
local editMode, gridFrame, preview

local function db()
	return ns.DB() and ns.DB().meta or {}
end

function ns.ToastAnchor()
	local m = db()
	return m.toastX or 0, m.toastY or 0
end

local function snap(v)
	return math.floor(v / GRID + 0.5) * GRID
end

local function place(f, index)
	local dx, dy = ns.ToastAnchor()
	f:SetPoint("TOP", UIParent, "TOP", dx, toastY(index) + dy)
end

-- A faint grid, the way the client's own layout editor shows one. Coarser than the snap step so it
-- guides the eye without becoming a mesh of lines.
local function grid()
	if gridFrame then return gridFrame end
	local g = CreateFrame("Frame", nil, UIParent)
	g:SetAllPoints(UIParent)
	g:SetFrameStrata("BACKGROUND")
	g:Hide()
	local w, h = UIParent:GetWidth(), UIParent:GetHeight()
	for x = 0, w, 64 do
		local t = g:CreateTexture(nil, "ARTWORK")
		t:SetColorTexture(1, 0.82, 0.2, 0.05)
		t:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, 0)
		t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, 0)
		t:SetWidth(1)
	end
	for y = 0, h, 64 do
		local t = g:CreateTexture(nil, "ARTWORK")
		t:SetColorTexture(1, 0.82, 0.2, 0.05)
		t:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -y)
		t:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, -y)
		t:SetHeight(1)
	end
	local hint = g:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hint:SetPoint("TOP", UIParent, "TOP", 0, -6)
	hint:SetTextColor(1, 0.82, 0)
	hint:SetText(ns.T("arrastra la notificacion: se pega a la grilla"))
	g.hint = hint
	gridFrame = g
	return g
end

-- Move mode: a preview toast you can drag. The drag is snapped on release, and the position is saved
-- so every later toast drops there.
function ns.ToastEdit(on)
	on = (on ~= nil) and on or (not editMode)
	editMode = on
	local g = grid()
	g:SetShown(editMode)
	if not editMode then
		if preview then preview:Hide() end
		return
	end
	if not preview then
		preview = CreateFrame("Frame", "GarchaDexToastPreview", UIParent)
		preview:SetSize(WIDTH, HEIGHT)
		preview:SetFrameStrata("DIALOG")
		preview:EnableMouse(true)
		preview:SetMovable(true)
		preview:SetClampedToScreen(true)
		preview:RegisterForDrag("LeftButton")
		local bg = S.tex(preview, 0.06, 0.04, 0.03, 0.95, "BACKGROUND")
		bg:SetAllPoints(preview)
		S.Trim(preview)
		local t = preview:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("CENTER", 0, 0)
		t:SetTextColor(1, 0.82, 0)
		t:SetText(ns.T("arrastrame"))
		preview.text = t
		preview:SetScript("OnDragStart", function(self)
			self:StartMoving()
			self.dragging = true
		end)
		preview:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			self.dragging = false
			local left = self:GetLeft() or 0
			local top = self:GetTop() or 0
			local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
			local dx2 = snap(left + self:GetWidth() / 2 - uiW / 2)
			local dy2 = snap((top - uiH) - toastY(1))
			local m = db()
			m.toastX, m.toastY = dx2, dy2
			for _, f in ipairs(toasts) do place(f, f.slot or 1) end
			self:ClearAllPoints()
			place(self, 1)
			print(("|cff33ff99GarchaDex|r %s x=%d y=%d"):format(ns.T("notificaciones en:"), dx2, dy2))
		end)
	end
	preview:ClearAllPoints()
	place(preview, 1)
	preview:Show()
end

function ns.ToastReset()
	local m = db()
	m.toastX, m.toastY = 0, 0
	for _, f in ipairs(toasts) do place(f, f.slot or 1) end
	if preview then preview:ClearAllPoints(); place(preview, 1) end
	print("|cff33ff99GarchaDex|r " .. ns.T("notificaciones al centro"))
end

local function newToast(index)
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetSize(WIDTH, HEIGHT)
	-- anchored by its TOP edge: x and y come from the saved anchor, so the whole stack follows where
	-- the player parked it in move mode
	place(f, index)
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
		if self.sliding then
			self.slideT = (self.slideT or 0) + elapsed
			local k = math.min(1, self.slideT / SLIDE)
			local dx = ns.ToastAnchor()
			self:SetPoint("TOP", UIParent, "TOP", dx, self.fromY + (self.toY - self.fromY) * k)
			if k >= 1 then self.sliding = false end
		end
		self.age = (self.age or 0) + elapsed
		if self.age < FADE then
			self:SetAlpha(self.age / FADE)
		elseif self.age > HOLD then
			if not self.leaving then
				self.leaving = true
				-- out of the stack at once: the ones below rise while this one fades out in place
				leaveStack(self)
				D.Pump()
			end
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
	place(f, f.slot or 1)
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

-- Rise animation: a toast that changes slot glides up instead of snapping, and it does it in SLIDE
-- seconds — the stack has to close the gap fast, or the eye reads the empty slot as a lost toast.
slideTo = function(f, index)
	local dx, dy = ns.ToastAnchor()
	f.slot = index
	if not f.toY then f.toY = toastY(index) + dy end
	f.fromY = f.toY
	f.toY = toastY(index) + dy
	f.slideT = 0
	if math.abs(f.fromY - f.toY) < 0.5 then
		f.sliding = false
		f:ClearAllPoints()
		f:SetPoint("TOP", UIParent, "TOP", dx, f.toY)
	else
		f.sliding = true
	end
end

-- every visible toast recomputes its slot after one leaves or joins
relayout = function()
	for i, f in ipairs(toasts) do slideTo(f, i) end
end

-- drop a frame from the stack right away, so the rest rises while it fades out in place
leaveStack = function(f)
	for i = #toasts, 1, -1 do
		if toasts[i] == f then table.remove(toasts, i) end
	end
	relayout()
end

function D.Release(f)
	f:Hide()
	f:SetAlpha(1)
	f.sliding = false
	f.toY = nil
	f.leaving = false
	leaveStack(f)
	pool[#pool + 1] = f
	D.Pump()
end

function D.Pump()
	while queue[1] and #toasts < MAX_TOASTS do
		local rec = table.remove(queue, 1)
		local f = table.remove(pool)
		if not f then f = newToast(1) end
		toasts[#toasts + 1] = f
		f.toY = nil
		f.sliding = false
		f.leaving = false
		f.slot = #toasts
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
