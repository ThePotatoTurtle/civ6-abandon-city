-- ===========================================================================
-- ABN_Util.lua
-- Module:   ABN_Util (global table), shared (gameplay + UI), include("ABN_Util")
-- Owner:    WP3 (PLAN 1: Log, Round, Dist, city lookup by plot, ordered helpers).
--
-- Engine calls (PLAN Appendix A): Game.GetCurrentGameTurn (G+UI),
-- Map.GetPlot / pPlot:GetIndex (G+UI), Map.GetPlotDistance (G+UI),
-- CityManager.GetCityAt (G+UI), pCity:GetID/GetX/GetY/GetOwner (G+UI),
-- PlayerManager.GetAliveIDs (G+UI), CityManager.GetDistrictAt (G only),
-- Players[p]:GetDistricts():FindID(pCity:GetDistrictID()) (UI only,
-- CitySupport.lua:360,618), pDistrict:GetDamage(DefenseTypes.*) (G+UI).
--
-- Determinism (PLAN 10): the only pairs() is inside ABN_Util.SortedKeys, which
-- sorts the keys; every other walk is ipairs over a dense array.
-- ===========================================================================

if ABN_Util ~= nil and ABN_Util.LOADED == 1 then
	return
end

include("ABN_Config")

ABN_Util = {}

-- ---------------------------------------------------------------------------
-- Context and turn
-- ---------------------------------------------------------------------------

-- IsGameplay() -> bool: true in the gameplay context (the UI global is nil
-- there), false in a UI context (EFV_Util.lua EFV_IsGameplay, in game).
function ABN_Util.IsGameplay()
	return UI == nil
end

-- Turn() -> current game turn (-1 if it cannot be read).
function ABN_Util.Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return -1
end

-- ---------------------------------------------------------------------------
-- Logging: one Lua.log line "[ABN][T<turn>][<tag>] <message>".
-- Error(tag, ...) adds "ERROR " so log readers (and the offline harness) can
-- find failures.
-- ---------------------------------------------------------------------------
local function Format(fmt, ...)
	local ok, msg = pcall(string.format, tostring(fmt), ...)
	if not ok then
		msg = tostring(fmt)
	end
	return msg
end

function ABN_Util.Log(tag, fmt, ...)
	print("[ABN][T" .. tostring(ABN_Util.Turn()) .. "][" .. tostring(tag) .. "] " .. Format(fmt, ...))
end

function ABN_Util.Error(tag, fmt, ...)
	print("[ABN][T" .. tostring(ABN_Util.Turn()) .. "][" .. tostring(tag) .. "] ERROR " .. Format(fmt, ...))
end

-- Round(x): math.floor(x + 0.5), the same function as ABN_Config.Round.
ABN_Util.Round = ABN_Config.Round

-- ---------------------------------------------------------------------------
-- Map and cities
-- ---------------------------------------------------------------------------

-- Dist(x1, y1, x2, y2) -> hex distance in tiles (Map.GetPlotDistance; 999
-- when it cannot be read, so a failed read never counts as "near").
function ABN_Util.Dist(x1, y1, x2, y2)
	local ok, d = pcall(function() return Map.GetPlotDistance(x1, y1, x2, y2) end)
	if ok and type(d) == "number" then
		return d
	end
	return 999
end

-- PlotIndex(x, y) -> plot index, or nil off the map.
function ABN_Util.PlotIndex(x, y)
	local ok, idx = pcall(function()
		local p = Map.GetPlot(x, y)
		if p == nil then
			return nil
		end
		return p:GetIndex()
	end)
	if ok and type(idx) == "number" then
		return idx
	end
	return nil
end

-- CityPlot(pCity) -> plot index of the city centre, or nil.
function ABN_Util.CityPlot(pCity)
	if pCity == nil then
		return nil
	end
	return ABN_Util.PlotIndex(pCity:GetX(), pCity:GetY())
end

-- CityAt(x, y) -> the city on (x, y), or nil (CityManager.GetCityAt).
function ABN_Util.CityAt(x, y)
	if type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	local ok, c = pcall(function() return CityManager.GetCityAt(x, y) end)
	if ok then
		return c
	end
	return nil
end

-- CityFor(owner, cityID, x, y) -> the city on (x, y) when it is owned by owner
-- and (if cityID is given) has that ID; nil otherwise. This is the re-fetch
-- used before every action on a stored record (PLAN 3).
function ABN_Util.CityFor(owner, cityID, x, y)
	local c = ABN_Util.CityAt(x, y)
	if c == nil then
		return nil
	end
	if c:GetOwner() ~= owner then
		return nil
	end
	if cityID ~= nil and c:GetID() ~= cityID then
		return nil
	end
	return c
