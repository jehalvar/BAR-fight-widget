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
local MAP = "Supreme Isthmus v2.1"
local MAX_BYTES, MAX_PLAYERS = 1048576, 16
local MAX_HOVER_TRAITS = 4
-- Keep older helper caches consistent with the website's retired badges.
local RETIRED_TRAITS = {consistent_opener = true, early_defence = true, mobile_heavy = true, leaker = true}
local REFRESH_SECONDS, OFFLINE_SECONDS = 60, 30
local RECOVERY_REFRESH_SECONDS, ACTIVE_REFRESH_SECONDS = 120, 240
local INSTANCE_TOKEN = tostring({}):gsub("[^a-zA-Z0-9]", "")
local NULL = {}
local POSITION_NAMES = {
    P1 = "Geo sea", P2 = "Tech", P3 = "Air", P4 = "Pond",
    P5 = "Front (suicide)", P6 = "Front (second)", P7 = "Geo tech", P8 = "Beach sea",
}
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
local rosterScroll, traitScroll = 0, 0
local lastSignature, lastRequestID, lastResponseText = "", nil, nil
local requestSequence, lastRequestAt, pendingAt, lastSuccessAt = 0, -REFRESH_SECONDS, nil, nil
local status = "Open BAR Fight to view historical traits."
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

