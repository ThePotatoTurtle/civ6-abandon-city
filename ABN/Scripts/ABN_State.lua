-- ===========================================================================
-- ABN_State.lua
-- Module:   ABN_State (global table), include("ABN_State")
-- Context:  shared. Gameplay reads and writes; the UI only reads (Game:GetProperty
--           works in UI, EFV T03). Every write is inside an ABN:G-ONLY region and
--           refuses to run in a UI context.
-- Owner:    WP3 (PLAN 3: Game-property store).
--
-- Storage (PLAN 3; EFV Records rules, measured in game):
--   * one Game property per key, each a dense array of flat records;
--   * one Game:SetProperty per key after each change (Put);
--   * records hold numbers and strings only: booleans become 0/1, empty
--     strings are dropped (they come back as nil), functions/userdata dropped;
--   * an empty array may read back as nil: Get always returns a table;
--   * Get deep-copies what GetProperty returns (it may be a live reference),
--     so editing a Get result never changes the saved state until Put.
--   * records are keyed by owner + plot index; callers re-check the stored
--     cityID against the live city (ABN_Util.CityFor).
--
-- Record shapes (PLAN 3 table):
--   ABN_Active    {owner, cityID, x, y, plot, P0, T, F, D, R, start, lastStep, status}
--   ABN_Windows   {owner, x, y, D, R, start, endTurn, srcPlot, phase}
--   ABN_Cooldowns {owner, cityID, plot, endTurn}
--   ABN_Damage    {owner, cityID, plot, lastTurn, g, o}
--   ABN_Flagged   {plot, bits, x, y}
--   ABN_OrigCaps  {player, plot}
--   ABN_SchemaV   number (ABN_State.SCHEMA)
--
-- Determinism: ipairs only; arrays keep insertion order; removal rebuilds
-- the array in order.
-- ===========================================================================

if ABN_State ~= nil and ABN_State.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")

ABN_State = {}

ABN_State.SCHEMA = 1

-- ---------------------------------------------------------------------------
-- Low level
-- ---------------------------------------------------------------------------

-- Copy of a record with only storable values (numbers, strings, 0/1, nested
-- tables of the same). Walks keys in SortedKeys order.
local function Clean(v, depth)
	local tv = type(v)
	if tv == "number" then
		return v
	elseif tv == "string" then
		if v == "" then
			return nil
		end
		return v
	elseif tv == "boolean" then
		return v and 1 or 0
	elseif tv == "table" then
		if (depth or 0) > 10 then
			return nil
		end
		local out = {}
		for _, k in ipairs(ABN_Util.SortedKeys(v)) do
			out[k] = Clean(v[k], (depth or 0) + 1)
		end
		return out
	end
	return nil
end

local function ReadRaw(key)
	local ok, v = pcall(function() return Game:GetProperty(key) end)
	if not ok then
		ABN_Util.Error("State", "GetProperty(%s) failed: %s", tostring(key), tostring(v))
		return nil
	end
	return v
end

