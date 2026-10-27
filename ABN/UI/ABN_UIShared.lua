-- ===========================================================================
-- ABN_UIShared.lua
-- Module:   ABN_UIShared (global table), UI only, include("ABN_UIShared")
-- Owner:    WP8 (PLAN 9: Request(), state readers, preview builder, texts).
-- The UI never writes state; it asks gameplay through EXECUTE_SCRIPT.
-- Everything here is advisory: gameplay re-validates every request (PLAN 4).
-- ===========================================================================

if ABN_UIShared ~= nil and ABN_UIShared.LOADED == 1 then
	return
end

include("ABN_Config")
include("ABN_Util")
include("ABN_Rules")

ABN_UIShared = {}
local M = ABN_UIShared

local LOYALTY_WARN_BELOW = 50 -- DECISIONS #14

local function Log(tag, fmt, ...)
	if ABN_Util ~= nil and ABN_Util.Log ~= nil then
		ABN_Util.Log(tag, fmt, ...)
	end
end

-- ---------------------------------------------------------------------------
-- Requests (PLAN 4). Flat params only.
-- ---------------------------------------------------------------------------

-- Request(onStart, params): copies the flat params and adds OnStart. Returns true when sent.
function M.Request(onStart, params)
	local pid = Game.GetLocalPlayer()
	if pid == nil or pid < 0 then
		return false
	end
	local t = { OnStart = onStart }
	for k, v in pairs(params or {}) do
		local tv = type(v)
		if tv == "number" or tv == "string" or tv == "boolean" then
			t[k] = v
		end
	end
	UI.RequestPlayerOperation(pid, PlayerOperations.EXECUTE_SCRIPT, t)
	return true
end

function M.RequestStart(cityID, x, y)
	return M.Request(ABN_Config.REQ_START, { cityID = cityID, x = x, y = y })
end

function M.RequestCancel(cityID, x, y)
	return M.Request(ABN_Config.REQ_CANCEL, { cityID = cityID, x = x, y = y })
end

-- ---------------------------------------------------------------------------
-- State readers (Game properties; the UI reads them itself)
-- ---------------------------------------------------------------------------

local function ReadArray(key)
	local v = Game:GetProperty(key)
	if type(v) ~= "table" then
		return {}
	end
	return v
end
M.ReadArray = ReadArray

-- The RUN record of this city, or nil. Keyed by owner + plot, cityID checked too.
function M.FindActive(owner, cityID, x, y)
	for _, r in ipairs(ReadArray(ABN_Config.KEY_ACTIVE)) do
		if r.owner == owner and r.x == x and r.y == y and (r.cityID == nil or r.cityID == cityID) then
			return r
		end
	end
	return nil
end

-- 1-based turn of the abandonment (click turn = 1), clamped to 1..T.
function M.TurnIndex(rec, turn)
	local k = turn - rec.start + 1
	if k < 1 then k = 1 end
	if rec.T ~= nil and k > rec.T then k = rec.T end
	return k
end

