-- ===========================================================================
-- ABN_Removal.lua
-- Module:   ABN_Removal (global table), gameplay. Branch R-G / G1 (DECISIONS #22).
-- Owner:    WP1 stub; WP6 implements (PLAN 6). No OnAck (R-UI dropped).
--
-- Remove(rec) -> result, reason
--   rec: a record with flat numbers rec.x, rec.y, rec.owner, rec.cityID.
--   result is one of "DONE" | "PENDING" | "FAILED":
--     "DONE"    GetCityAt(x, y) was nil after Players[owner]:GetCities():Destroy(pCity).
--     "FAILED"  nothing was removed (or removal could not be confirmed); see reason.
--     "PENDING" is never returned (R-G removes in the same call; no real reason to wait).
--   reason (2nd return value, string) explains the result:
--     "OK"           result DONE.
--     "LOST"         result FAILED. The city is not ours any more: no city on the
--                    plot, or it has another owner (captured/flipped/traded) or
--                    another ID (a new city founded on the ruin). Nothing was
--                    destroyed. WP7 treats it per DECISIONS #13 (auto-cancel
--                    style end, no cooldown, notify), NOT as a retryable failure.
--     "BAD_REC"      result FAILED. rec missing or its x/y/owner/cityID not numbers.
--     "NO_PLAYER"    result FAILED. Players[rec.owner] or its GetCities() is missing.
--     "NO_DESTROY"   result FAILED. GetCities().Destroy is not a function.
--     "CALL_ERROR"   result FAILED. Destroy raised an error (logged).
--     "STILL_THERE"  result FAILED. Destroy returned but GetCityAt(x, y) is not nil.
--   Only reasons other than "LOST" are retry/escalate cases (PLAN Q1).
--
-- MP rules: no random, no pairs() over state, no Game.GetLocalPlayer, no state
-- written here. Called only from the synced turn hook (OnGameTurnStarted).
-- No unit move and no tile cleanup (DECISIONS #23; S1 showed none is needed).
-- ===========================================================================

if ABN_Removal ~= nil and ABN_Removal.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")
include("ABN_State")

ABN_Removal = {}

local TAG = "REMOVE"

local function Fail(reason, fmt, ...)
	ABN_Util.Log(TAG, "FAILED(" .. reason .. ") " .. fmt, ...)
	return "FAILED", reason
end

local function CityAtPlot(x, y)
	local ok, c = pcall(function() return CityManager.GetCityAt(x, y) end)
	if ok then return c end
	return nil
end

function ABN_Removal.Remove(rec)
	if type(rec) ~= "table" or type(rec.x) ~= "number" or type(rec.y) ~= "number"
			or type(rec.owner) ~= "number" or type(rec.cityID) ~= "number" then
		return Fail("BAD_REC", "record missing x/y/owner/cityID")
	end
	local x, y, owner, cityID = rec.x, rec.y, rec.owner, rec.cityID
	ABN_Util.Log(TAG, "start city %d owner %d at (%d,%d)", cityID, owner, x, y)

	-- 1. Re-fetch by plot and verify identity.
	local pCity = CityAtPlot(x, y)
	if pCity == nil then
		return Fail("LOST", "no city at (%d,%d) (city %d owner %d)", x, y, cityID, owner)
	end
	local okO, curOwner = pcall(function() return pCity:GetOwner() end)
	local okI, curID = pcall(function() return pCity:GetID() end)
	if not (okO and okI) or curOwner ~= owner or curID ~= cityID then
		return Fail("LOST", "city at (%d,%d) is %s/%s, expected %d/%d",
			x, y, tostring(curOwner), tostring(curID), owner, cityID)
	end
	ABN_Util.Log(TAG, "verified city %d owner %d at (%d,%d)", cityID, owner, x, y)

	-- 2. G1: Players[owner]:GetCities():Destroy(pCity), in pcall.
	local coll = nil
	pcall(function() coll = Players[owner]:GetCities() end)
	if coll == nil then
		return Fail("NO_PLAYER", "Players[%d]:GetCities() unavailable", owner)
	end
	local okT, t = pcall(function() return type(coll.Destroy) end)
	if not (okT and t == "function") then
		return Fail("NO_DESTROY", "GetCities().Destroy missing")
	end
	local okC, err = pcall(function() coll:Destroy(pCity) end)
	if not okC then
		return Fail("CALL_ERROR", "Destroy raised: %s", tostring(err))
	end
	ABN_Util.Log(TAG, "Destroy(city %d) returned", cityID)

	-- 3. Confirm.
	if CityAtPlot(x, y) ~= nil then
		return Fail("STILL_THERE", "city still at (%d,%d) after Destroy", x, y)
	end
	ABN_Util.Log(TAG, "DONE city %d owner %d at (%d,%d) removed", cityID, owner, x, y)
	return "DONE", "OK"
end

ABN_Removal.LOADED = 1
