-- ===========================================================================
-- ABN_Config.lua
-- Module:   ABN_Config (global table), shared (gameplay + UI), include("ABN_Config")
-- Owner:    WP1 wrote this stub (tunables final); WP2 fills in the pure math.
-- PLAN 2. Pure functions: no engine calls. Lua 5.1 only.
-- ===========================================================================

-- Load-once guard: include() re-runs a file each time it is called.
if ABN_Config ~= nil and ABN_Config.LOADED == 1 then
	return
end

ABN_Config = {}

ABN_Config.VERSION = "1.0.0"   -- keep equal to ABN.modinfo title / description
ABN_Config.T_BANDS = { {maxPop = 4, T = 3}, {maxPop = 9, T = 4}, {maxPop = math.huge, T = 5} }
ABN_Config.F_SMALL_MAX_POP = 4
ABN_Config.F_SMALL = 1
ABN_Config.F_LARGE = 2
ABN_Config.S_POP_LO = 1
ABN_Config.S_POP_HI = 20
ABN_Config.D_BASE = 4
ABN_Config.D_SPAN = 6
ABN_Config.R_BASE = 6
ABN_Config.R_SPAN = 6
ABN_Config.POST_TURNS_PER_T = 1        -- debuff runs T more turns after removal
ABN_Config.D_SUM_CAP = nil             -- Q6 / DECISIONS #15: nil = no cap
ABN_Config.COOLDOWN_TURNS = 5
ABN_Config.DAMAGE_MEMORY_TURNS = 5
ABN_Config.ENEMY_RADIUS = 6
ABN_Config.ALWAYS_ENEMY_IDS = {62, 63} -- Free Cities, Barbarians (DECISIONS #4)
ABN_Config.REMOVAL_MECH = "G1"         -- DECISIONS #22
ABN_Config.LOYALTY_MECH = "B2"         -- DECISIONS #26
ABN_Config.SIEGE_MECH   = "COMPUTED"   -- G has no IsUnderSiege (DECISIONS #24)
ABN_Config.LOY_BITS = {1, 2, 4, 8, 16}

-- Game property keys (PLAN 3)
ABN_Config.KEY_SCHEMA    = "ABN_SchemaV"
ABN_Config.KEY_ACTIVE    = "ABN_Active"
ABN_Config.KEY_WINDOWS   = "ABN_Windows"
ABN_Config.KEY_COOLDOWNS = "ABN_Cooldowns"
ABN_Config.KEY_DAMAGE    = "ABN_Damage"
ABN_Config.KEY_FLAGGED   = "ABN_Flagged"
ABN_Config.KEY_ORIGCAPS  = "ABN_OrigCaps"

-- Request names (PLAN 4)
ABN_Config.REQ_START  = "ABN_Start"
ABN_Config.REQ_CANCEL = "ABN_Cancel"

-- Pure math (PLAN 2). No engine calls, no globals beyond math.

-- Round half up.
function ABN_Config.Round(x)
	return math.floor(x + 0.5)
end

-- Abandonment length in turns: first T_BANDS entry with P0 <= maxPop.
function ABN_Config.T(P0)
	local bands = ABN_Config.T_BANDS
	for i = 1, #bands do
		if P0 <= bands[i].maxPop then
			return bands[i].T
		end
	end
	return bands[#bands].T
end

-- Final-turn population.
function ABN_Config.F(P0)
	if P0 <= ABN_Config.F_SMALL_MAX_POP then
		return ABN_Config.F_SMALL
	end
	return ABN_Config.F_LARGE
end

-- Target population after k removals, 1 <= k <= T-1. Never below 1.
function ABN_Config.TargetK(P0, T, F, k)
	return math.max(1, ABN_Config.Round(P0 + (F - P0) * k / (T - 1)))
end

-- targets[1] = P0 (during turn 1), targets[k+1] = TargetK(k); targets[T] == F.
function ABN_Config.Schedule(P0)
	local T = ABN_Config.T(P0)
	local F = ABN_Config.F(P0)
	local targets = { [1] = P0 }
	for k = 1, T - 1 do
		targets[k + 1] = ABN_Config.TargetK(P0, T, F, k)
	end
	return { T = T, F = F, targets = targets }
end

-- Size factor: clamp((P0 - S_POP_LO) / (S_POP_HI - S_POP_LO), 0, 1).
function ABN_Config.S(P0)
	local s = (P0 - ABN_Config.S_POP_LO) / (ABN_Config.S_POP_HI - ABN_Config.S_POP_LO)
	if s < 0 then s = 0 end
	if s > 1 then s = 1 end
	return s
end

-- Loyalty debuff strength per turn.
function ABN_Config.D(P0)
	return ABN_Config.Round(ABN_Config.D_BASE + ABN_Config.D_SPAN * ABN_Config.S(P0))
end

-- Reward / radius-related size value (PLAN 2: R_BASE + R_SPAN * S).
function ABN_Config.R(P0)
	return ABN_Config.Round(ABN_Config.R_BASE + ABN_Config.R_SPAN * ABN_Config.S(P0))
end

-- Last turn whose end-of-turn loyalty counts (DECISIONS #11).
function ABN_Config.DebuffEndTurn(start, T)
	return start + 2 * T - 1
end

-- DECISIONS #12: ran e turns (click and cancel turns included) => debuff for e more turns.
function ABN_Config.CancelEndTurn(start, cancelTurn)
	local e = cancelTurn - start + 1
	return cancelTurn + e
end

-- Sum of D values (DECISIONS #8). cap (or D_SUM_CAP when cap is nil) limits the sum;
-- both nil = no cap (DECISIONS #15). Non-number entries are ignored.
function ABN_Config.SumD(list, cap)
	local sum = 0
	for i = 1, #(list or {}) do
		local v = list[i]
		if type(v) == "number" then
			sum = sum + v
		end
	end
	if cap == nil then cap = ABN_Config.D_SUM_CAP end
	if cap ~= nil and sum > cap then
		sum = cap
	end
	return sum
end

-- Ladder flags for D, ascending (9 -> {1, 8}). The ladder 1,2,4,8,16 reaches at most
-- 31: D above 31 is CLAMPED to 31 (all flags); D <= 0 or non-number gives {}.
-- D is floored to an integer first.
function ABN_Config.Bits(D)
	local out = {}
	if type(D) ~= "number" then return out end
	local ladder = ABN_Config.LOY_BITS
	local max = 0
	for i = 1, #ladder do max = max + ladder[i] end
	D = math.floor(D)
	if D > max then D = max end
	for i = #ladder, 1, -1 do
		if D >= ladder[i] then
			D = D - ladder[i]
			table.insert(out, 1, ladder[i])
		end
	end
	return out
end

-- The city is blocked from a new abandonment while turn < CooldownEnd.
function ABN_Config.CooldownEnd(cancelTurn)
	return cancelTurn + ABN_Config.COOLDOWN_TURNS
end

ABN_Config.LOADED = 1
