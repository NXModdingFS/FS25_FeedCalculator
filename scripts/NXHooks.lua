-- NXHooks.lua
-- Server-side hooks that scale husbandry inputs (food/water/straw) and
-- outputs (manure/milk/liquidManure/pallets) by the NXScaling multiplier.
-- Each hook is a no-op when the multiplier is ~1.0, deferring to the
-- original game logic in that case.

NXHooks = NXHooks or {}

local function getFactor()
    if NXScaling == nil or type(NXScaling.getScaleFactor) ~= "function" then
        return 1.0
    end
    return NXScaling:getScaleFactor()
end

local function isNoOp(factor)
    return math.abs((factor or 1.0) - 1.0) <= 0.0001
end

local function warn(msg)
    Logging.warning("[NXFC] " .. tostring(msg))
end

-- =====================================================
-- Food
-- =====================================================
function NXHooks:installFoodHook()
    if self.foodInstalled then return true end
    if PlaceableHusbandryFood == nil or type(PlaceableHusbandryFood.updateFeeding) ~= "function" then
        warn("Food hook skipped: PlaceableHusbandryFood.updateFeeding missing")
        return false
    end

    self.foodOrig = PlaceableHusbandryFood.updateFeeding
    PlaceableHusbandryFood.updateFeeding = function(placeable, superFunc)
        local original = NXHooks.foodOrig
        if type(original) ~= "function" then return superFunc(placeable) end

        local factor = getFactor()
        local spec   = placeable ~= nil and placeable.spec_husbandryFood or nil
        local afs    = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
        local env    = g_currentMission ~= nil and g_currentMission.environment or nil

        if placeable == nil or spec == nil or afs == nil or env == nil
           or not placeable.isServer or spec.animalTypeIndex == nil or isNoOp(factor) then
            return original(placeable, superFunc)
        end

        local f = superFunc(placeable)
        local consumed = {}
        local lph = spec.litersPerHour or 0
        local delta = lph * env.timeAdjustment * factor
        f = f * afs:consumeFood(spec.animalTypeIndex, delta, placeable, consumed)
        for ftIdx, d in pairs(consumed) do
            placeable:removeFood(d, ftIdx)
        end
        return f
    end

    self.foodInstalled = true
    return true
end

-- =====================================================
-- Water
-- =====================================================
function NXHooks:installWaterHook()
    if self.waterInstalled then return true end
    if PlaceableHusbandryWater == nil or type(PlaceableHusbandryWater.updateFeeding) ~= "function" then
        warn("Water hook skipped: PlaceableHusbandryWater.updateFeeding missing")
        return false
    end

    self.waterOrig = PlaceableHusbandryWater.updateFeeding
    PlaceableHusbandryWater.updateFeeding = function(placeable, superFunc)
        local original = NXHooks.waterOrig
        if type(original) ~= "function" then return superFunc(placeable) end

        local factor = getFactor()
        local spec   = placeable ~= nil and placeable.spec_husbandryWater or nil
        local env    = g_currentMission ~= nil and g_currentMission.environment or nil

        if placeable == nil or spec == nil or env == nil
           or not placeable.isServer or isNoOp(factor) then
            return original(placeable, superFunc)
        end

        local f = superFunc(placeable)
        local lph = spec.litersPerHour or 0
        if lph <= 0 then return f end

        local delta = lph * env.timeAdjustment * factor
        if delta <= 0 then return f end

        if spec.automaticWaterSupply then
            local ft = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(spec.fillType) or nil
            local pricePerLiter = ft ~= nil and ft.pricePerLiter or 0
            g_currentMission:addMoney(-(delta * pricePerLiter), placeable:getOwnerFarmId(),
                MoneyType.PURCHASE_WATER, false, false)
            return f
        end

        f = f * math.clamp((delta - placeable:removeHusbandryFillLevel(nil, delta, spec.fillType)) / delta, 0, 1)
        return f
    end

    self.waterInstalled = true
    return true
end

