-- GarchaDex / UI.lua
-- The dex card: a game-styled window with the creature's own art, its spells and its drops.
-- Two layers are always labelled: what you measured, and the vanilla 1.12 reference.
--
-- Secret values (measured on build 70425): the spell name and icon a mob casts can be STORED
-- and DRAWN, but never compared, printed or used as a key. So the spell list shows the
-- reference (readable ids) and the observed casts as drawn rows, with no dedupe between them.

local addonName, ns = ...

local UI = {}
ns.UI = UI

local S = ns.Skin
local C = S.C

local frame, rows, search, body
local currentID
local MAX_ROWS = 90          -- the body scrolls, so this is only a sanity cap
local MAX_DROP_ROWS = 40
local ROW_H = 18
local hiddenRows = 0

local function copper(n)
	n = math.floor((n or 0) + 0.5)
	local g, s, c = math.floor(n / 10000), math.floor((n % 10000) / 100), n % 100
	if g > 0 then return ("%dg %ds %dc"):format(g, s, c) end
	if s > 0 then return ("%ds %dc"):format(s, c) end
	return ("%dc"):format(c)
end

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

-- ------------------------------------------------------------------ rows

local function newRow(index)
	local r = CreateFrame("Frame", nil, body.content)
	r:SetHeight(ROW_H)
	r:SetPoint("TOPLEFT", body.content, "TOPLEFT", 0, -(index - 1) * ROW_H)
	r:SetPoint("RIGHT", body.content, "RIGHT", 0, 0)

	local bg = S.tex(r, C.row[1], C.row[2], C.row[3], 0, "BACKGROUND")
	bg:SetAllPoints(r)
	r.bg = bg

	-- the percentage bar sits behind the text: measured in green, reference in blue
	local bar = S.tex(r, C.accent[1], C.accent[2], C.accent[3], 0, "BACKGROUND")
	bar:SetPoint("RIGHT", r, "RIGHT", -2, 0)
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
	suffix:SetPoint("RIGHT", r, "RIGHT", -6, 0)
	suffix:SetJustifyH("RIGHT")
	suffix:SetTextColor(0.6, 0.6, 0.6)
	r.suffix = suffix
	return r
end

local function prep(i, iconPath, colour, pct, barColour)
	local r = rows[i]
	if not r then
		r = newRow(i)
		rows[i] = r
	end
	r:Show()
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
		r.bar:SetColorTexture(bc[1], bc[2], bc[3], 0.16)
		r.bar:SetWidth(math.max(2, math.min(160, pct * 1.6)))
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
	r.text:SetWidth(0)      -- 0 = auto width
	r.text:SetText(ns.T(msg or ""))
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
	r.text:SetWidth(240)
	local okText = pcall(function() r.text:SetText(name or "?") end)
	if not okText then r.text:SetText("?") end
	r.suffix:SetText(ns.T(suffixText or ""))
	return r
end

-- section header: title on the left, hairline to the right, tab-like background
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

local function note(i, txt, colour)
	local r = prep(i, nil, colour or C.grey)
	r.text:SetWidth(0)
	r.text:SetText(ns.T(txt))
end

-- ------------------------------------------------------------------ chips (header stats)

local function chip(parent, x, y, label)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(62, 34)
	f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	local bg = S.tex(f, 0.08, 0.08, 0.10, 0.85, "BACKGROUND")
	bg:SetAllPoints(f)
	S.Border(f, C.border)
	local v = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	v:SetPoint("TOP", 0, -5)
	v:SetText("0")
	f.value = v
	local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	l:SetPoint("BOTTOM", 0, 3)
	l:SetText(ns.T(label))
	l:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
	return f
end

-- ------------------------------------------------------------------ the card

