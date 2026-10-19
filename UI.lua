local ADDON, ns = ...

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local GHOST_ALPHA, RELEASED_ALPHA = 0.55, 0.22

local CLASSIFICATION = {
	elite = "Elite",
	rareelite = "Rare Elite",
	rare = "Rare",
	worldboss = "Boss",
	trivial = "Trivial",
	minus = "Minion",
}

local CLASSIFICATION_COLOR = {
	elite = { 1, 0.82, 0 },
	rareelite = { 0.8, 0.8, 1 },
	rare = { 0.8, 0.8, 1 },
	worldboss = { 1, 0.5, 0.25 },
}

local frame, ghost, prevButton, nextButton
local nameText, detailText, zoneText, captureText, statusText, counterText, emptyText
local view, pos = {}, 0

-- Pale blue-white lighting makes the model read as a spirit.
local function Ghostify(model)
	model:SetAlpha(model.ghostAlpha or GHOST_ALPHA)
	pcall(model.SetLight, model, true, {
		omnidirectional = false,
		point = CreateVector3D(0, 0, -1),
		ambientIntensity = 1,
		ambientColor = CreateColor(0.55, 0.75, 1),
		diffuseIntensity = 0.8,
		diffuseColor = CreateColor(0.7, 0.85, 1),
	})
end

local TAB_BOUND, TAB_RELEASED = 1, 2
local tabs = {}

local function UpdateTabLabels()
	local bound, released = 0, 0
	for _, soul in ipairs(ns.db.souls) do
		if soul.released then released = released + 1 else bound = bound + 1 end
	end
	tabs[TAB_BOUND]:SetText(("Bound (%d)"):format(bound))
	tabs[TAB_RELEASED]:SetText(("Released (%d)"):format(released))
	for _, tab in ipairs(tabs) do PanelTemplates_TabResize(tab, 0) end
end

