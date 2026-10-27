-- ===========================================================================
-- ABN_Dev_Check.lua  (ABN_Dev 0.1.0.0, WP9)
-- Module:   ABN_Dev_Check (global table), gameplay. TESTING ONLY.
-- Content:  the dev tools' own model of what the mod must do, and the checks
--           that compare it with the mod's state:
--             * ExpectedBlocker / ProbeCity: blocking rules (spec 1.2),
--               re-implemented here and compared with ABN_Rules.FirstBlocker;
--             * ArmStart / ArmCancel: record the click-time facts before the
--               panel sends ABN_Start / ABN_Cancel (the real requests);
--             * Observe: after every turn start (and on demand) it matches the
--               mod's ABN_Active / ABN_Windows / ABN_Cooldowns records and the
--               ABN_DBIT_<n> plot flags with a ledger of the abandonments the
--               dev tools saw begin: schedule population, removal turn,
--               window D/R/end turn, cooldown, auto-cancel, loyalty ladder.
--           Every verdict is one line:
--             [ABN][CHECK] <ID> <PASS|FAIL|INFO> T<turn> <numbers>
--           (tools\summarize_abn_log.py). IDs carry the turn, so a FAIL is
--           never hidden by a later PASS.
--
-- The mod is read only through its Game-property state (PLAN 3), its pure
-- math (ABN_Config) and ABN_Rules.FirstBlocker (PLAN 13). Nothing here changes
-- mod state. The expected values come from ABN_Config's pure math (tested
-- offline) and the spec numbers in ABN_Dev_Core, not from the mod's records.
--
-- Game properties written here (G only): ABN_DevLedger, ABN_DevArm,
-- ABN_DevDamage, ABN_DevOrigCaps, ABN_DevPops, ABN_DevProbe.
-- ===========================================================================

if ABN_Dev_Check ~= nil and ABN_Dev_Check.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Rules")
include("ABN_Dev_Core")

-- ABN:GLOBALS ABN_Config ABN_Rules (modules of the ABN dependency mod, importable through its ImportFiles)
ABN_Dev_Check = {}
local X = ABN_Dev_Check
local C = ABN_Dev_Core
local K = C.KEY

local BIT_PREFIX = "ABN_DBIT_"

