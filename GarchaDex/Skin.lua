-- GarchaDex / Skin.lua
-- One place for how GarchaDex looks: dark game-styled panels, flat borders, accent line,
-- cropped icons, quality-coloured item names. No custom art: every texture is the client's own.

local addonName, ns = ...

local S = {}
ns.Skin = S

S.C = {
	bg      = { 0.04, 0.04, 0.05, 0.94 },
	header  = { 0.08, 0.08, 0.10, 0.95 },
	row     = { 0.10, 0.10, 0.12, 0.55 },
	border  = { 0.20, 0.20, 0.24, 1.00 },
	accent  = { 0.25, 0.82, 0.35, 1.00 },
	gold    = { 1.00, 0.82, 0.00, 1.00 },
	blue    = { 0.42, 0.72, 1.00, 1.00 },
	grey    = { 0.55, 0.55, 0.60, 1.00 },
	dim     = { 0.38, 0.38, 0.42, 1.00 },
	red     = { 1.00, 0.36, 0.32, 1.00 },
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

-- a 1px outline drawn from four textures: no template dependency, identical on every client
function S.Border(frame, color, size)
	color = color or S.C.border
	size = size or 1
	if not frame.gdxBorder then
		frame.gdxBorder = {}
		for i = 1, 4 do
			frame.gdxBorder[i] = tex(frame, color[1], color[2], color[3], color[4] or 1, "BORDER")
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

function S.IconBorder(frame)
	local b = tex(frame, 0, 0, 0, 0.8, "BORDER")
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
	b:SetScript("OnEnter", function(f)
		x:SetText("|cffff8888X|r")
	end)
	b:SetScript("OnLeave", function(f)
		x:SetText("|cffff5555X|r")
	end)
	return b
end

-- generic docked panel with title bar, accent line and drag support
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
	S.Border(f, S.C.border)

	local head = tex(f, S.C.header[1], S.C.header[2], S.C.header[3], S.C.header[4], "BACKGROUND")
	head:SetPoint("TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", -1, -1)
	head:SetHeight(28)
	f.head = head

	local accent = tex(f, S.C.accent[1], S.C.accent[2], S.C.accent[3], 0.9, "ARTWORK")
	accent:SetPoint("TOPLEFT", 1, -29)
	accent:SetPoint("TOPRIGHT", -1, -29)
	accent:SetHeight(2)

	local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	t:SetPoint("LEFT", head, "LEFT", 10, 0)
	t:SetText(title or "GarchaDex")
	f.title = t

	f.close = S.CloseButton(f, function() f:Hide() end)
	f:EnableKeyboard(true)
	f:SetScript("OnKeyDown", function(self, key)
		if key == "ESCAPE" then self:Hide() end
	end)
	return f
end

-- flat button with hover/pressed feedback
function S.Button(parent, label, w, h, tip, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 64, h or 20)
	local bg = tex(b, 0.12, 0.12, 0.14, 0.9, "BACKGROUND")
	bg:SetAllPoints(b)
	b.bg = bg
	local hl = tex(b, 0.25, 0.82, 0.35, 0.18, "HIGHLIGHT")
	hl:SetAllPoints(b)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("CENTER")
	fs:SetText(label)
	b.fs = fs
	b:SetScript("OnClick", onClick)
	if tip then
		b:SetScript("OnEnter", function(self)
			bg:SetColorTexture(0.25, 0.82, 0.35, 0.25)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(ns.T(tip), 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function()
			bg:SetColorTexture(0.12, 0.12, 0.14, 0.9)
			GameTooltip:Hide()
		end)
	end
	return b
end

-- a scrollable body: clips its children and scrolls with the wheel, with a slim custom bar
function S.ScrollBody(parent, x, y, w, h)
	local body = CreateFrame("Frame", nil, parent)
	body:SetSize(w, h)
	body:SetPoint("TOPLEFT", x, y)
	local content = CreateFrame("Frame", nil, body)
	content:SetSize(w, h)
	content:SetPoint("TOPLEFT")
	body.content = content
	body.offset = 0
	body.maxOffset = 0
	body:EnableMouseWheel(true)

	local bar = tex(body, 0.16, 0.16, 0.18, 0.8, "OVERLAY")
	bar:SetSize(3, h)
	bar:SetPoint("TOPRIGHT", body, "TOPRIGHT", 6, 0)
	local thumb = tex(body, 0.35, 0.75, 0.40, 0.9, "OVERLAY")
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
