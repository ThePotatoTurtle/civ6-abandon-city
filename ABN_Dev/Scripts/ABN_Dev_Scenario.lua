-- ===========================================================================
-- ABN_Dev_Scenario.lua  (ABN_Dev 0.1.0.0, WP9)
-- Module:   ABN_Dev_Scenario (global table), gameplay. TESTING ONLY.
-- Content:  the scenario commands behind the panel buttons: test cities of a
--           chosen size, neighbours at exact distances, enemies at exact
--           distances, damage, siege, war, meeting, the last-city case, and
--           the expected-timeline print. Each command verifies its own
--           set-up with a [ABN][CHECK] line, so the log shows whether the
--           scenario really exists. Commands are called as
--             ABN_Dev_Scenario.CMD[name](requesterID, params)
--           by the ABN_Dev dispatcher (ABN_Dev_Gameplay.lua), which runs in a
--           synced EXECUTE_SCRIPT handler.
--
-- Uses only calls proven in the spike session (GetCities():Create, Destroy,
-- ChangePopulation, GetUnits():Create, SetDamage, DeclareWarOn, SetHasMet).
-- The selected city (cityID, x, y in the params) wins over the focus city.
-- ===========================================================================

if ABN_Dev_Scenario ~= nil and ABN_Dev_Scenario.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Rules")
include("ABN_Dev_Core")
include("ABN_Dev_Check")

-- ABN:GLOBALS ABN_Config ABN_Rules
ABN_Dev_Scenario = {}
local S = ABN_Dev_Scenario
local C = ABN_Dev_Core
local X = ABN_Dev_Check
local K = C.KEY

local CMD = {}
S.CMD = CMD

local function Fail(id, text)
	C.Check(id .. "_" .. C.NextSeq(), "FAIL", text)
end

-- The city the command acts on, with a message when there is none.
local function Target(me, params, what)
	local c, tag = C.ResolveTarget(me, params)
	if c == nil then
		Fail(what or "TARGET", "no target city: found your capital, make a test city or open a city first")
		return nil, "none"
	end
	return c, tag
end

local function Distance(c, p)
	return C.Dist(c:GetX(), c:GetY(), p:GetX(), p:GetY())
end

-- Founds a pop-N city for me at the plot, registers it, and verifies the result.
local function MakeCity(me, plot, pop, label, anchor)
	local c, msg = C.FoundCity(me, plot)
	if c == nil then
		Fail("MAKE", label .. ": " .. C.Str(msg))
		return nil, nil
	end
	if pop > 1 then
		local ok, err = pcall(function() c:ChangePopulation(pop - 1) end)
		if not ok then C.Info("ChangePopulation failed: " .. C.Str(err)) end
	end
	local tag = C.AddCity(c, pop)
	local got = c:GetPopulation()
	local detail = label .. " " .. C.CityLabel(c) .. " pop=" .. got .. " (wanted " .. pop .. ")"
	if anchor ~= nil then detail = detail .. " distance " .. Distance(anchor, plot) .. " from " .. C.TagOf(anchor) end
	C.Check("MAKE_" .. tag, got == pop and "PASS" or "FAIL", detail)
	return c, tag
end

-- ---------------------------------------------------------------------------
-- Test cities
-- ---------------------------------------------------------------------------
CMD.make_city = function(me, params)
	local pop = tonumber(params.pop) or 1
	if pop < 1 then pop = 1 end
	if pop > 40 then pop = 40 end
	local anchor = C.ResolveTarget(me, nil)
	if anchor == nil then
		Fail("MAKE", "found your capital first")
		return
	end
	local plot = C.FindSite(me, anchor:GetX(), anchor:GetY(), C.MIN_CITY_DIST, 12, nil)
	if plot == nil then
		local cap = C.Capital(me)
		if cap ~= nil then plot = C.FindSite(me, cap:GetX(), cap:GetY(), C.MIN_CITY_DIST, 12, nil) end
	end
	if plot == nil then
		Fail("MAKE", "no free land 4-12 tiles from " .. C.TagOf(anchor) .. " or the capital")
		return
	end
	local c, tag = MakeCity(me, plot, pop, "test city", anchor)
	if c ~= nil then
		C.SetFocus(tag)
		C.Info("focus is now " .. tag .. " (pop " .. c:GetPopulation() .. ")")
	end
