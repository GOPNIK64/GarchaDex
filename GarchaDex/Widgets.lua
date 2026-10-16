-- GarchaDex / Widgets.lua
-- Floating toolbar (one button per tool, no typing) plus the index and the text windows.
-- Everything here is drawn through Skin.lua, so every window matches the card.

local addonName, ns = ...

local UI = ns.UI
local S = ns.Skin
local C = S.C

local bar, textFrame
local ROW_H = 20

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
	-- the window grows with the text (lines x line height), clamped to the screen
	local lines = 1
	for _ in string.gmatch(text or "", "\n") do
		lines = lines + 1
	end
	local lh = 14
	local okLh, v = pcall(function() return textFrame.edit:GetLineHeight() end)
	if okLh and type(v) == "number" and v > 0 then lh = v end
	local maxH = math.max(200, (UIParent:GetHeight() or 768) - 140)
	local editH = math.min(lines * lh + 8, maxH - 70)
	textFrame.edit:SetHeight(editH)
	textFrame:SetHeight(editH + 70)
	textFrame:Show()
	return textFrame
end


-- ------------------------------------------------------------------ art audit

-- Atlas names are checked with the client's own C_Texture.GetAtlasExists, and texture paths are
-- drawn in a grid: a missing path shows the client's green checkerboard, so one look settles it.
local ART_ATLASES = {
	"UI-Frame-Portrait-Border", "UI-Frame-IconBackground", "UI-DialogBox-Border", "UI-DialogBox-Background",
	"UI-Panel-Button-Up", "UI-Panel-Button-Down", "UI-Panel-Button-Highlight", "UI-Panel-Button-Disabled",
	"options-icon", "common-icon-redx", "bags-icon-slot", "UI-Tooltip-Border",
	"UI-HUD-ActionBar-IconFrame", "talents-frame-border", "UI-HUD-MicroMenu-Bags-Up", "ui-frame-generic-dark",
}
local ART_PATHS = {
	"Interface\\Tooltips\\UI-Tooltip-Border",
	"Interface\\Tooltips\\UI-Tooltip-Background",
	"Interface\\DialogFrame\\UI-DialogBox-Border",
	"Interface\\DialogFrame\\UI-DialogBox-Background",
	"Interface\\DialogFrame\\UI-DialogBox-Header",
	"Interface\\Buttons\\UI-Panel-Button-Up",
	"Interface\\Buttons\\UI-Panel-Button-Down",
	"Interface\\Buttons\\UI-Panel-Button-Highlight",
	"Interface\\Common\\UI-TooltipDivider",
	"Interface\\Buttons\\UI-Panel-Button-Disabled",
}

