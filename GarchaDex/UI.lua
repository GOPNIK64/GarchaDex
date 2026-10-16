-- GarchaDex / UI.lua
-- One self-contained window, shaped like a pokedex: the index of every creature you have found
-- on the left, the card of the selected one on the right, and the spine between them.
-- Nothing is stacked: selecting a row repaints the right pane in place.
--
-- Drops show only what the player has actually looted from this creature, with the static 1.12
-- chance beside it: the point is completing the dex, not reading raw capture data. The rest of
-- the pool stays hidden until it drops.
--
-- Secret values (measured on build 70425): the spell name and icon a mob casts can be STORED
-- and DRAWN, but never compared, printed or used as a key. So the spell list shows the
-- reference (readable ids) and the observed casts as drawn rows, with no dedupe between them.

local addonName, ns = ...

local UI = {}
ns.UI = UI

local S = ns.Skin
local C = S.C

local frame, rows, body
local listRows, listFilter, listOffset, listCache, listCount
local currentID

local ROW_H = 18
local LIST_ROW_H = 30
local LIST_ROWS = 15
local LIST_W = 250
local PANE_X = 274          -- 10 margin + list + the spine gap: the window reads symmetric
local PANE_W = 556
local WIN_W = PANE_X + PANE_W + 10
local WIN_H = 560            -- fixed: the panes scroll instead of the window resizing
local PANE_H = WIN_H - 60
local MAX_ROWS = 200
-- the client's own question-mark icon: an undiscovered slot in the dex
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- ------------------------------------------------------------------ lookups

local function itemName(id)
	if C_Item and C_Item.GetItemNameByID then
		local ok, v = pcall(C_Item.GetItemNameByID, tonumber(id))
		if ok and type(v) == "string" and v ~= "" then return v end
	end
	return "item " .. tostring(id)
end

local function itemIcon(id)
	if C_Item and C_Item.GetItemIconByID then
		local ok, v = pcall(C_Item.GetItemIconByID, tonumber(id))
		if ok and v ~= nil then return v end
	end
	return nil
end

local function spellInfo(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, tonumber(id))
		if ok and type(info) == "table" then return info.name, info.iconID end
	end
	return nil, nil
end