-- Get(key) -> dense array of record tables (never nil). Non-table elements
-- and anything after a hole are skipped.
function ABN_State.Get(key)
	local v = ReadRaw(key)
	local out = {}
	if type(v) ~= "table" then
		return out
	end
	for _, e in ipairs(v) do
		if type(e) == "table" then
			out[#out + 1] = ABN_Util.DeepCopy(e)
		end
	end
	return out
end

-- Put(key, arr) -> bool: stores the array (cleaned, dense) with one
-- Game:SetProperty. Gameplay only; returns false (and logs) in a UI context.
function ABN_State.Put(key, arr)
	if not ABN_Util.IsGameplay() then
		ABN_Util.Error("State", "Put(%s) called in a UI context; the UI never writes state", tostring(key))
		return false
	end
	local out = {}
	for _, e in ipairs(arr or {}) do
		if type(e) == "table" then
			out[#out + 1] = Clean(e)
		end
	end
	local ok, err = false, nil
	-- ABN:G-ONLY begin
	ok, err = pcall(function() Game:SetProperty(key, out) end)
	-- ABN:G-ONLY end
	if not ok then
		ABN_Util.Error("State", "SetProperty(%s) failed: %s", tostring(key), tostring(err))
		return false
	end
	return true
end

-- Schema() -> stored schema number, or nil when never initialised.
function ABN_State.Schema()
	local v = ReadRaw(ABN_Config.KEY_SCHEMA)
	if type(v) == "number" then
		return v
	end
	return nil
end

-- Init() -> schema: writes ABN_SchemaV = SCHEMA when missing (gameplay only;
-- call once at load or at the first turn start). Later schema versions add
-- their migrations here.
function ABN_State.Init()
	local s = ABN_State.Schema()
	if s ~= nil then
		return s
	end
	if not ABN_Util.IsGameplay() then
		return nil
	end
	-- ABN:G-ONLY begin
	local ok, err = pcall(function() Game:SetProperty(ABN_Config.KEY_SCHEMA, ABN_State.SCHEMA) end)
	if not ok then
		ABN_Util.Error("State", "SetProperty(%s) failed: %s", ABN_Config.KEY_SCHEMA, tostring(err))
		return nil
	end
	-- ABN:G-ONLY end
	ABN_Util.Log("State", "schema initialised to %d", ABN_State.SCHEMA)
	return ABN_State.SCHEMA
end

-- ---------------------------------------------------------------------------
-- Generic array operations (each write = one Put)
-- ---------------------------------------------------------------------------

-- Find(key, fn) -> record, index of the first record with fn(rec) true; nil.
function ABN_State.Find(key, fn)
	local i, rec = ABN_Util.FindIndex(ABN_State.Get(key), fn)
	return rec, i
end

-- FindAll(key, fn) -> array of the records with fn(rec) true (stored order).
function ABN_State.FindAll(key, fn)
	return ABN_Util.Filter(ABN_State.Get(key), fn)
end

-- Add(key, rec) -> index, or nil when the write failed (or in UI): appends rec.
function ABN_State.Add(key, rec)
	local arr = ABN_State.Get(key)
	arr[#arr + 1] = rec
	if not ABN_State.Put(key, arr) then
		return nil
	end
	return #arr
end

-- RemoveWhere(key, fn) -> array of removed records (no write when none).
function ABN_State.RemoveWhere(key, fn)
	local kept, removed = ABN_Util.Partition(ABN_State.Get(key), fn)
	if #removed > 0 then
		ABN_State.Put(key, kept)
	end
	return removed
end

-- Upsert(key, fn, rec) -> index (nil when the write failed): replaces the
-- first record with fn(old) true by rec (same position), or appends rec.
function ABN_State.Upsert(key, fn, rec)
	local arr = ABN_State.Get(key)
	local i = ABN_Util.FindIndex(arr, fn)
	if i == nil then
		i = #arr + 1
	end
	arr[i] = rec
	if not ABN_State.Put(key, arr) then
		return nil
	end
	return i
end

-- Matchers
local function OwnerPlot(owner, plot)
	return function(r) return r.owner == owner and r.plot == plot end
end

-- ---------------------------------------------------------------------------
-- ABN_Active {owner, cityID, x, y, plot, P0, T, F, D, R, start, lastStep, status}
-- ---------------------------------------------------------------------------

-- FindActive(owner, plot) -> record, index | nil
function ABN_State.FindActive(owner, plot)
	return ABN_State.Find(ABN_Config.KEY_ACTIVE, OwnerPlot(owner, plot))
end

-- SetActive(rec): replaces the record with the same owner + plot, or appends.
function ABN_State.SetActive(rec)
	return ABN_State.Upsert(ABN_Config.KEY_ACTIVE, OwnerPlot(rec.owner, rec.plot), rec)
end

-- RemoveActive(owner, plot) -> the removed record, or nil.
function ABN_State.RemoveActive(owner, plot)
	return ABN_State.RemoveWhere(ABN_Config.KEY_ACTIVE, OwnerPlot(owner, plot))[1]
end

-- ---------------------------------------------------------------------------
-- ABN_Windows {owner, x, y, D, R, start, endTurn, srcPlot, phase}
-- One abandoning plot can own several windows (a cancelled run whose debuff
-- still runs, then a restart), so a window is identified by owner + srcPlot +
-- start.
-- ---------------------------------------------------------------------------
local function WindowMatch(owner, srcPlot, start)
	return function(w) return w.owner == owner and w.srcPlot == srcPlot and w.start == start end
end

function ABN_State.AddWindow(rec)
	return ABN_State.Add(ABN_Config.KEY_WINDOWS, rec)
end

-- FindWindow(owner, srcPlot, start) -> record, index | nil
function ABN_State.FindWindow(owner, srcPlot, start)
	return ABN_State.Find(ABN_Config.KEY_WINDOWS, WindowMatch(owner, srcPlot, start))
end

-- SetWindow(rec): replaces the window with the same owner + srcPlot + start, or appends.
function ABN_State.SetWindow(rec)
	return ABN_State.Upsert(ABN_Config.KEY_WINDOWS, WindowMatch(rec.owner, rec.srcPlot, rec.start), rec)
end

-- WindowsOf(owner) -> that owner's windows, stored order.
function ABN_State.WindowsOf(owner)
	return ABN_State.FindAll(ABN_Config.KEY_WINDOWS, function(w) return w.owner == owner end)
end

-- DropExpiredWindows(turn) -> removed windows (endTurn < turn), stored order.
function ABN_State.DropExpiredWindows(turn)
	return ABN_State.RemoveWhere(ABN_Config.KEY_WINDOWS, function(w)
		return type(w.endTurn) ~= "number" or w.endTurn < turn
	end)
end

-- ---------------------------------------------------------------------------
-- ABN_Cooldowns {owner, cityID, plot, endTurn}; blocked while turn < endTurn.
-- ---------------------------------------------------------------------------

-- AddCooldown(owner, cityID, plot, endTurn): one cooldown per owner + plot
-- (a newer one replaces the older one).
function ABN_State.AddCooldown(owner, cityID, plot, endTurn)
	return ABN_State.Upsert(ABN_Config.KEY_COOLDOWNS, OwnerPlot(owner, plot),
		{ owner = owner, cityID = cityID, plot = plot, endTurn = endTurn })
end

-- FindCooldown(owner, plot) -> record, index | nil (expired ones included;
-- ABN_Rules compares endTurn).
function ABN_State.FindCooldown(owner, plot)
	return ABN_State.Find(ABN_Config.KEY_COOLDOWNS, OwnerPlot(owner, plot))
end

-- DropExpiredCooldowns(turn) -> removed records (endTurn <= turn, PLAN 5 step 5).
function ABN_State.DropExpiredCooldowns(turn)
	return ABN_State.RemoveWhere(ABN_Config.KEY_COOLDOWNS, function(c)
		return type(c.endTurn) ~= "number" or c.endTurn <= turn
	end)
end

-- ---------------------------------------------------------------------------
-- ABN_Damage {owner, cityID, plot, lastTurn, g, o} (written by ABN_Damage, WP7)
-- ---------------------------------------------------------------------------

-- FindDamage(owner, plot) -> record, index | nil
function ABN_State.FindDamage(owner, plot)
	return ABN_State.Find(ABN_Config.KEY_DAMAGE, OwnerPlot(owner, plot))
end

-- SetDamage(rec): replaces the record with the same owner + plot, or appends.
function ABN_State.SetDamage(rec)
	return ABN_State.Upsert(ABN_Config.KEY_DAMAGE, OwnerPlot(rec.owner, rec.plot), rec)
end

-- RemoveDamage(owner, plot) -> the removed record, or nil.
function ABN_State.RemoveDamage(owner, plot)
	return ABN_State.RemoveWhere(ABN_Config.KEY_DAMAGE, OwnerPlot(owner, plot))[1]
end

-- ---------------------------------------------------------------------------
-- ABN_Flagged {plot, bits} (L-B2 plots carrying ladder properties)
-- ---------------------------------------------------------------------------

-- FindFlagged(plot) -> record, index | nil
function ABN_State.FindFlagged(plot)
	return ABN_State.Find(ABN_Config.KEY_FLAGGED, function(r) return r.plot == plot end)
end

-- SetFlagged(plot, bits, x, y): bits > 0 stores/replaces the entry; 0 or nil
-- removes it. x, y are kept because ABN_Loyalty clears stale plots by x/y.
function ABN_State.SetFlagged(plot, bits, x, y)
	if bits == nil or bits == 0 then
		ABN_State.RemoveWhere(ABN_Config.KEY_FLAGGED, function(r) return r.plot == plot end)
		return nil
	end
	return ABN_State.Upsert(ABN_Config.KEY_FLAGGED, function(r) return r.plot == plot end,
		{ plot = plot, bits = bits, x = x, y = y })
end

-- ---------------------------------------------------------------------------
-- ABN_OrigCaps {player, plot}: each major's first capital plot (DECISIONS #25).
-- Recorded by ABN_Rules.RecordOrigCaps() at each turn start while missing;
-- never changed once set.
-- ---------------------------------------------------------------------------

-- FindOrigCap(player) -> record, index | nil
function ABN_State.FindOrigCap(player)
	return ABN_State.Find(ABN_Config.KEY_ORIGCAPS, function(r) return r.player == player end)
end

-- AddOrigCap(player, plot) -> bool: appends unless the player already has
-- one; false when nothing was written.
function ABN_State.AddOrigCap(player, plot)
	if ABN_State.FindOrigCap(player) ~= nil then
		return false
	end
	return ABN_State.Add(ABN_Config.KEY_ORIGCAPS, { player = player, plot = plot }) ~= nil
end

ABN_State.LOADED = 1