end

-- Neighbours of the target at exact distances (pop 3 each).
local function Neighbours(me, params, rings, what)
	local t, tag = Target(me, params, what)
	if t == nil then return end
	local made = {}
	for _, ring in ipairs(rings) do
		local plot = C.FindSite(me, t:GetX(), t:GetY(), ring, ring, nil)
		if plot == nil then
			Fail("NBR", "no free site at exactly " .. ring .. " tiles from " .. tag)
		else
			local c, ntag = MakeCity(me, plot, 3, "neighbour at " .. ring, t)
			if c ~= nil then
				local d = Distance(t, plot)
				C.Check("NBR_" .. ntag .. "_d" .. ring, d == ring and "PASS" or "FAIL", ntag .. " is " .. d .. " tiles from " .. tag .. " (wanted " .. ring .. ")")
				made[#made + 1] = ntag .. "@" .. ring
			end
		end
	end
	local pop = t:GetPopulation()
	C.Info(what .. " around " .. tag .. " (pop " .. pop .. "): " .. table.concat(made, " ") ..
		"; if " .. tag .. " is abandoned now its radius is " .. ABN_Config.R(pop) .. " and D is " .. ABN_Config.D(pop))
end

CMD.nbrs_7_10 = function(me, params)
	Neighbours(me, params, { 7, 10 }, "neighbours at 7 and 10")
end

CMD.nbrs_r = function(me, params)
	local t = Target(me, params, "NBR")
	if t == nil then return end
	local r = ABN_Config.R(t:GetPopulation())
	Neighbours(me, params, { r, r + 1 }, "neighbours at R and R+1 (R=" .. r .. ")")
end

-- A second city B (pop 4) near the target, and a neighbour N inside both radii.
CMD.overlap = function(me, params)
	local t, tag = Target(me, params, "OVERLAP")
	if t == nil then return end
	local bPlot = C.FindSite(me, t:GetX(), t:GetY(), 5, 6, nil)
	if bPlot == nil then
		Fail("OVERLAP", "no free site 5-6 tiles from " .. tag)
		return
	end
	local b, btag = MakeCity(me, bPlot, 4, "overlap B", t)
	if b == nil then return end
	local nPlot = C.FindSite(me, t:GetX(), t:GetY(), 4, 6, function(p)
		local d = Distance(b, p)
		return d >= C.MIN_CITY_DIST and d <= 6
	end)
	if nPlot == nil then
		Fail("OVERLAP", "no free site for N within 6 tiles of both " .. tag .. " and " .. btag)
		return
	end
	local n, ntag = MakeCity(me, nPlot, 3, "overlap N", t)
	if n ~= nil then
		C.Info("overlap set: abandon " .. tag .. " (pop " .. t:GetPopulation() .. ") and " .. btag .. " (pop 4); " .. ntag ..
			" is " .. Distance(t, nPlot) .. " tiles from " .. tag .. " and " .. Distance(b, nPlot) .. " from " .. btag ..
			": its loyalty drop should be D(" .. tag .. ")+D(" .. btag .. ") = " .. ABN_Config.D(t:GetPopulation()) .. "+" .. ABN_Config.D(4))
	end
end

-- Focus: the next city of the cycle capital, C1, C2, ...
CMD.focus_next = function(me, params)
	local tags = { "CAP" }
	for _, r in ipairs(C.Registry()) do
		if r.owner == me and C.CityAt(r.x, r.y, r.owner, r.id) ~= nil then tags[#tags + 1] = r.tag end
	end
	local st = C.State()
	local cur = 0
	for i, t in ipairs(tags) do
		if t == st.focus then cur = i end
	end
	local nxt = tags[(cur % #tags) + 1]
	C.SetFocus(nxt)
	local c = C.CityByTag(nxt, me)
	C.Info("focus is now " .. nxt .. (c ~= nil and (" " .. C.CityLabel(c) .. " pop=" .. c:GetPopulation()) or " (missing)"))
end

CMD.focus_sel = function(me, params)
	local c, tag = Target(me, params, "FOCUS")
	if c == nil then return end
	if tag == "none" then return end
	if string.sub(tag, 1, 1) == "X" then
		tag = C.AddCity(c, c:GetPopulation())
	end
	C.SetFocus(tag)
	C.Info("focus is now " .. tag .. " " .. C.CityLabel(c) .. " pop=" .. c:GetPopulation())
end

-- ---------------------------------------------------------------------------
-- Diplomacy
-- ---------------------------------------------------------------------------
CMD.meet_all = function(me, params)
	local met = {}
	for _, pid in ipairs(C.AliveIDs()) do
		if pid ~= me and C.IsMajor(pid) then
			C.SetMet(me, pid)
			C.SetMet(pid, me)
			met[#met + 1] = pid .. (C.IsHuman(pid) and "(human)" or "(AI)")
		end
	end
	-- who should receive the owner's notifications (humans that have met the owner)
	local who = { me .. "(owner)" }
	for _, pid in ipairs(C.AliveIDs()) do
		if pid ~= me and C.IsMajor(pid) and C.IsHuman(pid) and C.HasMet(pid, me) == true then who[#who + 1] = tostring(pid) end
	end
	C.Check("MEET_" .. C.NextSeq(), "INFO", "met both ways with " .. table.concat(met, " ") ..
		"; notifications for P" .. me .. " should reach: " .. table.concat(who, " "))
end

-- Hotseat: meet only the next human major (lowest ID above me, else the lowest
-- other one), so a third human stays unmet (spec 4, session test 6).
CMD.meet_human = function(me, params)
	local first, after = nil, nil
	for _, pid in ipairs(C.AliveIDs()) do
		if pid ~= me and C.IsMajor(pid) and C.IsHuman(pid) then
			if first == nil then first = pid end
			if after == nil and pid > me then after = pid end
		end
	end
	local other = after or first
	if other == nil then
		C.Check("MEET_" .. C.NextSeq(), "INFO", "no other human major to meet (hotseat only)")
		return
	end
	C.SetMet(me, other)
	C.SetMet(other, me)
	local who = { me .. "(owner)" }
	for _, pid in ipairs(C.AliveIDs()) do
		if pid ~= me and C.IsMajor(pid) and C.IsHuman(pid) and C.HasMet(pid, me) == true then who[#who + 1] = tostring(pid) end
	end
	C.Check("MEET_" .. C.NextSeq(), C.HasMet(other, me) == true and "PASS" or "FAIL", "met both ways with human P" .. other ..
		"; notifications for P" .. me .. " should reach: " .. table.concat(who, " "))
end

local function DeclareWar(me, x, y)
	local E = C.NearestAIMajor(me, x, y)
	if E == nil then return nil end
	C.SetMet(me, E)
	C.SetMet(E, me)
	if C.AtWar(me, E) ~= true then
		pcall(function() Players[me]:GetDiplomacy():DeclareWarOn(E, WarTypes.FORMAL_WAR, true) end)
	end
	return E
end

CMD.war_ai = function(me, params)
	local t = Target(me, params, "WAR")
	if t == nil then return end
	local E = DeclareWar(me, t:GetX(), t:GetY())
	if E == nil then
		Fail("WAR", "no AI major with a capital to fight")
		return
	end
	local a, b = C.AtWar(me, E), C.AtWar(E, me)
	C.Check("WAR_" .. C.NextSeq(), (a == true and b == true) and "PASS" or "FAIL", "war with P" .. E .. ": me->E=" .. C.Str(a) .. " E->me=" .. C.Str(b))
end

-- ---------------------------------------------------------------------------
-- Enemies at an exact distance
-- ---------------------------------------------------------------------------
-- params.dist = tiles, params.kind = "ai" (nearest AI major, at war) | "barb" (63) | "free" (62)
CMD.enemy = function(me, params)
	local t, tag = Target(me, params, "ENEMY")
	if t == nil then return end
	local d = tonumber(params.dist) or 6
	local kind = params.kind
	local owner
	if kind == "barb" then
		owner = C.BARBARIAN_ID
	elseif kind == "free" then
		owner = C.FREE_CITIES_ID
	else
		kind = "ai"
		owner = DeclareWar(me, t:GetX(), t:GetY())
		if owner == nil then
			Fail("ENEMY", "no AI major with a capital to use as the enemy")
			return
		end
	end
	local plot = C.FindFreeRingPlot(t:GetX(), t:GetY(), d)
	if plot == nil then
		Fail("ENEMY", "no free land at exactly " .. d .. " tiles from " .. tag)
		return
	end
	local u, msg = C.CreateUnit(owner, "UNIT_WARRIOR", plot)
	local id = "ENEMY_" .. tag .. "_d" .. d .. "_" .. kind .. "_" .. C.NextSeq()
	if u == nil then
		C.Check(id, "FAIL", "could not create a warrior for P" .. owner .. ": " .. C.Str(msg))
		return
	end
	local actual = Distance(t, plot)
	local exp = #C.EnemyScan(me, t:GetX(), t:GetY(), C.ENEMY_RADIUS) > 0
	local ok, got = pcall(ABN_Rules.EnemyNear, t:GetX(), t:GetY(), me, C.ENEMY_RADIUS)
	local detail = "P" .. owner .. " warrior at distance " .. actual .. " from " .. tag .. " (wanted " .. d .. "); enemies within " ..
		C.ENEMY_RADIUS .. ": expected EnemyNear=" .. tostring(exp) .. " got=" .. C.Str(got)
	if actual ~= d then
		C.Check(id, "FAIL", detail .. " (distance)")
	elseif not ok then
		C.Check(id, "FAIL", detail .. " (ABN_Rules.EnemyNear raised: " .. C.Str(got) .. ")")
	else
		C.Check(id, got == exp and "PASS" or "FAIL", detail)
	end
	X.ProbeCity(me, t)
end

CMD.besiege = function(me, params)
	local t, tag = Target(me, params, "SIEGE")
	if t == nil then return end
	local E = DeclareWar(me, t:GetX(), t:GetY())
	if E == nil then
		Fail("SIEGE", "no AI major with a capital to besiege with")
		return
	end
	local made = 0
	for _, p in ipairs(C.Ring(t:GetX(), t:GetY(), 1)) do
		if C.FreeLand(p) then
			if C.CreateUnit(E, "UNIT_WARRIOR", p) ~= nil then made = made + 1 end
		end
	end
	local exp = #C.EnemyScan(me, t:GetX(), t:GetY(), C.ENEMY_RADIUS) > 0
	local ok, got = pcall(ABN_Rules.EnemyNear, t:GetX(), t:GetY(), me, C.ENEMY_RADIUS)
	local id = "SIEGE_" .. tag .. "_" .. C.NextSeq()
	local detail = "P" .. E .. " warriors on the " .. made .. " free tiles around " .. tag .. "; EnemyNear expected=" .. tostring(exp) .. " got=" .. C.Str(got)
	C.Check(id, (made > 0 and ok and got == exp and exp == true) and "PASS" or "FAIL", detail)
	X.ProbeCity(me, t)
end

-- ---------------------------------------------------------------------------
-- Damage
-- ---------------------------------------------------------------------------
-- params.kind = "g" (garrison) | "o" (outer, needs walls); params.amount
local function SetDamageOn(c, defense, amount)
	local d = CityManager.GetDistrictAt(c:GetX(), c:GetY())
	if d == nil then return nil, nil, "no city centre district" end
	local max = d:GetMaxDamage(defense) or 0
	local ok, err = pcall(function() d:SetDamage(defense, amount) end)
	if not ok then return nil, max, "SetDamage raised: " .. C.Str(err) end
	return d:GetDamage(defense), max, nil
end

CMD.damage = function(me, params)
	local t, tag = Target(me, params, "DMG")
	if t == nil then return end
	local amount = tonumber(params.amount) or 30
	local defense = DefenseTypes.DISTRICT_GARRISON
	local label = "garrison"
	if params.kind == "o" then
		defense = DefenseTypes.DISTRICT_OUTER
		label = "outer wall"
	end
	local got, max, err = SetDamageOn(t, defense, amount)
	local id = "DMG_" .. tag .. "_" .. C.NextSeq()
	if err ~= nil then
		C.Check(id, "FAIL", label .. ": " .. err)
		return
	end
	if max == 0 then
		C.Check(id, "INFO", label .. " damage cannot be set: max is 0 (no walls on " .. tag .. "); use the garrison button")
		return
	end
	local want = math.min(amount, max)
	C.Check(id, got == want and "PASS" or "FAIL", tag .. " " .. label .. " damage " .. C.Str(got) .. "/" .. max .. " (wanted " .. want .. ")")
	if got ~= nil and got > 0 then X.NoteDamage(t, C.Turn()) end
	X.ProbeCity(me, t)
end

CMD.heal = function(me, params)
	local t, tag = Target(me, params, "HEAL")
	if t == nil then return end
	local g1 = SetDamageOn(t, DefenseTypes.DISTRICT_GARRISON, 0)
	local o1 = SetDamageOn(t, DefenseTypes.DISTRICT_OUTER, 0)
	local id = "HEAL_" .. tag .. "_" .. C.NextSeq()
	C.Check(id, ((g1 or 0) == 0 and (o1 or 0) == 0) and "PASS" or "FAIL", tag .. " damage now " .. C.Str(g1) .. "/" .. C.Str(o1))
	X.ProbeCity(me, t)
end

-- ---------------------------------------------------------------------------
-- The last-city case (destroys every other city of the requester!)
-- ---------------------------------------------------------------------------
CMD.last_city = function(me, params)
	local t, tag = Target(me, params, "LASTCITY")
	if t == nil then return end
	local ledger = C.ReadArr(K.LEDGER)
	local killed = 0
	for _, c in ipairs(C.CitiesOf(me)) do
		if c:GetID() ~= t:GetID() then
			local x, y = c:GetX(), c:GetY()
			local ok, err = pcall(function() Players[me]:GetCities():Destroy(c) end)
			if ok then
				killed = killed + 1
				for _, e in ipairs(ledger) do
					if e.owner == me and e.x == x and e.y == y then e.devKilled = 1 end
				end
			else
				C.Info("Destroy failed: " .. C.Str(err))
			end
		end
	end
	C.WriteProp(K.LEDGER, ledger)
	local keep = {}
	for _, r in ipairs(C.Registry()) do
		if r.owner ~= me or C.CityAt(r.x, r.y, r.owner, r.id) ~= nil then keep[#keep + 1] = r end
	end
	C.SaveRegistry(keep)
	local n = C.CityCount(me)
	C.Check("LASTCITY_" .. C.NextSeq(), n == 1 and "PASS" or "FAIL", "destroyed " .. killed .. " cities; P" .. me .. " has " .. n .. " city left (" .. tag .. ")")
	C.SetFocus(C.TagOf(t))
	local c = C.CityAt(t:GetX(), t:GetY(), me)
	if c ~= nil then X.ProbeCity(me, c) end
end

-- ---------------------------------------------------------------------------
-- The original-capital case (razes the capital!). The palace cannot be moved, so the
-- capital is destroyed and a new city is founded on the same plot: it is no capital,
-- it stands on the recorded first-capital plot and its original owner is the player,
-- so the blocker must be ORIGINAL_CAPITAL (spec 1.2 rule 5, DECISIONS #5).
-- Needs one other city (so LAST_CITY does not apply) and a turn start since the game began.
-- ---------------------------------------------------------------------------
CMD.orig_capital = function(me, params)
	local cap = C.Capital(me)
	if cap == nil then
		Fail("ORIGCAP", "no capital to raze")
		return
	end
	if C.CityCount(me) < 2 then
		Fail("ORIGCAP", "make a test city first: the capital would be the last city")
		return
	end
	if X.OrigCapOwner(C.PlotIndexOf(cap)) ~= me then
		Fail("ORIGCAP", "the capital plot is not recorded yet: end a turn first")
		return
	end
	local x, y = cap:GetX(), cap:GetY()
	local ledger = C.ReadArr(K.LEDGER)
	local ok, err = pcall(function() Players[me]:GetCities():Destroy(cap) end)
	for _, e in ipairs(ledger) do
		if e.owner == me and e.x == x and e.y == y then e.devKilled = 1 end
	end
	C.WriteProp(K.LEDGER, ledger)
	if C.CityAt(x, y) ~= nil then
		Fail("ORIGCAP", "could not raze the capital: ok=" .. tostring(ok) .. " err=" .. C.Str(err))
		return
	end
	local plot = Map.GetPlot(x, y)
	local c, msg = C.FoundCity(me, plot)
	if c == nil then
		Fail("ORIGCAP", "could not refound the city on the old capital plot: " .. C.Str(msg))
		return
	end
	local tag = C.AddCity(c, c:GetPopulation())
	C.SetFocus(tag)
	local isCap = C.Capital(me) ~= nil and C.Capital(me):GetID() == c:GetID()
	C.Check("ORIGCAP_" .. C.NextSeq(), "INFO", "capital razed; " .. tag .. " refounded on its plot " .. C.CityLabel(c) ..
		" (" .. (isCap and "the game made it the capital" or "not the capital") .. "); original owner " .. C.Str(c:GetOriginalOwner()))
	X.ProbeCity(me, c)
end

-- ---------------------------------------------------------------------------
-- Plan: the expected timeline for the target city, from the pure math
-- ---------------------------------------------------------------------------
CMD.plan = function(me, params)
	local t, tag = Target(me, params, "PLAN")
	if t == nil then return end
	local turn = C.Turn()
	local pop = t:GetPopulation()
	local sch = ABN_Config.Schedule(pop)
	local D, R = ABN_Config.D(pop), ABN_Config.R(pop)
	local pops = {}
	for i = 1, #sch.targets do
		pops[#pops + 1] = "T" .. (turn + i - 1) .. ":" .. sch.targets[i]
	end
	C.Info("PLAN " .. tag .. " pop=" .. pop .. " if started now: T=" .. sch.T .. " F=" .. sch.F .. " populations " .. table.concat(pops, " ") ..
		" | removed at the start of turn " .. (turn + sch.T))
	C.Info("PLAN debuff D=" .. D .. " R=" .. R .. " on turns " .. turn .. ".." .. ABN_Config.DebuffEndTurn(turn, sch.T) ..
		" | cancel at turn c: debuff to c+(c-" .. turn .. "+1), cooldown until c+" .. ABN_Config.COOLDOWN_TURNS)
	local hit, miss = {}, {}
	for _, c in ipairs(C.CitiesOf(me)) do
		if c:GetID() ~= t:GetID() then
			local d = Distance(t, c)
			local entry = C.TagOf(c) .. "(d=" .. d .. ")"
			if d <= R then hit[#hit + 1] = entry else miss[#miss + 1] = entry end
		end
	end
	C.Info("PLAN affected: " .. (#hit > 0 and table.concat(hit, " ") or "none") .. " | outside: " .. (#miss > 0 and table.concat(miss, " ") or "none"))
end

-- ---------------------------------------------------------------------------
-- Checked start / cancel (the panel sends the real ABN_Start / ABN_Cancel between these)
-- ---------------------------------------------------------------------------
CMD.arm_start = function(me, params)
	local t = Target(me, params, "ARM_START")
	if t == nil then return end
	X.ArmStart(me, t)
end

CMD.arm_cancel = function(me, params)
	local t = Target(me, params, "ARM_CANCEL")
	if t == nil then return end
	X.ArmCancel(me, t)
end

-- ---------------------------------------------------------------------------
-- Checks, dump, probe, switches
-- ---------------------------------------------------------------------------
CMD.check = function(me, params)
	local n, fail = X.Observe("now")
	C.Info("CHECK NOW: " .. n .. " checks, " .. fail .. " failed")
end

CMD.dump = function(me, params)
	X.Dump(me)
end

CMD.probe = function(me, params)
	local t = C.ResolveTarget(me, params)
	X.ProbeAll(me, t)
end

CMD.checker = function(me, params)
	local st = C.State()
	if params.on == 1 then st.checker = 1 elseif params.on == 0 then st.checker = 0 else st.checker = (st.checker == 0) and 1 or 0 end
	C.SaveState(st)
	C.Info("turn checker " .. (st.checker ~= 0 and "ON" or "OFF"))
end

-- Clears the dev bookkeeping (not the mod's state): ledger, arm, damage notes, tally.
CMD.reset = function(me, params)
	C.WriteProp(K.LEDGER, {})
	X.ClearArm()
	C.WriteProp(K.DMG, {})
	C.ResetTally()
	C.Info("dev ledger, arm, damage notes and tally cleared (the mod's own state is untouched)")
end

S.LOADED = 1
