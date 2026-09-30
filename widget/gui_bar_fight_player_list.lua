-- BAR Fight adapter for BAR's native player list. Its distinct filename avoids
-- replacing an existing user-authored gui_advplayerslist.lua.
-- Copyright (C) 2026 BAR Fight contributors. GNU GPL, version 2 or later.
-- The actual list remains the version supplied by the currently loaded game:
-- https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/luaui/Widgets/gui_advplayerslist.lua
-- Only trusted game-archive Lua is loaded; web responses are never code.

local widget = widget
local SOURCE_PATH = "LuaUI/Widgets/gui_advplayerslist.lua"
local MAX_SOURCE_BYTES = 2097152

local function notice(message)
    if Spring and Spring.Echo then Spring.Echo("[BAR Fight] " .. message) end
end

if not VFS or type(VFS.LoadFile) ~= "function" or VFS.ZIP == nil then
    notice("The bundled player list could not be read.")
    return false
end

-- ZIP is essential: RAW_FIRST would recursively load this adapter.
local source = VFS.LoadFile(SOURCE_PATH, VFS.ZIP)
if type(source) ~= "string" or #source == 0 or #source > MAX_SOURCE_BYTES then
    notice("The bundled player list could not be read.")
    return false
end
source = source:gsub("\r\n", "\n")

local function hasOnce(value)
    local first, finish = source:find(value, 1, true)
    return first ~= nil and source:find(value, finish + 1, true) == nil
end

-- Check the upstream hit-test expressions, not a release number. A future layout
-- change leaves the original list running and disables only this integration.
local compatible = hasOnce("function NameTip(mouseX, playerID, accountID, nameIsAlias)")
    and hasOnce("and mouseX >= widgetPosX + (m_name.posX + (1 * playerScale)) * widgetScale")
    and hasOnce("and mouseX <= widgetPosX + (m_name.posX + m_name.width) * widgetScale")
    and hasOnce("local tipPosY = widgetPosY + ((widgetHeight - vOffset) * widgetScale)")
    and hasOnce("if mouseY >= tipPosY and mouseY <= tipPosY + (16 * widgetScale * playerScale) then")
    and hasOnce("DrawPlayer(drawObject, leader, drawListOffset[i], mouseX, mouseY, true, false, false)")
    and hasOnce("function widget:DrawScreen()")
    and hasOnce("function widget:Shutdown()")

-- This suffix shares the bundled widget's lexical scope. It reads its actual
-- live layout and visible rows; it neither reconstructs nor guesses the layout.
-- Run after the native drawing pass so cached rendering cannot leave hover stale.
local hoverSuffix = [==[

-- Keep adapter locals in their own function: the upstream chunk already uses
-- Lua 5.1's limit of 200 local variables in some BAR releases.
;(function()
    local barFightDrawScreen = widget.DrawScreen
    local barFightShutdown = widget.Shutdown

    local function barFightNotifyHover()
        local callback = WG and WG.barFightTraitsHover
        if type(callback) ~= "function" then return end
        if (Spring.IsGUIHidden and Spring.IsGUIHidden())
            or (WG.topbar and WG.topbar.showingQuit and WG.topbar.showingQuit()) then
            pcall(callback, nil)
            return
        end
        local x, y = spGetMouseState()
        local left = widgetPosX + (m_name.posX + (1 * playerScale)) * widgetScale
        local right = widgetPosX + (m_name.posX + m_name.width) * widgetScale
        if type(x) == "number" and type(y) == "number"
            and x >= left and x <= right and apiAbsPosition
            and x >= apiAbsPosition[2] and x <= apiAbsPosition[4]
            and y >= apiAbsPosition[3] and y <= apiAbsPosition[1] then
            for index, playerID in ipairs(drawList) do
                local p = player[playerID]
                local offset = drawListOffset[index]
                if playerID >= 0 and playerID < specOffset and p and p.team ~= nil
                    and not p.spec and not p.ai and p.accountID and type(offset) == "number" then
                    local bottom = widgetPosY + ((widgetHeight - offset) * widgetScale)
                    local top = bottom + (16 * widgetScale * playerScale)
                    if y >= bottom and y <= top then
                        pcall(callback, playerID, p.accountID, left, bottom, right, top)
                        return
                    end
                end
            end
        end
        pcall(callback, nil)
    end

    function widget:DrawScreen(...)
        barFightDrawScreen(self, ...)
        -- A changed game implementation or disabled traits widget must not stop
        -- the game's own list. Failure clears the supplementary hover only.
        local ok = pcall(barFightNotifyHover)
        if not ok and WG and type(WG.barFightTraitsHover) == "function" then
            pcall(WG.barFightTraitsHover, nil)
        end
    end

    function widget:Shutdown(...)
        if WG and type(WG.barFightTraitsHover) == "function" then
            pcall(WG.barFightTraitsHover, nil)
        end
        return barFightShutdown(self, ...)
    end
end)()
]==]

local chunk, err
if compatible then chunk, err = loadstring(source .. hoverSuffix, "@" .. SOURCE_PATH) end
if not chunk then
    notice("Native player-name hover is unavailable for this game version; the original list is retained.")
    chunk, err = loadstring(source, "@" .. SOURCE_PATH)
end
if not chunk then
    notice("The bundled player list could not be compiled: " .. tostring(err))
    return false
end
-- BAR's own loader uses the widget table as the environment in exactly this way.
setfenv(chunk, widget)
return chunk()
