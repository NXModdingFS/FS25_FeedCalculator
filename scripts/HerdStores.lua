-- HerdStores.lua
-- Everything that answers "what is physically in this barn right now".
-- Nothing in here calculates demand; it only reads levels off the husbandry
-- specialisations and normalises the wildly different shapes they come in.

NXHerdMeter = NXHerdMeter or {}

local Stores = {}
NXHerdMeter.Stores = Stores

-- Specialisation tables we care about, in the order they should be probed.
-- Each entry names the spec field and the tag the rest of the mod uses for it.
Stores.SPEC_TAGS = {
    { spec = "spec_husbandryFood",         tag = "food"   },
    { spec = "spec_husbandryWater",        tag = "water"  },
    { spec = "spec_husbandryStraw",        tag = "straw"  },
    { spec = "spec_husbandryMeadow",       tag = "meadow" },
    { spec = "spec_husbandryMilk",         tag = "milk"   },
    { spec = "spec_husbandryLiquidManure", tag = "slurry" },
    { spec = "spec_husbandryPallets",      tag = "pallet" },
}

-- Calls a method only when the object actually has one, which is the normal
-- case here: husbandry specialisations differ by animal type and by which
-- animal mods are loaded. A missing method returns nil; a method that raises
-- is a real fault and is left to surface in the log.
local function invoke(holder, methodName, ...)
    if type(holder) ~= "table" then return nil end
    local fn = holder[methodName]
    if type(fn) ~= "function" then return nil end
    return fn(holder, ...)
end

Stores.invoke = invoke

-- A husbandry reference can arrive as the placeable itself, as the animals
-- spec table, or as a module handle. Everything downstream wants the placeable,
-- so resolve once and reuse.
function Stores.placeableOf(husbandry)
    if type(husbandry) ~= "table" then return nil end
    if husbandry.owningPlaceable ~= nil then return husbandry.owningPlaceable end
    return husbandry
end

function Stores.specOf(husbandry, specField)
    local placeable = Stores.placeableOf(husbandry)
    if placeable ~= nil and type(placeable[specField]) == "table" then
        return placeable[specField]
    end
    if type(husbandry) == "table" and type(husbandry[specField]) == "table" then
        return husbandry[specField]
    end
    return nil
end

-- Stable identity for caching per barn. Falls back to the table address when
-- the placeable has not been assigned an id yet (very early in loading).
function Stores.identify(husbandry)
    local placeable = Stores.placeableOf(husbandry)
    if placeable ~= nil and placeable.id ~= nil then
        return "husbandry:" .. tostring(placeable.id)
    end
    return "husbandry@" .. tostring(husbandry)
end

-- Animal clusters live in different places depending on which animal mod is
-- driving the barn. Walk the candidates until one yields a list.
function Stores.herdOf(husbandry)
    if type(husbandry) ~= "table" then return nil end

    local placeable = Stores.placeableOf(husbandry)
    local candidates = {
        husbandry,
        husbandry.spec_husbandryAnimals,
        placeable ~= nil and placeable.spec_husbandryAnimals or nil,
        invoke(husbandry, "getModuleByName", "husbandryAnimals"),
    }

    for _, holder in pairs(candidates) do
        if type(holder) == "table" then
            local list = invoke(holder, "getClusters")
            if type(list) == "table" then return list end
            if type(holder.clusters) == "table" then return holder.clusters end
        end
    end

    return nil
end

function Stores.animalTypeIndexOf(husbandry)
    local spec = Stores.specOf(husbandry, "spec_husbandryAnimals")
    if spec ~= nil and spec.animalTypeIndex ~= nil then return spec.animalTypeIndex end

    local foodSpec = Stores.specOf(husbandry, "spec_husbandryFood")
    if foodSpec ~= nil and foodSpec.animalTypeIndex ~= nil then return foodSpec.animalTypeIndex end

    return nil
end

