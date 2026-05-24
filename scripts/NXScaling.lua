-- NXScaling.lua
-- State, save/load, and MP sync for NX FeedCalculator consumption scaling.
-- Single global multiplier applied to all hooked husbandry inputs and outputs.

NXScaling = NXScaling or {}

NXScaling.MOD_NAME    = g_currentModName or "FS25_NXFeedCalculator"
NXScaling.FILE_NAME   = "nxFeedCalcScaling.xml"
NXScaling.XML_ROOT    = "nxFeedCalcScaling"
NXScaling.XML_KEY     = NXScaling.XML_ROOT .. ".settings"
NXScaling.XML_VERSION = 1

NXScaling.DEFAULT_ENABLED    = false
NXScaling.DEFAULT_MODE       = "vanilla" -- vanilla | auto | manual | hybrid
NXScaling.DEFAULT_MULTIPLIER = 1.0
NXScaling.MIN_MULTIPLIER     = 0.0
NXScaling.MAX_MULTIPLIER     = 100.0

NXScaling.enabled              = NXScaling.DEFAULT_ENABLED
NXScaling.selectedMode         = NXScaling.DEFAULT_MODE
NXScaling.customMultiplier     = NXScaling.DEFAULT_MULTIPLIER
NXScaling.hasUnsavedChanges    = false
NXScaling.clientSyncReceived   = false
NXScaling.clientRequestTimer   = 0
NXScaling.missionHooksInstalled = false
NXScaling.CLIENT_REQUEST_RETRY_MS = 2000

NXScaling.xmlSchema = XMLSchema.new("NXScaling")
NXScaling.xmlSchema:register(XMLValueType.INT,    NXScaling.XML_ROOT .. "#version",          "NX scaling savegame version", NXScaling.XML_VERSION)
NXScaling.xmlSchema:register(XMLValueType.BOOL,   NXScaling.XML_KEY  .. "#enabled",          "Enable scaling",              NXScaling.DEFAULT_ENABLED)
NXScaling.xmlSchema:register(XMLValueType.FLOAT,  NXScaling.XML_KEY  .. "#customMultiplier", "Custom multiplier",           NXScaling.DEFAULT_MULTIPLIER)
NXScaling.xmlSchema:register(XMLValueType.STRING, NXScaling.XML_KEY  .. "#mode",             "Selected mode",               NXScaling.DEFAULT_MODE)

local function getSavegameFilePath()
    if g_currentMission == nil then return nil end
    local dir = nil
    if g_currentMission.missionInfo ~= nil then
        dir = g_currentMission.missionInfo.savegameDirectory
    end
    if (dir == nil or dir == "") and g_currentMission.savegameDirectory ~= nil then
        dir = g_currentMission.savegameDirectory
    end
    if type(dir) ~= "string" or dir == "" then return nil end
    return dir .. "/" .. NXScaling.FILE_NAME
end

local function getDaysPerPeriod()
    if g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod then
        local d = g_currentMission.environment.daysPerPeriod
        if type(d) == "number" and d > 0 then return d end
    end
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.daysPerPeriod then
        local d = g_currentMission.missionInfo.daysPerPeriod
        if type(d) == "number" and d > 0 then return d end
    end
    return 1
end

local function normalizeMode(m)
    if type(m) ~= "string" then return nil end
    m = string.lower(m)
    if m == "vanilla" or m == "auto" or m == "manual" or m == "hybrid" then
        return m
    end
    return nil
end

local function clampMultiplier(v)
    local n = tonumber(v) or NXScaling.DEFAULT_MULTIPLIER
    if n ~= n then n = NXScaling.DEFAULT_MULTIPLIER end
    if n < NXScaling.MIN_MULTIPLIER then n = NXScaling.MIN_MULTIPLIER end
    if n > NXScaling.MAX_MULTIPLIER then n = NXScaling.MAX_MULTIPLIER end
    return n
end

function NXScaling:getCustomMultiplier()
    return clampMultiplier(self.customMultiplier)
end

function NXScaling:getModeName()
    if not self.enabled then return "vanilla" end
    return normalizeMode(self.selectedMode) or "manual"
end

function NXScaling:getScaleFactor()
    if not self.enabled then return 1.0 end
    local mode = self:getModeName()
    if mode == "auto" then
        return getDaysPerPeriod()
    elseif mode == "manual" then
        return self:getCustomMultiplier()
    elseif mode == "hybrid" then
        return getDaysPerPeriod() * self:getCustomMultiplier()
    end
    return 1.0
end

function NXScaling:notifyMenuStateChanged()
    if NXSettingsMenu ~= nil and type(NXSettingsMenu.updateCurrentPage) == "function" then
        NXSettingsMenu:updateCurrentPage()
    end
end

