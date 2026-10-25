-- HerdTuning.lua
-- Owns the feed intensity settings, their persistence and their replication.
--
-- Two independent controls rather than a mode list:
--   seasonScaled  - fold the length of an in-game month into the rate
--   trim          - a straight multiplier on top
-- The product of the two is the only number the rest of the mod consumes.

NXHerdMeter = NXHerdMeter or {}

local Tuning = {}
NXHerdMeter.Tuning = Tuning

Tuning.STORE_FILE   = "NXHerdMeter.xml"
Tuning.ROOT         = "nxHerdMeter"
Tuning.NODE         = "nxHerdMeter.demand"
Tuning.REVISION     = 1
Tuning.LEGACY_FILE  = "nxFeedCalcScaling.xml"

Tuning.TRIM_FLOOR   = 0.05
Tuning.TRIM_CEILING = 25.0
Tuning.NEUTRAL_TRIM = 1.0

Tuning.POLL_INTERVAL_MS = 2500

-- Trim steps are generated so the ramp stays even: fine control around the
-- neutral point, progressively coarser as it climbs.
local function buildTrimRamp()
    local ramp, seen = {}, {}

    local function push(hundredths)
        if seen[hundredths] then return end
        seen[hundredths] = true
        ramp[#ramp + 1] = hundredths / 100
    end

    local bands = {
        { from = 10,  to = 90,   step = 10  },
        { from = 95,  to = 150,  step = 5   },
        { from = 175, to = 300,  step = 25  },
        { from = 350, to = 600,  step = 50  },
        { from = 700, to = 1200, step = 100 },
    }

    for _, band in ipairs(bands) do
        for value = band.from, band.to, band.step do
            push(value)
        end
    end

    return ramp
end

Tuning.TRIM_RAMP = buildTrimRamp()

-- Live state.
Tuning.seasonScaled = false
Tuning.trim         = Tuning.NEUTRAL_TRIM
Tuning.synced       = true
Tuning.pollTimer    = 0
Tuning.hooksBound   = false

-- ------------------------------------------------------------
--  Helpers
-- ------------------------------------------------------------

local function clampTrim(value)
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric then return Tuning.NEUTRAL_TRIM end
    if numeric < Tuning.TRIM_FLOOR then return Tuning.TRIM_FLOOR end
    if numeric > Tuning.TRIM_CEILING then return Tuning.TRIM_CEILING end
    return numeric
end

function Tuning.nearestRampIndex(value)
    local target = clampTrim(value)
    local bestIndex, bestGap = 1, math.huge
    for index, candidate in ipairs(Tuning.TRIM_RAMP) do
        local gap = math.abs(candidate - target)
        if gap < bestGap then
            bestGap = gap
            bestIndex = index
        end
    end
    return bestIndex
end

function Tuning:getTrim()
    return clampTrim(self.trim)
end

function Tuning:isSeasonScaled()
    return self.seasonScaled == true
end

-- The single number every other module asks for.
function Tuning:intensity()
    local factor = self:getTrim()
    if self:isSeasonScaled() then
        factor = factor * NXHerdMeter.Demand.monthLengthInDays()
    end
    return factor
end

-- True when the settings leave vanilla behaviour untouched.
function Tuning:isNeutral()
    return math.abs(self:intensity() - 1.0) <= 0.0001
end

function Tuning:describe()
    return string.format("seasonScaled=%s trim=%.2f monthDays=%d intensity=%.3f",
        tostring(self:isSeasonScaled()),
        self:getTrim(),
        NXHerdMeter.Demand.monthLengthInDays(),
        self:intensity())
end

-- ------------------------------------------------------------
--  State transitions
-- ------------------------------------------------------------

local function notifyUi()
    local options = NXHerdMeter.Options
    if options ~= nil and type(options.refreshOpenPage) == "function" then
        options:refreshOpenPage()
    end
end

function Tuning:adopt(seasonScaled, trim)
    self.seasonScaled = seasonScaled == true
    self.trim = clampTrim(trim)

    -- Every cached figure was derived from the old factor.
    if type(NXHerdMeter.resurveyAll) == "function" then
        NXHerdMeter.resurveyAll()
    end

    notifyUi()
end

function Tuning:restoreDefaults()
    self.seasonScaled = false
    self.trim         = Tuning.NEUTRAL_TRIM
    self.synced       = true
    self.pollTimer    = 0
    notifyUi()
end

-- Route a change through whoever is allowed to make it. On a client this
-- becomes a request; the server is the only writer.
function Tuning:submit(seasonScaled, trim)
    if g_server ~= nil then
        self:adopt(seasonScaled, trim)
        g_server:broadcastEvent(NXHerdTuningEvent.newState(self.seasonScaled, self:getTrim()), true)
        return
    end

    local connection = g_client ~= nil and g_client:getServerConnection() or nil
    if connection ~= nil then
        connection:sendEvent(NXHerdTuningEvent.newState(seasonScaled == true, clampTrim(trim)))
        return
    end

    self:adopt(seasonScaled, trim)
end

-- ------------------------------------------------------------
--  Replication
-- ------------------------------------------------------------
-- One event class carries both directions. A poll has no payload and simply
-- asks the server to push the authoritative values back.

NXHerdTuningEvent = {}
local tuningEventMeta = Class(NXHerdTuningEvent, Event)
InitEventClass(NXHerdTuningEvent, "NXHerdTuningEvent")

function NXHerdTuningEvent.emptyNew()
    return Event.new(tuningEventMeta)
end

function NXHerdTuningEvent.newPoll()
    local event = NXHerdTuningEvent.emptyNew()
    event.isPoll = true
    return event
end

function NXHerdTuningEvent.newState(seasonScaled, trim)
    local event = NXHerdTuningEvent.emptyNew()
    event.isPoll       = false
    event.seasonScaled = seasonScaled == true
    event.trim         = trim
    return event
end

function NXHerdTuningEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isPoll == true)
    if self.isPoll then return end
    streamWriteBool(streamId, self.seasonScaled == true)
    streamWriteFloat32(streamId, self.trim or Tuning.NEUTRAL_TRIM)