-- =============================================================
--  Grazing (husbandryMeadow)
-- =============================================================
-- The meadow spec keeps a virtual fill level per grazeable fruit type, topped
-- up by the foliage growing inside the fence. Animals draw on it through the
-- same food demand as the trough, which is why it is reported alongside the
-- trough rather than as a separate feed line.

function Stores.hasPasture(husbandry)
    return Stores.specOf(husbandry, "spec_husbandryMeadow") ~= nil
end

-- Litres of standing grass the herd can still eat off the pasture.
function Stores.pastureLiters(husbandry)
    local spec = Stores.specOf(husbandry, "spec_husbandryMeadow")
    if spec == nil or type(spec.fillLevels) ~= "table" then return 0 end

    local total = 0
    for _, level in pairs(spec.fillLevels) do
        if type(level) == "number" and level > 0 then
            total = total + level
        end
    end
    return total
end

-- Grazed feed is weighted differently to a balanced ration; the spec carries
-- the weighting the game applies. Reported for context, never used to alter
-- the litre figures.
function Stores.pastureQuality(husbandry)
    local spec = Stores.specOf(husbandry, "spec_husbandryMeadow")
    if spec == nil then return nil end
    local weight = tonumber(spec.productionWeight)
    if weight ~= nil and weight > 0 then return weight end
    return nil
end

-- =============================================================
--  Trough
-- =============================================================

-- Ask the animal food system which fill types this herd will accept, then let
-- the husbandry report what it holds of each. getAvailableFood is the only
-- reader that also sees pasture stock, so the pasture share is subtracted
-- afterwards to isolate the trough.
local function sumViaFoodGroups(placeable, animalTypeIndex)
    local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if foodSystem == nil or animalTypeIndex == nil then return nil end
    if type(placeable.getAvailableFood) ~= "function" then return nil end

    local recipe = invoke(foodSystem, "getAnimalFood", animalTypeIndex)
    if type(recipe) ~= "table" or type(recipe.groups) ~= "table" then return nil end

    local total, counted = 0, false
    for _, group in pairs(recipe.groups) do
        if type(group) == "table" and type(group.fillTypes) == "table" then
            for _, fillTypeIndex in pairs(group.fillTypes) do
                local available = invoke(placeable, "getAvailableFood", fillTypeIndex)
                if type(available) == "number" and available > 0 then
                    total = total + available
                    counted = true
                end
            end
        end
    end

    if not counted then return nil end
    return total
end

-- Last resort: read the raw fill level tables the food specs expose.
local function sumRawFillLevels(placeable)
    local sources = {
        placeable.spec_husbandryFood,
        placeable.spec_husbandryStorage,
        placeable.storage,
        placeable.foodStorage,
    }

    for _, source in pairs(sources) do
        if type(source) == "table" then
            local total = 0
            if type(source.fillLevels) == "table" then
                for _, level in pairs(source.fillLevels) do
                    if type(level) == "number" and level > 0 then
                        total = total + level
                    end
                end
            elseif type(source.fillLevel) == "number" and source.fillLevel > 0 then
                total = source.fillLevel
            end
            if total > 0 then return total end
        end
    end

    return 0
end

-- Returns trough litres, pasture litres and their sum.
function Stores.feedOnHand(husbandry)
    local placeable = Stores.placeableOf(husbandry)
    if placeable == nil then return 0, 0, 0 end

    local grazing = Stores.pastureLiters(husbandry)
    local combined = sumViaFoodGroups(placeable, Stores.animalTypeIndexOf(husbandry))

    if combined == nil then
        -- Raw tables never include the pasture, so add it back on.
        combined = sumRawFillLevels(placeable) + grazing
    end

    local trough = combined - grazing
    if trough < 0 then trough = 0 end

    return trough, grazing, trough + grazing
end

