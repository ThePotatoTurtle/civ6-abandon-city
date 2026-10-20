-- ===========================================================================
-- fake_ui.lua  (offline harness) - minimal UI-context layer for panel tests:
-- ContextPtr, Controls (auto-created controls), InstanceManager,
-- PopupDialogInGame, UIManager, input events and UI.RequestPlayerOperation.
-- Load after fake_engine.lua (the runner does) and call FAKE_UI.Enable(); it
-- defines the global UI, so code that tests `UI == nil` sees the UI context.
--
-- Requests: UI.RequestPlayerOperation(pid, PlayerOperations.EXECUTE_SCRIPT,
-- params) is recorded in FAKE_UI.requests and routed to
-- GameEvents[params.OnStart](pid, params) as the gameplay context (UI == nil,
-- FAKE.context == "G"), the way the engine delivers it on every machine.
-- Delivery is immediate unless FAKE_UI.deferRequests = true; then the
-- requests wait in FAKE_UI.pending until FAKE_UI.DeliverRequests().
--
-- FAKE_UI.LoadContext(rel) runs one AddUserInterfaces context file in its own
-- environment (own Controls and ContextPtr, like separate engine contexts);
-- FAKE_UI.AsGameplay(fn) runs fn with UI == nil and FAKE.context == "G".
-- ===========================================================================

FAKE_UI = { requests = {}, pending = {}, deferRequests = false, inputHandler = nil, built = {}, ims = {}, popups = {} }

local Control = {}
Control.__index = Control
local function NewControl(name)
	return setmetatable({ name = name, hidden = false, text = "", callbacks = {}, sizeX = 100 }, Control)
end
function Control:SetText(t) self.text = t end
function Control:GetText() return self.text end
function Control:SetHide(h) self.hidden = h and true or false end
function Control:IsHidden() return self.hidden end
function Control:RegisterCallback(ev, fn) self.callbacks[ev] = fn end
function Control:Click() local f = self.callbacks[Mouse.eLClick]; if f then f() end end
function Control:RClick() local f = self.callbacks[Mouse.eRClick]; if f then f() end end
function Control:Hover() local f = self.callbacks[Mouse.eMouseEnter]; if f then f() end end
function Control:CalculateSize() end
function Control:CalculateInternalSize() end
function Control:ReprocessAnchoring() end
function Control:SetSizeX(x) self.sizeX = x end
function Control:GetSizeX() return self.sizeX end
function Control:SetToolTipString(s) self.tooltip = s end
function Control:SetDisabled(d) self.disabled = d end
function Control:IsDisabled() return self.disabled == true end
function Control:LocalizeAndSetText(k, ...) self.text = Locale.Lookup(k, ...) end
function Control:SetAlpha(a) self.alpha = a end
function Control:SetIcon(i) self.icon = i end
function Control:SetColor(c) self.color = c end
function Control:ChangeParent(p) self.parent = p end
function Control:AddChildAtIndex(c, i) self.firstChild = c end
function Control:DoAutoSize() self.autoSized = (self.autoSized or 0) + 1 end

local function NewControls()
	return setmetatable({}, {
		__index = function(t, k) local c = NewControl(k); rawset(t, k, c); return c end,
	})
end

