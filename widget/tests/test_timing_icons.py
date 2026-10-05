"""Focused regression checks for timing-button unit icons."""
import unittest

import test_widget as widget_tests


UNIT_IDS = {
    'armack': 101, 'corack': 102, 'legack': 103,
    'armfus': 201, 'corfus': 202, 'legfus': 203,
    'armmanni': 301, 'armmart': 302, 'cormart': 303, 'armliche': 304,
}


@unittest.skipIf(widget_tests.LuaRuntime is None, 'Optional lupa Lua 5.1 runtime is not installed')
class TimingIconTests(unittest.TestCase):
    def setUp(self):
        self.case = widget_tests.WidgetTests('runTest')
        self.case.setUp()
        self.lua = self.case.lua
        self.globals = self.case.globals
        definitions = ','.join(f'{code}={{id={unit_id}}}' for code, unit_id in UNIT_IDS.items())
        self.lua.execute(f'''
            UnitDefNames = {{{definitions}}}
            textureEvents, iconRects, drawEvents = {{}}, {{}}, {{}}
            currentTexture, failedTexture = nil, nil
            local originalRect, originalText = gl.Rect, gl.Text
            gl.Rect = function(...)
                assert(currentTexture == nil, "texture state leaked into rectangle")
                drawEvents[#drawEvents + 1] = {{kind="rect"}}
                return originalRect(...)
            end
            gl.Text = function(...)
                assert(currentTexture == nil, "texture state leaked into text")
                drawEvents[#drawEvents + 1] = {{kind="text"}}
                return originalText(...)
            end
            gl.Texture = function(texture)
                textureEvents[#textureEvents + 1] = texture
                if texture == false then currentTexture = nil; return true end
                if texture == failedTexture then currentTexture = nil; return false end
                currentTexture = texture
                return true
            end
            gl.TexRect = function(x1, y1, x2, y2)
                iconRects[#iconRects + 1] = {{texture=currentTexture, x1=x1, y1=y1, x2=x2, y2=y2}}
                drawEvents[#drawEvents + 1] = {{kind="icon", texture=currentTexture}}
            end
        ''')

    def open_timing_panel(self):
        self.case.start()
        self.case.call('TextCommand', 'barfight timing')
        self.case.timing_respond(units=widget_tests.quick_catalogue())

    def drawn_text(self, draw=False):
        if draw:
            self.case.draw()
        return [item['text'] for item in self.globals.drawn.values()]

    def icon_textures(self):
        return [entry['texture'] for entry in self.globals.iconRects.values()]

    def clear_draw_capture(self):
        self.lua.execute('iconRects, textureEvents, drawEvents = {}, {}, {}')

    def test_quick_group_icons_follow_selected_faction_and_presets_remain_clickable(self):
        self.open_timing_panel()
        self.case.click_text('All factions (unknown)')
        self.case.click_text('Armada')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('#101', self.icon_textures())
        self.case.click_text('First T2 con')
        self.assertEqual(self.case.timing_request()['unit'], 'group:t2-constructor-armada')

        self.case.click_text('Armada')
        self.case.click_text('Cortex')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('#102', self.icon_textures())
        self.assertNotIn('#101', self.icon_textures())
        self.case.click_text('First T2 con')
        self.assertEqual(self.case.timing_request()['unit'], 'group:t2-constructor-cortex')
        self.assertIn('#102', self.icon_textures())

        self.case.click_text('Cortex')
        self.case.click_text('Legion')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('#103', self.icon_textures())
        self.assertNotIn('#102', self.icon_textures())
        self.assertTrue(any(entry is False for entry in self.globals.textureEvents.values()))

    def test_exact_unit_icon_appears_in_selected_field_and_search_result(self):
        self.open_timing_panel()
        self.case.click_text('Unit: T2 constructors  [Search]')
        self.globals.engineTextInput('Fusion')
        self.clear_draw_capture()
        texts = self.case.draw()
        self.assertIn('#201', self.icon_textures())
        self.assertIn('Fusion Reactor [armfus]', self.drawn_text())
        self.case.click_text('Fusion Reactor [armfus]')
        self.assertEqual(self.case.timing_request()['unit'], 'armfus')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('#201', self.icon_textures())

    def test_missing_or_failed_unit_icon_uses_placeholder_and_restores_draw_state(self):
        self.open_timing_panel()
        self.case.click_text('Unit: T2 constructors  [Search]')
        self.globals.engineTextInput('Liche')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('#304', self.icon_textures())
        self.globals.failedTexture = '#304'
        self.clear_draw_capture()
        self.case.draw()
        texts = self.drawn_text()
        self.assertIn('?', texts)
        self.assertNotIn('#304', self.icon_textures())
        self.assertIsNone(self.globals.currentTexture)
        self.assertTrue(any(entry is False for entry in self.globals.textureEvents.values()))

        # An unknown UnitDefNames entry must remain selectable without a bind.
        extra = widget_tests.quick_catalogue() + [dict(id='ghostunit', base_id='ghostunit', label='Ghost Unit',
                                                       kind='unit', faction='armada')]
        self.case.timing_respond(units=extra)
        self.globals.failedTexture = None
        self.globals.engineKeyPress(27)
        self.clear_draw_capture()
        self.case.draw()
        search_label = next(text for text in self.drawn_text()
                            if text.startswith('Unit: ') and text.endswith('[Search]'))
        self.case.click_text(search_label)
        self.globals.engineTextInput('Ghost')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('Search: Ghost |', self.drawn_text())
        self.assertIsNone(self.globals.currentTexture)
        self.clear_draw_capture()
        self.case.click_text('Ghost Unit [ghostunit]')
        self.assertEqual(self.case.timing_request()['unit'], 'ghostunit')
        self.clear_draw_capture()
        self.case.draw()
        self.assertIn('?', self.drawn_text())
        self.assertNotIn('#nil', self.icon_textures())
        self.assertNotIn('#ghostunit', self.icon_textures())


if __name__ == '__main__':
    unittest.main()
