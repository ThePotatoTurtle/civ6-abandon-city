-- ===========================================================================
-- ABN_Dev_Core.lua  (ABN_Dev 0.1.0.0, WP9)
-- Module:   ABN_Dev_Core (global table), gameplay. TESTING ONLY.
-- Content:  logging ([ABN][DEV] and [ABN][CHECK] lines, the tally, the lines
--           the panel shows), the dev Game-property store, and the player,
--           map, unit and city helpers shared by ABN_Dev_Scenario and
--           ABN_Dev_Check.
--
-- Game properties written here (G only; flat numbers and strings, arrays of
-- flat tables):
--   ABN_DevState    {focus, checker, seq, nextTag}
--   ABN_DevTally    {pass, fail, lastFail}
--   ABN_DevLast     array of the last lines (strings) for the panel
--   ABN_DevCities   array {tag, owner, id, x, y, pop0}  test city registry
--
-- MP rules (playbook 3): no pairs(), no math.random, no Game.GetLocalPlayer,
-- no os.*; every list is sorted by ID or plot index; state changes only in
-- GameEvents handlers (ABN_Dev request, OnGameTurnStarted).
-- ===========================================================================

if ABN_Dev_Core ~= nil and ABN_Dev_Core.LOADED == 1 then
	return
end

include("ABN_Config")

ABN_Dev_Core = {}
local C = ABN_Dev_Core

C.VERSION = "0.1.0.0"
C.KEY = {
	STATE  = "ABN_DevState",
	TALLY  = "ABN_DevTally",
	LAST   = "ABN_DevLast",
	CITIES = "ABN_DevCities",
	LEDGER = "ABN_DevLedger",
	ARM    = "ABN_DevArm",
	DMG    = "ABN_DevDamage",
	ORIG   = "ABN_DevOrigCaps",
	POPS   = "ABN_DevPops",
	PROBE  = "ABN_DevProbe",
	STAMP  = "ABN_DevStamp",
}

-- The spec numbers the dev checks are written against (spec 1.2); they are
-- deliberately not read from ABN_Config so a wrong config value shows up.
C.ENEMY_RADIUS = 6
C.DAMAGE_MEMORY_TURNS = 5
C.FREE_CITIES_ID = 62
C.BARBARIAN_ID = 63
C.MIN_CITY_DIST = 4

local LAST_MAX = 18
local LINE_MAX = 300

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
function C.Str(v)
	if v == nil then return "nil" end
	return tostring(v)
end

function C.Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then return t end
	return -1
end

function C.ReadProp(key)
	local ok, v = pcall(function() return Game:GetProperty(key) end)
	if ok then return v end
	return nil
end

