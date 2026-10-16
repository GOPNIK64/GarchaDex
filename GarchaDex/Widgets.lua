-- GarchaDex / Widgets.lua
-- Floating toolbar (one button per tool, no typing) plus the index and the text windows.
-- Everything here is drawn through Skin.lua, so every window matches the card.

local addonName, ns = ...

local UI = ns.UI
local S = ns.Skin
local C = S.C

local bar, indexFrame, indexRows, indexOffset, indexFilter, indexList, textFrame

local ROW_H = 20
local INDEX_ROWS = 15

local function say(msg) print("|cff33ff99GarchaDex|r " .. ns.T(msg)) end

local function copper(n)
	n = math.floor((n or 0) + 0.5)
	local g, s, c = math.floor(n / 10000), math.floor((n % 10000) / 100), n % 100
	if g > 0 then return ("%dg %ds %dc"):format(g, s, c) end
	if s > 0 then return ("%ds %dc"):format(s, c) end
	return ("%dc"):format(c)
end

-- ------------------------------------------------------------------ copyable text window

function UI.ShowText(title, text)
	if not textFrame then
		textFrame = S.Panel("GarchaDexTextFrame", UIParent, 720, 470, title or "GarchaDex")
		textFrame:SetPoint("CENTER")
		local eb = CreateFrame("EditBox", nil, textFrame)
		eb:SetMultiLine(true)
		eb:SetFontObject("ChatFontNormal")
		eb:SetWidth(678)
		eb:SetHeight(392)
		eb:SetPoint("TOPLEFT", 18, -40)
		eb:SetAutoFocus(false)      -- never grab the keyboard: WASD has to keep working
		eb:SetScript("OnEscapePressed", function(f)
			f:ClearFocus()
			textFrame:Hide()
		end)
		textFrame.edit = eb
		local hint = textFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("BOTTOMLEFT", 18, 12)
		hint:SetText(ns.T("click en el texto · Cmd+A / Cmd+C copia · Esc cierra"))
	end
	textFrame.title:SetText(title or "GarchaDex")
	textFrame.edit:SetText(text or "")
	textFrame.edit:ClearFocus()
	textFrame:Show()
	return textFrame
end

-- ------------------------------------------------------------------ index (every npc found, classic pokedex style)