function NXScaling:applyState(enabled, mode, multiplier, markDirty)
    local oldEnabled = self.enabled
    local oldMode    = self:getModeName()
    local oldMult    = self:getCustomMultiplier()

    self.enabled = enabled == true

    local nm = normalizeMode(mode)
    if nm == nil then
        nm = self.enabled and "manual" or "vanilla"
    end
    self.selectedMode = nm
    self.customMultiplier = clampMultiplier(multiplier)

    local changed =
        oldEnabled ~= self.enabled
        or oldMode ~= self:getModeName()
        or math.abs(oldMult - self:getCustomMultiplier()) > 0.0001

    if changed and markDirty then
        self.hasUnsavedChanges = true
    end

    self:notifyMenuStateChanged()
end

function NXScaling:resetToDefaults()
    self.enabled              = self.DEFAULT_ENABLED
    self.selectedMode         = self.DEFAULT_MODE
    self.customMultiplier     = self.DEFAULT_MULTIPLIER
    self.hasUnsavedChanges    = false
    self.clientSyncReceived   = g_server ~= nil
    self.clientRequestTimer   = 0
    self:notifyMenuStateChanged()
end

function NXScaling:getRequestedStateForMode(mode)
    local nm = normalizeMode(mode)
    if nm == nil then return false end

    local enabled = self.enabled
    local mult    = self:getCustomMultiplier()

    if nm == "vanilla" then
        enabled = false
        mult    = 1.0
    elseif nm == "auto" then
        enabled = true
        mult    = 1.0
    elseif nm == "manual" or nm == "hybrid" then
        enabled = true
    end

    return true, enabled, nm, mult
end

function NXScaling:getDebugState()
    return string.format(
        "enabled=%s mode=%s multiplier=%.3f daysPerPeriod=%d factor=%.3f",
        tostring(self.enabled),
        self:getModeName(),
        self:getCustomMultiplier(),
        getDaysPerPeriod(),
        self:getScaleFactor()
    )
end

-- =====================================================
-- MP Events
-- =====================================================
NXScalingStateEvent = {}
local NXScalingStateEvent_mt = Class(NXScalingStateEvent, Event)
InitEventClass(NXScalingStateEvent, "NXScalingStateEvent")

function NXScalingStateEvent.emptyNew()
    return Event.new(NXScalingStateEvent_mt)
end

function NXScalingStateEvent.new(enabled, mode, multiplier)
    local self = NXScalingStateEvent.emptyNew()
    self.enabled    = enabled
    self.mode       = mode
    self.multiplier = multiplier
    return self
end

local function modeToIndex(m)
    local n = normalizeMode(m) or "vanilla"
    if n == "auto"   then return 2 end
    if n == "manual" then return 3 end
    if n == "hybrid" then return 4 end
    return 1
end

local function indexToMode(i)
    local modes = { "vanilla", "auto", "manual", "hybrid" }
    return modes[i] or "vanilla"
end

function NXScalingStateEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.enabled == true)
    streamWriteUIntN(streamId, modeToIndex(self.mode), 3)
    streamWriteFloat32(streamId, self.multiplier or NXScaling.DEFAULT_MULTIPLIER)
end

function NXScalingStateEvent:readStream(streamId, connection)
    self.enabled    = streamReadBool(streamId)
    self.mode       = indexToMode(streamReadUIntN(streamId, 3))
    self.multiplier = streamReadFloat32(streamId)
    self:run(connection)
end

local function connectionCanModify(connection)
    if connection == nil then return g_server ~= nil end
    if type(connection.getIsMasterUser) == "function" then
        local ok, v = pcall(connection.getIsMasterUser, connection)
        if ok and type(v) == "boolean" then return v end
    end
    if connection.isMasterUser ~= nil then return connection.isMasterUser == true end
    if g_currentMission ~= nil and g_currentMission.userManager ~= nil
       and type(g_currentMission.userManager.getUserByConnection) == "function" then
        local ok, user = pcall(g_currentMission.userManager.getUserByConnection, g_currentMission.userManager, connection)
        if ok and type(user) == "table" then
            if type(user.getIsMasterUser) == "function" then
                local ok2, v = pcall(user.getIsMasterUser, user)
                if ok2 and type(v) == "boolean" then return v end
            end
            if user.isMasterUser ~= nil then return user.isMasterUser == true end
        end
    end
    return false
end

function NXScalingStateEvent:run(connection)
    if NXScaling == nil then return end

    if not connection:getIsServer() then
        if connectionCanModify(connection) then
            NXScaling:applyState(self.enabled, self.mode, self.multiplier, true)
            g_server:broadcastEvent(NXScalingStateEvent.new(
                NXScaling.enabled, NXScaling.selectedMode, NXScaling:getCustomMultiplier()
            ), true)
        else
            -- Reject: push current authoritative state back
            if type(connection.sendEvent) == "function" then
                connection:sendEvent(NXScalingStateEvent.new(
                    NXScaling.enabled, NXScaling.selectedMode, NXScaling:getCustomMultiplier()
                ), false)
            end
        end
    else
        NXScaling:applyState(self.enabled, self.mode, self.multiplier, false)
        NXScaling.clientSyncReceived = true
        NXScaling.clientRequestTimer = 0
    end
