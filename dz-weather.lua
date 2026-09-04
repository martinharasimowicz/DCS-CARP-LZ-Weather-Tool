-- DCS DZ Weather, single-player prototype

local Terrain = require("terrain")

local M_TO_FT = 3.280839895
local MS_TO_KT = 1.943844492
local PA_TO_INHG = 1 / 3386.389
local FLAG_PREFIX = "DZWX_"

local FORM = table.concat({
    "DZ NAME: DZ ALPHA",
    "COORD: N 34 12.345 E 043 16.789",
    "DROP AGL FT: 800",
    "",
    "Press CARP or LZ below."
}, "\n")

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function round(n)
    if n >= 0 then
        return math.floor(n + 0.5)
    end
    return math.ceil(n - 0.5)
end

local function field(body, label)
    local value = body:match("[\r\n]*%s*" .. label .. "%s*:%s*([^\r\n]+)")
    return value and trim(value) or nil
end

local function numberList(s)
    local out = {}
    for token in s:gmatch("%d+%.?%d*") do
        out[#out + 1] = tonumber(token)
    end
    return out
end

local function hemiValue(nums, hemi, maxDegrees)
    if #nums < 1 or #nums > 3 then
        return nil
    end
    local value = nums[1]
    if nums[2] then
        if nums[2] >= 60 then return nil end
        value = value + nums[2] / 60
    end
    if nums[3] then
        if nums[3] >= 60 then return nil end
        value = value + nums[3] / 3600
    end
    if value > maxDegrees then return nil end
    if hemi == "S" or hemi == "W" then value = -value end
    return value
end

local function latLonFromHemispheres(raw)
    local s = raw:upper()
    s = s:gsub("°", " "):gsub("'", " "):gsub('"', " ")
    s = s:gsub(",", " ")

    local latStart, latEnd, latH = s:find("([NS])")
    local lonStart, lonEnd, lonH = s:find("([EW])")
    if not latStart or not lonStart or latStart > lonStart then return nil end

    local latNums = numberList(s:sub(latEnd + 1, lonStart - 1))
    local lonNums = numberList(s:sub(lonEnd + 1))
    local lat = hemiValue(latNums, latH, 90)
    local lon = hemiValue(lonNums, lonH, 180)
    if not lat or not lon then return nil end
    return lat, lon
end

local function latLonFromDecimal(raw)
    local lat, lon = raw:match("^%s*([+-]?%d+%.?%d*)%s*[,;]%s*([+-]?%d+%.?%d*)%s*$")
    lat, lon = tonumber(lat), tonumber(lon)
    if not lat or not lon or math.abs(lat) > 90 or math.abs(lon) > 180 then
        return nil
    end
    return lat, lon
end

local function terrainLatLonToMeters(lat, lon)
    local a, b = Terrain.convertLatLonToMeters(lat, lon)
    if type(a) == "table" then
        return a.x or a[1], a.z or a.y or a[2]
    end
    return a, b
end

local function terrainMgrsToMeters(raw)
    local attempts = {raw, raw:gsub("%s+", "")}
    for _, value in ipairs(attempts) do
        local ok, a, b = pcall(Terrain.convertMGRStoMeters, value)
        if ok and a then
            if type(a) == "table" then
                return a.x or a[1], a.z or a.y or a[2]
            end
            return a, b
        end
    end
    return nil
end

local function parseCoordinate(raw)
    local lat, lon = latLonFromDecimal(raw)
    if not lat then lat, lon = latLonFromHemispheres(raw) end
    if lat then
        local x, z = terrainLatLonToMeters(lat, lon)
        if x and z then return x, z, lat, lon end
    end

    local x, z = terrainMgrsToMeters(raw)
    if x and z then return x, z, nil, nil end
    return nil, nil, nil, nil, "Coordinate format not recognized. Press FORM for examples."
end

local function missionScript(x, z, dropAglFt, includeDrop, requestId)
    local template = [=[
local x, z = %.8f, %.8f
local dropAglFt = %.4f
local includeDrop = %s
local prefix = %q
local requestId = %d
local elev = land.getHeight({x=x, y=z})

local function set(name, value)
    trigger.action.setUserFlag(prefix .. name, math.floor(value + 0.5))
end

local function sampleWind(alt)
    local w = atmosphere.getWind({x=x, y=alt, z=z})
    local speedKt = math.sqrt(w.x*w.x + w.z*w.z) * %.12f
    local toward = math.deg(math.atan2(w.z, w.x))
    local from = (toward + 180) %% 360
    return from, speedKt
end

local function sampleTP(alt)
    local temperatureK, pressurePa = atmosphere.getTemperatureAndPressure({x=x, y=alt, z=z})
    return temperatureK, pressurePa
end

local surfaceDir, surfaceKt = sampleWind(elev + 10)
local surfaceK, qfePa = sampleTP(elev + 2)
local _, qnhPa = sampleTP(0)
local dropMsl = elev + dropAglFt * 0.3048

set("ELEV_CM", elev * 100 + 1000000)
set("SWIND_DEG100", surfaceDir * 100)
set("SWIND_KT100", surfaceKt * 100)
set("STEMP_K100", surfaceK * 100)
set("QFE_PA", qfePa)
set("QNH_PA", qnhPa)
set("DROP_CM", dropMsl * 100 + 1000000)

if includeDrop then
    local dropDir, dropKt = sampleWind(dropMsl)
    local dropK = sampleTP(dropMsl)
    set("DWIND_DEG100", dropDir * 100)
    set("DWIND_KT100", dropKt * 100)
    set("DTEMP_K100", dropK * 100)
end

trigger.action.setUserFlag(prefix .. "READY", requestId)
]=]
    return string.format(template, x, z, dropAglFt, tostring(includeDrop),
        FLAG_PREFIX, requestId, MS_TO_KT)
end

local function runInMission(script)
    local command = string.format("a_do_script(%q)", script)
    local result, err = net.dostring_in("mission", command)
    if not result then
        return nil, err or "DCS rejected the mission-script request"
    end
    return true
end

local function readFlag(name)
    local expression = string.format(
        "return trigger.misc.getUserFlag(%q)", FLAG_PREFIX .. name)
    local value, err = net.dostring_in("server", expression)
    if value == nil then
        value, err = net.dostring_in("mission", expression)
    end
    value = tonumber(value)
    if value == nil then return nil, err end
    return value
end

local function decodeResults(requestId, includeDrop)
    local ready, err = readFlag("READY")
    if ready ~= requestId then
        return nil, err or "Weather result was not returned by the mission state."
    end

    local names = {
        "ELEV_CM", "SWIND_DEG100", "SWIND_KT100", "STEMP_K100",
        "QFE_PA", "QNH_PA", "DROP_CM"
    }
    if includeDrop then
        names[#names + 1] = "DWIND_DEG100"
        names[#names + 1] = "DWIND_KT100"
        names[#names + 1] = "DTEMP_K100"
    end

    local data = {}
    for _, name in ipairs(names) do
        data[name], err = readFlag(name)
        if data[name] == nil then return nil, err or ("Missing result: " .. name) end
    end
    return data
end

local function celsius(k100)
    return k100 / 100 - 273.15
end

local function output(body, mode, name, coord, dropAglFt, data)
    local markerStart = body:find("\n%-%-%- DZ WEATHER %-%-%-")
    if markerStart then
        body = body:sub(1, markerStart - 1)
    end
    local errorStart = body:find("\n\nERROR:")
    if errorStart then
        body = body:sub(1, errorStart - 1)
    end
    body = body:gsub("%s+$", "")

    local elevM = (data.ELEV_CM - 1000000) / 100
    local dropM = (data.DROP_CM - 1000000) / 100
    local surfaceC = celsius(data.STEMP_K100)
    local lines = {
        body,
        "",
        "--- DZ WEATHER ---",
        string.format("TARGET: %s [%s]", name, mode),
        "COORD: " .. coord,
        string.format("TERRAIN: %d ft MSL", round(elevM * M_TO_FT)),
        string.format("SURFACE: %03d T / %.1f kt | %.1f C / %.1f F",
            round(data.SWIND_DEG100 / 100) % 360,
            data.SWIND_KT100 / 100,
            surfaceC, surfaceC * 9 / 5 + 32),
        string.format("PRESSURE: QFE %.2f inHg (%d hPa) | QNH %.2f inHg (%d hPa)",
            data.QFE_PA * PA_TO_INHG, round(data.QFE_PA / 100),
            data.QNH_PA * PA_TO_INHG, round(data.QNH_PA / 100))
    }

    if mode == "CARP" then
        local dropC = celsius(data.DTEMP_K100)
        lines[#lines + 1] = string.format("DROP: %d ft AGL / %d ft MSL",
            round(dropAglFt), round(dropM * M_TO_FT))
        lines[#lines + 1] = string.format("AT DROP: %03d T / %.1f kt | %.1f C / %.1f F",
            round(data.DWIND_DEG100 / 100) % 360,
            data.DWIND_KT100 / 100,
            dropC, dropC * 9 / 5 + 32)
    end
    return table.concat(lines, "\n")
end

local function calculate(text, mode)
    local body = text:getText()
    local name = field(body, "DZ%s+NAME") or "UNNAMED DZ"
    local coord = field(body, "COORD")
    if not coord then
        text:setText(body .. "\n\nERROR: Missing COORD field. Press FORM to reset.")
        return
    end

    local x, z, _, _, parseErr = parseCoordinate(coord)
    if not x or not z then
        text:setText(body .. "\n\nERROR: " .. tostring(parseErr))
        return
    end

    local includeDrop = mode == "CARP"
    local dropAglFt = tonumber(field(body, "DROP%s+AGL%s+FT") or "")
    if includeDrop and (not dropAglFt or dropAglFt < 0 or dropAglFt > 50000) then
        text:setText(body .. "\n\nERROR: DROP AGL FT must be from 0 to 50000.")
        return
    end
    dropAglFt = dropAglFt or 0

    local requestId = math.floor((os.clock() * 1000) % 100000000) + 1
    local ok, err = runInMission(missionScript(x, z, dropAglFt, includeDrop, requestId))
    if not ok then
        text:setText(body .. "\n\nERROR: " .. tostring(err) ..
            "\nStart a single-player mission, then try again.")
        return
    end

    local data
    data, err = decodeResults(requestId, includeDrop)
    if not data then
        text:setText(body .. "\n\nERROR: " .. tostring(err) ..
            "\nSee Scratchpad.log and dcs.log.")
        return
    end

    text:setText(output(body, mode, name, coord, dropAglFt, data))
end

addButton(0, 0, 55, 24, "FORM", function(text)
    text:setText(FORM)
end)

addButton(60, 0, 65, 24, "CARP", function(text)
    local ok, err = pcall(calculate, text, "CARP")
    if not ok then
        log("DZ Weather CARP error: " .. tostring(err))
        text:setText(text:getText() .. "\n\nERROR: " .. tostring(err))
    end
end)

addButton(130, 0, 55, 24, "LZ", function(text)
    local ok, err = pcall(calculate, text, "LZ")
    if not ok then
        log("DZ Weather LZ error: " .. tostring(err))
        text:setText(text:getText() .. "\n\nERROR: " .. tostring(err))
    end
end)
