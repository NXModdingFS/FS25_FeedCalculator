-- HerdOptions.lua
-- Adds the mod's controls to Settings > Game.
--
-- The controls are described as data and built by one loop. Where possible an
-- existing option box on the page is cloned, so the controls inherit whatever
-- styling the current game build uses; if no template can be found they are
-- assembled from GUI profiles instead.

NXHerdMeter = NXHerdMeter or {}

local Tuning  = NXHerdMeter.Tuning
local text    = NXHerdMeter.Readout.phrase
local Options = {}
NXHerdMeter.Options = Options

Options.bound   = false
Options.pages   = {}
Options.silent  = false

-- ------------------------------------------------------------
--  Control descriptors
-- ------------------------------------------------------------

local function toggleTexts()
    return { text("nxhm_toggle_off", "Off"), text("nxhm_toggle_on", "On") }
end

local function trimTexts()
    local labels = {}
    for index, value in ipairs(Tuning.TRIM_RAMP) do
        labels[index] = string.format("%.2fx", value)
    end
    return labels
end

Options.CONTROLS = {
    {
        key      = "season",
        field    = "nxhmSeasonOption",
        callback = "onSeasonScaleChanged",
        title    = function() return text("nxhm_opt_season", "Scale feed use to month length") end,
        help     = function()
            return text("nxhm_opt_season_help",
                "Multiplies husbandry throughput by the number of days in an in-game month, so a longer month costs proportionally more feed.")
        end,
        texts    = toggleTexts,
        state    = function() return Tuning:isSeasonScaled() and 2 or 1 end,
        commit   = function(state) Tuning:submit(state == 2, Tuning:getTrim()) end,
    },
    {
        key      = "trim",
        field    = "nxhmTrimOption",
        callback = "onTrimChanged",
        title    = function() return text("nxhm_opt_trim", "Feed use multiplier") end,
        help     = function()
            return text("nxhm_opt_trim_help",
                "A straight multiplier on husbandry feed, water, bedding and produce. Applies on top of month length scaling.")
        end,
        texts    = trimTexts,
        state    = function() return Tuning.nearestRampIndex(Tuning:getTrim()) end,
        commit   = function(state)
            local value = Tuning.TRIM_RAMP[state]
            if value ~= nil then Tuning:submit(Tuning:isSeasonScaled(), value) end
        end,
    },
}

-- ------------------------------------------------------------
--  Permissions
-- ------------------------------------------------------------

-- Throughput is simulated on the host, so only the host or an admin may retune.
local function playerMayEdit(frame)
    if g_server ~= nil then return true end

    if frame ~= nil and frame.hasMasterRights ~= nil then
        return frame.hasMasterRights == true
    end

    local mission = g_currentMission
    if mission ~= nil then
        if type(mission.getIsClientMasterUser) == "function" then
            local ok, value = pcall(mission.getIsClientMasterUser, mission)
            if ok and type(value) == "boolean" then return value end
        end
        if mission.isClientMasterUser ~= nil then return mission.isClientMasterUser == true end
    end

    return false
end

-- ------------------------------------------------------------
--  Element construction
-- ------------------------------------------------------------

local function looksLikeOption(element)
    return type(element) == "table"
        and type(element.setTexts) == "function"
        and type(element.setState) == "function"
end

-- Clone an option box that already exists on the page. A box carrying several
-- values is preferred: a two state checkbox styles the multiplier ramp badly.
local function findTemplate(layout)
    if type(layout) ~= "table" or type(layout.elements) ~= "table" then return nil end

    local fallback = nil

    for _, container in ipairs(layout.elements) do
        if type(container) == "table" and type(container.elements) == "table"
           and type(container.clone) == "function" then

            local option = container.elements[1]
            if looksLikeOption(option) then
                if type(option.texts) == "table" and #option.texts > 2 then
                    return container
                end
                fallback = fallback or container
            end
        end
    end

    return fallback
end

-- The caption sits alongside the option; the tooltip lives inside it.
local function findCaption(container)
    if type(container.elements) ~= "table" then return nil end

    for index = 2, #container.elements do
        local element = container.elements[index]
        if type(element) == "table" and type(element.setText) == "function" and element.name ~= "ignore" then
            return element
        end
    end

    return nil
end

local function findTooltip(option)
    if type(option) ~= "table" or type(option.elements) ~= "table" then return nil end

    for _, element in ipairs(option.elements) do
        if type(element) == "table" and type(element.setText) == "function" then
            return element
        end
    end

    return nil
end

local function reserveFocus(element)
    if type(element) ~= "table" then return end
    if FocusManager ~= nil and type(FocusManager.serveAutoFocusId) == "function" then
        element.focusId = FocusManager:serveAutoFocusId()
    end
    if type(element.elements) == "table" then
        for _, child in pairs(element.elements) do reserveFocus(child) end
    end
end

