-- ===========================================================================
-- harness.lua  (offline harness)
-- Test helpers on top of fake_engine.lua: world building, loading mod files,
-- turn simulation, request firing, log/notification queries and assertions.
--
-- Test files (tests/offline/test_*.lua) register tests with
--   test("name", function() ... end, opts)
-- opts: { allowErrors = true } accepts handler errors and ERROR log lines;
-- xfail("Phase 2: reason") marks an expected failure (see run_tests.py).
-- Each test runs in a FRESH Lua state: fake engine + fake UI layer (not
-- enabled) + this file + the test file, then the named test function.
-- A test usually does:
--   H.world{}
--   H.load("ABN/Scripts/ABN_Gameplay.lua")     -- the AddGameplayScripts file
--   ... set up diplomacy, fire requests and turns, assert ...
-- ===========================================================================

H = {}
TESTS = {}

function test(name, fn, opts)
	TESTS[#TESTS + 1] = { name = name, fn = fn, opts = opts or {} }
end

-- Explicit expected-fail declaration (the ONLY way to get XFAIL from the runner):
--   test("name", fn, xfail("Phase 2 (WP2.1): vote popup"))
-- The reason must name the pending work package ("WPx.y") or phase ("Phase N").
function xfail(reason, opts)
	opts = opts or {}
	opts.xfail = reason
	return opts
end

-- Skips the running test (status SKIP, not a failure).
function H.skip(reason)
	error("SKIP " .. tostring(reason), 0)
end

-- Skips the running test when GameInfo was not exported from the game DB
-- (tests/offline/data/gameinfo_data.lua missing: no game on this machine).
function H.needGameInfo()
	if not FAKE.gameInfoLoaded then
		H.skip("needs tests/offline/data/gameinfo_data.lua (generated from the game DB)")
	end
end

-- ---------------------------------------------------------------------------
-- Assertions (errors start with "ASSERT" so the runner can tell them apart)
-- ---------------------------------------------------------------------------
local function Ser(v, depth)
	depth = depth or 0
	if type(v) == "table" then
		if depth > 4 then return "{...}" end
		local parts = {}
		for _, k in ipairs(FAKE.SortedKeys(v)) do
			local ks = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
			parts[#parts + 1] = ks .. "=" .. Ser(v[k], depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end
H.Ser = Ser

local function Fail(msg, level)
	error("ASSERT " .. msg, (level or 2) + 1)
end
H.fail = function(msg) Fail(msg, 2) end

function H.ok(v, msg)
	if not v then Fail((msg or "expected truthy") .. " (got " .. Ser(v) .. ")", 2) end
end
function H.eq(actual, expected, msg)
	if actual ~= expected then
		Fail((msg or "values differ") .. ": expected " .. Ser(expected) .. ", got " .. Ser(actual), 2)
	end
end
function H.ne(actual, notExpected, msg)
	if actual == notExpected then
		Fail((msg or "value must differ") .. ": got " .. Ser(actual), 2)
	end
end
function H.isnil(v, msg)
	if v ~= nil then Fail((msg or "expected nil") .. " (got " .. Ser(v) .. ")", 2) end
end
function H.notnil(v, msg)
	if v == nil then Fail(msg or "expected non-nil", 2) end
end
local function DeepEq(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not DeepEq(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end
H.deepEqual = DeepEq
function H.deq(actual, expected, msg)
	if not DeepEq(actual, expected) then
		Fail((msg or "tables differ") .. ":\n  expected " .. Ser(expected) .. "\n  got      " .. Ser(actual), 2)
	end
end
function H.contains(list, v, msg)
	for _, x in ipairs(list or {}) do
		if x == v then return end
	end
	Fail((msg or "list does not contain value") .. ": " .. Ser(v) .. " not in " .. Ser(list), 2)
end
function H.notContains(list, v, msg)
	for _, x in ipairs(list or {}) do
		if x == v then Fail((msg or "list must not contain value") .. ": " .. Ser(v), 2) end
	end
end
function H.len(list, n, msg)
	local got = list and #list or -1
	if got ~= n then Fail((msg or "length differs") .. ": expected " .. n .. ", got " .. got .. " " .. Ser(list), 2) end
end
function H.throws(fn, msg)
	local ok = pcall(fn)
	if ok then Fail(msg or "expected an error", 2) end
end

-- ---------------------------------------------------------------------------
-- World building
-- ---------------------------------------------------------------------------
-- H.world{ turn = 1, players = { {id = 0, human = true}, ... } }
-- Default players: 0 human major, 1, 2, 3 AI majors, 4 city-state,
-- 62 Free Cities, 63 Barbarians. Each player is its own team (team = id)
-- unless the player entry says otherwise. H.world also builds a 40x24 land
-- map (wrapX) unless opts.map == false or opts.map = { w, h, wrapX, terrain }.
function H.world(opts)
	opts = opts or {}
	FAKE.turn = opts.turn or 1
	local players = opts.players or {
		{ id = 0, human = true },
		{ id = 1 },
		{ id = 2 },
		{ id = 3 },
		{ id = 4, kind = "CITY_STATE" },
		{ id = 62, kind = "FREE_CITIES" },
		{ id = 63, kind = "BARBARIAN" },
	}
	for _, p in ipairs(players) do
		FAKE.NewPlayer(p.id, FAKE.DeepCopy(p))
	end
	if opts.map ~= false then
		local m = opts.map or {}
		FAKE.NewMap(m.w or 40, m.h or 24, m.wrapX, m.terrain)
	end
	return FAKE.players
end

function H.player(id) return Players[id] end
function H.kill(pid) Players[pid].alive = false end
function H.human(pid, v) Players[pid].human = (v ~= false) end

-- Cities and units: H.city(pid, x, y, population, opts) / H.unit(pid, x, y, opts)
-- (opts as FAKE.NewCity / FAKE.NewUnit). H.dist is the hex distance on the fake map.
function H.city(pid, x, y, pop, opts)
	opts = opts or {}
	opts.population = pop or opts.population or 1
	return FAKE.NewCity(pid, x, y, opts)
end
function H.unit(pid, x, y, opts)
	opts = opts or {}
	return FAKE.NewUnit(pid, opts.type or "UNIT_FAKE", x, y, opts)
end
function H.dist(x1, y1, x2, y2) return Map.GetPlotDistance(x1, y1, x2, y2) end

-- Diplomacy (symmetric unless noted)
function H.war(a, b) FAKE.SetWar(a, b, true) end
function H.peace(a, b) FAKE.SetWar(a, b, false) end
function H.meet(a, b)
	FAKE.PairSet(FAKE.diplo.met, a, b, true); FAKE.PairSet(FAKE.diplo.met, b, a, true)
end

-- ---------------------------------------------------------------------------
-- Loading mod files
-- ---------------------------------------------------------------------------
-- Runs a file (path from the repo root) like AddGameplayScripts does and marks
-- the log position where the test body starts.
function H.load(rel)
	local r = FAKE.dofile(rel)
	H.markBody()
	return r
end

-- Simulates quitting to the main menu and loading the save: the listed
-- globals and every event handler are dropped (fresh Lua state in the game),
-- Game properties and the world survive, then the files run again.
function H.reload(files, globals)
	for _, name in ipairs(globals or {}) do
		_G[name] = nil
	end
	for _, ns in ipairs({ GameEvents, Events, LuaEvents }) do
		for _, ev in pairs(ns) do
			ev.handlers = {}
		end
	end
	if type(files) == "string" then files = { files } end
	for _, rel in ipairs(files or {}) do
		FAKE.dofile(rel)
	end
end

-- Loads ABN/Scripts/ABN_Gameplay.lua (the AddGameplayScripts file) when it exists.
-- Returns true when it was loaded, false when the mod does not exist yet.
H.GAMEPLAY_FILE = "ABN/Scripts/ABN_Gameplay.lua"
function H.loadABN()
	if __py_read(H.GAMEPLAY_FILE) == nil then
		H.markBody()
		return false
	end
	H.load(H.GAMEPLAY_FILE)
	return true
end

function H.markBody()
	FAKE.bodyStart = #FAKE.log
end

-- ---------------------------------------------------------------------------
-- Turn simulation in the in-game order measured in game:
--   OnGameTurnStarted(N) > human PlayerTurnStarted > PlayerTurnStartComplete >
--   acts > every other living player in ID order PTS > PTSC > acts
--   (... 62, 63 last) > GameEvents.OnGameTurnEnded(N) > Events.TurnEnd(N) >
--   OnGameTurnStarted(N+1)
-- GameEvents.OnPlayerTurnEnded is NOT fired (it never fired in game).
-- H.endTurn() is the human(s) pressing End Turn in turn T:
--   1. every alive NON-human player p, ascending: PlayerTurnStarted(p) ->
--      PlayerTurnStartComplete(p) -> opts.act(p, T)
--   2. GameEvents.OnGameTurnEnded(T) (turn still T) -> Events.TurnEnd(T)
--   3. turn T+1 -> GameEvents.OnGameTurnStarted(T+1) -> Events.TurnBegin(T+1)
--   4. every alive HUMAN player p, ascending: PlayerTurnStarted(p) ->
--      PlayerTurnStartComplete(p)
-- It returns while the human(s) play turn T+1 (the test body acts as them).
-- ---------------------------------------------------------------------------
local function AliveAscending()
	local ids = PlayerManager.GetAliveIDs()
	table.sort(ids)
	return ids
end

local function IsHumanID(pid)
	local p = Players[pid]
	return p ~= nil and p:IsHuman() == true
end

local function StartPlayerTurn(pid)
	GameEvents.PlayerTurnStarted(pid)
	GameEvents.PlayerTurnStartComplete(pid)
end

function H.endTurn(opts)
	opts = opts or {}
	local T = FAKE.turn
	for _, pid in ipairs(AliveAscending()) do
		if not IsHumanID(pid) then
			StartPlayerTurn(pid)
			if opts.act then opts.act(pid, T) end
		end
	end
	GameEvents.OnGameTurnEnded(T)
	Events.TurnEnd(T)
	FAKE.turn = T + 1
	GameEvents.OnGameTurnStarted(FAKE.turn)
	Events.TurnBegin(FAKE.turn)
	for _, pid in ipairs(AliveAscending()) do
		if IsHumanID(pid) then
			StartPlayerTurn(pid)
		end
	end
	return FAKE.turn
end

function H.turns(n, opts)
	for _ = 1, n do H.endTurn(opts) end
	return FAKE.turn
end

-- Fires a UI request the way EXECUTE_SCRIPT delivers it: GameEvents[OnStart](playerID, params),
-- in the gameplay context. (With fake_ui enabled, UI.RequestPlayerOperation does the same.)
function H.request(pid, params)
	local p = FAKE.DeepCopy(params)
	local ui, ctx = UI, FAKE.context
	UI = nil
	FAKE.context = "G"
	GameEvents[p.OnStart](pid, p)
	UI = ui
	FAKE.context = ctx
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
function H.prop(k) return Game:GetProperty(k) end

-- Notifications sent. Filters: pid, typeName (either may be nil).
function H.notifs(pid, typeName)
	local out = {}
	for _, n in ipairs(FAKE.notifications) do
		if (pid == nil or n.pid == pid) and (typeName == nil or n.typeName == typeName) then
			out[#out + 1] = n
		end
	end
	return out
end
function H.clearNotifs() FAKE.notifications = {} end

-- Log lines of the test body (optionally only those containing a plain substring).
function H.lines(substr, fromStart)
	local out = {}
	local first = fromStart and 1 or ((FAKE.bodyStart or 0) + 1)
	for i = first, #FAKE.log do
		local l = FAKE.log[i]
		if substr == nil or string.find(l, substr, 1, true) then out[#out + 1] = l end
	end
	return out
end
function H.hasLine(substr) return #H.lines(substr) > 0 end
function H.errorLines()
	local out = {}
	for i = (FAKE.bodyStart or 0) + 1, #FAKE.log do
		local l = FAKE.log[i]
		if string.find(l, "%]%[[^%]]+%] ERROR ") or string.find(l, "%]%[[^%]]+%] G ERROR ")
				or string.find(l, "%]%[[^%]]+%] UI ERROR ") or string.find(l, "Runtime Error", 1, true) then
			out[#out + 1] = l
		end
	end
	return out
end
-- Asserts no ERROR lines, no handler errors, no storage-rule violations and no MP-unsafe calls.
function H.clean(msg)
	local errs = H.errorLines()
	if #errs > 0 then Fail((msg or "logged errors") .. ":\n  " .. table.concat(errs, "\n  "), 2) end
	if #FAKE.handlerErrors > 0 then Fail("handler errors:\n  " .. table.concat(FAKE.handlerErrors, "\n  "), 2) end
	if #FAKE.propViolations > 0 then Fail("property storage violations:\n  " .. table.concat(FAKE.propViolations, "\n  "), 2) end
	if #FAKE.forbidden > 0 then Fail("MP-unsafe calls in gameplay: " .. table.concat(FAKE.forbidden, ", "), 2) end
end
