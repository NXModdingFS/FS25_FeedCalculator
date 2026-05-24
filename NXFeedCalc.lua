source(Utils.getFilename("scripts/NXScaling.lua",      g_currentModDirectory or ""))
source(Utils.getFilename("scripts/NXSettingsMenu.lua", g_currentModDirectory or ""))
source(Utils.getFilename("scripts/NXHooks.lua",        g_currentModDirectory or ""))

AnimalFoodCalculator = {}
AnimalFoodCalculator.name = g_currentModName or "AnimalFoodCalculator"
AnimalFoodCalculator.debug = false
AnimalFoodCalculator.data = {}
AnimalFoodCalculator.daysPerPeriod = nil

local function isEASActive()
    if EAS_AnimalCluster ~= nil then return true end
    if g_modIsLoaded ~= nil then
        if g_modIsLoaded["FS25_EnhancedAnimalSystem"] == true then return true end
        for modName, isLoaded in pairs(g_modIsLoaded) do
            if isLoaded == true and type(modName) == "string"
                and string.find(string.lower(modName), "enhancedanimalsystem", 1, true) ~= nil then
                return true
            end
        end
    end
    return false
end

local function isRLActive()
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_RealisticLivestock"] == true then
        return true
    end
    return g_modManager ~= nil and g_modManager:getModByName("FS25_RealisticLivestock") ~= nil
end

-- ============================================================
--  DEBUG HELPERS
-- ============================================================