end

function NXHerdTuningEvent:readStream(streamId, connection)
    self.isPoll = streamReadBool(streamId)
    if not self.isPoll then
        self.seasonScaled = streamReadBool(streamId)
        self.trim         = streamReadFloat32(streamId)
    end
    self:run(connection)
end

-- Only an admin may retune a running server.
local function senderIsAdmin(connection)
    if connection == nil then return g_server ~= nil end

    if type(connection.getIsMasterUser) == "function" then
        local value = connection:getIsMasterUser()
        if type(value) == "boolean" then return value end
    end
    if connection.isMasterUser ~= nil then return connection.isMasterUser == true end

    local mission = g_currentMission
    local users = mission ~= nil and mission.userManager or nil
    if users ~= nil and type(users.getUserByConnection) == "function" then
        local user = users:getUserByConnection(connection)
        if type(user) == "table" then
            if type(user.getIsMasterUser) == "function" then
                local value = user:getIsMasterUser()
                if type(value) == "boolean" then return value end
            end
            if user.isMasterUser ~= nil then return user.isMasterUser == true end
        end
    end

    return false
end

local function pushTo(connection)
    if connection == nil or type(connection.sendEvent) ~= "function" then return end
    connection:sendEvent(NXHerdTuningEvent.newState(Tuning.seasonScaled, Tuning:getTrim()), false)
end

function NXHerdTuningEvent:run(connection)
    -- Arriving from the server: accept it, we are a client.
    if connection ~= nil and connection:getIsServer() then
        Tuning:adopt(self.seasonScaled, self.trim)
        Tuning.synced    = true
        Tuning.pollTimer = 0
        return
    end

    -- Arriving from a client: we are the server.
    if self.isPoll then
        pushTo(connection)
        return
    end

    if senderIsAdmin(connection) then
        Tuning:adopt(self.seasonScaled, self.trim)
        g_server:broadcastEvent(NXHerdTuningEvent.newState(Tuning.seasonScaled, Tuning:getTrim()), true)
    else
        -- Refused; correct the sender rather than leaving them out of step.
        pushTo(connection)
    end
end

-- ------------------------------------------------------------
--  Persistence
-- ------------------------------------------------------------

Tuning.schema = XMLSchema.new("NXHerdMeterTuning")
Tuning.schema:register(XMLValueType.INT,   Tuning.ROOT .. "#revision",     "Layout revision", Tuning.REVISION)
Tuning.schema:register(XMLValueType.BOOL,  Tuning.NODE .. "#seasonScaled", "Scale with month length", false)
Tuning.schema:register(XMLValueType.FLOAT, Tuning.NODE .. "#trim",         "Demand multiplier", Tuning.NEUTRAL_TRIM)

