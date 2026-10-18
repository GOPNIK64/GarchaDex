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
local listRows, listFilter, listCache, listCount
-- 0-based row window of the index. It must start at 0: nil here crashed the very first render when
-- nothing was selected yet, because the clamp at the bottom of rebuildList compares it with a number.
local listOffset = 0
-- forward declaration: newListRow's wheel handler calls it, and a local declared further down would
-- resolve to a nil global inside that closure (the index would simply refuse to scroll)
local rebuildList
local modelIdx = 1   -- which of the creature's skins the card is showing
local modelRotation = 0.6   -- and at what angle: dragging the model changes it, the DB remembers it
local modelZoom = 0.85      -- how close the camera sits: the wheel over the model changes it too
local ROT_PER_PIXEL = 0.010 -- drag sensitivity: one constant, because feel is a matter of taste
local uiTab = "card"        -- which of the two right-hand panes is showing
local seedTotal             -- how many creatures the bundled seed carries, counted once
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
	return { name = f[1], minLevel = f[2], maxLevel = f[3], rank = f[4], ctype = f[5], model = f[6], map = f[7], models = f[8] }
end

local RANK = { ["0"] = "normal", ["1"] = "elite", ["2"] = "elite raro", ["3"] = "jefe", ["4"] = "raro" }
local CTYPE = { ["1"] = "Bestia", ["2"] = "Dragonkin", ["3"] = "Demonio", ["4"] = "Elemental", ["5"] = "Gigante",
	["6"] = "No-muerto", ["7"] = "Humanoide", ["8"] = "Critter", ["9"] = "Mecanico", ["11"] = "Totem" }

-- gold is the one number that is pure fun: what this creature paid you, account-wide
local function copper(n)
	n = math.floor((n or 0) + 0.5)
	local g, s, c = math.floor(n / 10000), math.floor((n % 10000) / 100), n % 100
	if g > 0 then return ("%dg %ds"):format(g, s) end
	if s > 0 then return ("%ds %dc"):format(s, c) end
	return ("%dc"):format(c)
end

-- ------------------------------------------------------------------ left pane: the index of what you found

