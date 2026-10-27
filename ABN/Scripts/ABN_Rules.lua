-- ===========================================================================
-- ABN_Rules.lua
-- Module:   ABN_Rules (global table), shared (gameplay + UI), include("ABN_Rules")
-- Owner:    WP3 (PLAN 4 blocker order; DECISIONS #4, #5, #13, #24, #25).
--
-- Context-adaptive reads (SPIKES section 4, P probes and S4):
--   CAPITAL           both: Players[owner]:GetCities():GetCapitalCity() ID match
--                     (IsCapital is MISSING in G, so it is not used anywhere).
--   ORIGINAL_CAPITAL  both: the ABN_OrigCaps record of pCity:GetOriginalOwner()
--                     names this plot (DECISIONS #25). UI also: IsOriginalCapital().
--   SIEGE             UI only: centre district IsUnderSiege(). In G it is skipped;
--                     ENEMY_NEAR covers it (DECISIONS #24).
--   DAMAGED           both: current garrison/outer damage > 0, or the last
--                     damaged turn is less than DAMAGE_MEMORY_TURNS ago. The last
--                     turn comes from ABN_Damage.LastTurn (G, WP7) when it gives a
--                     number, else from the ABN_Damage property record.
--   ENEMY_NEAR        both: the S4 scan (ABN_Dev_Gameplay.lua EnemyScan, in game):
--                     alive players at war with owner, plus 62 and 63 always
--                     (DECISIONS #4); units with FormationClass not CIVILIAN
--                     within radius tiles (Map.GetPlotDistance <= radius).
--
-- A check whose engine read fails counts as blocking (logged), so a broken read
-- never lets an abandonment through.
-- MP (PLAN 10): read-only except RecordOrigCaps (G only); ipairs only; players
-- in ascending ID order; no Game.GetLocalPlayer, no math.random.
-- ===========================================================================

if ABN_Rules ~= nil and ABN_Rules.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")
include("ABN_State")

ABN_Rules = {}

-- Blocker codes in precedence order (PLAN 4).
ABN_Rules.CODES = {
	"ACTIVE", "COOLDOWN", "CAPITAL", "LAST_CITY", "ORIGINAL_CAPITAL",
	"SIEGE", "DAMAGED", "ENEMY_NEAR",
}

-- Returned by FirstBlocker when pCity is nil (callers validate the city first).
ABN_Rules.NO_CITY = "NO_CITY"

-- Runs fn in pcall; on error logs and returns failValue.
local function Safe(name, failValue, fn, ...)
	local ok, v = pcall(fn, ...)
	if not ok then
		ABN_Util.Error("Rules", "%s read failed (%s): %s", name, ABN_Util.IsGameplay() and "G" or "UI", tostring(v))
		return failValue
	end
	return v
end

-- ---------------------------------------------------------------------------
-- Single checks (each true = blocked by that rule)
-- ---------------------------------------------------------------------------

-- IsActive(pCity, owner) -> bool, record: an ABN_Active record for owner +
-- plot with this city's ID (rule 6).
function ABN_Rules.IsActive(pCity, owner)
	local plot = ABN_Util.CityPlot(pCity)
	local rec = ABN_State.FindActive(owner, plot)
	if rec ~= nil and (rec.cityID == nil or rec.cityID == pCity:GetID()) then
		return true, rec
	end
	return false, nil
end

-- CooldownEnd(pCity, owner, turn) -> endTurn while a cooldown for this city
-- (owner + plot + cityID) is running (turn < endTurn), else nil (rule 7).
function ABN_Rules.CooldownEnd(pCity, owner, turn)
	local plot = ABN_Util.CityPlot(pCity)
	local rec = ABN_State.FindCooldown(owner, plot)
	if rec == nil or type(rec.endTurn) ~= "number" then
		return nil
	end
	if rec.cityID ~= nil and rec.cityID ~= pCity:GetID() then
		return nil
	end
	if turn < rec.endTurn then
		return rec.endTurn
	end
	return nil
end

-- IsCapital(pCity, owner) -> bool: owner's capital by ID (rule 3; DECISIONS #25).
function ABN_Rules.IsCapital(pCity, owner)
	return Safe("capital", true, function()
		local cap = Players[owner]:GetCities():GetCapitalCity()
		return cap ~= nil and cap:GetID() == pCity:GetID()
	end)
end

-- IsLastCity(owner) -> bool: owner has at most one city (rule 4).
function ABN_Rules.IsLastCity(owner)
	return Safe("city count", true, function()
		return Players[owner]:GetCities():GetCount() <= 1
	end)
end

-- IsOriginalCapital(pCity) -> bool: any original capital, own or captured
-- (rule 5; DECISIONS #5, #25). Recorded first-capital plot of the city's
-- original owner == this plot; in UI also the engine's IsOriginalCapital().
function ABN_Rules.IsOriginalCapital(pCity)
	local plot = ABN_Util.CityPlot(pCity)
	local origOwner = Safe("original owner", nil, function() return pCity:GetOriginalOwner() end)
	if type(origOwner) == "number" then
		local rec = ABN_State.FindOrigCap(origOwner)
		if rec ~= nil and rec.plot == plot then
			return true
		end
	end
	if not ABN_Util.IsGameplay() then
		-- ABN:UI-ONLY begin
		local v = Safe("IsOriginalCapital", false, function() return pCity:IsOriginalCapital() end)
		if v == true then
			return true
		end
		-- ABN:UI-ONLY end
	end
	return false
end

-- IsUnderSiege(pCity) -> bool. UI: centre district IsUnderSiege() (CitySupport.lua:620).
-- G: always false (MISSING in G; DECISIONS #24, ENEMY_NEAR covers it).
function ABN_Rules.IsUnderSiege(pCity)
	if ABN_Util.IsGameplay() then
		return false
	end
	local d = ABN_Util.CentreDistrict(pCity)
	if d == nil then
		return false
	end
	local v = false
	-- ABN:UI-ONLY begin
	v = Safe("IsUnderSiege", false, function() return d:IsUnderSiege() end)
	-- ABN:UI-ONLY end
	return v == true
end

-- LastDamagedTurn(pCity, owner) -> turn of the last recorded damage, or nil.
-- G: ABN_Damage.LastTurn(owner, plot) (WP7) when it returns a number; else
-- (and always in UI) the ABN_Damage record for owner + plot with this cityID.
function ABN_Rules.LastDamagedTurn(pCity, owner)
	local plot = ABN_Util.CityPlot(pCity)
	if ABN_Util.IsGameplay() then
		-- ABN:G-ONLY begin
		if ABN_Damage ~= nil and type(ABN_Damage.LastTurn) == "function" then
			local t = Safe("ABN_Damage.LastTurn", nil, ABN_Damage.LastTurn, owner, plot)
			if type(t) == "number" then
				return t
			end
		end
		-- ABN:G-ONLY end
	end
	local rec = ABN_State.FindDamage(owner, plot)
	if rec ~= nil and type(rec.lastTurn) == "number"
			and (rec.cityID == nil or rec.cityID == pCity:GetID()) then
		return rec.lastTurn
	end
	return nil
end

-- IsDamaged(pCity, owner, turn) -> bool (rule 1, damage part): current
-- garrison or outer damage > 0, or turn - lastTurn < DAMAGE_MEMORY_TURNS.
-- An unreadable centre district counts as damaged.
function ABN_Rules.IsDamaged(pCity, owner, turn)
	local g, o = ABN_Util.CentreDamage(pCity)
	if g == nil and o == nil then
		ABN_Util.Error("Rules", "city %s: centre district damage unreadable", tostring(pCity:GetID()))
		return true
	end
	if (g or 0) > 0 or (o or 0) > 0 then
		return true
	end
	local last = ABN_Rules.LastDamagedTurn(pCity, owner)
	if last ~= nil and turn - last < ABN_Config.DAMAGE_MEMORY_TURNS then
		return true
	end
	return false
end

-- IsMilitary(pUnit) -> bool: FormationClass is not FORMATION_CLASS_CIVILIAN
-- (S4 scan). A unit whose type row cannot be read counts as military.
function ABN_Rules.IsMilitary(pUnit)
	local ok, fc = pcall(function() return GameInfo.Units[pUnit:GetType()].FormationClass end)
	if ok and fc == "FORMATION_CLASS_CIVILIAN" then
		return false
	end
	return true
end

-- IsEnemyOf(owner, pid) -> bool: 62/63 always (DECISIONS #4); otherwise
-- Players[owner]:GetDiplomacy():IsAtWarWith(pid).
function ABN_Rules.IsEnemyOf(owner, pid)
	if pid == owner then
		return false
	end
	if ABN_Util.Contains(ABN_Config.ALWAYS_ENEMY_IDS, pid) then
		return true
	end
	return Safe("IsAtWarWith", false, function()
		return Players[owner]:GetDiplomacy():IsAtWarWith(pid) == true
	end)
end

-- EnemyNear(x, y, owner, radius) -> bool: a military unit of an enemy of
-- owner (IsEnemyOf) is within radius tiles of (x, y) (rule 2). radius
-- defaults to ABN_Config.ENEMY_RADIUS. Players are scanned in ascending ID
-- order; a failed unit list read counts as an enemy near.
function ABN_Rules.EnemyNear(x, y, owner, radius)
	radius = radius or ABN_Config.ENEMY_RADIUS
	for _, pid in ipairs(ABN_Util.AliveIDs()) do
		if ABN_Rules.IsEnemyOf(owner, pid) then
			local found = Safe("units of " .. tostring(pid), true, function()
				for _, u in Players[pid]:GetUnits():Members() do
					if ABN_Util.Dist(x, y, u:GetX(), u:GetY()) <= radius and ABN_Rules.IsMilitary(u) then
						return true
					end
				end
				return false
			end)
			if found then
				return true
			end
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Combined checks
-- ---------------------------------------------------------------------------

-- ThreatBlocker(pCity, owner, turn) -> "SIEGE" | "DAMAGED" | "ENEMY_NEAR" | nil:
-- blocking conditions 1 and 2 only, in PLAN 4 order. The turn pipeline uses
-- this for auto-cancel (DECISIONS #2); FirstBlocker ends with it.
function ABN_Rules.ThreatBlocker(pCity, owner, turn)
	turn = turn or ABN_Util.Turn()
	if ABN_Rules.IsUnderSiege(pCity) then
		return "SIEGE"
	end
	if ABN_Rules.IsDamaged(pCity, owner, turn) then
		return "DAMAGED"
	end
	if ABN_Rules.EnemyNear(pCity:GetX(), pCity:GetY(), owner, ABN_Config.ENEMY_RADIUS) then
		return "ENEMY_NEAR"
	end
	return nil
end

-- FirstBlocker(pCity, owner, turn) -> code, info | nil
-- The first blocking reason in PLAN 4 order, or nil when owner may abandon
-- pCity now. info: the cooldown endTurn for "COOLDOWN" (restart allowed on
-- that turn), the Active record for "ACTIVE", else nil. turn defaults to the
-- current turn. pCity nil gives ABN_Rules.NO_CITY. Ownership, IsHuman and
-- IsMajor are the caller's checks (PLAN 4 steps 1-2).
function ABN_Rules.FirstBlocker(pCity, owner, turn)
	if pCity == nil then
		return ABN_Rules.NO_CITY, nil
	end
	turn = turn or ABN_Util.Turn()
	local active, rec = ABN_Rules.IsActive(pCity, owner)
	if active then
		return "ACTIVE", rec
	end
	local cdEnd = ABN_Rules.CooldownEnd(pCity, owner, turn)
	if cdEnd ~= nil then
		return "COOLDOWN", cdEnd
	end
	if ABN_Rules.IsCapital(pCity, owner) then
		return "CAPITAL", nil
	end
	if ABN_Rules.IsLastCity(owner) then
		return "LAST_CITY", nil
	end
	if ABN_Rules.IsOriginalCapital(pCity) then
		return "ORIGINAL_CAPITAL", nil
	end
	local threat = ABN_Rules.ThreatBlocker(pCity, owner, turn)
	if threat ~= nil then
		return threat, nil
	end
	return nil, nil
end

-- ---------------------------------------------------------------------------
-- Original capital recorder (gameplay only; DECISIONS #25)
-- ---------------------------------------------------------------------------

-- RecordOrigCaps() -> number of new records. For each alive major (ascending
-- ID) without an ABN_OrigCaps record whose current capital it founded itself
-- (GetOriginalOwner() == player), records {player, plot of that capital}.
-- WP7: call at the top of every OnGameTurnStarted (before any rule check) and
-- once at load. A capital founded during turn 1 is recorded at turn 2's start;
-- until then it is blocked as CAPITAL anyway. Does nothing in a UI context.
function ABN_Rules.RecordOrigCaps()
	if not ABN_Util.IsGameplay() then
		return 0
	end
	local added = 0
	-- ABN:G-ONLY begin
	local ids = Safe("GetAliveMajorIDs", {}, function()
		local out = {}
		for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do
			out[#out + 1] = id
		end
		return out
	end)
	table.sort(ids)
	for _, pid in ipairs(ids) do
		if ABN_State.FindOrigCap(pid) == nil then
			local cap = Safe("capital of " .. tostring(pid), nil, function()
				return Players[pid]:GetCities():GetCapitalCity()
			end)
			if cap ~= nil then
				local orig = Safe("original owner", nil, function() return cap:GetOriginalOwner() end)
				local plot = ABN_Util.CityPlot(cap)
				if orig == pid and plot ~= nil and ABN_State.AddOrigCap(pid, plot) then
					added = added + 1
					ABN_Util.Log("Rules", "original capital of player %d recorded at plot %d (%d,%d)",
						pid, plot, cap:GetX(), cap:GetY())
				end
			end
		end
	end
	-- ABN:G-ONLY end
	return added
end

ABN_Rules.LOADED = 1
