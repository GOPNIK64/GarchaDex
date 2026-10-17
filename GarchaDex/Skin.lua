-- GarchaDex / Skin.lua
-- One place for how GarchaDex looks: classic-stylized panels (warm dark brown, bronze and gold
-- trim, the game's own yellow), cropped icons, quality-coloured item names.
-- No custom art: when the client has the classic templates or atlases we use them, and every
-- use is verified at runtime so a missing texture can never become a green checkerboard.

local addonName, ns = ...

local S = {}
ns.Skin = S

-- Classic palette: dark warm brown panels, bronze trim, gold accents, the game's own yellow.
S.C = {
	bg      = { 0.07, 0.05, 0.04, 0.99 },   -- panel body (near opaque: overlapping panels must not blend)
	bgDark  = { 0.04, 0.03, 0.02, 1.00 },   -- wells (inside lists)
	header  = { 0.18, 0.13, 0.08, 1.00 },   -- title and section strips
	row     = { 0.14, 0.11, 0.07, 0.55 },   -- list rows
	border  = { 0.35, 0.27, 0.16, 1.00 },   -- bronze
	trim    = { 0.78, 0.66, 0.40, 1.00 },   -- gold trim
	accent  = { 0.84, 0.72, 0.34, 1.00 },   -- gold accent (bars, hairlines)
	gold    = { 1.00, 0.82, 0.00, 1.00 },   -- classic yellow
	green   = { 0.35, 0.90, 0.35, 1.00 },
	blue    = { 0.55, 0.75, 1.00, 1.00 },
	grey    = { 0.62, 0.56, 0.46, 1.00 },   -- parchment grey
	dim     = { 0.45, 0.40, 0.32, 1.00 },
	red     = { 0.95, 0.35, 0.28, 1.00 },
	white   = { 1.00, 1.00, 1.00, 1.00 },
}

local QUALITY = {
	[0] = { 0.62, 0.62, 0.62 },
	[1] = { 1.00, 1.00, 1.00 },
	[2] = { 0.12, 1.00, 0.00 },
	[3] = { 0.00, 0.44, 0.87 },
	[4] = { 0.64, 0.21, 0.93 },
	[5] = { 1.00, 0.50, 0.00 },
	[6] = { 0.90, 0.80, 0.50 },
	[7] = { 0.90, 0.80, 0.50 },
}

local function itemQuality(itemID)
	if not itemID or not (C_Item and C_Item.GetItemQualityByID) then return nil end
	local ok, q = pcall(C_Item.GetItemQualityByID, itemID)
	if ok and type(q) == "number" then return q end
	return nil
end
S.itemQuality = itemQuality

function S.qualityColor(itemID)
	local q = itemQuality(itemID)
	return QUALITY[q or 1] or QUALITY[1]
end

function S.hex(c)
	return ("|cff%02x%02x%02x"):format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

local function tex(parent, r, g, b, a, layer)
	local t = parent:CreateTexture(nil, layer or "BACKGROUND")
	t:SetColorTexture(r, g, b, a)
	return t
end
S.tex = tex

-- ------------------------------------------------------------------ client art, verified at runtime

function S.atlasExists(atlasName)
	if not atlasName or not (C_Texture and C_Texture.GetAtlasExists) then return false end
	local ok, exists = pcall(C_Texture.GetAtlasExists, atlasName)
	return (ok and exists) and true or false
end

-- use the client's classic atlas art only when the name really resolves
function S.Atlas(texture, atlasName)
	if not S.atlasExists(atlasName) then return false end
	local ok = pcall(function() texture:SetAtlas(atlasName) end)
	return ok
end

-- ------------------------------------------------------------------ borders

-- an n-px outline drawn from four textures: identical on every client, no template needed
function S.Border(frame, color, size, layer)
	color = color or S.C.border
	size = size or 1
	if not frame.gdxBorder then
		frame.gdxBorder = {}
		for i = 1, 4 do
			frame.gdxBorder[i] = tex(frame, color[1], color[2], color[3], color[4] or 1, layer or "BORDER")
		end
		local t, b, l, r = frame.gdxBorder[1], frame.gdxBorder[2], frame.gdxBorder[3], frame.gdxBorder[4]
		t:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
		t:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
		t:SetHeight(size)
		b:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
		b:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
		b:SetHeight(size)
		l:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
		l:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
		l:SetWidth(size)
		r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
		r:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
		r:SetWidth(size)
	end
	for _, t in ipairs(frame.gdxBorder) do
		t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	end
end

-- the classic double edge: a dark outer line with a gold inner line
function S.Trim(frame, outer, inner)
	S.Border(frame, outer or { 0.02, 0.02, 0.02, 0.90 }, 2)
	local f = CreateFrame("Frame", nil, frame)
	f:SetPoint("TOPLEFT", 2, -2)
	f:SetPoint("BOTTOMRIGHT", -2, 2)
	f:SetFrameLevel(frame:GetFrameLevel() + 1)
	S.Border(f, inner or S.C.trim, 1, "ARTWORK")
	frame.gdxTrim = f
	return f
end

function S.IconBorder(frame)
	local b = tex(frame, 0, 0, 0, 0.85, "BORDER")
	b:SetPoint("TOPLEFT", -1, 1)
	b:SetPoint("BOTTOMRIGHT", 1, -1)
	return b
end

-- the client's own close button when the template exists, a plain X when it does not
function S.CloseButton(parent, onClick)
	local ok, btn = pcall(CreateFrame, "Button", nil, parent, "UIPanelCloseButton")
	if ok and btn then
		btn:SetPoint("TOPRIGHT", 4, 4)
		btn:SetScript("OnClick", onClick)
		btn:SetFrameLevel(parent:GetFrameLevel() + 5)
		return btn
	end
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(20, 20)
	b:SetPoint("TOPRIGHT", -6, -6)
	local x = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	x:SetPoint("CENTER")
	x:SetText("|cffff5555X|r")
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function() x:SetText("|cffff8888X|r") end)
	b:SetScript("OnLeave", function() x:SetText("|cffff5555X|r") end)
	return b
