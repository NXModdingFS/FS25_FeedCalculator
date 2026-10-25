-- NXHerdMeter.lua
-- NX FeedCalculator entry point.
--
-- Load order matters: stores and demand are pure readers with no dependencies,
-- tuning owns settings state, and the governor, readout and options all build
-- on those.

local here = g_currentModDirectory or ""

source(Utils.getFilename("scripts/HerdStores.lua",   here))
source(Utils.getFilename("scripts/HerdDemand.lua",   here))
source(Utils.getFilename("scripts/HerdTuning.lua",   here))
source(Utils.getFilename("scripts/HerdGovernor.lua", here))
source(Utils.getFilename("scripts/HerdReadout.lua",  here))
source(Utils.getFilename("scripts/HerdOptions.lua",  here))

NXHerdMeter.modName    = g_currentModName or "FS25_FeedCalculator"
NXHerdMeter.reports    = {}
NXHerdMeter.monthDays  = nil

local Stores = NXHerdMeter.Stores
local Demand = NXHerdMeter.Demand

-- ------------------------------------------------------------
--  Companion mod detection
-- ------------------------------------------------------------
-- Extended animal mods add a lactation schedule to the animal sub types. The
-- result is cached, but only once a mission exists, because the mod list is
-- not populated while this file is being read.

local EXTENDED_GLOBALS = { "EAS_AnimalCluster", "EAS_AnimalSystem" }
local EXTENDED_HINTS   = { "enhancedanimalsystem" }

local extendedAnimals = nil

function NXHerdMeter.extendedAnimalsPresent()
    if extendedAnimals ~= nil then return extendedAnimals end

    local function detect()
        for _, name in ipairs(EXTENDED_GLOBALS) do
            if _G[name] ~= nil then return true end
        end

        if type(g_modIsLoaded) == "table" then
            for modName, loaded in pairs(g_modIsLoaded) do
                if loaded == true and type(modName) == "string" then
                    local lowered = string.lower(modName)
                    for _, hint in ipairs(EXTENDED_HINTS) do
                        if string.find(lowered, hint, 1, true) ~= nil then return true end
                    end
                end
            end
        end

        return false
    end

    local found = detect()

    -- Only trust a negative once the mod list is actually up.
    if found or g_currentMission ~= nil then
        extendedAnimals = found
    end

    return found
end

-- ------------------------------------------------------------
--  Cached figures
-- ------------------------------------------------------------
-- Other mods and the console command read these; the menu always recalculates
-- so what is on screen is never stale.

function NXHerdMeter.cacheReport(husbandry, report)
    if husbandry == nil or report == nil then return end

    local daily   = report.dailyIntake.food or 0
    local monthly = daily * report.daysInMonth

    NXHerdMeter.reports[Stores.identify(husbandry)] = {
        head         = report.head,
        monthlyFood  = monthly,
        dailyFood    = daily,
        daysInMonth  = report.daysInMonth,
    }

    -- Kept on the husbandry itself for anything that walks placeables.
    husbandry.nxHerdMonthlyFood = monthly
    husbandry.nxHerdDailyFood   = daily
end

function NXHerdMeter.eachHusbandry(visit)
    local mission = g_currentMission
    local system = mission ~= nil and mission.placeableSystem or nil
    if system == nil or type(system.placeables) ~= "table" then return end

    for _, placeable in pairs(system.placeables) do
        if type(placeable) == "table" and placeable.spec_husbandryAnimals ~= nil then
            visit(placeable)
        end
    end
end

function NXHerdMeter.resurvey(husbandry)
    if husbandry == nil then return end
    NXHerdMeter.cacheReport(husbandry, Demand.survey(husbandry))
end

function NXHerdMeter.resurveyAll()
    NXHerdMeter.eachHusbandry(NXHerdMeter.resurvey)
end

-- ------------------------------------------------------------
--  Updateable
-- ------------------------------------------------------------
-- Month length can change mid game; every cached figure is derived from it.