function UI.Show(id)
	id = id and tostring(id) or nil
	if not id and ns.UnitIdentity then id = ns.UnitIdentity("target") end
	if not id then
		print("|cff33ff99GarchaDex|r no hay target y no me pasaste un npc id.")
		return
	end
	if not frame then UI.Create() end
	currentID = id
	UI.currentID = id
	local e = ns.DB().seen[id]
	local meta = seedMeta(id)
	frame:Show()
	for _, r in pairs(rows) do r:Hide() end

	-- header: name, identity and stats
	local live = ns.UnitIdentity and ns.UnitIdentity("target")
	local title = (e and e.name) or (meta and meta.name) or ("npc " .. id)
	frame.name:SetText(title)
	local lvl, ctype, zone = "?", "?", nil
	if e then
		lvl = tostring(e.level or "?")
		ctype = e.creatureType and (CTYPE[tostring(e.creatureType)] or tostring(e.creatureType)) or nil
		zone = e.zone
	end
	if meta then
		lvl = (meta.minLevel == meta.maxLevel) and meta.minLevel or (meta.minLevel .. "-" .. meta.maxLevel)
		ctype = ctype or CTYPE[meta.ctype] or meta.ctype
	end
	local sub = ("npc %s · lvl %s%s%s"):format(id, lvl,
		ctype and (" · " .. ctype) or "", RANK and meta and meta.rank and (" · " .. (RANK[meta.rank] or meta.rank)) or "")
	if (not meta) and e then sub = sub .. " · mob comun" end
	frame.sub:SetText(sub)
	frame.chipSeen.value:SetText(tostring(e and e.seen or 0))
	frame.chipKills.value:SetText(tostring(e and e.kills or 0))
	frame.chipLoot.value:SetText(tostring(e and e.lootWindows or 0))
	frame.chipDeaths.value:SetText(tostring(e and e.deaths or 0))
	frame.chipDeaths.value:SetTextColor(C.red[1], C.red[2], C.red[3])
	frame.footer:SetText(ns.T("MEDIDO = lo que looteaste vos · REFERENCIA = base 1.12, no medida en Forever"))

	-- art: live portrait for a real target, the seed's display id for a known creature
	local drew = false
	if ns.frame and ns.frame.PortraitFor and live == id then
		drew = ns.frame.PortraitFor(frame.portrait, "target")
	end
	frame.model:Hide()
	if not drew and meta and meta.model then
		local ok = pcall(function()
			frame.model:Show()
			frame.model:SetModelByCreatureDisplayID(tonumber(meta.model), true)
			frame.model:SetPortraitZoom(1)
			frame.model:SetPosition(0, 0, 0)
			frame.model:SetRotation(0.6)
		end)
		drew = ok and true or false
	end
	if drew and not frame.model:IsShown() then frame.portrait:Show() else frame.portrait:Hide() end

	local i = 0
	hiddenRows = 0
	local function put(iconPath, msg, colour, pct, barColour)
		i = i + 1
		if i > MAX_ROWS then
			hiddenRows = hiddenRows + 1
			return
		end
		row(i, iconPath, msg, colour, pct, barColour)
	end

	-- identity / provenance
	if meta then
		put(nil, ("referencia 1.12: lvl %s-%s · %s · mapa %s"):format(
			meta.minLevel, meta.maxLevel, RANK[meta.rank] or meta.rank, meta.map), C.blue)
	else
		local n2, sp = ns.SeedN(id), ns.SeedSpells(id)
		if n2 or sp then
			local cnt = 0
			if sp then for _ in string.gmatch(sp, "%d+") do cnt = cnt + 1 end end
			put(nil, ("mob comun: sin ficha en el seed, pero la referencia tiene N=%s items%s"):format(
				n2 and tostring(n2) or "?", cnt > 0 and (" y " .. cnt .. " hechizo(s)") or ""), C.blue)
		else
			put(nil, "sin entrada en el seed: contenido de Forever, o mob que la base 1.12 no tiene", C.grey)
		end
	end
	if e then
		put(nil, ("medido: visto %d veces · looteado %d · plata %s%s%s"):format(
			e.seen or 0, e.lootWindows or 0, copper(e.moneyCopper),
			e.zone and (" · " .. e.zone) or "",
			(e.lootNoGuid or 0) > 0 and (" · |cffff8080sin GUID x" .. e.lootNoGuid .. "|r") or ""), C.green)
	end

	-- spells
	i = i + 1; section(i, "HECHIZOS · REFERENCIA 1.12", C.gold)
	local seedSpells = ns.SeedSpells(id)
	if seedSpells then
		for sid in string.gmatch(seedSpells, "%d+") do
			local name, icon = spellInfo(sid)
			put(icon, ("%s   |cff606060id %s|r"):format(name or ("spell " .. sid), sid), C.white)
		end
	else
		put(nil, "(sin hechizos declarados en la referencia)", C.dim)
	end
	if e and (e.casts or 0) > 0 then
		i = i + 1; section(i, ("HECHIZOS OBSERVADOS · %d casteos"):format(e.casts), C.blue)
		local log = e.spellLog or {}
		local shown = math.min(#log, 12)
		for k = #log - shown + 1, #log do
			local rec = log[k]
			if rec then
				i = i + 1
				if i <= MAX_ROWS then
					-- name and icon are secret values: hand them to the widget untouched
					local suffix = rec.name == nil
						and ("[" .. ns.tostringSafe(rec.how or "sin dato") .. "]")
						or ""
					rowSecret(i, rec.icon, rec.name, suffix, C.white)
				else
					hiddenRows = hiddenRows + 1
				end
			end
		end
		put(nil, "el cliente oculta el id del hechizo: estos nombres los dibuja el juego, no se pueden comparar ni contar", C.dim)
	end

	-- drops: measured first (this is the real thing), reference after
	i = i + 1; section(i, "DROPS MEDIDOS POR VOS", C.green)
	local ownSeed, sharedSeed = ns.ParseLoot(ns.SeedLoot(id))
	local n = ns.SeedN(id)
	local measured = {}
	for _, d in pairs((e and e.drops) or {}) do measured[#measured + 1] = d end
	table.sort(measured, function(a, b) return (a.count or 0) > (b.count or 0) end)
	local denom = (e and e.lootWindows or 0) > 0 and e.lootWindows or 1
	local discovered = 0
	for key in pairs(ownSeed) do if e and e.drops[tostring(key)] then discovered = discovered + 1 end end
	if #measured > 0 then
		put(nil, ("%d cadaveres looteados · %s/%s items de la pool descubiertos"):format(
			e.lootWindows or 0, tostring(discovered), n and tostring(n) or "?"), C.grey)
		for k = 1, math.min(#measured, MAX_DROP_ROWS) do
			local d = measured[k]
			local key = tonumber(d.id)
			local pct = 100 * (d.count or 0) / denom
			local refTxt
			if key and ownSeed[key] then
				refTxt = ("ref %.2f%%"):format(ownSeed[key])
			elseif key and sharedSeed[key] then
				refTxt = ("ref %.2f%% (grupo)"):format(sharedSeed[key])
			elseif key then
				refTxt = "no catalogado en 1.12"
			else
				refTxt = "sin id resuelto"
			end
			rowColored(i + k, itemIcon(d.id),
				("%s"):format((d.name or "?"):sub(1, 34)),
				S.qualityColor(key), ("%2d/%d = %5.1f%%%s   %s"):format(d.count or 0, denom, pct,
					(d.qty or 0) > 1 and ("  (" .. d.qty .. "u)") or "", refTxt), pct)
		end
		i = i + math.min(#measured, MAX_DROP_ROWS)
	else
		put(nil, ("sin drops medidos todavia (%d cadaveres looteados)"):format(e and e.lootWindows or 0), C.dim)
	end

	local list = {}
	for item, chance in pairs(ownSeed) do list[#list + 1] = { item, chance, false } end
	for item, chance in pairs(sharedSeed) do list[#list + 1] = { item, chance, true } end
	table.sort(list, function(a, b) return math.abs(a[2]) > math.abs(b[2]) end)
	i = i + 1; section(i, ("REFERENCIA 1.12 · " .. (n and tostring(n) or tostring(#list)) .. " items en la pool"), C.blue)
	if #list > 0 then
		for k = 1, math.min(#list, MAX_DROP_ROWS) do
			local it, ch, shared = list[k][1], list[k][2], list[k][3]
			local got = e and e.drops[tostring(it)]
			local tag = ch < 0 and " · condicional de quest" or (shared and " · grupo compartido" or "")
			rowColored(i + k, itemIcon(it), itemName(it):sub(1, 34), S.qualityColor(tonumber(it)),
				("%6.2f%%%s"):format(ch, tag), math.abs(ch))
		end
		i = i + math.min(#list, MAX_DROP_ROWS)
		if #list > MAX_DROP_ROWS then
			put(nil, ("... y %d items mas en la pool"):format(#list - MAX_DROP_ROWS), C.dim)
		end
	else
		put(nil, "esta pool no viene con su contenido en el seed: se llena con lo que lootees", C.dim)
	end

	for k = i + 1, MAX_ROWS do
		if rows[k] then rows[k]:Hide() end
	end
	-- rows are positioned top-down from the section blocks: recompute the offset for scrolling
	local total = i * ROW_H
	body.content:SetHeight(math.max(total, body:GetHeight()))
	if body.SetMaxOffset then body.SetMaxOffset(body, math.max(0, total - body:GetHeight())) end
end

-- ------------------------------------------------------------------ the window

function UI.Create()
	frame = S.Panel("GarchaDexFrame", UIParent, 560, 520, "GarchaDex")
	frame:SetPoint("CENTER")
	frame.title:SetText("|cff3fd15aGarchaDex|r  |cff808080poke-dex de enemigos|r")

	-- header block
	local head = CreateFrame("Frame", nil, frame)
	head:SetPoint("TOPLEFT", 1, -31)
	head:SetPoint("TOPRIGHT", -1, -31)
	head:SetHeight(78)
	local hbg = S.tex(head, 0.07, 0.07, 0.09, 0.6, "BACKGROUND")
	hbg:SetAllPoints(head)

	local model = CreateFrame("PlayerModel", nil, head)
	model:SetSize(64, 64)
	model:SetPoint("TOPLEFT", 10, -4)
	model:Hide()
	frame.model = model
	local portrait = head:CreateTexture(nil, "ARTWORK")
	portrait:SetSize(64, 64)
	portrait:SetPoint("TOPLEFT", 10, -4)
	portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.portrait = portrait
	local pframe = CreateFrame("Frame", nil, head)
	pframe:SetSize(66, 66)
	pframe:SetPoint("TOPLEFT", 9, -3)
	S.Border(pframe, C.accent)
	pframe:SetFrameLevel(head:GetFrameLevel() + 3)
	pframe:EnableMouse(false)

	local name = head:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	name:SetPoint("TOPLEFT", 86, -6)
	name:SetJustifyH("LEFT")
	frame.name = name
	local sub = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", 86, -28)
	sub:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
	frame.sub = sub

	-- two rows of two chips on the right of the header
	frame.chipSeen = chip(head, 356, -4, "visto")
	frame.chipKills = chip(head, 424, -4, "kills")
	frame.chipLoot = chip(head, 356, -40, "looteado")
	frame.chipDeaths = chip(head, 424, -40, "te mato")

	-- search
	local slabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	slabel:SetPoint("TOPLEFT", 14, -116)
	slabel:SetText(ns.T("buscar en el seed:"))
	slabel:SetTextColor(C.blue[1], C.blue[2], C.blue[3])
	search = CreateFrame("EditBox", nil, frame)
	search:SetSize(160, 20)
	search:SetPoint("TOPLEFT", 104, -114)
	search:SetAutoFocus(false)
	search:SetFontObject("ChatFontNormal")
	search:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
	local shint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	shint:SetPoint("LEFT", search, "RIGHT", 8, 0)
	shint:SetText(ns.T("nombre del mob + Enter · o targetear y tocar Ficha"))
	search:SetScript("OnEnterPressed", function(s)
		local q = string.lower((s:GetText() or ""))
		if q ~= "" then
			local seed = ns.npc or (ns.SEED and ns.SEED.npc) or {}
			local found
			for cid, rec in pairs(seed) do
				local nm = string.lower((string.match(rec, "^[^|]+") or ""))
				if string.find(nm, q, 1, true) then
					found = cid
					if nm == q then break end
				end
			end
			if found then
				s:ClearFocus()
				s:SetText("")
				UI.Show(found)
			else
				print("|cff33ff99GarchaDex|r no encontre '" .. q .. "' en el seed.")
			end
		end
	end)

	body = S.ScrollBody(frame, 14, -140, 526, 348)
	frame.body = body
	rows = {}
	UI.frameInstance = frame
	frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.footer:SetPoint("BOTTOMLEFT", 14, 10)
	frame.close:SetScript("OnClick", function() frame:Hide() end)
	return frame
end

-- creature portrait helper for a live unit token
ns.frame.PortraitFor = function(texture, token)
	local ok = pcall(SetPortraitTexture, texture, token)
	return ok
end

SLASH_GARCHADEXUI1 = "/gdxwin"
SlashCmdList["GARCHADEXUI"] = function()
	UI.Create()
	UI.Show()
end
