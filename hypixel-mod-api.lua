plugin = {
    name = "hypixel-mod-api",
    displayName = "Hypixel Mod API",
    prefix = "§bዞ",
    version = "1.0.1",
    description = "Events and functions for other plugins to integrate with the Hypixel Mod API",
}

-- Constants

local environments = { [0] = "production", [1] = "beta", [2] = "test" }
local roles = { [0] = "LEADER", [1] = "MOD", [2] = "MEMBER" }
local errors = {
    [1] = "API disabled",
    [2] = "Internal server error",
    [3] = "Rate limited",
    [4] = "Invalid packet version",
    [5] = "No longer supported"
}
local playerRanks = { [1] = "NORMAL", [2] = "YOUTUBER", [3] = "STAFF" }
local packageRanks = { [1] = "NONE", [2] = "VIP", [3] = "VIP+", [4] = "MVP", [5] = "MVP+" }
local monthlyRanks = { [1] = "NONE", [2] = "MVP++" }

local LOCATION_EVENT = "hyevent:location"
local LOCATION_EVENT_VERSION = 1
local REGISTER_CHANNEL = "hypixel:register"
local REGISTER_PACKET_VERSION = 1
-- The client's mods get this long after Hypixel's hello to register before we do.
local REGISTER_GRACE_MS = 2000
local RATE_LIMITED = 3
-- Hypixel answers one request of a kind every few seconds and refuses the rest (measured:
-- refused 2 s apart, answered 4 s apart).
local REQUEST_GAP_MS = 5000
-- Location events follow a world change within a moment; past this, ask instead.
local LOCATION_WAIT_MS = 1500

-- Session state

local state = {
    environment = nil,
    location = {},
    locatedAt = nil,
    changedAt = nil,
    -- What the client's mods last registered for, and whether this connection is registered.
    clientEvents = {},
    registered = false,
}

-- The client's own mods ask Hypixel too, and every answer reaches us whoever asked, so a recent
-- answer or one already on its way is shared rather than asked for again.
local requests = {
    ["hypixel:player_info"] = { version = 1 },
    ["hypixel:party_info"] = { version = 2 },
}

-- Formatting

