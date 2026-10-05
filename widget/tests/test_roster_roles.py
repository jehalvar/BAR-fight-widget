"""Role-history estimates and their transition to engine-observed starts."""
import unittest

import test_widget as harness


def role_profile(counts, account='100', **kwargs):
    value = harness.profile(account, **kwargs)
    template = value['positions'][0]
    value['positions'] = [dict(template, spot=spot, games=games, traits=[],
        status='preparing', preparing=True, coverage_percent=0) for spot, games in counts]
    return value


@unittest.skipIf(harness.LuaRuntime is None, 'Optional lupa runtime is unavailable')
class RosterRoleTests(unittest.TestCase):
    def setUp(self):
        self.case = harness.WidgetTests('runTest')
        self.case.setUp()

    def row_labels(self, name='Current name'):
        self.case.draw()
        entries = list(self.case.globals.drawn.values())
        name_entry = next(e for e in entries if e['text'] == name and e['size'] == 12)
        return [e['text'].removeprefix(' - ') for e in entries if e['size'] == 10
                and e['x'] >= name_entry['x'] and e['x'] < name_entry['x'] + 200
                and (e['y'] == name_entry['y'] or e['y'] == name_entry['y'] - 14)]

    def test_estimate_uses_every_position_game_even_without_trait_measurements(self):
        self.case.start()
        self.case.respond([role_profile([('P2', 7), ('P3', 3)], status='preparing'),
                           role_profile([('P8', 8), ('P4', 2)], account='200')])
        writes = len(self.case.globals.written)
        self.assertIn('Tech 70% est.', self.row_labels())
        self.assertIn('Beach sea 80% est.', self.row_labels('Other name'))
        texts = self.case.hover_name('Current name')
        self.assertIn('70% of 10 recorded position games.', texts)
        self.assertIn('2026-08-25 to 2026-09-23 UTC', texts)
        self.assertEqual(len(self.case.globals.written), writes)

    def test_observed_start_replaces_estimate_without_treating_manual_history_as_actual(self):
        self.case.standard_match()
        self.case.lua.execute('originalStart=Spring.GetTeamStartPosition; Spring.GetTeamStartPosition=function(team) if team==1 then return 0,0,0,false end; return originalStart(team) end')
        self.case.start()
        self.case.respond([role_profile([('P8', 7), ('P2', 3)])])
        self.assertIn('Beach sea 70% est.', self.row_labels())
        self.case.lua.execute('Spring.GetTeamStartPosition=originalStart')
        self.case.call('Update', 2)
        self.assertIn('Tech (detected)', self.row_labels())
        self.assertNotIn('Beach sea 70% est.', self.row_labels())
        self.case.call('TextCommand', 'barfight timing')
        self.case.timing_respond(units=harness.quick_catalogue())
        self.case.choose_timing_position('Air')
        self.assertIn('Tech (detected)', self.row_labels())

    def test_tied_small_empty_and_cached_history_stay_explicit(self):
        self.case.start()
        self.assertIn('Loading history...', self.row_labels())
        self.case.respond([role_profile([('P2', 5), ('P3', 5)])])
        self.assertIn('Mixed spots (est.)', self.row_labels())
        self.assertIn('50% each of 10 recorded position games.', self.case.hover_name('Current name'))
        self.case.respond([role_profile([('P2', 1)], stale=True)])
        self.assertIn('Tech 100% est.*', self.row_labels())
        texts = self.case.hover_name('Current name')
        self.assertTrue(any('Small history:' in s for s in texts))
        self.assertTrue(any('Saved history;' in s for s in texts))
        self.case.respond([role_profile([], status='no_data')])
        self.assertIn('No role history', self.row_labels())

    def test_trait_fallback_cannot_mix_role_counts_from_different_snapshots(self):
        self.case.start()
        previous = harness.profile()
        previous['positions'][0].update(spot='P2', games=30)
        self.case.respond([previous])
        current = role_profile([('P2', 7), ('P3', 3)], status='preparing')
        self.case.respond([current])
        self.assertIn('Tech 70% est.*', self.row_labels())
        self.assertFalse(any('90.9%' in s for s in self.row_labels()))

    def test_mirrored_detected_position_needs_no_history_or_account(self):
        self.case.standard_match()
        self.case.globals.players[1]['keys'] = self.case.lua.table()
        self.case.lua.execute('starts[1], starts[10] = starts[10], starts[1]')
        self.case.start()
        self.assertIn('Tech (detected)', self.row_labels())


if __name__ == '__main__':
    unittest.main()
