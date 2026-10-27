-- ===========================================================================
-- ABN_Loyalty.lua
-- Module:   ABN_Loyalty (global table), gameplay. Branch L-B2 (DECISIONS #26).
-- Owner:    WP5 (PLAN 7).
--
-- The debuff itself is data (ABN_Loyalty.xml): five modifiers ABN_LOY_BIT_<n>
-- (-n loyalty per turn), each active on a city while the city's plot has the
-- property ABN_DBIT_<n> >= 1. This file only sets those plot properties.
--
-- Coverage (spec 1.7, PLAN 5 step 4, DECISIONS #6, #8):
--   * a window is live on turn t when start <= t <= endTurn;
--   * a city is covered by a live window when the city's owner is the window's
--     owner (only the abandoning player's own cities, #6) and
--     Map.GetPlotDistance(city, window x/y) <= R (R inclusive, in tiles);
--   * the abandoned city itself is NOT covered by its own window (spec 1.7:
--     "excluding the abandoned city itself"). It is excluded by plot: the
--     window's srcPlot (or its x/y when srcPlot is missing) equals the city
--     plot. It is still covered by OTHER windows of the same owner (PLAN 11:
--     "each abandoning city is excluded from its own window only");
--   * the city's D = ABN_Config.SumD of the covering windows' D (a SUM, #8;
--     no cap, #15). The ladder holds at most 31 (ABN_Config.Bits clamps).
--
-- State:
--   ABN_Windows  read; Apply drops windows with endTurn < turn and saves.
--   ABN_Flagged  {plot, x, y, bits}: the city plots that carry ladder
--                properties now (bits = the D mask, 1..31). x/y are stored so
--                stale plots can be cleared with Map.GetPlot (Appendix A).
--
-- MP: called only from synced gameplay code (turn hook, request handler,
-- GameEvents.CityConquered). ipairs only; owners in ascending ID order,
-- cities in GetCities():Members() order; no Game.GetLocalPlayer.
-- ===========================================================================

if ABN_Loyalty ~= nil and ABN_Loyalty.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")
include("ABN_State")
include("ABN_Notify")

ABN_Loyalty = {}

ABN_Loyalty.PROP_PREFIX = "ABN_DBIT_"   -- + n; must match ABN_Loyalty.xml PropertyName

local function Log(fmt, ...)
	ABN_Util.Log("Loyalty", fmt, ...)
end

local function IsNum(v)
	return type(v) == "number"
end

local function ValidWindow(w)
	return type(w) == "table" and IsNum(w.owner) and IsNum(w.x) and IsNum(w.y)
		and IsNum(w.D) and IsNum(w.R) and IsNum(w.start) and IsNum(w.endTurn)
end

-- D mask (0..31) for a D sum: the sum of ABN_Config.Bits(D).
function ABN_Loyalty.Mask(D)
	local m = 0
	for _, b in ipairs(ABN_Config.Bits(D)) do
		m = m + b
	end
	return m
end

-- Sets ABN_DBIT_<n> on one plot to 1 for the bits in mask, 0 for the others.
local function WritePlot(pPlot, mask)
	for _, b in ipairs(ABN_Config.LOY_BITS) do
		local on = (math.floor(mask / b) % 2 == 1) and 1 or 0
		pPlot:SetProperty(ABN_Loyalty.PROP_PREFIX .. b, on)
	end
end

local function ClearAt(x, y)
	local pPlot = Map.GetPlot(x, y)
	if pPlot ~= nil then
		WritePlot(pPlot, 0)
		return true
	end
	return false
end

local function SameFlagged(a, b)
	if #a ~= #b then return false end
	for i, e in ipairs(a) do
		local f = b[i]
		if f == nil or f.plot ~= e.plot or f.bits ~= e.bits or f.x ~= e.x or f.y ~= e.y then
			return false
		end
	end
	return true
end

-- Is the city on the window's source plot (the abandoned city itself)?
local function IsSource(w, cityPlotIndex, cx, cy)
	if IsNum(w.srcPlot) and cityPlotIndex ~= nil then
		return w.srcPlot == cityPlotIndex
	end
	return w.x == cx and w.y == cy
end

-- Live windows on this turn, in array order.
local function LiveWindows(windows, turn)
	local live = {}
	for _, w in ipairs(windows) do
		if ValidWindow(w) and w.start <= turn and turn <= w.endTurn then
			live[#live + 1] = w
		end
	end
	return live
end

-- Desired flags {plot, x, y, bits} for the live windows: owners ascending,
-- cities in Members() order. Dead or missing owners are skipped.
local function Desired(live)
	local owners, seen = {}, {}
	for _, w in ipairs(live) do
		if not seen[w.owner] then
			seen[w.owner] = true
			owners[#owners + 1] = w.owner
		end
	end
	table.sort(owners)

	local out = {}
	for _, owner in ipairs(owners) do
		local pPlayer = Players[owner]
		if pPlayer ~= nil and pPlayer:IsAlive() then
			for _, pCity in pPlayer:GetCities():Members() do
				local cx, cy = pCity:GetX(), pCity:GetY()
				local pPlot = pCity:GetPlot()
				local idx = pPlot ~= nil and pPlot:GetIndex() or nil
				local ds = {}
				for _, w in ipairs(live) do
					if w.owner == owner and not IsSource(w, idx, cx, cy)
							and Map.GetPlotDistance(cx, cy, w.x, w.y) <= w.R then
						ds[#ds + 1] = w.D
					end
				end
				if #ds > 0 and idx ~= nil then
					local sum = ABN_Config.SumD(ds)
					local mask = ABN_Loyalty.Mask(sum)
					if sum > mask then
						Log("city %d (owner %d) D sum %d above the ladder, applied %d",
							pCity:GetID(), owner, sum, mask)
					end
					if mask > 0 then
						out[#out + 1] = { plot = idx, x = cx, y = cy, bits = mask }
					end
				end
			end
		end
	end
	return out
end

-- Writes the desired flags, clears stale ones, saves ABN_Flagged when changed.
local function Sync(turn, why)
	local windows = ABN_State.Get(ABN_Config.KEY_WINDOWS)
	local desired = Desired(LiveWindows(windows, turn))
	local old = ABN_State.Get(ABN_Config.KEY_FLAGGED)

	local want = {}
	for _, e in ipairs(desired) do
		want[e.plot] = true
		local pPlot = Map.GetPlot(e.x, e.y)
		if pPlot ~= nil then
			WritePlot(pPlot, e.bits)
		end
	end
	local cleared = 0
	for _, e in ipairs(old) do
		if type(e) == "table" and IsNum(e.plot) and not want[e.plot] and IsNum(e.x) and IsNum(e.y) then
			if ClearAt(e.x, e.y) then cleared = cleared + 1 end
		end
	end
	if not SameFlagged(desired, old) then
		ABN_State.Put(ABN_Config.KEY_FLAGGED, desired)
	end
	Log("%s T%d: %d windows live, %d cities flagged, %d cleared", why, turn,
		#LiveWindows(windows, turn), #desired, cleared)
	return desired
end

-- Apply(turn): PLAN 5 step 4. Drops windows with endTurn < turn (queues
-- DEBUFF_ENDED to the owner, saves ABN_Windows), then sets the ladder
-- properties for every covered city and clears every flagged plot that is no
-- longer covered. Returns the new ABN_Flagged array.
function ABN_Loyalty.Apply(turn)
	local windows = ABN_State.Get(ABN_Config.KEY_WINDOWS)
	local kept, dropped = {}, 0
	for _, w in ipairs(windows) do
		if ValidWindow(w) and w.endTurn < turn then
			dropped = dropped + 1
			Log("window of owner %d at (%d,%d) ended (endTurn %d)", w.owner, w.x, w.y, w.endTurn)
			-- args.city: the abandoned city's saved name, if the window carries one
			-- (field "city" or "name"; ABN_Notify falls back when nil).
			ABN_Notify.Queue("DEBUFF_ENDED", w.owner,
				{ city = w.city or w.name, D = w.D, R = w.R, endTurn = w.endTurn }, w.x, w.y)
		elseif ValidWindow(w) then
			kept[#kept + 1] = w
		else
			dropped = dropped + 1
			Log("dropped an invalid window record")
		end
	end
	if dropped > 0 then
		ABN_State.Put(ABN_Config.KEY_WINDOWS, kept)
	end
	return Sync(turn, "Apply")
end

-- ApplyNow(owner): re-apply at the current turn without the expiry step (no
-- notifications). Used by the start handler right after a window is added,
-- so the debuff counts in this turn's end-of-turn loyalty. It recomputes all
-- owners (the result is the same pure function of the state); owner is only
-- logged.
function ABN_Loyalty.ApplyNow(owner)
	local turn = Game.GetCurrentGameTurn()
	Log("ApplyNow for owner %s", tostring(owner))
	return Sync(turn, "ApplyNow")
end

-- OnCityConquered(capturerID, oldOwnerID, cityID, x, y): clears the captured
-- city's plot flags at once (a capturer never gets the debuff) and removes the
-- plot from ABN_Flagged. If the capturer has its own window covering the city,
-- the next Apply flags it again.
function ABN_Loyalty.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
	if not IsNum(x) or not IsNum(y) then return end
	local pPlot = Map.GetPlot(x, y)
	if pPlot == nil then return end
	WritePlot(pPlot, 0)
	local idx = pPlot:GetIndex()
	local old = ABN_State.Get(ABN_Config.KEY_FLAGGED)
	local kept = {}
	for _, e in ipairs(old) do
		if not (type(e) == "table" and e.plot == idx) then
			kept[#kept + 1] = e
		end
	end
	if #kept ~= #old then
		ABN_State.Put(ABN_Config.KEY_FLAGGED, kept)
	end
	Log("city %s at (%d,%d) captured by %s from %s: flags cleared", tostring(cityID), x, y,
		tostring(capturerID), tostring(oldOwnerID))
end

ABN_Loyalty.LOADED = 1
