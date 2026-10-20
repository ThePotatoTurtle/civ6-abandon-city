-- ===========================================================================
-- ABN_Dev_Gameplay.lua  (ABN_Dev spike build 0.0.0.1, WP0; SPIKES.md)
-- Context: gameplay (AddGameplayScripts). TESTING ONLY. Standalone: needs no ABN\.
--
-- One synced handler, GameEvents.ABN_Dev(playerID, params), dispatching on
-- params.cmd (flat params from UI/ABN_Dev_Panel.lua; EFV_Dev_Gameplay.lua:5717
-- pattern). The requester (playerID) is the only trusted player ID.
--
-- Every engine call that is still PENDING-SPIKE (SPIKES.md status P) runs in
-- pcall after a type() check (M() below). Result lines:
--   [ABN][SPIKE] <id> <variant> T<turn> <key>=<value> ...
--   [ABN][CHECK] <ID> <PASS|FAIL|INFO> T<turn> <detail>   (tools\summarize_abn_log.py)
-- The last 12 kept lines also go to Game:SetProperty("ABN_SpikeLast", {...}) at
-- the end of every synced handler (and before each risky S1 call), so the
-- panel can show them even when Lua.log is lost in a crash.
--
-- MP rules (playbook 3): no pairs() over state, no math.random, no
-- Game.GetLocalPlayer, state changes only in GameEvents handlers. The one
-- Events.* subscription (CityRemovedFromMap, S1 probe) only prints.
--
-- Game properties written here (G only):
--   ABN_SpikeLast    array of the last 12 result lines (strings)
--   ABN_SpikeCities  array of {tag, x, y, id, owner, campus?, basePT?}
--   ABN_SpikeState   flat table of spike phases and armed turn-start actions
-- ===========================================================================

ABN_Dev = {}
ABN_Dev.VERSION = "0.0.0.1"

local PREFIX = "[ABN][SPIKE]"
local LAST_KEY = "ABN_SpikeLast"
local STATE_KEY = "ABN_SpikeState"
local CITIES_KEY = "ABN_SpikeCities"
local LAST_MAX = 12
local LINE_MAX = 300
local BARBARIAN_ID = 63
local FREE_CITIES_ID = 62
local ENEMY_RADIUS = 6

local CMD = {}
local m_Last = nil

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
local function Str(v)
	if v == nil then return "nil" end
	return tostring(v)
end

local function Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then return t end
	return -1
end

