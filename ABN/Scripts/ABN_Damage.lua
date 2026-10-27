-- ===========================================================================
-- ABN_Damage.lua
-- Module:   ABN_Damage (global table), gameplay only, include("ABN_Damage")
-- Owner:    WP7 (PLAN 5 step 0: last-damaged tracker; spec 1.2 rule 1).
--
-- Tracks, for every city of every alive human major, the last turn its city
-- centre took damage (garrison or outer/walls), so ABN_Rules can block
-- "damaged in the last DAMAGE_MEMORY_TURNS turns" after the city has healed.
--
-- Record (Game property ABN_Damage, PLAN 3, plus x/y for the re-fetch):
--   {owner, cityID, plot, x, y, lastTurn, g, o}
--   g, o      the garrison and outer damage seen at the last read;
--   lastTurn  the turn a read saw g or o ABOVE the stored value (absent until
--             the city has been seen taking damage).
-- A record exists only while it carries information: current damage > 0, or
-- turn - lastTurn < DAMAGE_MEMORY_TURNS. Records of cities that are gone, have
-- another owner/ID, or whose owner is no longer an alive human major are
-- dropped at the turn-start refresh.
--
-- Sources (all synced):
--   Refresh(turn)            OnGameTurnStarted, step 0: every human city.
--   RefreshCity(pCity, turn) request handlers, before the rule checks.
--   OnCombat(aP, aU, dP, dU, aD, dD)   GameEvents.OnCombatOccurred: re-reads the
--             defender's cities right away, so a city hit and healed in the
--             same round is still stamped. The defender district ID is NOT
--             resolved (Players[p]:GetDistricts():FindID is unverified in G);
--             dD only filters: a number below 0 means no district defended.
--             If the engine applies the damage after the event, the next
--             combat or the turn-start refresh stamps it instead.
--
-- Engine calls (Appendix A): CityManager.GetDistrictAt + GetDamage (through
-- ABN_Util.CentreDamage), Players[p]:IsHuman/IsMajor/IsAlive,
-- GetCities():Members(), pCity:GetID/GetX/GetY, PlayerManager.GetAliveIDs
-- (ABN_Util.AliveIDs), Game.GetCurrentGameTurn (ABN_Util.Turn).
-- MP: ipairs only, owners ascending, cities in Members() order; no
-- Game.GetLocalPlayer, no random. Writes state only from synced handlers.
-- ===========================================================================

if ABN_Damage ~= nil and ABN_Damage.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")
include("ABN_State")

ABN_Damage = {}

local KEY = ABN_Config.KEY_DAMAGE

local function Log(fmt, ...)
	ABN_Util.Log("Damage", fmt, ...)
end

local function IsNum(v)
	return type(v) == "number"
end

-- true when pid is an alive human major (only humans can abandon).
local function IsTracked(pid)
	if not IsNum(pid) or pid < 0 then
		return false
	end
	local ok, res = pcall(function()
		local p = Players[pid]
		return p ~= nil and p:IsAlive() == true and p:IsHuman() == true and p:IsMajor() == true
	end)
	return ok and res == true
end

local function SameRecs(a, b)
	if #a ~= #b then
		return false
	end
	for i, r in ipairs(a) do
		local s = b[i]
		if s == nil or s.owner ~= r.owner or s.cityID ~= r.cityID or s.plot ~= r.plot
				or s.x ~= r.x or s.y ~= r.y or s.lastTurn ~= r.lastTurn or s.g ~= r.g or s.o ~= r.o then
			return false
		end
	end
	return true
end

local function Copy(arr)
	local out = {}
	for i, r in ipairs(arr) do
		out[i] = { owner = r.owner, cityID = r.cityID, plot = r.plot, x = r.x, y = r.y,
			lastTurn = r.lastTurn, g = r.g, o = r.o }
	end
	return out
end

-- Worth keeping on this turn?
local function Useful(r, turn)
	if (r.g or 0) > 0 or (r.o or 0) > 0 then
		return true
	end
	return IsNum(r.lastTurn) and turn - r.lastTurn < ABN_Config.DAMAGE_MEMORY_TURNS
end

