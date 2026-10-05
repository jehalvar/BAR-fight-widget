-- BAR Fight reads historical, server-computed traits. It records no gameplay.
-- Responses are parsed as JSON data and are never executed as Lua code.
local widget = widget

function widget:GetInfo()
    return {
        name = "BAR Fight Traits", desc = "Historical playstyle traits for the current players",
        author = "BAR Fight", date = "2026", license = "GNU GPL, v2 or later",
        -- DrawScreen runs from higher layers to lower layers. BAR's player list
        -- is -4, so its hover callback reaches us before drawing this popup.
        layer = -5, enabled = true,
    }
end

local REQUEST_PATH = "LuaUI/Config/bar_fight_traits_request.json"
local RESPONSE_PATH = "LuaUI/Config/bar_fight_traits_response.json"
local TIMING_REQUEST_PATH = "LuaUI/Config/bar_fight_timings_request.json"
local TIMING_RESPONSE_PATH = "LuaUI/Config/bar_fight_timings_response.json"
local MAP = "Supreme Isthmus v2.1"
local MAX_BYTES, MAX_PLAYERS = 1048576, 16
local MAX_HOVER_TRAITS = 4
-- Keep older helper caches consistent with the website's retired badges.
local RETIRED_TRAITS = {consistent_opener = true, early_defence = true, mobile_heavy = true, leaker = true}
local REFRESH_SECONDS, OFFLINE_SECONDS = 60, 30
local RECOVERY_REFRESH_SECONDS, ACTIVE_REFRESH_SECONDS = 120, 240
local CONNECTION_FRESH_SECONDS = 300
local INSTANCE_TOKEN = tostring({}):gsub("[^a-zA-Z0-9]", "")
local NULL = {}
local POSITION_NAMES = {
    P1 = "Geo sea", P2 = "Tech", P3 = "Air", P4 = "Pond",
    P5 = "Front (suicide)", P6 = "Front (second)", P7 = "Geo tech", P8 = "Beach sea",
}
local FACTION_NAMES = {armada = "Armada", cortex = "Cortex", legion = "Legion", all = "All factions"}
-- The same verified Supreme Isthmus v2.1 spawn centres and 900-unit matching
-- radius used by the website. A role describes a start, not a current job.
local SPAWNS = {
    {711,7218}, {837,10407}, {2155,11747}, {2513,7983},
    {4595,7440}, {4997,8570}, {4375,9800}, {4814,11077},
    {11579,5063}, {11456,1901}, {10129,541}, {9764,4339},
    {7729,4835}, {7292,3727}, {7925,2500}, {7492,1220},
}
local QUICK_TIMINGS = {
    sea = {{"First sub", "group:combat-sub"}, {"Shipyard ready", "group:t1-shipyard"}, {"First destroyer", "group:destroyer"}},
    tech = {{"First T2 con", "group:t2-constructor"}, {"First Fusion", "group:fusion"}, {"First Advanced Fusion", "group:advanced-fusion"}},
    front = {{"T1 factory ready", "group:t1-factory"}},
    geo = {{"First Starlight", "armmanni"}, {"First Mauser", "armmart"}, {"First Quaker", "cormart"}, {"First Liche", "armliche"}, {"Advanced Geo ready", "group:advanced-geo"}},
    air = {{"First Fusion", "group:fusion"}, {"First bomber", "group:conventional-bomber"}, {"First fighter", "group:fighter"}},
}
local QUICK_ROLES = {P1 = "sea", P2 = "tech", P3 = "air", P5 = "front", P6 = "front", P7 = "geo", P8 = "sea"}
local ID_KEYS = {
    "user_id", "userid", "userID", "account_id", "accountid", "accountID",
    "teiserver_user_id", "teiserverUserId", "chobbyUserId",
}

