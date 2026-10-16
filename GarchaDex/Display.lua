-- GarchaDex / Display.lua
-- Text report and the secret-value render test. The graphical window comes next;
-- this exists so capture can be verified in chat without a UI in the way.

local addonName, ns = ...

local function isSecret(v) return ns.isSecret(v) end

local function copper(n)
	n = math.floor((n or 0) + 0.5)
	local g = math.floor(n / 10000)
	local s = math.floor((n % 10000) / 100)
	local c = n % 100
	if g > 0 then return ("%dg %ds %dc"):format(g, s, c) end
	if s > 0 then return ("%ds %dc"):format(s, c) end
	return ("%dc"):format(c)
end

local buffer   -- when set, say() collects lines instead of printing them

local function stripColors(s)
	return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function say(msg)
	if buffer then
		buffer[#buffer + 1] = stripColors(ns.T(msg))
	else
		print("|cff33ff99GarchaDex|r " .. ns.T(msg))
	end
end

-- the same report as text, for the copyable box
local function capture(fn)
	buffer = {}
	local ok = pcall(fn)
	local text = table.concat(buffer, "\n")
	buffer = nil
	if not ok then return "error armando el texto" end
	return text
end

function ns.EntryText(id) return capture(function() ns.PrintEntry(id) end) end
function ns.StatsText() return capture(ns.PrintStats) end
function ns.SeedText() return capture(ns.PrintSeed) end
function ns.LootText() return capture(ns.PrintLoot) end
function ns.RunSecretTest() renderSecretTest() end

-- item and spell ids in the seed are plain numbers, so the client resolves their names
local function itemName(id)
	local n
	if C_Item and C_Item.GetItemNameByID then
		local ok, v = pcall(C_Item.GetItemNameByID, tonumber(id))
		if ok then n = v end
	end
	if (n == nil or n == "") and type(GetItemInfo) == "function" then
		local ok, v = pcall(GetItemInfo, tonumber(id))
		if ok then n = v end
	end
	if n == nil and C_Item and C_Item.GetItemInfo then
		local ok, v = pcall(C_Item.GetItemInfo, tonumber(id))
		if ok then n = v end
	end
	if type(n) == "string" and n ~= "" then return n end
	return "item " .. tostring(id)
end

local function spellName(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, tonumber(id))
		if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
	end
	return "spell " .. tostring(id)
end

local function seedMeta(id)
	local s = ns.SeedNpc(id)
	if not s then return nil end
	local f = {}
	for part in string.gmatch(s, "[^|]+") do f[#f + 1] = part end
	return { name = f[1], minLevel = f[2], maxLevel = f[3], rank = f[4], ctype = f[5], model = f[6], map = f[7] }
end

local RANK = { ["0"] = "normal", ["1"] = "elite", ["2"] = "rare-elite", ["3"] = "boss", ["4"] = "rare" }

function ns.PrintEntry(id)
	id = tostring(id)
	local e = ns.DB().seen[id]
	local meta = seedMeta(id)
	local title = (e and e.name) or (meta and meta.name) or ("npc " .. id)
	say(("|cffffd200%s|r  (npc %s)"):format(title, id))
	if meta then
		say(("  referencia 1.12: lvl %s-%s, %s, tipo %s, modelo %s, mapa %s"):format(
			meta.minLevel, meta.maxLevel, RANK[meta.rank] or meta.rank, meta.ctype, meta.model, meta.map))
	else
		local n2, sp = ns.SeedN(id), ns.SeedSpells(id)
		if n2 or sp then
			say(("  mob comun: sin ficha en el seed, pero la referencia si tiene la pool (N=%s)%s"):format(
				n2 and tostring(n2) or "?", sp and " y hechizos declarados" or ""))
		else
			say("  sin entrada en el seed (contenido de Forever, o mob que la base 1.12 no tiene)")
		end
	end
	if not e then
		say("  |cff808080nada capturado todavia|r")
		return
	end
	say(("  capturado: visto %d, kills %d, looteado %d, plata %s%s%s%s"):format(
		e.seen or 0, e.kills or 0, e.lootWindows or 0, copper(e.moneyCopper),
		e.zone and (", zona " .. e.zone) or "",
		e.deaths and e.deaths > 0 and (", te mató " .. e.deaths .. " veces") or "",
		(e.lootNoGuid or 0) > 0 and (", sin GUID x" .. e.lootNoGuid) or ""))
	if e.level then say(("  lvl %s, %s, %s"):format(tostring(e.level), tostring(e.creatureType or "?"), tostring(e.classification or "?"))) end

	-- drops: measured first, then the reference pool
	local drops = {}
	for _, d in pairs(e.drops or {}) do drops[#drops + 1] = d end
	table.sort(drops, function(a, b) return (a.count or 0) > (b.count or 0) end)
	local ownSeed, sharedSeed = ns.ParseLoot(ns.SeedLoot(id))
	local n = ns.SeedN(id)
	local denom = (e.lootWindows or 0) > 0 and e.lootWindows or 1
	local discovered = 0
	for key in pairs(ownSeed) do if e.drops[tostring(key)] then discovered = discovered + 1 end end
	if #drops > 0 then
		say(("  |cff00ff00DROPS MEDIDOS por vos|r · %d cadaveres looteados · %s/%s items descubiertos:"):format(
			e.lootWindows or 0, tostring(discovered), n and tostring(n) or "?"))
		for _, d in ipairs(drops) do
			local key = tonumber(d.id)
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
			say(("    %-30s %2d/%2d = %5.1f%%  (%du)  · %s"):format(
				(d.name or "?"):sub(1, 30), d.count or 0, denom, 100 * (d.count or 0) / denom, d.qty or 0, refTxt))
		end
	else
		say(("  |cff808080sin drops medidos todavia (%d cadaveres looteados)|r"):format(e.lootWindows or 0))
	end
	if n and (next(ownSeed) ~= nil or next(sharedSeed) ~= nil) then
		local list = {}
		for item, chance in pairs(ownSeed) do list[#list + 1] = { item, chance, false } end
		for item, chance in pairs(sharedSeed) do list[#list + 1] = { item, chance, true } end
		table.sort(list, function(a, b) return math.abs(a[2]) > math.abs(b[2]) end)
		say(("  |cffffd200REFERENCIA VANILLA 1.12|r (%d items en la pool):"):format(n))
		for i = 1, math.min(#list, 12) do
			local it, ch, shared = list[i][1], list[i][2], list[i][3]
			local tag = ch < 0 and " |cff8080ff[condicional de quest]" or (shared and " [grupo compartido]" or "")
			say(("    %-38s %7.2f%%%s"):format(itemName(it):sub(1, 38), ch, tag))
		end
		if #list > 12 then say(("    ... y %d mas"):format(#list - 12)) end
	elseif n then
		say(("  la referencia tiene |cffffd200N=%s|r items en la pool, pero su contenido no se empaqueta para mobs comunes:"):format(n))
		say("  esta lista se llena con lo que lootees vos.")
	else
		say("  |cff808080este mob no aparece en la base 1.12|r")
	end

	-- spells: reference list (readable) plus what was observed (identity hidden by the client)
	local seedSpells = ns.SeedSpells(id)
	if seedSpells then
		local names = {}
		for sid in string.gmatch(seedSpells, "%d+") do names[#names + 1] = spellName(sid) .. " (" .. sid .. ")" end
		say("  |cffffd200HECHIZOS (referencia 1.12)|r " .. table.concat(names, ", "))
	end
	local readable, hidden = 0, 0
	for _ in pairs(e.spells or {}) do readable = readable + 1 end
	hidden = e.casts or 0
	say(("  |cff00ff00HECHIZOS OBSERVADOS|r %d casteos%s"):format(hidden,
		readable > 0 and (", " .. readable .. " con nombre legible") or " (el cliente oculta el id para addons)"))
	local log = e.spellLog or {}
	for i = math.max(1, #log - 3), #log do
		local rec = log[i]
		if rec then
			local nm
			if rec.name == nil then
				nm = ("|cffff6060sin nombre|r |cff808080(%s)|r"):format(ns.tostringSafe(rec.how or "?"))
			elseif isSecret(rec.name) then
				nm = "|cff808080(secreto: el nombre y el icono se dibujan en la ventana: /gdx)|r"
			else
				nm = tostring(rec.name)
			end
			say(("    cast %d/%d: %s"):format(i, #log, nm))
		end
	end
	if not e.spells or next(e.spells) == nil then
		if hidden > 0 then
			say("    |cff808080(usa /gdx test para ver si la ventana puede mostrar el nombre y el icono)|r")
		end
	end
end

-- ------------------------------------------------------------------ secret render test

local testFrame
local function renderSecretTest()
	local last = ns.LastCast and ns.LastCast()
	if not testFrame then
		testFrame = CreateFrame("Frame", "GarchaDexSecretTest", UIParent)
		testFrame:SetSize(360, 96)
		testFrame:SetPoint("CENTER")
		testFrame:SetMovable(true)
		testFrame:EnableMouse(true)
		testFrame:RegisterForDrag("LeftButton")
		testFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
		testFrame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
		local bg = testFrame:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(testFrame)
		bg:SetColorTexture(0, 0, 0, 0.9)
		local icon = testFrame:CreateTexture(nil, "ARTWORK")
		icon:SetSize(48, 48)
		icon:SetPoint("LEFT", 16, 0)
		icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		testFrame.icon = icon
		local text = testFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		text:SetPoint("LEFT", icon, "RIGHT", 12, 0)
		text:SetWidth(250)
		text:SetJustifyH("LEFT")
		testFrame.text = text
	end
	local nameResult, iconResult = "sin datos", "sin datos"
	if last then
		-- the whole point: can a widget draw a secret?
		local okN, errN = pcall(function() testFrame.text:SetText(last.name) end)
		nameResult = okN and "SetText OK" or ("SetText BLOQUEADO: " .. ns.tostringSafe(errN))
		local okI, errI = pcall(function() testFrame.icon:SetTexture(last.icon) end)
		iconResult = okI and "SetTexture OK" or ("SetTexture BLOQUEADO: " .. ns.tostringSafe(errI))
		testFrame.text:SetText(last.name or "nil")
		-- does the widget hand the value back in the clear? if it does, spells can be keyed
		local okG, back = pcall(testFrame.text.GetText, testFrame.text)
		if not okG then
			say("GetText -> BLOQUEADO")
		elseif back == nil then
			say("GetText -> nil")
		elseif isSecret(back) then
			say("GetText -> |cffff4040sigue secreto|r (sin dedupe, como esperaba)")
		else
			say("GetText -> |cff00ff00PLANO|r: '" .. ns.tostringSafe(back) .. "' -> se puede deduplicar!")
			ns.PlainNameFromWidget = true
		end
		local okT, tex = pcall(testFrame.icon.GetTexture, testFrame.icon)
		if okT and tex ~= nil then
			say("GetTexture -> " .. (isSecret(tex) and "|cffff4040sigue secreto|r" or ("|cff00ff00PLANO|r: " .. ns.tostringSafe(tex))))
		end
	else
		testFrame.text:SetText("todavia no capture ningun casteo")
	end
	testFrame:Show()
	say("test de render -> " .. nameResult .. " | " .. iconResult)
	say("|cffffd200Decime si en la ventana ves el nombre del hechizo y el icono de verdad (no un cuadro con '?').|r")
end

function ns.PrintStats()
	local db = ns.DB()
	local mobs, kills, casts = 0, 0, 0
	for _, e in pairs(db.seen) do
		mobs = mobs + 1
		kills = kills + (e.kills or 0)
		casts = casts + (e.casts or 0)
	end
	local ck = ns.CharKey()
	local c = db.chars[ck] or {}
	say(("v%s · seed: npc=%s loot=%s lootn=%s spell=%s · mobs registrados %d | kills %d | casteos %d | de este personaje: kills %d, looteos %d, nodos %d"):format(
		ns.VERSION,
		type(ns.npc) == "table" and "si" or "NO",
		type(ns.loot) == "table" and "si" or "NO",
		type(ns.lootn) == "table" and "si" or "NO",
		type(ns.spell) == "table" and "si" or "NO",
		mobs, kills, casts, c.kills or 0, c.loots or 0, c.nodes or 0))
	say(("loot no atribuido: %s · ultimo source: %s"):format(
		tostring(db.meta.lastLootUnattributed or 0), tostring(db.meta.lastLootSource or "todavia nada")))
	local fb = 0
	for _, e in pairs(db.seen) do fb = fb + (e.lootFallback or 0) end
	say(("de esos, atribuidos por ultimo-kill (fallback): %d"):format(fb))
end

-- prints the last loot events, which is the only reliable way to see why a corpse was or
-- was not attributed (source string, method, money, items with their resolved id)
function ns.PrintLoot()
	local db = ns.DB()
	local log = db.meta.lootLog or {}
	say(("v%s · eventos de loot guardados: %d"):format(ns.VERSION, #log))
	if #log == 0 then
		say("ninguno todavia: si looteaste y no aparece, el handler no se esta ejecutando")
		return
	end
	for i = #log, math.max(1, #log - 5), -1 do
		local r = log[i]
		say(("%d) id=%s via %s · plata %sc"):format(i, tostring(r.id), tostring(r.method), tostring(r.money or 0)))
		say(("     src=%s"):format(tostring(r.src)))
		say(("     items=%s"):format(tostring(r.items)))
	end
end

-- answers "did the seed load, and can it be read for this id" in one line
function ns.PrintSeed()
	say("version " .. ns.VERSION)
	local function count(t)
		local n = 0
		if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
		return type(t) == "table" and tostring(n) or "AUSENTE"
	end
	say(("tablas: npc=%s loot=%s lootn=%s spell=%s wgrp=%s wloot=%s"):format(
		count(ns.npc), count(ns.loot), count(ns.lootn), count(ns.spell), count(ns.wgrp), count(ns.wloot)))
	local id = ns.UnitIdentity("target")
	if id then
		say(("target %s: SeedNpc=%s SeedN=%s SeedSpells=%s SeedLoot=%s"):format(
			id, tostring(ns.SeedNpc(id)), tostring(ns.SeedN(id)), tostring(ns.SeedSpells(id)),
			tostring(ns.SeedLoot(id) and "si" or "no")))
		say("chequeo crudo: ns.lootn[3197]=" .. tostring(ns.lootn and ns.lootn[3197]) ..
			" ns.spell[3197]=" .. tostring(ns.spell and ns.spell[3197]))
	else
		say("chequeo crudo: ns.lootn[3197]=" .. tostring(ns.lootn and ns.lootn[3197]) ..
			" ns.spell[3197]=" .. tostring(ns.spell and ns.spell[3197]))
	end
end

-- ------------------------------------------------------------------ copyable box

local box
local function showBox(text)
	-- the canonical text window lives in Widgets.lua: it has a working close button
	if ns.UI and ns.UI.ShowText then return ns.UI.ShowText("GarchaDex", text) end
	if not box then
		box = CreateFrame("Frame", "GarchaDexTextBox", UIParent)
		box:SetSize(700, 460)
		box:SetPoint("CENTER")
		box:SetMovable(true)
		box:EnableMouse(true)
		box:RegisterForDrag("LeftButton")
		box:SetScript("OnDragStart", function(f) f:StartMoving() end)
		box:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
		local bg = box:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(box)
		bg:SetColorTexture(0, 0, 0, 0.92)
		local eb = CreateFrame("EditBox", nil, box)
		eb:SetMultiLine(true)
		eb:SetFontObject("ChatFontNormal")
		eb:SetWidth(660)
		eb:SetHeight(420)
		eb:SetPoint("TOPLEFT", 18, -18)
		eb:SetAutoFocus(true)
		eb:SetScript("OnEscapePressed", function(s) s:ClearFocus(); box:Hide() end)
		box.edit = eb
		local btn = CreateFrame("Button", nil, box)
		btn:SetSize(70, 22)
		btn:SetPoint("BOTTOMRIGHT", -14, 10)
		btn:SetScript("OnClick", function() box:Hide() end)
		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("CENTER")
		fs:SetText("Cerrar")
		btn:SetFontString(fs)
	end
	box.edit:SetText(text or "")
	box.edit:HighlightText()
	box:Show()
end

SLASH_GARCHADEX1 = "/gdx"
SLASH_GARCHADEX2 = "/garchadex"
SlashCmdList["GARCHADEX"] = function(msg)
	msg = string.lower(msg or "")
	if msg == "stats" then
		ns.PrintStats()
	elseif msg == "test" then
		renderSecretTest()
	elseif msg:match("^%d+$") then
		if ns.UI then
			ns.UI.Show(msg)
		else
			ns.PrintEntry(msg)
		end
	elseif msg:match("^lang") then
		local code = string.match(msg, "^lang%s+(%a+)$") or "auto"
		local applied = ns.SetLang(code)
		ns.DB().meta.lang = (code == "auto") and nil or applied
		say(("idioma del addon: %s · cliente: %s"):format(applied, tostring(ns.LOCALE)))
	elseif msg == "bar" then
		if ns.UI and ns.UI.BuildBar then
			ns.UI.BuildBar()
			say("barra de herramientas visible (click derecho sobre ella la oculta)")
		end
	elseif msg == "loot" then
		ns.PrintLoot()
	elseif msg == "seed" then
		ns.PrintSeed()
	elseif msg == "wipe all" then
		ns.DB().seen = {}
		say("borre TODOS los datos capturados. La referencia y el rastro por personaje quedan.")
	elseif msg == "wipe" then
		local id = ns.UnitIdentity("target")
		if id and ns.DB().seen[id] then
			ns.DB().seen[id] = nil
			say("borre los datos capturados del npc " .. id .. " (la referencia del seed queda)")
		elseif not id then
			say("targeteá un enemigo, o usá /gdx wipe all")
		else
			say("el npc " .. id .. " no tenia datos capturados")
		end
	elseif msg == "box" then
		local id = ns.UnitIdentity("target")
		if id then
			showBox(ns.EntryText(id))
			say("texto en la ventana: seleccionado, Cmd+C para copiar.")
		else
			say("targeteá un enemigo para copiar su ficha (o usá /gdx text <npcID>)")
		end
	elseif msg == "text" then
		local id = ns.UnitIdentity("target")
		if id then
			ns.PrintEntry(id)
		else
			say("targeteá un enemigo o usá /gdx text <npcID>")
		end
	elseif msg == "" then
		local id = ns.UnitIdentity("target")
		if id then
			if ns.UI then
				ns.UI.Show(id)
			else
				ns.PrintEntry(id)
			end
		else
			say("targetea un enemigo o pasá un npc id. Comandos:")
			print("  |cffffff00/gdx|r ficha del target (ventana)   |cffffff00/gdx <npcID>|r ficha por id")
			print("  |cffffff00/gdx box|r la ficha en texto copiable  |cffffff00/gdx text|r en el chat")
			print("  |cffffff00/gdx seed|r estado del seed   |cffffff00/gdx loot|r ultimos looteos vistos")
			print("  |cffffff00/gdx lang es|en|auto|r idioma   |cffffff00/gdx wipe|r borra lo capturado del target")
			print("  |cffffff00/gdx stats|r contadores    |cffffff00/gdx test|r render de valores secretos")
		end
	else
		say("no entendi '" .. msg .. "'. Usá /gdx, /gdx <npcID>, /gdx text, /gdx stats, /gdx test")
	end
end
