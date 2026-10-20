-- Offline smoke tests of the ABN_Dev spike build (WP0, SPIKES.md): every spike
-- handler runs in the fake engine without Lua errors. The fake engine models
-- only verified calls; the PENDING ones (city destroy variants, CreateBuilding,
-- the G loyalty and growth readers, ...) are absent in gameplay, so these
-- tests also prove that the spike code survives a missing method.

local GAMEPLAY = "ABN_Dev/Scripts/ABN_Dev_Gameplay.lua"
local PANEL = "ABN_Dev/UI/ABN_Dev_Panel.lua"

local function Rows()
	FAKE.AddRow("Units", "UnitType", { UnitType = "UNIT_WARRIOR", FormationClass = "FORMATION_CLASS_LAND_COMBAT" })
	FAKE.AddRow("Units", "UnitType", { UnitType = "UNIT_BUILDER", FormationClass = "FORMATION_CLASS_CIVILIAN" })
	FAKE.AddRow("Districts", "DistrictType", { DistrictType = "DISTRICT_CAMPUS" })
end

-- P0 capital at (10,12); AI capitals far away so the 4-12 ring is free.
local function World(opts)
	H.world(opts)
	Rows()
	H.city(0, 10, 12, 3, { capital = true })
	H.city(1, 30, 12, 3, { capital = true })
	H.city(2, 30, 3, 3, { capital = true })
	H.city(3, 30, 20, 3, { capital = true })
	H.load(GAMEPLAY)
end

local function Dev(cmd, pid)
	H.request(pid or 0, { OnStart = "ABN_Dev", cmd = cmd, stamp = 1 })
end

local function Rec(tag)
	for _, r in ipairs(H.prop("ABN_SpikeCities") or {}) do
		if r.tag == tag then return r end
	end
	return nil
end

local function CityAt(tag)
	local r = Rec(tag)
	return r and CityManager.GetCityAt(r.x, r.y) or nil
end

