-- DCS F10 To Waypoint - native DCS point overlay.
-- Copyright (c) 2026 FabryAngio. All rights reserved. See LICENSE.
-- Loaded automatically from Saved Games\DCS\Scripts\Hooks.

local F10W = {
    version = "1.1.0", exportCommandPort = 42082, exportResponsePort = 42081,
    lastUiAttemptAt = -10,
    points = {}, aircraft = "Spectator", playerRole = nil,
    previousAircraft = nil, ui = {},
    transferBusy = false, transferStartedAt = 0, transferTimeout = 90,
    statusKind = "neutral", statusMessage = "READY",
    aircraftReadyAt = math.huge, configuredAircraft = nil,
    capturedPoints = {}, nextPointId = 0, preferredPointId = nil,
    pendingSequenceId = nil, transferPhase = nil, lastCancelAt = 0,
    sessionScope = nil,
    clipboardPrimed = false, lastClipboardText = nil, nextClipboardPollAt = 0,
}

local okSocket, socket = pcall(require, "socket")
local okLfs, lfs = pcall(require, "lfs")
local okTerrain, Terrain = pcall(require, "terrain")
local okGui, Gui = pcall(require, "dxgui")
if not okSocket or not okLfs or not okTerrain then
    log.write("F10W.GUI", log.ERROR, string.format("F10W disabled: socket=%s, lfs=%s, terrain=%s",
        tostring(okSocket), tostring(okLfs), tostring(okTerrain)))
    return
end

local logPath = lfs.writedir() .. [[Logs\F10W.log]]
local function writeLog(level, message)
    log.write("F10W.GUI", level, message)
    pcall(function()
        local file = io.open(logPath, "a")
        if file then
            file:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), message))
            file:close()
        end
    end)
end

local function readClipboardText()
    if not okGui or type(Gui) ~= "table" or type(Gui.GetTextFromClipboard) ~= "function" then
        return nil
    end
    local ok, value = pcall(Gui.GetTextFromClipboard)
    if ok and type(value) == "string" then return value end
    return nil
end

local exportResponseReceiver = socket.udp()
local responseBound, responseBindError = exportResponseReceiver:setsockname("127.0.0.1", F10W.exportResponsePort)
if not responseBound then
    writeLog(log.ERROR, "Export response port unavailable: " .. tostring(responseBindError))
    return
end
exportResponseReceiver:settimeout(0)
local exportSender = socket.udp()
exportSender:settimeout(0)

local aircraftProfiles = {
    ["FA-18C_hornet"] = { family = "hornet", minimum = 1, maximum = 59, noun = "WP" },
    ["F/A-18C"] = { family = "hornet", minimum = 1, maximum = 59, noun = "WP" },
    ["F-16C_50"] = { family = "viper", minimum = 1, maximum = 99, noun = "STPT" },
    ["F-16C"] = { family = "viper", minimum = 1, maximum = 99, noun = "STPT" },
    ["F-14B"] = { family = "tomcat", minimum = 1, maximum = 3, noun = "WP" },
    ["F-14A-95-GR"] = { family = "tomcat", minimum = 1, maximum = 3, noun = "WP" },
    ["F-14A-135-GR-Early"] = { family = "tomcat", minimum = 1, maximum = 3, noun = "WP" },
    ["F-14A-135-GR"] = { family = "tomcat", minimum = 1, maximum = 3, noun = "WP" },
    ["F-14BU"] = { family = "tomcat_bu", minimum = 1, maximum = 3, noun = "FPLN WP" },
    ["F-4E-45MC"] = { family = "phantom", minimum = 1, maximum = 2, noun = "TARGET" },
    ["A-10C"] = { family = "warthog", minimum = 0, maximum = 40, noun = "WP" },
    ["A-10C_2"] = { family = "warthog", minimum = 0, maximum = 40, noun = "WP" },
    ["AH-64D_BLK_II"] = { family = "apache", minimum = 1, maximum = 50, noun = "W" },
    ["AJS37"] = { family = "viggen", minimum = 1, maximum = 9, noun = "B" },
    ["JF-17"] = { family = "thunder", minimum = 1, maximum = 49, noun = "DST" },
    ["M-2000C"] = { family = "mirage2000", minimum = 1, maximum = 20, noun = "PREP" },
    ["Mirage-F1EE"] = { family = "miragef1", minimum = 1, maximum = 9, noun = "WP" },
    ["AV8BNA"] = { family = "harrier", minimum = 1, maximum = 99, noun = "WP" },
    ["F-15ESE"] = { family = "strikeeagle", minimum = 1, maximum = 99, noun = "A" },
    ["UH-60L"] = { family = "blackhawk", minimum = 0, maximum = 69, noun = "WP" },
    ["A-4E-C"] = { family = "skyhawk", minimum = 1, maximum = 2, noun = "DEST" },
}

local function getAircraftProfile(aircraft)
    return aircraftProfiles[aircraft]
end

local function isSupportedAircraft(aircraft)
    return getAircraftProfile(aircraft) ~= nil
end

local function getPlayerRole()
    local ok, result = pcall(function()
        local unitId = DCS.getPlayerUnit()
        if unitId == nil or unitId == "" then return nil end
        for _, slot in ipairs(DCS.getAvailableSlots(DCS.getPlayerCoalition()) or {}) do
            if tostring(slot.unitId) == tostring(unitId) then return slot.role end
        end
    end)
    return ok and result or nil
end