local function seedImportantList()
	local out = {}
	local seen = ns.DB().seen
	for id, rec in pairs(ns.npc or {}) do
		if not seen[id] then
			local name = string.match(rec, "^[^|]+") or ("npc " .. id)
			out[#out + 1] = { id = id, name = name, visited = false }
		end
	end
	return out
end

local function newIndexRow(i)
	local r = CreateFrame("Button", nil, indexFrame.body)
	r:SetHeight(ROW_H)
	r:SetPoint("TOPLEFT", indexFrame.body, "TOPLEFT", 4, -(i - 1) * ROW_H)
	r:SetPoint("RIGHT", indexFrame.body, "RIGHT", -4, 0)
	local bg = S.tex(r, C.row[1], C.row[2], C.row[3], 0.35, "BACKGROUND")
	bg:SetAllPoints(r)
	local hl = S.tex(r, C.accent[1], C.accent[2], C.accent[3], 0.18, "HIGHLIGHT")
	hl:SetAllPoints(r)
	local text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", 6, 0)
	text:SetJustifyH("LEFT")
	r.text = text
	r:SetScript("OnClick", function(self)
		if self.entry then UI.Show(self.entry.id) end
	end)
	r:SetScript("OnEnter", function(self)
		if self.entry and self.entry.e then
			local e = self.entry.e
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(self.entry.name, C.gold[1], C.gold[2], C.gold[3])
			GameTooltip:AddLine(("id %s · lvl %s · %s"):format(self.entry.id, tostring(e.level or "?"),
				tostring(e.creatureType or "?")), 0.8, 0.8, 0.8)
			GameTooltip:AddLine(("%s %d · kills %d · %s %d · %s"):format(
				ns.T("visto"), e.seen or 0, e.kills or 0, ns.T("looteado"), e.lootWindows or 0,
				copper(e.moneyCopper)), C.green[1], C.green[2], C.green[3])
			GameTooltip:AddLine(ns.T("click para abrir la ficha"), 0.6, 0.75, 1)
			GameTooltip:Show()
		end
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return r
end

local function rebuildIndex()
	local seen = ns.DB().seen
	local filter = string.lower((indexFilter and indexFilter:GetText()) or "")
	local list = {}
	for id, e in pairs(seen) do
		local name = e.name or (ns.npc and ns.npc[id] and string.match(ns.npc[id], "^[^|]+")) or ("npc " .. id)
		list[#list + 1] = { id = id, name = name, visited = true, e = e }
	end
	for _, r in ipairs(seedImportantList()) do list[#list + 1] = r end
	table.sort(list, function(a, b)
		if a.visited ~= b.visited then return a.visited end
		if a.visited and (a.e.seen or 0) ~= (b.e.seen or 0) then return (a.e.seen or 0) > (b.e.seen or 0) end
		return (a.name or "") < (b.name or "")
	end)
	if filter ~= "" then
		local f = {}
		for _, r in ipairs(list) do
			if string.find(string.lower(r.name), filter, 1, true) or string.find(tostring(r.id), filter, 1, true) then
				f[#f + 1] = r
			end
		end
		list = f
	end
	indexList = list
	local visited = 0
	for _, r in ipairs(list) do
		if r.visited then visited = visited + 1 end
	end
	if indexOffset > #list then indexOffset = math.max(0, #list - INDEX_ROWS) end
	for i = 1, INDEX_ROWS do
		local row, item = indexRows[i], list[indexOffset + i]
		if item then
			row:Show()
			row.entry = item
			local e = item.e
			if item.visited then
				local deaths = (e.deaths or 0) > 0 and ("   |cffff5c55" .. e.deaths .. "|r") or ""
				row.text:SetText(("|cffffd200%s|r  |cff707070id %s · lvl %s|r    %s %d · kills %d · %s %d%s"):format(
					item.name:sub(1, 26), item.id, tostring(e.level or "?"),
					ns.T("visto"), e.seen or 0, e.kills or 0, ns.T("looteado"), e.lootWindows or 0, deaths))
			else
				local meta = ns.SeedNpc(item.id)
				local lvl = (meta and string.match(meta, "^[^|]*|([^|]*)")) or "?"
				row.text:SetText(("|cff5a5a5a%s  id %s · lvl %s · %s|r"):format(
					item.name:sub(1, 26), item.id, tostring(lvl), ns.T("sin visitar")))
			end
		else
			row:Hide()
			row.entry = nil
		end
	end
	indexFrame.title:SetText(("|cff3fd15aGarchaDex|r  |cff808080%s|r · %d (%d %s)"):format(
		ns.T("Indice"), #list, visited, ns.T("con datos")))
end
UI.RebuildIndex = rebuildIndex

function UI.ShowIndex()
	if not indexFrame then
		indexFrame = S.Panel("GarchaDexIndex", UIParent, 640, 440, "GarchaDex")
		indexFrame:SetPoint("CENTER")
		indexFilter = CreateFrame("EditBox", nil, indexFrame)
		indexFilter:SetSize(180, 20)
		indexFilter:SetPoint("TOPLEFT", 16, -40)
		indexFilter:SetAutoFocus(false)
		indexFilter:SetFontObject("ChatFontNormal")
		indexFilter:SetScript("OnTextChanged", function()
			indexOffset = 0
			rebuildIndex()
		end)
		indexFilter:SetScript("OnEscapePressed", function(f)
			f:ClearFocus()
			indexFrame:Hide()
		end)
		local hint = indexFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("LEFT", indexFilter, "RIGHT", 8, 0)
		hint:SetText(ns.T("filtro por nombre o id · rueda del mouse para scrollear"))

		local body = CreateFrame("Frame", nil, indexFrame)
		body:SetPoint("TOPLEFT", 12, -68)
		body:SetPoint("BOTTOMRIGHT", -12, 14)
		body:EnableMouseWheel(true)
		indexFrame.body = body
		body:SetScript("OnMouseWheel", function(_, delta)
			if not indexList then return end
			indexOffset = math.max(0, math.min(math.max(0, #indexList - INDEX_ROWS), indexOffset - delta))
			rebuildIndex()
		end)
		indexRows = {}
		for i = 1, INDEX_ROWS do indexRows[i] = newIndexRow(i) end
		indexFrame:SetScript("OnShow", function() rebuildIndex() end)
	end
	indexOffset = indexOffset or 0
	indexFrame:Show()
	rebuildIndex()
end

-- ------------------------------------------------------------------ floating toolbar

local function saveBarPos()
	local p, _, rp, x, y = bar:GetPoint(1)
	ns.DB().meta.barPos = { p = p, rp = rp, x = x, y = y }
end

local function restoreBarPos()
	local pos = ns.DB().meta.barPos
	if pos and pos.p then
		bar:ClearAllPoints()
		bar:SetPoint(pos.p, UIParent, pos.rp or pos.p, pos.x or 0, pos.y or 0)
	end
end

local function addBarButton(label, tip, onClick)
	local b = S.Button(bar, label, 30, 30, tip, onClick)
	local n = (bar.buttons or 0)
	b:SetPoint("LEFT", bar, "LEFT", 4 + n * 33, 0)
	bar.buttons = n + 1
	return b
end

local function relayoutOpenWindows()
	if UI.frameInstance and UI.frameInstance:IsShown() and UI.currentID then
		UI.Show(UI.currentID)
	end
	if indexFrame and indexFrame:IsShown() then rebuildIndex() end
end

function UI.BuildBar()
	if bar then
		bar:Show()
		return bar
	end
	bar = CreateFrame("Frame", "GarchaDexBar", UIParent)
	bar:SetSize(4 + 8 * 33 + 4, 38)
	bar:SetPoint("LEFT", UIParent, "LEFT", 40, 120)
	bar:SetMovable(true)
	bar:EnableMouse(true)
	bar:SetClampedToScreen(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function(f) f:StartMoving() end)
	bar:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		pcall(saveBarPos)
	end)
	local bg = S.tex(bar, 0, 0, 0, 0.55, "BACKGROUND")
	bg:SetAllPoints(bar)
	S.Border(bar, C.border)
	restoreBarPos()

	addBarButton("Ficha", "ficha del enemigo targeteado", function()
		if UI.Show then UI.Show() end
	end)
	addBarButton("Indice", "todos los npcs encontrados, por id", function() UI.ShowIndex() end)
	addBarButton("Loot", "ultimos looteos vistos (diagnostico)", function()
		UI.ShowText("GarchaDex · loot", ns.LootText and ns.LootText() or "")
	end)
	addBarButton("Seed", "estado del seed y chequeo crudo", function()
		UI.ShowText("GarchaDex · seed", ns.SeedText and ns.SeedText() or "")
	end)
	addBarButton("Stats", "contadores generales", function()
		UI.ShowText("GarchaDex · stats", ns.StatsText and ns.StatsText() or "")
	end)
	addBarButton("Test", "render de valores secretos", function()
		if ns.RunSecretTest then ns.RunSecretTest() end
	end)
	addBarButton(ns.LANG == "en" and "ES" or "EN", "cambiar idioma del addon", function(self)
		local nxt = (ns.LANG == "en") and "es" or "en"
		ns.SetLang(nxt)
		ns.DB().meta.lang = nxt
		self.fs:SetText(nxt == "en" and "ES" or "EN")
		relayoutOpenWindows()
		say("idioma: " .. ns.LANG)
	end)
	addBarButton("X", "cerrar todas las ventanas de GarchaDex", function()
		if UI.frameInstance then UI.frameInstance:Hide() end
		if indexFrame then indexFrame:Hide() end
		if textFrame then textFrame:Hide() end
	end)
	bar:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then bar:Hide() end
	end)
	local handle = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	handle:SetPoint("BOTTOM", bar, "BOTTOM", 0, -13)
	handle:SetText(ns.T("arrastrable · click derecho oculta"))
	return bar
end