-- Ordered array property: only the table elements, in order, never nil.
function C.ReadArr(key)
	local out = {}
	local v = C.ReadProp(key)
	if type(v) == "table" then
		for _, e in ipairs(v) do
			if type(e) == "table" then out[#out + 1] = e end
		end
	end
	return out
end

function C.WriteProp(key, value)
	local ok, err = pcall(function() Game:SetProperty(key, value) end)
	if not ok then print("[ABN][DEV] property write failed " .. key .. ": " .. C.Str(err)) end
	return ok
end

-- ---------------------------------------------------------------------------
-- Dev state (flat table) and tally
-- ---------------------------------------------------------------------------
function C.State()
	local v = C.ReadProp(C.KEY.STATE)
	if type(v) ~= "table" then v = {} end
	if v.checker == nil then v.checker = 1 end
	if v.seq == nil then v.seq = 0 end
	if v.nextTag == nil then v.nextTag = 1 end
	return v
end

function C.SaveState(st)
	C.WriteProp(C.KEY.STATE, st)
end

-- Next number for IDs that must stay unique in the log (the summarizer keeps the
-- latest verdict per ID, so a repeated ID would hide an earlier FAIL).
function C.NextSeq()
	local st = C.State()
	st.seq = st.seq + 1
	C.SaveState(st)
	return st.seq
end

local m_Last = nil
local m_Tally = nil

local function LoadLast()
	m_Last = {}
	local v = C.ReadProp(C.KEY.LAST)
	if type(v) == "table" then
		for _, s in ipairs(v) do
			if type(s) == "string" and s ~= "" then m_Last[#m_Last + 1] = s end
		end
	end
end

local function LoadTally()
	m_Tally = { pass = 0, fail = 0, lastFail = "none" }
	local v = C.ReadProp(C.KEY.TALLY)
	if type(v) == "table" then
		m_Tally.pass = tonumber(v.pass) or 0
		m_Tally.fail = tonumber(v.fail) or 0
		if type(v.lastFail) == "string" then m_Tally.lastFail = v.lastFail end
	end
end

local function Keep(line)
	if m_Last == nil then LoadLast() end
	m_Last[#m_Last + 1] = string.sub(line, 1, LINE_MAX)
	while #m_Last > LAST_MAX do table.remove(m_Last, 1) end
end

-- Info line: [ABN][DEV] T<turn> text
function C.Info(text)
	local line = "[ABN][DEV] T" .. C.Turn() .. " " .. C.Str(text)
	print(line)
	Keep(line)
end

-- Print-only line (details; not kept for the panel).
function C.Note(text)
	print("[ABN][DEV] T" .. C.Turn() .. " " .. C.Str(text))
end

-- Check line: [ABN][CHECK] <ID> <PASS|FAIL|INFO|CHECK> T<turn> text.
-- The ID has no spaces. PASS and FAIL are counted.
function C.Check(id, status, text)
	if m_Tally == nil then LoadTally() end
	local line = "[ABN][CHECK] " .. C.Str(id) .. " " .. status .. " T" .. C.Turn() .. " " .. C.Str(text)
	print(line)
	if status == "PASS" then
		m_Tally.pass = m_Tally.pass + 1
	elseif status == "FAIL" then
		m_Tally.fail = m_Tally.fail + 1
		m_Tally.lastFail = C.Str(id)
	end
	if status ~= "PASS" then Keep(line) end
end

function C.Tally()
	if m_Tally == nil then LoadTally() end
	return m_Tally.pass, m_Tally.fail
end

function C.ResetTally()
	m_Tally = { pass = 0, fail = 0, lastFail = "none" }
end

-- Writes the panel lines and the tally (end of every synced entry point).
function C.Flush(stamp)
	if m_Last == nil then LoadLast() end
	if m_Tally == nil then LoadTally() end
	C.WriteProp(C.KEY.LAST, m_Last)
	C.WriteProp(C.KEY.TALLY, { pass = m_Tally.pass, fail = m_Tally.fail, lastFail = m_Tally.lastFail })
	if type(stamp) == "number" then C.WriteProp(C.KEY.STAMP, stamp) end
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------
function C.Alive(pid)
	local ok, a = pcall(function() return Players[pid] ~= nil and Players[pid]:IsAlive() end)
	return ok and a == true
end

function C.IsMajor(pid)
	local ok, v = pcall(function() return Players[pid]:IsMajor() end)
	return ok and v == true
end

function C.IsHuman(pid)
	local ok, v = pcall(function() return Players[pid]:IsHuman() end)
	return ok and v == true
end

-- Alive player IDs, ascending (GetAliveIDs has no useful order).
function C.AliveIDs()
	local ids = {}
	local ok = pcall(function()
		for _, id in ipairs(PlayerManager.GetAliveIDs()) do ids[#ids + 1] = id end
	end)
	if not ok then ids = {} end
	table.sort(ids)
	return ids
end

-- Cities of a player, ascending ID.
function C.CitiesOf(pid)
	local out = {}
	pcall(function()
		for _, city in Players[pid]:GetCities():Members() do out[#out + 1] = city end
	end)
	table.sort(out, function(a, b) return a:GetID() < b:GetID() end)
	return out
end

function C.CityCount(pid)
	local ok, n = pcall(function() return Players[pid]:GetCities():GetCount() end)
	if ok and type(n) == "number" then return n end
	return #C.CitiesOf(pid)
end

function C.Capital(pid)
	local ok, c = pcall(function() return Players[pid]:GetCities():GetCapitalCity() end)
	if ok then return c end
	return nil
end

function C.SetMet(a, b)
	return pcall(function() Players[a]:GetDiplomacy():SetHasMet(b) end)
end

function C.HasMet(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():HasMet(b) end)
	if ok then return v end
	return "ERR"
end

function C.AtWar(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():IsAtWarWith(b) end)
	if ok then return v end
	return "ERR"
end

-- The AI major whose capital is closest to (x, y), or nil.
function C.NearestAIMajor(me, x, y)
	local best, bestD = nil, 9999
	for _, pid in ipairs(C.AliveIDs()) do
		if pid ~= me and C.IsMajor(pid) and not C.IsHuman(pid) then
			local cap = C.Capital(pid)
			if cap ~= nil then
				local d = C.Dist(x, y, cap:GetX(), cap:GetY())
				if d < bestD then best, bestD = pid, d end
			end
		end
	end
	return best
end

-- ---------------------------------------------------------------------------
-- Map
-- ---------------------------------------------------------------------------
function C.Dist(x1, y1, x2, y2)
	local ok, d = pcall(function() return Map.GetPlotDistance(x1, y1, x2, y2) end)
	if ok and type(d) == "number" then return d end
	return 999
end

-- Plots within r (centre included), sorted by plot index.
function C.Around(x, y, r)
	local out = {}
	local ok, plots = pcall(function() return Map.GetNeighborPlots(x, y, r) end)
	if ok and plots ~= nil then
		for _, p in ipairs(plots) do out[#out + 1] = p end
	end
	table.sort(out, function(a, b) return a:GetIndex() < b:GetIndex() end)
	return out
end

-- Plots at exactly distance ring (sorted by index).
function C.Ring(x, y, ring)
	local out = {}
	for _, p in ipairs(C.Around(x, y, ring)) do
		if C.Dist(x, y, p:GetX(), p:GetY()) == ring then out[#out + 1] = p end
	end
	return out
end

function C.PlotOwner(plot)
	local ok, o = pcall(function() return plot:GetOwner() end)
	if ok and type(o) == "number" then return o end
	return -1
end

function C.PlotIndexOf(c)
	local ok, i = pcall(function() return c:GetPlot():GetIndex() end)
	if ok and type(i) == "number" then return i end
	return -1
end

function C.FreeLand(p)
	local ok, free = pcall(function()
		return not p:IsWater() and not p:IsImpassable() and not p:IsNaturalWonder()
			and p:GetUnitCount() == 0 and CityManager.GetCityAt(p:GetX(), p:GetY()) == nil
	end)
	return ok and free == true
end

function C.FarFromCities(plot, minDist)
	for _, pid in ipairs(C.AliveIDs()) do
		for _, c in ipairs(C.CitiesOf(pid)) do
			if C.Dist(plot:GetX(), plot:GetY(), c:GetX(), c:GetY()) < minDist then return false end
		end
	end
	return true
end

-- First site on rings minRing..maxRing around (x, y): free land, neutral or owned
-- by pid, at least MIN_CITY_DIST from every city, and passing test(plot).
function C.FindSite(pid, x, y, minRing, maxRing, test)
	for ring = minRing, maxRing do
		for _, p in ipairs(C.Ring(x, y, ring)) do
			local o = C.PlotOwner(p)
			if C.FreeLand(p) and (o < 0 or o == pid) and C.FarFromCities(p, C.MIN_CITY_DIST)
					and (test == nil or test(p)) then
				return p
			end
		end
	end
	return nil
end

-- Free land (no city, no unit) at exactly ring tiles; any owner.
function C.FindFreeRingPlot(x, y, ring)
	for _, p in ipairs(C.Ring(x, y, ring)) do
		if C.FreeLand(p) then return p end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Cities and units
-- ---------------------------------------------------------------------------
function C.CityLabel(c)
	if c == nil then return "nil" end
	return C.Str(c:GetOwner()) .. "/" .. C.Str(c:GetID()) .. "@" .. C.Str(c:GetX()) .. "," .. C.Str(c:GetY())
end

-- The city at (x, y) when it belongs to owner (and has cityID, when given).
function C.CityAt(x, y, owner, cityID)
	if type(x) ~= "number" or type(y) ~= "number" then return nil end
	local ok, c = pcall(function() return CityManager.GetCityAt(x, y) end)
	if not ok or c == nil then return nil end
	if owner ~= nil and c:GetOwner() ~= owner then return nil end
	if cityID ~= nil and c:GetID() ~= cityID then return nil end
	return c
end

-- Founds a city for pid at plot: GetCities():Create(x, y) (AustraliaScenario.lua:1163).
function C.FoundCity(pid, plot)
	local ok, err = pcall(function() Players[pid]:GetCities():Create(plot:GetX(), plot:GetY()) end)
	local c = CityManager.GetCityAt(plot:GetX(), plot:GetY())
	if c == nil or c:GetOwner() ~= pid then
		return nil, "Create failed at " .. plot:GetX() .. "," .. plot:GetY() .. " ok=" .. tostring(ok) .. " err=" .. C.Str(err)
	end
	return c, "founded"
end

function C.UnitIndex(typeName)
	local ok, idx = pcall(function() return GameInfo.Units[typeName].Index end)
	if ok then return idx end
	return nil
end

function C.UnitAt(owner, plot)
	local found = nil
	pcall(function()
		for _, u in ipairs(Units.GetUnitsInPlot(plot)) do
			if u:GetOwner() == owner then found = u end
		end
	end)
	return found
end

-- Creates a unit with GetUnits():Create (works for majors and for player 63, spike S4).
function C.CreateUnit(owner, typeName, plot)
	local idx = C.UnitIndex(typeName)
	if idx == nil then return nil, "no GameInfo.Units row " .. typeName end
	local ok, err = pcall(function() Players[owner]:GetUnits():Create(idx, plot:GetX(), plot:GetY()) end)
	local u = C.UnitAt(owner, plot)
	if u == nil then return nil, "Create ok=" .. tostring(ok) .. " err=" .. C.Str(err) end
	return u, "ok"
end

function C.IsCivilian(u)
	local ok, fc = pcall(function() return GameInfo.Units[u:GetType()].FormationClass end)
	return ok and fc == "FORMATION_CLASS_CIVILIAN"
end

-- Hostile military units within radius of (x, y) for owner (spec 1.2 rule 2):
-- players at war with owner plus 62 and 63; civilians ignored.
-- Returns a list of {pid, id, x, y, d}, ordered by player then unit ID.
function C.EnemyScan(owner, x, y, radius)
	local hits = {}
	for _, pid in ipairs(C.AliveIDs()) do
		if pid ~= owner and (pid == C.FREE_CITIES_ID or pid == C.BARBARIAN_ID or C.AtWar(owner, pid) == true) then
			local list = {}
			pcall(function()
				for _, u in Players[pid]:GetUnits():Members() do list[#list + 1] = u end
			end)
			table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
			for _, u in ipairs(list) do
				local d = C.Dist(x, y, u:GetX(), u:GetY())
				if d <= radius and not C.IsCivilian(u) then
					hits[#hits + 1] = { pid = pid, id = u:GetID(), x = u:GetX(), y = u:GetY(), d = d }
				end
			end
		end
	end
	return hits
end

-- City centre damage: garrison, outer (numbers, 0 when unreadable).
function C.Damage(c)
	local g, o = 0, 0
	pcall(function()
		local d = CityManager.GetDistrictAt(c:GetX(), c:GetY())
		if d ~= nil then
			g = d:GetDamage(DefenseTypes.DISTRICT_GARRISON) or 0
			o = d:GetDamage(DefenseTypes.DISTRICT_OUTER) or 0
		end
	end)
	return g, o
end

-- ---------------------------------------------------------------------------
-- Test city registry and focus
-- ---------------------------------------------------------------------------
function C.Registry()
	return C.ReadArr(C.KEY.CITIES)
end

function C.SaveRegistry(list)
	C.WriteProp(C.KEY.CITIES, list)
end

-- Registers a city under a new tag (C1, C2, ...). Returns the tag.
function C.AddCity(c, pop0)
	local st = C.State()
	local tag = "C" .. st.nextTag
	st.nextTag = st.nextTag + 1
	C.SaveState(st)
	local list = C.Registry()
	list[#list + 1] = { tag = tag, owner = c:GetOwner(), id = c:GetID(), x = c:GetX(), y = c:GetY(), pop0 = pop0 or c:GetPopulation() }
	C.SaveRegistry(list)
	return tag
end

-- Tag of a city: "CAP" for the owner's capital, its registry tag, else X<x>_<y>.
function C.TagOf(c)
	if c == nil then return "none" end
	local cap = C.Capital(c:GetOwner())
	if cap ~= nil and cap:GetID() == c:GetID() then return "CAP" end
	for _, r in ipairs(C.Registry()) do
		if r.owner == c:GetOwner() and r.x == c:GetX() and r.y == c:GetY() and r.id == c:GetID() then return r.tag end
	end
	return "X" .. c:GetX() .. "_" .. c:GetY()
end

-- The live city of a registry tag (or "CAP" for the requester's capital).
function C.CityByTag(tag, me)
	if tag == "CAP" then return C.Capital(me) end
	for _, r in ipairs(C.Registry()) do
		if r.tag == tag then return C.CityAt(r.x, r.y, r.owner, r.id) end
	end
	return nil
end

function C.SetFocus(tag)
	local st = C.State()
	st.focus = tag
	C.SaveState(st)
end

-- The target city of a request: the city the panel sent (the one open in the city
-- panel) when it is the requester's, else the focus city, else the capital.
function C.ResolveTarget(me, params)
	if type(params) == "table" and type(params.cityID) == "number" and params.cityID >= 0 then
		local c = C.CityAt(params.x, params.y, me, params.cityID)
		if c ~= nil then return c, C.TagOf(c) end
	end
	local st = C.State()
	if type(st.focus) == "string" then
		local c = C.CityByTag(st.focus, me)
		if c ~= nil then return c, st.focus end
	end
	local cap = C.Capital(me)
	if cap ~= nil then return cap, "CAP" end
	return nil, "none"
end

C.LOADED = 1
