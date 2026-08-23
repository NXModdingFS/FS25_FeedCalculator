-- HerdDemand.lua
-- Turns a barn full of animal clusters into monthly litre figures.
--
-- The game stores per-animal appetite as age-indexed curves on the animal
-- sub type. Those curves are LITRES PER DAY, not per month: the game schema
-- documents every input and output key as "liters per day based on age".
-- Everything this module returns is therefore a daily rate; callers multiply
-- by the month length themselves when they want a monthly figure.
--
-- One walk over the herd collects every input and every output at once, so
-- the menu never has to re-walk the same clusters per row.

NXHerdMeter = NXHerdMeter or {}

local Stores = NXHerdMeter.Stores
local Demand = {}
NXHerdMeter.Demand = Demand

-- Inputs the sub type curves describe. Outputs are discovered dynamically
-- because animal mods add their own.
Demand.INTAKE_KEYS = { "food", "water", "straw" }

-- ------------------------------------------------------------
--  Low level readers
-- ------------------------------------------------------------

-- Curves come as AnimalCurve objects, plain arrays, or bare numbers.
local function sampleCurve(curve, atIndex)
    if curve == nil then return 0 end
    if type(curve) == "number" then return curve end
    if type(curve) ~= "table" then return 0 end

    if type(curve.get) == "function" then
        local ok, value = pcall(curve.get, curve, atIndex)
        if ok and type(value) == "number" then return value end
    end

    local direct = curve[atIndex]
    if type(direct) == "number" then return direct end

    return 0
end

local function numberFrom(value, fallback)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then return fallback end
    return parsed
end

function Demand.headCount(cluster)
    if type(cluster) ~= "table" then return 0 end
    local viaGetter = Stores.tryCall(cluster, "getNumAnimals")
    if type(viaGetter) == "number" then return viaGetter end
    return numberFrom(cluster.numAnimals, 0)
end

function Demand.ageOf(cluster)
    if type(cluster) ~= "table" then return 0 end
    local viaGetter = Stores.tryCall(cluster, "getAge")
    if type(viaGetter) == "number" then return viaGetter end
    return numberFrom(cluster.age, 0)
end

function Demand.subTypeOf(cluster)
    if type(cluster) ~= "table" or cluster.subTypeIndex == nil then return nil end
    local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if system == nil or type(system.subTypes) ~= "table" then return nil end
    return system.subTypes[cluster.subTypeIndex]
end

-- Length of an in-game month. The live environment value is authoritative;
-- the planned value on missionInfo is only what the player asked for and can
-- lag behind after a settings change.
function Demand.monthLengthInDays()
    local mission = g_currentMission
    if mission == nil then return 1 end

    local environment = mission.environment
    if environment ~= nil then
        local live = numberFrom(environment.daysPerPeriod, 0)
        if live > 0 then return live end
    end

    local info = mission.missionInfo
    if info ~= nil then
        local active = numberFrom(info.daysPerPeriod, 0)
        if active > 0 then return active end
        local planned = numberFrom(info.plannedDaysPerPeriod, 0)
        if planned > 0 then return planned end
    end

    return 1
end

-- ------------------------------------------------------------
--  Food modifiers
-- ------------------------------------------------------------
-- Anything that bends the base appetite curve registers here. Each entry
-- returns a scalar; the chain multiplies them together. Keeping this open
-- means extended animal mods can be accommodated without touching the walk.

Demand.foodModifiers = {}

