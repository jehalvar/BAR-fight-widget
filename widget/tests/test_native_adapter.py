"""Check the native-list adapter without loading BAR or modifying its files."""
from pathlib import Path
import unittest

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    LuaRuntime = None


SOURCE = Path(__file__).resolve().parents[1] / "gui_bar_fight_player_list.lua"

# Small native-list fixture retaining the source expressions guarded by the
# adapter. Row two models a different player; negative entries model headings.
NATIVE = r'''
local widget = widget
local widgetPosX, widgetPosY, widgetHeight = 100, 100, 300
local widgetScale, playerScale, specOffset = 1.5, .8, 256
local m_name = {posX=20, width=100}
local apiAbsPosition = {560, 100, 100, 420}
local drawList, drawListOffset = {-1, 3, 7}, {0, 30, 60}
local player = {
    [3]={team=1, accountID=21705, posY=9999},
    [7]={team=2, accountID=71812, posY=9999},
}
local spGetMouseState = Spring.GetMouseState
function widget:GetInfo() return {name="AdvPlayersList", enabled=true} end
function DrawPlayer(playerID, leader, vOffset, mouseX, mouseY, onlyMainList, onlyMainList2, onlyMainList3)
    local tipPosY = widgetPosY + ((widgetHeight - vOffset) * widgetScale)
    if mouseY >= tipPosY and mouseY <= tipPosY + (16 * widgetScale * playerScale) then
        NameTip(mouseX, playerID, player[playerID].accountID, false)
    end
end
function NameTip(mouseX, playerID, accountID, nameIsAlias)
    local pTip = player[playerID]
    if
        accountID
        and mouseX >= widgetPosX + (m_name.posX + (1 * playerScale)) * widgetScale
        and mouseX <= widgetPosX + (m_name.posX + m_name.width) * widgetScale
        and WG.playernames
    then originalNameTips = originalNameTips + 1 end
end
function drawMainList()
    local leader, mouseX, mouseY = false, Spring.GetMouseState()
    for i, drawObject in ipairs(drawList) do
        if drawObject >= 0 then
            DrawPlayer(drawObject, leader, drawListOffset[i], mouseX, mouseY, true, false, false)
        end
    end
end
function widget:DrawScreen()
    nativeDraws = nativeDraws + 1
    -- Native render caching intentionally does not call DrawPlayer every frame.
end
function widget:Shutdown()
    nativeShutdowns = nativeShutdowns + 1
end
function widget:SetTestState(kind)
    if kind == "collapse" then drawList, drawListOffset = {-1, 7}, {0, 30}
    elseif kind == "spectator" then player[3].spec = true
    elseif kind == "ai" then player[3].ai = true
    elseif kind == "unknown" then player[3].accountID = nil
    elseif kind == "resize" then widgetScale = 1 end
end
'''

HARNESS = r'''
loaded, notifications, logs = {}, {}, {}
mouseX, mouseY, hidden = 150, 510, false
nativeDraws, nativeShutdowns, originalNameTips = 0, 0, 0
Spring = {
    GetMouseState = function() return mouseX, mouseY end,
    IsGUIHidden = function() return hidden end,
    Echo = function(value) logs[#logs+1] = value end,
}
WG = {barFightTraitsHover = function(...)
    notifications[#notifications+1] = {n=select('#', ...), ...}
end}
VFS = {
    ZIP = "archive-only",
    LoadFile = function(path, mode)
        loaded[#loaded+1] = {path,mode}
        assert(mode == VFS.ZIP, "An untrusted raw file was requested")
        return bundledSource
    end,
}
widget = setmetatable({}, {__index=_G})
widget.widget = widget
'''