end

-- CentreDistrict(pCity) -> the city-centre district object, or nil.
-- G: CityManager.GetDistrictAt(x, y) (S4, in game). UI: the player's district
-- by the city's district ID (CitySupport.lua:360,618).
function ABN_Util.CentreDistrict(pCity)
	if pCity == nil then
		return nil
	end
	local ok, d = false, nil
	if ABN_Util.IsGameplay() then
		-- ABN:G-ONLY begin
		ok, d = pcall(function() return CityManager.GetDistrictAt(pCity:GetX(), pCity:GetY()) end)
		-- ABN:G-ONLY end
	else
		-- ABN:UI-ONLY begin
		ok, d = pcall(function() return Players[pCity:GetOwner()]:GetDistricts():FindID(pCity:GetDistrictID()) end)
		-- ABN:UI-ONLY end
	end
	if ok then
		return d
	end
	return nil
end

-- CentreDamage(pCity) -> g, o: current garrison and outer (wall) damage of
-- the city centre (numbers), or nil, nil when the district cannot be read.
function ABN_Util.CentreDamage(pCity)
	local d = ABN_Util.CentreDistrict(pCity)
	if d == nil then
		return nil, nil
	end
	local okG, g = pcall(function() return d:GetDamage(DefenseTypes.DISTRICT_GARRISON) end)
	local okO, o = pcall(function() return d:GetDamage(DefenseTypes.DISTRICT_OUTER) end)
	if not okG or type(g) ~= "number" then
		g = nil
	end
	if not okO or type(o) ~= "number" then
		o = nil
	end
	return g, o
end

-- AliveIDs() -> alive player IDs, ascending (GetAliveIDs has no useful order).
function ABN_Util.AliveIDs()
	local ids = {}
	local ok = pcall(function()
		for _, id in ipairs(PlayerManager.GetAliveIDs()) do
			ids[#ids + 1] = id
		end
	end)
	if not ok then
		ids = {}
	end
	table.sort(ids)
	return ids
end

-- ---------------------------------------------------------------------------
-- Ordered helpers (dense arrays only)
-- ---------------------------------------------------------------------------

-- SortedKeys(t) -> keys of t, numbers ascending first, then strings ascending.
-- The one sanctioned pairs() (api_audit accepts pairs inside *SortedKeys).
function ABN_Util.SortedKeys(t)
	local nums, strs = {}, {}
	if type(t) ~= "table" then
		return nums
	end
	for k in pairs(t) do
		if type(k) == "number" then
			nums[#nums + 1] = k
		elseif type(k) == "string" then
			strs[#strs + 1] = k
		end
	end
	table.sort(nums)
	table.sort(strs)
	for _, k in ipairs(strs) do
		nums[#nums + 1] = k
	end
	return nums
end

-- DeepCopy(v) -> a fresh copy of v (tables walked in SortedKeys order).
function ABN_Util.DeepCopy(v, depth)
	if type(v) ~= "table" then
		return v
	end
	depth = depth or 0
	if depth > 20 then
		return nil
	end
	local out = {}
	for _, k in ipairs(ABN_Util.SortedKeys(v)) do
		out[k] = ABN_Util.DeepCopy(v[k], depth + 1)
	end
	return out
end

-- FindIndex(arr, fn) -> index, element of the first element with fn(e) true; nil.
function ABN_Util.FindIndex(arr, fn)
	for i, e in ipairs(arr or {}) do
		if fn(e) then
			return i, e
		end
	end
	return nil, nil
end

-- Filter(arr, fn) -> new array of the elements with fn(e) true (order kept).
function ABN_Util.Filter(arr, fn)
	local out = {}
	for _, e in ipairs(arr or {}) do
		if fn(e) then
			out[#out + 1] = e
		end
	end
	return out
end

-- Partition(arr, fn) -> kept, removed: removed holds the elements with fn(e)
-- true, kept the others; both keep the original order.
function ABN_Util.Partition(arr, fn)
	local kept, removed = {}, {}
	for _, e in ipairs(arr or {}) do
		if fn(e) then
			removed[#removed + 1] = e
		else
			kept[#kept + 1] = e
		end
	end
	return kept, removed
end

-- Contains(arr, v) -> bool.
function ABN_Util.Contains(arr, v)
	for _, e in ipairs(arr or {}) do
		if e == v then
			return true
		end
	end
	return false
end

-- SortedCopy(arr) -> ascending copy of an array of numbers (or strings).
function ABN_Util.SortedCopy(arr)
	local out = {}
	for _, e in ipairs(arr or {}) do
		out[#out + 1] = e
	end
	table.sort(out)
	return out
end

ABN_Util.LOADED = 1