local function LoadLast()
	m_Last = {}
	local ok, v = pcall(function() return Game:GetProperty(LAST_KEY) end)
	if ok and type(v) == "table" then
		for _, s in ipairs(v) do
			if type(s) == "string" and s ~= "" then m_Last[#m_Last + 1] = s end
		end
	end
end

-- keep = true: also kept for ABN_SpikeLast (synced handlers only).
local function Emit(line, keep)
	print(line)
	if keep then
		if m_Last == nil then LoadLast() end
		m_Last[#m_Last + 1] = string.sub(line, 1, LINE_MAX)
		while #m_Last > LAST_MAX do table.remove(m_Last, 1) end
	end
end

local function Spike(id, variant, text)
	Emit(PREFIX .. " " .. id .. " " .. variant .. " T" .. Turn() .. " " .. Str(text), true)
end

-- Print-only line: verbose details (Lua.log only, not kept for the panel), and
-- the only kind of line allowed in async Events.* handlers (writes no state).
local function Note(id, variant, text)
	print(PREFIX .. " " .. id .. " " .. variant .. " T" .. Turn() .. " " .. Str(text))
end

local function Check(id, status, text)
	Emit("[ABN][CHECK] " .. id .. " " .. status .. " T" .. Turn() .. " " .. Str(text), true)
end

local function Flush()
	if m_Last == nil then LoadLast() end
	local ok, err = pcall(function() Game:SetProperty(LAST_KEY, m_Last) end)
	if not ok then print(PREFIX .. " DEV flush failed: " .. Str(err)) end
end

-- ---------------------------------------------------------------------------
-- Guarded calls: M(obj, "Name", fn) -> ok, a, b. ok = false with a = "MISSING"
-- when obj.Name is not a function; otherwise pcall(fn).
-- ---------------------------------------------------------------------------
local function Has(obj, name)
	if obj == nil then return false end
	local ok, t = pcall(function() return type(obj[name]) end)
	return ok and t == "function"
end

local function M(obj, name, fn)
	if not Has(obj, name) then return false, "MISSING" end
	local ok, a, b = pcall(fn)
	if not ok then return false, "ERR(" .. Str(a) .. ")" end
	return true, a, b
end

-- "value" or "MISSING" / "ERR(...)"
local function R(ok, v)
	if ok then return Str(v) end
	return Str(v)
end

local function Num(v, d)
	if type(v) ~= "number" then return Str(v) end
	local m = 10 ^ (d or 1)
	return tostring(math.floor(v * m + 0.5) / m)
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local function LoadState()
	local ok, s = pcall(function() return Game:GetProperty(STATE_KEY) end)
	if ok and type(s) == "table" then return s end
	return {}
end

local function SaveState(s)
	Game:SetProperty(STATE_KEY, s)
end

local function LoadCities()
	local ok, v = pcall(function() return Game:GetProperty(CITIES_KEY) end)
	local out = {}
	if ok and type(v) == "table" then
		for _, r in ipairs(v) do
			if type(r) == "table" and type(r.tag) == "string" then out[#out + 1] = r end
		end
	end
	return out
end

local function SaveCities(list)
	Game:SetProperty(CITIES_KEY, list)
end

local function FindRec(list, tag)
	for _, r in ipairs(list) do
		if r.tag == tag then return r end
	end
	return nil
end

-- The live city of a record (same plot, same owner), or nil.
local function RecCity(rec)
	if rec == nil then return nil end
	local c = CityManager.GetCityAt(rec.x, rec.y)
	if c == nil or c:GetOwner() ~= rec.owner then return nil end
	return c
end

local function CityOf(tag)
	local rec = FindRec(LoadCities(), tag)
	return RecCity(rec), rec
end

-- ---------------------------------------------------------------------------
-- Players and map helpers (EFV_Dev_Gameplay.lua:623-752 pattern)
-- ---------------------------------------------------------------------------
local function Alive(pid)
	local ok, a = pcall(function() return Players[pid] ~= nil and Players[pid]:IsAlive() end)
	return ok and a == true
end

local function IsMajor(pid)
	local ok, v = pcall(function() return Players[pid]:IsMajor() end)
	return ok and v == true
end

local function IsHuman(pid)
	local ok, v = pcall(function() return Players[pid]:IsHuman() end)
	return ok and v == true
end

-- Alive player IDs, ascending (GetAliveIDs has no useful order).
local function AliveIDs()
	local ids = {}
	local ok = pcall(function()
		for _, id in ipairs(PlayerManager.GetAliveIDs()) do ids[#ids + 1] = id end
	end)
	if not ok then ids = {} end
	table.sort(ids)
	return ids
end

local function CitiesOf(pid)
	local out = {}
	pcall(function()
		for _, city in Players[pid]:GetCities():Members() do out[#out + 1] = city end
	end)
	table.sort(out, function(a, b) return a:GetID() < b:GetID() end)
	return out
end

local function Capital(pid)
	local ok, c = pcall(function() return Players[pid]:GetCities():GetCapitalCity() end)
	if ok then return c end
	return nil
end

local function Dist(x1, y1, x2, y2)
	local ok, d = pcall(function() return Map.GetPlotDistance(x1, y1, x2, y2) end)
	if ok and type(d) == "number" then return d end
	return 999
end

-- Plots within r (sorted by index; deterministic).
local function Around(x, y, r)
	local out = {}
	local ok, plots = pcall(function() return Map.GetNeighborPlots(x, y, r) end)
	if ok and plots ~= nil then
		for _, p in ipairs(plots) do out[#out + 1] = p end
	end
	table.sort(out, function(a, b) return a:GetIndex() < b:GetIndex() end)
	return out
end

-- Plots at exactly distance ring (sorted by index).
local function Ring(x, y, ring)
	local out = {}
	for _, p in ipairs(Around(x, y, ring)) do
		if Dist(x, y, p:GetX(), p:GetY()) == ring then out[#out + 1] = p end
	end
	return out
end

local function PlotOwner(plot)
	local ok, o = pcall(function() return plot:GetOwner() end)
	if ok and type(o) == "number" then return o end
	return -1
end

local function FreeLand(p)
	local ok, free = pcall(function()
		return not p:IsWater() and not p:IsImpassable() and not p:IsNaturalWonder()
			and p:GetUnitCount() == 0 and CityManager.GetCityAt(p:GetX(), p:GetY()) == nil
	end)
	return ok and free == true
end

local function Neutral(p) return PlotOwner(p) < 0 end

local function FarFromCities(plot, minDist)
	for _, pid in ipairs(AliveIDs()) do
		for _, c in ipairs(CitiesOf(pid)) do
			if Dist(plot:GetX(), plot:GetY(), c:GetX(), c:GetY()) < minDist then return false end
		end
	end
	return true
end

local function FindPlot(x, y, minRing, maxRing, test)
	for ring = minRing, maxRing do
		for _, p in ipairs(Ring(x, y, ring)) do
			if FreeLand(p) and (test == nil or test(p)) then return p end
		end
	end
	return nil
end

-- A new city for pid on free neutral land 4-12 tiles from (x, y), at least 4
-- tiles from every city (EFV FoundCityFor, EFV_Dev_Gameplay.lua:1007-1016).
local function FoundCityFor(pid, x, y)
	local plot = FindPlot(x, y, 4, 12, function(q) return Neutral(q) and FarFromCities(q, 4) end)
	if plot == nil then return nil, "no free neutral land 4-12 tiles from the capital" end
	local ok, err = pcall(function() Players[pid]:GetCities():Create(plot:GetX(), plot:GetY()) end)
	local c = CityManager.GetCityAt(plot:GetX(), plot:GetY())
	if c == nil or c:GetOwner() ~= pid then
		return nil, "Create failed at " .. plot:GetX() .. "," .. plot:GetY() .. " ok=" .. tostring(ok) .. " err=" .. Str(err)
	end
	return c, "founded"
end

local function CityLabel(c)
	if c == nil then return "nil" end
	return Str(c:GetOwner()) .. "/" .. Str(c:GetID()) .. "@" .. Str(c:GetX()) .. "," .. Str(c:GetY())
end

local function UnitIndex(typeName)
	local ok, idx = pcall(function() return GameInfo.Units[typeName].Index end)
	if ok then return idx end
	return nil
end

local function UnitAt(owner, plot)
	local found = nil
	pcall(function()
		for _, u in ipairs(Units.GetUnitsInPlot(plot)) do
			if u:GetOwner() == owner then found = u end
		end
	end)
	return found
end

-- Creates a unit with GetUnits():Create (V for majors, EFV SPIKES.md:354).
local function CreateUnit(owner, typeName, plot)
	local idx = UnitIndex(typeName)
	if idx == nil then return nil, "no GameInfo.Units row " .. typeName end
	local ok, err = pcall(function() Players[owner]:GetUnits():Create(idx, plot:GetX(), plot:GetY()) end)
	local u = UnitAt(owner, plot)
	if u == nil then return nil, "Create ok=" .. tostring(ok) .. " err=" .. Str(err) end
	return u, "ok"
end

local function NearestAIMajor(me, x, y)
	local best, bestD = nil, 9999
	for _, pid in ipairs(AliveIDs()) do
		if pid ~= me and IsMajor(pid) and not IsHuman(pid) then
			local cap = Capital(pid)
			if cap ~= nil then
				local d = Dist(x, y, cap:GetX(), cap:GetY())
				if d < bestD then best, bestD = pid, d end
			end
		end
	end
	return best
end

local function SetMet(a, b)
	local ok, err = pcall(function() Players[a]:GetDiplomacy():SetHasMet(b) end)
	return ok, err
end

local function HasMet(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():HasMet(b) end)
	if ok then return v end
	return "ERR"
end

local function AtWar(a, b)
	local ok, v = pcall(function() return Players[a]:GetDiplomacy():IsAtWarWith(b) end)
	if ok then return v end
	return "ERR"
end

-- ---------------------------------------------------------------------------
-- S0 Setup
-- ---------------------------------------------------------------------------
local SETUP_TAGS = { "S3-C", "S3-A", "S3-B0", "S3-B1", "S3-B2", "S2", "S4" }
local CAMPUS_TAGS = { "S3-A", "S3-B0", "S3-B1", "S3-B2" }
local S3_TAGS = { "S3-C", "S3-A", "S3-B0", "S3-B1", "S3-B2" }
local SITE_TAGS = { "S3-C", "S3-A", "S3-B0", "S3-B1", "S3-B2", "S2" }

-- A free owned plot next to the city (no city, no district, not reserved).
local function AdjacentOwnedPlot(c, reserved)
	for _, p in ipairs(Ring(c:GetX(), c:GetY(), 1)) do
		local okD, d = pcall(function() return CityManager.GetDistrictAt(p:GetX(), p:GetY()) end)
		if PlotOwner(p) == c:GetOwner() and FreeLand(p) and okD and d == nil and not reserved[p:GetIndex()] then
			return p
		end
	end
	return nil
end

CMD.s0_setup = function(me, params)
	local cap = Capital(me)
	if cap == nil then
		Spike("S0", "setup", "no capital: found your capital first")
		return
	end
	local list = LoadCities()
	local made = 0
	for _, tag in ipairs(SETUP_TAGS) do
		local rec = FindRec(list, tag)
		local c = RecCity(rec)
		if c ~= nil then
			Note("S0", "city", tag .. " exists " .. CityLabel(c))
		else
			local nc, msg = FoundCityFor(me, cap:GetX(), cap:GetY())
			if nc ~= nil then
				if rec == nil then
					rec = { tag = tag }
					list[#list + 1] = rec
				end
				rec.x, rec.y, rec.id, rec.owner = nc:GetX(), nc:GetY(), nc:GetID(), me
				rec.campus = nil
				made = made + 1
				Note("S0", "city", tag .. " " .. msg .. " " .. CityLabel(nc) .. " dist=" .. Dist(cap:GetX(), cap:GetY(), nc:GetX(), nc:GetY()))
			else
				Spike("S0", "city", tag .. " FAILED: " .. Str(msg))
			end
		end
	end
	SaveCities(list)

	-- Campus districts (V G: BlackDeathScenario_Support.lua:318)
	local campusIdx = nil
	pcall(function() campusIdx = GameInfo.Districts["DISTRICT_CAMPUS"].Index end)
	local reserved = {}
	local campusCount = 0
	for _, tag in ipairs(CAMPUS_TAGS) do
		local rec = FindRec(list, tag)
		local c = RecCity(rec)
		if c ~= nil and rec.campus ~= nil then
			campusCount = campusCount + 1
			reserved[rec.campus] = true
		elseif c ~= nil and campusIdx ~= nil then
			local p = AdjacentOwnedPlot(c, reserved)
			if p == nil then
				Spike("S0", "campus", tag .. " no free owned plot next to the city")
			else
				local ok, err = pcall(function() WorldBuilder.CityManager():CreateDistrict(c, campusIdx, 100, p:GetIndex()) end)
				local okD, d = pcall(function() return CityManager.GetDistrictAt(p:GetX(), p:GetY()) end)
				local placed = okD and d ~= nil
				if placed then
					rec.campus = p:GetIndex()
					reserved[p:GetIndex()] = true
					campusCount = campusCount + 1
				end
				local line = (placed and Note or Spike)
				line("S0", "campus", tag .. " plot=" .. p:GetX() .. "," .. p:GetY() .. " ok=" .. tostring(ok) ..
					" err=" .. Str(err) .. " districtThere=" .. tostring(placed))
			end
		end
	end
	SaveCities(list)

	-- One wonder in S3-A (P: WorldBuilderPlacement.lua:1239, UI only)
	local recA = FindRec(list, "S3-A")
	local cA = RecCity(recA)
	if cA ~= nil then
		local p = AdjacentOwnedPlot(cA, reserved)
		if p == nil then
			Spike("S0", "wonder", "no free plot next to S3-A: wonder effect deferred")
		else
			local wb = nil
			pcall(function() wb = WorldBuilder.CityManager() end)
			local ok, a, b = M(wb, "CreateBuilding", function() return wb:CreateBuilding(cA, "BUILDING_STONEHENGE", 100, p:GetIndex()) end)
			Spike("S0", "wonder", "CreateBuilding(S3-A, BUILDING_STONEHENGE) plot=" .. p:GetX() .. "," .. p:GetY() ..
				" ok=" .. tostring(ok) .. " ret=" .. Str(a) .. " status=" .. type(b) .. (ok and "" or " (wonder effect deferred)"))
		end
	end

	-- Meet every alive major both ways (V G: AlexanderScenario.lua:13)
	local met = {}
	for _, pid in ipairs(AliveIDs()) do
		if pid ~= me and IsMajor(pid) then
			local ok1 = SetMet(me, pid)
			local ok2 = SetMet(pid, me)
			met[#met + 1] = pid .. "(" .. tostring(ok1) .. "/" .. tostring(ok2) .. ")"
		end
	end
	Note("S0", "met", "SetHasMet both ways: " .. table.concat(met, " "))

	local live = 0
	for _, tag in ipairs(SETUP_TAGS) do
		if RecCity(FindRec(list, tag)) ~= nil then live = live + 1 end
	end
	Check("S0_CITIES", live == #SETUP_TAGS and "PASS" or "FAIL", "live test cities=" .. live .. "/" .. #SETUP_TAGS .. " (new " .. made .. ")")
	Check("S0_CAMPUS", campusCount == #CAMPUS_TAGS and "PASS" or "FAIL", "campus districts=" .. campusCount .. "/" .. #CAMPUS_TAGS)
end

-- ---------------------------------------------------------------------------
-- P Probes (gameplay half; the panel runs the UI half)
-- ---------------------------------------------------------------------------
local function ProbeCity(label, c, expectCapital)
	if c == nil then
		Spike("P", label, "no city")
		return
	end
	local okC, isCap = M(c, "IsCapital", function() return c:IsCapital() end)
	local okO, isOrig = M(c, "IsOriginalCapital", function() return c:IsOriginalCapital() end)
	local okW, origOwner = M(c, "GetOriginalOwner", function() return c:GetOriginalOwner() end)
	local capByID = "nil"
	pcall(function()
		local cap = Players[c:GetOwner()]:GetCities():GetCapitalCity()
		capByID = tostring(cap ~= nil and cap:GetID() == c:GetID())
	end)
	Spike("P", label, CityLabel(c) .. " G IsCapital=" .. R(okC, isCap) .. " IsOriginalCapital=" .. R(okO, isOrig) ..
		" GetOriginalOwner=" .. R(okW, origOwner) .. " owner=" .. Str(c:GetOwner()) .. " capitalByID=" .. capByID)
	local good = okC and isCap == expectCapital and okO and isOrig == expectCapital and okW and origOwner == c:GetOwner()
	Check("P_" .. string.upper(string.gsub(label, "%W", "_")), good and "PASS" or "FAIL",
		"G IsCapital=" .. R(okC, isCap) .. " IsOriginalCapital=" .. R(okO, isOrig) .. " origOwner=" .. R(okW, origOwner) ..
		" expect capital=" .. tostring(expectCapital))
end

CMD.p_probes = function(me, params)
	local cap = Capital(me)
	ProbeCity("own_capital", cap, true)
	ProbeCity("S2", (CityOf("S2")), false)
	local ai = nil
	if cap ~= nil then ai = NearestAIMajor(me, cap:GetX(), cap:GetY()) end
	ProbeCity("ai_capital", ai and Capital(ai) or nil, true)
	local w62, w63 = AtWar(me, FREE_CITIES_ID), AtWar(me, BARBARIAN_ID)
	Spike("P", "war", "IsAtWarWith(62)=" .. Str(w62) .. " IsAtWarWith(63)=" .. Str(w63))
	Check("P_WAR63", w63 == true and "PASS" or "FAIL", "IsAtWarWith(63)=" .. Str(w63))
	Check("P_WAR62", "INFO", "IsAtWarWith(62)=" .. Str(w62))
	local majors = {}
	local okM = pcall(function()
		for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do majors[#majors + 1] = tostring(id) end
	end)
	local alive = {}
	for _, id in ipairs(AliveIDs()) do alive[#alive + 1] = tostring(id) end
	local okF, fc = pcall(function() return PlayerManager.GetFreeCitiesPlayerID() end)
	Spike("P", "players", "GetAliveMajorIDs ok=" .. tostring(okM) .. " [" .. table.concat(majors, ",") .. "] GetAliveIDs(sorted)=[" ..
		table.concat(alive, ",") .. "] GetFreeCitiesPlayerID=" .. R(okF, fc))
end

-- ---------------------------------------------------------------------------
-- S2 Population
-- ---------------------------------------------------------------------------
local function PopSnap(label, c)
	if c == nil then
		Spike("S2", label, "no S2 city")
		return nil
	end
	local pop = c:GetPopulation()
	local growth = nil
	pcall(function() growth = c:GetGrowth() end)
	local okH, housing = M(growth, "GetHousing", function() return growth:GetHousing() end)
	local okF, food = M(growth, "GetFood", function() return growth:GetFood() end)
	local okT, thr = M(growth, "GetGrowthThreshold", function() return growth:GetGrowthThreshold() end)
	local okS, sur = M(growth, "GetFoodSurplus", function() return growth:GetFoodSurplus() end)
	local okG, ttg = M(growth, "GetTurnsUntilGrowth", function() return growth:GetTurnsUntilGrowth() end)
	local cit = nil
	pcall(function() cit = c:GetCitizens() end)
	local worked, wn, wErr = {}, 0, nil
	for _, p in ipairs(Around(c:GetX(), c:GetY(), 3)) do
		if PlotOwner(p) == c:GetOwner() then
			local px, py = p:GetX(), p:GetY()
			local ok, w = M(cit, "IsPlotWorked", function() return cit:IsPlotWorked(px, py) end)
			if not ok then
				wErr = w
			elseif w == true then
				wn = wn + 1
				worked[#worked + 1] = px .. "," .. py
			end
		end
	end
	Spike("S2", label, "pop=" .. Str(pop) .. " housing=" .. R(okH, housing) .. " food=" .. R(okF, food) .. " threshold=" .. R(okT, thr) ..
		" surplus=" .. R(okS, sur) .. " turnsToGrow=" .. R(okG, ttg) .. " worked=" .. (wErr and ("? " .. wErr) or (wn .. " [" .. table.concat(worked, " ") .. "]")))
	return pop
end

local function ChangePop(c, delta)
	local ok, err = pcall(function() c:ChangePopulation(delta) end)
	return ok, err
end

CMD.s2a = function(me, params)
	local c = CityOf("S2")
	if c == nil then
		Spike("S2", "a", "no S2 city: run S0 Setup first")
		return
	end
	local pop = PopSnap("before", c)
	local ok, err = ChangePop(c, 8 - pop)
	Spike("S2", "a", "ChangePopulation(" .. (8 - pop) .. ") ok=" .. tostring(ok) .. " err=" .. Str(err))
	local after = PopSnap("control_to_8", c)
	Check("S2_POP8", after == 8 and "PASS" or "FAIL", "pop=" .. Str(after) .. " expect 8")
end

CMD.s2b = function(me, params)
	local c = CityOf("S2")
	if c == nil then
		Spike("S2", "b", "no S2 city: run S0 Setup first")
		return
	end
	local pop = PopSnap("before_cut", c)
	if pop - 2 >= 1 then
		local ok, err = ChangePop(c, -2)
		Spike("S2", "A", "ChangePopulation(-2) ok=" .. tostring(ok) .. " err=" .. Str(err))
		local a = PopSnap("after_A", c)
		Check("S2_POP6", a == pop - 2 and "PASS" or "FAIL", "pop=" .. Str(a) .. " expect " .. (pop - 2))
	else
		Spike("S2", "A", "skipped: pop " .. pop .. " too small")
	end
	pop = c:GetPopulation()
	local delta = 2 - pop
	if delta < 0 then
		local ok, err = ChangePop(c, delta)
		Spike("S2", "B", "ChangePopulation(" .. delta .. ") ok=" .. tostring(ok) .. " err=" .. Str(err))
	else
		Spike("S2", "B", "skipped: pop " .. pop .. " already <= 2")
	end
	local b = PopSnap("after_B", c)
	Check("S2_POP2", b == 2 and "PASS" or "FAIL", "pop=" .. Str(b) .. " expect 2")
	local st = LoadState()
	st.s2Turns = 2
	SaveState(st)
end

-- ---------------------------------------------------------------------------
-- S3 Loyalty
-- ---------------------------------------------------------------------------
local BITS = { 1, 2, 4, 8, 16 }

-- G reading: loyalty, per-turn (P in G: CityPanelCulture.lua:88,98 is UI).
local function Loy(c)
	local ci = nil
	pcall(function() ci = c:GetCulturalIdentity() end)
	local okL, loy = M(ci, "GetLoyalty", function() return ci:GetLoyalty() end)
	local okP, pt = M(ci, "GetLoyaltyPerTurn", function() return ci:GetLoyaltyPerTurn() end)
	return (okL and loy or nil), (okP and pt or nil), R(okL, loy), R(okP, pt)
end

local function PlotProps(c)
	local p = c:GetPlot()
	local parts = {}
	local okB1, b1 = M(p, "GetProperty", function() return p:GetProperty("ABN_SPK_B1") end)
	parts[#parts + 1] = "B1=" .. R(okB1, b1)
	local d = 0
	for _, b in ipairs(BITS) do
		local ok, v = M(p, "GetProperty", function() return p:GetProperty("ABN_SPK_DBIT_" .. b) end)
		if ok and v == 1 then d = d + b end
	end
	parts[#parts + 1] = "D=" .. d
	return table.concat(parts, " ")
end

local function SetPlotProp(c, key, v)
	local p = c:GetPlot()
	local ok, err = M(p, "SetProperty", function() p:SetProperty(key, v) end)
	return ok, err
end

local function SetBits(c, D)
	local on = {}
	for _, b in ipairs(BITS) do
		local v = (math.floor(D / b) % 2 == 1) and 1 or 0
		local ok, err = SetPlotProp(c, "ABN_SPK_DBIT_" .. b, v)
		if not ok then return false, err end
		if v == 1 then on[#on + 1] = tostring(b) end
	end
	return true, "bits on [" .. table.concat(on, ",") .. "]"
end

-- Expected per-turn change against the city's own baseline, by phase.
local EXPECT = {
	["S3-C"] = { 0, 0, 0 },
	["S3-A"] = { 0, 0, 0 },
	["S3-B0"] = { -6, -6, -6 },
	["S3-B1"] = { -6, 0, 0 },
	["S3-B2"] = { -6, -9, 0 },
}

-- One kept line per reading (all five cities: loyalty/perTurn and the plot
-- properties) and, when G can read the per-turn figure, one CHECK line per
-- phase comparing each city with its own baseline (EXPECT).
local function S3Read(label, phase, list)
	local parts, verdicts, allGood, readable = {}, {}, true, 0
	for _, tag in ipairs(S3_TAGS) do
		local rec = FindRec(list, tag)
		local c = RecCity(rec)
		if c == nil then
			parts[#parts + 1] = tag .. " gone"
		else
			local loy, pt, sLoy, sPt = Loy(c)
			parts[#parts + 1] = tag .. " " .. (loy and Num(loy) or sLoy) .. "/" .. (pt and Num(pt) or sPt) .. " " .. PlotProps(c)
			local ex = EXPECT[tag] and EXPECT[tag][phase] or nil
			if phase >= 1 and ex ~= nil and pt ~= nil and rec.basePT ~= nil then
				readable = readable + 1
				local delta = pt - rec.basePT
				local good = math.abs(delta - ex) < 0.51
				allGood = allGood and good
				verdicts[#verdicts + 1] = tag .. " " .. Num(delta) .. (good and "" or ("(want " .. ex .. ")"))
			end
		end
	end
	Spike("S3", label, "loyalty/perTurn: " .. table.concat(parts, "; "))
	if phase >= 1 and readable > 0 then
		Check("S3_P" .. phase, allGood and "PASS" or "FAIL", label .. " perTurn change vs own baseline: " .. table.concat(verdicts, ", "))
	elseif phase >= 1 then
		Note("S3", label, "perTurn unreadable in G: compare the UI lines and the city panel")
	end
end

local function ChangeLoy(c, n)
	local ok, err = M(c, "ChangeLoyalty", function() c:ChangeLoyalty(n) end)
	return ok, err
end

local function Attach(c, id)
	local ok, r = M(c, "AttachModifierByID", function() return c:AttachModifierByID(id) end)
	return ok, r
end

CMD.s3_step = function(me, params)
	local st = LoadState()
	local list = LoadCities()
	local phase = (st.s3Phase or 0) + 1
	if phase > 3 then
		Spike("S3", "step", "all 3 clicks done (phase " .. (phase - 1) .. "); readings only")
		S3Read("extra", 3, list)
		return
	end
	local function C(tag) return RecCity(FindRec(list, tag)) end
	if phase == 1 then
		S3Read("baseline", 0, list)
		for _, tag in ipairs(S3_TAGS) do
			local c = C(tag)
			if c ~= nil then
				local ok, err = ChangeLoy(c, -40)
				local _, pt = Loy(c)
				FindRec(list, tag).basePT = pt
				Spike("S3", tag, "setup ChangeLoyalty(-40) ok=" .. tostring(ok) .. " err=" .. Str(err) .. " basePT=" .. Num(pt))
			end
		end
		local cA, cB0, cB1, cB2 = C("S3-A"), C("S3-B0"), C("S3-B1"), C("S3-B2")
		if cA ~= nil then
			local ok, err = ChangeLoy(cA, -6)
			Spike("S3", "A", "ChangeLoyalty(-6) ok=" .. tostring(ok) .. " err=" .. Str(err) .. " (repeats at every turn start until click 3)")
			st.s3A = 1
		end
		if cB0 ~= nil then
			local ok, r = Attach(cB0, "ABN_SPK_LOY_B0")
			Spike("S3", "B0", "AttachModifierByID(ABN_SPK_LOY_B0) ok=" .. tostring(ok) .. " ret=" .. Str(r))
		end
		if cB1 ~= nil then
			local ok, r = Attach(cB1, "ABN_SPK_LOY_B1")
			local okP, errP = SetPlotProp(cB1, "ABN_SPK_B1", 1)
			Spike("S3", "B1", "AttachModifierByID(ABN_SPK_LOY_B1) ok=" .. tostring(ok) .. " ret=" .. Str(r) ..
				"; plot:SetProperty(ABN_SPK_B1,1) ok=" .. tostring(okP) .. " err=" .. Str(errP))
		end
		if cB2 ~= nil then
			local ok, msg = SetBits(cB2, 6)
			Spike("S3", "B2", "D=6 ok=" .. tostring(ok) .. " " .. Str(msg))
		end
	elseif phase == 2 then
		local cB1, cB2 = C("S3-B1"), C("S3-B2")
		if cB1 ~= nil then
			local ok, err = SetPlotProp(cB1, "ABN_SPK_B1", 0)
			Spike("S3", "B1", "off: plot:SetProperty(ABN_SPK_B1,0) ok=" .. tostring(ok) .. " err=" .. Str(err))
		end
		if cB2 ~= nil then
			local ok, msg = SetBits(cB2, 9)
			Spike("S3", "B2", "re-level D=9 ok=" .. tostring(ok) .. " " .. Str(msg))
		end
	else
		st.s3A = 0
		Spike("S3", "A", "stop: no more ChangeLoyalty(-6)")
		local cB2 = C("S3-B2")
		if cB2 ~= nil then
			local ok, msg = SetBits(cB2, 0)
			Spike("S3", "B2", "off D=0 ok=" .. tostring(ok) .. " " .. Str(msg))
		end
	end
	st.s3Phase = phase
	SaveCities(list)
	SaveState(st)
	S3Read("after_click" .. phase, phase, list)
end

-- ---------------------------------------------------------------------------
-- S4 Siege, damage, enemies near
-- ---------------------------------------------------------------------------
local function CentreDistrict(c)
	local ok, d = pcall(function() return CityManager.GetDistrictAt(c:GetX(), c:GetY()) end)
	if ok then return d end
	return nil
end

local function DamageText(c)
	local d = CentreDistrict(c)
	if d == nil then return "no centre district" end
	local okG, g = M(d, "GetDamage", function() return d:GetDamage(DefenseTypes.DISTRICT_GARRISON) end)
	local okGM, gm = M(d, "GetMaxDamage", function() return d:GetMaxDamage(DefenseTypes.DISTRICT_GARRISON) end)
	local okO, o = M(d, "GetDamage", function() return d:GetDamage(DefenseTypes.DISTRICT_OUTER) end)
	local okOM, om = M(d, "GetMaxDamage", function() return d:GetMaxDamage(DefenseTypes.DISTRICT_OUTER) end)
	local okS, s = M(d, "IsUnderSiege", function() return d:IsUnderSiege() end)
	return "garrison=" .. R(okG, g) .. "/" .. R(okGM, gm) .. " outer=" .. R(okO, o) .. "/" .. R(okOM, om) ..
		" G IsUnderSiege=" .. R(okS, s)
end

local function IsCivilian(u)
	local ok, fc = pcall(function() return GameInfo.Units[u:GetType()].FormationClass end)
	return ok and fc == "FORMATION_CLASS_CIVILIAN"
end

-- The planned 6-tile scan: at-war players plus 62 and 63, military units only.
local function EnemyScan(me, x, y, radius)
	local hits = {}
	for _, pid in ipairs(AliveIDs()) do
		if pid ~= me and (pid == FREE_CITIES_ID or pid == BARBARIAN_ID or AtWar(me, pid) == true) then
			local list = {}
			pcall(function()
				for _, u in Players[pid]:GetUnits():Members() do list[#list + 1] = u end
			end)
			table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
			for _, u in ipairs(list) do
				local d = Dist(x, y, u:GetX(), u:GetY())
				if d <= radius and not IsCivilian(u) then
					hits[#hits + 1] = pid .. "/" .. u:GetID() .. "@" .. u:GetX() .. "," .. u:GetY() .. " d=" .. d
				end
			end
		end
	end
	return hits
end

-- A barbarian warrior at exactly ring tiles: variant A GetUnits():Create, then B InitUnit.
local function BarbarianAt(c, ring)
	local p = FindPlot(c:GetX(), c:GetY(), ring, ring, nil)
	if p == nil then
		Spike("S4", "barb" .. ring, "no free land at exactly " .. ring .. " tiles")
		return nil
	end
	local u, msg = CreateUnit(BARBARIAN_ID, "UNIT_WARRIOR", p)
	if u ~= nil then
		Spike("S4", "barb" .. ring, "variant A Players[63]:GetUnits():Create ok at " .. p:GetX() .. "," .. p:GetY())
		return u
	end
	Spike("S4", "barb" .. ring, "variant A failed: " .. Str(msg))
	local ok, err = pcall(function() UnitManager.InitUnit(BARBARIAN_ID, "UNIT_WARRIOR", p:GetX(), p:GetY()) end)
	u = UnitAt(BARBARIAN_ID, p)
	Spike("S4", "barb" .. ring, "variant B UnitManager.InitUnit(63) ok=" .. tostring(ok) .. " err=" .. Str(err) ..
		" unit=" .. tostring(u ~= nil) .. " at " .. p:GetX() .. "," .. p:GetY())
	return u
end

CMD.s4_run = function(me, params)
	local c = CityOf("S4")
	if c == nil then
		Spike("S4", "run", "no S4 city: run S0 Setup first")
		return
	end
	local E = NearestAIMajor(me, c:GetX(), c:GetY())
	if E == nil then
		Spike("S4", "run", "no AI major with a capital")
		return
	end
	SetMet(me, E)
	SetMet(E, me)
	local okW, errW = pcall(function() Players[me]:GetDiplomacy():DeclareWarOn(E, WarTypes.FORMAL_WAR, true) end)
	Spike("S4", "war", "DeclareWarOn(" .. E .. ") ok=" .. tostring(okW) .. " err=" .. Str(errW) .. " IsAtWarWith me->E=" ..
		Str(AtWar(me, E)) .. " E->me=" .. Str(AtWar(E, me)))
	local made, firstE = 0, nil
	for _, p in ipairs(Ring(c:GetX(), c:GetY(), 1)) do
		if FreeLand(p) then
			local u = CreateUnit(E, "UNIT_WARRIOR", p)
			if u ~= nil then
				made = made + 1
				firstE = firstE or u
			end
		end
	end
	Spike("S4", "surround", "E=" .. E .. " warriors created next to S4: " .. made)
	local d = CentreDistrict(c)
	local okD, errD = M(d, "SetDamage", function() d:SetDamage(DefenseTypes.DISTRICT_GARRISON, 40) end)
	Spike("S4", "damage", "SetDamage(GARRISON,40) ok=" .. tostring(okD) .. " err=" .. Str(errD) .. " " .. DamageText(c))
	BarbarianAt(c, 6)
	BarbarianAt(c, 7)
	local hits = EnemyScan(me, c:GetX(), c:GetY(), ENEMY_RADIUS)
	Spike("S4", "scan", "within " .. ENEMY_RADIUS .. ": " .. #hits .. " [" .. table.concat(hits, "; ") .. "]")
	local has6, has7 = false, false
	for _, h in ipairs(hits) do
		if string.find(h, "^63/") and string.find(h, " d=6$") then has6 = true end
		if string.find(h, "^63/") and string.find(h, " d=7$") then has7 = true end
	end
	Check("S4_SCAN", (has6 and not has7) and "PASS" or "FAIL", "barbarian at 6 listed=" .. tostring(has6) .. " at 7 listed=" .. tostring(has7))
	-- One own warrior next to an E warrior, with full moves
	local own = nil
	if firstE ~= nil then
		for _, p in ipairs(Ring(firstE:GetX(), firstE:GetY(), 1)) do
			if own == nil and FreeLand(p) then own = CreateUnit(me, "UNIT_WARRIOR", p) end
		end
	end
	if own ~= nil then
		local okM, mv = pcall(function() return own:GetMovesRemaining() .. "/" .. own:GetMaxMoves() end)
		Spike("S4", "attacker", "your warrior " .. own:GetID() .. " at " .. own:GetX() .. "," .. own:GetY() .. " moves=" .. R(okM, mv) ..
			" next to E warrior " .. firstE:GetID() .. ": attack it")
	else
		Spike("S4", "attacker", "no free plot next to an E warrior for your warrior")
	end
	local st = LoadState()
	st.s4Watch = 1
	st.s4E = E
	SaveState(st)
end

CMD.s4_read = function(me, params)
	local c = CityOf("S4")
	if c == nil then
		Spike("S4", "read", "no S4 city")
		return
	end
	Spike("S4", "read", CityLabel(c) .. " " .. DamageText(c))
	local hits = EnemyScan(me, c:GetX(), c:GetY(), ENEMY_RADIUS)
	Spike("S4", "read", "scan " .. #hits .. " [" .. table.concat(hits, "; ") .. "]")
end

local function OnCombat(aP, aU, dP, dU, aD, dD)
	local text = "OnCombatOccurred a=" .. Str(aP) .. "/" .. Str(aU) .. " d=" .. Str(dP) .. "/" .. Str(dU) ..
		" aD=" .. Str(aD) .. " dD=" .. Str(dD)
	if type(dD) == "number" and dD >= 0 and type(dP) == "number" and dP >= 0 then
		local dist = nil
		pcall(function() dist = Players[dP]:GetDistricts():FindID(dD) end)
		local okX, dx = M(dist, "GetX", function() return dist:GetX() end)
		local okY, dy = M(dist, "GetY", function() return dist:GetY() end)
		local city = nil
		if okX and okY then city = CityManager.GetCityAt(dx, dy) end
		text = text .. " defenderDistrict=" .. tostring(dist ~= nil) .. " at " .. R(okX, dx) .. "," .. R(okY, dy) ..
			" city=" .. CityLabel(city)
	end
	Spike("S4", "combat", text)
	Flush()
end

-- ---------------------------------------------------------------------------
-- S5 Notifications
-- ---------------------------------------------------------------------------
local function SendNotif(pid, typeName, x, y)
	local row = GameInfo.Types[typeName]
	if row == nil then return false, "no Types row" end
	local data = {}
	local t = Turn()
	if typeName == "ABN_DEV_NOTIF_A" then
		data[ParameterTypes.MESSAGE] = Locale.Lookup("LOC_ABN_DEV_NOTIF_A_MESSAGE", t)
		data[ParameterTypes.SUMMARY] = Locale.Lookup("LOC_ABN_DEV_NOTIF_A_SUMMARY", t)
	else
		data[ParameterTypes.MESSAGE] = Locale.Lookup("LOC_ABN_DEV_NOTIF_B_MESSAGE", t)
		data[ParameterTypes.SUMMARY] = Locale.Lookup("LOC_ABN_DEV_NOTIF_B_SUMMARY", t)
	end
	if type(x) == "number" and type(y) == "number" and x >= 0 then
		data[ParameterTypes.LOCATION] = { x = x, y = y }
	end
	data.AlwaysUnique = true
	data.ABN_Turn = t
	local ok, err = pcall(function() NotificationManager.SendNotification(pid, row.Hash, data) end)
	return ok, err
end

local function SendLine(pid, typeName, x, y)
	local ok, err = SendNotif(pid, typeName, x, y)
	Spike("S5", typeName, "to=" .. pid .. " location=" .. (x and (x .. "," .. y) or "none") .. " ok=" .. tostring(ok) .. " err=" .. Str(err))
end

local function MetLines(me)
	local sum = {}
	for _, v in ipairs(AliveIDs()) do
		if v ~= me and IsMajor(v) then
			sum[#sum + 1] = v .. ":" .. Str(HasMet(v, me)) .. "/" .. Str(HasMet(me, v))
			Note("S5", "met", "P" .. v .. " human=" .. tostring(IsHuman(v)) .. " Players[" .. v .. "]:HasMet(" .. me .. ")=" ..
				Str(HasMet(v, me)) .. " Players[" .. me .. "]:HasMet(" .. v .. ")=" .. Str(HasMet(me, v)))
		end
	end
	Spike("S5", "met", "HasMet v->me/me->v: " .. table.concat(sum, " "))
end

-- Other alive human majors, ascending (hotseat P1, P2).
local function OtherHumans(me)
	local out = {}
	for _, v in ipairs(AliveIDs()) do
		if v ~= me and IsMajor(v) and IsHuman(v) then out[#out + 1] = v end
	end
	return out
end

CMD.s5_self = function(me, params)
	local c = CityOf("S4")
	local x, y = nil, nil
	if c ~= nil then x, y = c:GetX(), c:GetY() end
	SendLine(me, "ABN_DEV_NOTIF_A", x, y)
	SendLine(me, "ABN_DEV_NOTIF_B", nil, nil)
	MetLines(me)
	local st = LoadState()
	st.s5Arm, st.s5Owner = 1, me
	SaveState(st)
	Spike("S5", "arm", "A will be sent to " .. me .. " at the next OnGameTurnStarted")
end

CMD.s5_hs_setup = function(me, params)
	local cap = Capital(me)
	local list = LoadCities()
	local rec = FindRec(list, "HS")
	if RecCity(rec) == nil and cap ~= nil then
		local nc, msg = FoundCityFor(me, cap:GetX(), cap:GetY())
		if nc ~= nil then
			if rec == nil then
				rec = { tag = "HS" }
				list[#list + 1] = rec
			end
			rec.x, rec.y, rec.id, rec.owner = nc:GetX(), nc:GetY(), nc:GetID(), me
			SaveCities(list)
		end
		Spike("S5", "hs_setup", "city HS " .. Str(msg) .. " " .. CityLabel(nc))
	end
	local others = OtherHumans(me)
	local p1, p2 = others[1], others[2]
	if p1 ~= nil then
		local ok1 = SetMet(me, p1)
		local ok2 = SetMet(p1, me)
		Spike("S5", "hs_setup", "SetHasMet " .. me .. "<->" .. p1 .. " ok=" .. tostring(ok1) .. "/" .. tostring(ok2))
	else
		Spike("S5", "hs_setup", "no second human player: start a hotseat game")
	end
	for _, v in ipairs({ p1, p2 }) do
		Spike("S5", "hs_met", "P" .. v .. " HasMet(" .. me .. ")=" .. Str(HasMet(v, me)) .. " " .. me .. ".HasMet(" .. v .. ")=" .. Str(HasMet(me, v)))
	end
	if p2 ~= nil and HasMet(p2, me) == true then
		Spike("S5", "hs_setup", "NOTE P" .. p2 .. " has already met P" .. me .. " on the map (no un-meet call)")
	end
end

-- Recipients: the owner plus each alive human v with Players[v]:HasMet(owner).
local function HotseatRecipients(me)
	local out = { me }
	for _, v in ipairs(OtherHumans(me)) do
		if HasMet(v, me) == true then out[#out + 1] = v end
	end
	return out
end

CMD.s5_hs_send = function(me, params)
	local c = CityOf("HS")
	local x, y = nil, nil
	if c ~= nil then x, y = c:GetX(), c:GetY() end
	local to = HotseatRecipients(me)
	for _, v in ipairs(to) do
		SendLine(v, "ABN_DEV_NOTIF_A", x, y)
		SendLine(v, "ABN_DEV_NOTIF_B", nil, nil)
	end
	local others = OtherHumans(me)
	Spike("S5", "hs_send", "recipients=[" .. table.concat(to, ",") .. "] other humans=[" .. table.concat(others, ",") .. "]")
	local st = LoadState()
	st.s5Arm, st.s5Owner = 2, me
	SaveState(st)
end

-- ---------------------------------------------------------------------------
-- S1 City removal
-- ---------------------------------------------------------------------------
local function CityByPlot(rec)
	if rec == nil then return nil end
	return CityManager.GetCityAt(rec.x, rec.y)
end

local function SiteSnap(label, rec)
	if rec == nil then return end
	local c = CityByPlot(rec)
	local head = rec.tag .. " " .. label .. " plot=" .. rec.x .. "," .. rec.y
	if c == nil then
		head = head .. " city=GONE"
	else
		local count = "?"
		pcall(function() count = tostring(Players[c:GetOwner()]:GetCities():GetCount()) end)
		head = head .. " city=" .. CityLabel(c) .. " pop=" .. Str(c:GetPopulation()) .. " ownerCities=" .. count
	end
	-- units within 2 tiles, all alive players
	local units = {}
	for _, pid in ipairs(AliveIDs()) do
		local n = 0
		pcall(function()
			for _, u in Players[pid]:GetUnits():Members() do
				if Dist(rec.x, rec.y, u:GetX(), u:GetY()) <= 2 then n = n + 1 end
			end
		end)
		if n > 0 then units[#units + 1] = pid .. ":" .. n end
	end
	-- plot owners within 3 rings
	local owners, order = {}, {}
	for _, p in ipairs(Around(rec.x, rec.y, 3)) do
		local o = PlotOwner(p)
		if owners[o] == nil then
			owners[o] = 0
			order[#order + 1] = o
		end
		owners[o] = owners[o] + 1
	end
	table.sort(order)
	local own = {}
	for _, o in ipairs(order) do own[#own + 1] = o .. ":" .. owners[o] end
	local campus = "n/a"
	if rec.campus ~= nil then
		pcall(function()
			local p = Map.GetPlotByIndex(rec.campus)
			campus = tostring(CityManager.GetDistrictAt(p:GetX(), p:GetY()) ~= nil)
		end)
	end
	local relig, trade = "n/a", "n/a"
	if c ~= nil then
		local rel = nil
		pcall(function() rel = c:GetReligion() end)
		local okR, r = M(rel, "GetMajorityReligion", function() return rel:GetMajorityReligion() end)
		relig = R(okR, r)
		local tr = nil
		pcall(function() tr = c:GetTrade() end)
		local okT, routes = M(tr, "GetOutgoingRoutes", function() return tr:GetOutgoingRoutes() end)
		trade = okT and tostring(type(routes) == "table" and #routes or routes) or Str(routes)
	end
	Note("S1", "snap", head .. " units2=[" .. table.concat(units, " ") .. "] owners3=[" .. table.concat(own, " ") ..
		"] campus=" .. campus .. " religion=" .. relig .. " routes=" .. trade)
end

local function SnapAll(label)
	local list = LoadCities()
	local sum = {}
	for _, tag in ipairs(SITE_TAGS) do
		local rec = FindRec(list, tag)
		SiteSnap(label, rec)
		if rec ~= nil then
			local c = CityByPlot(rec)
			local units = 0
			pcall(function()
				for _, u in Players[rec.owner]:GetUnits():Members() do
					if Dist(rec.x, rec.y, u:GetX(), u:GetY()) <= 1 then units = units + 1 end
				end
			end)
			local owner = -1
			pcall(function() owner = Map.GetPlot(rec.x, rec.y):GetOwner() end)
			sum[#sum + 1] = tag .. "=" .. (c and "live" or "GONE") .. "(own units<=1:" .. units .. " plotOwner:" .. owner .. ")"
		end
	end
	Spike("S1", label, table.concat(sum, " "))
end

-- G variants. Each returns ok, msg; the caller confirms with GetCityAt.
local function RunG1(c)
	local coll = nil
	pcall(function() coll = Players[c:GetOwner()]:GetCities() end)
	return M(coll, "Destroy", function() coll:Destroy(c) end)
end

local function RunG2(c)
	local ok, isTbl = pcall(function() return type(Cities) == "table" and type(Cities.DestroyCity) == "function" end)
	if not (ok and isTbl) then return false, "MISSING" end
	local okC, err = pcall(function() Cities.DestroyCity(c) end)
	if not okC then return false, "ERR(" .. Str(err) .. ")" end
	return true
end

local function RunG3(c)
	local wb = nil
	pcall(function() wb = WorldBuilder.CityManager() end)
	return M(wb, "Remove", function() wb:Remove(c) end)
end

local VARIANTS = {
	{ id = "G1", tag = "S3-A", call = "Players[o]:GetCities():Destroy(pCity)", fn = RunG1 },
	{ id = "G2", tag = "S3-B0", call = "Cities.DestroyCity(pCity)", fn = RunG2 },
	{ id = "G3", tag = "S3-B1", call = "WorldBuilder.CityManager():Remove(pCity)", fn = RunG3 },
}

local function VariantByID(id)
	for _, v in ipairs(VARIANTS) do
		if v.id == id then return v end
	end
	return nil
end

-- Runs variant v on c; writes "about to run" to ABN_SpikeLast first. Returns removed.
local function RunVariant(v, c, where, st)
	local x, y = c:GetX(), c:GetY()
	Spike("S1", v.id, "about to run " .. v.call .. " on " .. where .. " " .. CityLabel(c))
	Flush()
	local ok, err = v.fn(c)
	local gone = CityManager.GetCityAt(x, y) == nil
	Spike("S1", v.id, where .. " ok=" .. tostring(ok) .. " err=" .. Str(err) .. " removed=" .. tostring(gone))
	Check("S1_" .. v.id .. (where == "S2" and "_TURNSTART" or ""), gone and "PASS" or "FAIL",
		v.call .. " on " .. where .. ": removed=" .. tostring(gone) .. " ok=" .. tostring(ok) .. " err=" .. Str(err))
	if gone and st.s1Worked == nil then st.s1Worked = v.id end
	return gone
end

local function ArmUnits(me, list)
	for _, tag in ipairs(CAMPUS_TAGS) do
		local c = RecCity(FindRec(list, tag))
		if c ~= nil then
			local centre = c:GetPlot()
			local w = CreateUnit(me, "UNIT_WARRIOR", centre)
			local b = nil
			for _, p in ipairs(Ring(c:GetX(), c:GetY(), 1)) do
				if b == nil and FreeLand(p) then b = CreateUnit(me, "UNIT_BUILDER", p) end
			end
			Note("S1", "units", tag .. " warrior=" .. tostring(w ~= nil) .. " builder=" .. tostring(b ~= nil))
		end
	end
end

CMD.s1_run = function(me, params)
	local list = LoadCities()
	local st = LoadState()
	ArmUnits(me, list)
	SnapAll("before")
	for _, v in ipairs(VARIANTS) do
		local c = RecCity(FindRec(list, v.tag))
		if c == nil then
			Spike("S1", v.id, v.tag .. " is already gone (or not set up)")
		else
			RunVariant(v, c, v.tag, st)
		end
	end
	SnapAll("after")
	st.s1Watch = 1
	SaveState(st)
	Spike("S1", "result", "first working G variant=" .. Str(st.s1Worked))
end

CMD.s1_check = function(me, params)
	SnapAll("check")
	local st = LoadState()
	st.s1Watch = 1
	SaveState(st)
end

CMD.s1_arm_t = function(me, params)
	local st = LoadState()
	st.s1ArmT = 1
	SaveState(st)
	Spike("S1", "T", "armed: S2 is removed at the next OnGameTurnStarted with " .. Str(st.s1Worked or "the first G variant that works"))
end

-- Recovery after a crash: one variant per click (G1, then G2, then G3).
CMD.s1_one = function(me, params)
	local st = LoadState()
	local n = st.s1OneNext or 1
	local v = VARIANTS[n]
	if v == nil then
		Spike("S1", "one", "all three G variants tried")
		return
	end
	st.s1OneNext = n + 1
	SaveState(st)
	local c = RecCity(FindRec(LoadCities(), v.tag))
	if c == nil then
		Spike("S1", "one", v.id .. ": " .. v.tag .. " is gone or missing")
	else
		RunVariant(v, c, v.tag, st)
		SaveState(st)
	end
end

CMD.s1_hs_arm = function(me, params)
	local c, rec = CityOf("HS")
	if c == nil then c, rec = CityOf("S2") end
	if c == nil then
		Spike("S1", "hs_arm", "no HS or S2 city: run S5 HS Setup first")
		return
	end
	local st = LoadState()
	st.hsX, st.hsY, st.hsOwner = c:GetX(), c:GetY(), me
	st.hsSeq = (st.hsSeq or 0) + 1
	SaveState(st)
	Spike("S1", "hs_arm", "stored x=" .. c:GetX() .. " y=" .. c:GetY() .. " owner=" .. me .. " seq=" .. st.hsSeq ..
		" (" .. rec.tag .. "); the UI raze fires only when the local player is " .. me)
end

-- ---------------------------------------------------------------------------
-- Turn start (synced) and the Events probe
-- ---------------------------------------------------------------------------
local function Step(name, fn)
	local ok, err = pcall(fn)
	if not ok then Emit(PREFIX .. "[turn_" .. name .. "] G ERROR " .. Str(err), true) end
end

local function OnGameTurnStarted(turn)
	Spike("P", "turn", "OnGameTurnStarted arg=" .. Str(turn) .. " Game.GetCurrentGameTurn()=" .. Turn())
	local st = LoadState()
	Step("s2", function()
		if (st.s2Turns or 0) > 0 then
			PopSnap("turn_start", (CityOf("S2")))
			st.s2Turns = st.s2Turns - 1
		end
	end)
	Step("s3", function()
		if (st.s3Phase or 0) >= 1 then
			local list = LoadCities()
			if st.s3A == 1 then
				local c = RecCity(FindRec(list, "S3-A"))
				if c ~= nil then
					local before = Loy(c)
					local ok, err = ChangeLoy(c, -6)
					local after = Loy(c)
					Spike("S3", "A", "turn start ChangeLoyalty(-6) ok=" .. tostring(ok) .. " err=" .. Str(err) ..
						" loyalty " .. Num(before) .. " -> " .. Num(after))
				end
			end
			S3Read("turn_start", st.s3Phase, list)
		end
	end)
	Step("s4", function()
		if st.s4Watch == 1 then
			local c = CityOf("S4")
			if c ~= nil then Spike("S4", "turn_start", CityLabel(c) .. " " .. DamageText(c)) end
		end
	end)
	Step("s5", function()
		if st.s5Arm == 1 or st.s5Arm == 2 then
			local owner = st.s5Owner or 0
			local to = { owner }
			if st.s5Arm == 2 then to = HotseatRecipients(owner) end
			local c = CityOf(st.s5Arm == 2 and "HS" or "S4")
			local x, y = nil, nil
			if c ~= nil then x, y = c:GetX(), c:GetY() end
			for _, v in ipairs(to) do SendLine(v, "ABN_DEV_NOTIF_A", x, y) end
			st.s5Arm = 0
		end
	end)
	Step("s1", function()
		if st.s1ArmT == 1 then
			st.s1ArmT = 0
			local c = CityOf("S2")
			local v = VariantByID(st.s1Worked or "")
			if c == nil then
				Spike("S1", "T", "S2 is already gone")
			elseif v == nil then
				Spike("S1", "T", "none: no G variant worked, S2 stays")
				Check("S1_TURNSTART", "FAIL", "no working G variant")
			else
				RunVariant(v, c, "S2", st)
			end
		end
		if st.s1Watch == 1 then
			SnapAll("turn_start")
			st.s1Watch = 0
		end
		if st.hsOwner ~= nil and CityManager.GetCityAt(st.hsX, st.hsY) == nil then
			Spike("S1", "hs", "armed city at " .. st.hsX .. "," .. st.hsY .. " is gone: disarmed")
			st.hsX, st.hsY, st.hsOwner = nil, nil, nil
		end
	end)
	SaveState(st)
	Flush()
end

-- S1 probe: does Events.CityRemovedFromMap fire in gameplay? Print only.
local function OnCityRemovedG(pid, cityID)
	Note("S1", "G_event", "Events.CityRemovedFromMap fired in gameplay pid=" .. Str(pid) .. " cityID=" .. Str(cityID))
end

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
function ABN_Dev.OnRequest(playerID, params)
	if type(params) ~= "table" then
		Spike("DEV", "dispatch", "non-table params")
		Flush()
		return
	end
	local cmd = params.cmd
	local fn = CMD[cmd]
	if fn == nil then
		Spike("DEV", "dispatch", "unknown cmd " .. Str(cmd))
		Flush()
		return
	end
	Spike("DEV", "cmd", Str(cmd) .. " from P" .. Str(playerID) .. " stamp=" .. Str(params.stamp))
	local ok, err = pcall(fn, playerID, params)
	if not ok then
		Emit(PREFIX .. "[" .. Str(cmd) .. "] G ERROR " .. Str(err), true)
	end
	Flush()
end

ABN_Dev.CMD = CMD
ABN_Dev.OnGameTurnStarted = OnGameTurnStarted
ABN_Dev.OnCombat = OnCombat

GameEvents.ABN_Dev.Add(ABN_Dev.OnRequest)
GameEvents.OnGameTurnStarted.Add(OnGameTurnStarted)
GameEvents.OnCombatOccurred.Add(OnCombat)

local function SubscribeG()
	local okE = pcall(function() return Events ~= nil and Events.CityRemovedFromMap ~= nil end)
	if not okE then
		print(PREFIX .. " S1 G_event Events is not reachable in gameplay")
		return
	end
	local ok, err = pcall(function() Events.CityRemovedFromMap.Add(OnCityRemovedG) end)
	print(PREFIX .. " S1 G_event subscribe Events.CityRemovedFromMap in gameplay ok=" .. tostring(ok) .. " err=" .. Str(err))
end
SubscribeG()

print(PREFIX .. " DEV init ABN_Dev gameplay " .. ABN_Dev.VERSION .. " loaded; GameEvents.ABN_Dev registered")
