-- NXSettingsMenu.lua
-- Adds an "NX FeedCalculator" section to the in-game game-settings page.

NXSettingsMenu = NXSettingsMenu or {}

NXSettingsMenu.modeValues       = { "vanilla", "auto", "manual", "hybrid" }
NXSettingsMenu.multiplierValues = { 0.25, 0.50, 0.75, 1.00, 1.25, 1.50, 1.75, 2.00, 2.50, 3.00, 4.00, 5.00, 10.00 }
NXSettingsMenu.uiHookInstalled  = NXSettingsMenu.uiHookInstalled == true
NXSettingsMenu.isUpdatingUi     = false

local function tr(key, fallback)
    if g_i18n ~= nil and type(g_i18n.getText) == "function" then
        local ok, v = pcall(g_i18n.getText, g_i18n, key)
        if ok and type(v) == "string" and v ~= "" and v ~= key then
            return v
        end
    end
    return fallback
end

local function getModeTexts()
    return {
        tr("nxfc_mode_vanilla", "Vanilla"),
        tr("nxfc_mode_auto",    "Auto"),
        tr("nxfc_mode_manual",  "Manual"),
        tr("nxfc_mode_hybrid",  "Hybrid"),
    }
end

local function getMultiplierTexts()
    local t = {}
    for _, v in ipairs(NXSettingsMenu.multiplierValues) do
        table.insert(t, string.format("%.2fx", v))
    end
    return t
end

local function findNearestMultiplierState(value)
    local bestIdx, bestDelta = 1, math.huge
    local val = tonumber(value) or 1.0
    for i, c in ipairs(NXSettingsMenu.multiplierValues) do
        local d = math.abs(c - val)
        if d < bestDelta then
            bestDelta = d
            bestIdx   = i
        end
    end
    return bestIdx
end

local function canLocalUserModify(frame)
    if g_server ~= nil then return true end
    if frame ~= nil and frame.hasMasterRights ~= nil then
        return frame.hasMasterRights == true
    end
    if g_currentMission ~= nil then
        if type(g_currentMission.getIsClientMasterUser) == "function" then
            local ok, v = pcall(g_currentMission.getIsClientMasterUser, g_currentMission)
            if ok and type(v) == "boolean" then return v end
        end
        if g_currentMission.isClientMasterUser ~= nil then
            return g_currentMission.isClientMasterUser == true
        end
    end
    return true
end

function NXSettingsMenu:addSectionHeader(frame)
    local te = TextElement.new()
    te.name = "sectionHeader"
    te:loadProfile(g_gui:getProfile("fs25_settingsSectionHeader"), true)
    te:setText(tr("nxfc_settings_section", "NX FeedCalculator"))
    frame.gameSettingsLayout:addElement(te)
    te:onGuiSetupFinished()
end

function NXSettingsMenu:addMultiTextOption(frame, callback, texts, title, tooltip)
    local container = BitmapElement.new()
    container:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    local option = MultiTextOptionElement.new()
    option:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOption"), true)
    option.target = self
    option:setCallback("onClickCallback", callback)
    option:setTexts(texts)

    local titleEl = TextElement.new()
    titleEl:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    titleEl:setText(title)

    local tooltipEl = TextElement.new()
    tooltipEl.name = "ignore"
    tooltipEl:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltipEl:setText(tooltip)

    option:addElement(tooltipEl)
    container:addElement(option)
    container:addElement(titleEl)

    option:onGuiSetupFinished()
    titleEl:onGuiSetupFinished()
    tooltipEl:onGuiSetupFinished()

    frame.gameSettingsLayout:addElement(container)
    container:onGuiSetupFinished()

    return option, container
end