-- The husbandry keeps its own standing rate per in-game hour for each input.
-- Vanilla fills these from the same age curves, so reading them changes
-- nothing on a stock game. Animal overhaul mods replace the cluster model and
-- rebuild these fields from per-animal figures the curves cannot reproduce --
-- Realistic Livestock multiplies the curve by 1.25 when lactating, by a
-- pregnancy factor, by the animal's genetic metabolism and by its own food
-- scale, then stores the result per hour. Reading the published rate is
-- therefore right on vanilla and right under those mods, with no detection.
--
-- All three fields below are per in-game HOUR, so a day is x24.
Stores.ENGINE_RATES = {
    food  = { spec = "spec_husbandryFood",  field = "litersPerHour"      },
    water = { spec = "spec_husbandryWater", field = "litersPerHour"      },
    straw = { spec = "spec_husbandryStraw", field = "inputLitersPerHour" },
}

function Stores.engineIntakePerHour(husbandry, intakeKey)
    local entry = Stores.ENGINE_RATES[intakeKey]
    if entry == nil then return nil end

    local spec = Stores.specOf(husbandry, entry.spec)
    if spec == nil then return nil end

    -- A zero is meaningful (nothing being drawn), so only a missing field is nil.
    return tonumber(spec[entry.field])
end

function Stores.engineFoodPerHour(husbandry)
    return Stores.engineIntakePerHour(husbandry, "food")
end

-- The same idea for produced goods. Milk and pallets keep a rate per fill type
-- in a table; manure and slurry keep a single rate plus the fill type it lands
-- in. Realistic Livestock rebuilds the manure rate from per-animal output, and
-- waste and wool mods rewrite these fields too, so the published rate is the
-- only figure that reflects whatever is actually loaded.
Stores.ENGINE_YIELDS = {
    { spec = "spec_husbandryStraw",        rate = "outputLitersPerHour", fill = "outputFillType" },
    { spec = "spec_husbandryLiquidManure", rate = "litersPerHour",       fill = "fillType"       },
    { spec = "spec_husbandryMilk",         rate = "litersPerHour",       perFillType = true      },
    { spec = "spec_husbandryPallets",      rate = "litersPerHour",       perFillType = true      },
}

-- Returns { [fillTypeIndex] = litresPerHour }, or nil when nothing published.
function Stores.engineYieldPerHour(husbandry)
    local rates = nil

    local function add(fillTypeIndex, litres)
        local amount = tonumber(litres)
        if fillTypeIndex == nil or amount == nil or amount <= 0 then return end
        rates = rates or {}
        rates[fillTypeIndex] = (rates[fillTypeIndex] or 0) + amount
    end

    for _, entry in ipairs(Stores.ENGINE_YIELDS) do
        local spec = Stores.specOf(husbandry, entry.spec)
        if spec ~= nil then
            local value = spec[entry.rate]

            if entry.perFillType then
                if type(value) == "table" then
                    for fillTypeIndex, litres in pairs(value) do
                        add(fillTypeIndex, litres)
                    end
                end
            else
                add(spec[entry.fill], value)
            end
        end
    end

    return rates
end