local function requestTraits(manual)
    if not supportedMap() then status = "Traits are available for Supreme Isthmus v2.1."; return false end
    if #accounts == 0 then status = "No stable player account IDs are available in this match."; return false end
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
    if not ok then status = "Cannot write the local request. Check the BAR Fight installation."; return false end
    lastRequestID, pendingAt, lastResponseText = requestID, elapsed, nil
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
    table.sort(rows, function(a, b)
        if a.ally ~= b.ally then return a.ally < b.ally end
        if a.team ~= b.team then return a.team < b.team end
        return a.player_id < b.player_id
    end)
    local selectedExists = false
    for _, row in ipairs(rows) do if row.player_id == selectedPlayer then selectedExists = true end end
    if not selectedExists then selectedPlayer = rows[1] and rows[1].player_id; selectedSpot, expandedTrait = nil, nil end
    roster = rows
    local ordered = {}
    for id in pairs(ids) do ordered[#ordered + 1] = id end
    table.sort(ordered, function(a, b) return tonumber(a) < tonumber(b) end)
    if #ordered > MAX_PLAYERS then
        accounts = {}; status = "This panel supports up to 16 player accounts."; return
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
        status = "The helper response was incomplete or invalid; waiting for valid data."; return
    end
    if response.schema ~= 1 or response.request_id ~= lastRequestID then return end
    if response.map ~= nil and response.map ~= MAP then return end
    if response.ok ~= true then
        status = "Helper unavailable: " .. (textValue(response.error, 140) ~= "" and textValue(response.error, 140) or "please check the connection.")
        pendingAt = nil
        return
    end
    if type(response.profiles) ~= "table" or #response.profiles > MAX_PLAYERS then
        status = "The helper returned an unsupported profile response."; return
    end
    local incoming, seen = {}, {}
    for _, raw in ipairs(response.profiles) do
        local profile = validProfile(raw)
        if not profile or seen[profile.account_id] then status = "The helper returned an invalid player profile."; return end
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
    local profile = profiles[row.account_id]
    if not profile then
        drawText(pendingAt and "Loading this player’s historical profile..." or "No historical profile is available yet.", x1, top - 75, 12, palette.muted)
        drawText("Keep the BAR Fight helper running, then refresh.", x1, top - 97, 12, palette.muted)
        return
    end
    local dateLabel = profile.period.start_date ~= "" and (profile.period.start_date .. " to " .. profile.period.end_date .. " UTC") or "Historical replay interval"
    local freshness = profile.generated_at ~= "" and ("  |  Updated " .. profile.generated_at) or ""
    drawText(fit(dateLabel .. freshness .. (profile.stale and "  |  Stale cache" or ""), x2 - x1, 11),
        x1, top - 62, 11, profile.stale and palette.warning or palette.muted)
    if profile.status == "preparing" or profile.preparing then
        drawText(profile.preparation_note ~= "" and profile.preparation_note or "History is being prepared...",
            x1, top - 78, 10, palette.warning)
    end
    if #profile.positions == 0 then
        local message = profile.status == "preparing" and "This profile is being prepared. Refresh in a minute."
            or "No captured games for this player in the current interval."
        drawText(fit(message, x2 - x1, 12), x1, top - 92, 12, palette.muted)
        return
    end
    local position
    for _, candidate in ipairs(profile.positions) do if candidate.spot == selectedSpot then position = candidate end end
    if not position then
        for _, candidate in ipairs(profile.positions) do if not position or candidate.games > position.games then position = candidate end end
        selectedSpot = position.spot
    end
    drawText("Historical position - choose a role to inspect", x1, top - 87, 12, palette.muted)
    local chipWidth = (x2 - x1 - 8) / 2
    for index, candidate in ipairs(profile.positions) do
        local col, line = (index - 1) % 2, math.floor((index - 1) / 2)
        local chipX, chipY = x1 + col * (chipWidth + 8), top - 121 - line * 29
        button(chipX, chipY, chipX + chipWidth, chipY + 25, candidate.position_name,
            function() selectedSpot, expandedTrait, traitScroll = candidate.spot, nil, 0 end, candidate.spot == selectedSpot)
    end
    local y = top - 123 - math.ceil(#profile.positions / 2) * 29
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

function widget:Initialize()
    if Spring.GetViewGeometry then vsx, vsy = Spring.GetViewGeometry() end
    refreshRoster()
    WG.barFightTraitsHover = receiveNativeHover
    if Spring.Echo then Spring.Echo("[BAR Fight] Click the BAR Fight button or type /barfight to open the panel. Choose a player and a historical position.") end
end

function widget:Shutdown()
    dragging = false
    if WG.barFightTraitsHover == receiveNativeHover then WG.barFightTraitsHover = nil end
    nativeHover, hoverKey = nil, nil
end

function widget:Update(dt)
    if type(dt) ~= "number" or dt < 0 then return end
    elapsed, rosterTimer, responseTimer = elapsed + dt, rosterTimer + dt, responseTimer + dt
    if rosterTimer >= 2 then rosterTimer = 0; refreshRoster() end
    if responseTimer >= 1 then responseTimer = 0; pollResponse() end
    if pendingAt and elapsed - pendingAt >= OFFLINE_SECONDS then
        status = "No helper reply yet. Start the BAR Fight helper; cached traits remain available."
    end
    if ((pendingAt ~= nil or hasRecoveringProfile()) and elapsed - lastRequestAt >= RECOVERY_REFRESH_SECONDS)
        or (open and elapsed - lastRequestAt >= ACTIVE_REFRESH_SECONDS) then
        requestTraits(false)
    end
end

function widget:DrawScreen()
    if Spring.IsGUIHidden and Spring.IsGUIHidden() then hoverKey = nil; return end
    hits, rosterArea, detailArea, panelArea, dragArea = {}, nil, nil, nil, nil
    local right, top = vsx - 20, vsy - 90
    button(right - 119, top - 28, right, top, "BAR Fight", function()
        open = not open
        if not open then dragging = false end
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
    drawText("Historical player traits", left + 147, top - 23, 12, palette.muted)
    local remaining = math.max(0, math.ceil(REFRESH_SECONDS - (elapsed - lastRequestAt)))
    button(right - 146, top - 37, right - 45, top - 11, remaining > 0 and ("Refresh " .. remaining .. "s") or "Refresh",
        function() requestTraits(true) end)
    button(right - 38, top - 37, right - 10, top - 11, "X", function() open, dragging = false, false end)
    local statusLine = status
    if not supportedMap() then statusLine = "Available on Supreme Isthmus v2.1 only. No live match data is recorded." end
    drawText(fit(statusLine, width - 34, 11), left + 17, top - 69, 11, pendingAt and palette.warning or palette.muted)
    drawText("Public replay history  |  Mirrored positions combined  |  Scroll either column", left + 17, bottom + 12, 10, palette.muted)
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
            function() selectedPlayer, selectedSpot, expandedTrait, traitScroll = row.player_id, nil, nil, 0 end, selectedPlayer == row.player_id)
        hits[#hits].player = row
        local red, green, blue
        if Spring.GetTeamColor then red, green, blue = Spring.GetTeamColor(row.team) end
        rect(left + 9, y + 1, left + 12, y + 29, red and {red, green, blue, 1} or palette.accent)
        drawText("T" .. allies[row.ally], divider - 12, y + 3, 9, palette.muted, "ro")
    end
    drawDetails(divider + 17, listBottom, right - 17, top - 84)
    drawPlayerHover()
    gl.Color(1, 1, 1, 1)
end

function widget:MousePress(x, y, buttonNumber)
    if Spring.IsGUIHidden and Spring.IsGUIHidden() then return false end
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
    if command == "barfight" then open = not open; if not open then dragging = false end; return true end
    if command == "barfight refresh" then requestTraits(true); return true end
    return false
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