end

-- ------------------------------------------------------------------ panel

function S.Panel(name, parent, w, h, title, onHide)
	local f = CreateFrame("Frame", name, parent or UIParent)
	f:SetSize(w, h)
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	if onHide then f:SetScript("OnHide", onHide) end

	local bg = tex(f, S.C.bg[1], S.C.bg[2], S.C.bg[3], S.C.bg[4], "BACKGROUND")
	bg:SetAllPoints(f)
	f.bg = bg
	S.Trim(f)

	local head = tex(f, S.C.header[1], S.C.header[2], S.C.header[3], S.C.header[4], "BACKGROUND")
	head:SetPoint("TOPLEFT", 3, -3)
	head:SetPoint("TOPRIGHT", -3, -3)
	head:SetHeight(26)
	f.head = head

	local hair = tex(f, S.C.accent[1], S.C.accent[2], S.C.accent[3], 0.75, "ARTWORK")
	hair:SetPoint("TOPLEFT", 3, -29)
	hair:SetPoint("TOPRIGHT", -3, -29)
	hair:SetHeight(1)

	local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	t:SetPoint("LEFT", head, "LEFT", 12, 0)
	t:SetText(title or "GarchaDex")
	f.title = t

	f.close = S.CloseButton(f, function() f:Hide() end)
	f:EnableKeyboard(true)
	-- windows must behave like the game's own: clicking one brings it to the front of its level,
	-- and Escape closes the topmost instead of every panel at once
	pcall(function() f:SetToplevel(true) end)
	pcall(function() f:SetPropagateKeyboardInput(true) end)
	f:SetScript("OnShow", function(self)
		pcall(function() self:Raise() end)
	end)
	f:SetScript("OnMouseDown", function(self)
		pcall(function() self:Raise() end)
	end)
	f:SetScript("OnKeyDown", function(self, key)
		pcall(function() self:SetPropagateKeyboardInput(true) end)
		if key == "ESCAPE" then self:Hide() end
	end)
	return f
