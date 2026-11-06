-- DCS F10 To Waypoint - local Export.lua bridge.
-- Copyright (c) 2026 FabryAngio. All rights reserved. See LICENSE.
-- Runs only in the user's Export environment; it is not a mission script.

local F10W = {
    version = "1.1.0",
    responsePort = 42081,
    commandPort = 42082,
    actions = {},
    actionIndex = 1,
    nextActionAt = 0,
    specialStartedAt = 0,
    hornetNavigationPhase = nil,
    hornetPreciseToggleSent = false,
    hornetCoordinateMode = nil,
    phantomLastValue = nil,
    phantomLastDistance = nil,
    phantomStep = 0.05,
    viperReturnPressed = false,
    skyhawkPushCommand = nil,
    skyhawkSlewCommand = nil,
    skyhawkSlewDirection = nil,
    skyhawkSlewActive = false,
    skyhawkSlewLastDistance = nil,
    skyhawkSlewLastValue = nil,
    skyhawkConfirmValue = nil,
    skyhawkConfirmStartedAt = 0,
    sequenceId = nil,
    lastCancelledId = nil,
    sequenceDeadline = 0,
    heldControl = nil,
}

local okSocket, socket = pcall(require, "socket")
if not okSocket then
    log.write("F10W", log.ERROR, "LuaSocket unavailable; bridge disabled")
    return
end

local receiver = socket.udp()
local bound, bindError = receiver:setsockname("127.0.0.1", F10W.commandPort)
if not bound then
    log.write("F10W", log.ERROR, "Cannot bind UDP port " .. F10W.commandPort .. ": " .. tostring(bindError))
    return
end
receiver:settimeout(0)
local sender = socket.udp()
sender:settimeout(0)

local previousStart = LuaExportStart
local previousStop = LuaExportStop
local previousBefore = LuaExportBeforeNextFrame
local previousAfter = LuaExportAfterNextFrame

local function safelyCall(name, callback, ...)
    if callback then
        local ok, err = pcall(callback, ...)
        if not ok then log.write("F10W", log.ERROR, name .. ": " .. tostring(err)) end
    end
end

local function send(message, sequenceId)
    sequenceId = sequenceId or F10W.sequenceId
    if not sequenceId then return end
    message = "RSP|" .. sequenceId .. "|" .. message:gsub("^MSG|", "")
    pcall(function() sender:sendto(message, "127.0.0.1", F10W.responsePort) end)
end

