plugin = {
    name = "hypixel-mod-api",
    displayName = "Hypixel Mod API",
    prefix = "§bዞ",
    version = "1.1.1",
    credits = "Hexze",
    description = "Core Hypixel Mod API integration - provides events and functions for other plugins"
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

-- State
local state = {
    environment = nil,
    location = {},
    -- True once we've sent our own hypixel:register this connection. This is
    -- the real "are we talking to the Mod API" signal - unlike `environment`,
    -- it doesn't depend on having observed hypixel:hello (see below).
    registered = false
}

-- Formatting functions
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

-- Protocol
--
-- hypixel:hello is sent unconditionally by the server on every backend join,
-- regardless of client registration - so it cannot tell us whether a client
-- mod already registered, and it's not something we can prompt. Registration
-- (hypixel:register) is a separate, independent message: we send our own
-- regardless of hello, since a spec-compliant mod re-sends its full
-- subscription every time hello fires anyway (self-healing any overlap).
--
-- Because hello is a one-shot per-connection packet, attaching mid-session
-- (the common case: Hypixel was already open before Starfish/this plugin
-- started watching) means we'll never see it. So registration must not be
-- gated on any join/respawn event alone - it also runs once, unconditionally,
-- as soon as this script loads.
local function subscribeToLocationEvents()
    local writer = starfish.encoding.writer()
    writer:varint(1)
    writer:varint(1)
    writer:string("hyevent:location")
    writer:varint(1)
    starfish.server.sendPluginMessage("hypixel:register", writer:build())
    state.registered = true
end

-- Safe to call repeatedly: sendPluginMessage silently no-ops if there's no
-- bound session yet, and re-sending register is idempotent.
local function attemptRegistration()
    subscribeToLocationEvents()
end

starfish.events.on("server_join", function()
    state.environment = nil
    state.location = {}
    attemptRegistration()
end)

starfish.events.on("respawn", attemptRegistration)

-- Event handlers
starfish.events.on("plugin_message", function(event)
    if event.channel == "hypixel:hello" then
        local reader = starfish.encoding.reader(event.data)
        local envId = reader:varint()
        state.environment = environments[envId] or "unknown"
        state.location = {}
        -- Re-assert our subscription now that the connection is confirmed live.
        attemptRegistration()

    elseif event.channel == "hyevent:location" then
        local reader = starfish.encoding.reader(event.data)
        local version = reader:varint()
        local success = reader:bool()

        if success then
            state.location = {
                serverName = reader:string(),
                serverType = reader:optionalString(),
                lobbyName = reader:optionalString(),
                mode = reader:optionalString(),
                map = reader:optionalString()
            }
            starfish.events.broadcast("hypixel:location", {
                success = true,
                location = state.location
            })

            starfish.debug("Location: " .. formatLocation(state.location))
        else
            local errorCode = reader:varint()
            starfish.events.broadcast("hypixel:location", {
                success = false,
                error = errorCode,
                errorMessage = errors[errorCode] or "Unknown"
            })

            starfish.debug("Location error: " .. (errors[errorCode] or "Unknown"))
        end

    elseif event.channel == "hypixel:player_info" then
        local reader = starfish.encoding.reader(event.data)
        local version = reader:varint()
        local success = reader:bool()

        local result = {}
        if success then
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
            result.error = reader:varint()
            result.errorMessage = errors[result.error] or "Unknown"
        end
        starfish.events.broadcast("hypixel:player_info", result)

    elseif event.channel == "hypixel:party_info" then
        local reader = starfish.encoding.reader(event.data)
        local version = reader:varint()
        local success = reader:bool()

        local result = {}
        if success then
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
            result.error = reader:varint()
            result.errorMessage = errors[result.error] or "Unknown"
        end
        starfish.events.broadcast("hypixel:party_info", result)
    end
end)

-- Commands
starfish.commands.register("hloc", {
    description = "Show current Hypixel location"
}, function()
    if not state.registered then
        starfish.chat.send(starfish.chat.prefix("§cNot connected to Hypixel"))
        return
    end

    -- Environment (production/beta/test) only arrives via the one-shot hello
    -- packet on a fresh join, so it's frequently unknown when Starfish attaches
    -- to an already-connected session. It has no functional use elsewhere, so
    -- it's shown only when we happen to know it rather than as a fake "unknown".
    if state.environment then
        starfish.chat.send(starfish.chat.prefix("§bEnvironment§8: §e" .. state.environment))
    end
    starfish.chat.send(starfish.chat.prefix("§bLocation§8: " .. formatLocation(state.location)))
end)

starfish.commands.register("hplayer", {
    description = "Request and display player info from Hypixel"
}, function()
    if not state.registered then
        starfish.chat.send(starfish.chat.prefix("§cNot connected to Hypixel"))
        return
    end

    starfish.chat.send(starfish.chat.prefix("§6Requesting player info..."))

    starfish.events.once("hypixel:player_info", function(result)
        if result.success then
            starfish.chat.send(starfish.chat.prefix("§6Player Info§8: " .. formatPlayerInfo(result)))
        else
            starfish.chat.send(starfish.chat.prefix("§cError: " .. result.errorMessage))
        end
    end)

    local writer = starfish.encoding.writer()
    writer:varint(1)
    starfish.server.sendPluginMessage("hypixel:player_info", writer:build())
end)

starfish.commands.register("hparty", {
    description = "Request and display party info from Hypixel"
}, function()
    if not state.registered then
        starfish.chat.send(starfish.chat.prefix("§cNot connected to Hypixel"))
        return
    end

    starfish.chat.send(starfish.chat.prefix("§dRequesting party info..."))

    starfish.events.once("hypixel:party_info", function(result)
        if result.success then
            local lines = formatPartyInfo(result)
            for line in lines:gmatch("[^\n]+") do
                starfish.chat.send(starfish.chat.prefix(line))
            end
        else
            starfish.chat.send(starfish.chat.prefix("§cError: " .. result.errorMessage))
        end
    end)

    local writer = starfish.encoding.writer()
    writer:varint(2)
    starfish.server.sendPluginMessage("hypixel:party_info", writer:build())
end)

-- Export public API
starfish.api.export("getEnvironment", function()
    return state.environment
end)

starfish.api.export("getLocation", function()
    if not state.registered then return nil end
    return state.location
end)

starfish.api.export("requestPlayerInfo", function()
    if not state.registered then return false end
    local writer = starfish.encoding.writer()
    writer:varint(1)
    starfish.server.sendPluginMessage("hypixel:player_info", writer:build())
    return true
end)

starfish.api.export("requestPartyInfo", function()
    if not state.registered then return false end
    local writer = starfish.encoding.writer()
    writer:varint(2)
    starfish.server.sendPluginMessage("hypixel:party_info", writer:build())
    return true
end)

-- Attempt registration once immediately at load. This is the case server_join
-- and respawn can't cover: attaching to (or hot-reloading while on) a session
-- that's already connected to Hypixel, where no fresh join event will ever
-- fire again. Harmless no-op if there's no active connection yet.
attemptRegistration()