end

-- a fixed-height pane that scrolls its content, with a slim scrollbar that only appears when the
-- content is taller than the pane: the window never resizes under the player's cursor
function S.ScrollArea(parent, x, y, w, h)
	local area = CreateFrame("Frame", nil, parent)
	area:SetPoint("TOPLEFT", x, y)
	area:SetSize(w, h)
	local well = tex(area, S.C.bgDark[1], S.C.bgDark[2], S.C.bgDark[3], 1, "BACKGROUND")
	well:SetAllPoints(area)
	S.Border(area, S.C.border)
	pcall(function() area:SetClipsChildren(true) end)
	local content = CreateFrame("Frame", nil, area)
	content:SetPoint("TOPLEFT", 2, -2)
	content:SetWidth(w - 14)
	content:SetHeight(10)
	area.content = content
	area.offset = 0
	area.maxOffset = 0

	local track = tex(area, 0.10, 0.08, 0.05, 0.9, "ARTWORK")
	track:SetSize(4, h - 6)
	track:SetPoint("TOPRIGHT", -2, -3)
	local thumb = tex(area, S.C.trim[1], S.C.trim[2], S.C.trim[3], 0.85, "ARTWORK")
	thumb:SetSize(4, 40)
	area.track, area.thumb = track, thumb

	function area.Update()
		local viewH = h - 6
		local contentH = content:GetHeight() or 0
		local over = math.max(0, contentH - viewH)
		area.maxOffset = over
		if area.offset > over then area.offset = over end
		if area.offset < 0 then area.offset = 0 end
		content:ClearAllPoints()
		-- +offset moves the content UP (later rows into view): the sign matters, a minus here
		-- leaves a blank band at the top and cuts the bottom, which reads as "the scroll is broken"
		content:SetPoint("TOPLEFT", area, "TOPLEFT", 2, 2 + area.offset)
		local span = math.min(viewH, math.max(24, viewH * (viewH / math.max(1, contentH))))
		local frac = (over > 0) and (area.offset / over) or 0
		thumb:SetHeight(span)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", track, "TOP", 0, -frac * math.max(0, viewH - span))
		track:SetShown(over > 0)
		thumb:SetShown(over > 0)
	end

	function area.ScrollBy(delta)
		area.offset = area.offset - delta * 34
		area.Update()
	end

	area:EnableMouseWheel(true)
	area:SetScript("OnMouseWheel", function(self, delta) self.ScrollBy(delta) end)
	-- the rows inside are buttons with the mouse enabled: they must pass the wheel along, or the
	-- pane never scrolls while the cursor is over content
	content:EnableMouseWheel(true)
	content:SetScript("OnMouseWheel", function(_, delta) area.ScrollBy(delta) end)
	area.Update()
	return area
end

-- a body that grows with its content and clips what does not fit: no scrollbar anywhere
function S.GrowingBody(parent, x, y, w)
	local body = CreateFrame("Frame", nil, parent)
	body:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	body:SetWidth(w)
	body:SetHeight(10)
	local well = tex(body, S.C.bgDark[1], S.C.bgDark[2], S.C.bgDark[3], S.C.bgDark[4], "BACKGROUND")
	well:SetAllPoints(body)	-- background second: keep it under the rows
	well:SetParent(body)
	pcall(function() body:SetClipsChildren(true) end)
	local content = CreateFrame("Frame", nil, body)
	content:SetPoint("TOPLEFT")
	content:SetWidth(w)
	content:SetHeight(10)
	body.content = content
	body:EnableMouseWheel(true)
	body.offset = 0
	body.maxOffset = 0
	body:SetScript("OnMouseWheel", function(self, delta)
		if self.maxOffset <= 0 then return end
		self.offset = math.max(-self.maxOffset, math.min(0, self.offset + delta * 28))
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", body, "TOPLEFT", 0, self.offset)
	end)
	return body
