-- ===========================================================================
-- ABN_Notify.lua
-- Module:   ABN_Notify (global table), gameplay only, include("ABN_Notify").
-- Owner:    WP4 (PLAN 8; pattern of EFV_Notify / TX_Notify, S5 verified).
--
-- An in-memory FIFO of notifications (never saved) and the flush that sends
-- them with NotificationManager.SendNotification. Text is looked up in
-- gameplay at flush time from <base>_MESSAGE / <base>_SUMMARY.
--
-- API
--   ABN_Notify.Queue(kind, owner, args, x, y)
--     kind   one of the strings below.
--     owner  player ID of the abandoning player (or the former owner).
--     args   table with the fields named below (any other field is ignored).
--     x, y   plot of the abandoned city (numbers) or nil for no location.
--     Resolves the recipients now (HasMet and revealed plots are read at
--     queue time) and appends one entry per recipient. Returns nil.
--   ABN_Notify.Flush()  sends the queue in order. Call it last in every
--     handler and at the end of the turn pipeline.
--   ABN_Notify.Count(), ABN_Notify.Discard(), ABN_Notify.KINDS (tests).
--
-- Kinds (the exact strings), the notification type they send, who gets it,
-- and the args fields each one reads. "city" is the raw pCity:GetName()
-- (a text key or plain text; Queue runs Locale.Lookup on it, so queue
-- BEFORE the city is removed, or pass the name saved earlier). Numbers are
-- plain numbers.
--
--   STARTED       type ABN_NOTIF_STARTED. Owner + met humans.
--                 args: city, turns (T, the countdown length).
--   TICK          type ABN_NOTIF_TICK. Owner only (expires at end of turn).
--                 args: city, turns (turns left).
--   CANCELLED     type ABN_NOTIF_CANCELLED. Owner + met humans (player cancel).
--                 args: city, debuffTurns (how many more turns the loyalty
--                 penalty lasts, DECISIONS #12).
--   AUTOCANCEL    type ABN_NOTIF_AUTOCANCEL. Owner + met humans (blocking
--                 condition 1 or 2 appeared, spec 1.6; no cooldown).
--                 args: city, reason (an ABN_Rules code: ENEMY_NEAR, DAMAGED,
--                 SIEGE, ...; unknown or nil gives a generic reason),
--                 debuffTurns.
--   LOST          type ABN_NOTIF_AUTOCANCEL (own text variant). Owner + met
--                 humans. The city was captured, flipped or traded during the
--                 countdown (DECISIONS #13); owner is the FORMER owner.
--                 args: city, debuffTurns.
--   REMOVED       type ABN_NOTIF_REMOVED. Owner + met humans.
--                 args: city, debuffTurns (turns the penalty still runs, T).
--   DEBUFF_ENDED  type ABN_NOTIF_DEBUFF_ENDED. Owner only (expires end of turn).
--                 args: city (the abandoned city's saved name). x, y optional.
--
-- Text keys (ABN_Text_Core.xml), "_MESSAGE" and "_SUMMARY" appended:
--   others:  LOC_ABN_NOTIF_<TYPE>  (STARTED, CANCELLED, AUTOCANCEL, REMOVED)
--            LOC_ABN_NOTIF_AUTOCANCEL_LOST (LOST)
--   owner:   the same base plus "_OWN"; TICK and DEBUFF_ENDED have only the
--            base key (owner only).
--   LOC_ABN_CANCEL_REASON_<code>, LOC_ABN_CANCEL_REASON_GENERIC,
--   LOC_ABN_PLAYER_GENERIC.
--
-- Recipients (PLAN 8, DECISIONS #16, S5 result):
--   * owner: if human; always gets the location.
--   * others: each alive human major v, ascending ID, v ~= owner, with
--     Players[v]:GetDiplomacy():HasMet(owner) (works in hotseat, S5).
--     They get a location only if PlayersVisibility[v]:IsRevealed(x, y) is
--     true (pcall-guarded; any failure means no location). Their text names
--     the civ with the short civ description (LOC_ABN_PLAYER_GENERIC if the
--     config read fails).
--   * AI, city-states, Free Cities and barbarians never get one.
--
-- Data sent: MESSAGE, SUMMARY, LOCATION (when given), AlwaysUnique = true,
-- ABN_Turn, ABN_Kind. No AlwaysAutoActivate (PLAN 8).
--
-- MP: no pairs() over game state, no RNG, no Game.GetLocalPlayer. Only called
-- from synced handlers.
-- ===========================================================================

if ABN_Notify ~= nil and ABN_Notify.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")

ABN_Notify = {}

-- kind -> type and text key suffixes. The key is TEXT_PREFIX .. suffix .. "_MESSAGE" / "_SUMMARY".
local TEXT_PREFIX = "LOC_ABN_NOTIF_"
local KINDS = {
	STARTED = {
		typeName = "ABN_NOTIF_STARTED", base = "STARTED",
		ownBase = "STARTED_OWN", toOthers = true,
	},
	TICK = {
		typeName = "ABN_NOTIF_TICK", base = "TICK",
		ownBase = "TICK", toOthers = false,
	},
	CANCELLED = {
		typeName = "ABN_NOTIF_CANCELLED", base = "CANCELLED",
		ownBase = "CANCELLED_OWN", toOthers = true,
	},
	AUTOCANCEL = {
		typeName = "ABN_NOTIF_AUTOCANCEL", base = "AUTOCANCEL",
		ownBase = "AUTOCANCEL_OWN", toOthers = true,
	},
	LOST = {
		typeName = "ABN_NOTIF_AUTOCANCEL", base = "AUTOCANCEL_LOST",
		ownBase = "AUTOCANCEL_LOST_OWN", toOthers = true,
	},
	REMOVED = {
		typeName = "ABN_NOTIF_REMOVED", base = "REMOVED",
		ownBase = "REMOVED_OWN", toOthers = true,
	},
	DEBUFF_ENDED = {
		typeName = "ABN_NOTIF_DEBUFF_ENDED", base = "DEBUFF_ENDED",
		ownBase = "DEBUFF_ENDED", toOthers = false,
	},
}
ABN_Notify.KINDS = KINDS

-- Cancel reason code -> text key suffix (ABN_Rules.CODES).
local REASON_PREFIX = "LOC_ABN_CANCEL_REASON_"
local REASON_KEYS = {
	ACTIVE = "ACTIVE",
	COOLDOWN = "COOLDOWN",
	CAPITAL = "CAPITAL",
	LAST_CITY = "LAST_CITY",
	ORIGINAL_CAPITAL = "ORIGINAL_CAPITAL",
	SIEGE = "SIEGE",
	DAMAGED = "DAMAGED",
	ENEMY_NEAR = "ENEMY_NEAR",
}
local REASON_GENERIC = "GENERIC"
local PLAYER_GENERIC = "LOC_ABN_PLAYER_GENERIC"

-- FIFO of queued entries (module memory, never saved).
local m_Queue = {}

-- ===========================================================================
-- Helpers
-- ===========================================================================
local function Text(key, ...)
	local args = { ... }
	local n = select("#", ...)
	local ok, s = pcall(function()
		return Locale.Lookup(key, unpack(args, 1, n))
	end)
	if ok and type(s) == "string" then
		return s
	end
	ABN_Util.Log("Notify", "ERROR Locale.Lookup(%s) failed: %s", tostring(key), tostring(s))
	return tostring(key)
end

local function Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return -1
end

-- true if pid is a living human major. Any error -> false.
local function IsHumanMajor(pid)
	if type(pid) ~= "number" or pid < 0 then
		return false
	end
	local ok, res = pcall(function()
		local p = Players[pid]
		if p == nil then
			return false
		end
		return p:IsAlive() == true and p:IsMajor() == true and p:IsHuman() == true
	end)
	return ok and res == true
end

local function HasMet(viewer, owner)
	local ok, met = pcall(function()
		return Players[viewer]:GetDiplomacy():HasMet(owner)
	end)
	return ok and met == true
end

-- true only when the viewer has revealed the plot (S5 / DECISIONS #16).
local function Revealed(viewer, x, y)
	local ok, v = pcall(function()
		return PlayersVisibility[viewer]:IsRevealed(x, y)
	end)
	return ok and v == true
end

local function ValidPlot(x, y)
	return type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0
end

local function Num(v)
	if type(v) == "number" then
		return v
	end
	return 0
end

-- The abandoning civ as a short name (same for every viewer who has met it).
local function CivLabel(owner)
	local ok, key = pcall(function()
		return PlayerConfigurations[owner]:GetCivilizationShortDescription()
	end)
	if ok and type(key) == "string" and key ~= "" then
		local s = Text(key)
		if s ~= "" then
			return s
		end
	end
	return Text(PLAYER_GENERIC)
end

local function CityLabel(raw)
	if type(raw) ~= "string" or raw == "" then
		return ""
	end
	return Text(raw)
end

local function ReasonText(code)
	return Text(REASON_PREFIX .. (REASON_KEYS[code] or REASON_GENERIC))
end

-- Ascending IDs of the alive players (the engine order is not relied on).
local function AliveAscending()
	local ids = {}
	local ok, list = pcall(function() return PlayerManager.GetAliveIDs() end)
	if ok and type(list) == "table" then
		for _, id in ipairs(list) do
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

-- Lookup arguments for the owner's text.
local function OwnArgs(kind, city, args)
	if kind == "STARTED" or kind == "TICK" then
		return { city, Num(args.turns) }
	elseif kind == "AUTOCANCEL" then
		return { city, ReasonText(args.reason), Num(args.debuffTurns) }
	elseif kind == "CANCELLED" or kind == "LOST" or kind == "REMOVED" then
		return { city, Num(args.debuffTurns) }
	end
	return { city }
end

-- Lookup arguments for another civ's text.
local function OtherArgs(kind, civ, city, args)
	if kind == "STARTED" then
		return { civ, city, Num(args.turns) }
	end
	return { civ, city }
end

-- A same-batch entry for the same recipient, kind and city is replaced.
local function FindDuplicate(entry)
	for i, q in ipairs(m_Queue) do
		if q.pid == entry.pid and q.kind == entry.kind and q.cityKey == entry.cityKey
				and q.x == entry.x and q.y == entry.y then
			return i
		end
	end
	return nil
end

local function Add(entry)
	local dup = FindDuplicate(entry)
	if dup ~= nil then
		m_Queue[dup] = entry
	else
		m_Queue[#m_Queue + 1] = entry
	end
end

-- ===========================================================================
-- Public API
-- ===========================================================================
function ABN_Notify.Queue(kind, owner, args, x, y)
	local k = KINDS[kind]
	if k == nil then
		ABN_Util.Log("Notify", "ERROR queue: unknown kind %s", tostring(kind))
		return nil
	end
	if type(owner) ~= "number" then
		ABN_Util.Log("Notify", "ERROR queue: bad owner %s for kind %s", tostring(owner), kind)
		return nil
	end
	args = args or {}
	local city = CityLabel(args.city)
	local turn = Turn()
	local hasPlot = ValidPlot(x, y)

	-- The owner: always the location.
	if IsHumanMajor(owner) then
		Add({
			pid = owner, kind = kind, typeName = k.typeName, key = TEXT_PREFIX .. k.ownBase,
			args = OwnArgs(kind, city, args), cityKey = city,
			x = hasPlot and x or nil, y = hasPlot and y or nil, turn = turn,
		})
	end

	-- Other humans who have met the owner: the location only if revealed.
	if k.toOthers then
		local civ = nil
		for _, v in ipairs(AliveAscending()) do
			if v ~= owner and IsHumanMajor(v) and HasMet(v, owner) then
				if civ == nil then
					civ = CivLabel(owner)
				end
				local showAt = hasPlot and Revealed(v, x, y)
				Add({
					pid = v, kind = kind, typeName = k.typeName, key = TEXT_PREFIX .. k.base,
					args = OtherArgs(kind, civ, city, args), cityKey = city,
					x = showAt and x or nil, y = showAt and y or nil, turn = turn,
				})
			end
		end
	end
	return nil
end

-- Sends one entry. Errors are caught by Flush.
local function SendEntry(entry)
	local typeRow = GameInfo.Types[entry.typeName]
	if typeRow == nil or typeRow.Hash == nil then
		ABN_Util.Log("Notify", "ERROR unknown notification type %s (missing Types row); pid=%d not notified",
			tostring(entry.typeName), entry.pid)
		return false
	end
	local n = #entry.args
	local data = {}
	data[ParameterTypes.MESSAGE] = Text(entry.key .. "_MESSAGE", unpack(entry.args, 1, n))
	data[ParameterTypes.SUMMARY] = Text(entry.key .. "_SUMMARY", unpack(entry.args, 1, n))
	if ValidPlot(entry.x, entry.y) then
		data[ParameterTypes.LOCATION] = { x = entry.x, y = entry.y }
	end
	data.AlwaysUnique = true
	data.ABN_Turn = entry.turn
	data.ABN_Kind = entry.kind
	NotificationManager.SendNotification(entry.pid, typeRow.Hash, data)
	return true
end

function ABN_Notify.Flush()
	local queue = m_Queue
	m_Queue = {}
	if #queue == 0 then
		return nil
	end
	local sent, failed = 0, 0
	for _, entry in ipairs(queue) do
		local ok, res = pcall(SendEntry, entry)
		if ok and res then
			sent = sent + 1
		else
			failed = failed + 1
			if not ok then
				ABN_Util.Log("Notify", "ERROR send failed pid=%d type=%s: %s", entry.pid, entry.typeName, tostring(res))
			end
		end
	end
	ABN_Util.Log("Notify", "flush sent=%d failed=%d", sent, failed)
	return nil
end

-- Number of queued entries (tests, diagnostics).
function ABN_Notify.Count()
	return #m_Queue
end

-- Drops the queue without sending.
function ABN_Notify.Discard()
	m_Queue = {}
	return nil
end

ABN_Notify.LOADED = 1