-- Settings written by releases up to 1.0.0.4 so existing saves keep their
-- configuration instead of silently resetting.
Tuning.legacySchema = XMLSchema.new("NXHerdMeterTuningLegacy")
Tuning.legacySchema:register(XMLValueType.BOOL,   "nxFeedCalcScaling.settings#enabled",          "Legacy enable flag", false)
Tuning.legacySchema:register(XMLValueType.STRING, "nxFeedCalcScaling.settings#mode",             "Legacy mode", "vanilla")
Tuning.legacySchema:register(XMLValueType.FLOAT,  "nxFeedCalcScaling.settings#customMultiplier", "Legacy multiplier", 1.0)

local function savegameFolder()
    local mission = g_currentMission
    if mission == nil then return nil end

    local folder = nil
    if mission.missionInfo ~= nil then folder = mission.missionInfo.savegameDirectory end
    if (folder == nil or folder == "") then folder = mission.savegameDirectory end
    if type(folder) ~= "string" or folder == "" then return nil end

    return folder
end

local function pathFor(fileName)
    local folder = savegameFolder()
    if folder == nil then return nil end
    return folder .. "/" .. fileName
end

-- Fold the old four-mode setting onto the two-control model.
local function importLegacy()
    local path = pathFor(Tuning.LEGACY_FILE)
    if path == nil or XMLFile == nil or XMLFile.loadIfExists == nil then return false end

    local file = XMLFile.loadIfExists("NXHerdMeterLegacy", path, Tuning.legacySchema)
    if file == nil then return false end

    local enabled = file:getValue("nxFeedCalcScaling.settings#enabled", false)
    local mode    = tostring(file:getValue("nxFeedCalcScaling.settings#mode", "vanilla")):lower()
    local factor  = file:getValue("nxFeedCalcScaling.settings#customMultiplier", Tuning.NEUTRAL_TRIM)
    file:delete()

    if not enabled then
        Tuning:adopt(false, Tuning.NEUTRAL_TRIM)
        return true
    end

    local seasonScaled = (mode == "auto" or mode == "hybrid")
    local trim = (mode == "manual" or mode == "hybrid") and factor or Tuning.NEUTRAL_TRIM
    Tuning:adopt(seasonScaled, trim)

    return true
end

function Tuning:load()
    local path = pathFor(self.STORE_FILE)
    if path == nil then return false end

    local file = nil
    if XMLFile ~= nil and XMLFile.loadIfExists ~= nil then
        file = XMLFile.loadIfExists("NXHerdMeterTuning", path, self.schema)
    end

    if file == nil then
        if not importLegacy() then
            self:adopt(false, self.NEUTRAL_TRIM)
        end
        return false
    end

    self:adopt(
        file:getValue(self.NODE .. "#seasonScaled", false),
        file:getValue(self.NODE .. "#trim", self.NEUTRAL_TRIM)
    )
    file:delete()

    return true
end

function Tuning:save()
    local path = pathFor(self.STORE_FILE)
    if path == nil then return false end
    if XMLFile == nil or XMLFile.create == nil then return false end

    local file = XMLFile.create("NXHerdMeterTuning", path, self.ROOT, self.schema)
    if file == nil then return false end

    file:setValue(self.ROOT .. "#revision",     self.REVISION)
    file:setValue(self.NODE .. "#seasonScaled", self:isSeasonScaled())
    file:setValue(self.NODE .. "#trim",         self:getTrim())
    file:save()
    file:delete()

    return true
end

-- ------------------------------------------------------------
--  Lifecycle
-- ------------------------------------------------------------

function Tuning:bindMissionHooks()
    if self.hooksBound then return end
    if FSBaseMission == nil or type(FSBaseMission.loadSettingsFromServer) ~= "function" then return end

    FSBaseMission.loadSettingsFromServer = Utils.appendedFunction(
        FSBaseMission.loadSettingsFromServer,
        function(_, connection)
            if g_server ~= nil then pushTo(connection) end
        end)

    self.hooksBound = true
end

function Tuning:loadMap()
    self:bindMissionHooks()

    if g_server ~= nil then
        self.synced = true
    elseif g_client ~= nil then
        self.synced = false
        self.pollTimer = self.POLL_INTERVAL_MS
    end
end

-- Clients that joined before the server pushed state ask again until answered.
function Tuning:update(dt)
    if g_server ~= nil or g_client == nil or self.synced then return end

    self.pollTimer = (self.pollTimer or 0) + (dt or 0)
    if self.pollTimer < self.POLL_INTERVAL_MS then return end
    self.pollTimer = 0

    local connection = g_client:getServerConnection()
    if connection ~= nil then
        connection:sendEvent(NXHerdTuningEvent.newPoll())
    end
end

function Tuning:deleteMap() end

Tuning:restoreDefaults()
addModEventListener(Tuning)
