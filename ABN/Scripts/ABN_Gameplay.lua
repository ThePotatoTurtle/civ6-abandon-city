-- ===========================================================================
-- ABN_Gameplay.lua
-- Module:   ABN_Gameplay (global table), gameplay entry point
-- Context:  modinfo AddGameplayScripts. Included by no other file, so no
--           load-once guard (EFV_Gameplay pattern).
-- Owner:    WP7 (PLAN 4 requests, PLAN 5 turn pipeline; DECISIONS #2, #3, #8,
--           #11-13, #22-26).
--
-- Requests (UI -> G, EXECUTE_SCRIPT, flat params cityID, x, y):
--   GameEvents.ABN_Start(playerID, p)   ABN_Gameplay.OnStart
--   GameEvents.ABN_Cancel(playerID, p)  ABN_Gameplay.OnCancel
-- playerID (first argument) is the only trusted player. A rejected, duplicate
-- or stale request is a silent no-op with one log line.
--
-- Turn pipeline, GameEvents.OnGameTurnStarted(turn), each step in its own
-- pcall with a log line (one failing step does not stop the rest):
--   pre  ABN_State.Init(), ABN_Rules.RecordOrigCaps()
--   0    ABN_Damage.Refresh(turn)
--   1    auto-cancel: city gone / other owner / other ID -> LOST (DECISIONS
--        #13); last city (DECISIONS #27) or ABN_Rules.ThreatBlocker ->
--        AUTOCANCEL (DECISIONS #2). Both: no
--        cooldown, debuff window ends at CancelEndTurn (DECISIONS #12).
--   2    population: k = turn - start, 1 <= k <= T-1, cut to TargetK once per k
--   3    removals: turn >= start + T -> ABN_Removal.Remove (R-G, G1)
--   4    ABN_Loyalty.Apply(turn) (drops expired windows, queues DEBUFF_ENDED)
--   5    cooldown expiry (endTurn <= turn)
--   6    TICK to each running record's owner
--   end  ABN_Notify.Flush()
--
-- Records (PLAN 3; extra field `city` = the city's name key, saved so the
-- notifications after a capture or removal can still name it):
--   ABN_Active  {owner, cityID, x, y, plot, P0, T, F, D, R, start, lastStep, status, city}
--   ABN_Windows {owner, x, y, D, R, start, endTurn, srcPlot, phase, city}
--
-- Every handler is registered at file load with a literal GameEvents.<Name>.Add
-- call (the API audit matches these) and a log line.
-- MP (PLAN 10): ipairs only, no pairs() over state, no random, no
-- Game.GetLocalPlayer, state written only from these GameEvents handlers.
-- ===========================================================================

include("ABN_Config")
include("ABN_Util")
include("ABN_Rules")
include("ABN_State")
include("ABN_Damage")
include("ABN_Loyalty")
include("ABN_Removal")
include("ABN_Notify")

ABN_Gameplay = {}

local KEY_ACTIVE = ABN_Config.KEY_ACTIVE

local function Log(tag, fmt, ...)
	ABN_Util.Log(tag, fmt, ...)
end

local function IsNum(v)
	return type(v) == "number"
end

-- Runs fn in pcall; logs an ERROR line on failure. Returns ok, result.
local function Try(tag, what, fn, ...)
	local ok, res = pcall(fn, ...)
	if not ok then
		ABN_Util.Error(tag, "%s failed: %s", what, tostring(res))
	end
	return ok, res
end

-- State setup that must precede every rule check (WP3 integration notes).
local function Prepare()
	Try("Init", "ABN_State.Init", ABN_State.Init)
	Try("Init", "ABN_Rules.RecordOrigCaps", ABN_Rules.RecordOrigCaps)
end

local function CityName(pCity)
	local ok, n = pcall(function() return pCity:GetName() end)
	if ok and type(n) == "string" and n ~= "" then
		return n
	end
	return nil
end

-- The debuff window of an Active record (same owner + srcPlot + start).
local function WindowOf(rec)
	return ABN_State.FindWindow(rec.owner, rec.plot, rec.start)
end

-- Ends a running record early (player cancel, auto-cancel, lost city):
-- removes it, shortens its window to CancelEndTurn (never past the full
-- window, DECISIONS #11/#12) with the given phase, and returns the new endTurn.
local function EndRun(rec, turn, phase)
	ABN_State.RemoveActive(rec.owner, rec.plot)
	local full = ABN_Config.DebuffEndTurn(rec.start, rec.T)
	local endTurn = ABN_Config.CancelEndTurn(rec.start, turn)
	if endTurn > full then
		endTurn = full
	end
	local w = WindowOf(rec)
	if w == nil then
		ABN_Util.Error("Run", "window of city %d (owner %d, start %d) missing; recreated",
			rec.cityID, rec.owner, rec.start)
		w = { owner = rec.owner, x = rec.x, y = rec.y, D = rec.D, R = rec.R, start = rec.start,
			srcPlot = rec.plot, city = rec.city }
	end
	w.endTurn = endTurn
	w.phase = phase
	ABN_State.SetWindow(w)
	return endTurn
end

-- DECISIONS #13: the city was lost (captured, flipped, traded, gone).
local function EndLost(rec, turn, why)
	local endTurn = EndRun(rec, turn, "CANCEL")
	Log("Run", "LOST city %d (owner %d) at (%d,%d): %s; debuff until T%d, no cooldown",
		rec.cityID, rec.owner, rec.x, rec.y, why, endTurn)
	ABN_Notify.Queue("LOST", rec.owner, { city = rec.city, debuffTurns = endTurn - turn }, rec.x, rec.y)
end

-- DECISIONS #2: blocking condition 1 or 2 appeared.
local function EndAuto(rec, turn, reason)
	local endTurn = EndRun(rec, turn, "CANCEL")
	Log("Run", "AUTOCANCEL city %d (owner %d) at (%d,%d): %s; debuff until T%d, no cooldown",
		rec.cityID, rec.owner, rec.x, rec.y, reason, endTurn)
	ABN_Notify.Queue("AUTOCANCEL", rec.owner,
		{ city = rec.city, reason = reason, debuffTurns = endTurn - turn }, rec.x, rec.y)
end

-- Flat request params -> cityID, x, y (numbers) or nil.
local function Params(p)
	if type(p) ~= "table" then
		return nil
	end
	local cityID, x, y = tonumber(p.cityID), tonumber(p.x), tonumber(p.y)
	if cityID == nil or x == nil or y == nil then
		return nil
	end
	return cityID, x, y
end

-- ---------------------------------------------------------------------------
-- Requests (PLAN 4)
-- ---------------------------------------------------------------------------

local function DoStart(playerID, params)
	local cityID, x, y = Params(params)
	if cityID == nil then
		Log("Start", "rejected: bad params from player %s", tostring(playerID))
		return
	end
	-- 1. city exists at (x, y) with this ID and is the requester's.
	local pCity = ABN_Util.CityFor(playerID, cityID, x, y)
	if pCity == nil then
		Log("Start", "rejected: no city %d of player %s at (%d,%d)", cityID, tostring(playerID), x, y)
		return
	end
	-- 2. human major.
	local okP, human = pcall(function()
		local p = Players[playerID]
		return p ~= nil and p:IsHuman() == true and p:IsMajor() == true
	end)
	if not (okP and human) then
		Log("Start", "rejected: player %s is not a human major", tostring(playerID))
		return
	end
	-- 3. blockers (fresh damage read first).
	local turn = ABN_Util.Turn()
	Prepare()
	Try("Start", "ABN_Damage.RefreshCity", ABN_Damage.RefreshCity, pCity, turn)
	local code = ABN_Rules.FirstBlocker(pCity, playerID, turn)
	if code ~= nil then
		Log("Start", "rejected: city %d of player %d blocked by %s", cityID, playerID, tostring(code))
		return
	end

	local plot = ABN_Util.CityPlot(pCity)
	-- A record of an earlier city on this plot (lost, not yet seen by the turn
	-- start) is ended first, so its window is shortened and its owner told.
	local stale = ABN_State.FindActive(playerID, plot)
	if stale ~= nil and stale.cityID ~= cityID then
		EndLost(stale, turn, "another city now on the plot")
	end
	local P0 = pCity:GetPopulation()
	local s = ABN_Config.Schedule(P0)
	local D, R = ABN_Config.D(P0), ABN_Config.R(P0)
	local name = CityName(pCity)
	local rec = {
		owner = playerID, cityID = cityID, x = x, y = y, plot = plot,
		P0 = P0, T = s.T, F = s.F, D = D, R = R, start = turn, lastStep = 0,
		status = "RUN", city = name,
	}
	local win = {
		owner = playerID, x = x, y = y, D = D, R = R, start = turn,
		endTurn = ABN_Config.DebuffEndTurn(turn, s.T), srcPlot = plot, phase = "RUN", city = name,
	}
	if ABN_State.SetActive(rec) == nil then
		ABN_Util.Error("Start", "could not save the record of city %d", cityID)
		return
	end
	ABN_State.SetWindow(win)
	Log("Start", "STARTED city %d (%s) of player %d at (%d,%d): P0 %d T %d F %d D %d R %d, removal at T%d, debuff T%d-T%d",
		cityID, tostring(name), playerID, x, y, P0, s.T, s.F, D, R, turn + s.T, turn, win.endTurn)
	Try("Start", "ABN_Loyalty.ApplyNow", ABN_Loyalty.ApplyNow, playerID)
	ABN_Notify.Queue("STARTED", playerID, { city = name, turns = s.T }, x, y)
end

local function DoCancel(playerID, params)
	local cityID, x, y = Params(params)
	if cityID == nil then
		Log("Cancel", "ignored: bad params from player %s", tostring(playerID))
		return
	end
	local plot = ABN_Util.PlotIndex(x, y)
	local rec = plot ~= nil and ABN_State.FindActive(playerID, plot) or nil
	if rec == nil or rec.cityID ~= cityID then
		Log("Cancel", "ignored: no running abandonment of city %d for player %s at (%d,%d)",
			cityID, tostring(playerID), x, y)
		return
	end
	if ABN_Util.CityFor(playerID, cityID, x, y) == nil then
		Log("Cancel", "ignored: city %d of player %d is gone or changed hands (ends at the next turn start)",
			cityID, playerID)
		return
	end
	local turn = ABN_Util.Turn()
	local endTurn = EndRun(rec, turn, "CANCEL")
	local cdEnd = ABN_Config.CooldownEnd(turn)
	ABN_State.AddCooldown(playerID, cityID, plot, cdEnd)
	Log("Cancel", "CANCELLED city %d of player %d at (%d,%d) on turn %d of %d; debuff until T%d, restart from T%d",
		cityID, playerID, x, y, turn - rec.start + 1, rec.T, endTurn, cdEnd)
	ABN_Notify.Queue("CANCELLED", playerID, { city = rec.city, debuffTurns = endTurn - turn }, x, y)
end

-- Request: start an abandonment (PLAN 4). playerID is the only trusted player.
function ABN_Gameplay.OnStart(playerID, params)
	Try("Start", "OnStart", DoStart, playerID, params)
	Try("Start", "ABN_Notify.Flush", ABN_Notify.Flush)
end

-- Request: cancel an abandonment (PLAN 4).
function ABN_Gameplay.OnCancel(playerID, params)
	Try("Cancel", "OnCancel", DoCancel, playerID, params)
	Try("Cancel", "ABN_Notify.Flush", ABN_Notify.Flush)
end

-- ---------------------------------------------------------------------------
-- Turn pipeline (PLAN 5)
-- ---------------------------------------------------------------------------

-- Step 1: auto-cancel and lost cities.
local function StepAutoCancel(turn)
	local n = 0
	for _, rec in ipairs(ABN_State.Get(KEY_ACTIVE)) do
		Try("Turn", "auto-cancel check of city " .. tostring(rec.cityID), function()
			local pCity = ABN_Util.CityFor(rec.owner, rec.cityID, rec.x, rec.y)
			if pCity == nil then
				EndLost(rec, turn, "city gone or changed hands")
				n = n + 1
				return
			end
			-- Removing the owner's only city would eliminate them (DECISIONS #27).
			local code = ABN_Rules.IsLastCity(rec.owner) and "LAST_CITY"
				or ABN_Rules.ThreatBlocker(pCity, rec.owner, turn)
			if code ~= nil then
				EndAuto(rec, turn, code)
				n = n + 1
			end
		end)
	end
	return n
end

-- Step 2: population steps.
local function StepPopulation(turn)
	local n = 0
	for _, rec in ipairs(ABN_State.Get(KEY_ACTIVE)) do
		Try("Turn", "population step of city " .. tostring(rec.cityID), function()
			local k = turn - rec.start
			if k < 1 or k > rec.T - 1 or (rec.lastStep or 0) >= k then
				return
			end
			local pCity = ABN_Util.CityFor(rec.owner, rec.cityID, rec.x, rec.y)
			if pCity == nil then
				return
			end
			local target = ABN_Config.TargetK(rec.P0, rec.T, rec.F, k)
			local pop = pCity:GetPopulation()
			if pop > target then
				pCity:ChangePopulation(target - pop)
			end
			rec.lastStep = k
			ABN_State.SetActive(rec)
			Log("Pop", "city %d (owner %d) step %d/%d: pop %d -> target %d, now %d",
				rec.cityID, rec.owner, k, rec.T - 1, pop, target, pCity:GetPopulation())
			n = n + 1
		end)
	end
	return n
end

-- Step 3: removals at the end of turn T (= the turn start of start + T).
local function StepRemovals(turn)
	local n = 0
	for _, rec in ipairs(ABN_State.Get(KEY_ACTIVE)) do
		if turn >= rec.start + rec.T then
			Try("Turn", "removal of city " .. tostring(rec.cityID), function()
				local pCity = ABN_Util.CityFor(rec.owner, rec.cityID, rec.x, rec.y)
				local name = (pCity ~= nil and CityName(pCity)) or rec.city
				local result, reason = ABN_Removal.Remove(rec)
				if result == "DONE" then
					ABN_State.RemoveActive(rec.owner, rec.plot)
					ABN_State.RemoveDamage(rec.owner, rec.plot)
					local w = WindowOf(rec)
					local endTurn = ABN_Config.DebuffEndTurn(rec.start, rec.T)
					if w == nil then
						ABN_Util.Error("Remove", "window of city %d missing; recreated", rec.cityID)
						w = { owner = rec.owner, x = rec.x, y = rec.y, D = rec.D, R = rec.R,
							start = rec.start, endTurn = endTurn, srcPlot = rec.plot, city = name }
					end
					w.phase = "POST"
					ABN_State.SetWindow(w)
					Log("Remove", "REMOVED city %d (owner %d) at (%d,%d); debuff until T%d",
						rec.cityID, rec.owner, rec.x, rec.y, w.endTurn)
					ABN_Notify.Queue("REMOVED", rec.owner,
						{ city = name, debuffTurns = w.endTurn - turn + 1 }, rec.x, rec.y)
					n = n + 1
				elseif reason == "LOST" then
					EndLost(rec, turn, "found at removal")
				else
					ABN_Util.Error("Remove", "removal of city %d (owner %d) at (%d,%d) failed (%s, %s); retry next turn",
						rec.cityID, rec.owner, rec.x, rec.y, tostring(result), tostring(reason))
				end
			end)
		end
	end
	return n
end

-- Step 6: countdown notification to the owner of each running record.
local function StepTicks(turn)
	local n = 0
	for _, rec in ipairs(ABN_State.Get(KEY_ACTIVE)) do
		local left = rec.start + rec.T - turn
		if left >= 1 then
			ABN_Notify.Queue("TICK", rec.owner, { city = rec.city, turns = left }, rec.x, rec.y)
			n = n + 1
		end
	end
	return n
end

local function Step(name, fn, turn)
	local ok, res = pcall(fn, turn)
	if ok then
		Log("Turn", "T%d %s: %s", turn, name, tostring(res))
	else
		ABN_Util.Error("Turn", "T%d %s failed: %s", turn, name, tostring(res))
	end
end

function ABN_Gameplay.OnGameTurnStarted(turn)
	if not IsNum(turn) then
		turn = ABN_Util.Turn()
	end
	Log("Turn", "T%d pipeline start", turn)
	Prepare()
	Step("0 damage", ABN_Damage.Refresh, turn)
	Step("1 auto-cancel", StepAutoCancel, turn)
	Step("2 population", StepPopulation, turn)
	Step("3 removals", StepRemovals, turn)
	Step("4 debuff", function(t) return #ABN_Loyalty.Apply(t) end, turn)
	Step("5 cooldowns", function(t) return #ABN_State.DropExpiredCooldowns(t) end, turn)
	Step("6 ticks", StepTicks, turn)
	Step("flush", function() ABN_Notify.Flush(); return "done" end, turn)
end

-- ---------------------------------------------------------------------------
-- Other synced events
-- ---------------------------------------------------------------------------

-- GameEvents.CityConquered: clear the loyalty flags at once (L-B2), and end a
-- running abandonment of the old owner on that plot as LOST (DECISIONS #13)
-- instead of waiting for the turn start.
function ABN_Gameplay.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
	Try("Conquer", "ABN_Loyalty.OnCityConquered", ABN_Loyalty.OnCityConquered,
		capturerID, oldOwnerID, cityID, x, y)
	Try("Conquer", "lost-city check", function()
		if not (IsNum(oldOwnerID) and IsNum(x) and IsNum(y)) then
			return
		end
		local plot = ABN_Util.PlotIndex(x, y)
		local rec = plot ~= nil and ABN_State.FindActive(oldOwnerID, plot) or nil
		if rec ~= nil and ABN_Util.CityFor(rec.owner, rec.cityID, rec.x, rec.y) == nil then
			EndLost(rec, ABN_Util.Turn(), "captured by player " .. tostring(capturerID))
		end
	end)
	Try("Conquer", "ABN_Notify.Flush", ABN_Notify.Flush)
end

function ABN_Gameplay.OnCombatOccurred(...)
	Try("Combat", "ABN_Damage.OnCombat", ABN_Damage.OnCombat, ...)
end

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------
Prepare()

GameEvents.OnGameTurnStarted.Add(ABN_Gameplay.OnGameTurnStarted)
ABN_Util.Log("Init", "registered %s", "GameEvents.OnGameTurnStarted")

GameEvents.CityConquered.Add(ABN_Gameplay.OnCityConquered)
ABN_Util.Log("Init", "registered %s", "GameEvents.CityConquered")

GameEvents.OnCombatOccurred.Add(ABN_Gameplay.OnCombatOccurred)
ABN_Util.Log("Init", "registered %s", "GameEvents.OnCombatOccurred")

GameEvents.ABN_Start.Add(ABN_Gameplay.OnStart)
ABN_Util.Log("Init", "registered %s", "GameEvents.ABN_Start")

GameEvents.ABN_Cancel.Add(ABN_Gameplay.OnCancel)
ABN_Util.Log("Init", "registered %s", "GameEvents.ABN_Cancel")

ABN_Util.Log("Init", "ABN_Gameplay loaded, version %s", ABN_Config.VERSION)
