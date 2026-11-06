-- Exercises the real Export.lua bridge against mocked DCS devices and UDP.
-- Run from the project root: lua tests/test_export_protocol.lua
local checks, failures = 0, {}
local function check(condition, message)
    checks = checks + 1
    if not condition then failures[#failures + 1] = message end
end

local function bridge()
    local state = { now = 100, inputs = {}, messages = {}, controls = {}, logs = {},
        sockets = {}, upstream = {}, indications = {} }
    local socket = {}
    function socket.gettime() return state.now end
    function socket.udp()
        local udp = { closed = false }
        state.sockets[#state.sockets + 1] = udp
        function udp:setsockname(address, port)
            self.address, self.port = address, port
            return 1
        end
        function udp:settimeout(value) self.timeout = value end
        function udp:receivefrom()
            local item = table.remove(state.inputs, 1)
            if item then return item.data, item.address, 12345 end
            return nil, "timeout"
        end
        function udp:sendto(message, address, port)
            state.messages[#state.messages + 1] = { text = message, address = address, port = port }
            return #message
        end
        function udp:close() self.closed = true end
        return udp
    end
    local env = {
        require = function(name) assert(name == "socket"); return socket end,
        log = { INFO = 1, ERROR = 2,
            write = function(tag, level, message) state.logs[#state.logs + 1] = message end },
        GetDevice = function(id)
            return {
                performClickableAction = function(_, command, value)
                    state.controls[#state.controls + 1] = { device = id, command = command, value = value }
                end,
                get_argument_value = function() return 0 end,
            }
        end,
        list_indication = function(id) return state.indications[id] or "" end,
    }
    for _, name in ipairs({"LuaExportStart", "LuaExportStop", "LuaExportBeforeNextFrame", "LuaExportAfterNextFrame"}) do
        local callbackName = name
        env[name] = function() state.upstream[callbackName] = (state.upstream[callbackName] or 0) + 1 end
    end
    setmetatable(env, { __index = _G })
    env._G = env
    local chunk = assert(loadfile("dcs/DCS_F10ToWaypoint.lua"))
    setfenv(chunk, env)
    chunk()
    state.env = env
    function state:queue(data, address)
        self.inputs[#self.inputs + 1] = { data = data, address = address or "127.0.0.1" }
    end
    function state:frame(elapsed)
        self.now = self.now + (elapsed or 0)
        self.env.LuaExportBeforeNextFrame()
    end
    function state:has(message)
        for _, entry in ipairs(self.messages) do
            if entry.text == message then return true end
        end
        return false
    end
    function state:countContaining(text)
        local count = 0
        for _, entry in ipairs(self.messages) do
            if entry.text:find(text, 1, true) then count = count + 1 end
        end
        return count
    end
    return state
end

local function scenario(name, test)
    local ok, problem = pcall(test)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(problem) end
end

scenario("correlated completion", function()
    local b = bridge()
    b.env.LuaExportStart()
    b:queue("SEQ|00000001|17,3001,1,100;17,3001,0,50")
    b:frame()
    check(b:has("RSP|00000001|Sequence 00000001 accepted (2 actions)"), "Acceptance carries sequence ID")
    check(#b.controls == 1 and b.controls[1].value == 1, "First action executes after acceptance")
    b:frame(0.05)
    check(#b.controls == 1, "Action delay respected")
    b:frame(0.06)
    check(#b.controls == 2 and b.controls[2].value == 0, "Second action releases control")
    check(b:has("RSP|00000001|Sequence completed"), "Completion carries same sequence ID")
    b:frame(1)
    check(b:countContaining("Sequence completed") == 1, "Completion is emitted once")
    b.env.LuaExportAfterNextFrame()
    check(b.upstream.LuaExportStart == 1 and b.upstream.LuaExportBeforeNextFrame == 4
        and b.upstream.LuaExportAfterNextFrame == 1, "Existing export callbacks chained")
    for _, message in ipairs(b.messages) do
        check(message.address == "127.0.0.1" and message.port == 42081, "Responses stay on loopback response port")
    end
end)

scenario("cancel held control", function()
    local b = bridge()
    b:queue("SEQ|00000002|17,3001,1,1000;17,3001,0,50;17,3002,1,50;17,3002,0,50")
    b:frame()
    b:queue("CANCEL|00000002")
    b:frame(0.01)
    check(b:has("RSP|00000002|Sequence cancelled"), "Cancellation response correlated")
    check(#b.controls == 2 and b.controls[2].command == 3001 and b.controls[2].value == 0,
        "Cancellation immediately releases held momentary control")
    b:frame(10)
    check(#b.controls == 2 and b:countContaining("Sequence completed") == 0,
        "Cancelled sequence never executes remaining commands or reports success")
end)

scenario("early cancel", function()
    local b = bridge()
    b:queue("CANCEL|00000003")
    b:queue("SEQ|00000003|17,3001,1,100;17,3001,0,50")
    b:frame()
    check(#b.controls == 0, "Cancellation arriving before SEQ prevents late execution")
    check(b:has("RSP|00000003|Sequence cancelled") and b:countContaining("accepted") == 0,
        "Early-cancelled sequence never accepted")
    b:queue("SEQ|00000004|17,3002,1,100;17,3002,0,50")
    b:frame()
    check(#b.controls == 1 and b.controls[1].command == 3002, "A new ID can run after cancellation")
end)

scenario("queued cancel before action", function()
    local b = bridge()
    b:queue("SEQ|00000005|17,3001,1,100;17,3001,0,50")
    b:queue("CANCEL|00000005")
    b:frame()
    check(#b.controls == 0, "Same-frame queued cancellation is processed before a cockpit action")
end)

scenario("busy request identity", function()
    local b = bridge()
    b:queue("SEQ|00000006|17,3001,1,1000;17,3001,0,50")
    b:frame()
    b:queue("SEQ|00000007|17,3002,1,100;17,3002,0,50")
    b:frame(0.1)
    check(b:has("RSP|00000007|A transfer is already in progress: wait for it to complete"),
        "Busy rejection uses rejected request ID")
    check(not b:has("RSP|00000006|A transfer is already in progress: wait for it to complete"),
        "Busy request does not corrupt running request status")
    b:queue("CANCEL|00000007")
    b:frame(0.1)
    check(#b.controls == 1, "Cancelling different request does not release running request control")
    b:frame(1)
    check(#b.controls == 2 and b.controls[2].command == 3001
        and b:has("RSP|00000006|Sequence completed"), "Original sequence completes unchanged")
end)

scenario("reject remote sender", function()
    local b = bridge()
    b:queue("SEQ|00000008|17,3001,1,100;17,3001,0,50", "192.0.2.1")
    b:frame()
    check(#b.controls == 0 and #b.messages == 0, "Non-loopback datagram ignored")
end)

scenario("format rejection", function()
    local b = bridge()
    b:queue("SEQ|00000009|not-an-action")
    b:frame()
    check(b:has("RSP|00000009|Sequence 00000009 rejected: invalid format")
        and #b.controls == 0, "Malformed request reports rejection with its own ID")
    b:queue("SEQ|bad-id|17,3001,1,100")
    b:frame()
    check(#b.controls == 0, "Invalid request ID ignored")
end)

scenario("deadline on due action", function()
    local b = bridge()
    b:queue("SEQ|0000000a|17,3001,1,1000;17,3001,0,50;17,3002,1,100")
    b:frame()
    b:frame(180.01)
    check(b:has("RSP|0000000a|Action failed: export safety timeout; sequence stopped"),
        "Export deadline reports correlated failure")
    check(#b.controls == 2 and b.controls[2].command == 3001 and b.controls[2].value == 0,
        "Export deadline releases held control")
    b:frame(10)
    check(#b.controls == 2, "Deadline clears remaining queue")
end)

scenario("deadline before delayed release", function()
    local b = bridge()
    b:queue("SEQ|0000000b|17,3001,1,200000;17,3001,0,50")
    b:frame()
    b:frame(180.01)
    check(b:has("RSP|0000000b|Action failed: export safety timeout; sequence stopped"),
        "Hard deadline must apply even when next action is not due yet")
    check(#b.controls == 2 and b.controls[2].value == 0,
        "Hard deadline must release a delayed control at 180 seconds")
end)

scenario("stop resources", function()
    local b = bridge()
    b:queue("SEQ|0000000c|17,3001,1,1000;17,3001,0,50")
    b:frame()
    b.env.LuaExportStop()
    check(#b.controls == 2 and b.controls[2].value == 0, "Mission stop releases held control")
    check(b.sockets[1].closed and b.sockets[2].closed, "Mission stop closes both UDP sockets")
    check(b.upstream.LuaExportStop == 1, "Mission stop preserves existing export stop callback")
end)

if #failures > 0 then
    for _, failure in ipairs(failures) do io.stderr:write("FAIL: " .. failure .. "\n") end
    error(string.format("Export protocol tests: %d failure(s), %d checks", #failures, checks))
end
print("Export protocol tests passed: " .. checks)

