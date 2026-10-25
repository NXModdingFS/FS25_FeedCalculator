-- HerdGovernor.lua
-- Applies the tuning intensity to live husbandry throughput.
--
-- Rather than reproducing what each husbandry specialisation does, every rate
-- field on the relevant spec is scaled, the stock implementation is called,
-- and the fields are put back exactly as they were. The game keeps owning the
-- feeding logic; this only changes the numbers it reads on the way in.
--
-- Server side only: throughput is simulated on the host and replicated.

NXHerdMeter = NXHerdMeter or {}

local Governor = {}
NXHerdMeter.Governor = Governor

-- Which spec field holds the per-hour rate, for each specialisation whose
-- throughput should follow the setting. Fields may be a plain number or a
-- table of numbers keyed by fill type; both are handled.
Governor.TARGETS = {
    {
        id      = "food",
        class   = "PlaceableHusbandryFood",
        method  = "updateFeeding",
        spec    = "spec_husbandryFood",
        rates   = { "litersPerHour" },
    },
    {
        id      = "water",
        class   = "PlaceableHusbandryWater",
        method  = "updateFeeding",
        spec    = "spec_husbandryWater",
        rates   = { "litersPerHour" },
    },
    {
        id      = "straw",
        class   = "PlaceableHusbandryStraw",
        method  = "updateOutput",
        spec    = "spec_husbandryStraw",
        rates   = { "inputLitersPerHour", "outputLitersPerHour" },
    },
    {
        id      = "milk",
        class   = "PlaceableHusbandryMilk",
        method  = "updateOutput",
        spec    = "spec_husbandryMilk",
        rates   = { "litersPerHour" },
    },
    {
        id      = "slurry",
        class   = "PlaceableHusbandryLiquidManure",
        method  = "updateOutput",
        spec    = "spec_husbandryLiquidManure",
        rates   = { "litersPerHour" },
    },
    {
        id      = "pallets",
        class   = "PlaceableHusbandryPallets",
        method  = "updateOutput",
        spec    = "spec_husbandryPallets",
        rates   = { "litersPerHour" },
    },
}

Governor.bound = {}
Governor.pending = {}

-- Returns the factor to apply, or nil when the settings leave vanilla
-- behaviour alone and the stock code should simply run untouched.
local function scalingFactor()
    local tuning = NXHerdMeter.Tuning
    if tuning == nil or type(tuning.intensity) ~= "function" then return nil end
    if tuning:isNeutral() then return nil end
    return tuning:intensity()
end

-- Multiply every named rate field by the factor, returning what is needed to
-- undo it. Non numeric fields are left alone.
local function scaleRates(spec, fieldNames, factor)
    local undo = nil

    for _, fieldName in ipairs(fieldNames) do
        local value = spec[fieldName]

        if type(value) == "number" then
            undo = undo or {}
            undo[#undo + 1] = { field = fieldName, plain = value }
            spec[fieldName] = value * factor

        elseif type(value) == "table" then
            local originals, touched = {}, false
            for key, entry in pairs(value) do
                if type(entry) == "number" then
                    originals[key] = entry
                    value[key] = entry * factor
                    touched = true
                end
            end
            if touched then
                undo = undo or {}
                undo[#undo + 1] = { field = fieldName, keyed = originals }
            end
        end
    end

    return undo
end

local function restoreRates(spec, undo)
    if undo == nil then return end

    for _, record in ipairs(undo) do
        if record.plain ~= nil then
            spec[record.field] = record.plain
        elseif record.keyed ~= nil then
            local target = spec[record.field]
            if type(target) == "table" then
                for key, value in pairs(record.keyed) do
                    target[key] = value
                end
            end
        end
    end
end

-- Wrap one specialisation method. Idempotent: calling twice is a no-op, which
-- matters because installation is attempted both at load and after the mission
-- has finished building its placeable types.
function Governor:bind(target)
    if self.bound[target.id] then return true end

    local class = _G[target.class]
    if type(class) ~= "table" or type(class[target.method]) ~= "function" then
        return false
    end

    local stock = class[target.method]

    class[target.method] = function(placeable, superFunc, ...)
        local spec = type(placeable) == "table" and placeable[target.spec] or nil
        local factor = scalingFactor()

        -- If an earlier call raised part way through, its scaled values are
        -- still on that spec. Put them back before doing anything else, so a
        -- fault elsewhere cannot leave throughput permanently multiplied.
        local unfinished = Governor.pending[target.id]
        if unfinished ~= nil then
            Governor.pending[target.id] = nil
            restoreRates(unfinished.spec, unfinished.undo)
        end

        if spec == nil or placeable.isServer ~= true or factor == nil then
            return stock(placeable, superFunc, ...)
        end

        local undo = scaleRates(spec, target.rates, factor)
        if undo == nil then
            return stock(placeable, superFunc, ...)
        end

        Governor.pending[target.id] = { spec = spec, undo = undo }

        local a, b, c, d = stock(placeable, superFunc, ...)

        Governor.pending[target.id] = nil
        restoreRates(spec, undo)

        return a, b, c, d
    end

    self.bound[target.id] = true
    return true
end

function Governor:bindAll()
    local missed = nil

    for _, target in ipairs(self.TARGETS) do
        if not self:bind(target) then
            missed = missed or {}
            missed[#missed + 1] = target.class .. "." .. target.method
        end
    end

    return missed
end

-- Report anything still unbound once the mission is up, so a broken install is
-- visible in the log instead of silently doing nothing.
function Governor:reportUnbound()
    local missed = self:bindAll()
    if missed == nil then return end

    Logging.warning("[Feed Calculator] throughput scaling unavailable for: %s", table.concat(missed, ", "))
end
