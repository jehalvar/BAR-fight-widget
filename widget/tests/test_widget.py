"""Mock-engine integration checks; run with Python and the optional lupa wheel.

    python -m unittest discover -s widget/tests -v

The harness executes the real widget under Lua 5.1, without BAR, network access,
or writes to the player's configuration directory.
"""
import json
from pathlib import Path
import re
import unittest

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    LuaRuntime = None


SOURCE = Path(__file__).resolve().parents[1] / 'gui_bar_fight_traits.lua'
REQUEST = 'LuaUI/Config/bar_fight_traits_request.json'
RESPONSE = 'LuaUI/Config/bar_fight_traits_response.json'

ENGINE = r'''
widget = {}
WG = {}
files, written, drawn, rectangles, players, echoes = {}, {}, {}, {}, {}, {}
clipboard = {}
Game = {mapName = "Supreme Isthmus v2.1"}
os = {time = function() return 1720000000 end, date = os.date}
io = {open = function(path, mode)
    if mode == "wb" then
        local result = {value = ""}
        function result:write(value) self.value = self.value .. value; files[path] = self.value; written[#written+1] = path; return self end
        function result:close() return true end
        return result
    end
    if not files[path] then return nil end
    return {read = function(self, size) return string.sub(files[path], 1, size) end, close = function() return true end}
end}
Spring = {
    CreateDir = function() end,
    GetPlayerList = function() local result = {}; for id in pairs(players) do result[#result+1] = id end; table.sort(result); return result end,
    GetPlayerInfo = function(id, getPlayerOpts)
        local p = players[id]
        -- Recoil omits account options when explicitly passed false. This must
        -- match the engine: treating that argument as ignored hid missing IDs.
        local keys
        if getPlayerOpts ~= false then keys = p.keys end
        if p.legacy then return p.name, true, p.spectator or false, p.team, p.ally, 0, 0, "en", 0, keys end
        return p.name, true, p.spectator or false, p.team, p.ally, 0, 0, "en", 0, false, keys, false
    end,
    GetMyPlayerID = function() return 1 end,
    GetViewGeometry = function() return 1440, 900 end,
    GetTeamColor = function(team) return .3, .5, .7 end,
    IsGUIHidden = function() return false end,
    GetMouseState = function() return mouseX or 0, mouseY or 0 end,
    Echo = function(text) echoes[#echoes+1] = text end,
    SetClipboard = function(text) clipboard[#clipboard+1] = text end,
}
gl = {
    Color = function(r,g,b,a) assert(type(r)=="number" and type(g)=="number" and type(b)=="number" and type(a)=="number") end,
    Rect = function(x1,y1,x2,y2) assert(x2>=x1 and y2>=y1); rectangles[#rectangles+1] = {x1,y1,x2,y2} end,
    Text = function(text,x,y,size,options) drawn[#drawn+1] = {text=text,x=x,y=y,size=size,options=options} end,
    GetTextWidth = function(text) return #text * .48 end,
}
'''


def profile(account='100', name='Historical alias', status='available', stale=False):
    return dict(account_id=account, name=name, status=status, generated_at='2026-09-23T12:00:00Z', stale=stale,
                period=dict(start_date='2026-08-25', end_date='2026-09-23'),
                positions=[dict(spot='P8', position_name='Beach sea', games=30, coverage_percent=80,
                    status='available', traits=[dict(id='early_bomber_production', label='Early bomber producer',
                    frequency_percent=72.5, samples=20, description='Completed bombers early in 72.5% of measured games. Construction is not proof of an attack.')])])


