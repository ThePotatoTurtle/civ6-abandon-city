-- ===========================================================================
-- ABN_Dev_Panel.lua  (ABN_Dev 0.1.0.0, WP9; PLAN 12)
-- Context: UI (AddUserInterfaces, Context InGame). TESTING ONLY.
--
-- Ctrl+Shift+D or the launch bar "DEV" button toggles the panel
-- (EFV_Dev_Panel.lua:2290-2322 pattern). Buttons send one flat request
--   { OnStart = "ABN_Dev", cmd = "...", stamp = n, [cityID, x, y of the open city] }
-- (EFV_Dev_Panel.lua:241-262) to Scripts/ABN_Dev_Gameplay.lua. The checked
-- START and CANCEL buttons run a short sequence, one step per update tick:
--   START : ABN_Dev arm_start -> the real ABN_Start request -> ABN_Dev check
--   CANCEL: ABN_Dev arm_cancel -> the real ABN_Cancel request -> ABN_Dev check
-- so the mod is driven through exactly the requests its own button sends,
-- and the dev tools record the click-time facts around them.
--
-- The target of every command is the city open in the city panel (when it is
-- yours), else the focus city, else the capital.
--
-- Results: the panel shows the latest gameplay lines (Game property
-- ABN_DevLast, written by gameplay) and the UI lines, re-read on the update
-- tick. The UI half of "Probe blockers" compares ABN_Rules.FirstBlocker run
-- in this context with the gameplay answer. The UI writes no game state.
--
-- AddUserInterfaces contexts load HIDDEN: Initialize calls
-- ContextPtr:SetHide(false); only Controls.Main is toggled.
-- ===========================================================================
include("InstanceManager")
include("ABN_Config")
include("ABN_Rules")

-- ABN:GLOBALS ABN_Config ABN_Rules
local PREFIX = "[ABN][DEV]"
local DEV_VERSION = "0.1.0.0"
local UI_MAX = 8
local POLL_SECONDS = 0.4
local HOLD_TICKS = 2            -- ticks to wait after a real ABN_* request
local ACK_TIMEOUT_TICKS = 12    -- ticks to wait for the gameplay answer

local KEY_STATE = "ABN_DevState"
local KEY_TALLY = "ABN_DevTally"
local KEY_LAST = "ABN_DevLast"
local KEY_CITIES = "ABN_DevCities"
local KEY_PROBE = "ABN_DevProbe"
local KEY_STAMP = "ABN_DevStamp"

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
local m_UISeq = 0
local m_Pending = {}        -- {stamp, fn, label}: UI halves that wait for the gameplay answer
local m_Queue = {}          -- steps of a running sequence
local m_WaitStamp = nil
local m_WaitTicks = 0
local m_Hold = 0

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