local function press(actions, device, command, delay, afterReleaseDelay)
    actions[#actions + 1] = { device, command, 1, delay or 180 }
    actions[#actions + 1] = { device, command, 0, afterReleaseDelay or 70 }
end

local function pressValue(actions, device, command, value, delay, afterReleaseDelay)
    actions[#actions + 1] = { device, command, value, delay or 180 }
    actions[#actions + 1] = { device, command, 0, afterReleaseDelay or 70 }
end

local function setValue(actions, device, command, value, delay)
    actions[#actions + 1] = { device, command, value, delay or 250 }
end

local function decimalMinutes(coordinate, latitude, decimals)
    local multiplier = 10 ^ decimals
    local total = math.floor(math.abs(coordinate) * 60 * multiplier + 0.5)
    local degrees = math.floor(total / (60 * multiplier))
    local remainder = total % (60 * multiplier)
    local minutes = math.floor(remainder / multiplier)
    local fraction = remainder % multiplier
    local hemisphere = latitude
        and (coordinate >= 0 and "N" or "S")
        or (coordinate >= 0 and "E" or "W")
    return hemisphere, degrees, minutes, fraction
end

local function degreesMinutesSeconds(coordinate, latitude)
    local totalSeconds = math.floor(math.abs(coordinate) * 3600 + 0.5)
    local degrees = math.floor(totalSeconds / 3600)
    local remainder = totalSeconds % 3600
    local minutes = math.floor(remainder / 60)
    local seconds = remainder % 60
    local hemisphere = latitude
        and (coordinate >= 0 and "N" or "S")
        or (coordinate >= 0 and "E" or "W")
    return hemisphere, degrees, minutes, seconds
end

local function appendHornetDigits(actions, digits)
    for digit in digits:gmatch("%d") do
        local number = tonumber(digit)
        press(actions, 25, number == 0 and 3018 or 3018 + number)
    end
end

local function hornetPreciseDecimalMinutes(coordinate, latitude)
    return decimalMinutes(coordinate, latitude, 4)
end

local function hornetCoordinateDescription(point)
    local latHemisphere, latDegrees, latMinutes, latFraction =
        hornetPreciseDecimalMinutes(point.latitude, true)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction =
        hornetPreciseDecimalMinutes(point.longitude, false)
    local elevationMeters = math.floor(point.elevation + 0.5)
    local elevationFeet = math.floor(point.elevation / 0.3048 + 0.5)
    return string.format(
        "%s%02d %02d.%04d / %s%03d %02d.%04d | automatic PRECISE | ELEV %dm/%dft",
        latHemisphere, latDegrees, latMinutes, latFraction,
        lonHemisphere, lonDegrees, lonMinutes, lonFraction,
        elevationMeters, elevationFeet)
end

local function coordinateDescription(point)
    local latHemisphere, latDegrees, latMinutes, latFraction =
        decimalMinutes(point.latitude, true, 4)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction =
        decimalMinutes(point.longitude, false, 4)
    local elevationMeters = math.floor(point.elevation + 0.5)
    local elevationFeet = math.floor(point.elevation / 0.3048 + 0.5)
    return string.format("%s%02d %02d.%04d / %s%03d %02d.%04d | ELEV %dm/%dft",
        latHemisphere, latDegrees, latMinutes, latFraction,
        lonHemisphere, lonDegrees, lonMinutes, lonFraction,
        elevationMeters, elevationFeet)
end

local function appendNumericDigits(actions, device, commandForDigit, digits, delay)
    for digit in tostring(digits):gmatch("%d") do
        press(actions, device, commandForDigit(tonumber(digit)), delay)
    end
end

local function appendViperDigits(actions, digits)
    appendNumericDigits(actions, 17, function(number) return 3002 + number end, digits, 150)
end

local function formatViperCoordinate(coordinate, latitude)
    local hemisphere, degrees, minutes, fraction = decimalMinutes(coordinate, latitude, 3)
    local digits = latitude
        and string.format("%02d%02d%03d", degrees, minutes, fraction)
        or string.format("%03d%02d%03d", degrees, minutes, fraction)
    local hemisphereCommand = ({ N = 3004, S = 3010, E = 3008, W = 3006 })[hemisphere]
    return hemisphereCommand, digits
end

local function buildViper(latitude, longitude, elevation, steerpoint)
    local actions = {}
    actions[#actions + 1] = { 0, 9100, 0, 350 } -- return to and confirm the CNI page
    press(actions, 17, 3006, 250, 650) -- ICP 4/STPT
    actions[#actions + 1] = { 0, 9101, 0, 350 } -- confirm the STPT page before typing
    appendViperDigits(actions, tostring(steerpoint))
    press(actions, 17, 3016, 250, 500) -- ENTR
    -- After confirming the STPT number the DED selection sequence reaches
    -- LAT only after two DCS DOWN movements (the first one selects ELEV).
    pressValue(actions, 17, 3035, -1, 180, 220)
    pressValue(actions, 17, 3035, -1, 180, 350) -- DCS DOWN to LAT

    local latHemisphere, latDigits = formatViperCoordinate(latitude, true)
    press(actions, 17, latHemisphere, 180, 100)
    appendViperDigits(actions, latDigits)
    press(actions, 17, 3016, 250, 600)
    pressValue(actions, 17, 3035, -1, 180, 350) -- DCS DOWN to LNG

    local lonHemisphere, lonDigits = formatViperCoordinate(longitude, false)
    press(actions, 17, lonHemisphere, 180, 100)
    appendViperDigits(actions, lonDigits)
    press(actions, 17, 3016, 250, 600)
    pressValue(actions, 17, 3035, -1, 180, 350) -- DCS DOWN to ELEV

    local elevationFeet = math.floor((elevation or 0) / 0.3048 + 0.5)
    elevationFeet = math.max(0, math.min(32767, elevationFeet))
    appendViperDigits(actions, tostring(elevationFeet))
    press(actions, 17, 3016, 250, 600)

    -- Leave the DED cursor on the steerpoint selector.  Without this reset,
    -- the next transfer starts from ELEV and the waypoint digits are written
    -- into the wrong field even if the STPT page is opened again.
    for _ = 1, 4 do
        pressValue(actions, 17, 3034, 1, 180, 180) -- DCS UP
    end
    return actions
end

local function appendTomcatDigits(actions, digits)
    local commands = { [0] = 3535, [1] = 3536, [2] = 3537, [3] = 3538, [4] = 3539,
        [5] = 3540, [6] = 3541, [7] = 3542, [8] = 3543, [9] = 3544 }
    appendNumericDigits(actions, 24, function(number) return commands[number] end, digits, 150)
end

local function buildTomcat(latitude, longitude, elevation, waypoint)
    local actions = {}
    actions[#actions + 1] = { 24, 3530, 0.6, 600 } -- CAP category TAC DATA
    press(actions, 24, 3517 + waypoint, 220, 500) -- WP1/WP2/WP3

    local latHemisphere, latDegrees, latMinutes, latSeconds = degreesMinutesSeconds(latitude, true)
    press(actions, 24, 3531, 220, 150) -- CLEAR before each new CAP field
    press(actions, 24, 3536, 220, 200) -- LAT
    press(actions, 24, latHemisphere == "N" and 3533 or 3532, 180, 100)
    appendTomcatDigits(actions, string.format("%02d%02d%02d", latDegrees, latMinutes, latSeconds))
    press(actions, 24, 3534, 220, 500) -- ENTER

    local lonHemisphere, lonDegrees, lonMinutes, lonSeconds = degreesMinutesSeconds(longitude, false)
    press(actions, 24, 3531, 220, 150)
    press(actions, 24, 3541, 220, 200) -- LONG
    press(actions, 24, lonHemisphere == "E" and 3533 or 3532, 180, 100)
    appendTomcatDigits(actions, string.format("%03d%02d%02d", lonDegrees, lonMinutes, lonSeconds))
    press(actions, 24, 3534, 220, 500)

    local elevationFeet = math.floor((elevation or 0) / 0.3048 + 0.5)
    if elevationFeet >= 0 and elevationFeet <= 99999 then
        press(actions, 24, 3531, 220, 150)
        press(actions, 24, 3539, 220, 200) -- ALT
        appendTomcatDigits(actions, tostring(elevationFeet))
        press(actions, 24, 3534, 220, 500)
    end
    return actions
end

local function appendTomcatBuCharacter(actions, character)
    local number = tonumber(character)
    if number ~= nil then
        press(actions, 81, 3001 + number, 140)
        return
    end
    if character == "." then
        press(actions, 81, 3049, 140)
        return
    end
    local byte = string.byte(character:upper())
    if byte and byte >= string.byte("A") and byte <= string.byte("Z") then
        press(actions, 81, 3011 + byte - string.byte("A"), 140)
    end
end

local function appendTomcatBuText(actions, value)
    for character in tostring(value):gmatch(".") do
        appendTomcatBuCharacter(actions, character)
    end
end

local function clearTomcatBuScratchpad(actions)
    press(actions, 81, 3054, 900, 180) -- long CLR clears the complete scratchpad
end

local function formatTomcatBuCoordinate(latitude, longitude)
    local latHemisphere, latDegrees, latMinutes, latFraction = decimalMinutes(latitude, true, 3)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction = decimalMinutes(longitude, false, 3)
    return string.format("%s%02d%02d.%03d%s%03d%02d.%03d",
        latHemisphere, latDegrees, latMinutes, latFraction,
        lonHemisphere, lonDegrees, lonMinutes, lonFraction)
end

local function buildTomcatBu(latitude, longitude, elevation, waypoint)
    local actions = {}
    press(actions, 81, 3056, 220, 700) -- CDNU FPLN
    actions[#actions + 1] = { 0, 9200, 0, 250 } -- confirm FPLN page

    -- EXPAND shows the active waypoint on LSK 2. Future waypoints are shown
    -- two per page on LSK 1 and LSK 3.
    local scrollCount = 0
    local waypointLsk = 3061 -- active waypoint: LSK 2
    if waypoint >= 2 then
        scrollCount = math.floor((waypoint - 2) / 2) + 1
        waypointLsk = waypoint % 2 == 0 and 3060 or 3062 -- LSK 1 / LSK 3
    end
    for _ = 1, scrollCount do press(actions, 81, 3046, 180, 350) end
    press(actions, 81, waypointLsk, 220, 700)
    actions[#actions + 1] = { 0, 9201, 0, 250 } -- WP EDIT 1/2

    clearTomcatBuScratchpad(actions)
    appendTomcatBuText(actions, formatTomcatBuCoordinate(latitude, longitude))
    press(actions, 81, 3060, 220, 700) -- LSK 1: load coordinates from scratchpad

    press(actions, 81, 3048, 220, 600) -- RIGHT: WP EDIT 2/2
    actions[#actions + 1] = { 0, 9202, 0, 250 }
    clearTomcatBuScratchpad(actions)
    local elevationFeet = math.floor((elevation or 0) / 0.3048 + 0.5)
    elevationFeet = math.max(0, math.min(99999, elevationFeet))
    appendTomcatBuText(actions, tostring(elevationFeet))
    press(actions, 81, 3063, 220, 600) -- LSK 4: waypoint altitude

    press(actions, 81, 3047, 220, 600) -- LEFT: WP EDIT 1/2
    actions[#actions + 1] = { 0, 9201, 0, 250 }
    press(actions, 81, 3065, 220, 900) -- RSK 2: ENT, commit changes
    return actions
end

local function appendWarthogCharacter(actions, character)
    local number = tonumber(character)
    if number ~= nil then
        local digitCommand = number == 0 and 3024 or 3014 + number
        press(actions, 9, digitCommand, 140)
        return
    end
    local byte = string.byte(character:upper())
    if byte and byte >= string.byte("A") and byte <= string.byte("Z") then
        press(actions, 9, 3027 + byte - string.byte("A"), 140)
    end
end

local function appendWarthogText(actions, value)
    for character in tostring(value):gmatch(".") do appendWarthogCharacter(actions, character) end
end

local function clearWarthogScratchpad(actions)
    press(actions, 9, 3058, 850, 150) -- long CLR clears the complete scratchpad
end

local function formatWarthogCoordinate(coordinate, latitude)
    local hemisphere, degrees, minutes, fraction = decimalMinutes(coordinate, latitude, 3)
    return latitude
        and string.format("%s%02d%02d%03d", hemisphere, degrees, minutes, fraction)
        or string.format("%s%03d%02d%03d", hemisphere, degrees, minutes, fraction)
end

local function buildWarthog(latitude, longitude, elevation, waypoint)
    local actions = {}
    press(actions, 9, 3011, 220, 700) -- WP function key -> WPMENU
    press(actions, 9, 3005, 220, 700) -- LSK 3R -> WAYPOINT page

    clearWarthogScratchpad(actions)
    appendWarthogText(actions, tostring(waypoint))
    press(actions, 9, 3001, 220, 500) -- LSK 3L: select waypoint number

    local elevationFeet = math.floor((elevation or 0) / 0.3048 + 0.5)
    elevationFeet = math.max(0, math.min(32767, elevationFeet))
    clearWarthogScratchpad(actions)
    appendWarthogText(actions, tostring(elevationFeet))
    press(actions, 9, 3002, 220, 500) -- LSK 5L: elevation

    clearWarthogScratchpad(actions)
    appendWarthogText(actions, formatWarthogCoordinate(latitude, true))
    press(actions, 9, 3003, 220, 700) -- LSK 7L: latitude

    clearWarthogScratchpad(actions)
    appendWarthogText(actions, formatWarthogCoordinate(longitude, false))
    press(actions, 9, 3004, 220, 700) -- LSK 9L: longitude
    return actions
end

local function buildPhantom(latitude, longitude, _, target)
    local actions = {
        { 0, 9301, latitude, 250 },
        { 0, 9302, longitude, 250 },
    }
    if target == 1 then
        actions[#actions + 1] = { 16, 3001, 0.5, 500 } -- TARGET 1
    else
        actions[#actions + 1] = { 16, 3001, 1.0, 500 } -- RESET stores current rollers
        actions[#actions + 1] = { 16, 3001, 0.75, 500 } -- TARGET 2
    end
    return actions
end

local function buildHornet(latitude, longitude, elevation, waypoint)
    local actions = {}
    local function ampcd(button) press(actions, 37, 3010 + button, 260) end
    -- Export.lua reads the current AMPCD page and navigates only as needed.
    actions[#actions + 1] = { 0, 9002, 0, 350 }
    -- Read PRECISE on WP0, whose coordinates are initialized, before moving
    -- to a possibly empty destination slot.
    actions[#actions + 1] = { 0, 9001, 0, 350 }
    actions[#actions + 1] = { 0, 9003, 0, 350 } -- ensure PRECISE is boxed
    actions[#actions + 1] = { 0, 9001, waypoint, 350 }
    press(actions, 37, 3015, 300, 650) -- AMPCD PB5 UFC
    actions[#actions + 1] = { 0, 9008, 0, 350 } -- select the real POSN option
    -- Export.lua expands these actions according to the active LATLN format:
    -- DCML uses DDMM + MMMM; SEC uses DDMMSS + SS.
    actions[#actions + 1] = { 0, 9004, latitude, 350 }
    actions[#actions + 1] = { 0, 9005, longitude, 350 }
    -- Enter the terrain elevation after both precise coordinates.
    local elevationFeet = math.floor((elevation or 0) / 0.3048 + 0.5)
    if elevationFeet >= 0 and elevationFeet <= 32808 then
        -- The WYPT UFC menu exported by DCS places ELEV on option 3. Its
        -- elevation sub-menu places FEET on option 1.
        press(actions, 25, 3012, 300, 900) -- UFC option 3 ELEV
        press(actions, 25, 3010, 300, 800) -- UFC option 1 FEET
        appendHornetDigits(actions, tostring(elevationFeet))
        press(actions, 25, 3029, 250, 500)
        actions[#actions + 1] = { 0, 9007, elevationFeet, 350 }
    end
    press(actions, 25, 3028); press(actions, 25, 3028)
    return actions
end

local function appendApacheText(actions, text)
    for character in tostring(text):upper():gmatch(".") do
        local number = tonumber(character)
        if number then
            press(actions, 29, number == 0 and 3043 or 3032 + number, 150)
        else
            local byte = string.byte(character)
            if byte and byte >= string.byte("A") and byte <= string.byte("Z") then
                press(actions, 29, 3007 + byte - string.byte("A"), 150)
            end
        end
    end
end

local function formatApacheCoordinate(coordinate, latitude)
    local hemisphere, degrees, minutes, fraction = decimalMinutes(coordinate, latitude, 2)
    return latitude
        and string.format("%s%02d%02d%02d", hemisphere, degrees, minutes, fraction)
        or string.format("%s%03d%02d%02d", hemisphere, degrees, minutes, fraction)
end

local function buildApache(latitude, longitude, elevation, waypoint, role)
    local actions = {}
    local roleText = tostring(role or ""):lower()
    local cpg = roleText:find("gunner", 1, true) or roleText:find("cpg", 1, true)
    local mpd, ku = cpg and 45 or 43, cpg and 30 or 29
    press(actions, mpd, 3029, 220, 650) -- right MPD: TSD
    press(actions, mpd, 3013, 220, 500) -- B6: POINT

    -- Select an existing database waypoint and edit it.  ADD cannot target a
    -- numbered slot: the Apache always assigns the next free W number, which
    -- is why selecting W01 previously created W08 when W01-W07 existed.
    press(actions, mpd, 3024, 220, 350) -- L1: POINT>
    press(actions, ku, 3001, 220, 180) -- clear the KU
    -- appendApacheText targets the pilot KU. Translate those actions when in CPG.
    local firstTextAction = #actions + 1
    appendApacheText(actions, string.format("W%02d", waypoint))
    for index = firstTextAction, #actions do actions[index][1] = ku end
    press(actions, ku, 3006, 220, 600)
    press(actions, mpd, 3022, 220, 450) -- L3: EDIT
    press(actions, mpd, 3024, 220, 300) -- L1: FREE>
    press(actions, ku, 3006, 220, 350) -- preserve existing free text

    press(actions, ku, 3001, 220, 200) -- clear the KU before coordinates
    firstTextAction = #actions + 1
    appendApacheText(actions, formatApacheCoordinate(latitude, true))
    appendApacheText(actions, formatApacheCoordinate(longitude, false))
    for index = firstTextAction, #actions do actions[index][1] = ku end
    press(actions, ku, 3006, 220, 350)
    press(actions, ku, 3001, 220, 200)
    local elevationFeet = math.max(0, math.min(99999,
        math.floor((elevation or 0) / 0.3048 + 0.5)))
    firstTextAction = #actions + 1
    appendApacheText(actions, tostring(elevationFeet))
    for index = firstTextAction, #actions do actions[index][1] = ku end
    press(actions, ku, 3006, 220, 650)
    return actions
end

local function appendViggenDigits(actions, digits)
    appendNumericDigits(actions, 12, function(number) return 3020 + number end, digits, 160)
end

local function formatViggenCoordinate(coordinate, latitude)
    local _, degrees, minutes, seconds = degreesMinutesSeconds(coordinate, latitude)
    -- CK37 REF/LOLA accepts the displayed DDMMSS representation for both
    -- longitude (LO) and latitude (LA); longitude is entered first.
    return string.format("%02d%02d%02d", degrees, minutes, seconds)
end

local function buildViggen(latitude, longitude, _, waypoint)
    local actions = {}
    setValue(actions, 23, 3009, 0.1, 450) -- data selector: REF/LOLA
    setValue(actions, 23, 3008, 1, 350) -- data input mode: IN
    press(actions, 23, 3001, 220, 180) -- RENSA
    appendViggenDigits(actions, formatViggenCoordinate(longitude, false))
    press(actions, 12, 3010 + waypoint, 220, 400)
    appendViggenDigits(actions, formatViggenCoordinate(latitude, true))
    press(actions, 12, 3010 + waypoint, 220, 550)
    setValue(actions, 23, 3008, 0, 300) -- return to OUT
    return actions
end

local function appendThunderDigits(actions, digits)
    local commands = { [0] = 3224, [1] = 3202, [2] = 3203, [3] = 3204,
        [4] = 3209, [5] = 3210, [6] = 3211, [7] = 3216, [8] = 3217, [9] = 3218 }
    appendNumericDigits(actions, 46, function(number) return commands[number] end, digits, 160)
end

local function formatThunderCoordinate(coordinate, latitude)
    local hemisphere, degrees, minutes, fraction = decimalMinutes(coordinate, latitude, 3)
    local negative = hemisphere == "S" or hemisphere == "W"
    local digits = latitude
        and string.format("%02d%02d%03d", degrees, minutes, fraction)
        or string.format("%03d%02d%03d", degrees, minutes, fraction)
    return (negative and "0" or "") .. digits
end

local function buildThunder(latitude, longitude, _, waypoint)
    local actions = {}
    press(actions, 46, 3209, 220, 450) -- UFCP 4: DST page
    press(actions, 46, 3206, 220, 200) -- R1: destination number
    appendThunderDigits(actions, string.format("%02d", waypoint))
    press(actions, 46, 3206, 220, 450)
    press(actions, 46, 3212, 220, 200) -- L2: latitude
    appendThunderDigits(actions, formatThunderCoordinate(latitude, true))
    press(actions, 46, 3212, 220, 450)
    press(actions, 46, 3219, 220, 200) -- L3: longitude
    appendThunderDigits(actions, formatThunderCoordinate(longitude, false))
    press(actions, 46, 3219, 220, 550)
    return actions
end

local function appendMirage2000Digits(actions, digits)
    appendNumericDigits(actions, 9, function(number) return number == 0 and 3593 or 3583 + number end,
        digits, 150)
end

local function buildMirage2000(latitude, longitude, elevation, waypoint)
    local actions = {}
    -- Synchronize PREP from a known value, then advance to the requested slot.
    for _ = 1, 20 do press(actions, 9, 3111, 120, 45) end
    for _ = 1, waypoint do press(actions, 9, 3110, 120, 45) end
    setValue(actions, 9, 3574, 0.4, 300) -- L/G
    press(actions, 9, 3570, 180, 150)
    press(actions, 9, 3570, 180, 150)
    press(actions, 9, 3584, 180, 120)
    local latHemisphere, latDegrees, latMinutes, latFraction = decimalMinutes(latitude, true, 3)
    press(actions, 9, latHemisphere == "N" and 3585 or 3591, 160, 100)
    appendMirage2000Digits(actions, string.format("%02d%02d%03d", latDegrees, latMinutes, latFraction))
    press(actions, 9, 3596, 200, 350)
    press(actions, 9, 3586, 180, 120)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction = decimalMinutes(longitude, false, 3)
    press(actions, 9, lonHemisphere == "E" and 3589 or 3587, 160, 100)
    appendMirage2000Digits(actions, string.format("%03d%02d%03d", lonDegrees, lonMinutes, lonFraction))
    press(actions, 9, 3596, 200, 350)
    setValue(actions, 9, 3574, 0.3, 300) -- altitude
    press(actions, 9, 3584, 160, 80)
    press(actions, 9, 3584, 160, 100)
    local elevationFeet = math.max(0, math.min(99999,
        math.floor((elevation or 0) / 0.3048 + 0.5)))
    appendMirage2000Digits(actions, tostring(elevationFeet))
    press(actions, 9, 3596, 220, 500)
    return actions
end

local function appendMirageF1Digits(actions, digits)
    appendNumericDigits(actions, 1, function(number) return 3697 + number end, digits, 160)
end

local function buildMirageF1(latitude, longitude, _, waypoint)
    local actions = {}
    setValue(actions, 1, 3692, 0.1, 300) -- INS mode NAV
    setValue(actions, 1, 3690, 0, 250) -- parameter POS
    setValue(actions, 1, 3694, (waypoint - 1) * 0.111, 300)
    local latHemisphere, latDegrees, latMinutes, latFraction = decimalMinutes(latitude, true, 1)
    press(actions, 1, latHemisphere == "N" and 3699 or 3705, 160, 100)
    appendMirageF1Digits(actions, string.format("%02d%02d%01d", latDegrees, latMinutes, latFraction))
    press(actions, 1, 3711, 200, 350)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction = decimalMinutes(longitude, false, 1)
    press(actions, 1, lonHemisphere == "E" and 3703 or 3701, 160, 100)
    appendMirageF1Digits(actions, string.format("%03d%02d%01d", lonDegrees, lonMinutes, lonFraction))
    press(actions, 1, 3711, 220, 450)
    setValue(actions, 1, 3690, 0.2, 250) -- restore PP
    return actions
end

local function appendHarrierDigits(actions, digits)
    local commands = { [0] = 3315, [1] = 3302, [2] = 3303, [3] = 3304,
        [4] = 3306, [5] = 3307, [6] = 3308, [7] = 3310, [8] = 3311, [9] = 3312 }
    appendNumericDigits(actions, 23, function(number) return commands[number] end, digits, 160)
end

local function buildHarrier(latitude, longitude, elevation, waypoint)
    local actions = {}
    press(actions, 12, 3282, 220, 350) -- NAV mode
    press(actions, 26, 3217, 220, 300) -- left MPCD menu
    press(actions, 26, 3201, 220, 350) -- EHSD
    press(actions, 26, 3201, 220, 350) -- DATA
    appendHarrierDigits(actions, string.format("%02d", waypoint))
    press(actions, 23, 3314, 220, 350)
    press(actions, 24, 3251, 220, 200) -- ODU 2: position
    local latHemisphere, latDegrees, latMinutes, latSeconds = degreesMinutesSeconds(latitude, true)
    press(actions, 23, latHemisphere == "N" and 3303 or 3311, 160, 100)
    appendHarrierDigits(actions, string.format("%02d%02d%02d", latDegrees, latMinutes, latSeconds))
    press(actions, 23, 3314, 220, 300)
    local lonHemisphere, lonDegrees, lonMinutes, lonSeconds = degreesMinutesSeconds(longitude, false)
    press(actions, 23, lonHemisphere == "E" and 3308 or 3306, 160, 100)
    appendHarrierDigits(actions, string.format("%03d%02d%02d", lonDegrees, lonMinutes, lonSeconds))
    press(actions, 23, 3314, 220, 350)
    press(actions, 24, 3252, 220, 150) -- ODU 3: elevation
    local elevationFeet = math.max(0, math.min(99999,
        math.floor((elevation or 0) / 0.3048 + 0.5)))
    appendHarrierDigits(actions, tostring(elevationFeet))
    press(actions, 23, 3314, 220, 350)
    press(actions, 24, 3250, 220, 300)
    press(actions, 26, 3201, 220, 450) -- leave DATA
    return actions
end

local function appendStrikeEagleDigits(actions, digits, device)
    local commands = { [0] = 3036, [1] = 3020, [2] = 3021, [3] = 3022,
        [4] = 3025, [5] = 3026, [6] = 3027, [7] = 3030, [8] = 3031, [9] = 3032 }
    appendNumericDigits(actions, device or 56, function(number) return commands[number] end, digits, 160)
end

local function buildStrikeEagle(latitude, longitude, elevation, waypoint, role)
    local actions = {}
    local roleText = tostring(role or ""):lower()
    local device = (roleText:find("wso", 1, true) or roleText:find("rear", 1, true)) and 57 or 56
    press(actions, device, 3035); press(actions, device, 3035); press(actions, device, 3035)
    press(actions, device, 3038, 220, 200) -- MENU
    press(actions, device, 3033, 160, 80); press(actions, device, 3022, 180, 120) -- SHF+B
    press(actions, device, 3010, 180, 120); press(actions, device, 3010, 180, 250)
    appendStrikeEagleDigits(actions, tostring(waypoint), device)
    press(actions, device, 3033, 160, 80); press(actions, device, 3020, 180, 120) -- route A
    press(actions, device, 3001, 200, 180)
    local latHemisphere, latDegrees, latMinutes, latFraction = decimalMinutes(latitude, true, 3)
    press(actions, device, 3033, 160, 80)
    press(actions, device, latHemisphere == "N" and 3021 or 3031, 160, 80)
    appendStrikeEagleDigits(actions, string.format("%02d%02d%03d", latDegrees, latMinutes, latFraction), device)
    press(actions, device, 3002, 220, 250)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction = decimalMinutes(longitude, false, 3)
    press(actions, device, 3033, 160, 80)
    press(actions, device, lonHemisphere == "E" and 3027 or 3025, 160, 80)
    appendStrikeEagleDigits(actions, string.format("%03d%02d%03d", lonDegrees, lonMinutes, lonFraction), device)
    press(actions, device, 3003, 220, 250)
    local elevationFeet = math.max(0, math.min(99999,
        math.floor((elevation or 0) / 0.3048 + 0.5)))
    appendStrikeEagleDigits(actions, tostring(elevationFeet), device)
    press(actions, device, 3007, 220, 350)
    press(actions, device, 3038, 220, 180)
    appendStrikeEagleDigits(actions, tostring(waypoint), device)
    press(actions, device, 3033, 160, 80); press(actions, device, 3020, 180, 100)
    press(actions, device, 3010, 220, 500)
    return actions
end

local blackhawkDigitCommands = {
    [0] = 3255, [1] = 3242, [2] = 3243, [3] = 3244, [4] = 3246,
    [5] = 3247, [6] = 3248, [7] = 3250, [8] = 3251, [9] = 3252,
}

-- UH-60L 2.1.x ASN-128B cockpit device.
local blackhawkDevice = 26

local blackhawkCharacterCommands = {
    A = { 3238, 3242 }, B = { 3239, 3242 }, C = { 3240, 3242 },
    D = { 3238, 3243 }, E = { 3239, 3243 }, F = { 3240, 3243 },
    G = { 3238, 3244 }, H = { 3239, 3244 }, I = { 3240, 3244 },
    J = { 3238, 3246 }, K = { 3239, 3246 }, L = { 3240, 3246 },
    M = { 3238, 3247 }, N = { 3239, 3247 }, O = { 3240, 3247 },
    P = { 3238, 3248 }, Q = { 3239, 3248 }, R = { 3240, 3248 },
    S = { 3238, 3250 }, T = { 3239, 3250 }, U = { 3240, 3250 },
    V = { 3238, 3251 }, W = { 3239, 3251 }, X = { 3240, 3251 },
    Y = { 3238, 3252 }, Z = { 3239, 3252 }, [" "] = { 3239, 3255 },
}

local function appendBlackhawkCharacter(actions, character)
    local digit = tonumber(character)
    if digit then
        press(actions, blackhawkDevice, blackhawkDigitCommands[digit], 120, 55)
        return
    end
    local commands = blackhawkCharacterCommands[character]
    if not commands then return end
    press(actions, blackhawkDevice, commands[1], 120, 55)
    press(actions, blackhawkDevice, commands[2], 120, 55)
end

local function appendBlackhawkText(actions, value)
    for character in tostring(value or ""):gmatch(".") do
        appendBlackhawkCharacter(actions, character)
    end
end

local function formatBlackhawkCoordinate(coordinate, latitude)
    local hemisphere, degrees, minutes, fraction = decimalMinutes(coordinate, latitude, 2)
    local digits = latitude
        and string.format("%02d%02d%02d", degrees, minutes, fraction)
        or string.format("%03d%02d%02d", degrees, minutes, fraction)
    local hemisphereCommand = ({ N = 3247, S = 3250, E = 3243, W = 3251 })[hemisphere]
    return hemisphereCommand, digits
end

local function buildBlackhawk(latitude, longitude, _, waypoint, pointText, pointId)
    local actions = {}
    setValue(actions, blackhawkDevice, 3235, 0.04, 450) -- ASN-128B LAT/LONG mode
    setValue(actions, blackhawkDevice, 3236, 0.05, 450) -- waypoint display

    -- Read the ASN-128B display and select the requested 00-69 slot.  Its
    -- INC/DEC controls wrap, so a blind reset cannot be deterministic.
    actions[#actions + 1] = { 0, 9501, waypoint, 250 }

    local name = tostring(pointText or ""):upper():gsub("[^A-Z0-9 ]", " ")
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 13)
    if name == "" then name = ("F10W " .. tostring(pointId or "")):sub(1, 13) end

    press(actions, blackhawkDevice, 3237, 160, 80) -- KBD: edit waypoint name
    appendBlackhawkText(actions, name)
    press(actions, blackhawkDevice, 3237, 160, 100) -- KBD: latitude field
    local latitudeHemisphere, latitudeDigits = formatBlackhawkCoordinate(latitude, true)
    press(actions, blackhawkDevice, latitudeHemisphere, 140, 60)
    appendBlackhawkText(actions, latitudeDigits)
    press(actions, blackhawkDevice, 3237, 160, 100) -- KBD: longitude field
    local longitudeHemisphere, longitudeDigits = formatBlackhawkCoordinate(longitude, false)
    press(actions, blackhawkDevice, longitudeHemisphere, 140, 60)
    appendBlackhawkText(actions, longitudeDigits)
    press(actions, blackhawkDevice, 3256, 220, 600) -- ENT
    return actions
end

local function buildSkyhawk(latitude, longitude, _, destination)
    local actions = {}
    if destination == 1 then
        setValue(actions, 23, 3047, 0.3, 750) -- select D1 directly
        actions[#actions + 1] = { 0, 9411, latitude, 100 }
        actions[#actions + 1] = { 0, 9412, longitude, 100 }
    else
        setValue(actions, 23, 3047, 0.4, 750)
        actions[#actions + 1] = { 0, 9421, latitude, 100 }
        actions[#actions + 1] = { 0, 9422, longitude, 100 }
    end
    return actions
end

local function buildSequence(aircraft, point, waypoint)
    local profile = getAircraftProfile(aircraft)
    if not profile then return nil, "Unsupported module: " .. tostring(aircraft) end
    if waypoint < profile.minimum or waypoint > profile.maximum then
        return nil, string.format("%s: valid %s range is %d to %d",
            tostring(aircraft), profile.noun, profile.minimum, profile.maximum)
    end
    if profile.family == "hornet" then
        return buildHornet(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "viper" then
        return buildViper(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "tomcat" then
        return buildTomcat(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "tomcat_bu" then
        return buildTomcatBu(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "warthog" then
        return buildWarthog(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "phantom" then
        return buildPhantom(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "apache" then
        return buildApache(point.latitude, point.longitude, point.elevation, waypoint, F10W.playerRole)
    elseif profile.family == "viggen" then
        return buildViggen(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "thunder" then
        return buildThunder(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "mirage2000" then
        return buildMirage2000(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "miragef1" then
        return buildMirageF1(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "harrier" then
        return buildHarrier(point.latitude, point.longitude, point.elevation, waypoint)
    elseif profile.family == "strikeeagle" then
        return buildStrikeEagle(point.latitude, point.longitude, point.elevation, waypoint, F10W.playerRole)
    elseif profile.family == "blackhawk" then
        return buildBlackhawk(point.latitude, point.longitude, point.elevation, waypoint,
            point.text, point.id)
    elseif profile.family == "skyhawk" then
        return buildSkyhawk(point.latitude, point.longitude, point.elevation, waypoint)
    end
    return nil, "Unsupported aircraft family: " .. tostring(profile.family)
end

local function sendSequence(actions)
    local serialized = {}
    for index, action in ipairs(actions) do
        serialized[index] = string.format("%d,%d,%.8f,%d", action[1], action[2], action[3], action[4])
    end
    local id = string.format("%08x", math.floor(DCS.getRealTime() * 1000) % 4294967295)
    local sent, sendError = exportSender:sendto(
        "SEQ|" .. id .. "|" .. table.concat(serialized, ";"),
        "127.0.0.1", F10W.exportCommandPort)
    return sent ~= nil, sendError, id
end

local function setStatus(kind, message)
    kind = kind or "neutral"
    message = tostring(message or "")
    if kind == "error" and not message:find("^ERROR:") then message = "ERROR: " .. message end
    F10W.statusKind = kind
    F10W.statusMessage = message
    writeLog(kind == "error" and log.ERROR or log.INFO, message)
    if F10W.ui.status then
        local skin = F10W.ui.statusSkins and F10W.ui.statusSkins[kind]
        if skin then pcall(F10W.ui.status.setSkin, F10W.ui.status, skin) end
        pcall(F10W.ui.status.setText, F10W.ui.status, message)
    end
end

local function setTransferBusy(busy)
    F10W.transferBusy = busy == true
    F10W.transferStartedAt = F10W.transferBusy and DCS.getRealTime() or 0
    if not F10W.transferBusy then
        F10W.pendingSequenceId, F10W.transferPhase = nil, nil
    end
    if F10W.ui.insertButton then
        pcall(F10W.ui.insertButton.setEnabled, F10W.ui.insertButton, not F10W.transferBusy)
        pcall(F10W.ui.insertButton.setText, F10W.ui.insertButton,
            F10W.transferBusy and "Inserting..." or "Insert")
    end
    for _, name in ipairs({ "removeButton", "pointList",
        "decreaseWaypoint", "increaseWaypoint" }) do
        local widget = F10W.ui[name]
        if widget and widget.setEnabled then pcall(widget.setEnabled, widget, not F10W.transferBusy) end
    end
end

local function shortPointId(id)
    local value = tostring(id or "")
    return #value > 4 and value:sub(1, 4) or value
end

local function coordinateDisplay(point)
    if not point then return "LAT/LON (DDM): --", "Elevation: --" end
    local latHemisphere, latDegrees, latMinutes, latFraction =
        decimalMinutes(point.latitude, true, 4)
    local lonHemisphere, lonDegrees, lonMinutes, lonFraction =
        decimalMinutes(point.longitude, false, 4)
    local elevationMeters = math.floor(point.elevation + 0.5)
    local elevationFeet = math.floor(point.elevation / 0.3048 + 0.5)
    return string.format("LAT/LON (DDM):  %s%02d %02d.%04d    %s%03d %02d.%04d",
            latHemisphere, latDegrees, latMinutes, latFraction,
            lonHemisphere, lonDegrees, lonMinutes, lonFraction),
        string.format("Elevation:     %d m / %d ft", elevationMeters, elevationFeet)
end

local function updateCoordinateDisplay(point)
    local coordinates, elevation = coordinateDisplay(point)
    if F10W.ui.coordinates then
        pcall(F10W.ui.coordinates.setText, F10W.ui.coordinates, coordinates)
    end
    if F10W.ui.elevation then
        pcall(F10W.ui.elevation.setText, F10W.ui.elevation, elevation)
    end
end

local function rebuildPoints()
    F10W.points = {}
    for id, point in pairs(F10W.capturedPoints) do F10W.points[id] = point end
end

local function populatePointList()
    local combo = F10W.ui.pointList
    if not combo then return end
    local previousId
    pcall(function()
        local selected = combo:getSelectedItem()
        previousId = selected and selected.pointId
    end)
    combo:clear()
    local ListBoxItem = require("ListBoxItem")
    local ids = {}
    for id in pairs(F10W.points) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        local ma, mb = F10W.points[a], F10W.points[b]
        local na, nb = tonumber(ma.id), tonumber(mb.id)
        if na and nb and na ~= nb then return na < nb end
        return a < b
    end)
    local selectedItem
    for _, id in ipairs(ids) do
        local point = F10W.points[id]
        local caption = point.text ~= "" and point.text or ("F10 point " .. shortPointId(point.id))
        local item = ListBoxItem.new("[F10 point] " .. caption)
        item.pointId = id
        combo:insertItem(item)
        if not selectedItem then selectedItem = item end
        if id == (F10W.preferredPointId or previousId) then selectedItem = item end
    end
    F10W.preferredPointId = nil
    if selectedItem then combo:selectItem(selectedItem) end
    if selectedItem then
        updateCoordinateDisplay(F10W.points[selectedItem.pointId])
        if not F10W.transferBusy and F10W.statusKind == "neutral" then setStatus("neutral", "READY") end
    else
        updateCoordinateDisplay(nil)
        if not F10W.transferBusy then setStatus("neutral", "Select a point in F10 and press COPY.") end
    end
end

local function capturePoint(point)
    local latitude, longitude = Terrain.convertMetersToLatLon(point.x, point.z)
    if type(latitude) ~= "number" or type(longitude) ~= "number" then error("Invalid map coordinates") end
    local elevation = Terrain.GetHeight(point.x, point.z)
    if type(elevation) ~= "number" then error("Terrain elevation unavailable") end
    -- Reopening the same position should select the existing point, not fill the list.
    local id
    for key, existing in pairs(F10W.capturedPoints) do
        if math.abs(existing.x - point.x) < 0.01 and math.abs(existing.z - point.z) < 0.01 then id = key break end
    end
    if not id then
        local count = 0
        for _ in pairs(F10W.capturedPoints) do count = count + 1 end
        if count >= 200 then error("Point limit reached; remove some captured points") end
        F10W.nextPointId = F10W.nextPointId + 1
        id = "f10:" .. F10W.nextPointId
        F10W.capturedPoints[id] = { id = F10W.nextPointId, source = "f10_point", x = point.x, z = point.z,
            latitude = latitude, longitude = longitude, elevation = elevation,
            text = "Point " .. F10W.nextPointId }
    end
    F10W.preferredPointId = id
    rebuildPoints()
    populatePointList()
    writeLog(log.INFO, string.format("F10 point captured: %s; lat=%.8f lon=%.8f elev=%.2f",
        id, latitude, longitude, elevation))
    setStatus("neutral", "F10 point acquired. Choose the destination waypoint.")
end

local function parseMetricCoordinates(text)
    text = tostring(text or "")
    -- DCS' native coordinate window copies the metric line as, for example,
    -- "X-00270616 Z+00671744".  Accept separators too so that either the
    -- complete COPY block or just that line can be pasted here.
    local x = text:match("[Xx]%s*[:=]?%s*([+-]?%d+%.?%d*)")
    local z = text:match("[Zz]%s*[:=]?%s*([+-]?%d+%.?%d*)")
    x, z = tonumber(x), tonumber(z)
    if not x or not z then
        return nil, "Open F10, use Left Alt + click, then press COPY in the DCS coordinate window"
    end
    if math.abs(x) > 10000000 or math.abs(z) > 10000000 then
        return nil, "The pasted DCS metric coordinates are outside the supported range"
    end
    return { x = x, z = z }
end

local function pollClipboardCapture(now)
    if now < F10W.nextClipboardPollAt then return end
    F10W.nextClipboardPollAt = now + 0.25
    local text = readClipboardText()
    if text == nil then return end
    if not F10W.clipboardPrimed then
        F10W.clipboardPrimed, F10W.lastClipboardText = true, text
        return
    end
    if text == F10W.lastClipboardText then return end
    if F10W.transferBusy or not isSupportedAircraft(F10W.aircraft)
        or F10W.configuredAircraft ~= F10W.aircraft then return end
    F10W.lastClipboardText = text
    local point = parseMetricCoordinates(text)
    if not point then return end
    local ok, captureError = pcall(capturePoint, point)
    if not ok then
        setStatus("error", "Could not import DCS COPY: " .. tostring(captureError))
        return
    end
    setStatus("neutral", "DCS COPY imported automatically.")
end

local function processInsert()
    if F10W.transferBusy then
        setStatus("progress", "INSERTION IN PROGRESS")
        return
    end
    local selected = F10W.ui.pointList and F10W.ui.pointList:getSelectedItem()
    if not selected or not selected.pointId then setStatus("error", "Select an F10 point") return end
    local waypoint = F10W.ui.waypoint and tonumber(F10W.ui.waypoint:getValue())
    if not waypoint or waypoint % 1 ~= 0 then setStatus("error", "Invalid waypoint number") return end
    local point = F10W.points[selected.pointId]
    if not point then setStatus("error", "The selected F10 point no longer exists") return end
    writeLog(log.INFO, string.format(
        "F10 point %s: lat=%.8f lon=%.8f; %s",
        selected.pointId, point.latitude, point.longitude,
        coordinateDescription(point)))
    F10W.playerRole = getPlayerRole()
    if F10W.playerRole then writeLog(log.INFO, "Player role: " .. tostring(F10W.playerRole)) end
    local actions, buildError = buildSequence(F10W.aircraft, point, waypoint)
    if not actions then setStatus("error", buildError) return end
    local trace = {}
    for index, action in ipairs(actions) do
        trace[index] = string.format("%d:%d/%d/%.6f/%d",
            index, action[1], action[2], action[3], action[4])
    end
    writeLog(log.INFO, string.format("Action trace [%s %s%d]: %s",
        tostring(F10W.aircraft),
        tostring((getAircraftProfile(F10W.aircraft) or {}).noun or "WP"), waypoint,
        table.concat(trace, ";")))
    local sent, sendError, sequenceId = sendSequence(actions)
    if not sent then
        setStatus("error", "Failed to send sequence: " .. tostring(sendError))
        return
    end
    F10W.transferTimeout = F10W.aircraft == "A-4E-C" and waypoint == 2 and 170 or 90
    setTransferBusy(true)
    F10W.pendingSequenceId, F10W.transferPhase = sequenceId, "running"
    setStatus("progress", "INSERTION IN PROGRESS")
end

local function hideMainWindow()
    F10W.ui.isOpen = false
    if F10W.ui.main then
        F10W.ui.main:setHasCursor(false)
        F10W.ui.main:setSize(0, 0)
        -- A dxgui window must remain visible to retain its hotkey callback.
        F10W.ui.main:setVisible(true)
    end
end

local function showMainWindow()
    if F10W.ui.main and isSupportedAircraft(F10W.aircraft)
        and DCS.getRealTime() >= F10W.aircraftReadyAt then
        F10W.ui.isOpen = true
        F10W.ui.main:setSize(600, 309)
        F10W.ui.main:setHasCursor(true)
        F10W.ui.main:setVisible(true)
        populatePointList()
    end
end

local function toggleMainWindow()
    if F10W.ui.isOpen then hideMainWindow() else showMainWindow() end
end

local function createUi()
    if F10W.ui.main then return true end
    local Window, Static, Button = require("Window"), require("Static"), require("Button")
    local ComboList, Skin = require("ComboList"), require("Skin")
    local screenWidth = select(1, require("dxgui").GetWindowSize()) or 1920
    local main = Window.new("DCS F10 To Waypoint")
    main:setBounds(math.max(20, screenWidth - 630), 100, 600, 309)
    main:setHasCursor(true)

    local function textSkin(color, size, bold)
        local skin = Skin["staticSkin_ME"]()
        for _, states in pairs(skin.skinData.states or {}) do
            for _, state in pairs(states or {}) do
                if state.text then
                    state.text.color = color
                    state.text.fontSize = size
                    if bold then state.text.font = "DejaVuLGCSansCondensed-Bold.ttf" end
                end
            end
        end
        return skin
    end
    local labelSkin = textSkin("0xd8d8d8ff", 13, false)
    local dataSkin = textSkin("0xffffffff", 14, true)
    local statusSkins = {
        neutral = textSkin("0xd8d8d8ff", 16, true),
        warning = textSkin("0xffc04dff", 15, true),
        progress = textSkin("0xffa500ff", 17, true),
        error = textSkin("0xff4b4bff", 16, true),
        success = textSkin("0x63e66fff", 17, true),
    }

    local aircraftLabel = Static.new("Aircraft: " .. F10W.aircraft)
    aircraftLabel:setSkin(labelSkin); aircraftLabel:setBounds(18, 14, 564, 24); main:insertWidget(aircraftLabel)
    local pointLabel = Static.new("F10 point")
    pointLabel:setSkin(labelSkin); pointLabel:setBounds(18, 49, 120, 24); main:insertWidget(pointLabel)
    local pointList = ComboList.new()
    pointList:setSkin(Skin["comboListSkinNew_"]()); pointList:setBounds(150, 47, 432, 27); main:insertWidget(pointList)
    local profile = getAircraftProfile(F10W.aircraft)
    local waypointLabel = Static.new((profile and profile.noun or "Waypoint") .. " destination")
    waypointLabel:setSkin(labelSkin); waypointLabel:setBounds(18, 86, 150, 24); main:insertWidget(waypointLabel)
    local decreaseWaypoint = Button.new("<")
    decreaseWaypoint:setSkin(Skin["buttonSkin_MENew2"]())
    decreaseWaypoint:setBounds(175, 79, 48, 36); main:insertWidget(decreaseWaypoint)
    local waypointValueSkin = textSkin("0xffffffff", 18, true)
    for _, states in pairs(waypointValueSkin.skinData.states or {}) do
        for _, state in pairs(states or {}) do
            if state.text and state.text.horzAlign then state.text.horzAlign.type = "middle" end
        end
    end
    local waypointValue = Static.new("1")
    waypointValue:setSkin(waypointValueSkin)
    waypointValue:setBounds(229, 84, 72, 30); main:insertWidget(waypointValue)
    local increaseWaypoint = Button.new(">")
    increaseWaypoint:setSkin(Skin["buttonSkin_MENew2"]())
    increaseWaypoint:setBounds(307, 79, 48, 36); main:insertWidget(increaseWaypoint)
    local waypoint = {
        minimum = profile and profile.minimum or 1,
        maximum = profile and profile.maximum or 59,
        value = profile and profile.minimum or 1,
    }
    function waypoint:getValue() return self.value end
    function waypoint:setRange(minimum, maximum)
        self.minimum, self.maximum = minimum, maximum
        self:setValue(self.value)
    end
    function waypoint:setValue(value)
        value = math.floor(tonumber(value) or self.minimum)
        self.value = math.max(self.minimum, math.min(self.maximum, value))
        waypointValue:setText(tostring(self.value))
    end
    decreaseWaypoint.onChange = function() waypoint:setValue(waypoint:getValue() - 1) end
    increaseWaypoint.onChange = function() waypoint:setValue(waypoint:getValue() + 1) end
    waypoint:setValue(waypoint.value)
    local insertButton = Button.new("Insert")
    insertButton:setSkin(Skin["buttonSkin_MENew2"]()); insertButton:setBounds(375, 79, 207, 36); main:insertWidget(insertButton)
    local hideButton = Button.new("Hide")
    hideButton:setSkin(Skin["buttonSkin_MENew2"]()); hideButton:setBounds(18, 124, 270, 29); main:insertWidget(hideButton)
    local removeButton = Button.new("Remove selected point")
    removeButton:setSkin(Skin["buttonSkin_MENew2"]()); removeButton:setBounds(312, 124, 270, 29); main:insertWidget(removeButton)
    local coordinates = Static.new("LAT/LON (DDM): --")
    coordinates:setSkin(dataSkin); coordinates:setBounds(18, 166, 564, 25); main:insertWidget(coordinates)
    local elevation = Static.new("Elevation: --")
    elevation:setSkin(dataSkin); elevation:setBounds(18, 193, 564, 25); main:insertWidget(elevation)
    local status = Static.new("Select a point in F10 and press COPY.")
    status:setSkin(statusSkins.neutral); status:setBounds(18, 230, 564, 62); main:insertWidget(status)
    if status.setTextWrapping then status:setTextWrapping(true) end

    F10W.ui = { main = main, aircraft = aircraftLabel, pointList = pointList,
        waypoint = waypoint, waypointLabel = waypointLabel, status = status,
        coordinates = coordinates, elevation = elevation, statusSkins = statusSkins,
        insertButton = insertButton, isOpen = false,
        hideButton = hideButton, removeButton = removeButton,
        decreaseWaypoint = decreaseWaypoint, increaseWaypoint = increaseWaypoint }
    insertButton.onChange = processInsert
    pointList.onChange = function()
        local selected = pointList:getSelectedItem()
        updateCoordinateDisplay(selected and F10W.points[selected.pointId] or nil)
    end
    setTransferBusy(F10W.transferBusy)
    removeButton.onChange = function()
        if F10W.transferBusy then return end
        local item = pointList:getSelectedItem()
        if not item or not F10W.capturedPoints[item.pointId] then
            setStatus("neutral", "Select an F10 point to remove.") return
        end
        F10W.capturedPoints[item.pointId] = nil
        rebuildPoints()
        populatePointList()
    end
    hideButton.onChange = hideMainWindow
    function main:onClose() hideMainWindow() end
    main:addHotKeyCallback("Ctrl+Shift+m", toggleMainWindow)

    main:setVisible(true)
    hideMainWindow()
    writeLog(log.INFO, "Native dxgui overlay created and hidden; hotkey Ctrl+Shift+M")
    return true
end

local function ensureUi()
    if not F10W.ui.main then
        local now = DCS.getRealTime()
        if now - F10W.lastUiAttemptAt < 3 then return end
        F10W.lastUiAttemptAt = now
        local ok, result = pcall(createUi)
        if not ok then
            writeLog(log.ERROR, "dxgui overlay creation failed: " .. tostring(result))
            return
        end
    end
    if not isSupportedAircraft(F10W.aircraft) and F10W.ui.isOpen then hideMainWindow() end
end

local function pollExportResponses()
    while true do
        local data, address = exportResponseReceiver:receivefrom()
        if not data then return end
        local sequenceId, message = data:match("^RSP|([^|]+)|(.+)$")
        if address == "127.0.0.1" and message and sequenceId == F10W.pendingSequenceId then
            writeLog(log.INFO, message)
            if message == "Sequence completed" and F10W.transferPhase == "running" then
                setTransferBusy(false)
                setStatus("success", "WP INSERTED SUCCESSFULLY")
            elseif message == "Sequence cancelled" then
                setTransferBusy(false)
                setStatus("error", "Transfer stopped. Check the waypoint before retrying.")
            elseif message:find("failed:", 1, true)
                or message:find("rejected:", 1, true)
                or message:find("already in progress", 1, true) then
                setTransferBusy(false)
                local problem = message:gsub("^Action %d+ failed:%s*", "")
                setStatus("error", problem)
            end
        end
    end
end

local callbacks = {}
function callbacks.onSimulationStop()
    setTransferBusy(false)
    F10W.aircraft = "Spectator"
    F10W.previousAircraft = nil
    F10W.configuredAircraft = nil
    F10W.aircraftReadyAt = math.huge
    F10W.points, F10W.capturedPoints = {}, {}
    F10W.nextPointId = 0
    F10W.sessionScope, F10W.preferredPointId = nil, nil
    F10W.clipboardPrimed, F10W.lastClipboardText, F10W.nextClipboardPollAt = false, nil, 0
    if F10W.ui.pointList then F10W.ui.pointList:clear() end
    updateCoordinateDisplay(nil)
    setStatus("neutral", "READY")
    hideMainWindow()
    writeLog(log.INFO, "Simulation stopped; overlay hidden")
end

function callbacks.onSimulationFrame()
    pollExportResponses()
    F10W.aircraft = DCS.getPlayerUnitType() or "Spectator"
    local now = DCS.getRealTime()
    local scope = tostring(DCS.getPlayerCoalition()) .. ":" .. tostring(DCS.getPlayerUnit())
    if F10W.sessionScope ~= scope then
        if F10W.sessionScope then
            if F10W.transferBusy then
                F10W.transferPhase = "cancelling"
                F10W.transferStartedAt = now - F10W.transferTimeout
                F10W.lastCancelAt = -10
                setStatus("error", "Player slot changed. Stopping transfer...")
                if F10W.ui.insertButton then F10W.ui.insertButton:setText("Stopping...") end
            end
            -- A different slot/coalition must not inherit points from the previous cockpit.
            F10W.capturedPoints, F10W.preferredPointId = {}, nil
            rebuildPoints()
            populatePointList()
        end
        F10W.sessionScope = scope
        F10W.clipboardPrimed, F10W.lastClipboardText, F10W.nextClipboardPollAt = false, nil, 0
        writeLog(log.INFO, "Player scope changed: " .. scope)
    end
    if F10W.aircraft ~= F10W.previousAircraft then
        F10W.previousAircraft = F10W.aircraft
        F10W.playerRole = nil
        F10W.configuredAircraft = nil
        F10W.aircraftReadyAt = isSupportedAircraft(F10W.aircraft) and now + 12 or math.huge
        writeLog(log.INFO, string.format("Aircraft detected: %s | supported=%s | initialization hold=%s",
            tostring(F10W.aircraft), tostring(isSupportedAircraft(F10W.aircraft)),
            isSupportedAircraft(F10W.aircraft) and "12s" or "n/a"))
        ensureUi()
        if not isSupportedAircraft(F10W.aircraft) then hideMainWindow() end
    else
        ensureUi()
    end

    -- DCS can report the future player unit several seconds before it creates
    -- the cockpit.  Do not query mission state or touch aircraft-specific UI
    -- while mod indicators and devices are still being constructed.
    if isSupportedAircraft(F10W.aircraft) and now >= F10W.aircraftReadyAt
        and F10W.configuredAircraft ~= F10W.aircraft then
        F10W.configuredAircraft = F10W.aircraft
        writeLog(log.INFO, "Aircraft initialization hold completed: " .. F10W.aircraft)
        if F10W.ui.aircraft then F10W.ui.aircraft:setText("Aircraft: " .. F10W.aircraft) end
        local profile = getAircraftProfile(F10W.aircraft)
        if profile and F10W.ui.waypoint then
            F10W.ui.waypoint:setRange(profile.minimum, profile.maximum)
            local value = tonumber(F10W.ui.waypoint:getValue()) or profile.minimum
            F10W.ui.waypoint:setValue(math.max(profile.minimum, math.min(profile.maximum, value)))
        end
        if profile and F10W.ui.waypointLabel then
            F10W.ui.waypointLabel:setText(profile.noun .. " destination")
        end
        rebuildPoints()
        populatePointList()
    end

    if F10W.transferBusy and now - F10W.transferStartedAt > F10W.transferTimeout then
        if F10W.transferPhase ~= "cancelling" then
            F10W.transferPhase = "cancelling"
            setStatus("error", "Transfer timed out. Waiting for stop confirmation...")
            if F10W.ui.insertButton then F10W.ui.insertButton:setText("Stopping...") end
        end
        if now - F10W.lastCancelAt >= 1 then
            F10W.lastCancelAt = now
            exportSender:sendto("CANCEL|" .. tostring(F10W.pendingSequenceId), "127.0.0.1", F10W.exportCommandPort)
        end
        if now - F10W.transferStartedAt > F10W.transferTimeout + 5
            and F10W.statusMessage ~= "ERROR: No stop confirmation. Transfer locked; restart the mission." then
            setStatus("error", "No stop confirmation. Transfer locked; restart the mission.")
        end
    end
    pollClipboardCapture(now)
end
DCS.setUserCallbacks(callbacks)
writeLog(log.INFO, "DCS F10 To Waypoint GameGUI " .. F10W.version .. " started")


