-- Reopens Blizzard bags after anything other than you closes them.
-- Post-hooks only. Replacing CloseAllBags/CloseAllWindows taints Escape and
-- blocks HideUIPanel in combat.

local ADDON = ...

local db
local pendingUser = false   -- a bag toggle ran; record result next frame
local batch                 -- bag hides seen since last Process
local scheduled = false
local retrying = false
local reconciling = false
local bagFrames = {}

local PANEL_KEYS = { "left", "center", "right", "doublewide", "fullscreen" }
local TITLE = "Espi Keep Bags Open"
local LABEL = "Keep bags open"

local function KeyringID()
	if KEYRING_CONTAINER and C_ActionBar and C_ActionBar.ShouldShowKeyring and C_ActionBar.ShouldShowKeyring() then
		return KEYRING_CONTAINER
	end
end

local MAX_BAG = NUM_TOTAL_BAG_FRAMES or NUM_BAG_FRAMES

-- Same order as OpenAllBags so frames land where Blizzard puts them.
local function TrackedIDs()
	local ids = {}
	for id = BACKPACK_CONTAINER, MAX_BAG do
		ids[#ids + 1] = id
	end
	local key = KeyringID()
	if key then
		ids[#ids + 1] = key
	end
	return ids
end

local function Snapshot()
	local open = {}
	for _, id in ipairs(TrackedIDs()) do
		if IsBagOpen(id) then
			open[#open + 1] = id
		end
	end
	return open
end

local function Allowed()
	return not ContainerFrame_AllowedToOpenBags or ContainerFrame_AllowedToOpenBags()
end

local GetNumSlots = ContainerFrame_GetContainerNumSlots
	or (C_Container and C_Container.GetContainerNumSlots)
	or GetContainerNumSlots

local function HasSlots(id)
	return (GetNumSlots(id) or 0) > 0
end

-- Walks TrackedIDs so the tracked-bag rule and open order live in one place.
-- Returns nil when nothing is missing, the usual case on every bag update.
local function Missing()
	local list
	for _, id in ipairs(TrackedIDs()) do
		if tContains(db.want, id) and HasSlots(id) and not IsBagOpen(id) then
			list = list or {}
			list[#list + 1] = id
		end
	end
	return list
end

local Reconcile

local function RetryFire()
	retrying = false
	Reconcile()
end

local function Retry()
	if retrying then return end
	retrying = true
	C_Timer.After(0.5, RetryFire)
end

local function OpenList(list)
	for _, id in ipairs(list) do
		OpenBag(id)
	end
end

function Reconcile()
	-- A toggle you just made hasn't been recorded yet; Process will run us.
	if not db.enabled or pendingUser then return end
	local list = Missing()
	if not list then return end
	-- Center panels, hidden UI, cinematics: wait until bags are allowed again.
	if not Allowed() then
		Retry()
		return
	end
	reconciling = true
	xpcall(OpenList, geterrorhandler(), list)
	reconciling = false
end

-- Toggles are no-ops while blocked; don't let those wipe the saved state.
local function SaveState()
	if Allowed() then
		db.want = Snapshot()
	end
end

local function Process()
	scheduled = false
	if pendingUser then
		pendingUser = false
		SaveState()
	end
	batch = nil
	Reconcile()
end

local function Schedule()
	if scheduled then return end
	scheduled = true
	C_Timer.After(0, Process)
end

-- Deferred: OpenBackpack calls ToggleBackpack internally, so the outermost
-- hook (last to run) decides whether this was you or the game.
local function MarkUser()
	pendingUser = true
	Schedule()
end

local function ClearUser()
	pendingUser = false
end

-- Forbidden frames error when touched from addon code; skip them.
local function ShownOther(f)
	return type(f) == "table" and not bagFrames[f]
		and not (f.IsForbidden and f:IsForbidden())
		and f.IsShown and f:IsShown()
end

-- Windows Escape could close alongside the bags.
local function CollectOthers()
	local shown = {}
	if GetUIPanel then
		for _, key in ipairs(PANEL_KEYS) do
			local f = GetUIPanel(key)
			if ShownOther(f) then shown[#shown + 1] = f end
		end
	end
	if UISpecialFrames then
		for _, name in pairs(UISpecialFrames) do
			local f = _G[name]
			if ShownOther(f) then shown[#shown + 1] = f end
		end
	end
	return shown
end

-- First hide in a batch runs inside CloseAllBags, before CloseWindows,
-- so other windows are still up here.
local function OnBagHide()
	if reconciling then return end
	if not batch then
		batch = { others = CollectOthers() }
	end
	Schedule()
end

-- Escape: if it also closed another window, put bags back now (no flicker).
-- If bags were the only thing it closed, that's you closing them. Reopening
-- in that case would eat every Escape press.
local function OnGameMenuToggle()
	if not batch or batch.esc then return end
	batch.esc = true
	for _, f in ipairs(batch.others) do
		if not f:IsShown() then
			Reconcile()
			return
		end
	end
	SaveState()
end

-- Hooks can't be removed, so the enabled check lives here once instead of in
-- every handler.
local function WhenEnabled(fn)
	return function(...)
		if db.enabled then fn(...) end
	end
end

local function HookAll()
	local onHide, onUser = WhenEnabled(OnBagHide), WhenEnabled(MarkUser)
	local function Hook(f)
		if not f or bagFrames[f] then return end
		bagFrames[f] = true
		f:HookScript("OnHide", onHide)
		local close = f.CloseButton or _G[(f:GetName() or "") .. "CloseButton"]
		if close then
			close:HookScript("OnClick", onUser)
		end
	end
	if ContainerFrameContainer and ContainerFrameContainer.ContainerFrames then
		for _, f in ipairs(ContainerFrameContainer.ContainerFrames) do
			Hook(f)
		end
	end
	Hook(ContainerFrameCombinedBags)
	-- Clients without ContainerFrameContainer only have the numbered globals.
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		Hook(_G["ContainerFrame" .. i])
	end

	for _, name in ipairs({ "ToggleAllBags", "ToggleBackpack", "ToggleBag" }) do
		if _G[name] then hooksecurefunc(name, onUser) end
	end
	for _, name in ipairs({ "OpenBackpack", "OpenAllBags" }) do
		if _G[name] then hooksecurefunc(name, ClearUser) end
	end
	if ToggleGameMenu then
		hooksecurefunc("ToggleGameMenu", WhenEnabled(OnGameMenuToggle))
	end
end

local function Print(msg)
	print("|cff33ff99KeepBagsOpen|r: " .. msg)
end

local function PrintStatus(on)
	if on then
		local n = #db.want
		Print(("on, keeping %d bag%s open."):format(n, n == 1 and "" or "s"))
	else
		Print("off.")
	end
end

-- Runs when the enabled flag changes, from any source.
local function Apply(on)
	-- Whatever is open when you turn it on is what it keeps open. If nothing
	-- is (Escape closed them on the way to Settings), keep the saved set.
	if on then
		local open = Allowed() and Snapshot()
		if open and #open > 0 then
			db.want = open
		elseif #db.want == 0 then
			Print("on. No bags are open; open the ones you want kept.")
			return
		end
	end
	PrintStatus(on)
end

local function SetEnabled(on)
	db.enabled = on and true or false
	Apply(db.enabled)
end

local settingsCategory, settingsPanel

local function SetupSettings()
	local tip = "Reopen bags when the game closes them. Bags you close yourself stay closed."
	if Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting
		and Settings.CreateCheckbox and Settings.VarType then
		local ok = pcall(function()
			local category = Settings.RegisterVerticalLayoutCategory(TITLE)
			local setting = Settings.RegisterAddOnSetting(category, "KEEPBAGSOPEN_ENABLED", "enabled",
				db, Settings.VarType.Boolean, LABEL, true)
			setting:SetValueChangedCallback(function(_, value) Apply(value) end)
			Settings.CreateCheckbox(category, setting, tip)
			Settings.RegisterAddOnCategory(category)
			settingsCategory = category
		end)
		if ok then return end
	end
	if InterfaceOptions_AddCategory and CreateFrame then
		local panel = CreateFrame("Frame")
		panel.name = TITLE
		local check = CreateFrame("CheckButton", "KeepBagsOpenCheck", panel, "InterfaceOptionsCheckButtonTemplate")
		check:SetPoint("TOPLEFT", 16, -16)
		_G[check:GetName() .. "Text"]:SetText(LABEL)
		check.tooltipText = tip
		check:SetScript("OnClick", function(self) SetEnabled(self:GetChecked()) end)
		panel:SetScript("OnShow", function() check:SetChecked(db.enabled) end)
		InterfaceOptions_AddCategory(panel)
		settingsPanel = panel
	end
end

local function OpenSettings()
	if settingsCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(settingsCategory:GetID())
	elseif settingsPanel and InterfaceOptionsFrame_OpenToCategory then
		-- Known quirk: the first call can land on the wrong page.
		InterfaceOptionsFrame_OpenToCategory(settingsPanel)
		InterfaceOptionsFrame_OpenToCategory(settingsPanel)
	else
		Print("no settings panel available on this client; use /kbo on|off.")
	end
end

-- Retail addon compartment (TOC: AddonCompartmentFunc*).
function KeepBagsOpen_OnCompartmentClick()
	if db then SetEnabled(not db.enabled) end
end

function KeepBagsOpen_OnCompartmentEnter(_, button)
	if not db then return end
	GameTooltip:SetOwner(button, "ANCHOR_LEFT")
	GameTooltip:AddLine(TITLE)
	GameTooltip:AddLine(db.enabled and "|cff00ff00On|r" or "|cffff4040Off|r", 1, 1, 1)
	GameTooltip:AddLine("Click to toggle.", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

function KeepBagsOpen_OnCompartmentLeave()
	GameTooltip:Hide()
end

-- Everything but ADDON_LOADED is registered after db exists, so nothing
-- else needs to nil-check it.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		self:UnregisterEvent("ADDON_LOADED")
		KeepBagsOpenDB = KeepBagsOpenDB or {}
		db = KeepBagsOpenDB
		if db.enabled == nil then db.enabled = true end
		db.want = db.want or {}
		HookAll()
		SetupSettings()
		self:RegisterEvent("LOADING_SCREEN_DISABLED")
		self:RegisterEvent("BAG_UPDATE_DELAYED")
	else
		-- After a loading screen, and whenever bag sizes change: sizes read 0
		-- right after login, and a swapped-out bag reads 0 until the new one
		-- is in.
		Reconcile()
	end
end)

SLASH_KEEPBAGSOPEN1 = "/keepbags"
SLASH_KEEPBAGSOPEN2 = "/kbo"
SlashCmdList.KEEPBAGSOPEN = function(msg)
	if not db then return end
	msg = strtrim(msg or ""):lower()
	if msg == "" then
		SetEnabled(not db.enabled)
	elseif msg == "on" then
		SetEnabled(true)
	elseif msg == "off" then
		SetEnabled(false)
	elseif msg == "status" then
		PrintStatus(db.enabled)
	elseif msg == "config" or msg == "options" then
		OpenSettings()
	else
		Print("commands:")
		print("  /kbo - toggle")
		print("  /kbo on | off - set explicitly (on keeps the bags open right now)")
		print("  /kbo status - show state")
		print("  /kbo config - open settings")
	end
end