-- Diagnostic: every number the food spec carries, so the field holding the
-- real consumption rate can be identified when litersPerHour is not it.
function Stores.describeFoodSpec(husbandry)
    local spec = Stores.specOf(husbandry, "spec_husbandryFood")
    if spec == nil then return "no spec_husbandryFood" end

    local parts = {}
    for key, value in pairs(spec) do
        if type(value) == "number" then
            parts[#parts + 1] = string.format("%s=%g", tostring(key), value)
        end
    end
    table.sort(parts)

    if #parts == 0 then return "spec_husbandryFood carries no numbers" end
    return table.concat(parts, " ")
end

-- Level of a single non-food input (water, straw) in litres, or nil if the
-- barn does not expose one.
function Stores.inputLiters(husbandry, specField)
    local placeable = Stores.placeableOf(husbandry)
    local spec = Stores.specOf(husbandry, specField)
    if placeable == nil or spec == nil then return nil end

    if spec.fillType ~= nil then
        local level = invoke(placeable, "getHusbandryFillLevel", spec.fillType)
        if type(level) == "number" then return level end
    end

    if type(spec.fillLevels) == "table" then
        local total = 0
        for _, level in pairs(spec.fillLevels) do
            if type(level) == "number" and level > 0 then total = total + level end
        end
        return total
    end

    if type(spec.fillLevel) == "number" then return spec.fillLevel end

    return nil
end
-- =============================================================
--  Conditions rows
-- =============================================================
-- Each row in the menu belongs to a husbandry specialisation. Two ways to
-- work out which: the table identity the spec handed the menu, and the fill
-- type title the row is captioned with. The second compares one game string
-- to another game string, so it holds up in every language without ever
-- naming "straw" or "water" in code.

local INFO_FIELDS = { "foodInfo", "info", "conditionInfo", "infoTotal", "fillLevelInfo" }

-- Where each kind of row gets its numbers from.
local ROW_SOURCES = {
    { spec = "spec_husbandryWater",        role = "intake", intakeKey = "water", fills = { "fillType" } },
    { spec = "spec_husbandryStraw",        role = "intake", intakeKey = "straw", fills = { "inputFillType" } },
    { spec = "spec_husbandryStraw",        role = "yield",                       fills = { "outputFillType" } },
    { spec = "spec_husbandryMilk",         role = "yield",                       fills = { "fillTypes" } },
    { spec = "spec_husbandryLiquidManure", role = "yield",                       fills = { "fillType" } },
    { spec = "spec_husbandryPallets",      role = "yield",                       fills = { "fillTypes" } },
    { spec = "spec_husbandryMeadow",       role = "graze",                       fills = {} },
}

function Stores.normaliseLabel(text)
    if type(text) ~= "string" then return "" end
    local lowered = string.lower(text)
    lowered = string.gsub(lowered, "|.*$", "")
    lowered = string.gsub(lowered, "%s+", " ")
    return (string.gsub(lowered, "^%s*(.-)%s*$", "%1"))
end

local function collectFillTypes(spec, fields)
    local set, found = {}, false

    for _, field in ipairs(fields) do
        local value = spec[field]
        if type(value) == "table" then
            for _, index in pairs(value) do
                if type(index) == "number" then
                    set[index] = true
                    found = true
                end
            end
        elseif type(value) == "number" then
            set[value] = true
            found = true
        end
    end

    return set, found
end

local function fillTypeTitle(index)
    if g_fillTypeManager == nil then return nil end
    local title = invoke(g_fillTypeManager, "getFillTypeTitleByIndex", index)
    if type(title) == "string" and title ~= "" then return title end
    return nil
end

-- Returns, per row index, a descriptor saying what that row is and where its
-- figure comes from. Rows we cannot place are simply absent.
function Stores.classifyConditionRows(husbandry, infos)
    local byIndex = {}
    if type(infos) ~= "table" then return byIndex end

    local byTable, byTitle = {}, {}

    for _, source in ipairs(ROW_SOURCES) do
        local spec = Stores.specOf(husbandry, source.spec)
        if spec ~= nil then
            local fills, hasFills = collectFillTypes(spec, source.fills)

            local descriptor = {
                role      = source.role,
                intakeKey = source.intakeKey,
                specField = source.spec,
                fillTypes = fills,
            }

            for _, field in ipairs(INFO_FIELDS) do
                if type(spec[field]) == "table" and byTable[spec[field]] == nil then
                    byTable[spec[field]] = descriptor
                end
            end

            if hasFills then
                for index in pairs(fills) do
                    local key = Stores.normaliseLabel(fillTypeTitle(index))
                    if key ~= "" and byTitle[key] == nil then
                        byTitle[key] = descriptor
                    end
                end
            end
        end
    end

    for index, info in ipairs(infos) do
        if type(info) == "table" then
            -- Title first: one spec can own several rows (straw in, manure
            -- out) and only the fill type tells them apart.
            local hit = byTitle[Stores.normaliseLabel(info.title)]
            if hit == nil then hit = byTable[info] end
            byIndex[index] = hit
        end
    end

    return byIndex
end
