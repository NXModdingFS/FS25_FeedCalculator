

NXHerdMeter = NXHerdMeter or {}

local Stores  = NXHerdMeter.Stores
local Demand  = NXHerdMeter.Demand
local Readout = {}
NXHerdMeter.Readout = Readout

Readout.installed = false


local function phrase(key, fallback)
    if g_i18n == nil or type(g_i18n.getText) ~= "function" then return fallback end
    local text = g_i18n:getText(key)
    if type(text) == "string" and text ~= "" and text ~= key then return text end
    return fallback
end

Readout.phrase = phrase

local function volume(litres)
    if g_i18n ~= nil and type(g_i18n.formatVolume) == "function" then
        local text = g_i18n:formatVolume(litres, 0)
        if type(text) == "string" and text ~= "" then return text end
    end
    return string.format("%d l", math.floor((litres or 0) + 0.5))
end

-- How long a stock lasts, expressed in whole in-game months and days.
local function span(daysLeft, daysInMonth, stockLitres)
    if daysLeft == nil or daysLeft <= 0 then
        if (stockLitres or 0) > 0 then return phrase("nxhm_span_trace", "<1d") end
        return phrase("nxhm_span_empty", "empty")
    end

    -- With a one day month, "days" and "months" are the same unit; a single
    -- fractional month reads far better than "30m 0d".
    if daysInMonth <= 1 then
        return string.format(phrase("nxhm_span_fraction", "%.1fm"), daysLeft)
    end

    -- Truncate rather than round up: reporting 2.4 days of feed as a full
    -- month would be exactly the wrong direction to be wrong in.
    local months = math.floor(daysLeft / daysInMonth)
    local days   = math.floor(daysLeft - months * daysInMonth)

    if months == 0 and days == 0 then
        return phrase("nxhm_span_trace", "<1d")
    end

    if months > 0 and days > 0 then
        return string.format(phrase("nxhm_span_both", "%dm %dd"), months, days)
    end
    if months > 0 then
        return string.format(phrase("nxhm_span_months", "%dm"), months)
    end
    return string.format(phrase("nxhm_span_days", "%dd"), days)
end

local function daysOfCover(stockLitres, litresPerDay)
    if litresPerDay == nil or litresPerDay <= 0 then return nil end
    return (stockLitres or 0) / litresPerDay
end

-- ------------------------------------------------------------
--  Row text plumbing
-- ------------------------------------------------------------

local function joiner()
    return phrase("nxhm_join", " | ")
end

-- The menu rewrites row text on every refresh, but a redraw can land twice in
-- one frame; strip any suffix already added before appending a fresh one.
local function baseTextOf(element)
    if type(element) ~= "table" or type(element.getText) ~= "function" then return "" end

    local text = element:getText()
    if type(text) ~= "string" then return "" end

    local mark = joiner()
    local cut = string.find(text, mark, 1, true)
    if cut ~= nil then
        return (string.gsub(string.sub(text, 1, cut - 1), "%s+$", ""))
    end

    return text
end

local function appendToRow(element, suffix)
    if type(element) ~= "table" or type(element.setText) ~= "function" then return end
    if suffix == nil or suffix == "" then return end

    local base = baseTextOf(element)
    local composed = base ~= "" and (base .. joiner() .. suffix) or suffix
    element:setText(composed)
end

-- Fallback level reader for rows whose specialisation we could not query.
local function litresFromText(element)
    local text = baseTextOf(element)
    local digits = string.gsub(text, "[^%d]", "")
    return tonumber(digits) or 0
end

-- ------------------------------------------------------------
--  Output rows
-- ------------------------------------------------------------

local function yieldTotalFor(report, fillTypeSet)
    local perDay = 0
    for _, bucket in pairs(report.yields) do
        if bucket.fillType ~= nil and fillTypeSet[bucket.fillType] then
            perDay = perDay + bucket.perDay
        end
    end
    return perDay * report.daysInMonth
end

-- Third party rows carry no spec we know about; fall back to caption matching.
local function yieldByCaption(report, caption)
    local wanted = Stores.normaliseLabel(caption)
    if wanted == "" then return nil end

    for _, bucket in pairs(report.yields) do
        local title = Stores.normaliseLabel(bucket.title)
        if title ~= "" and (title == wanted or string.find(wanted, title, 1, true) ~= nil) then
            return bucket.perDay * report.daysInMonth
        end
    end

    return nil
end

-- ------------------------------------------------------------
--  Panel decoration
-- ------------------------------------------------------------