local function NewContextPtr(name)
	return {
		name = name,
		hidden = true,   -- AddUserInterfaces contexts load hidden
		SetHide = function(self, h) self.hidden = h and true or false end,
		IsHidden = function(self) return self.hidden end,
		SetInputHandler = function(self, fn) self.inputHandler = fn; FAKE_UI.inputHandler = fn end,
		SetRefreshHandler = function(self, fn) self.refreshHandler = fn end,
		RequestRefresh = function(self) self.refreshRequested = true end,
		ClearRequestRefresh = function(self) self.refreshRequested = false end,
		LookUpControl = function(self, path) FAKE_UI.built[path] = FAKE_UI.built[path] or NewControl(path); return FAKE_UI.built[path] end,
		-- Every control of the built instance exists (auto-created on access);
		-- FAKE_UI.builtInstances records { name, inst, parent } in build order.
		BuildInstanceForControl = function(self, name, inst, parent)
			setmetatable(inst, { __index = function(t, k) local c = NewControl(name .. "." .. k); rawset(t, k, c); return c end })
			FAKE_UI.builtInstances = FAKE_UI.builtInstances or {}
			FAKE_UI.builtInstances[#FAKE_UI.builtInstances + 1] = { name = name, inst = inst, parent = parent }
		end,
		-- Per-frame update handler (ContextPtr:SetUpdate); FAKE_UI.Update(env, dt) runs it.
		SetUpdate = function(self, fn) self.updateHandler = fn end,
		ClearUpdate = function(self) self.updateHandler = nil end,
	}
end

-- Routes one recorded request to its gameplay handler.
local function Deliver(req)
	if req.op ~= PlayerOperations.EXECUTE_SCRIPT or type(req.params) ~= "table" or req.params.OnStart == nil then
		return
	end
	req.delivered = true
	FAKE_UI.AsGameplay(function()
		GameEvents[req.params.OnStart](req.pid, FAKE.DeepCopy(req.params))
	end)
end

function FAKE_UI.DeliverRequests()
	local list = FAKE_UI.pending
	FAKE_UI.pending = {}
	for _, req in ipairs(list) do
		Deliver(req)
	end
	return #list
end

function FAKE_UI.Enable()
	FAKE.context = "UI"
	Mouse = { eLClick = 1, eRClick = 2, eMouseEnter = 3 }
	KeyEvents = { KeyUp = 1, KeyDown = 2 }
	Keys = setmetatable({ VK_ESCAPE = 27 }, { __index = function(_, k) return "KEY_" .. tostring(k) end })
	PopupPriority = { Low = 0, Medium = 1, High = 2 }
	Controls = NewControls()
	ContextPtr = NewContextPtr("global")
	FAKE_UI.queued = {}
	FAKE_UI.dequeued = {}
	UIManager = {
		QueuePopup = function(self, ctx) FAKE_UI.queued[ctx] = true end,
		DequeuePopup = function(self, ctx)
			FAKE_UI.queued[ctx] = nil
			FAKE_UI.dequeued[#FAKE_UI.dequeued + 1] = ctx
			return true
		end,
		IsInPopupQueue = function(self, ctx) return FAKE_UI.queued[ctx] == true end,
	}
	-- PopupDialog.lua: records every opened dialog in FAKE_UI.popups.
	FAKE_UI.popups = {}
	PopupDialogInGame = {}
	PopupDialogInGame.__index = PopupDialogInGame
	function PopupDialogInGame:new(id) return setmetatable({ id = id, texts = {}, buttons = {} }, PopupDialogInGame) end
	function PopupDialogInGame:AddTitle(t) self.title = t end
	function PopupDialogInGame:AddText(t) self.texts[#self.texts + 1] = t end
	function PopupDialogInGame:AddConfirmButton(label, fn) self.confirm = fn end
	function PopupDialogInGame:AddCancelButton(label, fn) self.cancel = fn end
	function PopupDialogInGame:AddCustomButton(label, fn) self.buttons[#self.buttons + 1] = { label = label, fn = fn } end
	function PopupDialogInGame:Open() FAKE_UI.popups[#FAKE_UI.popups + 1] = self end
	InstanceManager = {}
	function InstanceManager:new(instName, rootName, parent)
		local im = { instName = instName, rootName = rootName, list = {} }
		function im:GetInstance()
			local inst = setmetatable({}, { __index = function(t, k) local c = NewControl(k); rawset(t, k, c); return c end })
			self.list[#self.list + 1] = inst
			return inst
		end
		function im:ResetInstances() self.list = {} end
		function im:DestroyInstances() self.list = {} end
		FAKE_UI.ims[#FAKE_UI.ims + 1] = im
		return im
	end
	UI = {
		RequestPlayerOperation = function(pid, op, params)
			local req = { pid = pid, op = op, params = FAKE.DeepCopy(params), turn = FAKE.turn }
			FAKE_UI.requests[#FAKE_UI.requests + 1] = req
			if FAKE_UI.deferRequests then
				FAKE_UI.pending[#FAKE_UI.pending + 1] = req
			else
				Deliver(req)
			end
		end,
		PlaySound = function(s) FAKE_UI.sounds = FAKE_UI.sounds or {}; FAKE_UI.sounds[#FAKE_UI.sounds + 1] = s end,
	}
	FAKE.localPlayer = FAKE.localPlayer or 0
end

-- Key press through the active input handler. mods: { ctrl = bool, shift = bool }
function FAKE_UI.Key(key, mods)
	mods = mods or {}
	local input = {
		GetMessageType = function() return KeyEvents.KeyUp end,
		GetKey = function() return key end,
		IsControlDown = function() return mods.ctrl == true end,
		IsShiftDown = function() return mods.shift == true end,
		IsAltDown = function() return false end,
	}
	if FAKE_UI.inputHandler == nil then return false end
	return FAKE_UI.inputHandler(input)
end

-- A "Button" control built by any InstanceManager whose text equals label.
function FAKE_UI.FindButton(label)
	for _, im in ipairs(FAKE_UI.ims) do
		for _, inst in ipairs(im.list) do
			if rawget(inst, "Button") ~= nil and inst.Button.text == label then return inst.Button end
		end
	end
	return nil
end

-- Runs an AddUserInterfaces context file (e.g. "ABN/UI/ABN_Panel.lua") in its
-- own environment with its own Controls and ContextPtr. Globals it defines stay
-- in that environment; include()d modules are shared through _G like
-- ImportFiles modules. Returns the environment.
function FAKE_UI.LoadContext(rel)
	local env = setmetatable({ Controls = NewControls(), ContextPtr = NewContextPtr(rel) }, { __index = _G })
	local src = __py_read(rel)
	if src == nil then error("FAKE_UI.LoadContext: missing " .. rel) end
	local fn, err = loadstring(src, "@" .. rel)
	if fn == nil then error(err) end
	setfenv(fn, env)
	fn()
	return env
end

-- Runs the context's refresh handler if a refresh was requested (one frame).
function FAKE_UI.Frame(env)
	local c = env.ContextPtr
	if c.refreshRequested and c.refreshHandler ~= nil then
		c.refreshHandler()
	end
end

-- Runs the context's update handler (ContextPtr:SetUpdate) with dt seconds.
function FAKE_UI.Update(env, dt)
	local fn = env.ContextPtr.updateHandler
	if fn ~= nil then fn(dt or 1) end
	return fn ~= nil
end

-- Key press through one context's input handler.
function FAKE_UI.KeyTo(env, key, mods)
	local saved = FAKE_UI.inputHandler
	FAKE_UI.inputHandler = env.ContextPtr.inputHandler
	local r = FAKE_UI.Key(key, mods)
	FAKE_UI.inputHandler = saved
	return r
end

-- Runs fn as the gameplay context (UI == nil), then restores the UI context.
function FAKE_UI.AsGameplay(fn, ...)
	local ui, ctx = UI, FAKE.context
	UI = nil
	FAKE.context = "G"
	local ok, err = pcall(fn, ...)
	UI = ui
	FAKE.context = ctx
	if not ok then error(err, 2) end
end