function NXHerdMeter:update(dt)
    local days = Demand.monthLengthInDays()
    if days == self.monthDays then return end

    self.monthDays = days
    NXHerdMeter.resurveyAll()
end

-- ------------------------------------------------------------
--  Diagnostics
-- ------------------------------------------------------------

function NXHerdMeter.consoleReport()
    local lines = { "Feed Calculator: " .. NXHerdMeter.Tuning:describe() }
    local seen = 0

    NXHerdMeter.eachHusbandry(function(placeable)
        local report = Demand.survey(placeable)
        local daily = report.dailyIntake.food or 0

        -- Head count can be zero when an animal mod keeps its records out of
        -- reach; a published rate still makes the barn worth reporting.
        if report.head <= 0 and daily <= 0 then return end

        seen = seen + 1

        local trough, grazing = Stores.feedOnHand(placeable)
        local perMonth = function(key) return (report.dailyIntake[key] or 0) * report.daysInMonth end

        lines[#lines + 1] = string.format(
            "  #%d  %d animals  food %.0f l/day (%.0f l/mo)  trough %.0f l  pasture %.0f l  water %.0f l/day  straw %.0f l/day",
            seen, report.head, daily, perMonth("food"), trough, grazing,
            report.dailyIntake.water or 0, report.dailyIntake.straw or 0)

        lines[#lines + 1] = string.format(
            "        rate source: food=%s water=%s straw=%s yields=%s  intensity %.3f",
            report.rateSource.food or "?", report.rateSource.water or "?",
            report.rateSource.straw or "?", report.rateSource.yields or "?",
            report.intensity or 1)


        if Stores.hasPasture(placeable) then
            local quality = Stores.pastureQuality(placeable)
            local cover = daily > 0 and (grazing / daily) or 0
            lines[#lines + 1] = string.format(
                "        pasture covers %.1f days%s",
                cover,
                quality ~= nil and string.format(", graze weighting %.0f%%", quality * 100) or "")
        end
    end)

    if seen == 0 then
        lines[#lines + 1] = "  no stocked husbandries found"
    end

    return table.concat(lines, "\n")
end

-- ------------------------------------------------------------
--  Boot
-- ------------------------------------------------------------

-- Throughput scaling has to be in place before placeable types are built, so
-- try immediately and again once the mission is up.
NXHerdMeter.Governor:bindAll()

Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
    extendedAnimals = nil

    -- Menu frames from a previous session are gone; drop the stale references.
    NXHerdMeter.Options.pages = {}
    NXHerdMeter.reports = {}

    NXHerdMeter.Governor:reportUnbound()
    NXHerdMeter.Readout:install()
    NXHerdMeter.Options:install()

    NXHerdMeter.monthDays = Demand.monthLengthInDays()

    -- The host owns the settings; clients receive them over the wire.
    if g_server ~= nil then
        NXHerdMeter.Tuning:load()
    end

    if g_messageCenter ~= nil then
        g_messageCenter:subscribe(MessageType.HUSBANDRY_ANIMALS_CHANGED, function(husbandry)
            NXHerdMeter.resurvey(husbandry)
        end)
    end

    if g_currentMission ~= nil and type(g_currentMission.updateables) == "table" then
        table.insert(g_currentMission.updateables, NXHerdMeter)
    end

    -- Loading a second savegame in one session runs this again; registering
    -- the same command twice logs a warning.
    if not NXHerdMeter.commandRegistered then
        NXHerdMeter.commandRegistered = true
        addConsoleCommand("nxFeedReport", "Print feed demand and grazing cover for every husbandry",
            "consoleReport", NXHerdMeter)
    end
end)

if FSBaseMission ~= nil and type(FSBaseMission.saveSavegame) == "function" then
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
        if g_server ~= nil then
            NXHerdMeter.Tuning:save()
        end
    end)
end