local function LastOK()
	local last = H.prop("ABN_SpikeLast")
	H.ok(type(last) == "table" and #last >= 1 and #last <= 12, "ABN_SpikeLast holds 1..12 lines")
	for _, s in ipairs(last) do H.eq(type(s), "string") end
end

test("dev gameplay loads and registers its handlers", function()
	World()
	H.eq(GameEvents.ABN_Dev.Count(), 1)
	H.eq(GameEvents.OnGameTurnStarted.Count(), 1)
	H.eq(GameEvents.OnCombatOccurred.Count(), 1)
	H.len(H.lines("ABN_Dev gameplay 0.0.0.1 loaded", true), 1, "init line")
	H.clean()
end)

test("S0 setup: seven cities, four campuses, met both ways", function()
	World()
	Dev("s0_setup")
	for _, tag in ipairs({ "S3-C", "S3-A", "S3-B0", "S3-B1", "S3-B2", "S2", "S4" }) do
		H.notnil(CityAt(tag), "city " .. tag)
		local r = Rec(tag)
		local d = H.dist(10, 12, r.x, r.y)
		H.ok(d >= 4 and d <= 12, tag .. " 4-12 tiles from the capital (" .. d .. ")")
	end
	for _, tag in ipairs({ "S3-A", "S3-B0", "S3-B1", "S3-B2" }) do H.notnil(Rec(tag).campus, "campus " .. tag) end
	H.ok(H.hasLine("[ABN][CHECK] S0_CITIES PASS"))
	H.ok(H.hasLine("[ABN][CHECK] S0_CAMPUS PASS"))
	H.ok(H.hasLine("CreateBuilding(S3-A, BUILDING_STONEHENGE)"), "wonder attempt logged")
	H.eq(Players[1]:GetDiplomacy():HasMet(0), true)
	H.eq(Players[0]:GetDiplomacy():HasMet(3), true)
	Dev("s0_setup")
	H.eq(Players[0]:GetCities():GetCount(), 8, "a second S0 founds nothing new")
	LastOK()
	H.clean()
end)

test("Part 1 sequence: P, S2, S3 x3, S4, S5, turns, S1 without errors", function()
	World()
	Dev("s0_setup")
	Dev("p_probes")
	H.ok(H.hasLine("[ABN][CHECK] P_WAR63 PASS"))
	Dev("s2a")
	H.eq(CityAt("S2"):GetPopulation(), 8)
	Dev("s2b")
	H.eq(CityAt("S2"):GetPopulation(), 2)
	H.ok(H.hasLine("[ABN][CHECK] S2_POP6 PASS"))
	H.ok(H.hasLine("[ABN][CHECK] S2_POP2 PASS"))
	Dev("s3_step")
	H.eq(CityAt("S3-A").loyalty, 54, "setup -40 then A -6")
	H.contains(CityAt("S3-B0").modifiers, "ABN_SPK_LOY_B0")
	H.eq(CityAt("S3-B1"):GetPlot():GetProperty("ABN_SPK_B1"), 1)
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_2"), 1)
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_4"), 1)
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_1"), 0)
	Dev("s4_run")
	H.ok(H.hasLine("[ABN][CHECK] S4_SCAN PASS"), "barbarian at 6 listed, at 7 not")
	H.eq(CityManager.GetDistrictAt(CityAt("S4"):GetX(), CityAt("S4"):GetY()):GetDamage(DefenseTypes.DISTRICT_GARRISON), 40)
	Dev("s4_read")
	GameEvents.OnCombatOccurred(0, 5, 1, 6, -1, -1)
	H.ok(H.hasLine("OnCombatOccurred a=0/5 d=1/6"))
	Dev("s5_self")
	H.len(H.notifs(0, "ABN_DEV_NOTIF_A"), 1)
	H.len(H.notifs(0, "ABN_DEV_NOTIF_B"), 1)
	local a = H.notifs(0, "ABN_DEV_NOTIF_A")[1]
	H.eq(a.data[ParameterTypes.LOCATION].x, CityAt("S4"):GetX(), "A carries S4's location")
	H.isnil(H.notifs(0, "ABN_DEV_NOTIF_B")[1].data[ParameterTypes.LOCATION])
	H.endTurn()
	H.len(H.notifs(0, "ABN_DEV_NOTIF_A"), 2, "armed turn-start copy")
	H.eq(CityAt("S3-A").loyalty, 48, "A repeats at turn start")
	H.ok(H.hasLine("OnGameTurnStarted arg=2 Game.GetCurrentGameTurn()=2"))
	Dev("s3_step")
	H.eq(CityAt("S3-B1"):GetPlot():GetProperty("ABN_SPK_B1"), 0)
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_1"), 1)
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_8"), 1)
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_2"), 0)
	H.endTurn()
	Dev("s3_step")
	H.eq(CityAt("S3-B2"):GetPlot():GetProperty("ABN_SPK_DBIT_8"), 0)
	H.endTurn()
	H.eq(CityAt("S3-A").loyalty, 42, "A stopped after click 3 (two turn starts applied)")
	Dev("s3_step")
	H.ok(H.hasLine("all 3 clicks done"))
	-- S1: no G variant exists in the fake: logged as FAIL checks, no Lua error
	Dev("s1_run")
	H.ok(H.hasLine("[ABN][CHECK] S1_G1 FAIL"))
	H.ok(H.hasLine("[ABN][CHECK] S1_G2 FAIL"))
	H.ok(H.hasLine("[ABN][CHECK] S1_G3 FAIL"))
	H.notnil(CityAt("S3-A"))
	Dev("s1_check")
	Dev("s1_arm_t")
	H.endTurn()
	H.ok(H.hasLine("none: no G variant worked"))
	Dev("s1_one")
	Dev("s1_one")
	Dev("s1_one")
	Dev("s1_one")
	H.ok(H.hasLine("all three G variants tried"))
	Dev("no_such_cmd")
	H.ok(H.hasLine("unknown cmd no_such_cmd"))
	LastOK()
	H.clean()
end)

test("S3 CHECK lines when gameplay can read the per-turn loyalty", function()
	World()
	Dev("s0_setup")
	-- test-side model of what S3 hopes to see (not the engine): base -1, B0 -6
	-- always once attached, B1 -6 while the plot flag is 1, B2 = -(bit sum)
	local function Model(c)
		c.GetCulturalIdentity = function(self)
			return {
				GetLoyalty = function() return self.loyalty or 100 end,
				GetLoyaltyPerTurn = function()
					local pt, p = -1, self:GetPlot()
					for _, m in ipairs(self.modifiers) do
						if m == "ABN_SPK_LOY_B0" then pt = pt - 6 end
						if m == "ABN_SPK_LOY_B1" and p:GetProperty("ABN_SPK_B1") == 1 then pt = pt - 6 end
					end
					for _, b in ipairs({ 1, 2, 4, 8, 16 }) do
						if p:GetProperty("ABN_SPK_DBIT_" .. b) == 1 then pt = pt - b end
					end
					return pt
				end,
			}
		end
	end
	for _, tag in ipairs({ "S3-C", "S3-A", "S3-B0", "S3-B1", "S3-B2" }) do Model(CityAt(tag)) end
	Dev("s3_step")
	H.ok(H.hasLine("[ABN][CHECK] S3_P1 PASS"))
	Dev("s3_step")
	H.ok(H.hasLine("[ABN][CHECK] S3_P2 PASS"))
	Dev("s3_step")
	H.ok(H.hasLine("[ABN][CHECK] S3_P3 PASS"))
	H.len(H.lines(" FAIL "), 0, "no S3 FAIL line")
	H.clean()
end)

test("S1 with a working G1: removal now and at turn start, about-to-run line stored", function()
	World()
	Dev("s0_setup")
	-- test-side stand-in for the unverified GetCities():Destroy(pCity)
	Players[0]:GetCities().Destroy = function(_, c) FAKE.RemoveCity(c) end
	Dev("s1_run")
	H.isnil(CityAt("S3-A"), "G1 removed S3-A")
	H.notnil(CityAt("S3-B0"), "G2 missing in the fake")
	H.ok(H.hasLine("[ABN][CHECK] S1_G1 PASS"))
	H.eq(H.prop("ABN_SpikeState").s1Worked, "G1")
	H.ok(H.hasLine("about to run Players[o]:GetCities():Destroy(pCity)"))
	Dev("s1_arm_t")
	H.notnil(CityAt("S2"))
	H.endTurn()
	H.isnil(CityAt("S2"), "S2 removed in OnGameTurnStarted")
	H.ok(H.hasLine("[ABN][CHECK] S1_G1_TURNSTART PASS"))
	H.ok(H.hasLine("S3-A turn_start plot="), "automatic snapshot at the next turn start")
	H.clean()
end)

test("hotseat: S5 HS setup/send reach met humans only; S1 HS arm stores the owner", function()
	World({ players = {
		{ id = 0, human = true }, { id = 1, human = true }, { id = 2, human = true }, { id = 3 },
		{ id = 62, kind = "FREE_CITIES" }, { id = 63, kind = "BARBARIAN" },
	} })
	Dev("s5_hs_setup")
	H.notnil(CityAt("HS"))
	H.eq(Players[1]:GetDiplomacy():HasMet(0), true)
	H.eq(Players[2]:GetDiplomacy():HasMet(0), false)
	Dev("s5_hs_send")
	H.len(H.notifs(0, "ABN_DEV_NOTIF_A"), 1)
	H.len(H.notifs(1, "ABN_DEV_NOTIF_A"), 1)
	H.len(H.notifs(1, "ABN_DEV_NOTIF_B"), 1)
	H.len(H.notifs(2), 0, "P2 has not met P0")
	Dev("s1_hs_arm")
	local st = H.prop("ABN_SpikeState")
	H.eq(st.hsOwner, 0)
	H.eq(st.hsSeq, 1)
	H.endTurn()
	H.len(H.notifs(1, "ABN_DEV_NOTIF_A"), 2, "turn-start copy to P1")
	H.len(H.notifs(2), 0)
	H.clean()
end)

test("panel: hotkey, every button, UI halves, S6 attach and the HS guard", function()
	World({ players = {
		{ id = 0, human = true }, { id = 1, human = true }, { id = 2 }, { id = 3 },
		{ id = 62, kind = "FREE_CITIES" }, { id = 63, kind = "BARBARIAN" },
	} })
	FAKE_UI.Enable()
	local env = FAKE_UI.LoadContext(PANEL)
	H.eq(env.ContextPtr:IsHidden(), false, "Initialize un-hides the context")
	H.eq(env.Controls.Main:IsHidden(), true)
	FAKE_UI.KeyTo(env, Keys.D, { ctrl = true, shift = true })
	H.eq(env.Controls.Main:IsHidden(), false, "Ctrl+Shift+D opens the panel")
	Events.LoadGameViewStateDone()
	H.ok(FAKE_UI.builtInstances ~= nil and FAKE_UI.builtInstances[1].name == "DevLaunchBarItem", "launch bar DEV button built")
	local order = { "S0 Setup", "P Probes", "S2a To 8", "S2b Cut", "S3 Step", "S4 Run", "S4 Read", "S6 Attach", "S5 Self",
		"S1 Run", "S1 Check", "S1 Arm T", "S1 One", "S5 HS Setup", "S5 HS Send", "S1 HS Arm" }
	for _, label in ipairs(order) do
		local b = FAKE_UI.FindButton(label)
		H.notnil(b, "button " .. label)
		b:Click()
		FAKE_UI.Update(env, 1)
	end
	H.ok(#FAKE_UI.requests >= 14, "gameplay requests sent")
	for _, r in ipairs(FAKE_UI.requests) do H.eq(r.params.OnStart, "ABN_Dev") end
	local shown = env.Controls.ResultLabel:GetText()
	H.ok(string.find(shown, "S1 hs_arm", 1, true) ~= nil, "panel shows the gameplay lines")
	H.ok(string.find(shown, "[ABN]", 1, true) == nil, "no raw [tags] in the label")
	H.ok(string.find(env.Controls.InfoLabel:GetText(), "S4=", 1, true) ~= nil, "panel lists the test cities")
	H.ok(H.hasLine("[ABN][SPIKE] S3 UI"), "UI loyalty readings after S3 Step")
	H.ok(H.hasLine("[ABN][SPIKE] S4 UI"), "UI siege readings after S4 Run")
	H.ok(H.hasLine("[ABN][SPIKE] P UI"), "UI probes")
	H.ok(H.hasLine("CityDestroyDirectives LIBERATE_FOUNDER=0"))
	H.eq(env.Controls.ABN_DevBtnStack.parent, FAKE_UI.built["/InGame/CityPanel/ActionStack"], "S6 button re-parented")
	H.eq(env.Controls.ABN_DevBtnStack:IsHidden(), false)
	FAKE_UI.selectedCity = Players[0]:GetCities():GetCapitalCity()
	env.Controls.ABN_DevS6Button:Click()
	H.ok(H.hasLine("button click: selected city id="))
	Events.CitySelectionChanged(0, 1, 0, 0, 0, true, true)
	LuaEvents.CityPanel_LiveCityDataChanged(nil, false)
	H.ok(H.hasLine("CityPanel_LiveCityDataChanged showing=false"))
	-- HS guard: owner 0 and local 0 -> command; local 1 -> skip
	FAKE_UI.canDestroy = true
	FAKE.localPlayer = 1
	Events.PlayerTurnActivated(1, true)
	H.len(FAKE_UI.cityCommands, 0, "no command while another player is local")
	H.ok(H.hasLine("HS skip: local player is not the owner"))
	FAKE.localPlayer = 0
	Events.PlayerTurnActivated(0, true)
	H.len(FAKE_UI.cityCommands, 1, "command on the owner's own turn")
	Events.PlayerTurnActivated(0, false)
	H.len(FAKE_UI.cityCommands, 1, "once per arm")
	Events.CityRemovedFromMap(0, 9)
	H.ok(H.hasLine("Events.CityRemovedFromMap (UI) pid=0 cityID=9"))
	FAKE_UI.KeyTo(env, Keys.VK_ESCAPE, {})
	H.eq(env.Controls.Main:IsHidden(), true, "Esc closes")
	H.clean()
end)

test("panel S1 Run issues the UI raze only when CanStartCommand allows it", function()
	World()
	FAKE_UI.Enable()
	local env = FAKE_UI.LoadContext(PANEL)
	FAKE_UI.FindButton("S0 Setup"):Click()
	FAKE_UI.canDestroy = false
	FAKE_UI.FindButton("S1 Run"):Click()
	H.len(FAKE_UI.cityCommands, 0)
	H.ok(H.hasLine("U RAZE not allowed on S3-B2"))
	FAKE_UI.canDestroy = true
	FAKE_UI.destroyRemoves = true
	FAKE_UI.FindButton("S1 Run"):Click()
	H.len(FAKE_UI.cityCommands, 1)
	H.eq(FAKE_UI.cityCommands[1].params[UnitOperationTypes.PARAM_FLAGS], CityDestroyDirectives.RAZE)
	H.isnil(CityAt("S3-B2"), "U city removed by the (fake) command")
	FAKE_UI.Update(env, 1)
	H.clean()
end)
