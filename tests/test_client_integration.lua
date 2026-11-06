-- Exercise the actual DCS F10 To Waypoint GameGUI hook with Lua 5.1 UI/API mocks.
-- Run: luae.exe tests/test_client_integration.lua <repository-root>
local root = ((arg and arg[1]) or "."):gsub("\\", "/"):gsub("/$", "")
local assertions = 0
local function check(condition, message)
    assertions = assertions + 1
    if not condition then error(message or "assertion failed", 2) end
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "unexpected value") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end
local function contains(value, text, message)
    check(type(value) == "string" and value:find(text, 1, true) ~= nil,
        (message or "missing text") .. ": " .. tostring(value))
end

local widgets, messages, sent, inbox = {}, {}, {}, {}
local now, unit, side, aircraft = 0, "101", 2, "FA-18C_hornet"
local callbacks, clipboardText = nil, ""
local function newWidget(kind, text)
    local widget = { kind = kind, initialText = text, text = text or "", enabled = true,
        visible = true, items = {}, children = {}, hotkeys = {} }
    widgets[#widgets + 1] = widget
    function widget:setSkin(skin) self.skin = skin end
    function widget:setBounds(x, y, w, h) self.bounds = { x, y, w, h }; self.width, self.height = w, h end
    function widget:setHasCursor(value) self.hasCursor = value end
    function widget:insertWidget(child) self.children[#self.children + 1] = child end
    function widget:setText(value) self.text = value end
    function widget:getText() return self.text end
    function widget:setEnabled(value) self.enabled = value end
    function widget:setVisible(value) self.visible = value end
    function widget:setSize(w, h) self.width, self.height = w, h end
    function widget:setTextWrapping(value) self.wrapping = value end
    function widget:addHotKeyCallback(key, callback) self.hotkeys[key] = callback end
    function widget:clear() self.items, self.selected = {}, nil end
    function widget:insertItem(item) self.items[#self.items + 1] = item end
    function widget:selectItem(item) self.selected = item; if self.onChange then self.onChange(self) end end
    function widget:getSelectedItem() return self.selected end
    return widget
end
local function find(kind, text)
    for _, widget in ipairs(widgets) do
        if widget.kind == kind and (text == nil or widget.initialText == text) then return widget end
    end
    error("widget not created: " .. kind .. " " .. tostring(text))
end
local function click(widget)
    check(widget.enabled, "button must be enabled: " .. widget.initialText)
    check(type(widget.onChange) == "function", "button callback missing")
    widget.onChange(widget)
end
local function skin() return { skinData = { states = {} } } end
local loaded = {
    Skin = setmetatable({}, { __index = function() return skin end }),
    dxgui = {
        GetWindowSize = function() return 1920, 1080 end,
        GetTextFromClipboard = function() return clipboardText end,
    },
    lfs = { writedir = function() return "__F10W_MOCK_ROOT__/" end },
    terrain = {
        convertMetersToLatLon = function(x, z) return x / 1000, z / 1000 end,
        GetHeight = function(x) return 125 + x / 100000 end,
    },
}
for _, kind in ipairs({ "Window", "Static", "Button", "ComboList", "ListBoxItem" }) do
    local widgetKind = kind
    loaded[kind] = { new = function(text) return newWidget(widgetKind, text) end }
end
local socketCount = 0
loaded.socket = { udp = function()
    socketCount = socketCount + 1
    local value = {}
    function value:setsockname() return true end
    function value:settimeout() end
    function value:receivefrom() return table.remove(inbox, 1), "127.0.0.1", 42082 end
    function value:sendto(data, address, port)
        sent[#sent + 1] = { data = data, address = address, port = port }
        return #data
    end
    return value
end }

local env = setmetatable({}, { __index = _G })
env._G, env.package = env, { loaded = loaded }
env.require = function(name) assert(loaded[name], "unexpected require: " .. name); return loaded[name] end
env.io = { open = function() return nil end }
env.log = { INFO = "INFO", WARNING = "WARNING", ERROR = "ERROR", write = function(_, _, message)
    messages[#messages + 1] = tostring(message)
end }
env.DCS = {
    getRealTime = function() return now end,
    getPlayerUnitType = function() return aircraft end,
    getPlayerUnit = function() return unit end,
    getPlayerCoalition = function() return side end,
    getAvailableSlots = function() return { { unitId = unit, role = "Pilot" } } end,
    setUserCallbacks = function(value) callbacks = value end,
}
local hook = assert(loadfile(root .. "/dcs/DCS_F10ToWaypointGameGUI.lua"))
setfenv(hook, env)
hook()
check(callbacks and callbacks.onSimulationFrame, "hook registers callbacks")
equal(socketCount, 2, "GUI opens only two local sockets")
local function frame(time) now = time; callbacks.onSimulationFrame() end
local function lastSequence()
    for i = #sent, 1, -1 do
        local id = sent[i].data:match("^SEQ|([^|]+)|")
        if id then return id, sent[i].data end
    end
    error("no insertion was sent")
end

frame(0)
local main = find("Window", "DCS F10 To Waypoint")
local list = find("ComboList")
local coordinates = find("Static", "LAT/LON (DDM): --")
local status = find("Static", "Select a point in F10 and press COPY.")
local insert = find("Button", "Insert")
local hide = find("Button", "Hide")
local remove = find("Button", "Remove selected point")
equal(main.width, 0, "overlay starts hidden")
equal(#list.items, 0, "point list starts empty")
equal(find("Static", "F10 point").text, "F10 point", "UI describes points")
frame(13)
contains(status.text, "Select a point", "empty-state guidance is concise")
main.hotkeys["Ctrl+Shift+m"]()
equal(main.width, 600, "hotkey opens overlay")
equal(main.height, 309, "point-only overlay uses compact height")
equal(hide.width, 270, "hide button uses half control row")

clipboardText = "Metric: X+00041500 Z+00036500\nLat Long Decimal Minutes: N 41 00.000 E 036 00.000"
frame(13.5)
equal(#list.items, 1, "new DCS clipboard coordinates import automatically")
contains(list.items[1].text, "[F10 point]", "point origin is explicit")
contains(coordinates.text, "N41", "coordinate conversion includes latitude")
contains(coordinates.text, "E036", "coordinate conversion includes longitude")
contains(status.text, "automatically", "automatic acquisition reports success")
frame(14)
equal(#list.items, 1, "unchanged clipboard does not duplicate point")
clipboardText = "unrelated clipboard text"
frame(14.5)
equal(#list.items, 1, "unrelated clipboard text is ignored")

click(insert)
local id, payload = lastSequence()
contains(payload, "SEQ|", "insertion sends an Export sequence")
equal(insert.enabled, false, "insert locked during sequence")
equal(remove.enabled, false, "point removal locked during sequence")
inbox[#inbox + 1] = "RSP|stale-id|Sequence completed"
frame(15)
equal(insert.enabled, false, "unrelated response cannot complete transfer")
inbox[#inbox + 1] = "RSP|" .. id .. "|Sequence completed"
frame(16)
equal(insert.enabled, true, "matching response completes transfer")
contains(status.text, "WP INSERTED SUCCESSFULLY", "success status displayed")

click(remove)
equal(#list.items, 0, "selected point can be removed")
equal(coordinates.text, "LAT/LON (DDM): --", "removal clears coordinate display")
clipboardText = "Metric X+00046000 Z+00041000"
frame(17)
equal(#list.items, 1, "second F10 point is acquired")
unit, side = "202", 1
frame(18)
equal(#list.items, 0, "slot/coalition change clears prior cockpit points")
callbacks.onSimulationStop()
equal(main.width, 0, "mission stop hides overlay")
equal(#list.items, 0, "mission stop clears point list")
equal(coordinates.text, "LAT/LON (DDM): --", "mission stop clears coordinate display")

for _, text in ipairs(messages) do
    check(not text:lower():find("marker", 1, true), "runtime log must not contain legacy marker logic")
end
print("PASS: client integration (" .. assertions .. " assertions)")