-- Reads one city and updates arr in place (by owner + plot). Returns true when
-- the city was seen taking new damage.
local function UpdateCity(arr, pCity, owner, turn)
	if pCity == nil then
		return false
	end
	local plot = ABN_Util.CityPlot(pCity)
	if plot == nil then
		return false
	end
	local g, o = ABN_Util.CentreDamage(pCity)
	if g == nil and o == nil then
		return false -- unreadable: keep what we have (ABN_Rules blocks on it anyway)
	end
	g, o = g or 0, o or 0
	local cityID = pCity:GetID()
	local idx, old = ABN_Util.FindIndex(arr, function(r) return r.owner == owner and r.plot == plot end)
	if old ~= nil and old.cityID ~= cityID then
		old = nil -- another city on the same plot: start over
	end
	local oldG, oldO = 0, 0
	local lastTurn = nil
	if old ~= nil then
		oldG, oldO, lastTurn = old.g or 0, old.o or 0, old.lastTurn
	end
	local hit = g > oldG or o > oldO
	if hit then
		lastTurn = turn
	end
	local rec = { owner = owner, cityID = cityID, plot = plot, x = pCity:GetX(), y = pCity:GetY(),
		lastTurn = lastTurn, g = g, o = o }
	if idx ~= nil then
		if Useful(rec, turn) then
			arr[idx] = rec
		else
			table.remove(arr, idx)
		end
	elseif Useful(rec, turn) then
		arr[#arr + 1] = rec
	end
	if hit then
		Log("city %d (owner %d) at (%d,%d) damaged: garrison %d->%d, outer %d->%d, lastTurn %d",
			cityID, owner, rec.x, rec.y, oldG, g, oldO, o, turn)
	end
	return hit
end

local function UpdateOwner(arr, owner, turn)
	local hits = 0
	local ok, err = pcall(function()
		for _, pCity in Players[owner]:GetCities():Members() do
			if UpdateCity(arr, pCity, owner, turn) then
				hits = hits + 1
			end
		end
	end)
	if not ok then
		ABN_Util.Error("Damage", "cities of player %s unreadable: %s", tostring(owner), tostring(err))
	end
	return hits
end

-- Refresh(turn): PLAN 5 step 0. Reads every city of every alive human major
-- (ascending ID, Members() order), stamps new damage, drops records that no
-- longer carry information or whose city is gone / changed hands.
-- Returns the number of cities stamped this turn.
function ABN_Damage.Refresh(turn)
	turn = turn or ABN_Util.Turn()
	local old = ABN_State.Get(KEY)
	local arr = Copy(old)
	local hits = 0
	for _, pid in ipairs(ABN_Util.AliveIDs()) do
		if IsTracked(pid) then
			hits = hits + UpdateOwner(arr, pid, turn)
		end
	end
	local kept = ABN_Util.Filter(arr, function(r)
		if not (IsTracked(r.owner) and Useful(r, turn)) then
			return false
		end
		if IsNum(r.x) and IsNum(r.y) then
			return ABN_Util.CityFor(r.owner, r.cityID, r.x, r.y) ~= nil
		end
		return false
	end)
	if not SameRecs(kept, old) then
		ABN_State.Put(KEY, kept)
	end
	Log("refresh T%d: %d tracked, %d newly damaged", turn, #kept, hits)
	return hits
end

-- RefreshCity(pCity, turn): on-demand read of one city (request handlers,
-- before ABN_Rules). Returns true when it was stamped.
function ABN_Damage.RefreshCity(pCity, turn)
	if pCity == nil then
		return false
	end
	turn = turn or ABN_Util.Turn()
	local owner = pCity:GetOwner()
	local old = ABN_State.Get(KEY)
	local arr = Copy(old)
	local hit = UpdateCity(arr, pCity, owner, turn)
	if not SameRecs(arr, old) then
		ABN_State.Put(KEY, arr)
	end
	return hit
end

-- LastTurn(owner, plot) -> turn of the last seen damage of the city that is
-- on that plot now (same owner and city ID as the record), or nil.
function ABN_Damage.LastTurn(owner, plot)
	local rec = ABN_State.FindDamage(owner, plot)
	if rec == nil or not IsNum(rec.lastTurn) then
		return nil
	end
	if IsNum(rec.x) and IsNum(rec.y) and ABN_Util.CityFor(owner, rec.cityID, rec.x, rec.y) == nil then
		return nil
	end
	return rec.lastTurn
end

-- OnCombat(aPlayer, aUnit, dPlayer, dUnit, aDistrict, dDistrict): handler body
-- of GameEvents.OnCombatOccurred (registered in ABN_Gameplay). When the
-- defender is a tracked player and a district may have defended (dD >= 0, or
-- the argument is missing), re-reads that player's cities at once.
function ABN_Damage.OnCombat(aP, aU, dP, dU, aD, dD)
	if not IsTracked(dP) then
		return 0
	end
	if IsNum(dD) and dD < 0 then
		return 0
	end
	local turn = ABN_Util.Turn()
	local old = ABN_State.Get(KEY)
	local arr = Copy(old)
	local hits = UpdateOwner(arr, dP, turn)
	if not SameRecs(arr, old) then
		ABN_State.Put(KEY, arr)
	end
	if hits > 0 then
		Log("combat (defender %d, district %s): %d city(ies) stamped", dP, tostring(dD), hits)
	end
	return hits
end

ABN_Damage.LOADED = 1