end

-- ------------------------------------------------------------------ button

function S.Button(parent, label, w, h, tip, onClick)
	-- the client's classic button art when the template is there
	local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
	if ok and type(b) == "table" and b.SetText then
		b:SetSize(w or 64, h or 20)
		b:SetText(label)
		b:SetScript("OnClick", onClick)
		-- one label setter for both branches: the classic template owns the font string
		b.SetLabel = function(self, text)
			if self.fs then self.fs:SetText(text) else self:SetText(text) end
		end
		if tip then
			b:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(ns.T(tip), 1, 1, 1, true)
				GameTooltip:Show()
			end)
			b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		b.isClassic = true
		return b
	end
	-- fallback: flat bronze button with gold text
	b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 64, h or 20)
	local bg = tex(b, 0.16, 0.12, 0.07, 0.95, "BACKGROUND")
	bg:SetAllPoints(b)
	b.bg = bg
	S.Border(b, S.C.border)
	local hl = tex(b, S.C.accent[1], S.C.accent[2], S.C.accent[3], 0.18, "HIGHLIGHT")
	hl:SetAllPoints(b)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("CENTER")
	fs:SetText(label)
	b.fs = fs
	b.SetLabel = function(self, text)
		if self.fs then self.fs:SetText(text) else self:SetText(text) end
	end
	b:SetScript("OnClick", onClick)
	if tip then
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(ns.T(tip), 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	return b
end

-- ------------------------------------------------------------------ scroll body

function S.ScrollBody(parent, x, y, w, h)
	local body = CreateFrame("Frame", nil, parent)
	body:SetSize(w, h)
	body:SetPoint("TOPLEFT", x, y)
	local well = tex(body, S.C.bgDark[1], S.C.bgDark[2], S.C.bgDark[3], S.C.bgDark[4], "BACKGROUND")
	well:SetAllPoints(body)
	S.Border(body, S.C.border)
	local content = CreateFrame("Frame", nil, body)
	content:SetSize(w, h)
	content:SetPoint("TOPLEFT")
	body.content = content
	body.offset = 0
	body.maxOffset = 0
	body:EnableMouseWheel(true)

	local bar = tex(body, 0.30, 0.23, 0.13, 0.90, "OVERLAY")
	bar:SetSize(3, h)
	bar:SetPoint("TOPRIGHT", body, "TOPRIGHT", 6, 0)
	local thumb = tex(body, S.C.accent[1], S.C.accent[2], S.C.accent[3], 0.85, "OVERLAY")
	thumb:SetSize(3, h)
	thumb:SetPoint("TOPRIGHT", body, "TOPRIGHT", 6, 0)
	body.bar, body.thumb = bar, thumb

	local function applyScroll()
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", body, "TOPLEFT", 0, body.offset)
		local frac = (body.maxOffset > 0) and (body.offset / body.maxOffset) or 0
		local span = math.max(0.15, h / (h + body.maxOffset)) * h
		thumb:SetHeight(span)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", body, "TOP", 8, -frac * (h - span))
		thumb:SetShown(body.maxOffset > 0)
		bar:SetShown(body.maxOffset > 0)
	end
	body.ApplyScroll = applyScroll
	body.SetMaxOffset = function(self, m)
		self.maxOffset = math.max(0, m)
		if self.offset > self.maxOffset then self.offset = self.maxOffset end
		if self.offset < 0 then self.offset = 0 end
		applyScroll()
	end
	body:SetScript("OnMouseWheel", function(self, delta)
		self.offset = math.max(0, math.min(self.maxOffset, self.offset + delta * 28))
		applyScroll()
	end)
	return body
end

return S
