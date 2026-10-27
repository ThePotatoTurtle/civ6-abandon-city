-- ===========================================================================
-- ABN_CityButton.lua
-- Context:  UI companion context (AddUserInterfaces InGame), PLAN 9.
-- Owner:    WP8. The Abandon City button in the city panel, its tooltip, the
--           confirmation popup and the cancel popup.
-- The UI never writes game state: it sends ABN_Start / ABN_Cancel through
-- ABN_UIShared.Request and gameplay re-validates (PLAN 4).
-- ===========================================================================

include("PopupDialog")
include("ABN_UIShared")

local S = ABN_UIShared

local PANEL_PATH      = "/InGame/CityPanel/ActionStack" -- SPIKES S6
local PANEL_FALLBACK  = "/InGame/CityPanel/Banner"
local POLL_SECONDS    = 3   -- after a click, look for the synced state change this long
local POLL_STEP       = 0.25

local m_Target   = nil
local m_State    = { kind = "HIDE" }
local m_PollLeft = 0
local m_PollTick = 0
local m_Polling  = false

-- ---------------------------------------------------------------------------
-- Attach (retried on every refresh until the city panel exists)
-- ---------------------------------------------------------------------------
local function Attach()
	if m_Target ~= nil then
		return true
	end
	local target = nil
	pcall(function() target = ContextPtr:LookUpControl(PANEL_PATH) end)
	if target == nil then
		pcall(function() target = ContextPtr:LookUpControl(PANEL_FALLBACK) end)
	end
	if target == nil then
		return false
	end
	local ok = pcall(function()
		Controls.ABN_BtnStack:ChangeParent(target)
		target:CalculateSize()
		target:ReprocessAnchoring()
	end)
	if ok then
		m_Target = target
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
local function Relayout()
	if m_Target == nil then return end
	pcall(function()
		m_Target:CalculateSize()
		m_Target:ReprocessAnchoring()
	end)
end

local function Refresh()
	if not Attach() then
		return
	end
	local pCity = UI.GetHeadSelectedCity()
	local state = S.StateFor(pCity, Game.GetLocalPlayer(), Game.GetCurrentGameTurn())
	m_State = state
	m_State.city = pCity

	if state.kind == "HIDE" then
		Controls.ABN_BtnStack:SetHide(true)
		Relayout()
		return
	end

	Controls.ABN_Button:SetToolTipString(state.tooltip)
	if state.kind == "CANCEL" then
		Controls.ABN_Button:SetDisabled(false)
		Controls.ABN_ButtonLabel:SetText(tostring(state.left)) -- turns left
	elseif state.kind == "BLOCKED" then
		Controls.ABN_Button:SetDisabled(true)
		Controls.ABN_ButtonLabel:SetText("X")
	else
		Controls.ABN_Button:SetDisabled(false)
		Controls.ABN_ButtonLabel:SetText("X")
	end
	Controls.ABN_BtnStack:SetHide(false)
	Relayout()
end

local function StartPolling()
	m_PollLeft = POLL_SECONDS
	m_PollTick = 0
	m_Polling = true
	ContextPtr:SetUpdate(function(dt)
		if not m_Polling then
			return
		end
		m_PollLeft = m_PollLeft - dt
		m_PollTick = m_PollTick + dt
		if m_PollTick >= POLL_STEP then
			m_PollTick = 0
			Refresh()
		end
		if m_PollLeft <= 0 then
			m_PollTick = 0
			m_Polling = false
			Refresh()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Popups
-- ---------------------------------------------------------------------------
local function OpenConfirm(pCity, pv)
	local localPlayer = Game.GetLocalPlayer() -- hotseat guard: captured at open
	local cityID, x, y = pCity:GetID(), pCity:GetX(), pCity:GetY()
	local text = S.ConfirmText(pCity, pv)
	local pPopup = PopupDialogInGame:new("ABN_ConfirmAbandon")
	pPopup:AddTitle(text.title)
	pPopup:AddText(text.body)
	pPopup:AddConfirmButton(Locale.Lookup("LOC_ABN_POPUP_CONFIRM"), function()
		if Game.GetLocalPlayer() ~= localPlayer then
			return
		end
		S.RequestStart(cityID, x, y)
		StartPolling()
	end)
	pPopup:AddCancelButton(Locale.Lookup("LOC_ABN_POPUP_CANCEL"), nil)
	pPopup:Open()
end

local function OpenCancel(pCity, rec)
	local localPlayer = Game.GetLocalPlayer()
	local cityID, x, y = pCity:GetID(), pCity:GetX(), pCity:GetY()
	local text = S.CancelText(pCity, rec, Game.GetCurrentGameTurn())
	local pPopup = PopupDialogInGame:new("ABN_ConfirmCancel")
	pPopup:AddTitle(text.title)
	pPopup:AddText(text.body)
	pPopup:AddConfirmButton(Locale.Lookup("LOC_ABN_BUTTON_CANCEL"), function()
		if Game.GetLocalPlayer() ~= localPlayer then
			return
		end
		S.RequestCancel(cityID, x, y)
		StartPolling()
	end)
	pPopup:AddCancelButton(Locale.Lookup("LOC_ABN_CANCEL_KEEP"), nil)
	pPopup:Open()
end

local function OnButtonClick()
	Refresh() -- act on fresh state, not on what was drawn a while ago
	local state = m_State
	local pCity = state.city
	if pCity == nil then
		return
	end
	if state.kind == "START" then
		OpenConfirm(pCity, state.pv)
	elseif state.kind == "CANCEL" then
		OpenCancel(pCity, state.rec)
	end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function OnRefreshEvent()
	Refresh()
end

local function Initialize()
	-- Contexts load hidden; show this one (the button itself lives in the city panel).
	ContextPtr:SetHide(false)
	Controls.ABN_Button:RegisterCallback(Mouse.eLClick, OnButtonClick)

	Events.CitySelectionChanged.Add(OnRefreshEvent)
	LuaEvents.CityPanel_LiveCityDataChanged.Add(OnRefreshEvent)
	Events.PlayerTurnActivated.Add(OnRefreshEvent)
	Events.CityPopulationChanged.Add(OnRefreshEvent)
	Events.CityRemovedFromMap.Add(OnRefreshEvent)
	Events.LoadGameViewStateDone.Add(OnRefreshEvent)
	Attach()
end

Initialize()