local function parseSequence(data)
    local prefix, sequenceId, body = data:match("^(SEQ)|([^|]+)|(.+)$")
    if prefix ~= "SEQ" then return false end
    if not sequenceId:match("^%x%x%x%x%x%x%x%x$") then return false end
    if #F10W.actions > 0 and F10W.actionIndex <= #F10W.actions then
        send("MSG|A transfer is already in progress: wait for it to complete", sequenceId)
        return false
    end
    if sequenceId == F10W.lastCancelledId then
        send("MSG|Sequence cancelled", sequenceId)
        return false
    end
    local parsed = {}
    for token in body:gmatch("[^;]+") do
        local device, command, value, delay = token:match("^(%d+),(%d+),([%d%.%-]+),(%d+)$")
        if not device then
            send("MSG|Sequence " .. sequenceId .. " rejected: invalid format", sequenceId)
            return false
        end
        parsed[#parsed + 1] = {
            device = tonumber(device), command = tonumber(command),
            value = tonumber(value), delay = tonumber(delay)
        }
    end
    if #parsed == 0 or #parsed > 500 then
        send("MSG|Sequence " .. sequenceId .. " rejected: invalid action count", sequenceId)
        return false
    end
    F10W.actions = parsed
    F10W.sequenceId = sequenceId
    F10W.sequenceDeadline = socket.gettime() + 180
    F10W.heldControl = nil
    F10W.actionIndex = 1
    F10W.nextActionAt = socket.gettime()
    F10W.specialStartedAt = 0
    F10W.hornetNavigationPhase = nil
    F10W.hornetPreciseToggleSent = false
    F10W.hornetCoordinateMode = nil
    F10W.phantomLastValue = nil
    F10W.phantomLastDistance = nil
    F10W.phantomStep = 0.05
    F10W.viperReturnPressed = false
    F10W.skyhawkPushCommand = nil
    F10W.skyhawkSlewCommand = nil
    F10W.skyhawkSlewDirection = nil
    F10W.skyhawkSlewActive = false
    F10W.skyhawkSlewLastDistance = nil
    F10W.skyhawkSlewLastValue = nil
    F10W.skyhawkConfirmValue = nil
    F10W.skyhawkConfirmStartedAt = 0
    send("MSG|Sequence " .. sequenceId .. " accepted (" .. #parsed .. " actions)")
    return true
end

local function readHornetWaypointNumber()
    -- F/A-18C device_init.lua assigns indicator 4 to the AMPCD.
    -- Prefer exact element matching so the result does not depend on the
    -- formatting used by list_indication().
    if type(c_indication_txt_equal_to) == "function" then
        for waypoint = 0, 59 do
            local ok, matches = pcall(c_indication_txt_equal_to, 4,
                "WYPT_Page_Number", tostring(waypoint))
            if ok and matches then return waypoint end
        end
    end
    local ok, indication = pcall(list_indication, 4)
    if not ok or type(indication) ~= "string" then return nil end
    local value = indication:match("WYPT_Page_Number[^\r\n]*[\r\n]+%s*([0-9]+)")
        or indication:match("WYPT_Page_Number%s*[:=]?%s*([0-9]+)")
    return value and tonumber(value) or nil
end

local function expandHornetWaypoint(target)
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end

    local current = readHornetWaypointNumber()
    if current == nil then
        if now - F10W.specialStartedAt > 2 then
            return false, "unable to read the Hornet waypoint number on the AMPCD"
        end
        F10W.nextActionAt = now + 0.1
        return true
    end
    if current < 0 or current > 59 then
        return false, "Hornet waypoint number out of range: " .. tostring(current)
    end

    target = math.floor(tonumber(target) or -1)
    if target < 0 or target > 59 then
        return false, "requested Hornet waypoint out of range: " .. tostring(target)
    end
    local upSteps = (target - current) % 60
    local downSteps = (current - target) % 60
    local steps = upSteps
    local command = 3022 -- AMPCD PB12, waypoint up
    if downSteps < upSteps then
        steps = downSteps
        command = 3023 -- AMPCD PB13, waypoint down
    end

    table.remove(F10W.actions, F10W.actionIndex)
    for _ = steps, 1, -1 do
        table.insert(F10W.actions, F10W.actionIndex, { device = 37, command = command, value = 0, delay = 70 })
        table.insert(F10W.actions, F10W.actionIndex, { device = 37, command = command, value = 1, delay = 180 })
    end
    F10W.specialStartedAt = 0
    F10W.nextActionAt = now + 0.05
    return true
end

local function readHornetAmpcd()
    local ok, indication = pcall(list_indication, 4)
    if not ok or type(indication) ~= "string" then return nil end
    return indication
end

local function indicationContains(indication, value)
    return indication and indication:find(value, 1, true) ~= nil
end

local function queueHornetAmpcdPress(command, nextPhase)
    -- Keep the navigation special action in the queue. Insert a normal
    -- press/release pair before it, then inspect the resulting page again.
    table.insert(F10W.actions, F10W.actionIndex,
        { device = 37, command = command, value = 0, delay = 350 })
    table.insert(F10W.actions, F10W.actionIndex,
        { device = 37, command = command, value = 1, delay = 180 })
    F10W.hornetNavigationPhase = nextPhase
end

local function finishHornetNavigation(now)
    table.remove(F10W.actions, F10W.actionIndex)
    F10W.hornetNavigationPhase = nil
    F10W.specialStartedAt = 0
    F10W.nextActionAt = now + 0.1
end

local function navigateHornetWaypointPage()
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then
        F10W.specialStartedAt = now
        F10W.hornetNavigationPhase = "discover"
    end
    local indication = readHornetAmpcd()
    if indicationContains(indication, "WYPT_Latitude") then
        finishHornetNavigation(now)
        return true
    end
    if now - F10W.specialStartedAt > 10 then
        local dump = tostring(indication or "AMPCD unreadable"):gsub("[\r\n]+", " | ")
        if #dump > 800 then dump = dump:sub(1, 800) .. "..." end
        log.write("F10W", log.ERROR, "AMPCD navigation failed. Page: " .. dump)
        return false, "unable to reach HSI DATA WYPT; see dcs.log for details"
    end

    local phase = F10W.hornetNavigationPhase
    local onHsiMain = indicationContains(indication, "WYPT_Page_Number")
    local onDataPage = indicationContains(indication, "AC_Latitude")
        or indicationContains(indication, "Tacal_Latitude")
        or indicationContains(indication, "GPS_CurrentID")
        or indicationContains(indication, "GRID_Zone")
    local onSuptMenu = indicationContains(indication, "CHKLST")
        and indicationContains(indication, "HSI")
    local onTacMenu = indicationContains(indication, "AZ/EL")
        and indicationContains(indication, "STORES")

    if onHsiMain then
        queueHornetAmpcdPress(3020, "wait_data") -- PB10 DATA
    elseif onDataPage then
        queueHornetAmpcdPress(3017, "wait_wypt") -- PB7 WYPT
    elseif onSuptMenu then
        queueHornetAmpcdPress(3012, "wait_hsi") -- PB2 HSI
    elseif onTacMenu then
        queueHornetAmpcdPress(3028, "discover") -- PB18 toggles to SUPT
    elseif phase == "wait_hsi" or phase == "wait_data" or phase == "wait_wypt" then
        F10W.nextActionAt = now + 0.15
    else
        queueHornetAmpcdPress(3028, "discover") -- PB18 MENU
    end
    return true
end

local function readIndicationValue(indication, elementName)
    if type(indication) ~= "string" then return nil end
    for key, value in indication:gmatch("%-+[\r\n]+([^\r\n]+)[\r\n]+([^\r\n]*)") do
        if key == elementName then return value end
    end
    return nil
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function readHornetUfc()
    -- F/A-18C device_init.lua exposes the UFC as indicator 6.
    local ok, indication = pcall(list_indication, 6)
    if not ok or type(indication) ~= "string" then return nil end
    return indication
end

local function findHornetUfcOption(indication, acceptedLabels)
    for index = 1, 5 do
        local value = trim(readIndicationValue(indication, "UFC_OptionDisplay" .. index))
        for _, label in ipairs(acceptedLabels) do
            if value == label then return index end
        end
    end
    return nil
end

local function appendPress(target, device, command, pressDelay, releaseDelay)
    target[#target + 1] = { device = device, command = command, value = 1, delay = pressDelay or 180 }
    target[#target + 1] = { device = device, command = command, value = 0, delay = releaseDelay or 70 }
end

local function replaceSpecialWithActions(actions, nextDelay)
    table.remove(F10W.actions, F10W.actionIndex)
    for index = #actions, 1, -1 do
        table.insert(F10W.actions, F10W.actionIndex, actions[index])
    end
    F10W.specialStartedAt = 0
    F10W.nextActionAt = socket.gettime() + (nextDelay or 0.05)
end

local function ensureHornetPrecise()
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end

    local indication = readHornetAmpcd()
    local latitude = readIndicationValue(indication, "WYPT_Latitude")
    if not latitude then
        if now - F10W.specialStartedAt > 2 then
            return false, "unable to read PRECISE state on the AMPCD"
        end
        F10W.nextActionAt = now + 0.1
        return true
    end

    local _, digitCount = latitude:gsub("%d", "")
    if digitCount >= 8 then
        F10W.hornetCoordinateMode = latitude:find('"', 1, true) and "SEC" or "DCML"
        log.write("F10W", log.INFO, "PRECISE confirmed on WP0; format " .. F10W.hornetCoordinateMode)
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.hornetPreciseToggleSent = false
        F10W.nextActionAt = now + 0.1
        return true
    end

    if not F10W.hornetPreciseToggleSent then
        queueHornetAmpcdPress(3029, nil) -- PB19 PRECISE
        F10W.hornetPreciseToggleSent = true
        return true
    end

    if now - F10W.specialStartedAt > 2 then
        local dump = tostring(indication or "AMPCD unreadable"):gsub("[\r\n]+", " | ")
        log.write("F10W", log.ERROR, "PRECISE verification failed on WP0. AMPCD: " .. dump)
        return false, "unable to enable PRECISE on the AMPCD"
    end
    F10W.nextActionAt = now + 0.1
    return true
end

local function selectHornetPosition()
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end
    local indication = readHornetUfc()
    local option = findHornetUfcOption(indication, { "POSN" })
    if option then
        local actions = {}
        appendPress(actions, 25, 3009 + option, 250, 550)
        replaceSpecialWithActions(actions)
        return true
    end
    if now - F10W.specialStartedAt > 3 then
        local dump = tostring(indication or "UFC unreadable"):gsub("[\r\n]+", " | ")
        log.write("F10W", log.ERROR, "POSN option not found. UFC: " .. dump)
        return false, "POSN option unavailable on the UFC; see dcs.log for details"
    end
    F10W.nextActionAt = now + 0.1
    return true
end

local function formatHornetPreciseCoordinate(coordinate, latitude, secMode)
    local degrees, minutes, firstBlock, fraction
    if secMode then
        local totalHundredths = math.floor(math.abs(coordinate) * 360000 + 0.5)
        degrees = math.floor(totalHundredths / 360000)
        local remainder = totalHundredths % 360000
        minutes = math.floor(remainder / 6000)
        local seconds = math.floor((remainder % 6000) / 100)
        fraction = string.format("%02d", remainder % 100)
        firstBlock = latitude
            and string.format("%02d%02d%02d", degrees, minutes, seconds)
            or string.format("%d%02d%02d", degrees, minutes, seconds)
    else
        local totalTenThousandths = math.floor(math.abs(coordinate) * 600000 + 0.5)
        degrees = math.floor(totalTenThousandths / 600000)
        local remainder = totalTenThousandths % 600000
        minutes = math.floor(remainder / 10000)
        fraction = string.format("%04d", remainder % 10000)
        firstBlock = latitude
            and string.format("%02d%02d", degrees, minutes)
            or string.format("%d%02d", degrees, minutes)
    end
    return firstBlock, fraction
end

local function expandHornetCoordinate(coordinate, latitude)
    if F10W.hornetCoordinateMode ~= "DCML" and F10W.hornetCoordinateMode ~= "SEC" then
        return false, "PRECISE format was not detected before coordinate entry"
    end
    coordinate = tonumber(coordinate)
    if not coordinate or (latitude and math.abs(coordinate) > 90)
        or (not latitude and math.abs(coordinate) > 180) then
        return false, "Hornet coordinate out of range"
    end

    local secMode = F10W.hornetCoordinateMode == "SEC"
    local firstBlock, fraction = formatHornetPreciseCoordinate(coordinate, latitude, secMode)
    local actions = {}
    local hemisphereCommand = coordinate >= 0
        and (latitude and 3020 or 3024)
        or (latitude and 3026 or 3022)
    appendPress(actions, 25, hemisphereCommand, 350, 70)
    for digit in firstBlock:gmatch("%d") do
        local number = tonumber(digit)
        appendPress(actions, 25, number == 0 and 3018 or 3018 + number, 180, 70)
    end
    appendPress(actions, 25, 3029, 250, 500)
    for digit in fraction:gmatch("%d") do
        local number = tonumber(digit)
        appendPress(actions, 25, number == 0 and 3018 or 3018 + number, 180, 70)
    end
    appendPress(actions, 25, 3029, 250, latitude and 700 or 1200)
    replaceSpecialWithActions(actions)
    log.write("F10W", log.INFO, string.format("PRECISE %s coordinate %s: %s + %s",
        latitude and "LAT" or "LON", secMode and "SEC" or "DCML", firstBlock, fraction))
    return true
end

local function verifyHornetElevation(expectedFeet)
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end
    local indication = readHornetAmpcd()
    local displayed = readIndicationValue(indication, "WYPT_Elev")
    local actual = displayed and tonumber(displayed:match("([%-]?%d+)") or "") or nil
    if actual and math.abs(actual - expectedFeet) <= 1 then
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.nextActionAt = now + 0.1
        return true
    end
    if now - F10W.specialStartedAt > 3 then
        return false, string.format("elevation not confirmed: expected %d FT, AMPCD shows %s",
            expectedFeet, tostring(displayed or "no value"))
    end
    F10W.nextActionAt = now + 0.1
    return true
end

local function viperDedIndication()
    local ok, indication = pcall(list_indication, 6)
    return ok and type(indication) == "string" and indication or ""
end

local function ensureViperCniPage()
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end
    local indication = viperDedIndication()
    local onCni = indication:find("System Time", 1, true)
        and indication:find("Steerpoint Use", 1, true)
    if onCni then
        if F10W.viperReturnPressed then
            local device = GetDevice(17)
            if device then pcall(device.performClickableAction, device, 3032, 0) end
        end
        log.write("F10W", log.INFO, "F-16C CNI page confirmed on DED")
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.viperReturnPressed = false
        -- Give the DED enough time to finish drawing and accepting input.  A
        -- page-name match can occur one frame before the selector is ready.
        F10W.nextActionAt = now + 0.35
        return true
    end
    if now - F10W.specialStartedAt > 6 then
        if F10W.viperReturnPressed then
            local device = GetDevice(17)
            if device then pcall(device.performClickableAction, device, 3032, 0) end
        end
        local dump = indication:gsub("[\r\n]+", " | "):sub(1, 800)
        log.write("F10W", log.ERROR, "F-16C CNI page not detected. DED: " .. dump)
        F10W.viperReturnPressed = false
        return false, "F-16C could not return the DED to the CNI page"
    end

    local device = GetDevice(17)
    if not device then return false, "F-16C UFC device unavailable" end
    local value = F10W.viperReturnPressed and 0 or -1
    local ok, err = pcall(device.performClickableAction, device, 3032, value) -- DCS RTN
    if not ok then return false, "F-16C DCS RTN failed: " .. tostring(err) end
    F10W.viperReturnPressed = not F10W.viperReturnPressed
    F10W.nextActionAt = now + (F10W.viperReturnPressed and 0.18 or 0.35)
    return true
end

local function waitForViperSteerpointPage()
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end
    local indication = viperDedIndication()
    local currentSteerpointPage = indication:find("STEERPOINT LABEL", 1, true)
        and indication:find("STPT", 1, true)
        and indication:find("STEERPOINT Latitude", 1, true)
    -- Retain compatibility with DED element names used by older DCS builds.
    local legacySteerpointPage = indication:find("DEST_LAT", 1, true)
        and indication:find("DEST_LON", 1, true)
    if currentSteerpointPage or legacySteerpointPage then
        log.write("F10W", log.INFO, "F-16C STPT page confirmed on DED")
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.nextActionAt = now + 0.35
        return true
    end
    if now - F10W.specialStartedAt > 4 then
        local dump = indication:gsub("[\r\n]+", " | "):sub(1, 800)
        log.write("F10W", log.ERROR, "F-16C STPT page not detected. DED: " .. dump)
        return false, "F-16C STPT page did not open"
    end
    F10W.nextActionAt = now + 0.1
    return true
end

local function readTomcatBuCdnu()
    local ok, indication = pcall(list_indication, 28)
    if not ok or type(indication) ~= "string" then return "", {} end
    local delimiter = "-----------------------------------------"
    local values = {}
    local position = 1
    while true do
        local firstStart, firstEnd = indication:find(delimiter, position, true)
        if not firstStart then break end
        local nextStart = indication:find(delimiter, firstEnd + 1, true)
        if not nextStart then break end
        local block = indication:sub(firstEnd + 1, nextStart - 1)
        block = block:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
        local _, value = block:match("^([^\r\n]+)[\r\n]+(.*)$")
        values[#values + 1] = (value or ""):gsub("[\r\n]+", " ")
        position = nextStart
    end
    local rows = {}
    for row = 1, 8 do rows[row] = values[row + 5] or "" end
    return table.concat(rows, " | "), rows
end

local function waitForTomcatBuPage(command)
    local expected = ({ [9200] = "Flt Pln", [9201] = "Waypt Edit 1/2",
        [9202] = "Waypt Edit 2/2" })[command]
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end
    local display = readTomcatBuCdnu()
    if display:find(expected, 1, true) then
        log.write("F10W", log.INFO, "F-14B(U) CDNU confirmed: " .. expected)
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.nextActionAt = now + 0.15
        return true
    end
    if now - F10W.specialStartedAt > 5 then
        log.write("F10W", log.ERROR, "F-14B(U) CDNU page not detected; expected "
            .. expected .. ", display: " .. display)
        if display == "" then return false, "F-14B(U) CDNU is off or unavailable" end
        return false, "F-14B(U) CDNU did not reach " .. expected
    end
    F10W.nextActionAt = now + 0.1
    return true
end

local function roundedDrum(argument, maximum, inverted)
    local value = math.floor((GetDevice(0):get_argument_value(argument) or 0) * maximum + 0.5)
    if inverted then value = maximum - value end
    return value % maximum
end

local function readPhantomTargetCoordinate(latitude)
    if latitude then
        local negative = (GetDevice(0):get_argument_value(932) or 0) > 0.5
        local degreeTens = roundedDrum(931, 10, negative)
        local degreeOnes = roundedDrum(930, 10, negative)
        local minuteTens = roundedDrum(929, 6, negative)
        local minuteOnes = roundedDrum(928, 10, negative)
        local totalMinutes = (degreeTens * 10 + degreeOnes) * 60 + minuteTens * 10 + minuteOnes
        return negative and -totalMinutes or totalMinutes
    end
    local negative = (GetDevice(0):get_argument_value(934) or 0) > 0.5
    local degreeHundreds = roundedDrum(939, 10, negative)
    local degreeTens = roundedDrum(938, 10, negative)
    local degreeOnes = roundedDrum(937, 10, negative)
    local minuteTens = roundedDrum(936, 6, negative)
    local minuteOnes = roundedDrum(935, 10, negative)
    local totalMinutes = (degreeHundreds * 100 + degreeTens * 10 + degreeOnes) * 60
        + minuteTens * 10 + minuteOnes
    return negative and -totalMinutes or totalMinutes
end

local function shortestPhantomDistance(current, target, latitude)
    local maximum = latitude and (90 * 60) or (180 * 60)
    local span = maximum * 2
    local distance = target - current
    if distance > maximum then distance = distance - span end
    if distance < -maximum then distance = distance + span end
    return distance
end

local function setPhantomTargetCoordinate(coordinate, latitude)
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then
        F10W.specialStartedAt = now
        F10W.phantomLastValue = nil
        F10W.phantomLastDistance = nil
        F10W.phantomStep = 0.05
    end
    coordinate = tonumber(coordinate)
    if not coordinate or (latitude and math.abs(coordinate) > 80)
        or (not latitude and math.abs(coordinate) > 180) then
        return false, "F-4E target coordinate out of range"
    end

    local targetMinutes = coordinate * 60
    local target = targetMinutes >= 0
        and math.floor(targetMinutes + 0.5)
        or math.ceil(targetMinutes - 0.5)
    local current = readPhantomTargetCoordinate(latitude)
    local distance = shortestPhantomDistance(current, target, latitude)
    if distance == 0 then
        log.write("F10W", log.INFO, string.format("F-4E TARGET %s confirmed at %.4f degrees",
            latitude and "LAT" or "LON", coordinate))
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.phantomLastValue = nil
        F10W.phantomLastDistance = nil
        F10W.nextActionAt = now + 0.15
        return true
    end
    if now - F10W.specialStartedAt > 25 then
        return false, string.format("F-4E %s roller did not reach the requested coordinate (remaining %d minutes)",
            latitude and "latitude" or "longitude", distance)
    end

    if F10W.phantomLastValue ~= nil and current == F10W.phantomLastValue then
        F10W.phantomStep = math.min(1, F10W.phantomStep * 2)
    elseif F10W.phantomLastDistance and math.abs(distance) > math.abs(F10W.phantomLastDistance) then
        F10W.phantomStep = math.max(0.001, F10W.phantomStep / 2)
    elseif math.abs(distance) < 10 then
        F10W.phantomStep = math.min(F10W.phantomStep, 0.01)
    end

    local device = GetDevice(16)
    if not device then return false, "F-4E navigation computer device unavailable" end
    local command = latitude and 3008 or 3009
    local ok, err = pcall(function()
        device:performClickableAction(command, distance > 0 and F10W.phantomStep or -F10W.phantomStep)
    end)
    if not ok then return false, "F-4E target roller action failed: " .. tostring(err) end
    F10W.phantomLastValue = current
    F10W.phantomLastDistance = distance
    F10W.nextActionAt = now + 0.08
    return true
end

local function skyhawkDrumDigit(argument)
    local device = GetDevice(0)
    if not device then return nil end
    local value = device:get_argument_value(argument)
    if type(value) ~= "number" then return nil end
    -- The ASN-41 drums roll continuously between digits.  Rounding accepts
    -- the next digit halfway through the animation and can release SLEW one
    -- minute too early.  Floor reads only the fully reached digit.
    return math.floor(value * 10 + 0.0001) % 10
end

local function readSkyhawkDestinationCoordinate(latitude)
    local device = GetDevice(0)
    if not device then return nil end
    if latitude then
        local tens = skyhawkDrumDigit(191)
        local ones = skyhawkDrumDigit(192)
        local tenths = skyhawkDrumDigit(193)
        local hundredths = skyhawkDrumDigit(194)
        if not tens or not ones or not tenths or not hundredths then return nil end
        local encoded = tens * 1000 + ones * 100 + tenths * 10 + hundredths
        local degrees = math.floor(encoded / 100)
        local minutes = encoded % 100
        local value = degrees * 60 + minutes
        -- The A-4E-C cockpit source maps 0.0 to North and 0.5 to South.
        return (device:get_argument_value(195) or 0) > 0.25 and -value or value
    end
    local hundreds = skyhawkDrumDigit(197)
    local tens = skyhawkDrumDigit(198)
    local ones = skyhawkDrumDigit(199)
    local tenths = skyhawkDrumDigit(200)
    local hundredths = skyhawkDrumDigit(201)
    if not hundreds or not tens or not ones or not tenths or not hundredths then return nil end
    local encoded = hundreds * 10000 + tens * 1000 + ones * 100
        + tenths * 10 + hundredths
    local degrees = math.floor(encoded / 100)
    local minutes = encoded % 100
    local value = degrees * 60 + minutes
    -- The longitude flag maps 0.5 to East and 0.0 to West.
    return (device:get_argument_value(202) or 0) > 0.25 and value or -value
end

local function formatSkyhawkCoordinate(totalMinutes, latitude)
    totalMinutes = math.floor(tonumber(totalMinutes) or 0)
    local hemisphere
    if latitude then hemisphere = totalMinutes < 0 and "S" or "N"
    else hemisphere = totalMinutes < 0 and "W" or "E" end
    local absolute = math.abs(totalMinutes)
    local degrees = math.floor(absolute / 60)
    local minutes = absolute % 60
    return string.format(latitude and "%s%02d%02d" or "%s%03d%02d",
        hemisphere, degrees, minutes)
end

local function releaseSkyhawkPush()
    if not F10W.skyhawkPushCommand then return end
    local device = GetDevice(23)
    if device then pcall(device.performClickableAction, device, F10W.skyhawkPushCommand, 0) end
    F10W.skyhawkPushCommand = nil
end

local function setSkyhawkDestinationCoordinate(coordinate, latitude)
    local now = socket.gettime()
    coordinate = tonumber(coordinate)
    if not coordinate or (latitude and math.abs(coordinate) > 90)
        or (not latitude and math.abs(coordinate) > 180) then
        releaseSkyhawkPush()
        return false, "A-4E-C destination coordinate out of range"
    end

    local device = GetDevice(23)
    if not device then return false, "A-4E-C ASN-41 device unavailable" end
    local rotaryCommand = latitude and 3053 or 3054
    local pushCommand = latitude and 3152 or 3153
    if F10W.specialStartedAt == 0 then
        F10W.specialStartedAt = now
        F10W.skyhawkPushCommand = pushCommand
        local ok, err = pcall(device.performClickableAction, device, pushCommand, 1)
        if not ok then
            F10W.skyhawkPushCommand = nil
            return false, "A-4E-C ASN-41 push-to-set failed: " .. tostring(err)
        end
        log.write("F10W", log.INFO, string.format(
            "A-4E-C D1 %s programming started; target %.2f degrees",
            latitude and "LAT" or "LON", coordinate))
    end

    local current = readSkyhawkDestinationCoordinate(latitude)
    if current == nil then
        releaseSkyhawkPush()
        return false, "A-4E-C ASN-41 destination drums are unavailable"
    end
    local target = coordinate >= 0
        and math.floor(coordinate * 100 + 0.5)
        or math.ceil(coordinate * 100 - 0.5)
    local distance = target - current
    if distance == 0 then
        releaseSkyhawkPush()
        log.write("F10W", log.INFO, string.format(
            "A-4E-C D1 %s confirmed at %.2f degrees",
            latitude and "LAT" or "LON", coordinate))
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.nextActionAt = now + 0.15
        return true
    end
    if now - F10W.specialStartedAt > 30 then
        releaseSkyhawkPush()
        return false, string.format(
            "A-4E-C D1 %s did not reach the requested coordinate (current %.2f, target %.2f)",
            latitude and "latitude" or "longitude", current / 100, target / 100)
    end

    -- Each 0.015 command changes the ASN-41 display by exactly 0.01 degree.
    -- Positive longitude knob movement is westing, hence the reversed sign.
    local step = distance > 0 and 0.015 or -0.015
    if not latitude then step = -step end
    local count = math.min(80, math.abs(distance))
    local ok, err = pcall(function()
        -- Alternating with zero is required: avLuaDevice suppresses repeated
        -- identical clickable values inside the same simulation frame.
        for _ = 1, count do
            device:performClickableAction(rotaryCommand, step)
            device:performClickableAction(rotaryCommand, 0)
        end
    end)
    if not ok then
        releaseSkyhawkPush()
        return false, "A-4E-C ASN-41 coordinate knob failed: " .. tostring(err)
    end
    F10W.nextActionAt = now + 0.04
    return true
end

local function releaseSkyhawkSlew()
    if F10W.skyhawkSlewCommand then
        local device = GetDevice(23)
        if device then pcall(device.performClickableAction, device, F10W.skyhawkSlewCommand, 0) end
    end
    F10W.skyhawkSlewCommand = nil
    F10W.skyhawkSlewDirection = nil
    F10W.skyhawkSlewActive = false
end

local function resetSkyhawkSlewState()
    releaseSkyhawkSlew()
    F10W.skyhawkSlewLastDistance = nil
    F10W.skyhawkSlewLastValue = nil
    F10W.skyhawkConfirmValue = nil
    F10W.skyhawkConfirmStartedAt = 0
end

local function setSkyhawkSlewCoordinate(coordinate, latitude, destination)
    local now = socket.gettime()
    destination = math.floor(tonumber(destination) or 1)
    coordinate = tonumber(coordinate)
    if not coordinate or (latitude and math.abs(coordinate) > 90)
        or (not latitude and math.abs(coordinate) > 180) then
        resetSkyhawkSlewState()
        return false, string.format("A-4E-C D%d coordinate out of range", destination)
    end
    if F10W.specialStartedAt == 0 then
        F10W.specialStartedAt = now
        resetSkyhawkSlewState()
        log.write("F10W", log.INFO, string.format(
            "A-4E-C D%d %s slew started; target %.2f degrees",
            destination, latitude and "LAT" or "LON", coordinate))
    end

    local current = readSkyhawkDestinationCoordinate(latitude)
    if current == nil then
        resetSkyhawkSlewState()
        return false, "A-4E-C ASN-41 destination drums are unavailable"
    end
    -- The ASN-41 shows DDMM for latitude and DDDMM for longitude.  Work in
    -- signed whole arc-minutes so 43.875 degrees targets 43 deg 53 min,
    -- never the impossible value 43 deg 88 min.
    local target = coordinate >= 0
        and math.floor(coordinate * 60 + 0.5)
        or math.ceil(coordinate * 60 - 0.5)
    local distance = target - current
    if distance == 0 then
        -- Release the spring-loaded switch, then make sure the mechanical
        -- drums remain on the requested value after they finish rolling.
        if F10W.skyhawkSlewActive then releaseSkyhawkSlew() end
        if F10W.skyhawkConfirmValue ~= current then
            F10W.skyhawkConfirmValue = current
            F10W.skyhawkConfirmStartedAt = now
        end
        if now - F10W.skyhawkConfirmStartedAt < 0.35 then
            F10W.nextActionAt = now + 0.08
            return true
        end
        resetSkyhawkSlewState()
        log.write("F10W", log.INFO, string.format(
            "A-4E-C D%d %s confirmed: %s (source %.6f degrees)",
            destination, latitude and "LAT" or "LON",
            formatSkyhawkCoordinate(current, latitude), coordinate))
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.nextActionAt = now + 0.15
        if F10W.actionIndex > #F10W.actions then send("MSG|Sequence completed") end
        return true
    end
    if now - F10W.specialStartedAt > 60 then
        resetSkyhawkSlewState()
        return false, string.format(
            "A-4E-C D%d %s slew did not reach the requested coordinate (current %s, target %s)",
            destination, latitude and "latitude" or "longitude",
            formatSkyhawkCoordinate(current, latitude),
            formatSkyhawkCoordinate(target, latitude))
    end

    F10W.skyhawkConfirmValue = nil
    F10W.skyhawkConfirmStartedAt = 0
    local desiredDirection = distance > 0 and 1 or -1
    if not latitude then desiredDirection = -desiredDirection end -- positive is westing
    -- Keep the switch held while travelling most of the distance so the
    -- ASN-41's native acceleration can work.  Pulse it only inside the last
    -- few arc-minutes, where the mechanical drums provide safe feedback.
    local nearTarget = math.abs(distance) <= 15
    local crossedTarget = F10W.skyhawkSlewLastDistance
        and distance * F10W.skyhawkSlewLastDistance < 0
    local movingAway = F10W.skyhawkSlewLastDistance
        and math.abs(distance) > math.abs(F10W.skyhawkSlewLastDistance) + 1
    local valueChanged = F10W.skyhawkSlewLastValue ~= nil
        and current ~= F10W.skyhawkSlewLastValue

    if F10W.skyhawkSlewActive and (crossedTarget or movingAway
        or desiredDirection ~= F10W.skyhawkSlewDirection
        or (nearTarget and valueChanged)) then
        releaseSkyhawkSlew()
        F10W.skyhawkSlewLastDistance = distance
        F10W.skyhawkSlewLastValue = current
        F10W.nextActionAt = now + 0.04
        return true
    end

    if not F10W.skyhawkSlewActive then
        local device = GetDevice(23)
        if not device then return false, "A-4E-C ASN-41 device unavailable" end
        local command = latitude and 3166 or 3167
        local ok, err = pcall(device.performClickableAction, device, command, desiredDirection)
        if not ok then
            return false, string.format("A-4E-C D%d slew switch failed: %s",
                destination, tostring(err))
        end
        F10W.skyhawkSlewCommand = command
        F10W.skyhawkSlewDirection = desiredDirection
        F10W.skyhawkSlewActive = true
    end
    F10W.skyhawkSlewLastDistance = distance
    F10W.skyhawkSlewLastValue = current
    F10W.nextActionAt = now + 0.04
    return true
end

local function readBlackhawkWaypointNumber()
    -- list_indication() is zero-based here: ASN-128B is the sixth declared
    -- cockpit indicator and therefore index 5.  Index 6 is the LT clock.
    local ok, indication = pcall(list_indication, 5)
    if not ok or type(indication) ~= "string" then return nil, "" end
    local values = {}
    local delimiter = "-----------------------------------------"
    local position = 1
    while true do
        local firstStart, firstEnd = indication:find(delimiter, position, true)
        if not firstStart then break end
        local nextStart = indication:find(delimiter, firstEnd + 1, true)
        if not nextStart then break end
        local block = indication:sub(firstEnd + 1, nextStart - 1)
        block = block:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
        local _, value = block:match("^([^\r\n]+)[\r\n]+(.*)$")
        value = tostring(value or ""):gsub("[\r\n]+", "")
        if value ~= "" then values[#values + 1] = value end
        position = nextStart
    end
    local value
    for _, text in ipairs(values) do
        -- The generic top line can also begin with the active navigation
        -- waypoint (for example `01:MIZ...`).  ASN128_CURRENT_WP is rendered
        -- later, so retain the last matching line: that is the editable slot.
        local candidate = text:match("^%s*(%d%d):")
        if candidate then value = candidate end
    end
    -- Some mod versions render a line as several anonymous indicator
    -- elements.  Joining their visible values reconstructs `01:NAME`.
    if not value then
        for candidate in table.concat(values):gmatch("(%d%d):") do value = candidate end
    end
    return value and tonumber(value) or nil, indication
end

local function selectBlackhawkWaypoint(target)
    local now = socket.gettime()
    if F10W.specialStartedAt == 0 then F10W.specialStartedAt = now end
    target = math.floor(tonumber(target) or -1)
    if target < 0 or target > 69 then return false, "UH-60L waypoint must be between 00 and 69" end
    local current, indication = readBlackhawkWaypointNumber()
    if current == target then
        log.write("F10W", log.INFO, string.format("UH-60L ASN-128B waypoint %02d selected", target))
        table.remove(F10W.actions, F10W.actionIndex)
        F10W.specialStartedAt = 0
        F10W.nextActionAt = now + 0.15
        return true
    end
    if now - F10W.specialStartedAt > 6 then
        local dump = tostring(indication or ""):gsub("[\r\n]+", " | "):sub(1, 800)
        log.write("F10W", log.ERROR, "UH-60L ASN-128B waypoint read failed: " .. dump)
        if current == nil then
            return false, "UH-60L ASN-128B display is off or the waypoint page is unavailable"
        end
        return false, string.format("UH-60L ASN-128B could not select waypoint %02d", target)
    end
    if current == nil then
        F10W.nextActionAt = now + 0.1
        return true
    end

    local forward = (target - current) % 70
    local command = forward <= 35 and 3249 or 3253
    -- UH-60L 2.1.x moved the ASN-128B from cockpit device 23 to 26.
    local device = GetDevice(26)
    if not device then return false, "UH-60L ASN-128B device unavailable" end
    local okAction, err = pcall(function()
        device:performClickableAction(command, 1)
        device:performClickableAction(command, 0)
    end)
    if not okAction then return false, "UH-60L waypoint selector failed: " .. tostring(err) end
    F10W.nextActionAt = now + 0.1
    return true
end

local function stopSequence()
    releaseSkyhawkPush()
    releaseSkyhawkSlew()
    if F10W.heldControl then
        local control = F10W.heldControl
        pcall(function() GetDevice(control.device):performClickableAction(control.command, 0) end)
        F10W.heldControl = nil
    end
    F10W.actions, F10W.actionIndex, F10W.specialStartedAt = {}, 1, 0
    F10W.hornetNavigationPhase, F10W.viperReturnPressed = nil, false
end

local function pollCommands()
    -- Bounded draining handles a queued cancellation before another frame acts.
    for _ = 1, 16 do
        local data, address = receiver:receivefrom()
        if not data then return end
        if address == "127.0.0.1" then
            local cancelId = data:match("^CANCEL|(%x%x%x%x%x%x%x%x)$")
            if cancelId then
                if cancelId == F10W.sequenceId then stopSequence() end
                -- Remember even an early cancellation, so a late SEQ cannot start it.
                F10W.lastCancelledId = cancelId
                send("MSG|Sequence cancelled", cancelId)
            else
                parseSequence(data)
            end
        end
    end
end

local function runNextAction()
    if F10W.actionIndex > #F10W.actions then return end
    local now = socket.gettime()
    if now > F10W.sequenceDeadline then
        stopSequence()
        send("MSG|Action failed: export safety timeout; sequence stopped")
        return
    end
    if now < F10W.nextActionAt then return end
    local action = F10W.actions[F10W.actionIndex]
    if action.device == 0 and action.command == 9002 then
        local ok, err = navigateHornetWaypointPage()
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.hornetNavigationPhase = nil
        end
        return
    end
    if action.device == 0 and action.command == 9001 then
        local ok, err = expandHornetWaypoint(action.value)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
        end
        return
    end
    if action.device == 0 and action.command == 9003 then
        local ok, err = ensureHornetPrecise()
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.hornetPreciseToggleSent = false
        end
        return
    end
    if action.device == 0 and action.command == 9004 then
        local ok, err = expandHornetCoordinate(action.value, true)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
        end
        return
    end
    if action.device == 0 and action.command == 9005 then
        local ok, err = expandHornetCoordinate(action.value, false)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
        end
        return
    end
    if action.device == 0 and action.command == 9007 then
        local ok, err = verifyHornetElevation(math.floor(action.value + 0.5))
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
        end
        return
    end
    if action.device == 0 and action.command == 9008 then
        local ok, err = selectHornetPosition()
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
        end
        return
    end
    if action.device == 0 and (action.command == 9100 or action.command == 9101) then
        local ok, err
        if action.command == 9100 then
            ok, err = ensureViperCniPage()
        else
            ok, err = waitForViperSteerpointPage()
        end
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.specialStartedAt = 0
            F10W.viperReturnPressed = false
        end
        return
    end
    if action.device == 0 and action.command >= 9200 and action.command <= 9202 then
        local ok, err = waitForTomcatBuPage(action.command)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.specialStartedAt = 0
        end
        return
    end
    if action.device == 0 and (action.command == 9301 or action.command == 9302) then
        local ok, err = setPhantomTargetCoordinate(action.value, action.command == 9301)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.phantomLastValue = nil
            F10W.phantomLastDistance = nil
        end
        return
    end
    if action.device == 0 and (action.command == 9401 or action.command == 9402) then
        local ok, err = setSkyhawkDestinationCoordinate(action.value, action.command == 9401)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            releaseSkyhawkPush()
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.specialStartedAt = 0
        end
        return
    end
    if action.device == 0 and action.command >= 9411 and action.command <= 9422 then
        local latitude = action.command == 9411 or action.command == 9421
        local destination = action.command >= 9420 and 2 or 1
        local ok, err = setSkyhawkSlewCoordinate(action.value, latitude, destination)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            resetSkyhawkSlewState()
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.specialStartedAt = 0
        end
        return
    end
    if action.device == 0 and action.command == 9501 then
        local ok, err = selectBlackhawkWaypoint(action.value)
        if not ok then
            send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
            F10W.actions = {}
            F10W.actionIndex = 1
            F10W.specialStartedAt = 0
        end
        return
    end
    local ok, err = pcall(function()
        local device = GetDevice(action.device)
        if not device then error("device " .. action.device .. " unavailable") end
        device:performClickableAction(action.command, action.value)
        local following = F10W.actions[F10W.actionIndex + 1]
        if following and following.device == action.device and following.command == action.command
            and following.value == 0 and action.value ~= 0 then
            F10W.heldControl = { device = action.device, command = action.command }
        elseif F10W.heldControl and F10W.heldControl.device == action.device
            and F10W.heldControl.command == action.command and action.value == 0 then
            F10W.heldControl = nil
        end
    end)
    if not ok then
        send("MSG|Action " .. F10W.actionIndex .. " failed: " .. tostring(err))
        F10W.actions = {}
        F10W.actionIndex = 1
        return
    end
    F10W.actionIndex = F10W.actionIndex + 1
    F10W.nextActionAt = socket.gettime() + (action.delay / 1000)
    if F10W.actionIndex > #F10W.actions then send("MSG|Sequence completed") end
end

function LuaExportStart()
    safelyCall("upstream LuaExportStart", previousStart)
    log.write("F10W", log.INFO, "DCS F10 To Waypoint " .. F10W.version .. " started")
end

function LuaExportBeforeNextFrame()
    safelyCall("upstream LuaExportBeforeNextFrame", previousBefore)
    pollCommands()
    runNextAction()
end

function LuaExportAfterNextFrame()
    safelyCall("upstream LuaExportAfterNextFrame", previousAfter)
end

function LuaExportStop()
    safelyCall("upstream LuaExportStop", previousStop)
    stopSequence()
    pcall(function() receiver:close() end)
    pcall(function() sender:close() end)
end


