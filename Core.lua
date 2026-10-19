local ADDON, ns = ...

-- WoW Forever (interface 16001) runs Midnight's addon restrictions: the combat log is a
-- forbidden event, and unit data can come back as "secret" values in combat or inside
-- instances that addons may not compare, branch on or save. Captures are inferred from
-- our own Drain Soul / Shadowburn casts plus a Soul Shard landing in the bags, and every
-- unit value is passed through Safe() before use.

local SOUL_SHARD_ITEM = 6265
local DRAIN_GRACE = 3        -- a shard can land a moment after the Drain Soul channel ends
local SHADOWBURN_WINDOW = 6  -- Shadowburn grants a shard if the target dies within 5s of the cast
local XP_WINDOW = 3          -- how recent an XP message must be to name the captured soul

ns.SOUL_SHARD_ITEM = SOUL_SHARD_ITEM
ns.LOST_SOUL = "Lost Soul"
ns.LOST_SOUL_NPC = 392 -- Captain Grayson, the human ghost at the Westfall lighthouse

local function Safe(value)
	if value ~= nil and issecretvalue(value) then return nil end
	return value
end

local DRAIN_SOUL = C_Spell.GetSpellName(1120)
local SHADOWBURN = C_Spell.GetSpellName(17877)

local function IsSpell(spellID, name)
	spellID = Safe(spellID)
	return spellID ~= nil and C_Spell.GetSpellName(spellID) == name
end

-- "%s dies, you gain %d experience." -> a Lua pattern capturing the mob's name.
local XP_PATTERN = COMBATLOG_XPGAIN_FIRSTPERSON and "^" .. COMBATLOG_XPGAIN_FIRSTPERSON
	:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	:gsub("%%s", "(.+)")
	:gsub("%%d", "%%d+")

local ready = false
local lastCount = 0
local channel     -- { snap, stopped } for the current or most recent Drain Soul
local burn        -- { snap, time } for the most recent Shadowburn
local plainTarget -- snapshot of the current target taken while its data was readable
local lastXP      -- { name, time } from the most recent kill XP message
local incomplete  -- newest soul still missing details, to finish once combat ends

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff9b59ffSoul Journal|r: " .. msg)
end
ns.Print = Print

local function NpcIDFromGUID(guid)
	local kind, _, _, _, _, id = strsplit("-", guid or "")
	if kind == "Creature" or kind == "Vehicle" or kind == "Pet" then
		return tonumber(id)
	end
end

local function Snapshot(unit)
	-- UnitExists can itself be secret, so treat "no readable guid or name" as no unit.
	if Safe(UnitIsUnit(unit, "player")) == true then return end
	local guid, name = Safe(UnitGUID(unit)), Safe(UnitName(unit))
	if not guid and not name then return end
	local isPlayer = Safe(UnitIsPlayer(unit))
	local _, classFile = UnitClass(unit)
	return {
		guid = guid,
		name = name,
		level = Safe(UnitLevel(unit)),
		classification = Safe(UnitClassification(unit)),
		creatureType = Safe(UnitCreatureType(unit)),
		isPlayer = isPlayer or nil,
		class = isPlayer and Safe(classFile) or nil,
		race = isPlayer and Safe((UnitRace(unit))) or nil,
	}
end

-- Copy any field `into` is missing from `from`, unless they're clearly different units.
local function Merge(into, from)
	if not from then return into end
	if not into then return from end
	if into.guid and from.guid and into.guid ~= from.guid then return into end
	if into.name and from.name and into.name ~= from.name then return into end
	for key, value in pairs(from) do
		if into[key] == nil then into[key] = value end
	end
	return into
end

local function TargetSnapshot()
	return Merge(Snapshot("target"), plainTarget)
end

-- Drain Soul on Forever can produce shards on its ticks as well as on the kill, so a
-- channel stays open for as many shards as it yields.
local function TakeCapture(now)
	if channel and (not channel.stopped or now - channel.stopped <= DRAIN_GRACE) then
		return channel.snap, DRAIN_SOUL
	end
	if burn and now - burn.time <= SHADOWBURN_WINDOW then
		local snap = burn.snap
		burn = nil
		return snap, SHADOWBURN
	end
end

local function CountShards()
	return C_Item.GetItemCount(SOUL_SHARD_ITEM, true) or 0
end