local artPanel
function UI.ShowArt()
	local lines = { "atlas del cliente (C_Texture.GetAtlasExists):", "" }
	for _, a in ipairs(ART_ATLASES) do
		lines[#lines + 1] = ("  %-42s %s"):format(a, S.atlasExists(a) and "|cff40ff40SI|r" or "|cffff6060no|r")
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "templates de Blizzard (pcall CreateFrame):"
	for _, tpl in ipairs({ "UIPanelButtonTemplate", "UIPanelCloseButton", "BackdropTemplate",
		"UIPanelScrollFrameTemplate", "UICheckButtonTemplate", "InputBoxTemplate", "GameTooltipTemplate" }) do
		local ok = pcall(CreateFrame, "Frame", nil, UIParent, tpl)
		lines[#lines + 1] = ("  %-42s %s"):format(tpl, ok and "|cff40ff40SI|r" or "|cffff6060no|r")
	end
	for _, ty in ipairs({ "PlayerModel", "Model", "Cooldown", "StatusBar", "EditBox", "ScrollFrame" }) do
		local ok = pcall(CreateFrame, ty, nil, UIParent)
		lines[#lines + 1] = ("  tipo %-37s %s"):format(ty, ok and "|cff40ff40SI|r" or "|cffff6060no|r")
	end
	-- the 3d model is what the card uses for a creature you are not targeting: test both calls
	local okFrame, mframe = pcall(CreateFrame, "PlayerModel", nil, UIParent)
	local okOld, oframe = false, nil
	if not okFrame then okOld, oframe = pcall(CreateFrame, "Model", nil, UIParent) end
	local model = okFrame and mframe or oframe
	local callA, callB = "-", "-"
	if model then
		local okA, errA = pcall(function() model:SetModelByCreatureDisplayID(4192) end)
		callA = okA and "|cff40ff40ok|r" or ("|cffff6060ERR: " .. tostring(errA):sub(1, 60) .. "|r")
		local okB, errB = pcall(function() model:SetDisplayInfo(4192) end)
		callB = okB and "|cff40ff40ok|r" or ("|cffff6060ERR: " .. tostring(errB):sub(1, 60) .. "|r")
	end
	lines[#lines + 1] = ("  tipo %-37s %s"):format("PlayerModel (el de la ficha)",
		model and "|cff40ff40SI|r" or "|cffff6060no|r")
	lines[#lines + 1] = ("  %-41s %s"):format("SetModelByCreatureDisplayID(4192)", callA)
	lines[#lines + 1] = ("  %-41s %s"):format("SetDisplayInfo(4192)", callB)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "abajo: texturas por ruta. Si ves un damero verde/negro, esa ruta no existe aca."
	lines[#lines + 1] = "pegame esta lista y los cuadros que se vean bien y uso ese arte de verdad."
	UI.ShowText("GarchaDex · auditoria de arte", table.concat(lines, "\n"))

	if not artPanel then
		local gridRows = math.ceil(#ART_PATHS / 5)
		artPanel = S.Panel("GarchaDexArt", UIParent, 820, 52 + gridRows * 142, "GarchaDex · arte candidato")
		artPanel:SetPoint("CENTER", UIParent, "CENTER", 0, -60)
		-- a live 3d model next to the texture grid: if this one renders, the card's will too
		local okM, model = pcall(CreateFrame, "PlayerModel", nil, artPanel)
		if not okM then okM, model = pcall(CreateFrame, "Model", nil, artPanel) end
		if okM and model then
			model:SetSize(120, 150)
			model:SetPoint("BOTTOMRIGHT", -24, 30)
			pcall(function()
				model:SetModelByCreatureDisplayID(4192)
				model:SetPortraitZoom(1)
				model:SetCamDistanceScale(0.85)
				model:SetRotation(0.5)
			end)
			local l = model:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			l:SetPoint("TOP", model, "BOTTOM", 0, -2)
			l:SetText("modelo 4192 (Fanatic)")
		end
		for idx, path in ipairs(ART_PATHS) do
			local col = (idx - 1) % 5
			local row = math.floor((idx - 1) / 5)
			local box = CreateFrame("Frame", nil, artPanel)
			box:SetSize(110, 110)
			box:SetPoint("TOPLEFT", 20 + col * 122, -44 - row * 140)
			S.Border(box, C.border)
			local t = box:CreateTexture(nil, "ARTWORK")
			t:SetAllPoints(box)
			t:SetTexture(path)
			local l = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			l:SetPoint("TOP", box, "BOTTOM", 0, -4)
			l:SetWidth(120)
			l:SetText(path:match("[^\\]+$") or path)
		end
	end
	artPanel:Show()
end

-- ------------------------------------------------------------------ the widget (the only thing on screen)

-- One small book on screen. Everything else moved to slash commands: a toolbar of eight buttons
-- was clutter he asked to delete. Click opens the dex, right click hides it, /gdx widget brings it
-- back, and it remembers where it was left.
local widget

local function saveWidgetPos()
	local p, _, rp, x, y = widget:GetPoint(1)
	ns.DB().meta.widgetPos = { p = p, rp = rp, x = x, y = y }
end

function UI.BuildBar()
	if widget then
		widget:Show()
		return widget
	end
	widget = CreateFrame("Button", "GarchaDexWidget", UIParent)
	widget:SetSize(146, 26)
	widget:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -24)
	widget:SetMovable(true)
	widget:SetClampedToScreen(true)
	widget:RegisterForDrag("LeftButton")
	widget:SetScript("OnDragStart", function(f) f:StartMoving() end)
	widget:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		pcall(saveWidgetPos)
	end)

	-- the cover: warm brown, with the trim inset so the corners read rounded, like the book icon
	local cover = S.tex(widget, 0.13, 0.09, 0.05, 0.97, "BACKGROUND")
	cover:SetAllPoints(widget)
	local inner = CreateFrame("Frame", nil, widget)
	inner:SetPoint("TOPLEFT", 2, -2)
	inner:SetPoint("BOTTOMRIGHT", -2, 2)
	pcall(function() inner:SetFrameLevel(widget:GetFrameLevel() + 1) end)
	S.Border(inner, S.C.trim, 1, "ARTWORK")
	local hl = S.tex(widget, S.C.accent[1], S.C.accent[2], S.C.accent[3], 0.12, "HIGHLIGHT")
	hl:SetAllPoints(widget)

	local icon = widget:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("LEFT", 7, 0)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	pcall(function() icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09") end)

	local label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	label:SetText("|cffffd200GarchaDex|r")

	widget:SetScript("OnClick", function()
		if ns.UI and ns.UI.Show then ns.UI.Show() end
	end)
	widget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("GarchaDex v" .. tostring(ns.VERSION), 1, 0.82, 0, 1)
		GameTooltip:AddLine(ns.T("click para abrir el bestiario"), 0.85, 0.85, 0.85)
		GameTooltip:AddLine(ns.T("arrastrable · click derecho lo oculta · /gdx help"), 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
	widget:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then widget:Hide() end
	end)

	local pos = ns.DB().meta.widgetPos
	if pos and pos.p then
		widget:ClearAllPoints()
		widget:SetPoint(pos.p, UIParent, pos.rp or pos.p, pos.x or 0, pos.y or 0)
	end
	return widget
end