@unittest.skipIf(LuaRuntime is None, "Install lupa to execute the Lua 5.1 harness")
class NativeAdapterTests(unittest.TestCase):
    def make(self, native=NATIVE):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().bundledSource = native
        lua.execute(HARNESS)
        lua.execute(SOURCE.read_text(encoding="utf-8"))
        return lua

    def draw(self, lua, x=150, y=510):
        lua.globals().mouseX, lua.globals().mouseY = x, y
        lua.execute("widget:DrawScreen()")
        notifications = lua.globals().notifications
        return notifications[len(notifications)] if len(notifications) else None

    def test_reads_only_current_game_archive_and_retains_native_identity(self):
        lua = self.make()
        self.assertEqual(len(lua.globals().loaded), 1)
        self.assertEqual(lua.globals().loaded[1][1], "LuaUI/Widgets/gui_advplayerslist.lua")
        self.assertEqual(lua.execute("return widget:GetInfo().name"), "AdvPlayersList")

    def test_name_hover_supplies_exact_native_rectangle_each_frame(self):
        lua = self.make()
        first = self.draw(lua)
        self.assertEqual([first[i] for i in range(1, 7)], [3, 21705, 131.2, 505, 280, 524.2])
        self.draw(lua)
        self.assertEqual(len(lua.globals().notifications), 2)
        self.assertEqual(lua.execute("return widget.nativeDraws"), 2)
        self.assertEqual(lua.execute("return widget.originalNameTips or 0"), 0)

    def test_native_chunk_at_lua_local_variable_limit_still_compiles(self):
        # NATIVE has 13 top-level locals. Real BAR releases can already use all
        # 200, so the hook must not add any locals to their outer chunk.
        reserved = "local " + ",".join(f"reserved{i}" for i in range(187)) + "\n"
        lua = self.make(reserved + NATIVE)
        self.assertEqual(self.draw(lua)[1], 3)

    def test_name_column_excludes_ping_resources_and_outside_rows(self):
        lua = self.make()
        for x, y in [(350, 510), (120, 510), (150, 540), (150, 50)]:
            with self.subTest(x=x, y=y):
                notification = self.draw(lua, x, y)
                self.assertIsNone(notification[1])

    def test_second_player_and_collapsed_rows_use_live_layout(self):
        lua = self.make()
        self.assertEqual(self.draw(lua, 150, 470)[1], 7)
        lua.execute('widget:SetTestState("collapse")')
        self.assertEqual(self.draw(lua, 150, 510)[1], 7)
        self.assertIsNone(self.draw(lua, 150, 470)[1])

    def test_resize_uses_current_native_scale(self):
        lua = self.make()
        lua.execute('widget:SetTestState("resize")')
        notification = self.draw(lua, 130, 375)
        self.assertEqual([notification[i] for i in range(1, 7)], [3, 21705, 120.8, 370, 220, 382.8])

    def test_ineligible_players_and_hidden_interface_clear_hover(self):
        for state in ["spectator", "ai", "unknown"]:
            with self.subTest(state=state):
                lua = self.make()
                lua.execute('widget:SetTestState("' + state + '")')
                self.assertIsNone(self.draw(lua)[1])
        lua = self.make()
        lua.globals().hidden = True
        self.assertIsNone(self.draw(lua)[1])

    def test_shut_down_clears_hover_and_retains_native_shutdown(self):
        lua = self.make()
        self.draw(lua)
        lua.execute("widget:Shutdown()")
        notifications = lua.globals().notifications
        self.assertIsNone(notifications[len(notifications)][1])
        self.assertEqual(lua.execute("return widget.nativeShutdowns"), 1)

    def test_unknown_source_shape_runs_original_without_any_hover_hook(self):
        lua = self.make(NATIVE.replace("m_name.width) * widgetScale", "m_name.width + 1) * widgetScale"))
        self.assertIsNone(self.draw(lua))
        self.assertEqual(lua.execute("return widget.nativeDraws"), 1)
        self.assertEqual(len(lua.globals().logs), 1)

    def test_absent_or_broken_callback_does_not_break_native_draw(self):
        lua = self.make()
        lua.execute("WG.barFightTraitsHover = nil")
        self.draw(lua)
        lua.execute('WG.barFightTraitsHover = function() error("disabled") end')
        self.draw(lua)
        self.assertEqual(lua.execute("return widget.nativeDraws"), 2)

    def test_missing_archive_never_tries_raw_file(self):
        lua = self.make(None)
        self.assertEqual(len(lua.globals().loaded), 1)
        self.assertIsNone(lua.globals().widget.GetInfo)


if __name__ == "__main__":
    unittest.main()