function NXSettingsMenu:onFrameOpen()
    if not self.nxfc_initDone then
        NXSettingsMenu:addSectionHeader(self)

        self.nxfcModeOpt, self.nxfcModeBox = NXSettingsMenu:addMultiTextOption(
            self,
            "onNXModeChanged",
            getModeTexts(),
            tr("nxfc_settings_mode_title", "Consumption Scaling"),
            tr("nxfc_settings_mode_desc",  "How NX scales husbandry inputs (food/water/straw) and outputs (milk/manure/pallets).")
        )

        self.nxfcMultOpt, self.nxfcMultBox = NXSettingsMenu:addMultiTextOption(
            self,
            "onNXMultiplierChanged",
            getMultiplierTexts(),
            tr("nxfc_settings_mult_title", "Multiplier"),
            tr("nxfc_settings_mult_desc",  "Extra multiplier applied in Manual or Hybrid mode.")
        )

        self.gameSettingsLayout:invalidateLayout()
        self:updateAlternatingElements(self.gameSettingsLayout)
        self.nxfc_initDone = true
    end

    NXSettingsMenu:refresh(self)
end

function NXSettingsMenu:updateGameSettings()
    NXSettingsMenu:refresh(self)
end

function NXSettingsMenu:updateCurrentPage()
    if g_gui == nil or g_gui.currentGui == nil then return end
    local gui = g_gui.currentGui
    if gui.target == nil or gui.target.currentPage == nil then return end
    local page = gui.target.currentPage
    if page.nxfc_initDone then
        NXSettingsMenu:refresh(page)
    end
end

function NXSettingsMenu:refresh(page)
    if page == nil or not page.nxfc_initDone or NXScaling == nil then return end

    local mode = NXScaling:getModeName()
    local modeState = 1
    for i, m in ipairs(NXSettingsMenu.modeValues) do
        if m == mode then
            modeState = i
            break
        end
    end

    NXSettingsMenu.isUpdatingUi = true
    if page.nxfcModeOpt ~= nil then
        page.nxfcModeOpt:setState(modeState)
    end
    if page.nxfcMultOpt ~= nil then
        page.nxfcMultOpt:setState(findNearestMultiplierState(NXScaling:getCustomMultiplier()))
    end
    NXSettingsMenu.isUpdatingUi = false

    local canModify         = canLocalUserModify(page)
    local multiplierRelevant = mode == "manual" or mode == "hybrid"

    if page.nxfcModeOpt ~= nil then
        page.nxfcModeOpt:setDisabled(not canModify)
    end
    if page.nxfcMultOpt ~= nil then
        page.nxfcMultOpt:setDisabled((not canModify) or (not multiplierRelevant))
    end

    page.gameSettingsLayout:invalidateLayout()
    page:updateAlternatingElements(page.gameSettingsLayout)
end

function NXSettingsMenu:onNXModeChanged(state)
    if NXSettingsMenu.isUpdatingUi or NXScaling == nil then return end
    local mode = NXSettingsMenu.modeValues[state]
    if mode == nil then return end

    local ok, enabled, m, mult = NXScaling:getRequestedStateForMode(mode)
    if not ok then return end

    NXScaling:requestStateChange(enabled, m, mult)
    NXSettingsMenu:updateCurrentPage()
end

function NXSettingsMenu:onNXMultiplierChanged(state)
    if NXSettingsMenu.isUpdatingUi or NXScaling == nil then return end
    local mult = NXSettingsMenu.multiplierValues[state]
    if mult == nil then return end

    local mode = NXScaling:getModeName()
    if mode == "vanilla" then
        mode = "manual"
    elseif mode == "auto" then
        mode = "hybrid"
    end

    NXScaling:requestStateChange(true, mode, mult)
    NXSettingsMenu:updateCurrentPage()
end

local function init()
    if NXSettingsMenu.uiHookInstalled then return end
    if InGameMenuSettingsFrame ~= nil then
        InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
            InGameMenuSettingsFrame.updateGameSettings, NXSettingsMenu.updateGameSettings)
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen, NXSettingsMenu.onFrameOpen)
        NXSettingsMenu.uiHookInstalled = true
    end
end

init()