local function formatLocation(loc)
    local parts = {}
    if loc.serverName then parts[#parts + 1] = "§7server§8: §e" .. loc.serverName end
    if loc.serverType then parts[#parts + 1] = "§7type§8: §a" .. loc.serverType end
    if loc.lobbyName then parts[#parts + 1] = "§7lobby§8: §b" .. loc.lobbyName end
    if loc.mode then parts[#parts + 1] = "§7mode§8: §d" .. loc.mode end
    if loc.map then parts[#parts + 1] = "§7map§8: §6" .. loc.map end
    if #parts == 0 then return "§8(unknown)" end
    return table.concat(parts, "§7, ")
end

local function formatPlayerInfo(info)
    local parts = {}
    if info.playerRankName then
        parts[#parts + 1] = "§7rank§8: §e" .. info.playerRankName
    end
    if info.packageRankName then
        parts[#parts + 1] = "§7package§8: §a" .. info.packageRankName
    end
    if info.monthlyRankName then
        parts[#parts + 1] = "§7monthly§8: §d" .. info.monthlyRankName
    end
    if info.prefix then
        parts[#parts + 1] = "§7prefix§8: §f" .. info.prefix
    end
    return table.concat(parts, "§7, ")
end

local function formatPartyInfo(info)
    if not info.inParty then
        return "§7Not in a party"
    end
    local parts = { "§aIn party §7(" .. #info.members .. " members)§8:" }
    for _, member in ipairs(info.members) do
        local role = member.role or "MEMBER"
        local roleColor = role == "LEADER" and "§6" or (role == "MOD" and "§a" or "§7")
        parts[#parts + 1] = "  " .. roleColor .. role .. " §f" .. member.uuid
    end
    return table.concat(parts, "\n")
end

-- Mod API packets

local function requestLocation()
    local writer = starfish.encoding.writer()
    writer:varint(1)
    starfish.server.sendPluginMessage("hypixel:location", writer:build())
end

-- Registration. Hypixel keeps one event registration per connection and each register replaces
-- the last, so a register of our own would drop every event the client's mods asked for. Ours
-- rides along in the client's register instead, and we only register by ourselves when no mod
-- does - and then for the mods' last events too.

local function readEvents(payload)
    local ok, events = pcall(function()
        local reader = starfish.encoding.reader(payload)
        reader:varint()
        local events = {}
        for _ = 1, reader:varint() do
            events[reader:string()] = reader:varint()
        end
        return events
    end)
    return ok and events or nil
end

local function registerPayload(events)
    local writer = starfish.encoding.writer()
    local count = 0
    for _ in pairs(events) do
        count = count + 1
    end
    writer:varint(REGISTER_PACKET_VERSION)
    writer:varint(count)
    for event, version in pairs(events) do
        writer:string(event)
        writer:varint(version)
    end
    return writer:build()
end

local function withOurs(events)
    local all = {}
    for event, version in pairs(events) do
        all[event] = version
    end
    all[LOCATION_EVENT] = all[LOCATION_EVENT] or LOCATION_EVENT_VERSION
    return all
end

local function mergeClientRegister(payload)
    local events = readEvents(payload)
    if not events then
        return nil
    end
    state.clientEvents = events
    state.registered = true
    if events[LOCATION_EVENT] then
        return nil
    end
    return registerPayload(withOurs(events))
end

local function registerUnlessClientDid()
    starfish.timers.delay(REGISTER_GRACE_MS, function()
        if not state.registered then
            state.registered = true
            starfish.server.sendPluginMessage(REGISTER_CHANNEL, registerPayload(withOurs(state.clientEvents)))
        end
    end)
end

-- Asks for the location only when no location event followed a world change; a client that
-- never registered for location events, or a Starfish attached mid-session, still gets one.
local function expectLocation()
    local changedAt = starfish.time.monotonic()
    state.changedAt = changedAt
    starfish.timers.delay(LOCATION_WAIT_MS, function()
        if state.changedAt == changedAt and (state.locatedAt or 0) < changedAt then
            requestLocation()
        end
    end)
end

local function send(channel)
    local request = requests[channel]
    local writer = starfish.encoding.writer()
    writer:varint(request.version)
    starfish.server.sendPluginMessage(channel, writer:build())
    request.sentAt = starfish.time.monotonic()
    request.waiting = true
    request.ours = true
end

local function ask(channel)
    local request = requests[channel]
    local now = starfish.time.monotonic()
    if request.answer and now - request.answeredAt < REQUEST_GAP_MS then
        starfish.events.emit(channel, request.answer)
        return
    end
    if request.waiting and now - request.sentAt < REQUEST_GAP_MS then
        return
    end
    local wait = request.sentAt and REQUEST_GAP_MS - (now - request.sentAt) or 0
    if wait <= 0 then
        send(channel)
    elseif not request.queued then
        request.queued = true
        starfish.timers.delay(wait, function()
            request.queued = false
            send(channel)
        end)
    end
end

-- Our own request refused for the rate limit is retried once rather than reported.
local function answer(channel, result)
    local request = requests[channel]
    request.waiting = false
    if not result.success and result.error == RATE_LIMITED and request.ours and not request.retried then
        request.retried = true
        starfish.timers.delay(REQUEST_GAP_MS, function() send(channel) end)
        return
    end
    request.retried = false
    if result.success then
        request.answer = result
        request.answeredAt = starfish.time.monotonic()
    end
    starfish.events.emit(channel, result)
end

-- Every Hypixel response starts with a success flag. A failure carries only an error code;
-- a success is followed by the packet version and then its fields.
local function readResponse(data)
    local reader = starfish.encoding.reader(data)
    if not reader:bool() then
        return nil, reader:varint()
    end
    reader:varint()
    return reader
end

local function handleLocation(data)
    local reader, errorCode = readResponse(data)

    if reader then
        state.location = {
            serverName = reader:string(),
            serverType = reader:optionalString(),
            lobbyName = reader:optionalString(),
            mode = reader:optionalString(),
            map = reader:optionalString()
        }
        state.locatedAt = starfish.time.monotonic()
        starfish.events.emit("hypixel:location", {
            success = true,
            location = state.location
        })

        starfish.log.debug("Location: " .. formatLocation(state.location))
    else
        starfish.events.emit("hypixel:location", {
            success = false,
            error = errorCode,
            errorMessage = errors[errorCode] or "Unknown"
        })

        starfish.log.debug("Location error: " .. (errors[errorCode] or "Unknown"))
    end
end

-- Event wiring

starfish.events.on("session:join", function()
    state.environment = nil
    state.location = {}
    state.clientEvents = {}
    state.registered = false
end)

starfish.events.on("world:respawn", expectLocation)
starfish.events.on("session:attached", requestLocation)

starfish.server.onPluginMessage("hypixel:hello", function(data)
    local reader = starfish.encoding.reader(data)
    local envId = reader:varint()
    state.environment = environments[envId] or "unknown"
    state.location = {}
    state.registered = false
    registerUnlessClientDid()
    expectLocation()
end)

starfish.server.interceptOutgoing(REGISTER_CHANNEL, mergeClientRegister)

starfish.events.on("server:pluginMessageOutgoing", function(message)
    local request = requests[message.channel]
    if request then
        request.sentAt = starfish.time.monotonic()
        request.waiting = true
        request.ours = false
    end
end)

starfish.server.onPluginMessage("hyevent:location", handleLocation)
starfish.server.onPluginMessage("hypixel:location", handleLocation)

starfish.server.onPluginMessage("hypixel:player_info", function(data)
    local reader, errorCode = readResponse(data)

    local result = {}
    if reader then
        result.success = true
        result.playerRank = reader:varint()
        result.packageRank = reader:varint()
        result.monthlyPackageRank = reader:varint()
        result.prefix = reader:optionalString()
        result.playerRankName = playerRanks[result.playerRank] or "NORMAL"
        result.packageRankName = packageRanks[result.packageRank] or "NONE"
        result.monthlyRankName = monthlyRanks[result.monthlyPackageRank] or "NONE"
    else
        result.success = false
        result.error = errorCode
        result.errorMessage = errors[errorCode] or "Unknown"
    end
    answer("hypixel:player_info", result)
end)

starfish.server.onPluginMessage("hypixel:party_info", function(data)
    local reader, errorCode = readResponse(data)

    local result = {}
    if reader then
        result.success = true
        result.inParty = reader:bool()
        result.members = {}

        if result.inParty then
            local count = reader:varint()
            for i = 1, count do
                local uuid = reader:uuid()
                local roleId = reader:varint()
                result.members[i] = {
                    uuid = uuid,
                    role = roles[roleId] or "MEMBER"
                }
            end
        end
    else
        result.success = false
        result.error = errorCode
        result.errorMessage = errors[errorCode] or "Unknown"
    end
    answer("hypixel:party_info", result)
end)

-- Commands

starfish.commands.register("hloc", {
    description = "Show current Hypixel location"
}, function()
    if state.environment then
        starfish.chat.info("§bEnvironment§8: §e" .. state.environment)
    end
    starfish.chat.info("§bLocation§8: " .. formatLocation(state.location))
end)

starfish.commands.register("hplayer", {
    description = "Request and display player info from Hypixel"
}, function()
    starfish.chat.info("§6Requesting player info...")

    starfish.events.once("hypixel:player_info", function(result)
        if result.success then
            starfish.chat.info("§6Player Info§8: " .. formatPlayerInfo(result))
        else
            starfish.chat.info("§cError: " .. result.errorMessage)
        end
    end)

    ask("hypixel:player_info")
end)

starfish.commands.register("hparty", {
    description = "Request and display party info from Hypixel"
}, function()
    starfish.chat.info("§dRequesting party info...")

    starfish.events.once("hypixel:party_info", function(result)
        if result.success then
            local lines = formatPartyInfo(result)
            for line in lines:gmatch("[^\n]+") do
                starfish.chat.info(line)
            end
        else
            starfish.chat.info("§cError: " .. result.errorMessage)
        end
    end)

    ask("hypixel:party_info")
end)

-- Exports

starfish.plugin.export("getEnvironment", function()
    return state.environment
end)

starfish.plugin.export("getLocation", function()
    return state.location
end)

starfish.plugin.export("requestPlayerInfo", function()
    ask("hypixel:player_info")
    return true
end)

starfish.plugin.export("requestPartyInfo", function()
    ask("hypixel:party_info")
    return true
end)

-- Startup

requestLocation()