-- ---------------------------------------------------------------------------
-- Recorded facts: original capitals (DECISIONS #25) and damage
-- ---------------------------------------------------------------------------

-- Each major's first capital plot, recorded at turn start while missing.
function X.RecordOrigCaps()
	local list = C.ReadArr(K.ORIG)
	local changed = false
	for _, pid in ipairs(C.AliveIDs()) do
		if C.IsMajor(pid) then
			local have = false
			for _, r in ipairs(list) do
				if r.player == pid then have = true end
			end
			if not have then
				local cap = C.Capital(pid)
				if cap ~= nil then
					list[#list + 1] = { player = pid, plot = C.PlotIndexOf(cap) }
					changed = true
				end
			end
		end
	end
	if changed then C.WriteProp(K.ORIG, list) end
end

-- The major whose first capital stood on this plot, or nil.
function X.OrigCapOwner(plotIdx)
	for _, r in ipairs(C.ReadArr(K.ORIG)) do
		if r.plot == plotIdx then return r.player end
	end
	return nil
end

-- Damage the dev tools applied or saw: {plot, turn}, the latest per plot.
function X.NoteDamage(c, turn)
	local idx = C.PlotIndexOf(c)
	local list = C.ReadArr(K.DMG)
	for _, r in ipairs(list) do
		if r.plot == idx then
			r.turn = turn
			C.WriteProp(K.DMG, list)
			return
		end
	end
	list[#list + 1] = { plot = idx, turn = turn }
	C.WriteProp(K.DMG, list)
end

-- True when damage was applied or seen on this city within the last 5 turns. The mod's
-- own memory starts when ITS tracker sees the damage, which can be a turn later, so
-- this is a grey zone: both answers are accepted.
function X.DamageMemory(c, turn)
	local idx = C.PlotIndexOf(c)
	for _, r in ipairs(C.ReadArr(K.DMG)) do
		if r.plot == idx and turn - r.turn < C.DAMAGE_MEMORY_TURNS and turn - r.turn >= 0 then return true end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Blocking rules (spec 1.2), the dev tools' own version
-- ---------------------------------------------------------------------------

-- Returns the first blocking code (or nil) in the mod's precedence order and a grey
-- flag (damage memory could add DAMAGED). SIEGE is UI-only; G has none.
function X.ExpectedBlocker(c, owner, turn)
	local x, y = c:GetX(), c:GetY()
	local idx = C.PlotIndexOf(c)
	for _, r in ipairs(C.ReadArr(ABN_Config.KEY_ACTIVE)) do
		if r.owner == owner and r.x == x and r.y == y then return "ACTIVE", false end
	end
	for _, r in ipairs(C.ReadArr(ABN_Config.KEY_COOLDOWNS)) do
		if r.owner == owner and r.plot == idx and (r.cityID == nil or r.cityID == c:GetID())
				and turn < (r.endTurn or 0) then
			return "COOLDOWN", false
		end
	end
	local cap = C.Capital(owner)
	if cap ~= nil and cap:GetID() == c:GetID() then return "CAPITAL", false end
	if C.CityCount(owner) <= 1 then return "LAST_CITY", false end
	local oc = X.OrigCapOwner(idx)
	if oc ~= nil then
		local ok, orig = pcall(function() return c:GetOriginalOwner() end)
		if ok and orig == oc then return "ORIGINAL_CAPITAL", false end
	end
	local g, o = C.Damage(c)
	if g > 0 or o > 0 then return "DAMAGED", false end
	local gray = X.DamageMemory(c, turn)
	if #C.EnemyScan(owner, x, y, C.ENEMY_RADIUS) > 0 then return "ENEMY_NEAR", gray end
	return nil, gray
end

-- Compares ABN_Rules.FirstBlocker with the expected code. Returns got, expected ("NONE" for nil).
function X.ProbeCity(owner, c)
	local turn = C.Turn()
	local tag = C.TagOf(c)
	local exp, gray = X.ExpectedBlocker(c, owner, turn)
	local expS = exp or "NONE"
	local id = "BLOCK_" .. tag .. "_T" .. turn .. "_" .. C.NextSeq()
	local ok, got = pcall(ABN_Rules.FirstBlocker, c, owner, turn)
	if not ok then
		C.Check(id, "FAIL", "ABN_Rules.FirstBlocker raised: " .. C.Str(got))
		return "ERROR", expS
	end
	local gotS = got or "NONE"
	local g, o = C.Damage(c)
	local detail = "expected=" .. expS .. " got=" .. gotS .. " (pop=" .. c:GetPopulation() .. " damage=" .. g .. "/" .. o .. ")"
	if gotS == expS then
		C.Check(id, "PASS", detail)
	elseif gray and (gotS == "DAMAGED" or gotS == "NONE" or expS == "DAMAGED") then
		C.Check(id, "INFO", detail .. " (damage memory window, either answer accepted)")
	else
		C.Check(id, "FAIL", detail)
	end
	return gotS, expS
end

-- ---------------------------------------------------------------------------
-- Arms: facts recorded just before the real ABN_Start / ABN_Cancel request
-- ---------------------------------------------------------------------------

function X.ClearArm()
	C.WriteProp(K.ARM, { kind = "none" })
end

function X.GetArm()
	local a = C.ReadProp(K.ARM)
	if type(a) == "table" and (a.kind == "start" or a.kind == "cancel") then return a end
	return nil
end

-- Population of every city of every alive player on this turn. Taken at each turn start
-- (after the mod's pipeline) and just before a start request: those are the moments the
-- mod applies the loyalty flags, so a check made later in the turn compares only the
-- cities that existed then.
function X.SnapshotPops(turn)
	local out = {}
	for _, pid in ipairs(C.AliveIDs()) do
		for _, c in ipairs(C.CitiesOf(pid)) do
			out[#out + 1] = { plot = C.PlotIndexOf(c), pop = c:GetPopulation(), owner = pid, turn = turn }
		end
	end
	C.WriteProp(K.POPS, out)
end

-- Start: records the population, the turn and the expected blocker, and probes
-- ABN_Rules.FirstBlocker. Returns the arm table or nil.
function X.ArmStart(me, c)
	if c == nil then
		C.Check("ARM_START", "FAIL", "no city to start (found your capital, make a test city or open a city)")
		return nil
	end
	local turn = C.Turn()
	local exp, gray = X.ExpectedBlocker(c, me, turn)
	X.ProbeCity(me, c)
	X.SnapshotPops(turn)
	local arm = { kind = "start", owner = me, cityID = c:GetID(), x = c:GetX(), y = c:GetY(), plot = C.PlotIndexOf(c),
		pop = c:GetPopulation(), turn = turn, exp = exp or "NONE", gray = gray and 1 or 0 }
	C.WriteProp(K.ARM, arm)
	C.Info("ARMED start " .. C.TagOf(c) .. " pop=" .. arm.pop .. " expected blocker=" .. arm.exp .. "; now send ABN_Start")
	return arm
end

-- Cancel: records whether the mod has an active record for the city.
function X.ArmCancel(me, c)
	if c == nil then
		C.Check("ARM_CANCEL", "FAIL", "no city to cancel")
		return nil
	end
	local had = 0
	for _, r in ipairs(C.ReadArr(ABN_Config.KEY_ACTIVE)) do
		if r.owner == me and r.x == c:GetX() and r.y == c:GetY() then had = 1 end
	end
	local arm = { kind = "cancel", owner = me, cityID = c:GetID(), x = c:GetX(), y = c:GetY(), plot = C.PlotIndexOf(c),
		turn = C.Turn(), hadRecord = had }
	C.WriteProp(K.ARM, arm)
	C.Info("ARMED cancel " .. C.TagOf(c) .. " active record=" .. had .. "; now send ABN_Cancel")
	return arm
end

-- ---------------------------------------------------------------------------
-- Observation context and record finders
-- ---------------------------------------------------------------------------
local function Emit(ctx, id, status, text)
	ctx.n = ctx.n + 1
	if status == "FAIL" then ctx.fail = ctx.fail + 1 end
	C.Check(id, status, text)
end

local function Id(ctx, base, e)
	return base .. "_" .. e.tag .. ctx.sfx
end

local function FindActive(ctx, e)
	for _, r in ipairs(ctx.active) do
		if r.owner == e.owner and r.x == e.x and r.y == e.y and r.start == e.start then return r end
	end
	return nil
end

local function FindWindow(ctx, e)
	for _, w in ipairs(ctx.wins) do
		if w.owner == e.owner and w.x == e.x and w.y == e.y and w.start == e.start then return w end
	end
	return nil
end

-- A cooldown record for the entry's city (owner + plot + city ID), any end turn.
local function FindCooldown(ctx, e)
	for _, r in ipairs(ctx.cds) do
		if r.owner == e.owner and r.plot == e.plot and (r.cityID == nil or r.cityID == e.cityID) then return r end
	end
	return nil
end

local function LedgerEntry(ledger, r)
	for _, e in ipairs(ledger) do
		if e.owner == r.owner and e.x == r.x and e.y == r.y and e.start == r.start then return e end
	end
	return nil
end

local function SnapPop(plotIdx)
	for _, s in ipairs(C.ReadArr(K.POPS)) do
		if s.plot == plotIdx then return s end
	end
	return nil
end

-- What the dev model treats as an auto-cancel cause at this turn start (spec 1.6).
local function BlockedNow(e, city)
	if C.CityCount(e.owner) <= 1 then return "LAST_CITY" end
	local g, o = C.Damage(city)
	if g > 0 or o > 0 then return "DAMAGED" end
	if #C.EnemyScan(e.owner, e.x, e.y, C.ENEMY_RADIUS) > 0 then return "ENEMY_NEAR" end
	return nil
end

local function BitsOf(plot)
	local sum = 0
	for _, n in ipairs(ABN_Config.LOY_BITS) do
		local v = plot:GetProperty(BIT_PREFIX .. n)
		if type(v) == "number" and v >= 1 then sum = sum + n end
	end
	return sum
end

local function LadderSum(D)
	local sum = 0
	for _, n in ipairs(ABN_Config.Bits(D)) do sum = sum + n end
	return sum
end

-- ---------------------------------------------------------------------------
-- A new abandonment appears: validate the mod's record
-- ---------------------------------------------------------------------------
local function AddEntry(ctx, r)
	local city = C.CityAt(r.x, r.y)
	local tag = city ~= nil and C.TagOf(city) or ("X" .. C.Str(r.x) .. "_" .. C.Str(r.y))
	local sid = "START_" .. tag .. ctx.sfx
	if type(r.P0) ~= "number" or type(r.start) ~= "number" or type(r.x) ~= "number" then
		Emit(ctx, sid, "FAIL", "ABN_Active record has no numeric P0/start/x: " .. C.Str(r.P0) .. "/" .. C.Str(r.start))
		return
	end
	local P0 = r.P0
	local sch = ABN_Config.Schedule(P0)
	local D, R = ABN_Config.D(P0), ABN_Config.R(P0)
	local bad = {}
	if city == nil then
		bad[#bad + 1] = "no city at " .. r.x .. "," .. r.y
	else
		if city:GetOwner() ~= r.owner then bad[#bad + 1] = "owner " .. C.Str(r.owner) .. " vs city owner " .. city:GetOwner() end
		if r.cityID ~= city:GetID() then bad[#bad + 1] = "cityID " .. C.Str(r.cityID) .. " vs " .. city:GetID() end
		if r.plot ~= nil and r.plot ~= C.PlotIndexOf(city) then bad[#bad + 1] = "plot " .. C.Str(r.plot) .. " vs " .. C.PlotIndexOf(city) end
	end
	if r.T ~= sch.T then bad[#bad + 1] = "T=" .. C.Str(r.T) .. " expected " .. sch.T end
	if r.F ~= sch.F then bad[#bad + 1] = "F=" .. C.Str(r.F) .. " expected " .. sch.F end
	if r.D ~= D then bad[#bad + 1] = "D=" .. C.Str(r.D) .. " expected " .. D end
	if r.R ~= R then bad[#bad + 1] = "R=" .. C.Str(r.R) .. " expected " .. R end
	if r.status ~= nil and r.status ~= "RUN" then bad[#bad + 1] = "status=" .. C.Str(r.status) end
	if r.start > ctx.turn then bad[#bad + 1] = "start " .. r.start .. " is in the future" end

	local how = "P0=" .. P0
	local arm = ctx.arm
	if arm ~= nil and arm.kind == "start" and arm.owner == r.owner and arm.x == r.x and arm.y == r.y then
		ctx.armUsed = true
		if r.P0 ~= arm.pop then bad[#bad + 1] = "P0=" .. P0 .. " but the population at the click was " .. arm.pop end
		if r.start ~= arm.turn then bad[#bad + 1] = "start=" .. r.start .. " but clicked on turn " .. arm.turn end
		if arm.exp ~= "NONE" and arm.gray == 0 then bad[#bad + 1] = "started although the city is blocked (" .. arm.exp .. ")" end
		how = how .. " (matches the click)"
	elseif city ~= nil then
		local snap = SnapPop(C.PlotIndexOf(city))
		if snap ~= nil and snap.turn == r.start then
			if math.abs(snap.pop - P0) > 1 then
				bad[#bad + 1] = "P0=" .. P0 .. " but the population at the start of turn " .. snap.turn .. " was " .. snap.pop
			end
			how = how .. " (pop " .. snap.pop .. " at the start of the click turn, real button)"
		else
			how = how .. " (no click record, P0 not verified)"
		end
	end
	if ctx.mode == "now" and city ~= nil and r.start == ctx.turn and city:GetPopulation() ~= P0 then
		bad[#bad + 1] = "population " .. city:GetPopulation() .. " changed on the click turn (should stay P0=" .. P0 .. ")"
	end

	local e = { owner = r.owner, cityID = r.cityID or -1, x = r.x, y = r.y, plot = city ~= nil and C.PlotIndexOf(city) or (r.plot or -1),
		tag = tag, P0 = P0, T = sch.T, F = sch.F, D = D, R = R, start = r.start, state = "RUN",
		endTurn = ABN_Config.DebuffEndTurn(r.start, sch.T), cancelTurn = 0, cooldownEnd = 0, windowDone = 0, cooldownDone = 1, done = 0 }
	ctx.ledger[#ctx.ledger + 1] = e
	local plan = {}
	for i = 1, #sch.targets do plan[#plan + 1] = sch.targets[i] end
	local detail = how .. " T=" .. sch.T .. " F=" .. sch.F .. " D=" .. D .. " R=" .. R .. " schedule=" .. table.concat(plan, ",") ..
		" removed at start of turn " .. (r.start + sch.T) .. ", debuff to turn " .. e.endTurn
	if #bad == 0 then
		Emit(ctx, sid, "PASS", detail)
	else
		Emit(ctx, sid, "FAIL", table.concat(bad, "; ") .. " | " .. detail)
	end
end

-- ---------------------------------------------------------------------------
-- Window and population checks
-- ---------------------------------------------------------------------------
local function CheckWindow(ctx, e, expPhase)
	local id = Id(ctx, "WIN", e)
	local w = FindWindow(ctx, e)
	if w == nil then
		Emit(ctx, id, "FAIL", "no ABN_Windows record for " .. e.tag .. " (start " .. e.start .. ", state " .. e.state .. ")")
		return nil
	end
	local bad = {}
	if w.D ~= e.D then bad[#bad + 1] = "D=" .. C.Str(w.D) .. " expected " .. e.D end
	if w.R ~= e.R then bad[#bad + 1] = "R=" .. C.Str(w.R) .. " expected " .. e.R end
	if w.endTurn ~= e.endTurn then bad[#bad + 1] = "endTurn=" .. C.Str(w.endTurn) .. " expected " .. e.endTurn end
	if w.phase ~= expPhase then bad[#bad + 1] = "phase=" .. C.Str(w.phase) .. " expected " .. expPhase end
	if w.srcPlot ~= nil and w.srcPlot ~= e.plot then bad[#bad + 1] = "srcPlot=" .. C.Str(w.srcPlot) .. " expected " .. e.plot end
	local detail = "D=" .. C.Str(w.D) .. " R=" .. C.Str(w.R) .. " turns " .. e.start .. ".." .. C.Str(w.endTurn) .. " phase=" .. C.Str(w.phase)
	if #bad == 0 then
		Emit(ctx, id, "PASS", detail)
	else
		Emit(ctx, id, "FAIL", table.concat(bad, "; ") .. " | " .. detail)
	end
	return w
end

local function PopCheck(ctx, e, rec, city, k)
	if city == nil or k < 1 or k > e.T - 1 then return end
	local target = ABN_Config.TargetK(e.P0, e.T, e.F, k)
	local pop = city:GetPopulation()
	local id = Id(ctx, "POP", e)
	if type(rec.lastStep) == "number" and rec.lastStep ~= k then
		Emit(ctx, id, "FAIL", "pop=" .. pop .. " target=" .. target .. " but lastStep=" .. rec.lastStep ..
			" (expected " .. k .. "): the mod's turn hook had not run yet? check the dev LoadOrder")
		return
	end
	local detail = "step " .. k .. "/" .. (e.T - 1) .. " pop=" .. pop .. " target=" .. target
	if pop > target then
		Emit(ctx, id, "FAIL", detail .. " (population not cut back)")
	elseif pop < 1 then
		Emit(ctx, id, "FAIL", detail .. " (below 1)")
	elseif pop == target then
		Emit(ctx, id, "PASS", detail)
	else
		Emit(ctx, id, "PASS", detail .. " (below target: starvation)")
	end
end

-- ---------------------------------------------------------------------------
-- Entry life cycle
-- ---------------------------------------------------------------------------
-- Last debuff turn after a cancel / auto-cancel / loss on cancelTurn: CancelEndTurn (e more
-- turns, DECISIONS #12), never past the full window DebuffEndTurn (DECISIONS #11).
local function CancelEnd(e, cancelTurn)
	return math.min(ABN_Config.CancelEndTurn(e.start, cancelTurn), ABN_Config.DebuffEndTurn(e.start, e.T))
end

local function Terminal(ctx, e, state, endTurn, cancelTurn)
	e.state = state
	e.endTurn = endTurn
	e.cancelTurn = cancelTurn or 0
	if state == "CANCELLED" then
		e.cooldownEnd = ABN_Config.CooldownEnd(e.cancelTurn)
		e.cooldownDone = 0
	end
end

local function Broken(ctx, e, id, text)
	Emit(ctx, id, "FAIL", text)
	e.state = "BROKEN"
	e.done = 1
end

-- The ABN_Active record is gone: why?
local function Classify(ctx, e, city, k)
	local turn = ctx.turn
	local arm = ctx.arm
	local manual = arm ~= nil and arm.kind == "cancel" and arm.owner == e.owner and arm.x == e.x and arm.y == e.y
		and arm.hadRecord == 1 and arm.turn >= e.start
	if manual then
		ctx.armUsed = true
		Terminal(ctx, e, "CANCELLED", CancelEnd(e, arm.turn), arm.turn)
		local id = Id(ctx, "CANCEL", e)
		if city == nil then
			Broken(ctx, e, id, "record gone after the cancel request but the city is gone too")
			return
		end
		Emit(ctx, id, "PASS", "record removed on turn " .. arm.turn .. " (ran " .. (arm.turn - e.start + 1) .. " turns); debuff to turn " ..
			e.endTurn .. ", cooldown until turn " .. e.cooldownEnd)
		return
	end
	if ctx.mode ~= "turn" then
		Broken(ctx, e, Id(ctx, "CANCEL", e), "the ABN_Active record disappeared and no cancel was armed")
		return
	end
	if city ~= nil then
		local why = BlockedNow(e, city)
		local gray = why == nil and X.DamageMemory(city, turn)
		if why ~= nil or gray then
			Terminal(ctx, e, "AUTOCANCEL", CancelEnd(e, turn), turn)
			local id = Id(ctx, "AUTOCANCEL", e)
			local detail = "auto-cancelled at the start of turn " .. turn .. " (" .. (why or "damage memory") .. "); debuff to turn " .. e.endTurn ..
				", no cooldown"
			Emit(ctx, id, why ~= nil and "PASS" or "INFO", detail)
		elseif k >= e.T then
			Broken(ctx, e, Id(ctx, "REMOVE", e), "the record is gone at turn " .. turn .. " (k=" .. k .. ") but the city still exists: removal failed")
		else
			Broken(ctx, e, Id(ctx, "AUTOCANCEL", e), "the record vanished at k=" .. k .. " with no blocker (no enemy within " ..
				C.ENEMY_RADIUS .. ", no damage) and no cancel")
		end
		return
	end
	-- the city is not ours any more
	local other = C.CityAt(e.x, e.y)
	if other ~= nil then
		Terminal(ctx, e, "LOST", CancelEnd(e, turn), turn)
		Emit(ctx, Id(ctx, "LOST", e), "PASS", "city changed hands (now owner " .. other:GetOwner() .. "); treated as an auto-cancel, debuff to turn " .. e.endTurn)
	elseif e.devKilled == 1 then
		Terminal(ctx, e, "LOST", CancelEnd(e, turn), turn)
		Emit(ctx, Id(ctx, "LOST", e), "INFO", "city destroyed by the dev tools")
	elseif k == e.T then
		Terminal(ctx, e, "REMOVED", ABN_Config.DebuffEndTurn(e.start, e.T), 0)
		Emit(ctx, Id(ctx, "REMOVE", e), "PASS", "city removed at the start of turn " .. turn .. " (start " .. e.start .. " + T " .. e.T ..
			"), record dropped; debuff to turn " .. e.endTurn)
	elseif k < e.T then
		Broken(ctx, e, Id(ctx, "REMOVE", e), "city removed early: turn " .. turn .. " is k=" .. k .. " of T=" .. e.T)
	else
		Terminal(ctx, e, "REMOVED", ABN_Config.DebuffEndTurn(e.start, e.T), 0)
		Emit(ctx, Id(ctx, "REMOVE", e), "INFO", "removal seen late: k=" .. k .. " > T=" .. e.T .. " (checker was off at turn " .. (e.start + e.T) .. "?)")
	end
end

-- After the abandonment ended: window until its end turn, cooldown, expiry.
local function AfterEnd(ctx, e)
	local turn = ctx.turn
	local phase = (e.state == "REMOVED") and "POST" or "CANCEL"
	if turn <= e.endTurn then
		CheckWindow(ctx, e, phase)
	elseif ctx.mode == "turn" and e.windowDone == 0 then
		local id = Id(ctx, "DEBUFFEND", e)
		if FindWindow(ctx, e) == nil then
			Emit(ctx, id, "PASS", "window dropped after its last turn " .. e.endTurn)
			e.windowDone = 1
		else
			Emit(ctx, id, "FAIL", "window still present at turn " .. turn .. " after its last turn " .. e.endTurn)
		end
	end
	-- cooldown
	if e.state == "CANCELLED" then
		if e.cooldownDone == 0 then
			local cd = FindCooldown(ctx, e)
			local id = Id(ctx, "COOLDOWN", e)
			if turn < e.cooldownEnd then
				if cd == nil then
					Emit(ctx, id, "FAIL", "no cooldown record while turn " .. turn .. " < " .. e.cooldownEnd)
				elseif cd.endTurn ~= e.cooldownEnd then
					Emit(ctx, id, "FAIL", "cooldown endTurn=" .. C.Str(cd.endTurn) .. " expected " .. e.cooldownEnd)
				else
					Emit(ctx, id, "PASS", "blocked until turn " .. e.cooldownEnd)
				end
			elseif ctx.mode == "turn" then
				if cd == nil then
					Emit(ctx, id, "PASS", "cooldown dropped at turn " .. turn .. " (end " .. e.cooldownEnd .. ")")
					e.cooldownDone = 1
				else
					Emit(ctx, id, "FAIL", "cooldown still present at turn " .. turn .. " (end " .. e.cooldownEnd .. ")")
				end
			end
		end
	elseif e.cooldownChecked ~= 1 then
		e.cooldownChecked = 1
		local cd = FindCooldown(ctx, e)
		local id = Id(ctx, "NOCOOLDOWN", e)
		if cd ~= nil and cd.endTurn == ABN_Config.CooldownEnd(e.state == "REMOVED" and e.start + e.T or e.cancelTurn) then
			Emit(ctx, id, "FAIL", "state " .. e.state .. " must not start a cooldown, found endTurn=" .. C.Str(cd.endTurn))
		else
			Emit(ctx, id, "PASS", "state " .. e.state .. ": no cooldown started")
		end
	end
	if e.windowDone == 1 and e.cooldownDone == 1 then e.done = 1 end
end

local function StepEntry(ctx, e)
	local turn = ctx.turn
	local rec = FindActive(ctx, e)
	local city = C.CityAt(e.x, e.y, e.owner, e.cityID)
	local k = turn - e.start
	if e.state == "RUN" then
		if rec ~= nil then
			if ctx.mode == "turn" then
				local why = city ~= nil and BlockedNow(e, city) or nil
				local gray = city ~= nil and why == nil and X.DamageMemory(city, turn)
				if city == nil then
					Emit(ctx, Id(ctx, "LOST", e), "FAIL", "the record is still active but the city is gone or changed hands (a lost city must end the abandonment)")
				elseif k >= e.T then
					Emit(ctx, Id(ctx, "REMOVE", e), "FAIL", "city must be removed at the start of turn " .. (e.start + e.T) ..
						" but the record is still active (k=" .. k .. ")")
				elseif why ~= nil then
					Emit(ctx, Id(ctx, "AUTOCANCEL", e), "FAIL", "should have auto-cancelled (" .. why .. ") but the record is still active")
				else
					PopCheck(ctx, e, rec, city, k)
					if gray then
						Emit(ctx, Id(ctx, "AUTOCANCEL", e), "INFO", "damage memory window: auto-cancel optional, the mod kept the abandonment")
					end
				end
			end
			if rec.status ~= nil and rec.status ~= "RUN" then
				Emit(ctx, Id(ctx, "STATUS", e), "FAIL", "active record status=" .. C.Str(rec.status))
			end
			CheckWindow(ctx, e, "RUN")
		else
			Classify(ctx, e, city, k)
		end
	end
	if e.state ~= "RUN" and e.state ~= "BROKEN" then
		AfterEnd(ctx, e)
	end
end

-- ---------------------------------------------------------------------------
-- Loyalty ladder: the ABN_DBIT_<n> flags of every city against the live windows
-- ---------------------------------------------------------------------------
local function CheckLoyalty(ctx)
	local live = {}
	for _, e in ipairs(ctx.ledger) do
		if e.done ~= 1 and e.state ~= "BROKEN" and e.start <= ctx.turn and ctx.turn <= e.endTurn then
			live[#live + 1] = e
		end
	end
	local cities, covered, skipped = 0, 0, 0
	local cover, bad = {}, {}
	local flagged = 0
	-- On demand (mode "now") the flags only reflect the cities that existed when the mod
	-- last applied them (turn start or a start request): the snapshot lists them.
	local inSnap = nil
	if ctx.mode == "now" then
		inSnap = {}
		for _, s in ipairs(C.ReadArr(K.POPS)) do inSnap[s.plot] = true end
	end
	for _, pid in ipairs(C.AliveIDs()) do
		for _, city in ipairs(C.CitiesOf(pid)) do
			local idx = C.PlotIndexOf(city)
			if inSnap ~= nil and not inSnap[idx] then
				skipped = skipped + 1
			else
			cities = cities + 1
			local list = {}
			for _, e in ipairs(live) do
				if e.owner == pid and idx ~= e.plot and C.Dist(city:GetX(), city:GetY(), e.x, e.y) <= e.R then
					list[#list + 1] = e.D
				end
			end
			local expBits = LadderSum(ABN_Config.SumD(list))
			local got = BitsOf(city:GetPlot())
			local tag = C.TagOf(city)
			if got > 0 then flagged = flagged + 1 end
			if #list > 0 then
				covered = covered + 1
				cover[#cover + 1] = tag .. "(-" .. expBits .. ")"
			end
			if got ~= expBits then
				bad[#bad + 1] = tag .. "@" .. city:GetX() .. "," .. city:GetY() .. " P" .. pid .. " flags=" .. got .. " expected " .. expBits
			end
			end
		end
	end
	if ctx.mode == "turn" then
		for _, e in ipairs(ctx.ledger) do
			if e.state ~= "RUN" and e.state ~= "BROKEN" and e.plot >= 0 and C.CityAt(e.x, e.y) == nil then
				local plot = Map.GetPlotByIndex(e.plot)
				if plot ~= nil and BitsOf(plot) ~= 0 then
					bad[#bad + 1] = "stale flags " .. BitsOf(plot) .. " on the plot of removed " .. e.tag
				end
			end
		end
	end
	if #live == 0 and #bad == 0 and ctx.idle then return end
	local detail = "cities=" .. cities .. " windows=" .. #live .. " covered=" .. covered .. " flagged=" .. flagged ..
		(#cover > 0 and (" [" .. table.concat(cover, " ") .. "]") or "") ..
		(skipped > 0 and (" (" .. skipped .. " newer city(ies) not checked until the next turn start)") or "")
	local id = "LOY" .. ctx.sfx
	if #bad == 0 then
		Emit(ctx, id, "PASS", detail)
	elseif ctx.orphans > 0 then
		Emit(ctx, id, "INFO", table.concat(bad, "; ") .. " | " .. ctx.orphans .. " window(s) are not in the dev ledger | " .. detail)
	else
		local shown = {}
		for i = 1, math.min(#bad, 4) do shown[#shown + 1] = bad[i] end
		Emit(ctx, id, "FAIL", table.concat(shown, "; ") .. (#bad > 4 and (" ... +" .. (#bad - 4) .. " more") or "") .. " | " .. detail)
	end
end

-- ---------------------------------------------------------------------------
-- Arm resolution
-- ---------------------------------------------------------------------------
local function ResolveArm(ctx)
	local arm = ctx.arm
	if arm == nil then return end
	local stale = ctx.mode == "now" or arm.turn < ctx.turn
	if arm.kind == "start" then
		if ctx.armUsed then
			X.ClearArm()
		elseif stale then
			local id = "STARTREQ_T" .. arm.turn .. "_" .. C.NextSeq()
			if arm.exp ~= "NONE" then
				Emit(ctx, id, "PASS", "start refused as expected (" .. arm.exp .. "): no ABN_Active record was created")
			elseif arm.gray == 1 then
				Emit(ctx, id, "INFO", "start produced no record (damage memory window)")
			else
				Emit(ctx, id, "FAIL", "ABN_Start produced no ABN_Active record although nothing blocks the city (expected blocker NONE, pop " ..
					arm.pop .. ")")
			end
			X.ClearArm()
		end
	elseif arm.kind == "cancel" then
		if ctx.armUsed then
			X.ClearArm()
		elseif stale then
			local id = "CANCELREQ_T" .. arm.turn .. "_" .. C.NextSeq()
			if arm.hadRecord == 0 then
				local made = false
				for _, r in ipairs(ctx.cds) do
					if r.owner == arm.owner and r.plot == arm.plot and r.endTurn == ABN_Config.CooldownEnd(arm.turn) then made = true end
				end
				if made then
					Emit(ctx, id, "FAIL", "cancel without an active abandonment created a cooldown")
				else
					Emit(ctx, id, "PASS", "cancel without an active abandonment was a no-op")
				end
			else
				Emit(ctx, id, "FAIL", "ABN_Cancel left the ABN_Active record in place")
			end
			X.ClearArm()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Observe: one full comparison of the mod's state with the dev ledger
-- ---------------------------------------------------------------------------

-- Marks the damage the dev tools can see on registered cities and the capital.
local function StampDamage(turn)
	for _, r in ipairs(C.Registry()) do
		local c = C.CityAt(r.x, r.y, r.owner, r.id)
		if c ~= nil then
			local g, o = C.Damage(c)
			if g > 0 or o > 0 then X.NoteDamage(c, turn) end
		end
	end
end

-- mode "turn": at a turn start, after the mod's pipeline. mode "now": on demand
-- (after a start or cancel request). Returns the number of checks and failures.
function X.Observe(mode)
	local turn = C.Turn()
	local arm = X.GetArm()
	local ctx = {
		mode = mode, turn = turn, n = 0, fail = 0, orphans = 0, idle = false, armUsed = false, arm = arm,
		active = C.ReadArr(ABN_Config.KEY_ACTIVE),
		wins = C.ReadArr(ABN_Config.KEY_WINDOWS),
		cds = C.ReadArr(ABN_Config.KEY_COOLDOWNS),
		ledger = C.ReadArr(K.LEDGER),
	}
	if mode == "turn" then
		ctx.sfx = "_T" .. turn
		StampDamage(turn)
	else
		ctx.sfx = "_T" .. turn .. "n" .. C.NextSeq()
	end

	for _, r in ipairs(ctx.active) do
		if LedgerEntry(ctx.ledger, r) == nil then AddEntry(ctx, r) end
	end
	local count = #ctx.ledger
	for i = 1, count do
		local e = ctx.ledger[i]
		if e.done ~= 1 then StepEntry(ctx, e) end
	end
	ResolveArm(ctx)

	for _, w in ipairs(ctx.wins) do
		if LedgerEntry(ctx.ledger, w) == nil then
			ctx.orphans = ctx.orphans + 1
			C.Check("WINORPHAN_" .. C.Str(w.owner) .. "_" .. C.Str(w.x) .. "_" .. C.Str(w.y) .. "_s" .. C.Str(w.start) .. ctx.sfx, "INFO",
				"window without a dev ledger entry (started before the dev tools saw it)")
		end
	end
	ctx.idle = (#ctx.active == 0 and #ctx.wins == 0 and #ctx.cds == 0 and #ctx.ledger == 0)
	CheckLoyalty(ctx)

	local kept = {}
	for _, e in ipairs(ctx.ledger) do
		if e.done ~= 1 then kept[#kept + 1] = e end
	end
	C.WriteProp(K.LEDGER, kept)
	if mode == "turn" then
		X.SnapshotPops(turn)
		if ctx.n > 0 then
			Emit(ctx, "SUM_T" .. turn, ctx.fail == 0 and "PASS" or "FAIL",
				"checks=" .. ctx.n .. " fail=" .. ctx.fail .. " ledger=" .. #kept .. " active=" .. #ctx.active .. " windows=" .. #ctx.wins ..
				" cooldowns=" .. #ctx.cds)
		end
	end
	return ctx.n, ctx.fail
end

-- ---------------------------------------------------------------------------
-- Probe: every blocker code against the mod, for the capital and the test cities
-- ---------------------------------------------------------------------------
function X.ProbeAll(me, focusCity)
	local seen = {}
	local list = {}
	local function Add(c)
		if c ~= nil then
			local key = c:GetX() .. "," .. c:GetY()
			if not seen[key] then
				seen[key] = true
				list[#list + 1] = c
			end
		end
	end
	Add(focusCity)
	Add(C.Capital(me))
	for _, r in ipairs(C.Registry()) do
		Add(C.CityAt(r.x, r.y, me, r.id))
	end
	local out = {}
	for _, c in ipairs(list) do
		local got, exp = X.ProbeCity(me, c)
		out[#out + 1] = C.TagOf(c) .. "=" .. got
		if focusCity ~= nil and c:GetX() == focusCity:GetX() and c:GetY() == focusCity:GetY() then
			C.WriteProp(K.PROBE, { plot = C.PlotIndexOf(c), x = c:GetX(), y = c:GetY(), cityID = c:GetID(), turn = C.Turn(), got = got, exp = exp })
		end
	end
	C.Info("PROBE " .. table.concat(out, " "))
	return #list
end

-- ---------------------------------------------------------------------------
-- Dump: the mod's records and the dev ledger, one line each
-- ---------------------------------------------------------------------------
function X.Dump(me)
	local st = C.State()
	local pass, fail = C.Tally()
	C.Info("DUMP focus=" .. C.Str(st.focus) .. " checker=" .. (st.checker ~= 0 and "on" or "off") .. " pass=" .. pass .. " fail=" .. fail)
	for _, r in ipairs(C.ReadArr(ABN_Config.KEY_ACTIVE)) do
		C.Info("DUMP active owner=" .. C.Str(r.owner) .. " city=" .. C.Str(r.cityID) .. "@" .. C.Str(r.x) .. "," .. C.Str(r.y) ..
			" P0=" .. C.Str(r.P0) .. " T=" .. C.Str(r.T) .. " F=" .. C.Str(r.F) .. " D=" .. C.Str(r.D) .. " R=" .. C.Str(r.R) ..
			" start=" .. C.Str(r.start) .. " lastStep=" .. C.Str(r.lastStep) .. " status=" .. C.Str(r.status))
	end
	for _, w in ipairs(C.ReadArr(ABN_Config.KEY_WINDOWS)) do
		C.Info("DUMP window owner=" .. C.Str(w.owner) .. " @" .. C.Str(w.x) .. "," .. C.Str(w.y) .. " D=" .. C.Str(w.D) .. " R=" .. C.Str(w.R) ..
			" start=" .. C.Str(w.start) .. " endTurn=" .. C.Str(w.endTurn) .. " phase=" .. C.Str(w.phase))
	end
	for _, r in ipairs(C.ReadArr(ABN_Config.KEY_COOLDOWNS)) do
		C.Info("DUMP cooldown owner=" .. C.Str(r.owner) .. " city=" .. C.Str(r.cityID) .. " plot=" .. C.Str(r.plot) .. " endTurn=" .. C.Str(r.endTurn))
	end
	for _, e in ipairs(C.ReadArr(K.LEDGER)) do
		C.Info("DUMP ledger " .. e.tag .. " state=" .. e.state .. " P0=" .. e.P0 .. " T=" .. e.T .. " D=" .. e.D .. " R=" .. e.R ..
			" start=" .. e.start .. " endTurn=" .. e.endTurn .. " cancelTurn=" .. e.cancelTurn .. " cooldownEnd=" .. e.cooldownEnd)
	end
	local lines = 0
	for _, pid in ipairs(C.AliveIDs()) do
		if C.IsMajor(pid) then
			for _, c in ipairs(C.CitiesOf(pid)) do
				if lines < 30 then
					lines = lines + 1
					local g, o = C.Damage(c)
					C.Note("DUMP city " .. C.TagOf(c) .. " " .. C.CityLabel(c) .. " pop=" .. c:GetPopulation() .. " flags=" .. BitsOf(c:GetPlot()) ..
						" damage=" .. g .. "/" .. o)
				end
			end
		end
	end
end

X.LOADED = 1