local function seedMeta(id)
	local s = ns.SeedNpc(id)
	if not s then return nil end
	local f = {}
	for part in string.gmatch(s, "[^|]+") do f[#f + 1] = part end
	return { name = f[1], minLevel = f[2], maxLevel = f[3], rank = f[4], ctype = f[5], model = f[6], map = f[7] }
end

local RANK = { ["0"] = "normal", ["1"] = "elite", ["2"] = "elite raro", ["3"] = "jefe", ["4"] = "raro" }
local CTYPE = { ["1"] = "Bestia", ["2"] = "Dragonkin", ["3"] = "Demonio", ["4"] = "Elemental", ["5"] = "Gigante",
	["6"] = "No-muerto", ["7"] = "Humanoide", ["8"] = "Critter", ["9"] = "Mecanico", ["11"] = "Totem" }

-- ------------------------------------------------------------------ left pane: the index of what you found

local function newListRow(i)
	local r = CreateFrame("Button", nil, frame.listPane)
	r:SetHeight(LIST_ROW_H)
	r:SetPoint("TOPLEFT", frame.listPane, "TOPLEFT", 6, -(i - 1) * LIST_ROW_H - 26)
	r:SetPoint("RIGHT", frame.listPane, "RIGHT", -6, 0)
	local sel = S.tex(r, C.accent[1], C.accent[2], C.accent[3], 0.22, "BACKGROUND")
	sel:SetAllPoints(r)
	sel:Hide()
	r.sel = sel
	local hl = S.tex(r, C.accent[1], C.accent[2], C.accent[3], 0.10, "HIGHLIGHT")
	hl:SetAllPoints(r)
	local name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	name:SetPoint("TOPLEFT", 5, -2)
	name:SetJustifyH("LEFT")
	r.name = name
	local info = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	info:SetPoint("TOPLEFT", 5, -16)
	info:SetJustifyH("LEFT")
	r.info = info
	r:SetScript("OnClick", function(self)
		if self.entry then UI.Show(self.entry.id) end
	end)
	r:SetScript("OnEnter", function(self)
		if not self.entry then return end
		local e = self.entry.e or {}
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.entry.name, C.gold[1], C.gold[2], C.gold[3])
		GameTooltip:AddLine(("id %s · lvl %s · %s"):format(self.entry.id, tostring(e.level or "?"),
			tostring(e.creatureType or "?")), 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return r
end

local function rebuildList()
	local seen = ns.DB().seen
	local filter = string.lower((listFilter and listFilter:GetText()) or "")
	local list = {}
	-- the dex is what you FOUND: only creatures you have actually met
	for id, e in pairs(seen) do
		local name = e.name or (ns.npc and ns.npc[id] and string.match(ns.npc[id], "^[^|]+")) or ("npc " .. id)
		list[#list + 1] = { id = id, name = name, e = e }
	end
	table.sort(list, function(a, b)
		if (a.e.seen or 0) ~= (b.e.seen or 0) then return (a.e.seen or 0) > (b.e.seen or 0) end
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
	listCache = list
	listCount = #list
	if listOffset > math.max(0, listCount - LIST_ROWS) then
		listOffset = math.max(0, listCount - LIST_ROWS)
	end
	for i = 1, LIST_ROWS do
		local row, item = listRows[i], list[listOffset + i]
		if item then
			row:Show()
			row.entry = item
			row.sel:SetShown(currentID == tostring(item.id))
			row.name:SetText("|cffffd200" .. item.name:sub(1, 24) .. "|r")
			local e = item.e or {}
			row.info:SetText(("|cff90806a id %s · lvl %s · %s %d|r"):format(
				item.id, tostring(e.level or "?"), ns.T("visto"), e.seen or 0))
		else
			row:Hide()
			row.entry = nil
		end
	end
end
UI.RebuildIndex = rebuildList

-- ------------------------------------------------------------------ right pane: the card rows

local function newRow(index)
	local r = CreateFrame("Button", nil, body.content)
	r:SetHeight(ROW_H)
	r:SetPoint("TOPLEFT", body.content, "TOPLEFT", 0, -(index - 1) * ROW_H)
	r:SetPoint("RIGHT", body.content, "RIGHT", 0, 0)

	local hl = S.tex(r, C.accent[1], C.accent[2], C.accent[3], 0.10, "HIGHLIGHT")
	hl:SetAllPoints(r)
	local bg = S.tex(r, C.row[1], C.row[2], C.row[3], 0, "BACKGROUND")
	bg:SetAllPoints(r)
	r.bg = bg
	local bar = S.tex(r, C.accent[1], C.accent[2], C.accent[3], 0, "BACKGROUND")
	bar:SetPoint("RIGHT", r, "RIGHT", -6, 0)
	bar:SetHeight(ROW_H - 6)
	bar:SetWidth(0)
	r.bar = bar
	local divider = S.tex(r, C.border[1], C.border[2], C.border[3], 0.5, "ARTWORK")
	divider:SetPoint("LEFT", 8, 0)
	divider:SetPoint("RIGHT", -8, 0)
	divider:SetHeight(1)
	r.divider = divider
	local icon = r:CreateTexture(nil, "ARTWORK")
	icon:SetSize(14, 14)
	icon:SetPoint("LEFT", 2, 0)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:Hide()
	r.icon = icon
	local text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", 20, 0)
	text:SetJustifyH("LEFT")
	text:SetHeight(ROW_H)
	r.text = text
	-- a second string: a secret name goes into r.text whole (never through string.format),
	-- because formatting a secret yields a secret that my sanitizer would turn into "<secret>"
	local suffix = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	suffix:SetPoint("RIGHT", r, "RIGHT", -8, 0)
	suffix:SetJustifyH("RIGHT")
	suffix:SetTextColor(0.6, 0.6, 0.6)
	r.suffix = suffix
	r:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local shown = false
		if self.hyperlink then
			shown = pcall(function() GameTooltip:SetHyperlink(self.hyperlink) end) and true or false
		end
		if not shown and self.tooltipText then
			GameTooltip:AddLine(self.tooltipText, 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return r
end

local function attachItem(r, itemID)
	if not (r and itemID) then return end
	if C_Item and C_Item.GetItemLink then
		local ok, link = pcall(C_Item.GetItemLink, tonumber(itemID))
		if ok and type(link) == "string" then r.hyperlink = link end
	end
	r.tooltipText = itemName(itemID)
end

local function attachSpell(r, spellID)
	if not (r and spellID) then return end
	if C_Spell and C_Spell.GetSpellLink then
		local ok, link = pcall(C_Spell.GetSpellLink, tonumber(spellID))
		if ok and type(link) == "string" then r.hyperlink = link end
	end
	local name = spellInfo(spellID)
	r.tooltipText = name or ("spell " .. tostring(spellID))
end

local function prep(i, iconPath, colour, pct, barColour)
	local r = rows[i]
	if not r then
		r = newRow(i)
		rows[i] = r
	end
	r:Show()
	r.hyperlink = nil
	r.tooltipText = nil
	r.bg:SetColorTexture(C.row[1], C.row[2], C.row[3], 0)
	r.divider:Hide()
	if iconPath then
		r.icon:Show()
		local ok = pcall(function() r.icon:SetTexture(iconPath) end)
		if not ok then r.icon:Hide() end
		r.text:SetPoint("LEFT", 20, 0)
	else
		r.icon:Hide()
		r.text:SetPoint("LEFT", 4, 0)
	end
	if pct and pct > 0 then
		local bc = barColour or C.accent
		r.bar:SetColorTexture(bc[1], bc[2], bc[3], 0.14)
		r.bar:SetWidth(math.max(2, math.min(210, pct * 2.2)))
	else
		r.bar:SetWidth(0)
	end
	r.suffix:SetText("")
	if colour then
		r.text:SetTextColor(colour[1], colour[2], colour[3])
	else
		r.text:SetTextColor(1, 0.82, 0)
	end
	return r
end

local function row(i, iconPath, msg, colour, pct, barColour)
	local r = prep(i, iconPath, colour, pct, barColour)
	r.text:SetWidth(0)
	r.text:SetText(ns.T(msg or ""))
	return r
end

local function rowColored(i, iconPath, txt, qualityColour, suffixText, pct)
	local r = prep(i, iconPath, qualityColour, pct)
	r.text:SetWidth(0)
	r.text:SetText(txt or "")
	r.suffix:SetText(suffixText or "")
	return r
end

local function rowSecret(i, iconPath, name, suffixText, colour)
	local r = prep(i, iconPath, colour)
	r.text:SetWidth(300)
	local okText = pcall(function() r.text:SetText(name or "?") end)
	if not okText then r.text:SetText("?") end
	r.suffix:SetText(ns.T(suffixText or ""))
	return r
end

local function section(i, txt, colour)
	local r = prep(i, nil, nil)
	r.text:SetText(ns.T(txt))
	r.text:SetTextColor(colour[1], colour[2], colour[3])
	r.bg:SetColorTexture(C.header[1], C.header[2], C.header[3], 0.75)
	r.divider:Show()
	r.divider:SetPoint("LEFT", r.text, "RIGHT", 10, 0)
	r.divider:SetPoint("RIGHT", -8, 0)
	r.divider:SetHeight(1)
	r.divider:SetColorTexture(colour[1], colour[2], colour[3], 0.25)
	return r
end

local function chip(parent, x, y, label)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(62, 32)
	f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	local bg = S.tex(f, 0.12, 0.08, 0.04, 0.9, "BACKGROUND")
	bg:SetAllPoints(f)
	S.Border(f, C.border)
	local v = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	v:SetPoint("TOP", 0, -4)
	v:SetText("0")
	f.value = v
	local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	l:SetPoint("BOTTOM", 0, 2)
	l:SetText(ns.T(label))
	l:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
	return f
end

-- ------------------------------------------------------------------ render the right pane

local function renderCard(id)
	if not frame then return false end
	id = id and tostring(id) or nil
	if not id and ns.UnitIdentity then id = ns.UnitIdentity("target") end
	if not id then
		-- nothing selected: fall back to the first creature of the index, so the pane is never empty
		rebuildList()
		if listCache and listCache[1] then id = tostring(listCache[1].id) end
	end
	for _, r in pairs(rows) do r:Hide() end
	if not id then
		currentID = nil
		UI.currentID = nil
		frame.name:SetText(ns.T("todavia no encontraste ningun enemigo"))
		frame.sub:SetText(ns.T("targetea algo y va a aparecer en el indice de la izquierda"))
		frame.portrait:Hide()
		frame.portraitFrame:Hide()
		if frame.model then frame.model:Hide() end
		body.content:SetHeight(24)
		body.offset = 0
		body.Update()
		return true
	end
	currentID = id
	UI.currentID = id
	local e = ns.DB().seen[id]
	local meta = seedMeta(id)

	-- header: name, identity and stats
	local live = ns.UnitIdentity and ns.UnitIdentity("target")
	local title = (e and e.name) or (meta and meta.name) or ("npc " .. id)
	frame.name:SetText(title)
	local lvl = "?"
	if e and e.level then lvl = tostring(e.level) end
	if meta then
		lvl = (meta.minLevel == meta.maxLevel) and meta.minLevel or (meta.minLevel .. "-" .. meta.maxLevel)
	end
	-- the client's own words for type and classification (already in the player's language)
	local ctype = (e and e.creatureType) or (meta and (CTYPE[meta.ctype] or meta.ctype)) or nil
	local rank = (e and e.classification) or (meta and (RANK[meta.rank] or meta.rank)) or nil
	if rank == "normal" or rank == "trivial" then rank = nil end
	local bits = { "npc " .. id, "lvl " .. lvl }
	if ctype then bits[#bits + 1] = tostring(ctype) end
	if rank then bits[#bits + 1] = tostring(rank) end
	if e and e.zone then bits[#bits + 1] = e.zone end
	frame.sub:SetText(ns.T(table.concat(bits, " · ")))
	frame.chipSeen.value:SetText(tostring(e and e.seen or 0))
	frame.chipKills.value:SetText(tostring(e and e.kills or 0))
	frame.chipLoot.value:SetText(tostring(e and e.lootWindows or 0))
	frame.chipDeaths.value:SetText(tostring(e and e.deaths or 0))

	-- art: live portrait for a real target, the seed's display id for a known creature
	local drew = false
	if ns.frame and ns.frame.PortraitFor and live == id then
		drew = ns.frame.PortraitFor(frame.portrait, "target")
	end
	if frame.model then frame.model:Hide() end
	if not drew and meta and meta.model and frame.model then
		local mid = tonumber(meta.model)
		local ok = pcall(function()
			frame.model:SetModelByCreatureDisplayID(mid)
			frame.model:SetPortraitZoom(1)
			frame.model:SetCamDistanceScale(0.85)
			frame.model:SetPosition(0, 0, 0)
			frame.model:SetRotation(0.6)
			frame.model:Show()
		end)
		if not ok then
			ok = pcall(function()
				frame.model:SetDisplayInfo(mid)
				frame.model:SetPortraitZoom(1)
				frame.model:Show()
			end)
		end
		drew = ok and true or false
	end
	if frame.model and frame.model:IsShown() then
		frame.portrait:Hide()
		frame.portraitFrame:Show()
	elseif drew then
		frame.portrait:Show()
		frame.portraitFrame:Show()
	else
		-- nothing to draw: hide the box instead of leaving an empty frame
		frame.portrait:Hide()
		frame.portraitFrame:Hide()
	end

	local i = 0
	local function put(iconPath, msg, colour, pct, barColour)
		i = i + 1
		if i > MAX_ROWS then return i end
		row(i, iconPath, msg, colour, pct, barColour)
		return i
	end

	-- identity / provenance
	if meta then
		put(nil, ("base 1.12: lvl %s-%s · %s"):format(
			meta.minLevel, meta.maxLevel, RANK[meta.rank] or meta.rank), C.blue)
	else
		put(nil, "no esta en la base 1.12: contenido de Forever", C.grey)
	end

	-- spells: every slot of the base is listed. One that you have not seen cast stays hidden as "?";
	-- with a single declared spell the id is unambiguous, so it is named once you see a cast.
	i = i + 1; section(i, "HECHIZOS · BASE 1.12", C.gold)
	local spellSlots = {}
	for sid in string.gmatch(ns.SeedSpells(id) or "", "%d+") do spellSlots[#spellSlots + 1] = sid end
	local observed = (e and (e.casts or 0) > 0) or false
	if #spellSlots > 0 then
		for k = 1, #spellSlots do
			local sid = spellSlots[k]
			local rr
			if observed and #spellSlots == 1 then
				local name, icon = spellInfo(sid)
				rr = rowColored(i + k, icon, name or ("spell " .. sid), C.white, "base 1.12", nil)
				attachSpell(rr, tonumber(sid))
			else
				rr = rowColored(i + k, QUESTION_ICON, "?", C.dim, "?", nil)
			end
		end
		i = i + #spellSlots
	else
		put(nil, "(sin hechizos declarados en la base 1.12)", C.dim)
	end
	if e and (e.casts or 0) > 0 then
		i = i + 1; section(i, ("HECHIZOS QUE LE VISTE CASTEAR · %d"):format(e.casts), C.blue)
		local log = e.spellLog or {}
		local shown, named = math.min(#log, 4), 0
		for k = #log - shown + 1, #log do
			local rec = log[k]
			if rec and rec.name ~= nil then named = named + 1 end
		end
		if named == 0 then
			-- every captured cast came back without a name (the client hides it): one line says it
			put(nil, "el cliente no le pone nombre a esos casteos: se ven cuando los dibuja el juego", C.dim)
		else
			for k = #log - shown + 1, #log do
				local rec = log[k]
				if rec and rec.name ~= nil then
					i = i + 1
					if i <= MAX_ROWS then
						rowSecret(i, rec.icon, rec.name, "", C.white)
					end
				end
			end
		end
	end

	-- drops: the whole pool is shown as slots. Looted ones carry their name, the rest stay hidden
	-- behind a "?" with the same static 1.12 chance, so the dex is something you complete.
	local ownSeed, sharedSeed = ns.ParseLoot(ns.SeedLoot(id))
	local n = ns.SeedN(id)
	local got = {}
	for key, rec in pairs((e and e.drops) or {}) do
		local itemID = tonumber(key) or tonumber(rec.id)
		if itemID then got[itemID] = rec end
	end
	local pool, seen = {}, {}
	for itemID, chance in pairs(ownSeed) do
		if not seen[itemID] then
			seen[itemID] = true
			pool[#pool + 1] = { id = itemID, chance = chance }
		end
	end
	for itemID, chance in pairs(sharedSeed) do
		if not seen[itemID] then
			seen[itemID] = true
			pool[#pool + 1] = { id = itemID, chance = chance, shared = true }
		end
	end
	table.sort(pool, function(a, b) return math.abs(a.chance) > math.abs(b.chance) end)
	local inPool = 0
	for k = 1, #pool do
		if got[pool[k].id] then inPool = inPool + 1 end
	end
	i = i + 1
	section(i, ("DROPS · %d/%s %s"):format(inPool, n and tostring(n) or tostring(#pool), ns.T("descubiertos")), C.green)
	if #pool > 0 then
		for k = 1, #pool do
			local slot = pool[k]
			local rec = got[slot.id]
			local refTxt = ("%.2f%%"):format(slot.chance)
			local rr
			if rec then
				-- discovered: the name, in the game's rarity colour
				rr = rowColored(i + k, itemIcon(slot.id),
					(rec.name or itemName(slot.id)):sub(1, 40), S.qualityColor(slot.id), refTxt,
					math.abs(slot.chance))
				attachItem(rr, slot.id)
			else
				-- not yet dropped: a slot with a question mark, but the chance is already known
				rr = rowColored(i + k, QUESTION_ICON, "", C.dim, refTxt, math.abs(slot.chance))
			end
		end
		i = i + #pool
		-- anything looted that the pool does not know about (Forever-only items) is shown too
		local extra = {}
		for itemID, rec in pairs(got) do
			if not seen[itemID] then extra[#extra + 1] = { id = itemID, rec = rec } end
		end
		for k = 1, #extra do
			local rr = rowColored(i + k, itemIcon(extra[k].id),
				(extra[k].rec.name or itemName(extra[k].id)):sub(1, 40), S.qualityColor(extra[k].id),
				ns.T("sin dato 1.12"), nil)
			attachItem(rr, extra[k].id)
		end
		i = i + #extra
	elseif next(got) then
		-- the creature dropped things but the base has no pool for it
		local extra = {}
		for itemID, rec in pairs(got) do extra[#extra + 1] = { id = itemID, rec = rec } end
		table.sort(extra, function(a, b) return (a.id or 0) < (b.id or 0) end)
		for k = 1, #extra do
			local rr = rowColored(i + k, itemIcon(extra[k].id),
				(extra[k].rec.name or itemName(extra[k].id)):sub(1, 40), S.qualityColor(extra[k].id),
				ns.T("sin dato 1.12"), nil)
			attachItem(rr, extra[k].id)
		end
		i = i + #extra
	else
		put(nil, ("todavia no looteaste nada de este mob (%d cadaveres)"):format(e and e.lootWindows or 0), C.dim)
	end

	for k = i + 1, MAX_ROWS do
		if rows[k] then rows[k]:Hide() end
	end

	-- the pane keeps its height and scrolls: the window never resizes under the cursor
	body.content:SetHeight(i * ROW_H + 12)
	body.offset = 0
	body.Update()
	return true
end

-- A card that dies halfway must say why: an error inside the render is reported, not swallowed.
function UI.Show(id)
	if not frame then
		local okC, errC = pcall(UI.Create)
		if not okC or not frame then
			print("|cffff4040GarchaDex|r no pude crear la ventana: " .. ns.tostringSafe(errC))
			return false
		end
	end
	local ok, err = pcall(renderCard, id)
	if not ok then
		print("|cffff4040GarchaDex|r error armando la ficha: " .. ns.tostringSafe(err))
	else
		frame:Show()
		rebuildList()
	end
	return ok
end

-- the toolbar's Index button: same window, the list is what matters
function UI.ShowIndex()
	UI.Show()
	if listFilter then listFilter:ClearFocus() end
	rebuildList()
end

-- ------------------------------------------------------------------ the window: two panes and a spine

function UI.Create()
	frame = S.Panel("GarchaDexFrame", UIParent, WIN_W, WIN_H, "GarchaDex")
	frame:SetPoint("CENTER")
	frame.title:SetText("|cff3fd15aGarchaDex|r |cff808080v" .. tostring(ns.VERSION) .. "|r")
	frame.title:ClearAllPoints()
	frame.title:SetPoint("CENTER", frame.head, "CENTER", 0, 0)

	-- left pane: the index
	local listPane = CreateFrame("Frame", nil, frame)
	listPane:SetPoint("TOPLEFT", 10, -38)
	listPane:SetWidth(LIST_W)
	listPane:SetHeight(PANE_H)
	listPane:EnableMouseWheel(true)
	pcall(function() listPane:SetClipsChildren(true) end)
	frame.listPane = listPane
	local lpbg = S.tex(listPane, C.bgDark[1], C.bgDark[2], C.bgDark[3], 1, "BACKGROUND")
	lpbg:SetAllPoints(listPane)
	S.Border(listPane, C.border)

	listFilter = CreateFrame("EditBox", nil, listPane)
	listFilter:SetSize(LIST_W - 12, 18)
	listFilter:SetPoint("TOPLEFT", 6, -4)
	listFilter:SetAutoFocus(false)
	listFilter:SetFontObject("ChatFontNormal")
	pcall(function() listFilter:SetPropagateKeyboardInput(false) end)
	listFilter:SetScript("OnTextChanged", function()
		listOffset = 0
		rebuildList()
	end)
	listFilter:SetScript("OnEscapePressed", function(f)
		f:ClearFocus()
		f:SetText("")
	end)
	listPane:SetScript("OnMouseWheel", function(_, delta)
		listOffset = math.max(0, math.min(math.max(0, (listCount or 0) - LIST_ROWS), (listOffset or 0) - delta))
		rebuildList()
	end)
	listRows = {}
	for i = 1, LIST_ROWS do listRows[i] = newListRow(i) end

	-- the spine: what makes it read as a book instead of two boxes
	local spine = S.tex(frame, 0.02, 0.02, 0.02, 0.95, "ARTWORK")
	spine:SetPoint("TOPLEFT", 10 + LIST_W + 3, -32)
	spine:SetPoint("BOTTOMLEFT", 10 + LIST_W + 3, 10)
	spine:SetWidth(8)
	local spineLine = S.tex(frame, C.trim[1], C.trim[2], C.trim[3], 0.7, "ARTWORK")
	spineLine:SetPoint("TOPLEFT", 10 + LIST_W + 5, -32)
	spineLine:SetPoint("BOTTOMLEFT", 10 + LIST_W + 5, 10)
	spineLine:SetWidth(2)

	-- right pane: the card
	local pane = CreateFrame("Frame", nil, frame)
	pane:SetPoint("TOPLEFT", PANE_X, -38)
	pane:SetWidth(PANE_W)
	pane:SetHeight(PANE_H)
	frame.pane = pane

	local head = CreateFrame("Frame", nil, pane)
	head:SetPoint("TOPLEFT", 0, 0)
	head:SetPoint("TOPRIGHT", 0, 0)
	head:SetHeight(76)
	local hbg = S.tex(head, 0.11, 0.07, 0.04, 0.6, "BACKGROUND")
	hbg:SetAllPoints(head)
	frame.head = head

	local portraitFrame = CreateFrame("Frame", nil, head)
	portraitFrame:SetSize(66, 66)
	portraitFrame:SetPoint("TOPLEFT", 2, -3)
	portraitFrame:SetFrameLevel(head:GetFrameLevel() + 3)
	S.Border(portraitFrame, C.accent)
	frame.portraitFrame = portraitFrame

	local okModel, model = pcall(CreateFrame, "PlayerModel", nil, head)
	if not okModel then
		okModel, model = pcall(CreateFrame, "Model", nil, head)
	end
	if okModel and model then
		model:SetSize(64, 64)
		model:SetPoint("TOPLEFT", 3, -4)
		model:SetFrameLevel(head:GetFrameLevel() + 2)
		model:Hide()
	end
	frame.model = model

	local portrait = head:CreateTexture(nil, "ARTWORK")
	portrait:SetSize(64, 64)
	portrait:SetPoint("TOPLEFT", 3, -4)
	portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.portrait = portrait

	local name = head:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	name:SetPoint("TOPLEFT", 78, -6)
	name:SetJustifyH("LEFT")
	name:SetWidth(210)
	frame.name = name
	local sub = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", 78, -30)
	sub:SetJustifyH("LEFT")
	sub:SetWidth(210)
	sub:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
	frame.sub = sub

	-- two rows of two chips on the right of the header
	frame.chipSeen = chip(head, 366, -4, "visto")
	frame.chipKills = chip(head, 434, -4, "kills")
	frame.chipLoot = chip(head, 366, -40, "looteado")
	frame.chipDeaths = chip(head, 434, -40, "te mato")

	body = S.ScrollArea(pane, 0, -84, PANE_W, PANE_H - 84)
	frame.body = body
	rows = {}

	frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.footer:SetPoint("BOTTOMLEFT", 14, 8)
	frame.footer:SetText("")
	UI.frameInstance = frame
	return frame
end

-- creature portrait helper for a live unit token
ns.frame.PortraitFor = function(texture, token)
	local ok = pcall(SetPortraitTexture, texture, token)
	return ok
end

SLASH_GARCHADEXUI1 = "/gdxwin"
SlashCmdList["GARCHADEXUI"] = function()
	UI.Show()
end