-- Bounded JSON decoder, deliberately independent of optional BAR libraries.
local function decodeJSON(text)
    if type(text) ~= "string" or #text > MAX_BYTES then error("Invalid JSON size") end
    local at, length, tokens = 1, #text, 0
    local parse
    local function skip()
        while at <= length and text:sub(at, at):match("[ \t\r\n]") do at = at + 1 end
    end
    local function utf8(code)
        if code < 128 then return string.char(code) end
        if code < 2048 then return string.char(192 + math.floor(code / 64), 128 + code % 64) end
        if code < 65536 then
            return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
        end
        return string.char(240 + math.floor(code / 262144), 128 + math.floor(code / 4096) % 64,
            128 + math.floor(code / 64) % 64, 128 + code % 64)
    end
    local function hex4()
        local hex = text:sub(at, at + 3)
        if #hex ~= 4 or not hex:match("^%x%x%x%x$") then error("Invalid Unicode escape") end
        at = at + 4
        return tonumber(hex, 16)
    end
    local function quoted()
        at = at + 1
        local parts, start = {}, at
        while at <= length do
            local byte = text:byte(at)
            if byte == 34 then
                parts[#parts + 1] = text:sub(start, at - 1)
                at = at + 1
                return table.concat(parts)
            elseif byte == 92 then
                parts[#parts + 1] = text:sub(start, at - 1)
                at = at + 1
                local escape = text:sub(at, at)
                at = at + 1
                if escape == "u" then
                    local code = hex4()
                    if code >= 55296 and code <= 56319 then
                        if text:sub(at, at + 1) ~= "\\u" then error("Missing low surrogate") end
                        at = at + 2
                        local low = hex4()
                        if low < 56320 or low > 57343 then error("Invalid low surrogate") end
                        code = 65536 + (code - 55296) * 1024 + low - 56320
                    elseif code >= 56320 and code <= 57343 then error("Unexpected low surrogate") end
                    parts[#parts + 1] = utf8(code)
                else
                    local escapes = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
                    if not escapes[escape] then error("Invalid escape") end
                    parts[#parts + 1] = escapes[escape]
                end
                start = at
            elseif byte < 32 then error("Control byte in JSON string")
            else at = at + 1 end
        end
        error("Unterminated JSON string")
    end
    parse = function(depth)
        tokens = tokens + 1
        if depth > 20 or tokens > 50000 then error("JSON complexity limit") end
        skip()
        local first = text:sub(at, at)
        if first == '"' then return quoted() end
        if first == "{" or first == "[" then
            local object, close = first == "{", first == "{" and "}" or "]"
            local result, seen = {}, {}
            at = at + 1
            skip()
            if text:sub(at, at) == close then at = at + 1; return result end
            while true do
                local key
                if object then
                    if text:sub(at, at) ~= '"' then error("Object key expected") end
                    key = quoted()
                    if seen[key] then error("Duplicate JSON key") end
                    seen[key] = true
                    skip()
                    if text:sub(at, at) ~= ":" then error("Colon expected") end
                    at = at + 1
                else key = #result + 1 end
                result[key] = parse(depth + 1)
                skip()
                local delimiter = text:sub(at, at)
                at = at + 1
                if delimiter == close then return result end
                if delimiter ~= "," then error("Comma expected") end
                skip()
            end
        end
        for _, literal in ipairs({"true", "false", "null"}) do
            if text:sub(at, at + #literal - 1) == literal then
                at = at + #literal
                if literal == "true" then return true end
                if literal == "false" then return false end
                return NULL
            end
        end
        local start = at
        if first == "-" then at = at + 1 end
        if text:sub(at, at) == "0" then at = at + 1
        elseif text:sub(at, at):match("[1-9]") then
            repeat at = at + 1 until not text:sub(at, at):match("%d")
        else error("JSON value expected") end
        if text:sub(at, at) == "." then
            at = at + 1
            if not text:sub(at, at):match("%d") then error("Fraction expected") end
            repeat at = at + 1 until not text:sub(at, at):match("%d")
        end
        if text:sub(at, at):match("[eE]") then
            at = at + 1
            if text:sub(at, at):match("[+-]") then at = at + 1 end
            if not text:sub(at, at):match("%d") then error("Exponent expected") end
            repeat at = at + 1 until not text:sub(at, at):match("%d")
        end
        local number = tonumber(text:sub(start, at - 1))
        if not number or number ~= number or math.abs(number) == math.huge then error("Invalid JSON number") end
        return number
    end
    local result = parse(0)
    skip()
    if at <= length then error("Trailing JSON content") end
    return result
end

local function textValue(value, limit)
    if type(value) ~= "string" then return "" end
    value = value:gsub("[%z\1-\31\127\255]", "")
    limit = limit or 160
    if #value > limit then
        local following = value:byte(limit + 1)
        if following and following >= 128 and following <= 191 then
            while limit > 0 and value:byte(limit) >= 128 and value:byte(limit) <= 191 do limit = limit - 1 end
            limit = math.max(0, limit - 1)
        end
        value = value:sub(1, limit)
    end
    return value
end

local function timestampText(value)
    if type(value) == "number" and value >= 0 and value < 4102444800 and os and os.date then
        local ok, formatted = pcall(os.date, "!%Y-%m-%d %H:%M UTC", math.floor(value))
        if ok then return formatted end
    elseif type(value) == "string" then
        local date, hour = value:match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)")
        if date and hour then return date .. " " .. hour .. " UTC" end
    end
    return ""
end

-- Convert the helper's UTC ISO timestamp without depending on the host timezone.
local function fetchedEpoch(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second, suffix = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not year or not (suffix == "Z" or suffix:match("^%.%d+Z$") or suffix == "+00:00" or suffix:match("^%.%d+%+00:00$")) then return nil end
    year, month, day, hour, minute, second = tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute), tonumber(second)
    if year < 1970 or year > 2100 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then return nil end
    local function leap(y) return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) end
    local months = {31, leap(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if day < 1 or day > months[month] then return nil end
    local days = day - 1
    for y = 1970, year - 1 do days = days + (leap(y) and 366 or 365) end
    for m = 1, month - 1 do days = days + months[m] end
    return days * 86400 + hour * 3600 + minute * 60 + second
end

local function accountID(value)
    if type(value) == "number" then
        if value < 1 or value > 9007199254740991 or value ~= math.floor(value) then return nil end
        value = string.format("%.0f", value)
    end
    if type(value) ~= "string" or #value > 16 or not value:match("^%d+$") then return nil end
    value = value:gsub("^0+", "")
    if value == "" or tonumber(value) > 9007199254740991 then return nil end
    return value
end

local function extractAccount(keys)
    if type(keys) ~= "table" then return nil end
    local found
    for _, key in ipairs(ID_KEYS) do
        local value = accountID(keys[key])
        if value then
            if found and found ~= value then return nil end
            found = value
        end
    end
    return found
end

local function percent(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value > 100 then return nil end
    return string.format("%.1f%%", value):gsub("%.0%%", "%%")
end

local function integer(value, maximum)
    return type(value) == "number" and value >= 0 and value <= (maximum or 10000000) and value == math.floor(value)
end

local function jsonString(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function supportedMap()
    local name = Game and Game.mapName
    return type(name) == "string" and name:lower():gsub("[^a-z0-9]", "") == "supremeisthmusv21"
end

local elapsed, rosterTimer, responseTimer = 0, 0, 0
local open, roster, accounts, requestedAccounts, profiles = false, {}, {}, {}, {}
local selectedPlayer, selectedSpot, expandedTrait = nil, nil, nil
local matchSelections, timingMenu, timingMenuArea = {}, nil, nil
local contextMap, contextFrame, selectedContextKey, selectedAutoSpot
local activeTab = "traits"
local timing = {unit = "group:t2-constructor", label = "T2 constructors", units = {
    {id = "group:t2-constructor", label = "T2 constructors", kind = "group"}},
    lastRequestAt = -REFRESH_SECONDS, signature = "", status = "Choose a unit to inspect historical ready times.",
    connectionState = "unverified", search = "", searching = false, scroll = 0}
local timingSearchArea, timingListArea
local rosterScroll, traitScroll = 0, 0
local lastSignature, lastRequestID, lastResponseText = "", nil, nil
local requestSequence, lastRequestAt, pendingAt, lastSuccessAt = 0, -REFRESH_SECONDS, nil, nil
local status = "Open BAR Fight to view historical traits."
local connectionState, checkedAt = "unverified", nil
local hits, rosterArea, detailArea, panelArea, dragArea = {}, nil, nil, nil, nil
local hoverKey, hoverSince = nil, 0
local nativeHover
local HOVER_DELAY = 0.3
local vsx, vsy = 1280, 720
-- nil keeps the original top-right placement for users who have never dragged.
local panelPositionX, panelPositionY
local dragging, dragOffsetX, dragOffsetY = false, 0, 0
local palette = {
    background = {0.035, 0.055, 0.075, 0.97}, surface = {0.065, 0.10, 0.13, 0.98},
    selected = {0.09, 0.22, 0.24, 1}, text = {0.9, 0.95, 0.97, 1},
    muted = {0.58, 0.7, 0.76, 1}, accent = {0.25, 0.89, 0.79, 1},
    warning = {1, 0.77, 0.38, 1}, border = {0.18, 0.28, 0.33, 1},
}

local searchPressedKeys, searchHeldKeys = {}, {}
local function setTimingSearchFocus(focused)
    if focused == timing.searching then return focused end
    if focused then
        -- BAR routes owned text before game shortcuts. Merely drawing a cursor
        -- does not enable SDL text events (chat normally leaves them stopped).
        if widgetHandler and widgetHandler.OwnText and not widgetHandler:OwnText() then
            timing.status = "Close the other text field, then click the unit search."
            return false
        end
        timing.searching = true
        timingMenu = nil
        searchPressedKeys = {}
        searchHeldKeys = Spring.GetPressedKeys and Spring.GetPressedKeys() or {}
        if Spring.SDLStartTextInput then Spring.SDLStartTextInput() end
    else
        timing.searching = false
        local released = not widgetHandler or not widgetHandler.DisownText or widgetHandler:DisownText()
        -- Another field may have taken ownership; never stop its native input.
        if released and Spring.SDLStopTextInput then Spring.SDLStopTextInput() end
    end
    return focused
end

local function selectionFor(row)
    if not row then return {} end
    local key = (row.account_id or tostring(row.player_id)) .. ":" .. row.team
    if not matchSelections[key] then matchSelections[key] = {} end
    return matchSelections[key]
end

local function factionFor(row)
    return selectionFor(row).faction or (row and row.startFaction) or "all"
end

local function updateStartContext(rows)
    local frame = Spring.GetGameFrame and Spring.GetGameFrame()
    if contextMap ~= nil and (contextMap ~= Game.mapName or (frame and contextFrame and frame < contextFrame)) then
        matchSelections, selectedSpot, timingMenu = {}, nil, nil
    end
    contextMap, contextFrame = Game.mapName, frame
    local validLayout = supportedMap() and Game.mapSizeX == 12288 and Game.mapSizeZ == 12288 and #rows == 16
    local teams, allies, counts = {}, {}, {}
    for _, row in ipairs(rows) do
        if teams[row.team] then validLayout = false end
        teams[row.team] = true
        allies[row.ally] = (allies[row.ally] or 0) + 1
        if Spring.GetTeamInfo then
            local _, _, _, isAI = Spring.GetTeamInfo(row.team, false)
            if isAI ~= false then validLayout = false end
        else validLayout = false end
        -- startUnit reflects the chosen faction; GetTeamInfo's side is only a
        -- lobby default. Enemy values may be hidden by the engine: leave unknown.
        local startUnit = Spring.GetTeamRulesParam and Spring.GetTeamRulesParam(row.team, "startUnit")
        local definition = UnitDefs and UnitDefs[tonumber(startUnit)]
        local name = definition and definition.name
        row.startFaction = name == "armcom" and "armada" or name == "corcom" and "cortex" or name == "legcom" and "legion" or nil
    end
    local allyCount = 0
    for _, count in pairs(allies) do allyCount = allyCount + 1; if count ~= 8 then validLayout = false end end
    if allyCount ~= 2 then validLayout = false end
    if Spring.GetTeamList and Spring.GetGaiaTeamID then
        local total, gaia = 0, Spring.GetGaiaTeamID()
        for _, team in ipairs(Spring.GetTeamList()) do
            if team ~= gaia then total = total + 1; if not teams[team] then validLayout = false end end
        end
        if total ~= 16 then validLayout = false end
    else validLayout = false end
    if not validLayout or not Spring.GetTeamStartPosition then return end
    for _, row in ipairs(rows) do
        local x, _, z, valid = Spring.GetTeamStartPosition(row.team)
        if valid == true and type(x) == "number" and type(z) == "number" and x == x and z == z
            and x >= 0 and x <= 12288 and z >= 0 and z <= 12288 and not (x == 0 and z == 0) then
            local best, distance, tied
            for index, point in ipairs(SPAWNS) do
                local d = (x - point[1])^2 + (z - point[2])^2
                if not distance or d < distance - 0.000001 then best, distance, tied = index, d, false
                elseif math.abs(d - distance) <= 0.000001 then tied = true end
            end
            if best and not tied and distance <= 900^2 then
                row.startIndex = best; counts[best] = (counts[best] or 0) + 1
            end
        end
    end
    for _, row in ipairs(rows) do
        if row.startIndex and counts[row.startIndex] == 1 then row.startSpot = "P" .. ((row.startIndex - 1) % 8 + 1) end
    end
end

local function requestTraits(manual)
    if not supportedMap() then lastRequestID, pendingAt, connectionState, checkedAt = nil, nil, "unsupported", nil; status = "Traits are available for Supreme Isthmus v2.1."; return false end
    if #accounts == 0 then lastRequestID, pendingAt, connectionState, checkedAt = nil, nil, "no_accounts", nil; status = "No stable player account IDs are available in this match."; return false end
    if manual and elapsed - lastRequestAt < REFRESH_SECONDS then return false end
    requestSequence = requestSequence + 1
    local epoch = os and os.time and os.time() or 0
    local player = Spring.GetMyPlayerID and Spring.GetMyPlayerID() or 0
    local requestID = "bft-" .. tostring(epoch) .. "-" .. tostring(player) .. "-" .. INSTANCE_TOKEN .. "-" .. tostring(requestSequence)
    local encoded = {}
    for _, id in ipairs(accounts) do encoded[#encoded + 1] = jsonString(id) end
    local payload = '{"schema":1,"request_id":' .. jsonString(requestID) .. ',"map":' .. jsonString(MAP)
        .. ',"accounts":[' .. table.concat(encoded, ",") .. "]}"
    if Spring.CreateDir then pcall(Spring.CreateDir, "LuaUI/Config") end
    local ok = pcall(function()
        local file, err = io.open(REQUEST_PATH, "wb")
        if not file then error(err or "Cannot create request") end
        local wrote, writeError = file:write(payload)
        file:close()
        if not wrote then error(writeError or "Cannot write request") end
    end)
    lastRequestAt = elapsed
    if not ok then lastRequestID, pendingAt, connectionState, checkedAt = nil, nil, "local_error", nil; status = "Cannot write the local request. Check the BAR Fight installation."; return false end
    lastRequestID, pendingAt, lastResponseText = requestID, elapsed, nil
    connectionState, checkedAt = "connecting", nil
    requestedAccounts = {}
    for _, id in ipairs(accounts) do requestedAccounts[id] = true end
    status = "Loading historical traits through the BAR Fight helper..."
    return true
end

local function refreshRoster()
    local rows, ids, occurrences = {}, {}, {}
    local playerIDs = Spring.GetPlayerList and Spring.GetPlayerList() or {}
    for index, playerID in ipairs(playerIDs) do
        if index > 128 then break end
        -- Current BAR reads accountInfo.accountid from the 11th return value.
        -- Older engines used a custom-key table in the 10th slot instead.
        -- Keep custom keys enabled (the default): passing false omits the account ID.
        local name, active, spectator, team, ally, _, _, _, _, legacyKeys, accountInfo = Spring.GetPlayerInfo(playerID)
        if name and not spectator and integer(team, 10000) and integer(ally, 10000) then
            local id = extractAccount(type(accountInfo) == "table" and accountInfo or legacyKeys)
            rows[#rows + 1] = {player_id = playerID, account_id = id, name = textValue(name, 80), team = team, ally = ally, active = active}
            if id then occurrences[id] = (occurrences[id] or 0) + 1 end
        end
    end
    for _, row in ipairs(rows) do
        if row.account_id and occurrences[row.account_id] == 1 then ids[row.account_id] = true
        else row.account_id = nil end
    end
    updateStartContext(rows)
    table.sort(rows, function(a, b)
        if a.ally ~= b.ally then return a.ally < b.ally end
        if a.team ~= b.team then return a.team < b.team end
        return a.player_id < b.player_id
    end)
    local selectedExists = false
    for _, row in ipairs(rows) do if row.player_id == selectedPlayer then selectedExists = true end end
    if not selectedExists then selectedPlayer = rows[1] and rows[1].player_id; selectedSpot, expandedTrait = nil, nil end
    roster = rows
    for _, row in ipairs(rows) do
        if row.player_id == selectedPlayer then
            local choice = selectionFor(row)
            local key = (row.account_id or tostring(row.player_id)) .. ":" .. row.team
            if selectedContextKey ~= key or (selectedAutoSpot and not row.startSpot and not choice.spot) then selectedSpot = nil end
            if choice.spot or row.startSpot then selectedSpot = choice.spot or row.startSpot end
            selectedContextKey, selectedAutoSpot = key, row.startSpot
        end
    end
    local ordered = {}
    for id in pairs(ids) do ordered[#ordered + 1] = id end
    table.sort(ordered, function(a, b) return tonumber(a) < tonumber(b) end)
    if #ordered > MAX_PLAYERS then
        accounts = {}; lastRequestID, pendingAt, connectionState, checkedAt = nil, nil, "no_accounts", nil; status = "This panel supports up to 16 player accounts."; return
    end
    accounts = ordered
    local signature = (supportedMap() and MAP or "unsupported") .. ":" .. table.concat(accounts, ",")
    if signature ~= lastSignature then
        lastSignature = signature
        requestTraits(false)
    end
end

local function validProfile(raw)
    if type(raw) ~= "table" or raw == NULL then return nil end
    local id = accountID(raw.account_id)
    if not id or not requestedAccounts[id] then return nil end
    local profile = {account_id = id, name = textValue(raw.name, 80), status = textValue(raw.status, 48),
        preparing = raw.preparing == true, preparation_note = textValue(raw.preparation_note, 160),
        generated_at = timestampText(raw.generated_at), stale = raw.stale == true, positions = {}}
    local period = type(raw.period) == "table" and raw.period or {}
    profile.period = {start_date = textValue(period.start_date, 10), end_date = textValue(period.end_date, 10)}
    if type(raw.positions) ~= "table" or #raw.positions > 8 then return nil end
    local seen = {}
    for _, position in ipairs(raw.positions) do
        if type(position) ~= "table" or not POSITION_NAMES[position.spot] or seen[position.spot]
            or not integer(position.games) or not percent(position.coverage_percent)
            or type(position.traits) ~= "table" or #position.traits > 12 then return nil end
        seen[position.spot] = true
        local clean = {spot = position.spot, position_name = POSITION_NAMES[position.spot], games = position.games,
            coverage_percent = position.coverage_percent, status = textValue(position.status, 48),
            preparing = position.preparing == true,
            prepared_games = type(position.prepared_games) == "number" and position.prepared_games >= 0
                and position.prepared_games == math.floor(position.prepared_games) and position.prepared_games or nil,
            preparation_percent = type(position.preparation_percent) == "number" and position.preparation_percent >= 0
                and position.preparation_percent <= 100 and position.preparation_percent or nil,
            preparation_note = textValue(position.preparation_note, 160), traits = {}}
        local traitIDs = {}
        for _, trait in ipairs(position.traits) do
            if type(trait) ~= "table" or type(trait.id) ~= "string" or #trait.id > 80 or traitIDs[trait.id]
                or type(trait.label) ~= "string" or #trait.label > 160 or trait.label == ""
                or not percent(trait.frequency_percent) or not integer(trait.samples)
                or trait.samples < 10 or trait.samples > position.games then return nil end
            traitIDs[trait.id] = true
            if not RETIRED_TRAITS[trait.id] then
                clean.traits[#clean.traits + 1] = {id = trait.id, label = textValue(trait.label, 160),
                    frequency_percent = trait.frequency_percent, samples = trait.samples,
                    description = textValue(trait.description, 1800)}
            end
        end
        profile.positions[#profile.positions + 1] = clean
    end
    table.sort(profile.positions, function(a, b) return a.spot < b.spot end)
    return profile
end

local function pollResponse()
    if not lastRequestID or not io or not io.open then return end
    local file = io.open(RESPONSE_PATH, "rb")
    if not file then return end
    local content = file:read(MAX_BYTES + 1)
    file:close()
    if not content or content == lastResponseText then return end
    lastResponseText = content
    local ok, response = pcall(decodeJSON, content)
    if not ok or type(response) ~= "table" then
        connectionState, checkedAt = "invalid", nil
        status = "The helper response was incomplete or invalid; waiting for valid data."; return
    end
    if response.schema ~= 1 or response.request_id ~= lastRequestID then return end
    if response.map ~= nil and response.map ~= MAP then return end
    if response.ok == false then
        local errors = {["privacy-disabled"] = "disabled", ["stopped"] = "stopped", ["timeout"] = "service_timeout",
            ["invalid-response"] = "service_invalid", ["unexpected-content-type"] = "service_invalid"}
        connectionState, checkedAt = errors[response.error_code] or "unavailable", nil
        status = "Helper unavailable: " .. (textValue(response.error, 140) ~= "" and textValue(response.error, 140) or "please check the connection.")
        pendingAt = nil
        return
    end
    if response.ok ~= true or (response.cached ~= nil and type(response.cached) ~= "boolean") then
        connectionState, checkedAt = "invalid", nil; return
    end
    if type(response.profiles) ~= "table" or #response.profiles > MAX_PLAYERS then
        connectionState, checkedAt = "invalid", nil
        status = "The helper returned an unsupported profile response."; return
    end
    local incoming, seen = {}, {}
    for _, raw in ipairs(response.profiles) do
        local profile = validProfile(raw)
        if not profile or seen[profile.account_id] then connectionState, checkedAt = "invalid", nil; status = "The helper returned an invalid player profile."; return end
        seen[profile.account_id] = true
        incoming[profile.account_id] = profile
    end
    for id, profile in pairs(incoming) do
        local previous = profiles[id]
        if previous then
            for _, position in ipairs(profile.positions) do
                if profile.status == "preparing" or position.status == "preparing" or position.preparing then
                    for _, oldPosition in ipairs(previous.positions) do
                        if oldPosition.spot == position.spot and #oldPosition.traits > 0 then
                            position.traits = oldPosition.traits
                            position.games = math.max(position.games, oldPosition.games)
                            position.coverage_percent = math.max(position.coverage_percent, oldPosition.coverage_percent)
                        end
                    end
                end
            end
            if (profile.status == "preparing" or profile.preparing) and #profile.positions == 0 and #previous.positions > 0 then
                previous.status, previous.stale = "preparing", true
            else
                if profile.status == "preparing" or profile.preparing then profile.stale = true end
                profiles[id] = profile
            end
        else profiles[id] = profile end
    end
    pendingAt, lastSuccessAt = nil, elapsed
    local fetched = fetchedEpoch(response.fetched_at)
    local now = os and os.time and os.time()
    connectionState = response.cached == true and "cached" or (response.cached == false and fetched and now and fetched <= now and "connected" or "unverified")
    checkedAt = connectionState == "connected" and fetched or nil
    status = response.cached and "Showing cached historical profiles." or "Historical profiles updated."
end

local function hasRecoveringProfile()
    for _, profile in pairs(profiles) do
        if profile.status == "preparing" or profile.preparing or profile.stale then return true end
        for _, position in ipairs(profile.positions) do
            if position.status == "preparing" or position.preparing then return true end
        end
    end
    return false
end

local function rect(x1, y1, x2, y2, color)
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    gl.Color(color[1], color[2], color[3], color[4]); gl.Rect(x1, y1, x2, y2)
end

local function drawText(value, x, y, size, color, options)
    gl.Color(color[1], color[2], color[3], color[4]); gl.Text(value, x, y, size, options or "o")
end

local function fit(value, width, size)
    value = textValue(value, 1800)
    if not gl.GetTextWidth or gl.GetTextWidth(value) * size <= width then return value end
    while #value > 0 and gl.GetTextWidth(value .. "...") * size > width do
        -- Remove one complete UTF-8 character, rather than leaving a partial byte sequence.
        local cut = #value
        while cut > 1 and value:byte(cut) >= 128 and value:byte(cut) <= 191 do cut = cut - 1 end
        value = value:sub(1, cut - 1)
    end
    return value .. "..."
end

local function connectionLabel(state, checked)
    if state == nil then state, checked = connectionState, checkedAt end
    if state == "connected" and checked then
        local now = os and os.time and os.time()
        if not now or now < checked then return "Website: not checked", palette.muted end
        local age = math.floor(now - checked)
        local ago = age < 60 and (age .. "s") or (math.floor(age / 60) .. "m")
        if age < CONNECTION_FRESH_SECONDS then return "Website: connected (checked " .. ago .. " ago)", palette.accent end
        return "Website: last check " .. ago .. " ago", palette.warning
    end
    local labels = {unverified = "Website: not checked", connecting = "Website: connecting...",
        cached = "Website: cached profiles (not checked)", unavailable = "Website: unavailable",
        stopped = "Website: helper stopped", service_timeout = "Website: request timed out", service_invalid = "Website: invalid service reply",
        disabled = "Website: profile lookups disabled", invalid = "Website: invalid helper reply",
        timeout = "Website: no helper reply", local_error = "Website: local request failed",
        unsupported = "Website: not checked (unsupported map)", no_accounts = "Website: not checked (no account IDs)"}
    if state == "cached" and activeTab == "timings" then return "Website: cached timings (not checked)", palette.warning end
    return labels[state] or labels.unverified, state == "unverified" and palette.muted or palette.warning
end

local function wrapped(value, width, size)
    local lines, line = {}, ""
    for word in textValue(value, 1800):gmatch("%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and gl.GetTextWidth and gl.GetTextWidth(candidate) * size > width then
            lines[#lines + 1] = line; line = word
        else line = candidate end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function inside(x, y, area)
    return area and x >= area[1] and x <= area[3] and y >= area[2] and y <= area[4]
end

local function button(x1, y1, x2, y2, label, action, selected)
    rect(x1, y1, x2, y2, selected and palette.selected or palette.surface)
    drawText(fit(label, x2 - x1 - 14, 12), x1 + 7, y1 + (y2 - y1 - 12) / 2 + 2, 12, selected and palette.accent or palette.text)
    hits[#hits + 1] = {x1, y1, x2, y2, action = action}
end

local function selectedRow()
    for _, row in ipairs(roster) do if row.player_id == selectedPlayer then return row end end
end

local function selectPosition(spot)
    local row = selectedRow()
    selectionFor(row).spot = spot
    selectedSpot = spot or (row and row.startSpot)
    expandedTrait, traitScroll, timing.copied, timingMenu = nil, 0, false, nil
end

local function unitFaction(item)
    if item.faction and FACTION_NAMES[item.faction] then return item.faction end
    local prefix = item.id:sub(1, 3)
    return prefix == "arm" and "armada" or prefix == "cor" and "cortex" or prefix == "leg" and "legion" or "all"
end

local function unitMatchesFaction(item, faction)
    if faction == "all" then return item.kind ~= "group" or not item.base_id or item.base_id == item.id end
    return unitFaction(item) == faction or (item.kind == "group" and not item.faction and not item.base_id)
end

local function resolveTimingUnit(base)
    local faction = factionFor(selectedRow())
    for _, item in ipairs(timing.units) do
        if (item.base_id or item.id) == base and unitMatchesFaction(item, faction) then return item end
    end
end

local function timingUnitID(value)
    if type(value) ~= "string" or #value > 100 then return nil end
    if value:match("^[a-z][a-z0-9_]*$") or value:match("^group:[a-z][a-z0-9%-]*$") then return value end
end

local function timingSignature()
    local row = selectedRow()
    if not supportedMap() or #accounts == 0 or not row or not row.account_id then return nil end
    return MAP .. ":" .. row.account_id .. ":" .. timing.unit, row
end

local function requestTiming(manual)
    local signature, row = timingSignature()
    if not signature then
        timing.signature, timing.requestID, timing.profile, timing.pendingAt = "", nil, nil, nil
        timing.connectionState, timing.checkedAt = "no_accounts", nil
        timing.status = "A supported map and stable player account are needed."
        return false
    end
    if signature == timing.signature and manual and elapsed - timing.lastRequestAt < REFRESH_SECONDS then return false end
    requestSequence = requestSequence + 1
    local epoch = os and os.time and os.time() or 0
    local requestID = ("bftm-" .. epoch .. "-" .. INSTANCE_TOKEN .. "-" .. requestSequence):sub(1, 80)
    local payload = '{"schema":1,"request_id":' .. jsonString(requestID) .. ',"map":' .. jsonString(MAP)
        .. ',"accounts":[' .. jsonString(row.account_id) .. '],"unit":' .. jsonString(timing.unit) .. '}'
    if Spring.CreateDir then pcall(Spring.CreateDir, "LuaUI/Config") end
    local ok = pcall(function()
        local file, err = io.open(TIMING_REQUEST_PATH, "wb")
        if not file then error(err or "Cannot create timing request") end
        local wrote, writeError = file:write(payload)
        file:close()
        if not wrote then error(writeError or "Cannot write timing request") end
    end)
    timing.signature, timing.lastRequestAt, timing.profile, timing.lastResponseText = signature, elapsed, nil, nil
    timing.account, timing.copied, timing.checkedAt = row.account_id, false, nil
    if not ok then
        timing.requestID, timing.pendingAt, timing.connectionState = nil, nil, "local_error"
        timing.status = "Cannot write the local timing request. Check the BAR Fight helper."
        return false
    end
    timing.requestID, timing.pendingAt, timing.connectionState = requestID, elapsed, "connecting"
    timing.status = "Loading historical build timings through the BAR Fight helper..."
    return true
end

local function readySeconds(value)
    return type(value) == "number" and value == value and value > 0 and value <= 86400
end

local function nullable(value)
    return value == nil or value == NULL
end

local function validTimingProfile(raw)
    if type(raw) ~= "table" or accountID(raw.account_id) ~= timing.account
        or type(raw.positions) ~= "table" or #raw.positions > 8 then return nil end
    local statuses = {available = true, preparing = true, unavailable = true, not_observed = true, no_data = true}
    if not statuses[raw.status] then return nil end
    local period = type(raw.period) == "table" and raw.period or {}
    local result = {account_id = timing.account, status = raw.status, stale = raw.stale == true, preparing = raw.preparing == true,
        generated_at = timestampText(raw.generated_at), checked_at = timestampText(raw.checked_at),
        period = {start_date = textValue(period.start_date, 10), end_date = textValue(period.end_date, 10)}, positions = {}}
    local seen = {}
    for _, item in ipairs(raw.positions) do
        if type(item) ~= "table" or not POSITION_NAMES[item.spot] or seen[item.spot] or not statuses[item.status]
            or not integer(item.games) or not integer(item.samples) or not integer(item.coverage_games)
            or item.samples > item.coverage_games or item.coverage_games > item.games
            or not percent(item.coverage_percent)
            or (item.coverage_games == 0 and not nullable(item.occurrence_percent))
            or (item.coverage_games > 0 and not percent(item.occurrence_percent)) then return nil end
        if item.status == "available" then
            if item.samples == 0 or not readySeconds(item.mean_seconds) or not readySeconds(item.median_seconds) then return nil end
        elseif not nullable(item.mean_seconds) or not nullable(item.median_seconds) then return nil end
        seen[item.spot] = true
        result.positions[#result.positions + 1] = {spot = item.spot, position_name = POSITION_NAMES[item.spot],
            status = item.status, preparing = item.preparing == true, games = item.games, samples = item.samples, coverage_games = item.coverage_games,
            coverage_percent = item.coverage_percent, occurrence_percent = not nullable(item.occurrence_percent) and item.occurrence_percent or nil,
            mean_seconds = readySeconds(item.mean_seconds) and item.mean_seconds or nil,
            median_seconds = readySeconds(item.median_seconds) and item.median_seconds or nil}
    end
    table.sort(result.positions, function(a, b) return a.spot < b.spot end)
    return result
end

local function pollTimingResponse()
    if not timing.requestID or not io or not io.open then return end
    local file = io.open(TIMING_RESPONSE_PATH, "rb")
    if not file then return end
    local content = file:read(MAX_BYTES + 1); file:close()
    if not content or content == timing.lastResponseText then return end
    timing.lastResponseText = content
    local ok, response = pcall(decodeJSON, content)
    if not ok or type(response) ~= "table" then
        timing.profile, timing.connectionState = nil, "invalid"
        timing.status = "Invalid timing response; waiting for valid data."; return
    end
    if response.schema ~= 1 or response.request_id ~= timing.requestID then return end
    if response.ok == false then
        timing.profile, timing.pendingAt, timing.checkedAt = nil, nil, nil
        timing.connectionState = response.error_code == "privacy-disabled" and "disabled" or "unavailable"
        timing.status = "Timing helper unavailable: " .. textValue(response.error, 140); return
    end
    if response.ok ~= true or response.map ~= MAP or response.method ~= "creator-first-ready-v1"
        or type(response.unit) ~= "table" or response.unit.id ~= timing.unit
        or type(response.profiles) ~= "table" or #response.profiles ~= 1
        or type(response.cached) ~= "boolean" then
        timing.profile, timing.connectionState = nil, "invalid"
        timing.status = "Timing reply does not match this lookup."; return
    end
    local incoming = validTimingProfile(response.profiles[1])
    if not incoming or timingSignature() ~= timing.signature then
        timing.profile, timing.connectionState = nil, "invalid"; timing.status = "Invalid player timing evidence."; return
    end
    local label = textValue(response.unit.label, 100)
    if label == "" or (response.unit.kind ~= "group" and response.unit.kind ~= "unit") then return end
    if type(response.units) == "table" and #response.units > 0 and #response.units <= 1000 then
        local units, seen = {}, {}
        for _, item in ipairs(response.units) do
            if type(item) ~= "table" or not timingUnitID(item.id) or seen[item.id]
                or textValue(item.label, 100) == "" or (item.kind ~= "group" and item.kind ~= "unit") then units = nil; break end
            seen[item.id] = true
            if (item.faction ~= nil and not FACTION_NAMES[item.faction])
                or (item.base_id ~= nil and not timingUnitID(item.base_id)) then units = nil; break end
            units[#units + 1] = {id = item.id, label = textValue(item.label, 100), kind = item.kind,
                faction = item.faction, base_id = item.base_id}
        end
        if units then timing.units = units end
    end
    timing.profile, timing.label, timing.pendingAt, timing.cached = incoming, label, nil, response.cached
    local fetched, now = fetchedEpoch(response.fetched_at), os and os.time and os.time()
    timing.connectionState = response.cached and "cached" or (fetched and now and fetched <= now and "connected" or "unverified")
    timing.checkedAt = timing.connectionState == "connected" and fetched or nil
    timing.status = incoming.status == "preparing" and "Build timing history is being prepared. Refresh in a minute."
        or (response.cached and "Showing cached historical build timings." or "Historical build timings updated.")
end

local function matchingTimingPosition()
    if timing.pendingAt or timing.signature ~= timingSignature() or not timing.profile then return nil end
    for _, item in ipairs(timing.profile.positions) do if item.spot == selectedSpot then return item end end
end

local function readyTime(value)
    local seconds = math.floor(value + 0.5)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function copyTiming()
    if not open or activeTab ~= "timings" then return end
    local position, row = matchingTimingPosition(), selectedRow()
    if not position or position.status ~= "available" or timing.profile.status ~= "available" or not row
        or not readySeconds(position.mean_seconds) then return end
    local value = row.name .. " - " .. position.position_name .. " - " .. timing.label .. " - " .. readyTime(position.mean_seconds)
    if Spring.SetClipboard and pcall(Spring.SetClipboard, value) then
        timing.copied = true; timing.status = "Timing copied to the clipboard. Nothing was sent to chat."
    else timing.status = "Clipboard unavailable; the average ready time remains visible below." end
end

local function filteredTimingUnits()
    local result, query = {}, timing.search:lower()
    for _, item in ipairs(timing.units) do
        if unitMatchesFaction(item, factionFor(selectedRow()))
            and (query == "" or item.label:lower():find(query, 1, true) or item.id:lower():find(query, 1, true)) then result[#result + 1] = item end
    end
    return result
end

local function chooseTimingUnit(item)
    setTimingSearchFocus(false)
    timing.base = item.base_id or item.id
    timing.unit, timing.label, timing.search, timing.scroll, timing.copied = item.id, item.label, "", 0, false
    requestTiming(false)
end

local function quickTimingChoices()
    local result = {}
    for _, preset in ipairs(QUICK_TIMINGS[QUICK_ROLES[selectedSpot]] or {}) do
        local unit = resolveTimingUnit(preset[2])
        if unit then result[#result + 1] = {label = preset[1], unit = unit} end
    end
    return result
end

local function alignTimingFaction()
    local item = resolveTimingUnit(timing.base or "group:t2-constructor")
    if not item then
        local presets = quickTimingChoices()
        item = presets[1] and presets[1].unit or resolveTimingUnit("group:t2-constructor")
    end
    if item and item.id ~= timing.unit then chooseTimingUnit(item) end
end

local function copyProfileLink(account)
    local url = "https://bar-fight.com/players/" .. account
    if type(Spring.SetClipboard) == "function" then
        local ok = pcall(Spring.SetClipboard, url)
        if ok then
            status = "Player profile link copied."
            if Spring.Echo then Spring.Echo("[BAR Fight] Player profile link copied.") end
            return
        end
    end
    status = "Clipboard unavailable; profile link sent to the game log."
    if Spring.Echo then Spring.Echo("[BAR Fight] " .. url) end
end

local function hoverPosition(profile, row)
    local best
    for _, position in ipairs(profile.positions) do
        if row.player_id == selectedPlayer and position.spot == selectedSpot then return position end
        if not best or position.games > best.games then best = position end
    end
    return best
end

local function drawHoverCard(row, anchorX, anchorY, source, nameArea)
    local width = math.min(390, vsx - 24)
    local lines = {}
    local function add(value, size, color, frequency)
        lines[#lines + 1] = {text = value, size = size or 12, color = color or palette.muted,
            frequency = frequency}
    end
    add(row.name, 16, palette.text)
    add("BAR Fight - historical traits", 11, palette.accent)
    local profile = row.account_id and profiles[row.account_id]
    if not row.account_id then
        add("No stable account ID is available for this player.")
    elseif not profile then
        add(pendingAt and "Loading this player's profile..." or "No cached profile yet. Start the BAR Fight helper.")
    else
        if profile.stale or status:find("Helper unavailable", 1, true) then
            add("Cached history - update pending", 11, palette.warning)
        end
        local position = hoverPosition(profile, row)
        if position and (position.status == "preparing" or position.preparing) then
            add(position.preparation_note ~= "" and position.preparation_note or "History is being prepared...", 11, palette.warning)
        elseif position and profile.preparing and #position.traits > 0 then
            add(profile.preparation_note ~= "" and profile.preparation_note or "History is being prepared...", 10, palette.warning)
        end
        if not position then
            add(profile.status == "preparing" and "This profile is being prepared. Try again shortly."
                or "No captured games in this date interval.")
        else
            add(position.position_name .. " history - " .. position.games .. " games", 12, palette.muted)
            if #position.traits == 0 then
                if position.status == "preparing" or position.preparing then
                    -- The preparation note above describes this state.
                else
                add((position.games < 10 or position.status == "insufficient_evidence")
                    and "At least 10 measured games are needed for a trait."
                    or "No repeated pattern currently meets a trait rule.")
                end
            else
                local maximum = math.max(1, math.min(MAX_HOVER_TRAITS, math.floor((vsy - 150) / 20)))
                for index = 1, math.min(maximum, #position.traits) do
                    local trait = position.traits[index]
                    add(trait.label, 13, palette.text, percent(trait.frequency_percent) .. " of games")
                end
                if #position.traits > maximum then add("+" .. (#position.traits - maximum) .. " more habits in /barfight", 10) end
            end
        end
    end
    add(source == "roster" and "Click name: dates, positions and evidence"
        or "/barfight: dates, positions and evidence", 10)
    local height = 22
    for _, line in ipairs(lines) do height = height + line.size + 7 end
    local left = nameArea and nameArea[3] + 16 or anchorX + 20
    if left + width > vsx - 12 then left = (nameArea and nameArea[1] or anchorX) - width - 16 end
    left = math.max(12, math.min(left, vsx - width - 12))
    local top = math.max(height + 12, math.min(anchorY + 18, vsy - 12))
    rect(left - 1, top - height - 1, left + width + 1, top + 1, palette.border)
    rect(left, top - height, left + width, top, palette.background)
    rect(left, top - 3, left + width, top, palette.accent)
    local y = top - 12
    for _, line in ipairs(lines) do
        y = y - line.size
        local frequencyWidth = line.frequency and gl.GetTextWidth(line.frequency) * 11 + 18 or 0
        drawText(fit(line.text, width - 24 - frequencyWidth, line.size), left + 12, y, line.size, line.color)
        if line.frequency then
            drawText(line.frequency, left + width - 12, y, 11, palette.accent, "ro")
        end
        y = y - 7
    end
end

local function receiveNativeHover(playerID, suppliedAccount, left, bottom, right, top)
    nativeHover = nil
    if not integer(playerID, 10000) then return end
    local account = accountID(suppliedAccount)
    if not account then return end
    for _, coordinate in ipairs({left, bottom, right, top}) do
        if type(coordinate) ~= "number" or coordinate ~= coordinate or math.abs(coordinate) > 100000 then return end
    end
    if not left or not bottom or not right or not top or left >= right or bottom >= top then return end
    for _, row in ipairs(roster) do
        if row.player_id == playerID and row.account_id == account then
            nativeHover = {player_id = playerID, account_id = account, area = {left, bottom, right, top}, updated = elapsed}
            return
        end
    end
end

local function nativeHoveredRow(x, y)
    if not nativeHover or elapsed - nativeHover.updated > 0.25 or not inside(x, y, nativeHover.area) then return nil end
    for _, row in ipairs(roster) do
        if row.player_id == nativeHover.player_id and row.account_id == nativeHover.account_id then return row end
    end
end

local function drawPlayerHover()
    if not supportedMap() or not Spring.GetMouseState then hoverKey = nil; return end
    local x, y, leftButton, middleButton, rightButton = Spring.GetMouseState()
    if leftButton or middleButton or rightButton then hoverKey = nil; return end
    local row, source, nameArea
    for _, hit in ipairs(hits) do
        if hit.player and inside(x, y, hit) then row, source, nameArea = hit.player, "roster", hit; break end
    end
    if not row and not inside(x, y, panelArea) then
        row, source = nativeHoveredRow(x, y), "native"
        nameArea = nativeHover and nativeHover.area
    end
    local key = row and (source .. ":" .. row.player_id .. ":" .. (row.account_id or "unknown"))
    if key ~= hoverKey then hoverKey, hoverSince = key, elapsed end
    if row and elapsed - hoverSince >= HOVER_DELAY then drawHoverCard(row, x, y, source, nameArea) end
end

local function drawDetails(x1, bottom, x2, top)
    local row = selectedRow()
    if not row then drawText("Waiting for the player roster...", x1, top - 18, 13, palette.muted); return end
    drawText(fit(row.name, x2 - x1, 18), x1, top - 20, 18, palette.text)
    if not row.account_id then
        drawText("No stable account ID supplied by this match.", x1, top - 48, 12, palette.warning)
        drawText("Names are never used to guess a player profile.", x1, top - 68, 12, palette.muted)
        return
    end
    drawText("Account " .. row.account_id, x1, top - 41, 11, palette.muted)
    button(x1, top - 72, x2, top - 48, "Copy profile link",
        function() copyProfileLink(row.account_id) end)
    local contentTop = top - 30
    local profile = profiles[row.account_id]
    if not profile then
        drawText(pendingAt and "Loading this player’s historical profile..." or "No historical profile is available yet.", x1, contentTop - 45, 12, palette.muted)
        drawText("Keep the BAR Fight helper running, then refresh.", x1, contentTop - 67, 12, palette.muted)
        return
    end
    local dateLabel = profile.period.start_date ~= "" and (profile.period.start_date .. " to " .. profile.period.end_date .. " UTC") or "Historical replay interval"
    local freshness = profile.generated_at ~= "" and ("  |  Updated " .. profile.generated_at) or ""
    drawText(fit(dateLabel .. freshness .. (profile.stale and "  |  Stale cache" or ""), x2 - x1, 11),
        x1, contentTop - 32, 11, profile.stale and palette.warning or palette.muted)
    if profile.status == "preparing" or profile.preparing then
        drawText(profile.preparation_note ~= "" and profile.preparation_note or "History is being prepared...",
            x1, contentTop - 48, 10, palette.warning)
    end
    if #profile.positions == 0 then
        local message = profile.status == "preparing" and "This profile is being prepared. Refresh in a minute."
            or "No captured games for this player in the current interval."
        drawText(fit(message, x2 - x1, 12), x1, contentTop - 62, 12, palette.muted)
        return
    end
    local position
    for _, candidate in ipairs(profile.positions) do if candidate.spot == selectedSpot then position = candidate end end
    if not position and not selectedSpot then
        for _, candidate in ipairs(profile.positions) do if not position or candidate.games > position.games then position = candidate end end
        selectedSpot = position.spot
    end
    drawText("Historical position - choose a role to inspect", x1, contentTop - 57, 12, palette.muted)
    local chipWidth = (x2 - x1 - 8) / 2
    for index, candidate in ipairs(profile.positions) do
        local col, line = (index - 1) % 2, math.floor((index - 1) / 2)
        local chipX, chipY = x1 + col * (chipWidth + 8), contentTop - 91 - line * 29
        button(chipX, chipY, chipX + chipWidth, chipY + 25, candidate.position_name,
            function() selectPosition(candidate.spot) end, candidate.spot == selectedSpot)
    end
    local y = contentTop - 93 - math.ceil(#profile.positions / 2) * 29
    if not position then
        drawText("No history for " .. (POSITION_NAMES[selectedSpot] or "this position") .. ". Choose another role above.", x1, y, 11, palette.muted)
        return
    end
    drawText(tostring(position.games) .. " recorded games for this position", x1, y, 11, palette.muted)
    y = y - 18
    if position.status == "preparing" or position.preparing or profile.preparing then
        local preparationNote = position.preparation_note ~= "" and position.preparation_note or profile.preparation_note
        drawText(fit(preparationNote ~= "" and preparationNote or "History is being prepared...",
            x2 - x1, 10), x1, y, 10, palette.warning)
        y = y - 15
    end
    for _, line in ipairs(wrapped("Each trait uses the games with the measurements it needs.", x2 - x1, 11)) do
        drawText(line, x1, y, 11, palette.muted)
        y = y - 15
    end
    y = y - 5
    drawText("Traits describe habits, not skill or live intentions.", x1, y, 11, palette.muted)
    y = y - 20
    detailArea = {x1, bottom, x2, y + 5}
    if #position.traits == 0 then
        if position.status == "preparing" or position.preparing then return end
        local message = (position.games < 10 or position.status == "insufficient_evidence")
            and "At least 10 measured games are needed for a trait."
            or "No repeated pattern currently meets a trait rule."
        for index, line in ipairs(wrapped(message, x2 - x1, 12)) do drawText(line, x1, y - index * 17, 12, palette.muted) end
        return
    end
    traitScroll = math.max(0, math.min(traitScroll, #position.traits - 1))
    for index = traitScroll + 1, #position.traits do
        local trait = position.traits[index]
        if y - 40 < bottom then break end
        rect(x1, y - 40, x2, y, expandedTrait == trait.id and palette.selected or palette.surface)
        drawText(fit(trait.label, x2 - x1 - 105, 13), x1 + 9, y - 17, 13, palette.text)
        drawText(percent(trait.frequency_percent) .. " of games", x2 - 9, y - 17, 11, palette.accent, "ro")
        drawText("Sample: " .. trait.samples .. " games  |  " .. (expandedTrait == trait.id and "Hide evidence" or "Show evidence"), x1 + 9, y - 33, 10, palette.muted)
        hits[#hits + 1] = {x1, y - 40, x2, y, tooltip = trait.description,
            action = function() expandedTrait = expandedTrait == trait.id and nil or trait.id end}
        y = y - 46
        if expandedTrait == trait.id then
            for _, line in ipairs(wrapped(trait.description, x2 - x1 - 16, 11)) do
                if y - 15 < bottom then break end
                drawText(fit(line, x2 - x1 - 16, 11), x1 + 8, y - 11, 11, palette.muted)
                y = y - 15
            end
            y = y - 8
        end
    end
end

local function drawTimings(x1, bottom, x2, top)
    local row = selectedRow()
    if not row then drawText("Waiting for the player roster...", x1, top - 18, 13, palette.muted); return end
    drawText(fit(row.name, x2 - x1, 18), x1, top - 20, 18, palette.text)
    if not row.account_id then
        drawText(fit("No stable account ID supplied by this match.", x2 - x1, 12), x1, top - 48, 12, palette.warning); return
    end
    drawText("Account " .. row.account_id .. " | Historical build timings", x1, top - 40, 11, palette.muted)
    local profile = timing.signature == timingSignature() and timing.profile or nil
    local history = profile or profiles[row.account_id]
    local positions = history and history.positions or {}
    local choice = selectionFor(row)
    if selectedSpot == nil then
        selectedSpot = choice.spot or row.startSpot
        if selectedSpot == nil then
            local best
            for _, item in ipairs(positions) do if not best or item.games > best.games then best = item end end
            if best then selectedSpot = best.spot end
        end
    end
    local middle = (x1 + x2) / 2
    local source = choice.spot and "manual" or row.startSpot and "auto" or "history"
    local positionLabel = selectedSpot and (POSITION_NAMES[selectedSpot] .. " (" .. source .. ")") or "Choose position"
    local faction = factionFor(row)
    local factionLabel = FACTION_NAMES[faction] .. (choice.faction and "" or row.startFaction and " (auto)" or " (unknown)")
    button(x1, top - 74, middle - 4, top - 48, positionLabel, function()
        setTimingSearchFocus(false); timingMenu = timingMenu == "position" and nil or "position"
    end, timingMenu == "position")
    button(middle + 4, top - 74, x2, top - 48, factionLabel, function()
        setTimingSearchFocus(false); timingMenu = timingMenu == "faction" and nil or "faction"
    end, timingMenu == "faction")
    drawText("Quick ready times - " .. (POSITION_NAMES[selectedSpot] or "choose a position"), x1, top - 91, 11, palette.muted)
    local quick = quickTimingChoices()
    local columns = x2 - x1 >= 510 and 3 or 2
    local rows = math.max(1, math.ceil(#quick / columns))
    local width = (x2 - x1 - (columns - 1) * 6) / columns
    for index, preset in ipairs(quick) do
        local column, line = (index - 1) % columns, math.floor((index - 1) / columns)
        local bx, by = x1 + column * (width + 6), top - 121 - line * 29
        button(bx, by, bx + width, by + 25, preset.label, function() chooseTimingUnit(preset.unit) end, timing.unit == preset.unit.id)
    end
    if #quick == 0 then drawText(fit("Use unit search for more choices.", x2-x1, 11), x1, top - 116, 11, palette.muted) end
    local searchTop = top - 104 - rows * 29
    timingSearchArea = {x1, searchTop - 27, x2, searchTop}
    button(x1, searchTop - 27, x2, searchTop,
        timing.searching and ("Search: " .. timing.search .. " |") or ("Unit: " .. timing.label .. "  [Search]"),
        function()
            if not timing.searching and setTimingSearchFocus(true) then timing.search, timing.scroll = "", 0 end
        end, timing.searching)
    local y = searchTop - 45
    local function line(value, offset, size, color)
        if y - offset >= bottom then drawText(fit(value, x2 - x1, size), x1, y - offset, size, color or palette.muted) end
    end
    local position = matchingTimingPosition()
    if profile and position then
        local available = profile.status == "available" and position.status == "available"
        line("Average first ready time - from game start", 0, 12)
        line(available and readyTime(position.mean_seconds) or "Not measured", 34, 30, available and palette.accent or palette.muted)
        line(available and ("Median " .. readyTime(position.median_seconds) .. " | Recorded history, not a build deadline")
            or (position.status == "preparing" and "History is being prepared. Refresh in a minute."
            or position.status == "not_observed" and "No first-ready event observed in the measured games."
            or "This unit timing is not measured for the selected position."), 55, 11)
        line("Sample: " .. position.samples .. " first-ready games | Occurrence: " .. (percent(position.occurrence_percent) or "Unknown"), 74, 11)
        line("Coverage: " .. percent(position.coverage_percent) .. " of selected games", 91, 11)
        local period = profile.period.start_date ~= "" and (profile.period.start_date .. " to " .. profile.period.end_date .. " UTC") or "Historical dates unavailable"
        line(period, 108, 11)
        line((profile.generated_at ~= "" and ("Updated " .. profile.generated_at) or "Update date unavailable")
            .. (profile.stale and " | Stale cache" or timing.cached and " | Helper cache" or ""), 125, 10,
            (profile.stale or timing.cached) and palette.warning or palette.muted)
        if available and y - 162 >= bottom then
            button(x1, y - 162, x2, y - 136, timing.copied and "Copied timing" or "Copy timing", copyTiming)
        else line("Copy timing unavailable for this result", 153, 11) end
        local notes = (position.preparing and "More history is being prepared. " or "")
            .. "Averages use games reaching first ready. Includes unfinished handovers; attributed to the creator."
        for index, text in ipairs(wrapped(notes, x2 - x1, 10)) do line(text, 180 + (index - 1) * 14, 10) end
    else
        line(timing.pendingAt and "Loading this player's build timings..." or profile and "No timing history for the selected position."
            or "No historical build timing is available yet.", 12, 12)
        line(profile and profile.status == "preparing" and "History is being prepared. Refresh in a minute."
            or "Keep the BAR Fight helper running, then refresh.", 33, 11)
    end
    -- Draw the search dropdown last so its hitboxes cover the result beneath it.
    if timing.searching then
        local matches = filteredTimingUnits()
        local capacity = math.max(1, math.min(8, math.floor((searchTop - 54 - bottom) / 27)))
        timing.scroll = math.max(0, math.min(timing.scroll, math.max(0, #matches - capacity)))
        local count = math.min(capacity, #matches)
        local listTop = searchTop - 31
        local listBottom = listTop - math.max(1, count) * 27 - 23
        timingListArea = {x1, listBottom, x2, listTop + 1}
        rect(x1, listBottom, x2, listTop + 1, palette.background)
        if count == 0 then drawText("No matching units", x1 + 8, listTop - 21, 12, palette.muted) end
        for index = timing.scroll + 1, math.min(#matches, timing.scroll + capacity) do
            local item, itemTop = matches[index], listTop - (index - timing.scroll - 1) * 27
            button(x1 + 2, itemTop - 25, x2 - 2, itemTop, item.label .. (item.kind == "group" and " (group)" or (" [" .. item.id .. "]")),
                function() chooseTimingUnit(item) end, item.id == timing.unit)
        end
        drawText(fit(#matches .. " matches | Scroll to browse | Enter selects top | Esc closes", x2 - x1 - 16, 10),
            x1 + 8, listBottom + 6, 10, palette.muted)
    end
    if timingMenu then
        local options = {}
        if timingMenu == "position" then
            options[#options + 1] = {label = "Use starting position (auto)", action = function() selectPosition(nil) end}
            for number = 1, 8 do
                local spot = "P" .. number
                options[#options + 1] = {label = POSITION_NAMES[spot], action = function() selectPosition(spot) end}
            end
        else
            options[#options + 1] = {label = "Use starting faction (auto)", action = function()
                choice.faction, timingMenu = nil, nil; alignTimingFaction()
            end}
            for _, value in ipairs({"all", "armada", "cortex", "legion"}) do
                local factionChoice = value
                options[#options + 1] = {label = FACTION_NAMES[value], action = function()
                    choice.faction, timingMenu = factionChoice, nil; alignTimingFaction()
                end}
            end
        end
        local menuBottom = top - 79 - #options * 27
        timingMenuArea = {x1, menuBottom, x2, top - 77}
        rect(x1, menuBottom, x2, top - 77, palette.background)
        for index, item in ipairs(options) do
            local by = top - 79 - index * 27
            button(x1 + 2, by + 1, x2 - 2, by + 26, item.label, item.action)
        end
    end
end

function widget:Initialize()
    if Spring.GetViewGeometry then vsx, vsy = Spring.GetViewGeometry() end
    refreshRoster()
    WG.barFightTraitsHover = receiveNativeHover
    if Spring.Echo then Spring.Echo("[BAR Fight] Click the BAR Fight button or type /barfight to open the panel. Choose a player and a historical position.") end
end

function widget:Shutdown()
    dragging = false
    setTimingSearchFocus(false)
    if WG.barFightTraitsHover == receiveNativeHover then WG.barFightTraitsHover = nil end
    nativeHover, hoverKey = nil, nil
end

function widget:Update(dt)
    if type(dt) ~= "number" or dt < 0 then return end
    if timing.searching and (not open or activeTab ~= "timings" or (Spring.IsGUIHidden and Spring.IsGUIHidden())) then
        setTimingSearchFocus(false)
    end
    elapsed, rosterTimer, responseTimer = elapsed + dt, rosterTimer + dt, responseTimer + dt
    if rosterTimer >= 2 then rosterTimer = 0; refreshRoster() end
    if responseTimer >= 1 then responseTimer = 0; pollResponse(); pollTimingResponse() end
    if pendingAt and elapsed - pendingAt >= OFFLINE_SECONDS then
        connectionState, checkedAt = "timeout", nil
        status = "No helper reply yet. Start the BAR Fight helper; cached traits remain available."
    end
    if ((pendingAt ~= nil or hasRecoveringProfile()) and elapsed - lastRequestAt >= RECOVERY_REFRESH_SECONDS)
        or (open and elapsed - lastRequestAt >= ACTIVE_REFRESH_SECONDS) then
        requestTraits(false)
    end
    if open and activeTab == "timings" then
        alignTimingFaction()
        local signature = timingSignature()
        if (signature or "") ~= timing.signature then requestTiming(false) end
        local recovering = timing.pendingAt or not timing.profile or timing.profile.status == "preparing" or timing.profile.stale or timing.profile.preparing
        if signature and elapsed - timing.lastRequestAt >= (recovering and RECOVERY_REFRESH_SECONDS or ACTIVE_REFRESH_SECONDS) then requestTiming(false) end
    end
    if timing.pendingAt and elapsed - timing.pendingAt >= OFFLINE_SECONDS then
        timing.connectionState, timing.checkedAt = "timeout", nil
        timing.status = "No timing helper reply yet. Start or update the BAR Fight helper."
    end
end

function widget:DrawScreen()
    if Spring.IsGUIHidden and Spring.IsGUIHidden() then hoverKey = nil; setTimingSearchFocus(false); return end
    hits, rosterArea, detailArea, panelArea, dragArea = {}, nil, nil, nil, nil
    timingSearchArea, timingListArea, timingMenuArea = nil, nil, nil
    local right, top = vsx - 20, vsy - 90
    button(right - 119, top - 28, right, top, "BAR Fight", function()
        open = not open
        if not open then dragging = false; setTimingSearchFocus(false) end
    end, open)
    if not open then drawPlayerHover(); gl.Color(1, 1, 1, 1); return end
    local width, height = math.min(820, math.max(1, vsx - 40)), math.min(610, math.max(1, vsy - 140))
    local minX, maxX = 20, math.max(20, vsx - width - 20)
    local minY, maxY = 20, math.max(20, vsy - height - 20)
    local left, bottom
    if panelPositionX == nil or panelPositionY == nil then
        left = math.max(minX, math.min(maxX, vsx - 20 - width))
        bottom = math.max(minY, math.min(maxY, vsy - 130 - height))
    else
        left = minX + math.max(0, math.min(1, panelPositionX)) * (maxX - minX)
        bottom = minY + math.max(0, math.min(1, panelPositionY)) * (maxY - minY)
    end
    left, bottom = math.max(minX, math.min(left, maxX)), math.max(minY, math.min(bottom, maxY))
    local panelTop
    top = top - 40
    panelTop = bottom + height
    right = left + width
    top = panelTop
    panelArea = {left, bottom, right, top}
    -- All titlebar space is draggable; button hitboxes take precedence below.
    dragArea = {left, top - 49, right, top}
    rect(left, bottom, right, top, palette.background)
    rect(left, top - 49, right, top, palette.surface)
    drawText("BAR FIGHT", left + 17, top - 24, 18, palette.accent)
    if width >= 600 then
        button(left + 142, top - 37, left + 210, top - 11, "Traits", function() activeTab = "traits"; setTimingSearchFocus(false) end, activeTab == "traits")
        button(left + 218, top - 37, left + 315, top - 11, "Build timings", function()
            activeTab = "timings"; setTimingSearchFocus(false)
            if timing.signature ~= timingSignature() then requestTiming(false) end
        end, activeTab == "timings")
    end
    local refreshedAt = activeTab == "timings" and timing.lastRequestAt or lastRequestAt
    local remaining = math.max(0, math.ceil(REFRESH_SECONDS - (elapsed - refreshedAt)))
    button(right - 146, top - 37, right - 45, top - 11, remaining > 0 and ("Refresh " .. remaining .. "s") or "Refresh",
        function() if activeTab == "timings" then requestTiming(true) else requestTraits(true) end end)
    button(right - 38, top - 37, right - 10, top - 11, "X", function() open, dragging = false, false; setTimingSearchFocus(false) end)
    local statusLine = activeTab == "timings" and timing.status or status
    if not supportedMap() then statusLine = "Available on Supreme Isthmus v2.1 only. No live match data is recorded." end
    drawText(fit(statusLine, width - 34, 11), left + 17, top - 69, 11, pendingAt and palette.warning or palette.muted)
    local connectionText, connectionColor = connectionLabel()
    if activeTab == "timings" then connectionText, connectionColor = connectionLabel(timing.connectionState, timing.checkedAt) end
    local connectionWidth = math.min(width - 34, 300)
    drawText(fit(connectionText, connectionWidth, 10), left + 17, bottom + 12, 10, connectionColor)
    if width > 520 then
        drawText(fit("Public history | Scroll either column", width - connectionWidth - 51, 10), left + connectionWidth + 34, bottom + 12, 10, palette.muted)
    end
    if not supportedMap() then gl.Color(1, 1, 1, 1); return end
    local rosterWidth = math.max(160, math.min(222, width * .29))
    local divider = left + rosterWidth
    rect(divider, bottom + 36, divider + 1, top - 84, palette.border)
    local listTop, listBottom = top - 88, bottom + 40
    rosterArea = {left + 8, listBottom, divider - 7, listTop}
    local capacity = math.max(1, math.floor((listTop - listBottom) / 34))
    rosterScroll = math.max(0, math.min(rosterScroll, math.max(0, #roster - capacity)))
    local allies, nextAlly = {}, 1
    for _, row in ipairs(roster) do if not allies[row.ally] then allies[row.ally] = nextAlly; nextAlly = nextAlly + 1 end end
    for index = rosterScroll + 1, math.min(#roster, rosterScroll + capacity) do
        local row, y = roster[index], listTop - (index - rosterScroll) * 34
        button(left + 8, y, divider - 7, y + 30, row.name,
            function()
                selectedPlayer, selectedSpot, expandedTrait, traitScroll = row.player_id, selectionFor(row).spot or row.startSpot, nil, 0
                timingMenu = nil
                setTimingSearchFocus(false)
                if activeTab == "timings" then requestTiming(false) end
            end, selectedPlayer == row.player_id)
        hits[#hits].player = row
        local red, green, blue
        if Spring.GetTeamColor then red, green, blue = Spring.GetTeamColor(row.team) end
        rect(left + 9, y + 1, left + 12, y + 29, red and {red, green, blue, 1} or palette.accent)
        drawText("T" .. allies[row.ally], divider - 12, y + 3, 9, palette.muted, "ro")
    end
    local detailsTop = top - 84
    if width < 600 then
        local middle = (divider + right) / 2
        button(divider + 8, detailsTop - 28, middle - 4, detailsTop - 2, "Traits", function() activeTab = "traits"; setTimingSearchFocus(false) end, activeTab == "traits")
        button(middle + 4, detailsTop - 28, right - 8, detailsTop - 2, "Build timings", function()
            activeTab = "timings"; setTimingSearchFocus(false); if timing.signature ~= timingSignature() then requestTiming(false) end
        end, activeTab == "timings")
        detailsTop = detailsTop - 32
    end
    if activeTab == "timings" then drawTimings(divider + 17, listBottom, right - 17, detailsTop)
    else drawDetails(divider + 17, listBottom, right - 17, detailsTop) end
    drawPlayerHover()
    gl.Color(1, 1, 1, 1)
end

function widget:MousePress(x, y, buttonNumber)
    if Spring.IsGUIHidden and Spring.IsGUIHidden() then return false end
    if timing.searching and not inside(x, y, timingSearchArea) and not inside(x, y, timingListArea) then setTimingSearchFocus(false) end
    if timingMenu and not inside(x, y, timingMenuArea) then timingMenu = nil end
    if buttonNumber ~= 1 then return open and inside(x, y, panelArea) or false end
    for index = #hits, 1, -1 do if inside(x, y, hits[index]) then hits[index].action(); return true end end
    if open and dragArea and inside(x, y, dragArea) then
        dragging = true
        dragOffsetX, dragOffsetY = x - panelArea[1], y - panelArea[2]
        return true
    end
    return open and inside(x, y, panelArea) or false
end

function widget:MouseMove(x, y)
    if not dragging then return false end
    local width, height = panelArea[3] - panelArea[1], panelArea[4] - panelArea[2]
    local minX, maxX = 20, math.max(20, vsx - width - 20)
    local minY, maxY = 20, math.max(20, vsy - height - 20)
    local left = math.max(minX, math.min(x - dragOffsetX, maxX))
    local bottom = math.max(minY, math.min(y - dragOffsetY, maxY))
    panelPositionX = maxX > minX and (left - minX) / (maxX - minX) or 0
    panelPositionY = maxY > minY and (bottom - minY) / (maxY - minY) or 0
    return true
end

function widget:MouseRelease(_, _, buttonNumber)
    if buttonNumber ~= 1 or not dragging then return false end
    dragging = false
    return true
end

function widget:MouseWheel(up)
    if not open or not Spring.GetMouseState then return false end
    if Spring.IsGUIHidden and Spring.IsGUIHidden() then return false end
    local x, y = Spring.GetMouseState()
    if timing.searching and inside(x, y, timingListArea) then timing.scroll = math.max(0, timing.scroll + (up and -1 or 1)); return true end
    if inside(x, y, rosterArea) then rosterScroll = math.max(0, rosterScroll + (up and -1 or 1)); return true end
    if inside(x, y, detailArea) then traitScroll = math.max(0, traitScroll + (up and -1 or 1)); return true end
    return false
end

function widget:IsAbove(x, y)
    if Spring.IsGUIHidden and Spring.IsGUIHidden() then return false end
    for _, hit in ipairs(hits) do if inside(x, y, hit) then return true end end
    return open and inside(x, y, panelArea) or false
end

function widget:GetTooltip(x, y)
    if x and y then
        for _, hit in ipairs(hits) do
            if inside(x, y, hit) then
                if hit.player then return "" end
                if hit.tooltip then return hit.tooltip end
                return "BAR Fight: historical traits only. Click a player and choose a historical position. /barfight toggles the panel."
            end
        end
        if inside(x, y, dragArea) then return "Drag to move BAR Fight" end
    end
    return "BAR Fight: historical traits only. Click a player and choose a historical position. /barfight toggles the panel."
end

function widget:TextCommand(command)
    if command == "barfight" then open = not open; if not open then dragging = false; setTimingSearchFocus(false) end; return true end
    if command == "barfight refresh" then if activeTab == "timings" then requestTiming(true) else requestTraits(true) end; return true end
    local unit = command:match("^barfight timing%s+(.+)$")
    if command == "barfight timing" or unit then
        open, activeTab = true, "timings"
        setTimingSearchFocus(false)
        if unit then
            unit = textValue(unit, 100):lower()
            local chosen
            for _, item in ipairs(timing.units) do if item.id == unit or item.label:lower() == unit then chosen = item; break end end
            if chosen then chooseTimingUnit(chosen)
            elseif timingUnitID(unit) then chooseTimingUnit({id = unit, label = unit})
            else timing.search, timing.scroll = unit, 0; setTimingSearchFocus(true) end
        end
        if timing.signature ~= timingSignature() then requestTiming(false) end
        return true
    end
    return false
end

function widget:TextInput(text)
    if not open or activeTab ~= "timings" or not timing.searching
        or (Spring.IsGUIHidden and Spring.IsGUIHidden()) then return false end
    timing.search, timing.scroll = textValue(timing.search .. textValue(text, 100), 100), 0
    return true
end

function widget:KeyPress(key, modifiers)
    if not open or activeTab ~= "timings" or not timing.searching
        or (Spring.IsGUIHidden and Spring.IsGUIHidden()) then return false end
    searchPressedKeys[key] = true
    if key == 27 then setTimingSearchFocus(false); return true end
    if key == 8 then
        local cut = #timing.search
        while cut > 0 and timing.search:byte(cut) >= 128 and timing.search:byte(cut) <= 191 do cut = cut - 1 end
        timing.search, timing.scroll = timing.search:sub(1, math.max(0, cut - 1)), 0
        return true
    end
    if key == 13 then local matches = filteredTimingUnits(); if matches[timing.scroll + 1] then chooseTimingUnit(matches[timing.scroll + 1]) end; return true end
    if key == 9 then setTimingSearchFocus(false); return true end
    if key == 273 or key == 274 then timing.scroll = math.max(0, timing.scroll + (key == 273 and -1 or 1)); return true end
    -- Suppress game bindings only while this explicit search field has focus.
    return true
end

function widget:KeyRelease(key)
    -- Let a camera/movement key held before focusing the field finish normally.
    if searchHeldKeys[key] then searchHeldKeys[key] = nil; searchPressedKeys[key] = nil; return false end
    if searchPressedKeys[key] then searchPressedKeys[key] = nil; return true end
    return timing.searching
end

function widget:ViewResize(x, y)
    if integer(x, 100000) and integer(y, 100000) and x > 0 and y > 0 then vsx, vsy = x, y end
end

function widget:GetConfigData()
    return {schema = 1, open = open, position = panelPositionX ~= nil and {x = panelPositionX, y = panelPositionY} or nil}
end

function widget:SetConfigData(data)
    if type(data) == "table" and data.schema == 1 then
        open = data.open == true
        if type(data.position) == "table" and type(data.position.x) == "number" and type(data.position.y) == "number"
            and data.position.x == data.position.x and data.position.y == data.position.y then
            panelPositionX = math.max(0, math.min(1, data.position.x))
            panelPositionY = math.max(0, math.min(1, data.position.y))
        end
    end
end