-- First reason the city cannot be started, or nil. Second value: turns left (COOLDOWN).
-- ABN_Rules.FirstBlocker does every check with UI reads (capital by ID, original
-- capital incl. IsOriginalCapital(), IsUnderSiege per DECISIONS #24). If it raises,
-- the button is blocked with a generic reason (a broken read never enables it).
function M.Blocker(pCity, owner, turn)
	local ok, code, info = pcall(ABN_Rules.FirstBlocker, pCity, owner, turn)
	if not ok then
		Log("UI", "FirstBlocker failed: %s", tostring(code))
		return "UNKNOWN"
	end
	if code == "COOLDOWN" then
		local left = 1
		if type(info) == "number" and info - turn > 1 then
			left = info - turn
		end
		return code, left
	end
	return code
end

-- ---------------------------------------------------------------------------
-- Preview builder (pure arithmetic from ABN_Config + advisory loyalty reads)
-- ---------------------------------------------------------------------------

local function CityLoyalty(pCity)
	local ok, v = pcall(function() return pCity:GetCulturalIdentity():GetLoyalty() end)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

-- Own cities (other than pCity) within R tiles, in Members() order:
-- { { name = LOC key, loyalty = number|nil, low = bool }, ... }
function M.AffectedCities(pCity, owner, R)
	local out = {}
	local x, y, id = pCity:GetX(), pCity:GetY(), pCity:GetID()
	for _, c in Players[owner]:GetCities():Members() do
		if c:GetID() ~= id and Map.GetPlotDistance(x, y, c:GetX(), c:GetY()) <= R then
			local loy = CityLoyalty(c)
			out[#out + 1] = { name = c:GetName(), loyalty = loy, low = loy ~= nil and loy < LOYALTY_WARN_BELOW }
		end
	end
	return out
end

-- Start preview for a city: P0, T, F, D, R, targets (turn 1..T), span (2T), affected.
function M.Preview(pCity, owner)
	local P0 = pCity:GetPopulation()
	local s = ABN_Config.Schedule(P0)
	local R = ABN_Config.R(P0)
	return {
		P0 = P0, T = s.T, F = s.F, targets = s.targets,
		D = ABN_Config.D(P0), R = R, span = 2 * s.T,
		affected = M.AffectedCities(pCity, owner, R),
	}
end

-- ---------------------------------------------------------------------------
-- Texts
-- ---------------------------------------------------------------------------

local function JoinTargets(targets, from, to)
	local parts = {}
	for i = from, to do
		parts[#parts + 1] = tostring(targets[i])
	end
	return table.concat(parts, ", ")
end

local BLOCK_KEYS = {
	SIEGE = "LOC_ABN_BLOCK_SIEGE", DAMAGED = "LOC_ABN_BLOCK_SIEGE",
	ENEMY_NEAR = "LOC_ABN_BLOCK_ENEMY_NEAR", CAPITAL = "LOC_ABN_BLOCK_CAPITAL",
	LAST_CITY = "LOC_ABN_BLOCK_LAST_CITY", ORIGINAL_CAPITAL = "LOC_ABN_BLOCK_ORIGINAL_CAPITAL",
	ACTIVE = "LOC_ABN_BLOCK_ACTIVE",
}

function M.BlockerText(code, cooldownLeft)
	if code == "COOLDOWN" then
		return Locale.Lookup("LOC_ABN_BLOCK_COOLDOWN", cooldownLeft or 1)
	end
	return Locale.Lookup(BLOCK_KEYS[code] or "LOC_ABN_BLOCK_UNKNOWN")
end

function M.StartTooltip(pv)
	return Locale.Lookup("LOC_ABN_BUTTON_ABANDON") .. "[NEWLINE]"
		.. Locale.Lookup("LOC_ABN_TT_START", pv.T, JoinTargets(pv.targets, 1, pv.T), pv.R, pv.D, pv.span)
end

function M.BlockedTooltip(code, cooldownLeft)
	return Locale.Lookup("LOC_ABN_BUTTON_ABANDON") .. "[NEWLINE]" .. M.BlockerText(code, cooldownLeft)
end

-- Facts of a running abandonment on this turn.
function M.RunInfo(rec, turn)
	local k = M.TurnIndex(rec, turn)
	local endTurn = ABN_Config.DebuffEndTurn(rec.start, rec.T)
	local left = rec.T - k + 1
	local targets = ABN_Config.Schedule(rec.P0).targets
	local debuffTurns = endTurn - turn + 1
	if debuffTurns < 0 then debuffTurns = 0 end
	return {
		k = k, left = left, targets = targets,
		debuffTurns = debuffTurns,
		-- Cancelling now: ran e turns (this one included), debuff continues e more (DECISIONS #12).
		cancelDebuffTurns = turn - rec.start + 1,
		cooldownTurns = ABN_Config.COOLDOWN_TURNS,
	}
end

function M.CancelTooltip(rec, turn)
	local ri = M.RunInfo(rec, turn)
	return Locale.Lookup("LOC_ABN_BUTTON_CANCEL") .. "[NEWLINE]"
		.. Locale.Lookup("LOC_ABN_TT_CANCEL", ri.left, JoinTargets(ri.targets, ri.k, rec.T), rec.R, rec.D, ri.debuffTurns)
end

-- Confirmation popup content: { title, body } (body is one string with [NEWLINE]s).
function M.ConfirmText(pCity, pv)
	local lines = { Locale.Lookup("LOC_ABN_POPUP_BODY", pv.T), "" }
	for i = 1, pv.T do
		local key = (i == pv.T) and "LOC_ABN_POPUP_TURN_LAST" or "LOC_ABN_POPUP_TURN"
		lines[#lines + 1] = Locale.Lookup(key, i, pv.targets[i])
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = Locale.Lookup("LOC_ABN_POPUP_DEBUFF", pv.R, pv.D, pv.span, pv.T)
	local names, low = {}, {}
	for _, a in ipairs(pv.affected) do
		names[#names + 1] = Locale.Lookup(a.name)
		if a.low then
			low[#low + 1] = Locale.Lookup("LOC_ABN_POPUP_CITY_LOYALTY", Locale.Lookup(a.name), math.floor(a.loyalty + 0.5))
		end
	end
	if #names > 0 then
		lines[#lines + 1] = Locale.Lookup("LOC_ABN_POPUP_AFFECTED", table.concat(names, ", "))
	else
		lines[#lines + 1] = Locale.Lookup("LOC_ABN_POPUP_AFFECTED_NONE")
	end
	if #low > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = Locale.Lookup("LOC_ABN_POPUP_WARN", table.concat(low, ", "))
	end
	return {
		title = Locale.Lookup("LOC_ABN_POPUP_TITLE", Locale.Lookup(pCity:GetName())),
		body = table.concat(lines, "[NEWLINE]"),
	}
end

function M.CancelText(pCity, rec, turn)
	local ri = M.RunInfo(rec, turn)
	return {
		title = Locale.Lookup("LOC_ABN_CANCEL_TITLE", Locale.Lookup(pCity:GetName())),
		body = Locale.Lookup("LOC_ABN_CANCEL_BODY", ri.cooldownTurns, rec.D, ri.cancelDebuffTurns),
	}
end

-- ---------------------------------------------------------------------------
-- Button state for the selected city (the context only draws it).
-- { kind = "HIDE" }
-- { kind = "START",  tooltip, pv }
-- { kind = "BLOCKED", tooltip, code }
-- { kind = "CANCEL", tooltip, left, rec }
-- ---------------------------------------------------------------------------
function M.StateFor(pCity, localPlayer, turn)
	if pCity == nil or localPlayer == nil or localPlayer < 0 or pCity:GetOwner() ~= localPlayer then
		return { kind = "HIDE" }
	end
	local rec = M.FindActive(localPlayer, pCity:GetID(), pCity:GetX(), pCity:GetY())
	if rec ~= nil then
		local ri = M.RunInfo(rec, turn)
		return { kind = "CANCEL", tooltip = M.CancelTooltip(rec, turn), left = ri.left, rec = rec }
	end
	local code, cd = M.Blocker(pCity, localPlayer, turn)
	if code ~= nil then
		return { kind = "BLOCKED", tooltip = M.BlockedTooltip(code, cd), code = code }
	end
	local pv = M.Preview(pCity, localPlayer)
	return { kind = "START", tooltip = M.StartTooltip(pv), pv = pv }
end

M.LOADED = 1