local function newListRow(i)
	local r = CreateFrame("Button", nil, frame.listPane)
	r:SetHeight(LIST_ROW_H)
	r:SetPoint("TOPLEFT", frame.listPane, "TOPLEFT", 6, -(i - 1) * LIST_ROW_H - 28)
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
		-- the fun number, right under the name: what this creature has paid you so far
		GameTooltip:AddLine(("%s: %s"):format(ns.T("oro"), copper(e.moneyCopper or 0)), 1, 0.82, 0)
		GameTooltip:AddLine(("%s: %s"):format(ns.T("kills"), tostring(e.kills or 0)), 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- the same for the list: the row is a button, the wheel has to reach the pane
	r:EnableMouseWheel(true)
	r:SetScript("OnMouseWheel", function(_, delta)
		listOffset = math.max(0, math.min(math.max(0, (listCount or 0) - LIST_ROWS), (listOffset or 0) - delta))
		rebuildList()
	end)
	return r
end

function rebuildList()
	local seen = ns.DB().seen
	listOffset = listOffset or 0
	local filter = string.lower((listFilter and listFilter:GetText()) or "")
	-- the dex is a bestiary: only creatures you can fight. Entries captured before hostility was
	-- recorded (no field) are kept, since they came from a target that was attackable then.
	local list = {}
	for id, e in pairs(seen) do
		if e.hostile ~= false then
			-- Entry() fills the name from the offline table when the client refused to give one, so an
			-- old entry stops reading "npc 250484" the moment the table knows it
			e = ns.Entry(id) or e
			local name = e.name or (ns.npc and ns.npc[id] and string.match(ns.npc[id], "^[^|]+")) or ("npc " .. id)
			list[#list + 1] = { id = id, name = name, e = e }
		end
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
	-- wheel over a row must scroll the card, not die on the button
	r:EnableMouseWheel(true)
	r:SetScript("OnMouseWheel", function(_, delta)
		if body and body.ScrollBy then body.ScrollBy(delta) end
	end)
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

local function chip(parent, x, y, label, w)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(w or 62, 32)
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

-- One guarded call per method. This client's model widget is missing several PlayerModel methods,
-- and a single absent one used to fail the whole pcall and hide the artwork: the blank portrait.
local function mcall(model, method, ...)
	local fn = model and model[method]
	if type(fn) ~= "function" then return false end
	local ok = pcall(fn, model, ...)
	return ok and true or false
end

local function renderCard(id)
	if not frame then return false end
	id = id and tostring(id) or nil
	if not id and ns.UnitIdentity then id = ns.UnitIdentity("target") end
	if not id then
		-- the dex opens on the last thing you killed: that is what you came back to look at
		local last = ns.LastKilled and ns.LastKilled()
		if last and ns.DB().seen[tostring(last)] then id = tostring(last) end
	end
	if not id then
		-- nothing else: fall back to the first creature of the index, so the pane is never empty
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
		if frame.modelBar then frame.modelBar:Hide() end
		if frame.model then frame.model:Hide() end
		body.content:SetHeight(24)
		body.offset = 0
		body.Update()
		return true
	end
	local sameCard = (currentID == id)
	currentID = id
	UI.currentID = id
	if not sameCard then modelIdx = 1 end
	local e = ns.Entry(id)   -- Entry also fills the name from the offline table for creatures the client cannot name
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
	if e and e.lastSeen then bits[#bits + 1] = ns.T("ultima vez") .. " " .. date("%d/%m", e.lastSeen) end
	frame.sub:SetText(ns.T(table.concat(bits, " · ")))
	frame.chipSeen.value:SetText(tostring(e and e.seen or 0))
	frame.chipKills.value:SetText(tostring(e and e.kills or 0))
	frame.chipLoot.value:SetText(tostring(e and e.lootWindows or 0))
	frame.chipDeaths.value:SetText(tostring(e and e.deaths or 0))
	frame.chipGold.value:SetText(copper(e and e.moneyCopper or 0))
	frame.chipGold.value:SetTextColor(S.C.gold[1], S.C.gold[2], S.C.gold[3])

	-- art: live portrait for a real target, otherwise the 3d model of this creature's skin.
	-- A generic mob usually has several skins (ModelId1..4 in the seed, plus any variant this account
	-- met live), so the strip under the portrait cycles them.
	local variants = {}
	local function addVariant(v)
		v = tonumber(v)
		if not v or v <= 0 then return end
		for _, x in ipairs(variants) do
			if x == v then return end
		end
		variants[#variants + 1] = v
	end
	if meta then
		addVariant(meta.model)
		for v in string.gmatch(meta.models or "", "[^,]+") do addVariant(v) end
	end
	if e and e.models then
		for v in pairs(e.models) do addVariant(v) end
	end
	if #variants == 0 then modelIdx = 1 elseif modelIdx > #variants then modelIdx = 1 end
	frame.variants = variants
	if frame.modelBar then
		frame.modelBar.count:SetText(modelIdx .. "/" .. #variants)
		frame.modelBar:SetShown(#variants > 1)
	end

	local drew = false
	if ns.frame and ns.frame.PortraitFor and live == id then
		drew = ns.frame.PortraitFor(frame.portrait, "target")
	end
	if frame.model then frame.model:Hide() end
	local mid = variants[modelIdx]
	if not drew and frame.model then
		-- the same skin, in every generation of the API: whichever this client actually has wins.
		-- Each call is guarded on its own, so one missing method no longer sinks the others.
		local function place()
			if mid then
				if mcall(frame.model, "SetModelByCreatureDisplayID", mid) then return "SetModelByCreatureDisplayID" end
				if mcall(frame.model, "SetCreatureDisplayID", mid) then return "SetCreatureDisplayID" end
				if mcall(frame.model, "SetDisplayInfo", mid) then return "SetDisplayInfo" end
			end
			-- last resort: the creature id itself, for a model widget that only knows SetCreature
			if tonumber(id) and mcall(frame.model, "SetCreature", tonumber(id)) then return "SetCreature" end
			return nil
		end
		local used = place()
		if used then
			mcall(frame.model, "SetPortraitZoom", 1)
			mcall(frame.model, "SetCamDistanceScale", modelZoom)
			mcall(frame.model, "SetPosition", 0, 0, 0)
			mcall(frame.model, "SetRotation", modelRotation)
			frame.model:Show()
			-- a model frame that was hidden often paints blank on the first set: re-apply it visible
			place()
			ns.artMethod = used
			drew = true
		end
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
	local got = {}
	for key, rec in pairs((e and e.drops) or {}) do
		local itemID = tonumber(key) or tonumber(rec.id)
		if itemID then got[itemID] = rec end
	end
	-- A negative chance marks a quest-conditional row: it does not roll unless the quest is up, so it
	-- stays out of the denominator. The card and the progress tab must agree on the size of the pool.
	local pool, kind, quests = {}, {}, 0
	local function addSlots(t, shared)
		for itemID, chance in pairs(t) do
			local k = kind[itemID]
			if not k then
				if chance < 0 then
					kind[itemID] = "quest"
					quests = quests + 1
				else
					kind[itemID] = "pool"
					pool[#pool + 1] = { id = itemID, chance = chance, shared = shared }
				end
			elseif k == "quest" and chance >= 0 then
				-- the same item is quest-only in one part of the table and a normal drop in another: the
				-- normal drop wins, or the pool would stay one row short forever
				kind[itemID] = "pool"
				quests = quests - 1
				pool[#pool + 1] = { id = itemID, chance = chance, shared = shared }
			end
		end
	end
	addSlots(ownSeed, false)
	addSlots(sharedSeed, true)
	table.sort(pool, function(a, b) return a.chance > b.chance end)
	local inPool = 0
	for k = 1, #pool do
		if got[pool[k].id] then inPool = inPool + 1 end
	end
	local gotN = 0
	for _ in pairs(got) do gotN = gotN + 1 end
	i = i + 1
	if #pool > 0 then
		section(i, ("DROPS · %d/%d %s"):format(inPool, #pool, ns.T("descubiertos")), C.green)
	else
		-- no reference pool at all: the honest header is how many you measured, not a 0/0 that reads
		-- like the addon lost your loot
		section(i, ("DROPS · %d %s"):format(gotN, ns.T("medidos, sin referencia")), C.green)
	end
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
			if kind[itemID] ~= "pool" then
				extra[#extra + 1] = { id = itemID, rec = rec, quest = (kind[itemID] == "quest") }
			end
		end
		for k = 1, #extra do
			local rr = rowColored(i + k, itemIcon(extra[k].id),
				(extra[k].rec.name or itemName(extra[k].id)):sub(1, 40), S.qualityColor(extra[k].id),
				ns.T(extra[k].quest and "condicional de quest" or "sin dato 1.12"), nil)
			attachItem(rr, extra[k].id)
		end
		i = i + #extra
		if quests > 0 then
			i = i + 1
			row(i, nil, ("%d %s"):format(quests, ns.T("condicionales de quest")), C.dim)
		end
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
			-- a half-built window is worse than no window: drop it so the next attempt rebuilds clean
			frame, rows = nil, nil
			print("|cffff4040GarchaDex|r no pude crear la ventana: " .. ns.tostringSafe(errC))
			return false
		end
	end
	if type(rows) ~= "table" then
		-- the frame survived a failed build (or an old one from before this code existed)
		frame = nil
		return UI.Show(id)
	end
	-- showing a card always means leaving the progress tab: the index click has to land on the card
	UI.SetTab("card")
	local ok, err = pcall(renderCard, id)
	if not ok then
		print("|cffff4040GarchaDex|r error armando la ficha: " .. ns.tostringSafe(err))
	else
		frame:Show()
		rebuildList()
		-- the updater script may have left a newer version behind: say it once, quietly, in the footer
		if frame.footer then
			local newer = ns.Outdated and ns.Outdated()
			frame.footer:SetText(newer and ("|cffe0b030" .. ns.T("hay una version nueva: ") .. tostring(newer) .. "|r") or "")
		end
	end
	return ok
end

-- the arrows under the portrait: cycle the skins of the creature you are looking at
function UI.CycleModel(dir)
	local n = (frame and frame.variants) and #frame.variants or 0
	if n < 2 or not currentID then return end
	modelIdx = ((modelIdx - 1 + (dir or 1)) % n) + 1
	renderCard(currentID)
end

-- ---------------------------------------------------------------- progress: how complete is the dex

local function countSeed()
	if seedTotal then return seedTotal end
	seedTotal = 0
	if type(ns.npc) == "table" then
		for _ in pairs(ns.npc) do seedTotal = seedTotal + 1 end
	end
	return seedTotal
end

-- A and B from the plan, and nothing else. Three rules keep the numbers honest: a quest-conditional
-- row (negative chance) never rolls without its quest, so it is out of the denominator; a drop the
-- reference does not list is counted as "outside" instead of inflating the score; and a creature with
-- no pool at all cannot belong to either number, so it is reported instead of silently skipped.
local function progressStats()
	local seen = (ns.DB() and ns.DB().seen) or {}
	local found, withRef, complete, noRef = 0, 0, 0, 0
	local poolRows, hitRows, outside = 0, 0, 0
	for id, e in pairs(seen) do
		found = found + 1
		local own, shared = ns.ParseLoot(ns.SeedLoot(id))
		local pool = {}
		local function addAll(t)
			for itemID, chance in pairs(t) do
				if chance >= 0 then pool[itemID] = true end
			end
		end
		addAll(own)
		addAll(shared)
		local n, hit, miss = 0, 0, 0
		for _ in pairs(pool) do n = n + 1 end
		for key in pairs((e and e.drops) or {}) do
			if pool[tonumber(key)] then hit = hit + 1 else miss = miss + 1 end
		end
		outside = outside + miss
		if n > 0 then
			withRef = withRef + 1
			poolRows = poolRows + n
			hitRows = hitRows + hit
			if hit >= n then complete = complete + 1 end
		else
			noRef = noRef + 1
		end
	end
	return {
		found = found, total = countSeed(), poolRows = poolRows, hitRows = hitRows,
		complete = complete, withRef = withRef, noRef = noRef, outside = outside,
	}
end

function UI.RefreshProgress()
	if not frame then return end
	local s = progressStats()
	local function pct(a, b) return (b > 0) and (a / b * 100) or 0 end
	if frame.barBestiary then
		frame.barBestiary:SetMinMaxValues(0, math.max(1, s.total))
		frame.barBestiary:SetValue(s.found)
		frame.barBestiary.text:SetText(("%d / %d · %.1f%%"):format(s.found, s.total, pct(s.found, s.total)))
	end
	if frame.barDrops then
		frame.barDrops:SetMinMaxValues(0, math.max(1, s.poolRows))
		frame.barDrops:SetValue(s.hitRows)
		frame.barDrops.text:SetText(("%d / %d · %.1f%%"):format(s.hitRows, s.poolRows, pct(s.hitRows, s.poolRows)))
	end
	if frame.progNotes then
		local lines = {
			{ "entradas completas", ("%d / %d"):format(s.complete, s.withRef) },
			{ "enemigos sin referencia", tostring(s.noRef) },
			{ "drops fuera de la referencia", tostring(s.outside) },
		}
		for k = 1, #lines do
			if frame.progNotes[k] then
				frame.progNotes[k].label:SetText(ns.T(lines[k][1]))
				frame.progNotes[k].value:SetText(lines[k][2])
			end
		end
	end
end

function UI.SetTab(name)
	uiTab = (name == "progress") and "progress" or "card"
	if not frame then return uiTab end
	local prog = (uiTab == "progress")
	if frame.head then frame.head:SetShown(not prog) end
	if body then body:SetShown(not prog) end
	if frame.progressPane then frame.progressPane:SetShown(prog) end
	if frame.tabCard then frame.tabCard.underline:SetShown(not prog) end
	if frame.tabProgress then frame.tabProgress.underline:SetShown(prog) end
	if prog then
		if listFilter then listFilter:ClearFocus() end
		UI.RefreshProgress()
	end
	return uiTab
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

	-- the two tabs live in the window's title strip, so neither pane loses a pixel of height.
	-- NOTE: S.Panel's `head` is a *texture*, not a frame: it can be an anchor, never a parent.
	local titleBar = frame.head
	local function tabButton(label, x, name)
		local b = S.Button(frame, ns.T(label), 88, 18, nil, function() UI.SetTab(name) end)
		b:SetPoint("TOPLEFT", titleBar, "TOPLEFT", x, -4)
		-- the active tab is marked with the same gold hairline the section headers use
		local line = S.tex(b, C.accent[1], C.accent[2], C.accent[3], 1, "OVERLAY")
		line:SetHeight(2)
		line:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 3, -3)
		line:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, -3)
		line:Hide()
		b.underline = line
		return b
	end
	frame.tabCard = tabButton("ficha", 10, "card")
	frame.tabProgress = tabButton("progreso", 102, "progress")

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

	-- a search box that reads as a search box: its own well, a border, a magnifier and a hint, or it
	-- looks like another list row and nobody finds it
	local fw = CreateFrame("Frame", nil, listPane)
	fw:SetSize(LIST_W - 12, 20)
	fw:SetPoint("TOPLEFT", 6, -4)
	local fwbg = S.tex(fw, 0.02, 0.015, 0.01, 1, "BACKGROUND")
	fwbg:SetAllPoints(fw)
	S.Border(fw, C.trim)
	local lupa = fw:CreateTexture(nil, "OVERLAY")
	lupa:SetSize(13, 13)
	lupa:SetPoint("LEFT", 5, 0)
	-- ask the client whether the atlas exists instead of trusting pcall: a missing atlas does not
	-- raise, it just draws nothing, and the box would look empty
	if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("common-search-magnifyingglass") then
		lupa:SetAtlas("common-search-magnifyingglass")
	else
		lupa:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02")
	end
	fw.hint = fw:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fw.hint:SetPoint("LEFT", 22, 0)
	fw.hint:SetText(ns.T("buscar por nombre o id"))
	fw.hint:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
	frame.filterFrame = fw

	listFilter = CreateFrame("EditBox", nil, fw)
	listFilter:SetSize(LIST_W - 46, 18)
	listFilter:SetPoint("LEFT", 22, 0)
	listFilter:SetAutoFocus(false)
	listFilter:SetFontObject("ChatFontNormal")
	pcall(function() listFilter:SetPropagateKeyboardInput(false) end)
	listFilter:SetScript("OnTextChanged", function(f)
		fw.hint:SetShown(f:GetText() == "")
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
	head:SetHeight(112)   -- tall enough for a 102px portrait: the creature is the point of the card
	local hbg = S.tex(head, 0.11, 0.07, 0.04, 0.6, "BACKGROUND")
	hbg:SetAllPoints(head)
	frame.head = head

	local portraitFrame = CreateFrame("Frame", nil, head)
	portraitFrame:SetSize(102, 102)
	portraitFrame:SetPoint("TOPLEFT", 2, -3)
	portraitFrame:SetFrameLevel(head:GetFrameLevel() + 3)
	S.Border(portraitFrame, C.accent)
	frame.portraitFrame = portraitFrame

	-- the skin strip: "< 1/3 >" pinned to the bottom edge of the portrait. Above the model's frame
	-- level, or the model (drawn 2 levels higher) would cover it.
	local bar = CreateFrame("Frame", nil, head)
	bar:SetSize(102, 14)
	bar:SetPoint("BOTTOMLEFT", portraitFrame, "BOTTOMLEFT", 0, 0)
	bar:SetFrameLevel(head:GetFrameLevel() + 5)
	local bbg = S.tex(bar, 0.02, 0.015, 0.01, 0.75, "BACKGROUND")
	bbg:SetAllPoints(bar)
	local function arrow(sym, x, dir)
		local b = CreateFrame("Button", nil, bar)
		b:SetSize(16, 14)
		b:SetPoint("LEFT", x, 0)
		local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		t:SetPoint("CENTER", 0, 0)
		t:SetText("|cffd4a94c" .. sym .. "|r")
		b:SetScript("OnClick", function() UI.CycleModel(dir) end)
		return b
	end
	arrow("<", 0, -1)
	arrow(">", 86, 1)
	bar.count = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bar.count:SetPoint("CENTER", 0, 0)
	bar.count:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
	bar:Hide()
	frame.modelBar = bar

	local okModel, model = pcall(CreateFrame, "PlayerModel", nil, head)
	if not okModel then
		okModel, model = pcall(CreateFrame, "Model", nil, head)
	end
	if okModel and model then
		model:SetSize(98, 98)
		model:SetPoint("TOPLEFT", 4, -5)
		model:SetFrameLevel(head:GetFrameLevel() + 2)
		model:Hide()
	end
	frame.model = model

	-- Dragging the model spins it, like the character sheet. The angle lives account-wide, so the
	-- pose you like survives a reload.
	if model then
		modelRotation = tonumber(ns.DB().meta.modelRotation) or 0.6
		modelZoom = tonumber(ns.DB().meta.modelZoom) or 0.85
		model:EnableMouse(true)
		model:RegisterForDrag("LeftButton")
		model:SetScript("OnDragStart", function(self)
			if GameTooltip then GameTooltip:Hide() end
			local from = GetCursorPosition() / UIParent:GetEffectiveScale()
			local base = modelRotation
			self:SetScript("OnUpdate", function()
				local now = GetCursorPosition() / UIParent:GetEffectiveScale()
				modelRotation = base + (now - from) * ROT_PER_PIXEL
				mcall(self, "SetRotation", modelRotation)
			end)
		end)
		model:SetScript("OnDragStop", function(self)
			self:SetScript("OnUpdate", nil)
			local db = ns.DB()
			if db then db.meta.modelRotation = modelRotation end
		end)
		-- the wheel zooms: a small plate needs the range more than the precision
		model:EnableMouseWheel(true)
		model:SetScript("OnMouseWheel", function(self, delta)
			modelZoom = math.max(0.30, math.min(2.00, modelZoom - (delta or 0) * 0.06))
			mcall(self, "SetCamDistanceScale", modelZoom)
			local db = ns.DB()
			if db then db.meta.modelZoom = modelZoom end
		end)
		-- otherwise nobody discovers either one: it is a portrait, not an obvious control
		model:SetScript("OnEnter", function(self)
			if self:GetScript("OnUpdate") then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(ns.T("arrastra para rotar"), 1, 1, 1)
			GameTooltip:AddLine(ns.T("rueda para acercar"), 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		model:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	local portrait = head:CreateTexture(nil, "ARTWORK")
	portrait:SetSize(98, 98)
	portrait:SetPoint("TOPLEFT", 4, -5)
	portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.portrait = portrait

	local name = head:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	name:SetPoint("TOPLEFT", 114, -8)
	name:SetJustifyH("LEFT")
	name:SetWidth(430)
	frame.name = name
	local sub = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", 114, -32)
	sub:SetJustifyH("LEFT")
	sub:SetWidth(430)
	sub:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
	frame.sub = sub

	-- the header of a real card: portrait on the left, name and identity to its right, then the five
	-- counters in a row underneath, because with a portrait this big there is no room to stack them
	-- at the right edge
	frame.chipSeen = chip(head, 114, -52, "visto", 70)
	frame.chipKills = chip(head, 190, -52, "kills", 70)
	frame.chipGold = chip(head, 266, -52, "oro", 70)
	frame.chipLoot = chip(head, 342, -52, "looteado", 70)
	frame.chipDeaths = chip(head, 418, -52, "te mato", 70)

	body = S.ScrollArea(pane, 0, -120, PANE_W, PANE_H - 120)
	frame.body = body
	rows = {}

	-- ---------------------------------------------------------------- the progress pane
	-- The bars are the game's own level bar: dark well, the client's gradient texture, value written on
	-- top. A StatusBar with SetValue is what makes it read as an xp bar; a texture driven by width reads
	-- as a coloured rectangle.
	local prog = CreateFrame("Frame", nil, pane)
	prog:SetPoint("TOPLEFT", 0, 0)
	prog:SetSize(PANE_W, PANE_H)
	prog:Hide()
	frame.progressPane = prog
	local function xpBar(y, label)
		local t = prog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOPLEFT", 4, y)
		t:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
		t:SetText(ns.T(label))
		local bar = CreateFrame("StatusBar", nil, prog)
		bar:SetPoint("TOPLEFT", 4, y - 18)
		bar:SetSize(PANE_W - 8, 16)
		bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(0)
		local bg = bar:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(bar)
		bg:SetTexture(0, 0, 0, 0.85)
		S.Border(bar, C.border)
		local txt = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		txt:SetPoint("CENTER", 0, 0)
		bar.text = txt
		return bar
	end
	frame.barBestiary = xpBar(-6, "bestiario")
	frame.barDrops = xpBar(-50, "drops de tus enemigos")
	-- the three numbers that keep the percentages honest, in the grey the card already uses
	local sep = S.tex(prog, C.border[1], C.border[2], C.border[3], 0.8, "ARTWORK")
	sep:SetHeight(1)
	sep:SetPoint("TOPLEFT", 4, -96)
	sep:SetPoint("TOPRIGHT", -4, -96)
	frame.progNotes = {}
	for k = 1, 3 do
		local l = prog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l:SetPoint("TOPLEFT", 6, -(104 + (k - 1) * 18))
		l:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
		local v = prog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		v:SetPoint("TOPRIGHT", -8, -(104 + (k - 1) * 18))
		v:SetTextColor(C.white[1], C.white[2], C.white[3])
		frame.progNotes[k] = { label = l, value = v }
	end

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