@unittest.skipIf(LuaRuntime is None, 'Optional lupa Lua 5.1 runtime is not installed')
class WidgetTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(ENGINE)
        self.globals = self.lua.globals()
        self.add_player(1, 'Current name', '100', 0)
        self.add_player(2, 'Other name', '200', 1)
        self.lua.execute(SOURCE.read_text(encoding='utf-8'))
        self.widget = self.globals.widget

    def add_player(self, player, name, account=None, ally=0, spectator=False):
        keys = dict(accountid=account) if account is not None else {}
        self.globals.players[player] = self.lua.table_from(dict(name=name, team=player, ally=ally,
            spectator=spectator, keys=self.lua.table_from(keys)))

    def call(self, method, *args):
        return self.widget[method](self.widget, *args)

    def start(self):
        self.call('Initialize')
        self.call('TextCommand', 'barfight')

    def request(self):
        content = self.globals.files[REQUEST]
        return json.loads(content) if content else None

    def respond(self, profiles=None, **extra):
        response = dict(schema=1, request_id=self.request()['request_id'], ok=True,
                        profiles=profiles if profiles is not None else [profile()])
        response.update(extra)
        self.globals.files[RESPONSE] = json.dumps(response)
        self.call('Update', 1)

    def draw(self):
        self.globals.drawn = self.lua.table()
        self.call('DrawScreen')
        return [entry['text'] for entry in self.globals.drawn.values()]

    def click_text(self, text):
        self.draw()
        for entry in self.globals.drawn.values():
            if entry['text'] == text:
                return self.call('MousePress', entry['x'] + 4, entry['y'] + 3, 1)
        self.fail(f'No drawn text {text!r}')

    def hover_name(self, text):
        self.draw()
        for entry in self.globals.drawn.values():
            if entry['text'] == text and entry['size'] == 12:
                self.globals.mouseX, self.globals.mouseY = entry['x'] + 4, entry['y'] + 3
                self.draw()
                self.call('Update', .31)
                return self.draw()
        self.fail(f'No player row {text!r}')

    def native_hover(self, player=1, account='100', bounds=(1090, 500, 1210, 522)):
        self.globals.mouseX, self.globals.mouseY = bounds[0] + 10, bounds[1] + 10
        self.globals.WG.barFightTraitsHover(player, account, *bounds)
        self.draw()
        self.call('Update', .31)
        self.globals.WG.barFightTraitsHover(player, account, *bounds)
        return self.draw()

    def test_own_roster_hover_shows_cached_traits_without_click_or_request(self):
        self.start()
        other = profile('200')
        other['positions'][0]['traits'][0]['label'] = 'Economy first'
        self.respond([profile(), other])
        count = len(self.globals.written)
        texts = self.hover_name('Other name')
        self.assertIn('BAR Fight - historical traits', texts)
        self.assertIn('Economy first', texts)
        self.assertIn('Early bomber producer', texts)  # Existing selected details remain unchanged.
        self.assertIn('72.5% of games', texts)
        self.assertNotIn('72.5% of games  |  Sample: 20 games', texts)
        self.assertEqual(len(self.globals.written), count)
        self.globals.mouseX, self.globals.mouseY = 0, 0
        self.assertNotIn('BAR Fight - historical traits', self.draw())

    def test_native_hover_works_with_panel_closed_and_never_captures_clicks(self):
        self.assertLess(self.call('GetInfo')['layer'], -4)
        self.call('Initialize')
        self.respond()
        texts = self.native_hover()
        self.assertIn('BAR Fight - historical traits', texts)
        self.assertIn('Early bomber producer', texts)
        self.assertFalse(self.call('MousePress', 1100, 510, 1))
        self.assertFalse(self.call('IsAbove', 1100, 510))

    def test_compact_hover_limits_badges_and_keeps_evidence_in_details(self):
        value = profile()
        value['positions'][0]['traits'] = [dict(id=f'pattern-{n}', label=f'Pattern {n}',
            frequency_percent=70+n, samples=20, description=f'Evidence for pattern {n}.') for n in range(6)]
        self.call('Initialize')
        self.respond([value])
        writes = len(self.globals.written)
        texts = self.native_hover()
        self.assertEqual([t for t in texts if t.startswith('Pattern ')], [f'Pattern {n}' for n in range(4)])
        self.assertIn('Beach sea history - 30 games', texts)
        self.assertIn('+2 more habits in /barfight', texts)
        self.assertFalse(any('Sample:' in t or t.startswith('Updated ') or '2026-08-25' in t for t in texts))
        self.assertEqual(len(self.globals.written), writes)
        self.globals.mouseX, self.globals.mouseY = 0, 0
        self.call('TextCommand', 'barfight')
        texts = self.draw()
        self.assertIn('Pattern 5', texts)
        self.assertTrue(any('2026-08-25' in t for t in texts))
        self.click_text('Pattern 0')
        self.assertIn('Evidence for pattern 0.', self.draw())
        self.assertTrue(any('Sample: 20 games' in t for t in self.draw()))

    def test_retired_traits_are_hidden_in_old_cached_profiles(self):
        value = profile(stale=True)
        value['positions'][0]['traits'] += [dict(id=key, label='Retired '+key,
            frequency_percent=80, samples=20, description='Old rule.')
            for key in ('consistent_opener','early_defence','mobile_heavy','leaker')]
        self.call('Initialize')
        self.respond([value])
        texts = self.native_hover()
        self.assertIn('Early bomber producer', texts)
        self.assertIn('Cached history - update pending', texts)
        self.assertFalse(any(t.startswith('Retired ') for t in texts))
        self.call('TextCommand', 'barfight')
        self.globals.mouseX, self.globals.mouseY = 0, 0
        self.assertFalse(any(t.startswith('Retired ') for t in self.draw()))

    def test_startup_reads_engine_account_options_and_matches_native_identity(self):
        self.call('Initialize')
        request = self.request()
        self.assertIsNotNone(request, 'Startup must obtain account IDs and ask the helper for traits.')
        self.assertEqual(request['accounts'], ['100', '200'])
        self.assertEqual(list(self.globals.written.values()), [REQUEST])
        other = profile('200')
        other['positions'][0]['traits'][0]['label'] = 'Economy first'
        self.respond([profile(), other])
        texts = self.native_hover(player=2, account='200')
        self.assertIn('Other name', texts)
        self.assertIn('Economy first', texts)
        self.assertNotIn('Early bomber producer', texts)

    def test_bundled_native_adapter_and_traits_widget_work_together(self):
        from test_native_adapter import NATIVE, SOURCE as ADAPTER
        self.call('Initialize')
        self.respond()
        self.globals.bundledNative = NATIVE.replace('3, 7', '1, 2').replace('[3]', '[1]').replace('[7]', '[2]')\
            .replace('21705', '100').replace('71812', '200')
        self.globals.adapterSource = ADAPTER.read_text(encoding='utf-8')
        self.lua.execute('''
            VFS = {ZIP="archive-only", LoadFile=function(path,mode)
                assert(mode=="archive-only"); return bundledNative
            end}
            nativeWidget = setmetatable({nativeDraws=0,nativeShutdowns=0,originalNameTips=0}, {__index=_G})
            nativeWidget.widget = nativeWidget
            local chunk = assert(loadstring(adapterSource)); setfenv(chunk,nativeWidget); chunk()
            mouseX,mouseY=150,510
            nativeWidget:DrawScreen()
        ''')
        self.draw()
        self.call('Update', .31)
        self.lua.execute('nativeWidget:DrawScreen()')
        self.assertIn('Early bomber producer', self.draw())
        self.lua.execute('mouseX=350; nativeWidget:DrawScreen()')
        self.assertNotIn('BAR Fight - historical traits', self.draw())
        self.assertEqual(self.lua.execute('return nativeWidget.nativeDraws'), 3)

    def test_native_hover_rejects_wrong_account_and_resource_column(self):
        self.call('Initialize')
        self.respond()
        self.assertNotIn('BAR Fight - historical traits', self.native_hover(account='200'))
        self.native_hover()
        self.globals.mouseX = 1240
        self.assertNotIn('BAR Fight - historical traits', self.draw())

    def test_native_hover_expires_and_shutdown_removes_own_callback(self):
        self.call('Initialize')
        self.respond()
        self.assertIn('BAR Fight - historical traits', self.native_hover())
        self.call('Update', .3)
        self.assertNotIn('BAR Fight - historical traits', self.draw())
        self.call('Shutdown')
        self.assertIsNone(self.globals.WG.barFightTraitsHover)

    def test_hover_delay_clear_and_hidden_gui(self):
        self.call('Initialize')
        self.respond()
        self.globals.mouseX, self.globals.mouseY = 1100, 510
        self.globals.WG.barFightTraitsHover(1, '100', 1090, 500, 1210, 522)
        self.assertNotIn('BAR Fight - historical traits', self.draw())
        self.call('Update', .1)
        self.globals.WG.barFightTraitsHover(1, '100', 1090, 500, 1210, 522)
        self.assertNotIn('BAR Fight - historical traits', self.draw())
        self.assertIn('BAR Fight - historical traits', self.native_hover())
        self.globals.WG.barFightTraitsHover(None, None, None, None, None, None)
        self.assertNotIn('BAR Fight - historical traits', self.draw())
        self.lua.execute('Spring.IsGUIHidden = function() return true end')
        self.assertEqual(self.native_hover(), [])

    def test_hover_popups_fit_viewport_corners_and_show_insufficient_evidence(self):
        self.call('Initialize')
        value = profile(status='insufficient_evidence', stale=True)
        value['positions'][0].update(traits=[], games=5, status='insufficient_evidence')
        self.respond([value])
        for width, height in [(1280, 720), (1920, 1080)]:
            self.call('ViewResize', width, height)
            for left, bottom in [(0, 0), (width - 140, height - 30)]:
                self.globals.rectangles = self.lua.table()
                texts = self.native_hover(bounds=(left, bottom, left + 120, bottom + 22))
                self.assertIn('BAR Fight - historical traits', texts)
                self.assertTrue(any('10 measured games' in text for text in texts))
                for area in self.globals.rectangles.values():
                    self.assertGreaterEqual(area[1], 0)
                    self.assertGreaterEqual(area[2], 0)
                    self.assertLessEqual(area[3], width)
                    self.assertLessEqual(area[4], height)

    def test_writes_only_sorted_stable_accounts_and_canonical_map(self):
        self.add_player(3, 'Unknown ID', None, 1)
        self.add_player(4, 'Spectator', '300', 1, True)
        self.start()
        request = self.request()
        self.assertEqual(set(request), {'schema', 'request_id', 'map', 'accounts'})
        self.assertEqual(request['accounts'], ['100', '200'])
        self.assertEqual(request['map'], 'Supreme Isthmus v2.1')
        self.assertRegex(request['request_id'], r'^[A-Za-z0-9_-]{1,80}$')
        self.assertEqual(list(self.globals.written.values()), [REQUEST])

    def test_map_version_guard_prevents_lookup_on_other_map(self):
        self.globals.Game.mapName = 'Supreme Isthmus v2.2'
        self.start()
        self.assertIsNone(self.request())
        self.assertTrue(any('v2.1 only' in text for text in self.draw()))

    def test_supported_map_separators_are_normalized(self):
        self.globals.Game.mapName = 'Supreme_Isthmus_v2.1'
        self.start()
        self.assertEqual(self.request()['map'], 'Supreme Isthmus v2.1')

    def test_conflicting_or_missing_id_never_uses_name_as_identity(self):
        self.globals.players[1]['keys'].account_id = '999'
        self.start()
        self.assertEqual(self.request()['accounts'], ['200'])
        texts = self.draw()
        self.assertIn('No stable account ID supplied by this match.', texts)
        self.assertIn('Names are never used to guess a player profile.', texts)

    def test_valid_response_shows_percent_dates_position_and_current_alias(self):
        self.start()
        self.respond()
        texts = self.draw()
        self.assertIn('Current name', texts)
        self.assertNotIn('Historical alias', texts)
        self.assertIn('Beach sea', texts)
        self.assertIn('72.5% of games', texts)
        self.assertTrue(any(text.startswith('2026-08-25 to 2026-09-23 UTC') for text in texts))
        self.assertTrue(any('Updated 2026-09-23 12:00 UTC' in text for text in texts))
        self.assertIn('30 recorded games for this position', texts)
        self.assertTrue(any('Sample: 20 games' in text for text in texts))
        self.assertTrue(self.click_text('Early bomber producer'))
        self.assertTrue(any('Completed bombers early' in text for text in self.draw()))

    def test_startup_points_to_the_panel_button_and_player_position_flow(self):
        self.call('Initialize')
        message = ' '.join(self.globals.echoes.values())
        self.assertIn('Click the BAR Fight button or type /barfight', message)
        self.assertIn('Choose a player and a historical position', message)
        self.assertTrue(self.click_text('BAR Fight'))
        self.assertIn('Historical player traits', self.draw())

    def test_combined_history_count_does_not_imply_every_game_measures_each_trait(self):
        value = profile()
        position = value['positions'][0]
        position.update(games=32, coverage_percent=25)
        position['traits'][0]['samples'] = 12
        self.start()
        self.respond([value])
        texts = self.draw()
        note = 'Each trait uses the games with the measurements it needs.'
        self.assertIn('32 recorded games for this position', texts)
        self.assertIn(note, texts)
        self.assertLess(texts.index('32 recorded games for this position'), texts.index(note))
        self.assertTrue(any('Sample: 12 games' in text for text in texts))
        self.assertNotIn('25% of games', texts)
        position.update(traits=[], status='insufficient_evidence')
        self.respond([value])
        self.assertIn(note, self.draw())
        self.assertTrue(any('10 measured games' in text for text in self.draw()))

    def test_unicode_json_escapes_are_decoded(self):
        value = profile()
        value['positions'][0]['traits'][0]['label'] = 'Économie 🚀'
        self.start()
        self.respond([value])
        self.assertIn('Économie 🚀', self.draw())

    def test_long_unicode_label_truncates_only_complete_characters(self):
        value = profile()
        value['positions'][0]['traits'][0]['label'] = 'é' * 70
        self.start()
        self.respond([value])
        self.assertTrue(any(text.startswith('é') and text.endswith('...') for text in self.draw()))

    def test_stale_profile_is_explicit(self):
        self.start()
        self.respond([profile(stale=True)])
        self.assertTrue(any('Stale cache' in text for text in self.draw()))

    def test_current_and_legacy_engine_identity_slots_are_supported(self):
        self.globals.players[2].legacy = True
        self.start()
        self.assertEqual(self.request()['accounts'], ['100', '200'])

    def test_duplicate_active_account_id_is_not_guessed(self):
        self.add_player(3, 'Duplicate account', '100', 1)
        self.start()
        self.assertEqual(self.request()['accounts'], ['200'])
        self.assertIn('No stable account ID supplied by this match.', self.draw())

    def test_unix_profile_timestamp_is_displayed_in_utc(self):
        value = profile()
        value['generated_at'] = 1720000000
        self.start()
        self.respond([value])
        self.assertTrue(any('Updated 2024-07-03 09:46 UTC' in text for text in self.draw()))

    def test_wrong_request_and_wrong_account_responses_cannot_replace_profile(self):
        self.start()
        self.respond(request_id='old-request')
        self.assertNotIn('Early bomber producer', self.draw())
        self.respond([profile(account='999')])
        self.assertNotIn('Early bomber producer', self.draw())

    def test_remote_lua_is_not_executed_and_bad_json_keeps_cache(self):
        self.start()
        self.respond()
        for content in ('_G.pwned = true; return {}', '{"schema":1,"schema":1}',
                        '{"x":1e999}', '{"x":"\\ud800"}', '[' * 30 + ']' * 30,
                        'x' * (1048576 + 1)):
            with self.subTest(content=content[:30]):
                self.globals.files[RESPONSE] = content
                self.call('Update', 1)
                self.assertIsNone(self.globals.pwned)
                self.assertIn('Early bomber producer', self.draw())

    def test_manual_refresh_throttle(self):
        self.start()
        self.respond()
        initial = self.request()['request_id']
        self.call('TextCommand', 'barfight refresh')
        self.assertEqual(self.request()['request_id'], initial)
        self.call('Update', 58)
        self.assertEqual(self.request()['request_id'], initial)
        self.call('Update', 1)
        self.assertEqual(self.request()['request_id'], initial)
        self.call('TextCommand', 'barfight refresh')
        self.assertNotEqual(self.request()['request_id'], initial)

    def test_account_roster_change_requests_update_but_rename_does_not(self):
        self.start()
        initial = self.request()['request_id']
        self.globals.players[1].name = 'Renamed'
        self.call('Update', 2)
        self.assertEqual(self.request()['request_id'], initial)
        self.add_player(3, 'New player', '300', 1)
        self.call('Update', 2)
        self.assertNotEqual(self.request()['request_id'], initial)
        self.assertEqual(self.request()['accounts'], ['100', '200', '300'])

    def test_larger_roster_is_not_partially_sent_as_wrong_match(self):
        for index in range(3, 18):
            self.add_player(index, f'Player {index}', str(index * 100), index % 2)
        self.start()
        self.assertIsNone(self.request())

    def test_offline_message_keeps_existing_profile(self):
        self.start()
        self.respond()
        self.call('Update', 60)
        self.call('TextCommand', 'barfight refresh')
        self.call('Update', 31)
        texts = self.draw()
        self.assertTrue(any('No helper reply' in text for text in texts))
        self.assertIn('Early bomber producer', texts)

    def test_preparing_does_not_erase_usable_cached_traits(self):
        self.start()
        self.respond()
        preparing = profile(status='preparing')
        preparing['positions'] = []
        self.respond([preparing])
        texts = self.draw()
        self.assertIn('Early bomber producer', texts)
        self.assertTrue(any('Stale cache' in text for text in texts))

    def test_position_preparation_keeps_cached_traits_and_shows_clear_state(self):
        self.start()
        self.respond()
        pending = profile()
        position = pending['positions'][0]
        position.update(status='preparing', traits=[], preparing=True,
                        preparation_percent=40, preparation_note='History is being prepared...')
        self.respond([pending])
        texts = self.draw()
        self.assertIn('Early bomber producer', texts)
        self.assertIn('History is being prepared...', texts)
        texts = self.hover_name('Current name')
        self.assertIn('Early bomber producer', texts)
        self.assertIn('History is being prepared...', texts)

    def test_available_badges_can_include_preparing_note(self):
        self.start()
        value = profile()
        value['preparing'] = True
        value['positions'][0].update(status='available', preparing=True, prepared_games=12,
            preparation_percent=50, preparation_note='Updating history...')
        self.respond([value])
        self.assertIn('Updating history...', self.draw())
        self.assertIn('Updating history...', self.hover_name('Current name'))

    def test_preparing_profile_renews_request_past_bridge_freshness_and_stops_when_ready(self):
        self.start()
        value = profile(status='preparing')
        value['preparing'] = True
        value['positions'][0].update(preparing=True, preparation_percent=20,
            preparation_note='History is being prepared...')
        self.respond([value])
        original_id = self.request()['request_id']
        self.call('Update', 299)
        self.assertNotEqual(self.request()['request_id'], original_id)
        renewed_id = self.request()['request_id']
        self.respond([profile()])
        self.call('Update', 238)
        self.assertEqual(self.request()['request_id'], renewed_id)

    def test_slow_helper_request_is_renewed_while_pending(self):
        self.start()
        original_id = self.request()['request_id']
        self.call('Update', 121)
        self.assertNotEqual(self.request()['request_id'], original_id)

    def test_open_ready_panel_refreshes_on_bounded_interval_for_new_history(self):
        self.start()
        self.respond()
        original_id = self.request()['request_id']
        self.call('Update', 301)
        self.assertNotEqual(self.request()['request_id'], original_id)
        updated = profile()
        updated['positions'][0]['traits'][0]['label'] = 'Newly prepared history'
        self.respond([updated])
        self.assertIn('Newly prepared history', self.draw())

    def test_trait_without_minimum_evidence_is_rejected(self):
        value = profile()
        value['positions'][0]['traits'][0]['samples'] = 2
        self.start()
        self.respond([value])
        self.assertNotIn('Early bomber producer', self.draw())

    def test_roster_and_trait_lists_can_scroll_and_toggle(self):
        for index in range(3, 17):
            self.add_player(index, f'Player {index}', str(index * 100), index % 2)
        value = profile()
        value['positions'][0]['traits'] = [dict(id=f'trait-{n}', label=f'Trait {n}',
            frequency_percent=70, samples=20, description='Repeated historical pattern.') for n in range(12)]
        self.start()
        self.respond([value])
        self.draw()
        self.globals.mouseX, self.globals.mouseY = 650, 600
        self.assertTrue(self.call('MouseWheel', False))
        self.globals.mouseX, self.globals.mouseY = 1200, 400
        self.assertTrue(self.call('MouseWheel', False))
        self.call('TextCommand', 'barfight')
        self.assertEqual(self.draw(), ['BAR Fight'])
        self.assertFalse(self.call('MouseWheel', False))

    def test_render_after_resize_and_hidden_gui(self):
        self.start()
        self.respond()
        self.call('ViewResize', 1024, 768)
        self.assertIn('Early bomber producer', self.draw())
        self.lua.execute('Spring.IsGUIHidden = function() return true end')
        self.assertEqual(self.draw(), [])
        self.assertFalse(self.call('MousePress', 1200, 600, 1))
        self.assertFalse(self.call('IsAbove', 1200, 600))

    def test_panel_background_swallows_clicks_without_game_orders(self):
        self.start()
        self.draw()
        self.assertTrue(self.call('MousePress', 1100, 750, 1))
        self.assertTrue(self.call('MousePress', 1100, 750, 3))
        self.assertTrue(self.call('IsAbove', 1100, 750))

    def test_profile_link_is_copied_only_after_click_for_the_selected_account(self):
        self.start()
        self.draw()
        self.assertEqual(len(self.globals.clipboard), 0)
        self.hover_name('Other name')
        self.assertEqual(len(self.globals.clipboard), 0)
        self.click_text('Other name')
        self.assertIn('Copy profile link', self.draw())
        self.click_text('Copy profile link')
        self.assertEqual(list(self.globals.clipboard.values()), ['https://bar-fight.com/players/200'])

    def test_profile_link_is_available_without_traits_but_not_without_account_id(self):
        self.start()
        texts = self.draw()
        self.assertTrue(any('Loading this player' in text or 'No historical profile' in text for text in texts))
        self.assertIn('Copy profile link', texts)
        self.add_player(3, 'Unknown account', None, 2)
        self.call('Update', 2.1)
        self.click_text('Unknown account')
        texts = self.draw()
        self.assertIn('No stable account ID supplied by this match.', texts)
        self.assertNotIn('Copy profile link', texts)
        self.assertEqual(len(self.globals.clipboard), 0)

    def test_profile_link_falls_back_to_echo_when_clipboard_is_unavailable_or_throws(self):
        self.start()
        self.lua.execute('Spring.SetClipboard = nil')
        self.click_text('Copy profile link')
        self.assertIn('[BAR Fight] https://bar-fight.com/players/100', list(self.globals.echoes.values()))
        self.lua.execute('Spring.SetClipboard = function() error("clipboard failed") end')
        self.click_text('Copy profile link')
        self.assertEqual(list(self.globals.echoes.values()).count('[BAR Fight] https://bar-fight.com/players/100'), 2)

    def panel_rect(self):
        self.globals.rectangles = self.lua.table()
        self.draw()
        # First rectangle is the always-visible BAR Fight button; the next is
        # the panel background (x1, y1, x2, y2).
        return tuple(self.globals.rectangles[2][index] for index in range(1, 5))

    def test_titlebar_drag_moves_panel_and_mouse_release_ends_capture(self):
        self.start()
        left, bottom, right, top = self.panel_rect()
        self.assertEqual(self.call('GetTooltip', left + 330, top - 20), 'Drag to move BAR Fight')
        self.assertTrue(self.call('MousePress', left + 330, top - 20, 1))
        self.assertTrue(self.call('MouseMove', left + 230, top - 100))
        moved = self.panel_rect()
        self.assertEqual(moved[0], left - 100)
        self.assertEqual(moved[1], bottom - 80)
        self.assertTrue(self.call('MouseRelease', 0, 0, 1))
        self.assertFalse(self.call('MouseMove', 100, 100))

    def test_panel_controls_do_not_start_drag(self):
        self.start()
        left, bottom, right, top = self.panel_rect()
        # Refresh is a button within the header and remains a button.
        self.assertTrue(self.call('MousePress', right - 90, top - 20, 1))
        self.assertFalse(self.call('MouseMove', right - 40, top - 10))
        self.assertTrue(self.call('MousePress', right - 20, top - 20, 1))
        self.assertFalse(self.call('MouseMove', right - 5, top - 5))

    def test_drag_clamps_to_viewport_after_resize_and_persists_normalized_position(self):
        self.start()
        left, bottom, right, top = self.panel_rect()
        self.assertTrue(self.call('MousePress', left + 330, top - 20, 1))
        self.assertTrue(self.call('MouseMove', 100000, -100000))
        self.call('MouseRelease', 0, 0, 1)
        moved = self.panel_rect()
        self.assertEqual(moved[0], 1420 - (right - left))
        self.assertEqual(moved[1], 20)
        saved = self.call('GetConfigData')
        self.assertTrue(saved['open'])
        self.assertAlmostEqual(saved['position']['x'], 1)
        self.assertAlmostEqual(saved['position']['y'], 0)
        self.call('ViewResize', 1024, 768)
        resized = self.panel_rect()
        self.assertEqual(resized[0], 1004 - (resized[2] - resized[0]))
        self.assertEqual(resized[1], 20)
        self.assertLessEqual(resized[3], 768)
        self.call('ViewResize', 320, 240)
        compact = self.panel_rect()
        self.assertGreaterEqual(compact[0], 20)
        self.assertGreaterEqual(compact[1], 20)
        self.assertLessEqual(compact[2], 320)
        self.assertLessEqual(compact[3], 240)

    def test_position_config_restores_without_changing_open_or_default_placement(self):
        self.start()
        original = self.panel_rect()
        self.assertEqual(original[2], 1420)
        config = self.call('GetConfigData')
        self.assertIsNone(config['position'])
        self.call('SetConfigData', self.lua.table_from(dict(schema=1, open=True,
            position=self.lua.table_from(dict(x=.25, y=.4)))))
        restored = self.panel_rect()
        self.assertNotEqual(restored[:2], original[:2])
        saved = self.call('GetConfigData')
        self.assertTrue(saved['open'])
        self.assertAlmostEqual(saved['position']['x'], .25)
        self.assertAlmostEqual(saved['position']['y'], .4)

    def test_full_profiles_stay_inside_common_viewports(self):
        value = profile()
        names = ['Geo sea', 'Tech', 'Air', 'Pond', 'Front (suicide)', 'Front (second)', 'Geo tech', 'Beach sea']
        template = value['positions'][0]
        value['positions'] = [dict(template, spot=f'P{index + 1}', position_name=name) for index, name in enumerate(names)]
        self.start()
        self.respond([value])
        for width, height in ((1280, 720), (1920, 1080)):
            with self.subTest(width=width, height=height):
                self.call('ViewResize', width, height)
                self.globals.rectangles = self.lua.table()
                texts = self.draw()
                self.assertTrue(any(text.startswith('2026-08-25 to 2026-09-23 UTC') for text in texts))
                self.assertIn('72.5% of games', texts)
                self.assertIn('Beach sea', texts)
                for entry in self.globals.drawn.values():
                    self.assertGreaterEqual(entry['x'], 0)
                    self.assertLessEqual(entry['x'], width)
                    self.assertGreaterEqual(entry['y'], 0)
                    self.assertLessEqual(entry['y'] + entry['size'], height)
                for rectangle in self.globals.rectangles.values():
                    self.assertGreaterEqual(rectangle[1], 0)
                    self.assertGreaterEqual(rectangle[2], 0)
                    self.assertLessEqual(rectangle[3], width)
                    self.assertLessEqual(rectangle[4], height)
                self.click_text('Early bomber producer')
                self.assertTrue(any('Completed bombers early' in text for text in self.draw()))
                self.click_text('Early bomber producer')


class WidgetScopeTests(unittest.TestCase):
    def test_widget_has_no_network_execution_or_game_control_calls(self):
        code = SOURCE.read_text(encoding='utf-8')
        for forbidden in ('loadstring(', 'loadfile(', 'dofile(', 'os.execute', 'io.popen',
                          'socket.', 'http.', 'SendCommands', 'GiveOrder', 'GetAllUnits',
                          'GetTeamUnits', 'GetUnitPosition', 'SetGameSpeed'):
            self.assertNotIn(forbidden, code)
        self.assertEqual(set(re.findall(r'LuaUI/Config/[^"\s]+', code)), {REQUEST, RESPONSE})


if __name__ == '__main__':
    unittest.main()