local function buildFromTemplate(frame, template, descriptor)
    local container = template:clone(frame.gameSettingsLayout)
    if container == nil then return nil end

    container.id = "nxhmBox_" .. descriptor.key

    local option = container.elements[1]
    if not looksLikeOption(option) then return nil end

    option.id     = "nxhmOption_" .. descriptor.key
    option.target = Options
    option:setCallback("onClickCallback", descriptor.callback)

    local caption = findCaption(container)
    if caption ~= nil then caption:setText(descriptor.title()) end

    local tooltip = findTooltip(option)
    if tooltip ~= nil then tooltip:setText(descriptor.help()) end

    reserveFocus(container)
    if type(frame.controlsList) == "table" then
        table.insert(frame.controlsList, container)
    end

    return option
end

-- Used when the page has no clonable option, for instance if a UI overhaul
-- mod replaced the settings layout wholesale.
local function buildFromProfiles(frame, descriptor)
    if g_gui == nil or type(g_gui.getProfile) ~= "function" then return nil end

    local container = BitmapElement.new()
    container:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    local option = MultiTextOptionElement.new()
    option:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOption"), true)
    option.target = Options
    option:setCallback("onClickCallback", descriptor.callback)

    local caption = TextElement.new()
    caption:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    caption:setText(descriptor.title())

    local tooltip = TextElement.new()
    tooltip.name = "ignore"
    tooltip:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltip:setText(descriptor.help())

    option:addElement(tooltip)
    container:addElement(option)
    container:addElement(caption)

    option:onGuiSetupFinished()
    caption:onGuiSetupFinished()
    tooltip:onGuiSetupFinished()

    frame.gameSettingsLayout:addElement(container)
    container:onGuiSetupFinished()

    reserveFocus(container)
    if type(frame.controlsList) == "table" then
        table.insert(frame.controlsList, container)
    end

    return option
end

local function addHeading(frame)
    if g_gui == nil or type(g_gui.getProfile) ~= "function" then return end

    local heading = TextElement.new()
    heading.name = "sectionHeader"
    heading:loadProfile(g_gui:getProfile("fs25_settingsSectionHeader"), true)
    heading:setText(text("nxhm_opt_section", "NX FeedCalculator"))
    frame.gameSettingsLayout:addElement(heading)
    heading:onGuiSetupFinished()
end

-- ------------------------------------------------------------
--  Page lifecycle
-- ------------------------------------------------------------

function Options:attach(frame)
    if type(frame) ~= "table" or type(frame.gameSettingsLayout) ~= "table" then return end

    if not frame.nxhmAttached then
        addHeading(frame)

        local template = findTemplate(frame.gameSettingsLayout)

        for _, descriptor in ipairs(self.CONTROLS) do
            local option = nil
            if template ~= nil then
                option = buildFromTemplate(frame, template, descriptor)
            end
            if option == nil then
                option = buildFromProfiles(frame, descriptor)
            end
            frame[descriptor.field] = option
        end

        frame.gameSettingsLayout:invalidateLayout()
        if type(frame.updateAlternatingElements) == "function" then
            frame:updateAlternatingElements(frame.gameSettingsLayout)
        end

        frame.nxhmAttached = true
        table.insert(self.pages, frame)
    end

    self:refresh(frame)
end

function Options:refresh(frame)
    if type(frame) ~= "table" or not frame.nxhmAttached then return end

    local mayEdit = playerMayEdit(frame)

    self.silent = true
    for _, descriptor in ipairs(self.CONTROLS) do
        local option = frame[descriptor.field]
        if option ~= nil then
            option:setTexts(descriptor.texts())
            option:setState(descriptor.state())
            option:setDisabled(not mayEdit)
        end
    end
    self.silent = false

    frame.gameSettingsLayout:invalidateLayout()
    if type(frame.updateAlternatingElements) == "function" then
        frame:updateAlternatingElements(frame.gameSettingsLayout)
    end
end

-- Called when the state changes underneath an open menu, for example when the
-- server pushes new values to a client.
function Options:refreshOpenPage()
    for _, frame in ipairs(self.pages) do
        pcall(self.refresh, self, frame)
    end
end

-- ------------------------------------------------------------
--  Callbacks
-- ------------------------------------------------------------

local function commit(key, state)
    if Options.silent then return end

    for _, descriptor in ipairs(Options.CONTROLS) do
        if descriptor.key == key then
            descriptor.commit(state)
            break
        end
    end

    Options:refreshOpenPage()
end

function Options:onSeasonScaleChanged(state)
    commit("season", state)
end

function Options:onTrimChanged(state)
    commit("trim", state)
end

-- ------------------------------------------------------------
--  Install
-- ------------------------------------------------------------

function Options:install()
    if self.bound then return end
    if InGameMenuSettingsFrame == nil then return end

    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuSettingsFrame.onFrameOpen,
        function(frame) pcall(Options.attach, Options, frame) end)

    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
        InGameMenuSettingsFrame.updateGameSettings,
        function(frame) pcall(Options.refresh, Options, frame) end)

    self.bound = true
end

Options:install()
