-- ===========================================================================
-- ABN_Dev_Panel.lua  (ABN_Dev spike build 0.0.0.1, WP0; SPIKES.md)
-- Context: UI (AddUserInterfaces, Context InGame). TESTING ONLY.
--
-- Ctrl+Shift+D or the launch bar "DEV" button toggles the panel
-- (EFV_Dev_Panel.lua:2290-2322 pattern). One button per spike step; gameplay
-- steps go to Scripts/ABN_Dev_Gameplay.lua as one flat EXECUTE_SCRIPT request
--   { OnStart = "ABN_Dev", cmd = "...", stamp = n }
-- (EFV_Dev_Panel.lua:241-262). UI-only spike parts run here: the UI half of
-- the P probes, the S1 raze command (U) and its hotseat guard, the S3
-- loyalty breakdown, the S4 UI siege/damage reads and the S6 city panel
-- button.
--
-- Results: the panel shows the last gameplay lines (Game property
-- ABN_SpikeLast, written by gameplay) and the last UI lines, re-read on the
-- update tick, so Leon can read the outcome even when Lua.log is lost.
-- The UI writes no game state; the S1 RAZE command is the owner's own city
-- command, issued only for the local player's city.
--
-- AddUserInterfaces contexts load HIDDEN: Initialize calls
-- ContextPtr:SetHide(false); only Controls.Main is toggled.
-- ===========================================================================
include("InstanceManager")

local PREFIX = "[ABN][SPIKE]"
local DEV_VERSION = "0.0.0.1"
local UI_MAX = 10
local POLL_SECONDS = 0.5

local m_ButtonIM = InstanceManager:new("DevButtonInstance", "Button", Controls.ButtonStack)
local m_HeaderIM = InstanceManager:new("DevHeaderInstance", "Header", Controls.ButtonStack)
local m_Open = false
local m_LaunchInst = {}
local m_LaunchDone = false
local m_UILines = {}
local m_StampN = 0
local m_Clock = 0
local m_NextPoll = 0
local m_LastSig = ""
local m_Pending = {}          -- cmd -> true: run the UI half when the gameplay answer arrives
local m_S6Target = nil
local m_S6Where = nil
local m_HSDoneSeq = -1        -- S1 HS: the arm (hsSeq) already issued on this machine

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Str(v)
	if v == nil then return "nil" end
	return tostring(v)
end

local function LocalID()
	return Game.GetLocalPlayer()
end

local function Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok then return Str(t) end
	return "?"
end