-- Bound souls page in capture order; released souls in the order they were spent.
local function RebuildView()
	wipe(view)
	local wantReleased = ns.db.tab == TAB_RELEASED
	for i, soul in ipairs(ns.db.souls) do
		if (soul.released ~= nil) == wantReleased then
			view[#view + 1] = i
		end
	end
	if wantReleased then
		local souls = ns.db.souls
		table.sort(view, function(a, b)
			if souls[a].released ~= souls[b].released then return souls[a].released < souls[b].released end
			return a < b
		end)
	end
	UpdateTabLabels()
end

local function DescribeLevel(soul)
	local level = (soul.level and soul.level > 0) and tostring(soul.level) or "??"
	local parts = { "Level " .. level }
	if soul.isPlayer then
		if soul.race then parts[#parts + 1] = soul.race end
		local className = soul.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[soul.class]
		parts[#parts + 1] = className or "Player"
	else
		if CLASSIFICATION[soul.classification] then parts[#parts + 1] = CLASSIFICATION[soul.classification] end
		if soul.creatureType then parts[#parts + 1] = soul.creatureType end
	end
	return table.concat(parts, " ")
end

-- Animation ids from AnimationData: the humanoid emotes, then a few that beasts and
-- other non-humanoids usually have, so every ghost has something to perform.
local EMOTES = { 60, 64, 65, 66, 67, 68, 69, 70, 73, 74, 77, 80, 81, 82, 84 }
local BEAST_EMOTES = { 74, 2, 16 } -- roar, spell cast, unarmed attack
local EMOTE_SECONDS = 3
local EMOTE_CLICKS_MIN, EMOTE_CLICKS_MAX = 3, 8
local clicksUntilEmote = math.random(EMOTE_CLICKS_MIN, EMOTE_CLICKS_MAX)

local function PickEmote()
	local available = {}
	for _, list in ipairs({ EMOTES, BEAST_EMOTES }) do
		for _, anim in ipairs(list) do
			if not ghost.HasAnimation or ghost:HasAnimation(anim) then
				available[#available + 1] = anim
			end
		end
		if #available > 0 then break end
	end
	return available[math.random(#available)]
end

local PUT_DOWN_GEMS_SOUND = 1204

local clinkHandle

-- The clink of a gem being set down in the bags. Each click cuts off the previous
-- clink and starts a fresh one, so rapid clicking never stacks or gets swallowed.
local function PlayClink()
	if clinkHandle then StopSound(clinkHandle) end
	local _, handle = PlaySound(PUT_DOWN_GEMS_SOUND, "SFX", false)
	clinkHandle = handle
end

-- Turn to face the viewer, perform, then go back to idly spinning.
local function Emote()
	local anim = PickEmote()
	if not anim then return end
	local token = {}
	ghost.emoting = token
	ghost:SetFacing(0)
	ghost:SetAnimation(anim)
	C_Timer.After(EMOTE_SECONDS, function()
		if ghost.emoting ~= token then return end
		ghost.emoting = nil
		ghost.facing = 0
		ghost:SetAnimation(0)
	end)
end

-- Players and souls whose identity was hidden have no NPC id to rebuild, so they
-- appear as a generic human ghost.
local function ShowGhost(soul)
	ghost.ghostAlpha = soul.released and RELEASED_ALPHA or GHOST_ALPHA
	ghost:Show()
	ghost:ClearModel()
	ghost.emoting = nil
	ghost:SetCreature(soul.npcID or ns.LOST_SOUL_NPC)
	ghost:SetPortraitZoom(0)
	Ghostify(ghost)
end

local function Refresh()
	if not frame or not frame:IsShown() then return end
	local count = #view
	pos = math.max(math.min(pos, count), count > 0 and 1 or 0)
	prevButton:SetEnabled(pos > 1)
	nextButton:SetEnabled(pos < count)

	if count == 0 then
		ghost:Hide()
		emptyText:Show()
		if ns.db.tab == TAB_RELEASED then
			emptyText:SetText("No souls released yet.\nSpent shards appear here.")
		elseif #ns.db.souls > 0 then
			emptyText:SetText("No souls bound.\nFinish a foe with Drain Soul\nor Shadowburn.")
		else
			emptyText:SetText("No souls captured yet.\nFinish a foe with Drain Soul\nor Shadowburn.")
		end
		for _, fs in ipairs({ nameText, detailText, zoneText, captureText, statusText, counterText }) do
			fs:SetText("")
		end
		return
	end

	emptyText:Hide()
	local soul = ns.db.souls[view[pos]]
	ShowGhost(soul)

	nameText:SetText(soul.name or ns.LOST_SOUL)
	local color = soul.isPlayer and soul.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[soul.class]
	if color then
		nameText:SetTextColor(color.r, color.g, color.b)
	else
		local c = CLASSIFICATION_COLOR[soul.classification] or { 0.85, 0.75, 1 }
		nameText:SetTextColor(c[1], c[2], c[3])
	end

	detailText:SetText(DescribeLevel(soul))
	zoneText:SetText(soul.subzone and (soul.subzone .. ", " .. (soul.zone or "")) or (soul.zone or ""))
	captureText:SetText(("%s  -  you were level %s%s"):format(
		date("%b %d, %Y %H:%M", soul.time),
		soul.playerLevel or "?",
		soul.method and ("  -  " .. soul.method) or ""))

	if soul.released then
		statusText:SetText("Released " .. date("%b %d, %Y", soul.released))
		statusText:SetTextColor(0.55, 0.55, 0.55)
	else
		statusText:SetText("Bound within a Soul Shard")
		statusText:SetTextColor(0.4, 1, 0.5)
	end

	counterText:SetText(("Soul %d of %d"):format(pos, count))
end

local function Step(delta)
	pos = pos + delta
	Refresh()
end

local function MakeArrow(direction)
	local button = CreateFrame("Button", nil, frame)
	button:SetSize(32, 32)
	local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. (direction < 0 and "Prev" or "Next") .. "Page-"
	button:SetNormalTexture(base .. "Up")
	button:SetPushedTexture(base .. "Down")
	button:SetDisabledTexture(base .. "Disabled")
	button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	button:SetScript("OnClick", function()
		PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_PAGE_TURN or 836)
		Step(direction)
	end)
	return button
end

local function Text(template, point, relativeTo, relativePoint, y)
	local fs = frame:CreateFontString(nil, "OVERLAY", template)
	fs:SetPoint(point, relativeTo, relativePoint, 0, y)
	fs:SetWidth(300)
	fs:SetJustifyH("CENTER")
	return fs
end

local function Build()
	frame = CreateFrame("Frame", "SoulJournalFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(340, 480)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()
	tinsert(UISpecialFrames, "SoulJournalFrame")

	local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:ClearAllPoints()
	title:SetPoint("TOP", 0, -5)
	title:SetText("Soul Journal")

	-- The shard is built in three layers: the solid crystal body behind, the ghost in
	-- the middle, and a translucent crystal face in front so the spirit looks trapped.
	local shard = CreateFrame("Frame", nil, frame)
	shard:SetSize(240, 240)
	shard:SetPoint("TOP", 0, -32)
	shard:EnableMouseWheel(true)
	shard:SetScript("OnMouseWheel", function(_, delta) Step(-delta) end)

	local glow = shard:CreateTexture(nil, "BACKGROUND", nil, -8)
	glow:SetAllPoints()
	glow:SetTexture(MEDIA .. "ShardGlow")
	glow:SetBlendMode("ADD")
	local pulse = glow:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local fade = pulse:CreateAnimation("Alpha")
	fade:SetFromAlpha(0.35)
	fade:SetToAlpha(1)
	fade:SetDuration(1.8)
	fade:SetSmoothing("IN_OUT")
	pulse:Play()

	local body = shard:CreateTexture(nil, "BACKGROUND")
	body:SetAllPoints()
	body:SetTexture(MEDIA .. "ShardBack")

	-- Sized to the crystal's dark heart, so the ghost stays inside the shard's outline.
	ghost = CreateFrame("PlayerModel", nil, shard)
	ghost:SetPoint("TOPLEFT", 50, -46)
	ghost:SetPoint("BOTTOMRIGHT", -50, 30)
	ghost:SetFrameLevel(shard:GetFrameLevel() + 1)
	ghost.facing, ghost.bob = 0, 0
	ghost:SetScript("OnUpdate", function(self, elapsed)
		if not self.emoting then
			self.facing = self.facing + elapsed * 0.4
			self:SetFacing(self.facing)
		end
		self.bob = self.bob + elapsed * 1.6
		self:SetPosition(0, 0, math.sin(self.bob) * 0.04)
	end)

	shard:EnableMouse(true)
	shard:SetScript("OnMouseDown", function()
		if #view == 0 then return end
		PlayClink()
		clicksUntilEmote = clicksUntilEmote - 1
		if clicksUntilEmote <= 0 then
			clicksUntilEmote = math.random(EMOTE_CLICKS_MIN, EMOTE_CLICKS_MAX)
			Emote()
		end
	end)


	local face = CreateFrame("Frame", nil, shard)
	face:SetAllPoints()
	face:SetFrameLevel(shard:GetFrameLevel() + 2)

	local facets = face:CreateTexture(nil, "ARTWORK")
	facets:SetAllPoints()
	facets:SetTexture(MEDIA .. "ShardFront")

	emptyText = face:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("CENTER")
	emptyText:SetWidth(200)

	prevButton = MakeArrow(-1)
	prevButton:SetPoint("RIGHT", shard, "LEFT", -6, 0)
	nextButton = MakeArrow(1)
	nextButton:SetPoint("LEFT", shard, "RIGHT", 6, 0)

	nameText = Text("GameFontNormalLarge", "TOP", shard, "BOTTOM", -14)
	detailText = Text("GameFontHighlight", "TOP", nameText, "BOTTOM", -6)
	zoneText = Text("GameFontHighlightSmall", "TOP", detailText, "BOTTOM", -6)
	captureText = Text("GameFontDisableSmall", "TOP", zoneText, "BOTTOM", -4)
	statusText = Text("GameFontNormal", "TOP", captureText, "BOTTOM", -10)

	counterText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	counterText:SetPoint("BOTTOMRIGHT", -14, 14)

	-- Tabs hang off the bottom edge like the character sheet's; PanelTemplates expects
	-- them to be named <frame>Tab<n>.
	ns.db.onlyBound = nil
	if ns.db.tab ~= TAB_RELEASED then ns.db.tab = TAB_BOUND end
	for i = 1, 2 do
		local tab = CreateFrame("Button", "SoulJournalFrameTab" .. i, frame, "PanelTabButtonTemplate")
		tab:SetID(i)
		tab:SetScript("OnClick", function(self)
			PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
			ns.db.tab = self:GetID()
			PanelTemplates_SetTab(frame, ns.db.tab)
			RebuildView()
			pos = #view
			Refresh()
		end)
		tabs[i] = tab
	end
	tabs[TAB_BOUND]:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
	tabs[TAB_RELEASED]:SetPoint("LEFT", tabs[TAB_BOUND], "RIGHT", 4, 0)
	PanelTemplates_SetNumTabs(frame, 2)
	PanelTemplates_SetTab(frame, ns.db.tab)

	frame:SetScript("OnShow", function()
		RebuildView()
		pos = #view
		Refresh()
	end)
end

function ns.Toggle()
	if not ns.db then return end
	if not frame then Build() end
	frame:SetShown(not frame:IsShown())
end

-- Called by Core whenever souls are added or released. A new capture jumps the Bound
-- tab to it; a new release does the same on the Released tab.
function ns.OnSoulsChanged(captured)
	if not frame or not frame:IsShown() then return end
	RebuildView()
	local onBound = ns.db.tab == TAB_BOUND
	if (captured and onBound) or (captured == false and not onBound) then
		pos = #view
	end
	Refresh()
end