-- =====================================================
-- Straw (input) + Manure (output, produced from straw spec)
-- =====================================================
function NXHooks:installStrawHook()
    if self.strawInstalled then return true end
    if PlaceableHusbandryStraw == nil or type(PlaceableHusbandryStraw.updateOutput) ~= "function" then
        warn("Straw hook skipped: PlaceableHusbandryStraw.updateOutput missing")
        return false
    end

    self.strawOrig = PlaceableHusbandryStraw.updateOutput
    PlaceableHusbandryStraw.updateOutput = function(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        local original = NXHooks.strawOrig
        if type(original) ~= "function" then
            return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
        end

        local factor = getFactor()
        local spec   = placeable ~= nil and placeable.spec_husbandryStraw or nil
        local env    = g_currentMission ~= nil and g_currentMission.environment or nil

        if placeable == nil or spec == nil or env == nil
           or not placeable.isServer or isNoOp(factor)
           or spec.inputFillType == nil or spec.outputFillType == nil
           or spec.inputLitersPerHour == nil or spec.outputLitersPerHour == nil
           or spec.inputLitersPerHour <= 0 or spec.isManureActive == nil then
            return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        end

        if spec.isManureActive and type(placeable.getHusbandryIsFillTypeSupported) == "function" then
            if placeable:getHusbandryIsFillTypeSupported(spec.outputFillType) == false then
                return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
            end
        end

        local amount = spec.inputLitersPerHour * env.timeAdjustment * factor
        if amount <= 0 then
            return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
        end

        local delta = amount - placeable:removeHusbandryFillLevel(placeable:getOwnerFarmId(), amount, spec.inputFillType)
        if spec.outputLitersPerHour > 0 and delta > 0 then
            local liters = foodFactor * spec.outputLitersPerHour * (delta / amount) * env.timeAdjustment * factor
            if liters > 0 then
                placeable:addHusbandryFillLevelFromTool(placeable:getOwnerFarmId(), liters, spec.outputFillType, nil, nil, nil)
            end
        end

        if type(placeable.updateStrawPlane) == "function" then
            placeable:updateStrawPlane()
        end

        return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
    end

    self.strawInstalled = true
    return true
end

-- =====================================================
-- Milk
-- =====================================================
function NXHooks:installMilkHook()
    if self.milkInstalled then return true end
    if PlaceableHusbandryMilk == nil or type(PlaceableHusbandryMilk.updateOutput) ~= "function" then
        warn("Milk hook skipped: PlaceableHusbandryMilk.updateOutput missing")
        return false
    end

    self.milkOrig = PlaceableHusbandryMilk.updateOutput
    PlaceableHusbandryMilk.updateOutput = function(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        local original = NXHooks.milkOrig
        if type(original) ~= "function" then
            return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
        end

        local factor = getFactor()
        local spec   = placeable ~= nil and placeable.spec_husbandryMilk or nil
        local env    = g_currentMission ~= nil and g_currentMission.environment or nil

        if placeable == nil or spec == nil or env == nil
           or not placeable.isServer or isNoOp(factor) then
            return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        end

        local hasCustom = false
        if spec.hasMilkProduction and spec.fillTypes ~= nil and #spec.fillTypes > 0 then
            for _, ftIdx in ipairs(spec.fillTypes) do
                local lph = spec.litersPerHour ~= nil and spec.litersPerHour[ftIdx] or 0
                if lph > 0 then
                    placeable:addHusbandryFillLevelFromTool(
                        placeable:getOwnerFarmId(),
                        productionFactor * globalProductionFactor * lph * env.timeAdjustment * factor,
                        ftIdx, nil, nil, nil)
                    hasCustom = true
                end
            end
            if hasCustom then
                return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
            end
        end

        return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
    end

    self.milkInstalled = true
    return true
end

-- =====================================================
-- Liquid manure
-- =====================================================
function NXHooks:installLiquidManureHook()
    if self.liquidManureInstalled then return true end
    if PlaceableHusbandryLiquidManure == nil or type(PlaceableHusbandryLiquidManure.updateOutput) ~= "function" then
        warn("LiquidManure hook skipped: PlaceableHusbandryLiquidManure.updateOutput missing")
        return false
    end

    self.liquidManureOrig = PlaceableHusbandryLiquidManure.updateOutput
    PlaceableHusbandryLiquidManure.updateOutput = function(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        local original = NXHooks.liquidManureOrig
        if type(original) ~= "function" then
            return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
        end

        local factor = getFactor()
        local spec   = placeable ~= nil and placeable.spec_husbandryLiquidManure or nil
        local env    = g_currentMission ~= nil and g_currentMission.environment or nil

        if placeable == nil or spec == nil or env == nil
           or not placeable.isServer or isNoOp(factor) then
            return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        end

        local lph = spec.litersPerHour or 0
        if lph > 0 and spec.fillType ~= nil then
            placeable:addHusbandryFillLevelFromTool(
                placeable:getOwnerFarmId(),
                foodFactor * lph * env.timeAdjustment * factor,
                spec.fillType, nil, nil, nil)
            return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
        end

        return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
    end

    self.liquidManureInstalled = true
    return true
end

-- =====================================================
-- Pallets (eggs, wool, goat milk, etc.)
-- =====================================================
function NXHooks:installPalletHook()
    if self.palletInstalled then return true end
    if PlaceableHusbandryPallets == nil or type(PlaceableHusbandryPallets.updateOutput) ~= "function" then
        warn("Pallet hook skipped: PlaceableHusbandryPallets.updateOutput missing")
        return false
    end

    self.palletOrig = PlaceableHusbandryPallets.updateOutput
    PlaceableHusbandryPallets.updateOutput = function(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        local original = NXHooks.palletOrig
        if type(original) ~= "function" then
            return superFunc(placeable, foodFactor, productionFactor, globalProductionFactor)
        end

        local factor = getFactor()
        local spec   = placeable ~= nil and placeable.spec_husbandryPallets or nil
        local env    = g_currentMission ~= nil and g_currentMission.environment or nil

        if placeable == nil or spec == nil or env == nil
           or not placeable.isServer or isNoOp(factor)
           or spec.fillTypes == nil or spec.pendingLiters == nil then
            return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        end

        -- Temporarily scale litersPerHour, run original, then restore.
        local hasCustom = false
        local saved = {}
        for _, ftIdx in ipairs(spec.fillTypes) do
            local lph = spec.litersPerHour ~= nil and spec.litersPerHour[ftIdx] or nil
            if lph ~= nil then
                saved[ftIdx] = lph
                spec.litersPerHour[ftIdx] = math.max(lph * factor, 0)
                hasCustom = true
            end
        end

        if not hasCustom then
            return original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)
        end

        local r1, r2, r3, r4 = original(placeable, superFunc, foodFactor, productionFactor, globalProductionFactor)

        for ftIdx, lph in pairs(saved) do
            if spec.litersPerHour ~= nil then
                spec.litersPerHour[ftIdx] = lph
            end
        end

        return r1, r2, r3, r4
    end

    self.palletInstalled = true
    return true
end

function NXHooks:installAll()
    self:installFoodHook()
    self:installWaterHook()
    self:installStrawHook()
    self:installMilkHook()
    self:installLiquidManureHook()
    self:installPalletHook()
end