local function safe(v)
    if v == nil then return "nil" end
    if type(v) == "boolean" then return tostring(v) end
    if type(v) == "number"  then return string.format("%g", v) end
    if type(v) == "string"  then return '"' .. v .. '"' end
    if type(v) == "table"   then return "{table #" .. tostring(#v) .. "}" end
    return tostring(v)
end

local function dbg(msg)
    print("[NXFC_DEBUG] " .. tostring(msg))
end

local function dbgHeader(title)
    dbg("========== " .. title .. " ==========")
end

local function dumpFillTypes()
    dbgHeader("ALL FILL TYPES (FillTypeManager)")
    if not g_fillTypeManager then dbg("  g_fillTypeManager is nil"); return end
    local fillTypes = g_fillTypeManager:getFillTypes()
    if not fillTypes then dbg("  getFillTypes() returned nil"); return end
    for i, ft in pairs(fillTypes) do
        dbg(string.format("  [%d] name=%-30s title=%s", i, safe(ft.name), safe(ft.title)))
    end
end

local function dumpFillLevels(label, fillLevels)
    if not fillLevels then dbg("  " .. label .. " = nil"); return end
    dbg("  --- " .. label .. " ---")
    for ftIdx, lvl in pairs(fillLevels) do
        local name = "?"
        if g_fillTypeManager then
            local ft = g_fillTypeManager:getFillTypeByIndex(ftIdx)
            name = ft and ft.name or "?"
        end
        dbg(string.format("    fillType[%d] %-25s = %g", ftIdx, name, lvl or 0))
    end
end

local function dumpStorages(target, label)
    dbgHeader("STORAGES on " .. label)

    if target.spec_husbandryFood then
        dbg("  spec_husbandryFood found")
        dumpFillLevels("spec_husbandryFood.fillLevels", target.spec_husbandryFood.fillLevels)
        dbg("  spec_husbandryFood.capacity = " .. safe(target.spec_husbandryFood.capacity))
    else
        dbg("  spec_husbandryFood = nil")
    end

    if target.spec_husbandryStorage then
        dbg("  spec_husbandryStorage found")
        dumpFillLevels("spec_husbandryStorage.fillLevels", target.spec_husbandryStorage.fillLevels)
    else
        dbg("  spec_husbandryStorage = nil")
    end

    if target.storage then
        dbg("  storage found")
        dumpFillLevels("storage.fillLevels", target.storage.fillLevels)
        dbg("  storage.capacity = " .. safe(target.storage.capacity))
    else
        dbg("  storage = nil")
    end

    if target.foodStorage then
        dbg("  foodStorage found")
        dbg("  foodStorage.fillLevel = " .. safe(target.foodStorage.fillLevel))
        dbg("  foodStorage.capacity  = " .. safe(target.foodStorage.capacity))
        dumpFillLevels("foodStorage.fillLevels", target.foodStorage.fillLevels)
    else
        dbg("  foodStorage = nil")
    end
end

local function dumpCluster(c, idx)
    dbgHeader("CLUSTER #" .. tostring(idx))

    dbg("  numAnimals      = " .. safe(c.numAnimals))
    dbg("  age             = " .. safe(c.age))
    dbg("  subTypeIndex    = " .. safe(c.subTypeIndex))
    dbg("  typeId          = " .. safe(c.typeId))
    dbg("  typeName        = " .. safe(c.typeName))
    dbg("  id              = " .. safe(c.id))
    dbg("  name            = " .. safe(c.name))

    dbg("  sex             = " .. safe(c.sex))
    dbg("  lactating       = " .. safe(c.lactating))
    dbg("  lactationFactor = " .. safe(c.lactationFactor))
    dbg("  pregnant        = " .. safe(c.pregnant))
    dbg("  reproState      = " .. safe(c.reproState))
    dbg("  gestationAge    = " .. safe(c.gestationAge))

    dbg("  health          = " .. safe(c.health))
    dbg("  fitness         = " .. safe(c.fitness))
    dbg("  cleanliness     = " .. safe(c.cleanliness))
    dbg("  productivity    = " .. safe(c.productivity))
    dbg("  reproductivity  = " .. safe(c.reproductivity))

    dbg("  foodFactor      = " .. safe(c.foodFactor))
    dbg("  hungerLevel     = " .. safe(c.hungerLevel))
    dbg("  foodConsumption = " .. safe(c.foodConsumption))
    dbg("  dailyFoodUsage  = " .. safe(c.dailyFoodUsage))
    dbg("  foodUsageScale  = " .. safe(c.foodUsageScale))
    dbg("  baseConsumption = " .. safe(c.baseConsumption))
    dbg("  consumptionRate = " .. safe(c.consumptionRate))

    dbg("  weightKg        = " .. safe(c.weightKg))
    dbg("  dryMatterNeeded = " .. safe(c.dryMatterNeeded))
    dbg("  metabolicWeight = " .. safe(c.metabolicWeight))

    dbg("  --- ALL OTHER KEYS IN CLUSTER ---")
    local known = {
        numAnimals=1,age=1,subTypeIndex=1,typeId=1,typeName=1,id=1,name=1,
        sex=1,lactating=1,lactationFactor=1,pregnant=1,reproState=1,gestationAge=1,
        health=1,fitness=1,cleanliness=1,productivity=1,reproductivity=1,
        foodFactor=1,hungerLevel=1,foodConsumption=1,dailyFoodUsage=1,
        foodUsageScale=1,baseConsumption=1,consumptionRate=1,
        weightKg=1,dryMatterNeeded=1,metabolicWeight=1,
    }
    for k, v in pairs(c) do
        if not known[k] and type(v) ~= "function" then
            dbg(string.format("    [%s] = %s", tostring(k), safe(v)))
        end
    end

    -- subType from animalSystem
    if g_currentMission and g_currentMission.animalSystem and c.subTypeIndex then
        local subTypes = g_currentMission.animalSystem.subTypes
        local st = subTypes and subTypes[c.subTypeIndex]
        if st then
            dbgHeader("  SUBTYPE for cluster #" .. tostring(idx))
            dbg("    st.name = " .. safe(st.name))
            dbg("    st.type = " .. safe(st.type))

            if st.input then
                dbg("    --- st.input keys ---")
                for k, v in pairs(st.input) do
                    if type(v) ~= "function" then
                        if type(v) == "table" then
                            local vals = {}
                            for i2 = 0, 10 do
                                local entry = v[i2]
                                if entry ~= nil then
                                    vals[#vals+1] = string.format("[%d]=%s", i2, safe(entry))
                                end
                            end
                            local getStr = ""
                            if type(v.get) == "function" then
                                for i2 = 0, 10 do
                                    local ok, res = pcall(v.get, v, i2)
                                    if ok then
                                        getStr = getStr .. string.format("[%d]=%s ", i2, safe(res))
                                    end
                                end
                            end
                            dbg(string.format("    input[%s] table vals=%s  :get()=%s",
                                tostring(k), table.concat(vals, " "), getStr))
                        else
                            dbg(string.format("    input[%s] = %s", tostring(k), safe(v)))
                        end
                    end
                end
            else
                dbg("    st.input is nil")
            end

            if st.output then
                dbg("    --- st.output keys ---")
                for k, v in pairs(st.output) do
                    if type(v) ~= "function" then
                        if type(v) == "table" then
                            local vals = {}
                            for i2 = 0, 5 do
                                if v[i2] ~= nil then
                                    vals[#vals+1] = string.format("[%d]=%s", i2, safe(v[i2]))
                                end
                            end
                            dbg(string.format("    output[%s] = %s", tostring(k), table.concat(vals, " ")))
                        else
                            dbg(string.format("    output[%s] = %s", tostring(k), safe(v)))
                        end
                    end
                end
            end
        else
            dbg("  subType lookup failed for subTypeIndex=" .. safe(c.subTypeIndex))
        end
    end
end

local function dumpHusbandryFields(h)
    dbgHeader("HUSBANDRY TOP-LEVEL")
    dbg("  type(h)    = " .. type(h))
    dbg("  h.typeName = " .. safe(h.typeName))
    local fields = {
        "totalFoodConsumption","dailyFoodConsumption","foodConsumptionPerDay",
        "foodConsumptionPerHour","totalDailyFood","monthlyFoodUsage",
        "foodFillLevel","foodCapacity","totalFoodCapacity",
    }
    for _, f in ipairs(fields) do
        if h[f] ~= nil then
            dbg(string.format("  h.%-30s = %s", f, safe(h[f])))
        end
    end
end

-- Throttle: only dump once every 5 real seconds to avoid log spam
-- os library is not available in FS25 Lua sandbox, use getTimeSec() instead
local _lastDump = nil

local function fullDump(husbandry)
    if not AnimalFoodCalculator.debug then return end
    if not husbandry then dbg("fullDump called with nil husbandry"); return end
    local now = getTimeSec()
    if _lastDump and (now - _lastDump) < 5 then return end
    _lastDump = now

    dbg("##############################################################")
    dbg("# NXFC FULL ANIMAL DATA DUMP")
    dbg("##############################################################")

    dumpFillTypes()
    dumpHusbandryFields(husbandry)

    local target = husbandry.owningPlaceable or husbandry
    dumpStorages(target, "owningPlaceable/husbandry")

    if target.spec_husbandryAnimals and target.spec_husbandryAnimals ~= husbandry then
        dumpStorages(target.spec_husbandryAnimals, "spec_husbandryAnimals")
    end

    dbgHeader("GAME SETTINGS")
    if g_currentMission and g_currentMission.missionInfo then
        dbg("  plannedDaysPerPeriod = " .. safe(g_currentMission.missionInfo.plannedDaysPerPeriod))
        dbg("  daysPerPeriod        = " .. safe(g_currentMission.missionInfo.daysPerPeriod))
    end

    -- Resolve clusters
    local clusters = nil
    local function tryGetClusters(o)
        if type(o.getClusters) == "function" then
            local ok, res = pcall(o.getClusters, o)
            if ok and type(res) == "table" then return res end
        end
        return type(o.clusters) == "table" and o.clusters or nil
    end
    clusters = tryGetClusters(husbandry)
    if not clusters and target.spec_husbandryAnimals then
        clusters = tryGetClusters(target.spec_husbandryAnimals)
    end

    if clusters then
        dbg("  Total clusters found: " .. #clusters)
        for i, c in ipairs(clusters) do
            dumpCluster(c, i)
        end
    else
        dbg("  No clusters found on this husbandry object")
    end

    dbg("##############################################################")
    dbg("# END DUMP")
    dbg("##############################################################")
end

-- ============================================================
--  ORIGINAL MOD CODE
-- ============================================================

local function getClustersFromObject(obj)
    if not obj then return nil end

    local function tryGetClusters(o)
        if type(o.getClusters) == "function" then
            local ok, res = pcall(o.getClusters, o)
            if ok and type(res) == "table" then return res end
        end
        if type(o.clusters) == "table" then return o.clusters end
        return nil
    end

    local clusters = tryGetClusters(obj)
    if clusters then return clusters end
    if obj.spec_husbandryAnimals then
        clusters = tryGetClusters(obj.spec_husbandryAnimals)
        if clusters then return clusters end
    end
    if obj.owningPlaceable and obj.owningPlaceable.spec_husbandryAnimals then
        clusters = tryGetClusters(obj.owningPlaceable.spec_husbandryAnimals)
        if clusters then return clusters end
    end
    if type(obj.getModuleByName) == "function" then
        local ok, mod = pcall(obj.getModuleByName, obj, "husbandryAnimals")
        if ok and mod then
            clusters = tryGetClusters(mod)
            if clusters then return clusters end
        end
    end
    return nil
end

local function getHusbandryKey(h)
    if h and h.owningPlaceable and h.owningPlaceable.id then
        return "placeable_" .. tostring(h.owningPlaceable.id)
    end
    return tostring(h)
end

local function getCurrentFood(h)
    if not h then return 0 end
    local total = 0
    local target = h.owningPlaceable or h

    local spec = target.spec_husbandryFood
    if spec and spec.fillLevels then
        for fillTypeIndex, fillLevel in pairs(spec.fillLevels) do
            if fillLevel and fillLevel > 0 then
                total = total + fillLevel
            end
        end
    end

    if total == 0 then
        if target.storage and target.storage.fillLevels then
            for fillTypeIndex, fillLevel in pairs(target.storage.fillLevels) do
                if fillLevel > 0 then
                    total = total + fillLevel
                end
            end
        end
    end

    if total == 0 then
        if target.foodStorage then
            if type(target.foodStorage.fillLevel) == "number" and target.foodStorage.fillLevel > 0 then
                total = total + target.foodStorage.fillLevel
            end
            if target.foodStorage.fillLevels then
                for idx, lvl in pairs(target.foodStorage.fillLevels) do
                    if lvl > 0 then
                        total = total + lvl
                    end
                end
            end
        end
    end

    if total == 0 then
        if target.spec_husbandryStorage and target.spec_husbandryStorage.fillLevels then
            for idx, lvl in pairs(target.spec_husbandryStorage.fillLevels) do
                if lvl > 0 then
                    total = total + lvl
                end
            end
        end
    end

    return total
end

local function getClusterAge(cluster)
    if cluster == nil then return 0 end
    if type(cluster.getAge) == "function" then
        local ok, age = pcall(cluster.getAge, cluster)
        if ok and type(age) == "number" then return age end
    end
    return cluster.age or 0
end

local function getClusterNumAnimals(cluster)
    if cluster == nil then return 0 end
    if type(cluster.getNumAnimals) == "function" then
        local ok, n = pcall(cluster.getNumAnimals, cluster)
        if ok and type(n) == "number" then return n end
    end
    return cluster.numAnimals or 0
end

local function getSubTypeFromCluster(cluster)
    if cluster == nil or cluster.subTypeIndex == nil then return nil end
    if not g_currentMission or not g_currentMission.animalSystem then return nil end
    local subTypes = g_currentMission.animalSystem.subTypes
    return subTypes and subTypes[cluster.subTypeIndex] or nil
end

-- EAS food multiplier: project reproduction state and read subType.lactation[].food
-- for the appropriate month, rather than trusting cluster.lactationFactor (which is
-- not guaranteed to exist on EAS clusters and only reflects current state).
local function getEASFoodFactor(cluster)
    if cluster == nil or not isEASActive() then return 1.0 end

    local subType = getSubTypeFromCluster(cluster)
    if subType == nil or type(subType.lactation) ~= "table" then
        if cluster.lactating then
            return cluster.lactationFactor or 1.0
        end
        return 1.0
    end

    local canReproduce = false
    if type(cluster.getCanReproduce) == "function" then
        local ok, res = pcall(cluster.getCanReproduce, cluster)
        if ok then canReproduce = (res == true) end
    elseif subType.supportsReproduction == true then
        canReproduce = getClusterAge(cluster) >= (tonumber(subType.reproductionMinAgeMonth) or 0)
    end

    if not canReproduce or cluster.hadABirth ~= true then
        return 1.0
    end

    local targetMonth = (tonumber(cluster.monthsSinceLastBirth) or 0) + 1
    for _, entry in ipairs(subType.lactation) do
        if tonumber(entry.month) == targetMonth then
            local v = entry.food
            if type(v) == "number" then return v end
            if type(v) == "string" then
                local parsed = tonumber(v)
                if parsed ~= nil then return parsed end
            end
        end
    end

    return 1.0
end

function AnimalFoodCalculator:calcInputByAge(cluster, inputName, extraMonths)
    if not cluster or cluster.subTypeIndex == nil or inputName == nil then return 0 end

    local subType = getSubTypeFromCluster(cluster)
    if not subType or type(subType.input) ~= "table" or subType.input[inputName] == nil then
        return 0
    end

    local idx = getClusterAge(cluster) + (extraMonths or 0)
    if idx < 0 then idx = 0 end

    local curve = subType.input[inputName]
    local baseVal = 0
    if type(curve.get) == "function" then
        baseVal = curve:get(idx) or 0
    elseif type(curve[idx]) == "number" then
        baseVal = curve[idx]
    end

    if inputName == "food" then
        baseVal = baseVal * getEASFoodFactor(cluster)
    end

    return baseVal
end

function AnimalFoodCalculator:calcFoodByAge(cluster, extraMonths)
    return self:calcInputByAge(cluster, "food", extraMonths)
end

function AnimalFoodCalculator:calcOutputByAge(cluster, outputName, extraMonths)
    if not cluster or cluster.subTypeIndex == nil or outputName == nil then return 0, nil end

    local subType = getSubTypeFromCluster(cluster)
    if not subType or type(subType.output) ~= "table" or subType.output[outputName] == nil then
        return 0, nil
    end

    local idx = getClusterAge(cluster) + (extraMonths or 0)
    if idx < 0 then idx = 0 end

    local def = subType.output[outputName]
    local baseVal, fillType = 0, nil
    if type(def) == "table" then
        fillType = def.fillType
        if def.curve ~= nil then
            local curve = def.curve
            if type(curve.get) == "function" then
                baseVal = curve:get(idx) or 0
            elseif type(curve[idx]) == "number" then
                baseVal = curve[idx]
            end
        elseif type(def.get) == "function" then
            baseVal = def:get(idx) or 0
        elseif type(def[idx]) == "number" then
            baseVal = def[idx]
        end
    end

    return baseVal, fillType
end

-- Prefer the live runtime value (environment.daysPerPeriod) over missionInfo.
-- plannedDaysPerPeriod is the user-set target and can desync from the active value.
local function getDaysPerMonth()
    if g_currentMission then
        local env = g_currentMission.environment
        if env ~= nil and env.daysPerPeriod ~= nil and env.daysPerPeriod > 0 then
            return env.daysPerPeriod
        end
        if g_currentMission.missionInfo then
            local mi = g_currentMission.missionInfo
            if mi.daysPerPeriod ~= nil and mi.daysPerPeriod > 0 then
                return mi.daysPerPeriod
            end
            if mi.plannedDaysPerPeriod ~= nil and mi.plannedDaysPerPeriod > 0 then
                return mi.plannedDaysPerPeriod
            end
        end
    end
    return 1
end

function AnimalFoodCalculator:calcFoodPerCluster(cluster)
    if not cluster then return 0, 0, 1 end

    local num = getClusterNumAnimals(cluster)
    local dpm = getDaysPerMonth()

    local perAnimalPerMonth = self:calcFoodByAge(cluster, 0)
    local perAnimalPerDay   = (dpm > 0) and (perAnimalPerMonth / dpm) or 0

    local daily   = perAnimalPerDay   * num
    local monthly = perAnimalPerMonth * num

    return daily, monthly, dpm
end

function AnimalFoodCalculator:onAnimalsChanged(h)
    if not h then return end
    local clusters = getClustersFromObject(h)
    if not clusters then return end

    local totalDaily, totalMonthly = 0, 0
    local dpm = getDaysPerMonth()

    for _, c in ipairs(clusters) do
        local d, m = self:calcFoodPerCluster(c)
        totalDaily = totalDaily + (d or 0)
        totalMonthly = totalMonthly + (m or 0)
    end

    h.nxfcDaily = totalDaily
    h.nxfcMonthly = totalMonthly

    local key = getHusbandryKey(h)
    if key then
        self.data[key] = { daily = totalDaily, monthly = totalMonthly, daysPerMonth = dpm }
    end
end

function AnimalFoodCalculator:update(dt)
    local now = getDaysPerMonth()
    if now ~= self.daysPerPeriod then
        self.daysPerPeriod = now

        if g_currentMission and g_currentMission.placeableSystem and g_currentMission.placeableSystem.placeables then
            for _, place in pairs(g_currentMission.placeableSystem.placeables) do
                if place.spec_husbandryAnimals then
                    self:onAnimalsChanged(place.spec_husbandryAnimals)
                end
            end
        end
    end
end

-- =====================================================
-- Conditions-panel helpers (water/straw + outputs)
-- =====================================================
local function normalizeText(s)
    if type(s) ~= "string" then return "" end
    local t = string.lower(s)
    t = t:gsub("ä", "a"):gsub("ö", "o"):gsub("ü", "u"):gsub("ß", "ss")
    t = t:gsub("|.*$", "")
    t = t:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    return t
end

local function formatTimeRemaining(daysRemaining, dpm, currentLevel)
    if daysRemaining > 0 then
        if dpm == 1 then
            return string.format("%.1fm", daysRemaining / dpm)
        end
        local months = math.floor(daysRemaining / dpm)
        local days   = math.ceil(daysRemaining - (months * dpm))
        if months > 0 and days > 0 then return string.format("%dm %dd", months, days) end
        if months > 0 then return string.format("%dm", months) end
        return string.format("%dd", days)
    end
    return (currentLevel and currentLevel > 0) and "<0.1d" or "Empty"
end

local function getOriginalConditionText(valueEl)
    local ok, t = pcall(valueEl.getText, valueEl)
    if not ok or type(t) ~= "string" then return "" end
    local sep = string.find(t, "|", 1, true)
    if sep then
        return (t:sub(1, sep - 1):gsub("%s+$", ""))
    end
    return t
end

local function setConditionWithExtra(valueEl, extraText)
    local original = getOriginalConditionText(valueEl)
    local composed = (original ~= "" and (original .. "  |  " .. extraText)) or extraText
    pcall(valueEl.setText, valueEl, composed)
end

local function parseLiters(text)
    if type(text) ~= "string" then return 0 end
    local digits = text:gsub("[^%d]", "")
    return tonumber(digits) or 0
end

local function getLocalizedFormat(key, fallback)
    if g_i18n and type(g_i18n.getText) == "function" then
        local ok, v = pcall(g_i18n.getText, g_i18n, key)
        if ok and type(v) == "string" and v ~= "" and v ~= key then
            return v
        end
    end
    return fallback
end

local INPUT_TITLE_PATTERNS = {
    water = { "water", "wasser", "eau" },
    straw = { "straw", "stroh", "paille" },
}

local function matchesAny(text, patterns)
    for _, p in ipairs(patterns) do
        if p ~= "" and string.find(text, p, 1, true) then return true end
    end
    return false
end

local function aggregateHusbandry(husbandry)
    local result = { inputs = { food = 0, water = 0, straw = 0 }, outputsByTitle = {} }
    local clusters = getClustersFromObject(husbandry)
    if not clusters then return result end

    for _, c in ipairs(clusters) do
        local num = getClusterNumAnimals(c)
        local subType = getSubTypeFromCluster(c)
        if num > 0 and subType then
            for _, name in ipairs({ "food", "water", "straw" }) do
                local v = AnimalFoodCalculator:calcInputByAge(c, name, 0) or 0
                result.inputs[name] = result.inputs[name] + v * num
            end

            if type(subType.output) == "table" then
                for outputName, def in pairs(subType.output) do
                    local v, fillType = AnimalFoodCalculator:calcOutputByAge(c, outputName, 0)
                    if v and v > 0 then
                        local title = nil
                        if fillType ~= nil and g_fillTypeManager ~= nil then
                            title = g_fillTypeManager:getFillTypeTitleByIndex(fillType)
                        end
                        title = title or tostring(outputName)
                        local key = normalizeText(title)
                        if key ~= "" then
                            local bucket = result.outputsByTitle[key]
                            if bucket == nil then
                                bucket = { monthly = 0, title = title, name = outputName }
                                result.outputsByTitle[key] = bucket
                            end
                            bucket.monthly = bucket.monthly + v * num
                        end
                    end
                end
            end
        end
    end

    return result
end

local function updateConditionsPanel(self, husbandry)
    if type(self.conditionValue) ~= "table" then return end
    if type(husbandry.getConditionInfos) ~= "function" then return end

    local ok, infos = pcall(husbandry.getConditionInfos, husbandry)
    if not ok or type(infos) ~= "table" then return end

    local totals = aggregateHusbandry(husbandry)
    local dpm    = getDaysPerMonth()
    local inputFmt  = getLocalizedFormat("nxfc_cond_input_fmt",  "%.0fl/mo (%s remain)")
    local outputFmt = getLocalizedFormat("nxfc_cond_output_fmt", "%.0fl/mo")

    for i, info in ipairs(infos) do
        local valueEl = self.conditionValue[i]
        if info ~= nil and type(valueEl) == "table" and type(valueEl.setText) == "function" then
            local normalized = normalizeText(info.title or "")
            local extraText  = nil

            if normalized ~= "" then
                local inputName = nil
                if matchesAny(normalized, INPUT_TITLE_PATTERNS.water) then
                    inputName = "water"
                elseif matchesAny(normalized, INPUT_TITLE_PATTERNS.straw) then
                    inputName = "straw"
                end

                if inputName ~= nil then
                    local monthly = totals.inputs[inputName] or 0
                    if monthly > 0 then
                        local daily      = monthly / (dpm > 0 and dpm or 1)
                        local fillLevel  = parseLiters(getOriginalConditionText(valueEl))
                        local daysRemain = (daily > 0) and (fillLevel / daily) or 0
                        extraText = string.format(inputFmt, monthly, formatTimeRemaining(daysRemain, dpm, fillLevel))
                    end
                else
                    local outputData = totals.outputsByTitle[normalized]
                    if outputData == nil then
                        for key, data in pairs(totals.outputsByTitle) do
                            if key ~= "" and string.find(normalized, key, 1, true) ~= nil then
                                outputData = data
                                break
                            end
                        end
                    end
                    if outputData and (outputData.monthly or 0) > 0 then
                        extraText = string.format(outputFmt, outputData.monthly)
                    end
                end
            end

            if extraText ~= nil then
                setConditionWithExtra(valueEl, extraText)
            end
        end
    end
end

local function NXFC_GUI(self, husbandry, ...)
    if not husbandry then
        husbandry = self.husbandry or self.selectedHusbandry or self.animalHusbandry or self.currentHusbandry
    end
    if not husbandry then
        if type(self.getDisplayedHusbandry) == "function" then
            local ok, h = pcall(self.getDisplayedHusbandry, self)
            if ok and h then husbandry = h end
        end
    end
    if not husbandry then return end

    -- ── DEBUG DUMP ──────────────────────────────────────────
    fullDump(husbandry)
    -- ────────────────────────────────────────────────────────

    AnimalFoodCalculator:onAnimalsChanged(husbandry)

    local clusters = getClustersFromObject(husbandry)
    if not clusters then return end

    local totalDaily, totalMonthly = 0, 0
    local dpm = getDaysPerMonth()

    for _, c in ipairs(clusters) do
        local d, m = AnimalFoodCalculator:calcFoodPerCluster(c)
        totalDaily = totalDaily + (d or 0)
        totalMonthly = totalMonthly + (m or 0)
    end

    local currentFood = getCurrentFood(husbandry)
    local daysRemaining = (totalDaily > 0) and (currentFood / totalDaily) or 0
    local statusString = formatTimeRemaining(daysRemaining, dpm, currentFood)

    local fmt = "%.0fl Monthly | %.0fl (%s) Remains"
    if g_i18n and type(g_i18n.getText) == "function" then
        local ok, txt = pcall(g_i18n.getText, g_i18n, "nxfc_gui_format")
        if ok and txt and txt ~= "" then fmt = txt end
    end

    local nxfcText = string.format(fmt, totalMonthly, currentFood, statusString or "")

    if self.foodRowTotalValue and type(self.foodRowTotalValue.setText) == "function" then
        pcall(self.foodRowTotalValue.setText, self.foodRowTotalValue, nxfcText)
    end
    if self.foodRowValue and type(self.foodRowValue.setText) == "function" then
        pcall(self.foodRowValue.setText, self.foodRowValue, "")
    end
    if self.foodRowFillLevelValue and type(self.foodRowFillLevelValue.setText) == "function" then
        pcall(self.foodRowFillLevelValue.setText, self.foodRowFillLevelValue, "")
    end

    updateConditionsPanel(self, husbandry)
end

-- Install consumption/output hooks as early as possible. Each hook is idempotent.
if NXHooks ~= nil then
    NXHooks:installAll()
end

Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
    AnimalFoodCalculator.daysPerPeriod = getDaysPerMonth()

    -- Re-attempt hook install in case specs weren't ready at module load.
    if NXHooks ~= nil then
        NXHooks:installAll()
    end

    -- Server loads persisted scaling settings; clients receive them via MP sync.
    if g_server ~= nil and NXScaling ~= nil and type(NXScaling.loadFromSavegameFile) == "function" then
        NXScaling:loadFromSavegameFile()
    end

    if g_messageCenter then
        g_messageCenter:subscribe(MessageType.HUSBANDRY_ANIMALS_CHANGED, function(h) AnimalFoodCalculator:onAnimalsChanged(h) end)
    end

    if g_currentMission then
        table.insert(g_currentMission.updateables, AnimalFoodCalculator)
    end

    if InGameMenuAnimalsFrame and type(InGameMenuAnimalsFrame.updateHusbandryDisplay) == "function" then
        InGameMenuAnimalsFrame.updateHusbandryDisplay =
            Utils.appendedFunction(InGameMenuAnimalsFrame.updateHusbandryDisplay, NXFC_GUI)
    end
end)

-- Persist scaling settings on save (server only).
if FSBaseMission ~= nil and type(FSBaseMission.saveSavegame) == "function" then
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
        if g_server ~= nil and NXScaling ~= nil and type(NXScaling.saveToSavegameFile) == "function" then
            NXScaling:saveToSavegameFile()
        end
    end)
end

return AnimalFoodCalculator