local function BoundSouls()
	local bound = {}
	for _, soul in ipairs(ns.db.souls) do
		if not soul.released then bound[#bound + 1] = soul end
	end
	return bound
end
ns.BoundSouls = BoundSouls

local function ApplySnapshot(soul, snap)
	for _, key in ipairs({ "name", "level", "classification", "creatureType", "isPlayer", "class", "race" }) do
		if soul[key] == nil then soul[key] = snap[key] end
	end
	soul.npcID = soul.npcID or NpcIDFromGUID(snap.guid)
end

local function AddSoul(snap, method)
	-- Copy so a long Drain Soul channel's later shards don't share one table.
	snap = Merge(CopyTable(snap or {}), Snapshot("target")) or {}
	if not snap.name and lastXP and GetTime() - lastXP.time <= XP_WINDOW then
		snap.name = lastXP.name
	end
	local subzone = GetSubZoneText()
	local soul = {
		zone = GetRealZoneText(),
		subzone = subzone ~= "" and subzone or nil,
		time = time(),
		playerLevel = UnitLevel("player"),
		method = method,
	}
	ApplySnapshot(soul, snap)
	table.insert(ns.db.souls, soul)

	if not (soul.name and soul.level and soul.npcID) and not soul.isPlayer then
		incomplete = { soul = soul }
	end
	local level = (soul.level and soul.level > 0) and soul.level or "??"
	Print(("Captured the soul of |cffffffff%s|r (level %s)."):format(soul.name or ns.LOST_SOUL, level))
	ns.OnSoulsChanged(true)
end

-- Out of combat the corpse's details are readable again; fill in what was hidden,
-- provided the player hasn't switched targets since the capture.
local function FinishIncomplete()
	local pending = incomplete
	incomplete = nil
	if not pending or pending.targetMoved then return end
	local snap = Snapshot("target")
	if not snap then return end
	local soul = pending.soul
	if soul.name and snap.name and soul.name ~= snap.name then return end
	ApplySnapshot(soul, snap)
	ns.OnSoulsChanged(nil)
end

-- Shards are indistinguishable, so assume the oldest one is spent first (untracked
-- shards from before the addon was installed count as oldest).
local function ReleaseSouls(n, prevCount)
	local bound = BoundSouls()
	local untracked = math.max(0, prevCount - #bound)
	n = n - math.min(n, untracked)
	if n <= 0 then return end
	local now = time()
	for i = 1, math.min(n, #bound) do
		bound[i].released = now
	end
	ns.OnSoulsChanged(false)
end

local function OnBagsChanged()
	if not ready then return end
	local count = CountShards()
	local delta = count - lastCount
	if delta > 0 then
		for _ = 1, delta do
			local snap, method = TakeCapture(GetTime())
			if not method then break end
			AddSoul(snap, method)
		end
	elseif delta < 0 then
		ReleaseSouls(-delta, lastCount)
	end
	lastCount = count
end

local function OnXPMessage(msg)
	msg = Safe(msg)
	local name = msg and XP_PATTERN and msg:match(XP_PATTERN)
	if name then lastXP = { name = name, time = GetTime() } end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

events:SetScript("OnEvent", function(self, event, arg1, _, spellID)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		SoulJournalDB = SoulJournalDB or {}
		SoulJournalDB.souls = SoulJournalDB.souls or {}
		ns.db = SoulJournalDB
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_ENTERING_WORLD" then
		self:UnregisterEvent("PLAYER_ENTERING_WORLD")
		if select(2, UnitClass("player")) ~= "WARLOCK" then return end
		self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
		self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
		self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
		self:RegisterEvent("BAG_UPDATE_DELAYED")
		self:RegisterEvent("PLAYER_TARGET_CHANGED")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
		plainTarget = Snapshot("target")
		-- Give the client a moment to finish loading bag contents before trusting counts.
		C_Timer.After(3, function()
			lastCount = CountShards()
			local bound = #BoundSouls()
			if lastCount < bound then
				ReleaseSouls(bound - lastCount, bound)
			end
			ready = true
		end)
	elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
		if IsSpell(spellID, DRAIN_SOUL) then
			channel = { snap = TargetSnapshot() }
		end
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if channel and not channel.stopped then channel.stopped = GetTime() end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if IsSpell(spellID, SHADOWBURN) then
			burn = { snap = TargetSnapshot(), time = GetTime() }
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		-- Usually fires before the pull, while the new target's details are still readable.
		local snap = Snapshot("target")
		plainTarget = snap and snap.name and snap or nil
		if incomplete then incomplete.targetMoved = true end
	elseif event == "PLAYER_REGEN_ENABLED" then
		FinishIncomplete()
	elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
		OnXPMessage(arg1)
	elseif event == "BAG_UPDATE_DELAYED" then
		OnBagsChanged()
	end
end)

-- Right-clicking a Soul Shard in your bags opens the journal. Shards aren't usable,
-- so this only piggybacks on the click; skip it when right-click would sell/trade/bank.
local function IsShown(frame) return frame and frame:IsShown() end

hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
	if IsShown(MerchantFrame) or IsShown(BankFrame) or IsShown(TradeFrame)
		or IsShown(SendMailFrame) or IsShown(AuctionFrame) then
		return
	end
	if C_Container.GetContainerItemID(bag, slot) == SOUL_SHARD_ITEM then
		ns.Toggle()
	end
end)

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
	if tooltip ~= GameTooltip or not ns.db or Safe(data and data.id) ~= SOUL_SHARD_ITEM then return end
	local bound = BoundSouls()
	local newest = bound[#bound]
	if newest then
		tooltip:AddLine(("Newest soul: %s"):format(newest.name or ns.LOST_SOUL), 0.75, 0.6, 1)
	end
	tooltip:AddLine(("%d recorded souls bound  -  Right-click to open Soul Journal"):format(#bound), 0.6, 0.45, 0.9)
end)

StaticPopupDialogs["SOULJOURNAL_CLEAR"] = {
	text = "Erase every soul from your Soul Journal?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		wipe(ns.db.souls)
		ns.OnSoulsChanged(false)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

SLASH_SOULJOURNAL1 = "/souls"
SLASH_SOULJOURNAL2 = "/souljournal"
SlashCmdList.SOULJOURNAL = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "clear" then
		StaticPopup_Show("SOULJOURNAL_CLEAR")
	elseif msg == "help" then
		Print("/souls - open the journal, /souls clear - erase all records")
	else
		ns.Toggle()
	end
end