end

NXScalingRequestEvent = {}
local NXScalingRequestEvent_mt = Class(NXScalingRequestEvent, Event)
InitEventClass(NXScalingRequestEvent, "NXScalingRequestEvent")

function NXScalingRequestEvent.emptyNew()
    return Event.new(NXScalingRequestEvent_mt)
end

function NXScalingRequestEvent.new()
    return NXScalingRequestEvent.emptyNew()
end

function NXScalingRequestEvent:writeStream(streamId, connection) end

function NXScalingRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

function NXScalingRequestEvent:run(connection)
    if g_server ~= nil and NXScaling ~= nil and connection ~= nil and type(connection.sendEvent) == "function" then
        connection:sendEvent(NXScalingStateEvent.new(
            NXScaling.enabled, NXScaling.selectedMode, NXScaling:getCustomMultiplier()
        ), false)
    end
end

function NXScaling:requestStateChange(enabled, mode, multiplier)
    if g_server ~= nil then
        self:applyState(enabled, mode, multiplier, true)
        g_server:broadcastEvent(NXScalingStateEvent.new(
            self.enabled, self.selectedMode, self:getCustomMultiplier()
        ), true)
        return true
    end

    if g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(NXScalingStateEvent.new(enabled, mode, multiplier))
        return true
    end

    self:applyState(enabled, mode, multiplier, true)
    return true
end

-- =====================================================
-- Persistence
-- =====================================================
function NXScaling:loadFromSavegameFile()
    local path = getSavegameFilePath()
    if path == nil then
        self.hasUnsavedChanges = false
        return false
    end

    local xmlFile = nil
    if XMLFile ~= nil and XMLFile.loadIfExists ~= nil then
        xmlFile = XMLFile.loadIfExists("NXScalingXML", path, self.xmlSchema)
    end

    if xmlFile == nil then
        self:applyState(self.DEFAULT_ENABLED, self.DEFAULT_MODE, self.DEFAULT_MULTIPLIER, false)
        self.hasUnsavedChanges = false
        return false
    end

    self:applyState(
        xmlFile:getValue(self.XML_KEY .. "#enabled",          self.DEFAULT_ENABLED),
        xmlFile:getValue(self.XML_KEY .. "#mode",             self.DEFAULT_MODE),
        xmlFile:getValue(self.XML_KEY .. "#customMultiplier", self.DEFAULT_MULTIPLIER),
        false
    )
    self.hasUnsavedChanges = false
    xmlFile:delete()
    return true
end

function NXScaling:saveToSavegameFile()
    local path = getSavegameFilePath()
    if path == nil then return false end

    local xmlFile = nil
    if XMLFile ~= nil and XMLFile.create ~= nil then
        xmlFile = XMLFile.create("NXScalingXML", path, self.XML_ROOT, self.xmlSchema)
    end
    if xmlFile == nil then return false end

    xmlFile:setValue(self.XML_ROOT .. "#version",          self.XML_VERSION)
    xmlFile:setValue(self.XML_KEY  .. "#enabled",          self.enabled)
    xmlFile:setValue(self.XML_KEY  .. "#customMultiplier", self:getCustomMultiplier())
    xmlFile:setValue(self.XML_KEY  .. "#mode",             self:getModeName())
    xmlFile:save()
    xmlFile:delete()

    self.hasUnsavedChanges = false
    return true
end

-- =====================================================
-- Mod event listener (loadMap / update / deleteMap)
-- =====================================================
function NXScaling:installMissionHooks()
    if self.missionHooksInstalled then return end

    if FSBaseMission ~= nil and type(FSBaseMission.loadSettingsFromServer) == "function" then
        FSBaseMission.loadSettingsFromServer = Utils.appendedFunction(FSBaseMission.loadSettingsFromServer, function(baseMission, connection)
            if g_server ~= nil and NXScaling ~= nil and connection ~= nil and type(connection.sendEvent) == "function" then
                connection:sendEvent(NXScalingStateEvent.new(
                    NXScaling.enabled, NXScaling.selectedMode, NXScaling:getCustomMultiplier()
                ), false)
            end
        end)
        self.missionHooksInstalled = true
    end
end

function NXScaling:loadMap()
    self:installMissionHooks()

    if g_server ~= nil then
        self.clientSyncReceived = true
        self.clientRequestTimer = 0
    elseif g_client ~= nil then
        self.clientSyncReceived = false
        self.clientRequestTimer = self.CLIENT_REQUEST_RETRY_MS
    end
end

function NXScaling:update(dt)
    if g_server ~= nil or g_client == nil or self.clientSyncReceived then return end
    self.clientRequestTimer = (self.clientRequestTimer or 0) + (dt or 0)
    if self.clientRequestTimer < self.CLIENT_REQUEST_RETRY_MS then return end
    self.clientRequestTimer = 0
    if g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(NXScalingRequestEvent.new())
    end
end

function NXScaling:deleteMap() end

NXScaling:resetToDefaults()
addModEventListener(NXScaling)