-- Standing grass on the pasture counts towards the same appetite as the
-- trough, so it is folded into one stock figure. Breaking the two apart made
-- the line long enough for the menu to clip the time remaining off the end.
local function decorateFeedRow(frame, husbandry, report)
    local daily   = report.dailyIntake.food or 0
    local monthly = daily * report.daysInMonth

    local _, _, stocked = Stores.feedOnHand(husbandry)
    local cover = span(daysOfCover(stocked, daily), report.daysInMonth, stocked)

    local line = string.format(
        phrase("nxhm_feed_line", "%s/mo | %s | %s left"),
        volume(monthly), volume(stocked), cover)

    if type(frame.foodRowTotalValue) == "table" and type(frame.foodRowTotalValue.setText) == "function" then
        frame.foodRowTotalValue:setText(line)
    end

    -- The stock game splits the same information across two more labels; with
    -- the combined line in place they would only repeat it.
    for _, field in ipairs({ "foodRowValue", "foodRowFillLevelValue" }) do
        local element = frame[field]
        if type(element) == "table" and type(element.setText) == "function" then
            element:setText("")
        end
    end
end

-- Grazing: the pasture and the trough feed the same appetite, so the honest
-- reading is how long the standing grass alone would carry the herd.
local function grazingSuffix(husbandry, report)
    local daily = report.dailyIntake.food or 0
    if daily <= 0 then return nil end

    local monthly = daily * report.daysInMonth
    local grass = Stores.pastureLiters(husbandry)

    return string.format(
        phrase("nxhm_row_graze", "%s/mo | %s left"),
        volume(monthly),
        span(daysOfCover(grass, daily), report.daysInMonth, grass))
end

local function intakeSuffix(husbandry, report, intakeKey, specField, element)
    local daily = report.dailyIntake[intakeKey] or 0
    if daily <= 0 then return nil end

    local monthly = daily * report.daysInMonth

    local stock = Stores.inputLiters(husbandry, specField)
    if stock == nil then stock = litresFromText(element) end

    return string.format(
        phrase("nxhm_row_intake", "%s/mo | %s left"),
        volume(monthly),
        span(daysOfCover(stock, daily), report.daysInMonth, stock))
end

local function yieldSuffix(report, fillTypes, element)
    local litres = yieldTotalFor(report, fillTypes)

    if litres <= 0 then
        litres = yieldByCaption(report, baseTextOf(element)) or 0
    end

    if litres <= 0 then return nil end

    return string.format(phrase("nxhm_row_yield", "%s/mo"), volume(litres))
end

local function decorateConditionRows(frame, husbandry, report)
    if type(frame.conditionValue) ~= "table" then return end
    if type(husbandry.getConditionInfos) ~= "function" then return end

    local infos = husbandry:getConditionInfos()
    if type(infos) ~= "table" then return end

    local rows = Stores.classifyConditionRows(husbandry, infos)

    for index, info in ipairs(infos) do
        local element = frame.conditionValue[index]

        if type(element) == "table" and type(element.setText) == "function" then
            local row = rows[index]
            local suffix = nil

            if row == nil then
                -- Not a row we recognise; it may still line up with a produce
                -- figure by name, which is how other mods' rows get filled in.
                local litres = yieldByCaption(report, info.title or baseTextOf(element))
                if litres ~= nil and litres > 0 then
                    suffix = string.format(phrase("nxhm_row_yield", "%s/mo"), volume(litres))
                end
            elseif row.role == "graze" then
                suffix = grazingSuffix(husbandry, report)
            elseif row.role == "intake" then
                suffix = intakeSuffix(husbandry, report, row.intakeKey, row.specField, element)
            elseif row.role == "yield" then
                suffix = yieldSuffix(report, row.fillTypes, element)
            end

            appendToRow(element, suffix)
        end
    end
end

-- ------------------------------------------------------------
--  Entry point
-- ------------------------------------------------------------

local function resolveHusbandry(frame, supplied)
    if supplied ~= nil then return supplied end

    for _, field in ipairs({ "husbandry", "selectedHusbandry", "animalHusbandry", "currentHusbandry" }) do
        if frame[field] ~= nil then return frame[field] end
    end

    return Stores.invoke(frame, "getDisplayedHusbandry")
end

function Readout.onHusbandryDisplayed(frame, husbandry)
    local target = resolveHusbandry(frame, husbandry)
    if target == nil then return end

    local report = Demand.survey(target)

    NXHerdMeter.cacheReport(target, report)

    decorateFeedRow(frame, target, report)
    decorateConditionRows(frame, target, report)
end

function Readout:install()
    if self.installed then return end
    if InGameMenuAnimalsFrame == nil then return end
    if type(InGameMenuAnimalsFrame.updateHusbandryDisplay) ~= "function" then return end

    InGameMenuAnimalsFrame.updateHusbandryDisplay = Utils.appendedFunction(
        InGameMenuAnimalsFrame.updateHusbandryDisplay,
        Readout.onHusbandryDisplayed)

    self.installed = true
end
