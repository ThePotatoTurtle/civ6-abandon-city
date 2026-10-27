-- ===========================================================================
-- ABN_Dev_Gameplay.lua  (ABN_Dev 0.1.0.0, WP9; PLAN 12)
-- Context:  gameplay (AddGameplayScripts). TESTING ONLY. Needs the ABN mod
--           (modinfo dependency, LoadOrder 14000, so every handler of ABN
--           runs before the ones below).
--
-- One synced request handler, GameEvents.ABN_Dev(playerID, params), dispatching
-- on params.cmd to ABN_Dev_Scenario.CMD (flat params from UI/ABN_Dev_Panel.lua;
-- EFV_Dev_Gameplay.lua:5717 pattern). The requester is the only trusted
-- player ID, and only humans may use the dev commands.
--
-- Turn start (GameEvents.OnGameTurnStarted, after the mod's pipeline):
--   ABN_Dev_Check.Observe("turn") compares the mod's state with the dev
--   ledger and writes [ABN][CHECK] lines (population, removal turn, windows,
--   cooldown, loyalty flags, auto-cancel). Switch it off with the panel's
--   "Checker" button.
--
-- Log lines (Lua.log; tools\summarize_abn_log.py reads the CHECK lines):
--   [ABN][CHECK] <ID> <PASS|FAIL|INFO> T<turn> <numbers>
--   [ABN][DEV] T<turn> <text>
-- The panel shows the latest lines from Game:SetProperty("ABN_DevLast", ...),
-- so a result can be read even when Lua.log is lost in a crash.
--
-- MP rules (playbook 3): no pairs() over state, no math.random, no
-- Game.GetLocalPlayer, state changes only in these two GameEvents handlers.
-- ===========================================================================

include("ABN_Config")
include("ABN_Dev_Core")
include("ABN_Dev_Check")
include("ABN_Dev_Scenario")

-- ABN:GLOBALS ABN_Config ABN_Rules
ABN_Dev = {}
ABN_Dev.VERSION = ABN_Dev_Core.VERSION

local C = ABN_Dev_Core
local X = ABN_Dev_Check
local S = ABN_Dev_Scenario

function ABN_Dev.OnRequest(playerID, params)
	if type(params) ~= "table" then
		C.Info("dispatch: non-table params")
		C.Flush()
		return
	end
	local cmd = params.cmd
	local fn = S.CMD[cmd]
	if fn == nil then
		C.Info("dispatch: unknown cmd " .. C.Str(cmd))
		C.Flush(params.stamp)
		return
	end
	if not C.IsHuman(playerID) then
		C.Info("dispatch: ignored " .. C.Str(cmd) .. " from non-human P" .. C.Str(playerID))
		C.Flush(params.stamp)
		return
	end
	C.Note("cmd " .. C.Str(cmd) .. " from P" .. C.Str(playerID) .. " stamp=" .. C.Str(params.stamp))
	local ok, err = pcall(fn, playerID, params)
	if not ok then
		local line = "[ABN][DEV] G ERROR cmd " .. C.Str(cmd) .. ": " .. C.Str(err)
		print(line)
		C.Info("cmd " .. C.Str(cmd) .. " raised an error (see Lua.log)")
	end
	C.Flush(params.stamp)
end

function ABN_Dev.OnGameTurnStarted(turn)
	local ok, err = pcall(function()
		X.RecordOrigCaps()
		local st = C.State()
		local active = #C.ReadArr(ABN_Config.KEY_ACTIVE)
		local wins = #C.ReadArr(ABN_Config.KEY_WINDOWS)
		local cds = #C.ReadArr(ABN_Config.KEY_COOLDOWNS)
		C.Note("TURN " .. C.Str(turn) .. " mod state: active=" .. active .. " windows=" .. wins .. " cooldowns=" .. cds ..
			" schema=" .. C.Str(C.ReadProp(ABN_Config.KEY_SCHEMA)) .. " checker=" .. (st.checker ~= 0 and "on" or "off"))
		if st.checker ~= 0 then
			X.Observe("turn")
		end
	end)
	if not ok then
		print("[ABN][DEV] G ERROR turn hook: " .. C.Str(err))
	end
	C.Flush()
end

-- Print-only: the combat events the mod's damage tracker listens to.
function ABN_Dev.OnCombat(aP, aU, dP, dU, aD, dD)
	C.Note("COMBAT a=" .. C.Str(aP) .. "/" .. C.Str(aU) .. " d=" .. C.Str(dP) .. "/" .. C.Str(dU) .. " aD=" .. C.Str(aD) .. " dD=" .. C.Str(dD))
end

GameEvents.ABN_Dev.Add(ABN_Dev.OnRequest)
GameEvents.OnGameTurnStarted.Add(ABN_Dev.OnGameTurnStarted)
GameEvents.OnCombatOccurred.Add(ABN_Dev.OnCombat)

print("[ABN][DEV] ABN_Dev gameplay " .. ABN_Dev.VERSION .. " loaded; GameEvents.ABN_Dev registered")