function Demand.addFoodModifier(label, resolver)
    if type(resolver) ~= "function" then return end
    Demand.foodModifiers[#Demand.foodModifiers + 1] = { label = label, resolve = resolver }
end

function Demand.foodModifierScalar(cluster, subType)
    local scalar = 1
    for _, modifier in ipairs(Demand.foodModifiers) do
        local ok, value = pcall(modifier.resolve, cluster, subType)
        if ok then
            local numeric = numberFrom(value, 1)
            if numeric > 0 then scalar = scalar * numeric end
        end
    end
    return scalar
end

-- Can this cluster be at a point in its cycle where it would be lactating?
local function isBreedingAge(cluster, subType)
    local viaGetter = Stores.tryCall(cluster, "getCanReproduce")
    if type(viaGetter) == "boolean" then return viaGetter end

    if subType ~= nil and subType.supportsReproduction == true then
        local minimum = numberFrom(subType.reproductionMinAgeMonth, 0)
        return Demand.ageOf(cluster) >= minimum
    end

    return false
end

-- Lactating animals eat more. Extended animal mods publish a month-by-month
-- table on the sub type, which is more precise than the single live factor
-- carried on the cluster, so prefer it when it is there.
Demand.addFoodModifier("lactation", function(cluster, subType)
    if not NXHerdMeter.extendedAnimalsPresent() then return 1 end

    local schedule = subType ~= nil and subType.lactation or nil

    if type(schedule) ~= "table" then
        if cluster.lactating then return numberFrom(cluster.lactationFactor, 1) end
        return 1
    end

    if cluster.hadABirth ~= true then return 1 end
    if not isBreedingAge(cluster, subType) then return 1 end

    local monthWanted = numberFrom(cluster.monthsSinceLastBirth, 0) + 1
    for _, row in ipairs(schedule) do
        if type(row) == "table" and numberFrom(row.month, -1) == monthWanted then
            return numberFrom(row.food, 1)
        end
    end

    return 1
end)

-- ------------------------------------------------------------
--  Per animal figures
-- ------------------------------------------------------------

-- Litres one animal of this cluster consumes of one input per day.
function Demand.intakePerHead(cluster, intakeKey)
    local subType = Demand.subTypeOf(cluster)
    if subType == nil or type(subType.input) ~= "table" then return 0 end

    local litres = sampleCurve(subType.input[intakeKey], math.max(Demand.ageOf(cluster), 0))
    if litres <= 0 then return 0 end

    if intakeKey == "food" then
        litres = litres * Demand.foodModifierScalar(cluster, subType)
    end

    return litres
end

-- Only some outputs name their fill type (<milk fillType="MILK">). The rest
-- (<manure>, <liquidManure>) take it from the key itself, so fall back to
-- looking the key up as a fill type name.
function Demand.resolveOutputFillType(definition, outputKey)
    if type(definition) == "table" and definition.fillType ~= nil then
        return definition.fillType
    end

    if g_fillTypeManager ~= nil and type(outputKey) == "string" then
        local index = Stores.tryCall(g_fillTypeManager, "getFillTypeIndexByName", string.upper(outputKey))
        if type(index) == "number" then return index end
    end

    return nil
end

-- Litres one animal of this cluster produces of one output per day, plus
-- the fill type that output lands in.
function Demand.yieldPerHead(cluster, outputKey)
    local subType = Demand.subTypeOf(cluster)
    if subType == nil or type(subType.output) ~= "table" then return 0, nil end

    local definition = subType.output[outputKey]
    if definition == nil then return 0, nil end

    local atIndex = math.max(Demand.ageOf(cluster), 0)

    if type(definition) ~= "table" then
        return sampleCurve(definition, atIndex), nil
    end

    local source = definition.curve
    if source == nil then source = definition end

    return sampleCurve(source, atIndex), Demand.resolveOutputFillType(definition, outputKey)
end

-- ------------------------------------------------------------
--  Whole barn survey
-- ------------------------------------------------------------

local function describeFillType(fillTypeIndex, fallbackName)
    if fillTypeIndex ~= nil and g_fillTypeManager ~= nil then
        local title = Stores.tryCall(g_fillTypeManager, "getFillTypeTitleByIndex", fillTypeIndex)
        if type(title) == "string" and title ~= "" then return title end
    end
    return tostring(fallbackName)
end

-- One pass over every cluster in the barn. Returns daily litres for each
-- input, daily litres for each distinct output, and the herd size.
function Demand.survey(husbandry)
    local report = {
        head        = 0,
        daysInMonth = Demand.monthLengthInDays(),
        dailyIntake = {},
        yields      = {},
    }

    for _, key in ipairs(Demand.INTAKE_KEYS) do
        report.dailyIntake[key] = 0
    end

    local herd = Stores.herdOf(husbandry)
    if herd == nil then return report end

    for _, cluster in ipairs(herd) do
        local head = Demand.headCount(cluster)
        local subType = Demand.subTypeOf(cluster)

        if head > 0 and subType ~= nil then
            report.head = report.head + head

            for _, key in ipairs(Demand.INTAKE_KEYS) do
                report.dailyIntake[key] = report.dailyIntake[key] + Demand.intakePerHead(cluster, key) * head
            end

            if type(subType.output) == "table" then
                for outputKey, _ in pairs(subType.output) do
                    local perHead, fillTypeIndex = Demand.yieldPerHead(cluster, outputKey)
                    if perHead > 0 then
                        local bucketKey = fillTypeIndex or ("named:" .. tostring(outputKey))
                        local bucket = report.yields[bucketKey]
                        if bucket == nil then
                            bucket = {
                                perDay     = 0,
                                fillType   = fillTypeIndex,
                                outputName = outputKey,
                                title      = describeFillType(fillTypeIndex, outputKey),
                            }
                            report.yields[bucketKey] = bucket
                        end
                        bucket.perDay = bucket.perDay + perHead * head
                    end
                end
            end
        end
    end

    return report
end
