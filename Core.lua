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
local SPARK_MEMORY = 300     -- how long sparks wait for their creature's soul to follow
local SPEND_GRACE = 2        -- a spent shard can leave the bags a moment after the cast ends

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

-- Spells that cost a Soul Shard. Most ranks have their own name ("Create Healthstone
-- (Minor)"), so every rank is listed; ids this client doesn't have are skipped.
local SHARD_SPELLS = {}
for _, id in ipairs({
	6201, 6202, 5699, 11729, 11730,      -- Create Healthstone
	693, 20752, 20755, 20756, 20757,     -- Create Soulstone
	6366, 17951, 17952, 17953,           -- Create Firestone
	2362, 17727, 17728,                  -- Create Spellstone
	697, 712, 691, 1122, 18540,          -- Summon Voidwalker/Succubus/Felhunter, Inferno, Ritual of Doom
	698,                                 -- Ritual of Summoning
	6353, 17877,                         -- Soulfire, Shadowburn
}) do
	local name = C_Spell.GetSpellName(id)
	if name then SHARD_SPELLS[name] = true end
end

local function ShardSpellName(spellID)
	spellID = Safe(spellID)
	local name = spellID and C_Spell.GetSpellName(spellID)
	return name and SHARD_SPELLS[name] and name or nil
end

-- "%s dies, you gain %d experience." -> a Lua pattern capturing the mob's name.
local XP_PATTERN = COMBATLOG_XPGAIN_FIRSTPERSON and "^" .. COMBATLOG_XPGAIN_FIRSTPERSON
	:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	:gsub("%%s", "(.+)")
	:gsub("%%d", "%%d+")

local ready = false
local lastCount = 0
local channel     -- { snap, stopped, soul } for the current or most recent Drain Soul
local burn        -- { snap, time } for the most recent Shadowburn
local plainTarget -- snapshot of the current target taken while its data was readable
local lastXP      -- { name, time } from the most recent kill XP message
local incomplete  -- newest soul still missing details, to finish once combat ends
local spending    -- { name, castGUID, ended } for the current or most recent shard-costing cast
local spentGUID   -- cast already credited with a release, so its late events don't reopen it

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
-- channel stays open for as many shards as it yields. The third value says whether the
-- channel was still running, which a kill would have ended.
local function TakeCapture(now)
	if channel and (not channel.stopped or now - channel.stopped <= DRAIN_GRACE) then
		return channel.snap, DRAIN_SOUL, not channel.stopped
	end
	if burn and now - burn.time <= SHADOWBURN_WINDOW then
		local snap = burn.snap
		burn = nil
		return snap, SHADOWBURN
	end
end

-- true for a shard from the kill, false for one from a Drain Soul tick, nil if unsure.
-- Death is the best evidence when readable, then a kill XP message for that name, then
-- whether the channel was still running.
local function WasKill(snap, method, channeling)
	if method == SHADOWBURN then return true end
	local guid = Safe(UnitGUID("target"))
	if guid and snap.guid and guid == snap.guid then
		local dead = Safe(UnitIsDead("target"))
		if dead ~= nil then return dead end
	end
	local recentXP = lastXP and GetTime() - lastXP.time <= XP_WINDOW
	if recentXP and snap.name and lastXP.name == snap.name then return true end
	if channeling then return false end
end

local function CountShards()
	return C_Item.GetItemCount(SOUL_SHARD_ITEM, true) or 0
end

-- Each record is one creature. A shard from the kill is its soul; shards from Drain Soul
-- ticks before that are sparks of it. A record with sparks but no soul (the creature
-- died some other way, or got away) is marked sparkOnly.
local function BoundSouls()
	local bound = {}
	for _, soul in ipairs(ns.db.souls) do
		if not soul.released then bound[#bound + 1] = soul end
	end
	return bound
end
ns.BoundSouls = BoundSouls

-- How many of the shards in the bags the journal accounts for.
local function BoundShards()
	local n = 0
	for _, soul in ipairs(BoundSouls()) do
		n = n + (soul.sparkOnly and 0 or 1) + (soul.sparks or 0)
	end
	return n
end

local function ApplySnapshot(soul, snap)
	for _, key in ipairs({ "name", "level", "classification", "creatureType", "isPlayer", "class", "race", "guid" }) do
		if soul[key] == nil then soul[key] = snap[key] end
	end
	soul.npcID = soul.npcID or NpcIDFromGUID(snap.guid)
end

-- The record that sparks from this creature already went to, if its soul hasn't followed.
local function FindSparked(snap)
	local soul = channel and channel.soul
	if soul and soul.sparkOnly and not soul.released then return soul end
	if not snap.guid then return end
	local now = time()
	for i = #ns.db.souls, 1, -1 do
		soul = ns.db.souls[i]
		if now - soul.time > SPARK_MEMORY then return end
		if soul.sparkOnly and not soul.released and soul.guid == snap.guid then return soul end
	end
end

local function Stamp(soul, method)
	local subzone = GetSubZoneText()
	soul.zone = GetRealZoneText()
	soul.subzone = subzone ~= "" and subzone or nil
	soul.time = time()
	soul.playerLevel = UnitLevel("player")
	soul.method = method
end

-- Capture lines, picked at random but never the same one twice running. {what} is
-- "a soul spark" or "the soul", {who} the creature.
local CAPTURE_LINES = {
	"Your spectral claws rip {what} from {who}.",
	"You tear {what} loose from {who}.",
	"You siphon {what} out of {who}.",
	"{who} lets out a hollow wail as you claim {what}.",
	"Shadow coils around {who} and drags back {what}.",
	"You wrench {what} from {who} and seal it away.",
}
local lastLine

local function AnnounceCapture(what, who)
	local pick
	repeat pick = math.random(#CAPTURE_LINES) until pick ~= lastLine or #CAPTURE_LINES == 1
	lastLine = pick
	local line = CAPTURE_LINES[pick]:gsub("{what}", what):gsub("{who}", who)
	Print(line)
end

local function AddSoul(snap, method, channeling)
	-- Copy so a long Drain Soul channel's later shards don't share one table.
	snap = Merge(CopyTable(snap or {}), Snapshot("target")) or {}
	local spark = WasKill(snap, method, channeling) == false
	-- A tick shard's target is still alive, so a recent XP message names some other mob.
	if not snap.name and not spark and lastXP and GetTime() - lastXP.time <= XP_WINDOW then
		snap.name = lastXP.name
	end

	local soul = FindSparked(snap)
	if not soul then
		soul = { sparkOnly = spark or nil }
		Stamp(soul, method)
		table.insert(ns.db.souls, soul)
	elseif not spark then
		-- The soul follows its sparks: the record now dates from the kill.
		soul.sparkOnly = nil
		Stamp(soul, method)
	end
	ApplySnapshot(soul, snap)
	if channel and method == DRAIN_SOUL then channel.soul = soul end

	if not (soul.name and soul.level and soul.npcID) and not soul.isPlayer then
		incomplete = { soul = soul }
	end
	local who = "|cffffffff" .. (soul.name or ns.LOST_SOUL) .. "|r"
	if spark then
		soul.sparks = (soul.sparks or 0) + 1
		AnnounceCapture("|cffc9a6ffa soul spark|r", who)
	else
		local level = (soul.level and soul.level > 0) and soul.level or "??"
		AnnounceCapture("|cffc9a6ffthe soul|r", ("%s (level %s)"):format(who, level))
	end
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

-- What took the shard: a shard-costing spell cast just now, or an open vendor, trade or
-- mail window. Anything else (deleting it, or a spell not in the list) stays unknown.
local function TakeSpender(now)
	if spending and (not spending.ended or now - spending.ended <= SPEND_GRACE) then
		local name = spending.name
		spentGUID = spending.castGUID
		spending = nil
		return name
	end
	if MerchantFrame and MerchantFrame:IsShown() then return nil, "sold" end
	if TradeFrame and TradeFrame:IsShown() then return nil, "traded" end
	if SendMailFrame and SendMailFrame:IsShown() then return nil, "mailed" end
end

local function OnShardSpell(spellID, castGUID, ended)
	local name = ShardSpellName(spellID)
	castGUID = Safe(castGUID)
	if not name or (castGUID and castGUID == spentGUID) then return end
	if spending and spending.castGUID == castGUID and castGUID then
		spending.ended = spending.ended or ended
	else
		spending = { name = name, castGUID = castGUID, ended = ended }
	end
end

local function OnCastEnded(castGUID)
	castGUID = Safe(castGUID)
	if spending and not spending.ended and (not castGUID or spending.castGUID == castGUID) then
		spending.ended = GetTime()
	end
end

local function Release(soul, now, spell, how)
	soul.released = now
	soul.releasedBy = spell
	soul.releasedHow = how
end

-- Shards are indistinguishable, so spend them in a fixed order: untracked shards from
-- before the addon was installed, then sparks, then whole souls, oldest first each time.
-- Kept souls and their sparks sit out until every other shard has been spent.
local function ReleaseSouls(n, prevCount, spell, how)
	local untracked = math.max(0, prevCount - BoundShards())
	n = n - math.min(n, untracked)
	if n <= 0 then return end
	local now = time()
	local bound = BoundSouls()
	for _, kept in ipairs({ false, true }) do
		for _, soul in ipairs(bound) do
			if n <= 0 then break end
			local take = (soul.kept == true) == kept and math.min(n, soul.sparks or 0) or 0
			if take > 0 then
				soul.sparks = soul.sparks - take
				soul.sparksSpent = (soul.sparksSpent or 0) + take
				n = n - take
				if soul.sparkOnly and soul.sparks == 0 then Release(soul, now, spell, how) end
			end
		end
		for _, soul in ipairs(bound) do
			if n <= 0 then break end
			if (soul.kept == true) == kept and not soul.sparkOnly and not soul.released then
				Release(soul, now, spell, how)
				n = n - 1
			end
		end
	end
	ns.OnSoulsChanged(false)
end

local function OnBagsChanged()
	if not ready then return end
	local count = CountShards()
	local delta = count - lastCount
	if delta > 0 then
		for _ = 1, delta do
			local snap, method, channeling = TakeCapture(GetTime())
			if not method then break end
			AddSoul(snap, method, channeling)
		end
	elseif delta < 0 then
		ReleaseSouls(-delta, lastCount, TakeSpender(GetTime()))
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

events:SetScript("OnEvent", function(self, event, arg1, castGUID, spellID)
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
		self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
		self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
		self:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
		self:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
		self:RegisterEvent("BAG_UPDATE_DELAYED")
		self:RegisterEvent("PLAYER_TARGET_CHANGED")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
		plainTarget = Snapshot("target")
		-- Give the client a moment to finish loading bag contents before trusting counts.
		C_Timer.After(3, function()
			lastCount = CountShards()
			local bound = BoundShards()
			if lastCount < bound then
				ReleaseSouls(bound - lastCount, bound)
			end
			ready = true
		end)
	elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
		if IsSpell(spellID, DRAIN_SOUL) then
			channel = { snap = TargetSnapshot() }
		end
		OnShardSpell(spellID, castGUID)
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if channel and not channel.stopped then channel.stopped = GetTime() end
		OnCastEnded(castGUID)
	elseif event == "UNIT_SPELLCAST_START" then
		OnShardSpell(spellID, castGUID)
	elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED"
		or event == "UNIT_SPELLCAST_INTERRUPTED" then
		OnCastEnded(castGUID)
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if IsSpell(spellID, SHADOWBURN) then
			burn = { snap = TargetSnapshot(), time = GetTime() }
		end
		OnShardSpell(spellID, castGUID, GetTime())
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
	local souls, sparks, newest = 0, 0, nil
	for _, soul in ipairs(BoundSouls()) do
		if not soul.sparkOnly then
			souls = souls + 1
			newest = soul
		end
		sparks = sparks + (soul.sparks or 0)
	end
	if newest then
		tooltip:AddLine(("Newest soul: %s"):format(newest.name or ns.LOST_SOUL), 0.75, 0.6, 1)
	end
	local held = ("%d recorded souls"):format(souls)
	if sparks > 0 then held = held .. (" and %d sparks"):format(sparks) end
	tooltip:AddLine(held .. " bound  -  Right-click to open Soul Journal", 0.6, 0.45, 0.9)
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