-- A UI-side check line (the summarizer reads it like the gameplay ones).
local function UICheck(id, status, text)
	m_UISeq = m_UISeq + 1
	local line = "[ABN][CHECK] " .. id .. "_T" .. Turn() .. "_u" .. m_UISeq .. " " .. status .. " T" .. Turn() .. " " .. Str(text)
	print(line)
	m_UILines[#m_UILines + 1] = string.sub(line, 1, 300)
	while #m_UILines > UI_MAX do table.remove(m_UILines, 1) end
end

local function ReadProp(key)
	local ok, v = pcall(function() return Game:GetProperty(key) end)
	if ok then return v end
	return nil
end

local function Capital(pid)
	local ok, c = pcall(function() return Players[pid]:GetCities():GetCapitalCity() end)
	if ok then return c end
	return nil
end

-- The city open in the city panel, when it is the local player's.
local function SelectedCity()
	local ok, c = pcall(function() return UI.GetHeadSelectedCity() end)
	if ok and c ~= nil and c:GetOwner() == LocalID() then return c end
	return nil
end

-- The focus city set by the gameplay side (registry tag in ABN_DevState.focus).
local function FocusCity()
	local me = LocalID()
	local st = ReadProp(KEY_STATE)
	local tag = type(st) == "table" and st.focus or nil
	if type(tag) == "string" and tag ~= "CAP" then
		local reg = ReadProp(KEY_CITIES)
		if type(reg) == "table" then
			for _, r in ipairs(reg) do
				if r.tag == tag then
					local c = CityManager.GetCityAt(r.x, r.y)
					if c ~= nil and c:GetOwner() == r.owner and c:GetID() == r.id then return c, tag end
				end
			end
		end
	end
	return Capital(me), "CAP"
end

-- Same order as the gameplay side: open city, focus city, capital.
local function TargetCity()
	local c = SelectedCity()
	if c ~= nil then return c end
	return (FocusCity())
end

-- ---------------------------------------------------------------------------
-- Requests (flat params; EFV_Dev_Panel.lua:241-262)
-- ---------------------------------------------------------------------------
local function SendRaw(p)
	local ok, err = pcall(function()
		UI.RequestPlayerOperation(LocalID(), PlayerOperations.EXECUTE_SCRIPT, p)
	end)
	return ok, err
end

-- A dev command. Returns its stamp.
local function Send(cmd, args)
	m_StampN = m_StampN + 1
	local p = { OnStart = "ABN_Dev", cmd = cmd, stamp = m_StampN }
	local sel = SelectedCity()
	if sel ~= nil then
		p.cityID = sel:GetID()
		p.x = sel:GetX()
		p.y = sel:GetY()
	end
	if args ~= nil then
		for _, k in ipairs({ "pop", "dist", "kind", "amount", "on" }) do
			if args[k] ~= nil then p[k] = args[k] end
		end
	end
	local ok, err = SendRaw(p)
	UILog("DEV", "request cmd=" .. cmd .. " stamp=" .. m_StampN .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	return m_StampN
end

-- The real mod request (PLAN 4): ABN_Start / ABN_Cancel with cityID, x, y of the target.
local function SendABN(name)
	local c = TargetCity()
	if c == nil then
		UILog("DEV", name .. ": no target city")
		return false
	end
	local ok, err = SendRaw({ OnStart = name, cityID = c:GetID(), x = c:GetX(), y = c:GetY() })
	UILog("DEV", "request " .. name .. " city=" .. c:GetID() .. "@" .. c:GetX() .. "," .. c:GetY() .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	return ok
end

-- ---------------------------------------------------------------------------
-- Sequence runner: one step per call, waiting for the gameplay answer
-- ---------------------------------------------------------------------------
local function AckStamp()
	return tonumber(ReadProp(KEY_STAMP)) or 0
end

local function RunStep(step)
	if step.gp ~= nil then
		m_WaitStamp = Send(step.gp, step.args)
		m_WaitTicks = 0
	elseif step.abn ~= nil then
		SendABN(step.abn)
		m_Hold = HOLD_TICKS
	end
end

local function Pump(fromTick)
	if m_Hold > 0 then
		if fromTick then m_Hold = m_Hold - 1 end
		return
	end
	if m_WaitStamp ~= nil then
		if AckStamp() >= m_WaitStamp then
			m_WaitStamp = nil
		else
			if fromTick then
				m_WaitTicks = m_WaitTicks + 1
				if m_WaitTicks > ACK_TIMEOUT_TICKS then
					UILog("DEV", "no gameplay answer for stamp " .. m_WaitStamp .. ": continuing")
					m_WaitStamp = nil
				end
			end
			return
		end
	end
	if #m_Queue == 0 then return end
	local step = table.remove(m_Queue, 1)
	RunStep(step)
end

-- ---------------------------------------------------------------------------
-- UI halves
-- ---------------------------------------------------------------------------

-- Probe blockers: the same city, ABN_Rules.FirstBlocker run in the UI context against
-- the gameplay answer. SIEGE (UI only) stands for DAMAGED or ENEMY_NEAR in gameplay.
local function ProbeCompareUI()
	local pr = ReadProp(KEY_PROBE)
	if type(pr) ~= "table" then
		UILog("DEV", "no gameplay probe result yet")
		return
	end
	local c = CityManager.GetCityAt(pr.x, pr.y)
	if c == nil then
		UILog("DEV", "probe city is gone")
		return
	end
	local ok, ui = pcall(ABN_Rules.FirstBlocker, c, LocalID(), tonumber(Turn()) or 0)
	local uiS = ui or "NONE"
	local gS = pr.got or "NONE"
	local detail = "city " .. c:GetID() .. "@" .. c:GetX() .. "," .. c:GetY() .. " UI=" .. Str(uiS) .. " gameplay=" .. Str(gS)
	if not ok then
		UICheck("UIBLOCK", "FAIL", "ABN_Rules.FirstBlocker raised in the UI: " .. Str(ui))
	elseif uiS == gS then
		UICheck("UIBLOCK", "PASS", detail)
	elseif uiS == "SIEGE" and (gS == "DAMAGED" or gS == "ENEMY_NEAR") then
		UICheck("UIBLOCK", "PASS", detail .. " (siege is UI-only, DECISIONS #24)")
	else
		UICheck("UIBLOCK", "FAIL", detail)
	end
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------
local BUTTONS = {
	{ header = "Test cities (found your capital first; a new city becomes the focus)" },
	{ label = "City pop 1", cmd = "make_city", args = { pop = 1 } },
	{ label = "City pop 4", cmd = "make_city", args = { pop = 4 } },
	{ label = "City pop 5", cmd = "make_city", args = { pop = 5 } },
	{ label = "City pop 8", cmd = "make_city", args = { pop = 8 } },
	{ label = "City pop 9", cmd = "make_city", args = { pop = 9 } },
	{ label = "City pop 10", cmd = "make_city", args = { pop = 10 } },
	{ label = "City pop 15", cmd = "make_city", args = { pop = 15 } },
	{ label = "City pop 20", cmd = "make_city", args = { pop = 20 } },
	{ label = "Nbrs at 7 + 10", cmd = "nbrs_7_10" },
	{ label = "Nbrs at R, R+1", cmd = "nbrs_r" },
	{ label = "Overlap set", cmd = "overlap" },
	{ label = "Focus next", cmd = "focus_next" },
	{ label = "Focus open city", cmd = "focus_sel" },
	{ header = "Diplomacy and enemies (they act on the open city, else the focus)" },
	{ label = "Meet all majors", cmd = "meet_all" },
	{ label = "Meet next human", cmd = "meet_human" },
	{ label = "War nearest AI", cmd = "war_ai" },
	{ label = "Besiege city", cmd = "besiege" },
	{ label = "Enemy 6 (AI war)", cmd = "enemy", args = { dist = 6, kind = "ai" } },
	{ label = "Enemy 7 (AI war)", cmd = "enemy", args = { dist = 7, kind = "ai" } },
	{ label = "Enemy 6 (barb 63)", cmd = "enemy", args = { dist = 6, kind = "barb" } },
	{ label = "Enemy 7 (barb 63)", cmd = "enemy", args = { dist = 7, kind = "barb" } },
	{ label = "Enemy 6 (free 62)", cmd = "enemy", args = { dist = 6, kind = "free" } },
	{ label = "Enemy 7 (free 62)", cmd = "enemy", args = { dist = 7, kind = "free" } },
	{ header = "Damage, the last-city and original-capital cases (these destroy cities)" },
	{ label = "Damage garrison", cmd = "damage", args = { kind = "g", amount = 30 } },
	{ label = "Damage walls", cmd = "damage", args = { kind = "o", amount = 30 } },
	{ label = "Heal city", cmd = "heal" },
	{ label = "LAST CITY (kills rest)", cmd = "last_city" },
	{ label = "ORIG CAPITAL (razes cap)", cmd = "orig_capital" },
	{ header = "Abandonment (sends the real ABN_Start / ABN_Cancel)" },
	{ label = "START (checked)", steps = { { gp = "arm_start" }, { abn = "ABN_Start" }, { gp = "check" } } },
	{ label = "CANCEL (checked)", steps = { { gp = "arm_cancel" }, { abn = "ABN_Cancel" }, { gp = "check" } } },
	{ label = "Plan (timeline)", cmd = "plan" },
	{ label = "Probe blockers", cmd = "probe", after = ProbeCompareUI },
	{ label = "Check now", cmd = "check" },
	{ label = "Dump state", cmd = "dump" },
	{ label = "Turn checker on/off", cmd = "checker" },
	{ label = "Reset dev ledger", cmd = "reset" },
}

local RefreshResults

local function OnButton(def)
	if def.ui ~= nil then
		local ok, err = pcall(def.ui)
		if not ok then UILog("DEV", def.label .. " UI ERROR " .. Str(err)) end
	end
	if def.steps ~= nil then
		m_Queue = {}
		for _, s in ipairs(def.steps) do m_Queue[#m_Queue + 1] = s end
		m_Hold = 0
		m_WaitStamp = nil
		Pump(false)
	elseif def.cmd ~= nil then
		local stamp = Send(def.cmd, def.args)
		if def.after ~= nil then
			m_Pending[#m_Pending + 1] = { stamp = stamp, fn = def.after, label = def.label }
		end
	end
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
local function InfoText()
	local st = ReadProp(KEY_STATE)
	local ty = ReadProp(KEY_TALLY)
	local checker = "ON"
	if type(st) == "table" and st.checker == 0 then checker = "OFF" end
	local pass, fail, last = 0, 0, "-"
	if type(ty) == "table" then
		pass = tonumber(ty.pass) or 0
		fail = tonumber(ty.fail) or 0
		if type(ty.lastFail) == "string" and fail > 0 then last = ty.lastFail end
	end
	local focus, tag = FocusCity()
	local sel = SelectedCity()
	local focusText = "none"
	if focus ~= nil then focusText = tag .. " pop " .. Str(focus:GetPopulation()) end
	local target = ""
	if sel ~= nil then target = " | open city pop " .. Str(sel:GetPopulation()) .. " is the target" end
	local verdict = fail > 0 and ("  <<< " .. fail .. " FAIL, last " .. last) or ""
	return "Local P" .. Str(LocalID()) .. " | turn " .. Turn() .. " | focus " .. focusText .. target ..
		" | checker " .. checker .. " | checks PASS " .. pass .. " FAIL " .. fail .. verdict
end

-- Log line -> label text: drop the [ABN][DEV] tag, keep CHECK, and turn the
-- remaining brackets into parentheses (labels treat [X] as markup).
local function Display(s)
	s = Str(s)
	s = string.gsub(s, "^%[ABN%]%[DEV%]%s*", "")
	s = string.gsub(s, "^%[ABN%]%[CHECK%]%s*", "CHECK ")
	s = string.gsub(s, "%[", "(")
	s = string.gsub(s, "%]", ")")
	return s
end

RefreshResults = function()
	local last = ReadProp(KEY_LAST)
	local g = {}
	if type(last) == "table" then
		for _, s in ipairs(last) do g[#g + 1] = Display(s) end
	end
	local u = {}
	for _, s in ipairs(m_UILines) do u[#u + 1] = Display(s) end
	Controls.InfoLabel:SetText(InfoText())
	Controls.ResultLabel:SetText("Gameplay (non-PASS lines and info, newest last):[NEWLINE]" .. (#g > 0 and table.concat(g, "[NEWLINE]") or "-"))
	Controls.UILabel:SetText("UI:[NEWLINE]" .. (#u > 0 and table.concat(u, "[NEWLINE]") or "-"))
	pcall(function()
		Controls.ResultStack:CalculateSize()
		Controls.ResultScroll:CalculateInternalSize()
	end)
end

local function Signature()
	local last = ReadProp(KEY_LAST)
	local n = type(last) == "table" and #last or 0
	local ty = ReadProp(KEY_TALLY)
	local t = type(ty) == "table" and (Str(ty.pass) .. "/" .. Str(ty.fail)) or "-"
	return n .. "|" .. (n > 0 and Str(last[n]) or "") .. "|" .. t .. "|" .. Str(ReadProp(KEY_STAMP))
end

-- Update tick: run the UI halves whose gameplay answer arrived, pump the sequence,
-- refresh the display when the gameplay lines changed.
local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if m_Clock < m_NextPoll then return end
	m_NextPoll = m_Clock + POLL_SECONDS
	local ack = AckStamp()
	local pend = m_Pending
	m_Pending = {}
	for _, p in ipairs(pend) do
		if p.stamp <= ack then
			local ok, err = pcall(p.fn)
			if not ok then UILog("DEV", p.label .. " UI ERROR " .. Str(err)) end
		else
			m_Pending[#m_Pending + 1] = p
		end
	end
	Pump(true)
	local sig = Signature()
	if sig ~= m_LastSig then
		m_LastSig = sig
		if m_Open then RefreshResults() end
	end
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
	print(PREFIX .. " UI launch bar button ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " (Ctrl+Shift+D works regardless)")
end

local function OnPlayerTurnActivated(pid, isFirstTime)
	if pid ~= LocalID() then return end
	if m_Open then RefreshResults() end
end

local function OnCitySelectionChanged(owner, cityID, i, j, k, isSelected, isEditable)
	if m_Open then RefreshResults() end
end

local function Subscribe(label, getter, fn)
	local ok, err = pcall(function()
		local ev = getter()
		if ev == nil then error("event is nil") end
		ev.Add(function(...)
			local okH, errH = pcall(fn, ...)
			if not okH then print(PREFIX .. " UI " .. label .. " listener error: " .. Str(errH)) end
		end)
	end)
	if not ok then print(PREFIX .. " UI subscribe FAILED " .. label .. ": " .. Str(err)) end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)       -- contexts load hidden
	Controls.Main:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
	Controls.RefreshButton:RegisterCallback(Mouse.eLClick, RefreshResults)
	Controls.TitleLabel:SetText("Abandon Cities dev tools " .. DEV_VERSION .. "  (Ctrl+Shift+D)")
	m_StampN = AckStamp()           -- never behind the gameplay side's last answer (loaded games)
	ContextPtr:SetUpdate(OnUpdate)
	BuildButtons()
	Subscribe("Events.LoadGameViewStateDone", function() return Events.LoadGameViewStateDone end, AttachLaunchButton)
	Subscribe("Events.PlayerTurnActivated", function() return Events.PlayerTurnActivated end, OnPlayerTurnActivated)
	Subscribe("Events.CitySelectionChanged", function() return Events.CitySelectionChanged end, OnCitySelectionChanged)
	print(PREFIX .. " UI ready (Ctrl+Shift+D) " .. DEV_VERSION)
end

Initialize()