-- One UI result line: printed and shown in the panel.
local function UILog(id, text)
	local line = PREFIX .. " " .. id .. " UI T" .. Turn() .. " " .. Str(text)
	print(line)
	m_UILines[#m_UILines + 1] = string.sub(line, 1, 300)
	while #m_UILines > UI_MAX do table.remove(m_UILines, 1) end
end

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

local function Num(v)
	if type(v) ~= "number" then return Str(v) end
	return tostring(math.floor(v * 10 + 0.5) / 10)
end

local function ReadProp(key)
	local ok, v = pcall(function() return Game:GetProperty(key) end)
	if ok then return v end
	return nil
end

local function Records()
	local v = ReadProp("ABN_SpikeCities")
	if type(v) == "table" then return v end
	return {}
end

local function RecByTag(tag)
	for _, r in ipairs(Records()) do
		if r.tag == tag then return r end
	end
	return nil
end

local function CityOf(tag)
	local r = RecByTag(tag)
	if r == nil then return nil end
	local c = CityManager.GetCityAt(r.x, r.y)
	if c == nil or c:GetOwner() ~= r.owner then return nil end
	return c
end

local function CityLabel(c)
	if c == nil then return "nil" end
	return Str(c:GetOwner()) .. "/" .. Str(c:GetID()) .. "@" .. Str(c:GetX()) .. "," .. Str(c:GetY())
end

local function Capital(pid)
	local ok, c = pcall(function() return Players[pid]:GetCities():GetCapitalCity() end)
	if ok then return c end
	return nil
end

-- ---------------------------------------------------------------------------
-- Requests (flat params; EFV_Dev_Panel.lua:241-262)
-- ---------------------------------------------------------------------------
local function Send(cmd)
	m_StampN = m_StampN + 1
	local p = { OnStart = "ABN_Dev", cmd = cmd, stamp = m_StampN }
	local ok, err = pcall(function()
		UI.RequestPlayerOperation(LocalID(), PlayerOperations.EXECUTE_SCRIPT, p)
	end)
	UILog("DEV", "request cmd=" .. cmd .. " stamp=" .. m_StampN .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
end

-- ---------------------------------------------------------------------------
-- UI halves of the spikes
-- ---------------------------------------------------------------------------

-- P: the same probes from the UI (CitySupport.lua:421, WorldRankings.lua:1844, RazeCity.lua:83).
local function ProbeUI(label, c)
	if c == nil then
		UILog("P", label .. " no city")
		return
	end
	local okC, a = M(c, "IsCapital", function() return c:IsCapital() end)
	local okO, b = M(c, "IsOriginalCapital", function() return c:IsOriginalCapital() end)
	local okW, o = M(c, "GetOriginalOwner", function() return c:GetOriginalOwner() end)
	UILog("P", label .. " " .. CityLabel(c) .. " UI IsCapital=" .. Str(a) .. " IsOriginalCapital=" .. Str(b) ..
		" GetOriginalOwner=" .. Str(o) .. " owner=" .. Str(c:GetOwner()))
end

local function NearestAICapital(me)
	local cap = Capital(me)
	if cap == nil then return nil end
	local best, bestD = nil, 9999
	local ids = {}
	pcall(function()
		for _, id in ipairs(PlayerManager.GetAliveIDs()) do ids[#ids + 1] = id end
	end)
	table.sort(ids)
	for _, pid in ipairs(ids) do
		local ok, isAI = pcall(function() return pid ~= me and Players[pid]:IsMajor() and not Players[pid]:IsHuman() end)
		if ok and isAI then
			local c = Capital(pid)
			if c ~= nil then
				local d = Map.GetPlotDistance(cap:GetX(), cap:GetY(), c:GetX(), c:GetY())
				if d < bestD then best, bestD = c, d end
			end
		end
	end
	return best
end

local function ProbesUI()
	local me = LocalID()
	ProbeUI("own_capital", Capital(me))
	ProbeUI("S2", CityOf("S2"))
	ProbeUI("ai_capital", NearestAICapital(me))
end

-- S3: loyalty, per-turn and every non-zero breakdown entry (CityPanelCulture.lua:88-149).
local S3_TAGS = { "S3-C", "S3-A", "S3-B0", "S3-B1", "S3-B2" }
local function LoyaltyUI(why)
	for _, tag in ipairs(S3_TAGS) do
		local c = CityOf(tag)
		if c ~= nil then
			local ci = nil
			pcall(function() ci = c:GetCulturalIdentity() end)
			local _, loy = M(ci, "GetLoyalty", function() return ci:GetLoyalty() end)
			local _, pt = M(ci, "GetLoyaltyPerTurn", function() return ci:GetLoyaltyPerTurn() end)
			local okB, bd = M(ci, "GetIdentitySourcesDetailedBreakdown", function() return ci:GetIdentitySourcesDetailedBreakdown() end)
			local parts = {}
			if okB and type(bd) == "table" then
				for _, inner in ipairs(bd) do
					if type(inner) == "table" then
						local src, val = next(inner)
						if type(val) == "number" and val ~= 0 then parts[#parts + 1] = Str(src) .. "=" .. Num(val) end
					end
				end
			else
				parts[1] = "breakdown " .. Str(bd)
			end
			UILog("S3", tag .. " " .. why .. " loyalty=" .. Num(loy) .. " perTurn=" .. Num(pt) .. " | " .. table.concat(parts, "; "))
		end
	end
end

-- S4: damage and siege from the UI (CitySupport.lua:359-372, 618-620).
local function SiegeUI(why)
	local c = CityOf("S4")
	if c == nil then return end
	local d = nil
	pcall(function() d = Players[c:GetOwner()]:GetDistricts():FindID(c:GetDistrictID()) end)
	local _, g = M(d, "GetDamage", function() return d:GetDamage(DefenseTypes.DISTRICT_GARRISON) end)
	local _, gm = M(d, "GetMaxDamage", function() return d:GetMaxDamage(DefenseTypes.DISTRICT_GARRISON) end)
	local _, o = M(d, "GetDamage", function() return d:GetDamage(DefenseTypes.DISTRICT_OUTER) end)
	local _, s = M(d, "IsUnderSiege", function() return d:IsUnderSiege() end)
	UILog("S4", why .. " " .. CityLabel(c) .. " garrison=" .. Str(g) .. "/" .. Str(gm) .. " outer=" .. Str(o) .. " UI IsUnderSiege=" .. Str(s))
end

-- S1 U: the owner's own RAZE command (RazeCity.lua:46-56; Raze_City_Reminder_Popup.lua:29-37).
local DIRECTIVES = { "LIBERATE_FOUNDER", "LIBERATE_PREVIOUS_OWNER", "KEEP", "RAZE" }

local function DirectiveValue(name)
	local ok, v = pcall(function() return CityDestroyDirectives[name] end)
	if ok then return v end
	return nil
end

local function CanDestroy(c, flags)
	local ok, v = pcall(function()
		local t = {}
		t[UnitOperationTypes.PARAM_FLAGS] = flags
		return CityManager.CanStartCommand(c, CityCommandTypes.DESTROY, t)
	end)
	if ok then return v end
	return "ERR(" .. Str(v) .. ")"
end

local function RequestRaze(c)
	local ok, err = pcall(function()
		local t = {}
		t[UnitOperationTypes.PARAM_FLAGS] = CityDestroyDirectives.RAZE
		UI.DeselectAllCities()
		CityManager.RequestCommand(c, CityCommandTypes.DESTROY, t)
	end)
	return ok, err
end

local function S1RunUI()
	local vals = {}
	for _, n in ipairs(DIRECTIVES) do vals[#vals + 1] = n .. "=" .. Str(DirectiveValue(n)) end
	UILog("S1", "CityDestroyDirectives " .. table.concat(vals, " "))
	local U = CityOf("S3-B2")
	if U == nil then
		UILog("S1", "U city S3-B2 missing")
	else
		local can = {}
		for _, n in ipairs(DIRECTIVES) do can[#can + 1] = n .. "=" .. Str(CanDestroy(U, DirectiveValue(n))) end
		UILog("S1", "U " .. CityLabel(U) .. " CanStartCommand(DESTROY): " .. table.concat(can, " "))
	end
	UILog("S1", "RAZE on capital=" .. Str(CanDestroy(Capital(LocalID()), DirectiveValue("RAZE"))) ..
		" on control S3-C=" .. Str(CanDestroy(CityOf("S3-C"), DirectiveValue("RAZE"))))
	if U ~= nil and CanDestroy(U, DirectiveValue("RAZE")) == true then
		local ok, err = RequestRaze(U)
		UILog("S1", "U RequestCommand(DESTROY, RAZE) on S3-B2 ok=" .. tostring(ok) .. " err=" .. Str(err))
	else
		UILog("S1", "U RAZE not allowed on S3-B2: no command sent")
	end
	Send("s1_run")
end

-- S1 HS guard: fire the stored raze only while the local player is the owner.
local function HotseatGuard(pid)
	local st = ReadProp("ABN_SpikeState")
	if type(st) ~= "table" or st.hsOwner == nil then return end
	local okH, human = pcall(function() return Players[pid]:IsHuman() end)
	if not (okH and human) then return end
	local me = LocalID()
	UILog("S1", "HS PlayerTurnActivated pid=" .. Str(pid) .. " local=" .. Str(me) .. " owner=" .. Str(st.hsOwner) .. " seq=" .. Str(st.hsSeq))
	if me ~= st.hsOwner then
		UILog("S1", "HS skip: local player is not the owner")
		return
	end
	if m_HSDoneSeq == st.hsSeq then return end
	local c = CityManager.GetCityAt(st.hsX, st.hsY)
	if c == nil or c:GetOwner() ~= me then
		UILog("S1", "HS city gone or not ours")
		return
	end
	m_HSDoneSeq = st.hsSeq
	local can = CanDestroy(c, DirectiveValue("RAZE"))
	if can == true then
		local ok, err = RequestRaze(c)
		UILog("S1", "HS RequestCommand(DESTROY, RAZE) local=" .. Str(me) .. " ok=" .. tostring(ok) .. " err=" .. Str(err))
	else
		UILog("S1", "HS RAZE not allowed: CanStartCommand=" .. Str(can))
	end
end

-- S6: test button reparented into the city panel (EFV_UnitActions.lua:94-110 pattern).
local function S6Attach()
	local target, where = nil, nil
	pcall(function() target = ContextPtr:LookUpControl("/InGame/CityPanel/ActionStack") end)
	where = "/InGame/CityPanel/ActionStack"
	if target == nil then
		pcall(function() target = ContextPtr:LookUpControl("/InGame/CityPanel/Banner") end)
		where = "/InGame/CityPanel/Banner (fallback)"
	end
	if target == nil then
		UILog("S6", "LookUpControl nil for ActionStack and Banner: use a floating overlay (R-UI 2.3 D)")
		return
	end
	local ok, err = pcall(function()
		if m_S6Target == nil then Controls.ABN_DevBtnStack:ChangeParent(target) end
		Controls.ABN_DevBtnStack:SetHide(false)
		target:CalculateSize()
		target:ReprocessAnchoring()
	end)
	if ok then
		m_S6Target, m_S6Where = target, where
	end
	UILog("S6", "attach to " .. where .. " ok=" .. tostring(ok) .. " err=" .. Str(err) .. "; open a city now")
end

local function S6Click()
	local c = nil
	pcall(function() c = UI.GetHeadSelectedCity() end)
	local last = ReadProp("ABN_SpikeLast")
	local n = type(last) == "table" and #last or 0
	UILog("S6", "button click: selected city id=" .. (c and Str(c:GetID()) or "nil") .. " owner=" .. (c and Str(c:GetOwner()) or "nil") ..
		" ABN_SpikeLast lines=" .. n .. (n > 0 and (" last=" .. Str(last[n])) or ""))
end

local function S6Refresh(label)
	if m_S6Target == nil then return end
	local ok = pcall(function()
		m_S6Target:CalculateSize()
		m_S6Target:ReprocessAnchoring()
	end)
	UILog("S6", label .. " (refresh ok=" .. tostring(ok) .. ")")
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------
local BUTTONS = {
	{ header = "Part 1 (single player)" },
	{ label = "S0 Setup", cmd = "s0_setup" },
	{ label = "P Probes", cmd = "p_probes", ui = ProbesUI },
	{ label = "S2a To 8", cmd = "s2a" },
	{ label = "S2b Cut", cmd = "s2b" },
	{ label = "S3 Step", cmd = "s3_step", after = function() LoyaltyUI("after_click") end },
	{ label = "S4 Run", cmd = "s4_run", after = function() SiegeUI("after_run") end },
	{ label = "S4 Read", cmd = "s4_read", after = function() SiegeUI("read") end },
	{ label = "S6 Attach", ui = S6Attach },
	{ label = "S5 Self", cmd = "s5_self" },
	{ header = "Part 1, last (risky: city removal)" },
	{ label = "S1 Run", ui = S1RunUI },
	{ label = "S1 Check", cmd = "s1_check" },
	{ label = "S1 Arm T", cmd = "s1_arm_t" },
	{ label = "S1 One", cmd = "s1_one" },
	{ header = "Part 2 (hotseat)" },
	{ label = "S5 HS Setup", cmd = "s5_hs_setup" },
	{ label = "S5 HS Send", cmd = "s5_hs_send" },
	{ label = "S1 HS Arm", cmd = "s1_hs_arm" },
}

local RefreshResults

local function OnButton(def)
	if def.ui ~= nil then
		local ok, err = pcall(def.ui)
		if not ok then UILog("DEV", def.label .. " UI ERROR " .. Str(err)) end
	end
	if def.cmd ~= nil then Send(def.cmd) end
	if def.after ~= nil then m_Pending[#m_Pending + 1] = def end
	RefreshResults()
end

local function BuildButtons()
	m_ButtonIM:ResetInstances()
	m_HeaderIM:ResetInstances()
	for _, def in ipairs(BUTTONS) do
		if def.header ~= nil then
			local h = m_HeaderIM:GetInstance()
			h.HeaderLabel:SetText(def.header)
		else
			local b = m_ButtonIM:GetInstance()
			b.Button:SetText(def.label)
			b.Button:RegisterCallback(Mouse.eLClick, function() OnButton(def) end)
		end
	end
	Controls.ButtonStack:CalculateSize()
end

-- ---------------------------------------------------------------------------
-- Result display
-- ---------------------------------------------------------------------------
local function CitiesText()
	local parts = {}
	for _, r in ipairs(Records()) do
		local c = CityManager.GetCityAt(r.x, r.y)
		local name = "gone"
		if c ~= nil then
			local ok, n = pcall(function() return Locale.Lookup(c:GetName()) end)
			name = ok and Str(n) or "?"
		end
		parts[#parts + 1] = Str(r.tag) .. "=" .. name .. " (" .. Str(r.x) .. "," .. Str(r.y) .. ")"
	end
	if #parts == 0 then return "Test cities: none yet (found your capital, then S0 Setup)" end
	return "Test cities: " .. table.concat(parts, ", ")
end

-- Log line -> label text: drop the [ABN][SPIKE] tag, keep CHECK, and turn the
-- remaining brackets into parentheses (labels treat [X] as markup).
local function Display(s)
	s = Str(s)
	s = string.gsub(s, "^%[ABN%]%[SPIKE%]%s*", "")
	s = string.gsub(s, "^%[ABN%]%[CHECK%]%s*", "CHECK ")
	s = string.gsub(s, "%[", "(")
	s = string.gsub(s, "%]", ")")
	return s
end

RefreshResults = function()
	local last = ReadProp("ABN_SpikeLast")
	local g = {}
	if type(last) == "table" then
		for _, s in ipairs(last) do g[#g + 1] = Display(s) end
	end
	local u = {}
	for _, s in ipairs(m_UILines) do u[#u + 1] = Display(s) end
	Controls.InfoLabel:SetText("Local P" .. Str(LocalID()) .. " | turn " .. Turn() .. " | " .. CitiesText())
	Controls.ResultLabel:SetText("Gameplay (ABN_SpikeLast):[NEWLINE]" .. (#g > 0 and table.concat(g, "[NEWLINE]") or "-"))
	Controls.UILabel:SetText("UI:[NEWLINE]" .. (#u > 0 and table.concat(u, "[NEWLINE]") or "-"))
	pcall(function()
		Controls.ResultStack:CalculateSize()
		Controls.ResultScroll:CalculateInternalSize()
	end)
end

local function Signature()
	local last = ReadProp("ABN_SpikeLast")
	if type(last) ~= "table" then return "none" end
	return #last .. "|" .. Str(last[#last])
end

-- Update tick: re-read ABN_SpikeLast; when it changed, run the pending UI halves.
local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if m_Clock < m_NextPoll then return end
	m_NextPoll = m_Clock + POLL_SECONDS
	local sig = Signature()
	if sig == m_LastSig then return end
	m_LastSig = sig
	local pend = m_Pending
	m_Pending = {}
	for _, def in ipairs(pend) do
		local ok, err = pcall(def.after)
		if not ok then UILog("DEV", def.label .. " UI ERROR " .. Str(err)) end
	end
	if m_Open then RefreshResults() end
end

-- ---------------------------------------------------------------------------
-- Show / hide, hotkey, launch bar (EFV_Dev_Panel.lua:2280-2340)
-- ---------------------------------------------------------------------------
local function SetOpen(open)
	m_Open = open and true or false
	if ContextPtr:IsHidden() then ContextPtr:SetHide(false) end
	if m_Open then RefreshResults() end
	Controls.Main:SetHide(not m_Open)
end

local function Toggle()
	SetOpen(not m_Open)
end

local function OnInput(pInput)
	if pInput:GetMessageType() == KeyEvents.KeyUp then
		local key = pInput:GetKey()
		if key == Keys.D and pInput:IsControlDown() and pInput:IsShiftDown() then
			Toggle()
			return true
		end
		if key == Keys.VK_ESCAPE and m_Open then
			SetOpen(false)
			return true
		end
	end
	return false
end

local function AttachLaunchButton()
	if m_LaunchDone then return end
	m_LaunchDone = true
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		ContextPtr:BuildInstanceForControl("DevLaunchBarItem", m_LaunchInst, buttonStack)
		m_LaunchInst.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
		ContextPtr:BuildInstanceForControl("DevLaunchBarPinInstance", {}, buttonStack)
		buttonStack:CalculateSize()
		local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
		backing:SetSizeX(buttonStack:GetSizeX() + 116)
		local backingTile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
		backingTile:SetSizeX(buttonStack:GetSizeX() - 20)
		LuaEvents.LaunchBar_Resize(buttonStack:GetSizeX())
	end)
	print(PREFIX .. " DEV UI launch bar button ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " (Ctrl+Shift+D works regardless)")
end

-- Always-on UI logger at the local player's turn start (SPIKES 0).
local function OnPlayerTurnActivated(pid, isFirstTime)
	HotseatGuard(pid)
	if pid ~= LocalID() then return end
	local st = ReadProp("ABN_SpikeState")
	if type(st) == "table" and (st.s3Phase or 0) >= 1 then LoyaltyUI("turn_start") end
	if type(st) == "table" and st.s4Watch == 1 then SiegeUI("turn_start") end
	if m_Open then RefreshResults() end
end

local function OnCityRemoved(pid, cityID)
	UILog("S1", "Events.CityRemovedFromMap (UI) pid=" .. Str(pid) .. " cityID=" .. Str(cityID))
end

local function OnCitySelectionChanged(owner, cityID, i, j, k, isSelected, isEditable)
	if m_S6Target ~= nil then
		S6Refresh("CitySelectionChanged owner=" .. Str(owner) .. " city=" .. Str(cityID) .. " selected=" .. Str(isSelected))
	end
end

local function OnLiveCityData(kData, isShowing)
	if m_S6Target ~= nil then S6Refresh("CityPanel_LiveCityDataChanged showing=" .. Str(isShowing)) end
end

local function Subscribe(label, getter, fn)
	local ok, err = pcall(function()
		local ev = getter()
		if ev == nil then error("event is nil") end
		ev.Add(function(...)
			local okH, errH = pcall(fn, ...)
			if not okH then print(PREFIX .. " DEV UI " .. label .. " listener error: " .. Str(errH)) end
		end)
	end)
	if not ok then print(PREFIX .. " DEV UI subscribe FAILED " .. label .. ": " .. Str(err)) end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)       -- contexts load hidden
	Controls.Main:SetHide(true)
	Controls.ABN_DevBtnStack:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
	Controls.RefreshButton:RegisterCallback(Mouse.eLClick, RefreshResults)
	Controls.ABN_DevS6Button:RegisterCallback(Mouse.eLClick, S6Click)
	Controls.TitleLabel:SetText("Abandon City spike tools " .. DEV_VERSION .. "  (Ctrl+Shift+D)")
	ContextPtr:SetUpdate(OnUpdate)
	BuildButtons()
	Subscribe("Events.LoadGameViewStateDone", function() return Events.LoadGameViewStateDone end, AttachLaunchButton)
	Subscribe("Events.PlayerTurnActivated", function() return Events.PlayerTurnActivated end, OnPlayerTurnActivated)
	Subscribe("Events.CityRemovedFromMap", function() return Events.CityRemovedFromMap end, OnCityRemoved)
	Subscribe("Events.CitySelectionChanged", function() return Events.CitySelectionChanged end, OnCitySelectionChanged)
	Subscribe("LuaEvents.CityPanel_LiveCityDataChanged", function() return LuaEvents.CityPanel_LiveCityDataChanged end, OnLiveCityData)
	print(PREFIX .. " DEV UI ready (Ctrl+Shift+D) " .. DEV_VERSION)
end

Initialize()
