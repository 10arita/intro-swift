"""Private collection: lossless migration, safe matching, units and resumption."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.parse
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from collect_songle_chorus import (API, ROOT, collect_target, migrate_manual,
                                  open_database, seed_targets, source_url, summary)


class FakeClient:
    def __init__(self, entries, chorus):
        self.entries, self.chorus, self.calls = entries, chorus, []

    def get(self, url, refresh=False):
        self.calls.append(url)
        return self.entries if 'songs/search.json' in url else self.chorus


class SongleDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'private.sqlite3'
        self.db = open_database(self.path)
        self.manual = ROOT / 'server/manual-chorus.json'
        self.records = json.loads(self.manual.read_text())['records']
        self.entry = {'id': 123, 'title': '白日', 'artist': {'name': 'King Gnu'},
                      'duration': 279560.0, 'permalink': 'http://www.youtube.com/watch?v=example',
                      'url': 'https://songle.jp/songs/www.youtube.com%2Fwatch%3Fv%3Dexample'}
        self.chorus = {'chorusSegments': [{'isChorus': True, 'repeats': [
            {'start': 69940, 'duration': 23260.000000000004},
            {'start': 147360.00000000003, 'duration': 23260}]}],
            'repeatSegments': [{'isChorus': False, 'repeats': [{'start': 3560, 'duration': 10300}]}]}

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def target(self, artist='King Gnu'):
        from collect_songle_chorus import normalize
        with self.db:
            self.db.execute('''INSERT INTO targets(title,artist,title_key,artist_key,sources_json)
                VALUES(?,?,?,?,?)''', ('白日', artist, normalize('白日'), normalize(artist), '[]'))
        return self.db.execute('SELECT * FROM targets ORDER BY id DESC LIMIT 1').fetchone()

    def test_all_600_records_are_lossless_and_reimport_is_idempotent(self):
        self.assertEqual(migrate_manual(self.db, self.manual), 600)
        self.assertEqual(migrate_manual(self.db, self.manual), 600)
        actual = [json.loads(row[0]) for row in self.db.execute(
            "SELECT payload_json FROM observations WHERE source='manual' ORDER BY id")]
        self.assertEqual(actual, self.records)
        self.assertEqual(self.db.execute('SELECT count(*) FROM imports').fetchone()[0], 1)
        self.assertEqual(self.db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
        self.assertEqual(self.db.execute('PRAGMA foreign_key_check').fetchall(), [])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_invalid_catalog_cannot_partially_migrate(self):
        catalog = json.loads(self.manual.read_text())
        catalog['records'][-1]['chorusStartMS'] = catalog['records'][-1]['durationMS']
        bad = Path(self.temp.name) / 'bad.json'
        bad.write_text(json.dumps(catalog))
        with self.assertRaises(ValueError):
            migrate_manual(self.db, bad)
        self.assertEqual(self.db.execute('SELECT count(*) FROM observations').fetchone()[0], 0)

    def test_manual_priority_survives_songle_collection(self):
        migrate_manual(self.db, self.manual)
        record = self.records[0]
        with self.db:
            self.db.execute('INSERT INTO targets(title,artist,title_key,artist_key,sources_json) VALUES(?,?,?,?,?)',
                            (record['title'], record['artist'], record['title'], record['artist'], '[]'))
        from collect_songle_chorus import store_songle
        target = dict(self.db.execute('SELECT * FROM targets').fetchone())
        entry = {**self.entry, 'title': record['title'], 'artist': {'name': record['artist']}}
        with self.db:
            store_songle(self.db, target, entry, self.chorus)
        preferred = self.db.execute('SELECT * FROM preferred_chorus WHERE title=? AND artist=?',
                                    (record['title'], record['artist'])).fetchone()
        self.assertEqual(preferred['source'], 'manual')
        self.assertEqual(preferred['chorus_start_ms'], record['chorusStartMS'])
        self.assertEqual(self.db.execute("SELECT count(*) FROM observations WHERE source='manual'").fetchone()[0], 600)

    def test_api_milliseconds_and_all_intervals_are_preserved(self):
        target = self.target()
        client = FakeClient([self.entry], self.chorus)
        self.assertEqual(collect_target(self.db, client, target), 'collected')
        observation = self.db.execute('SELECT * FROM observations').fetchone()
        self.assertEqual(observation['chorus_start_ms'], 69940)  # no 1.5s playback lead-in
        self.assertEqual(observation['duration_ms'], 279560)
        self.assertEqual(observation['status'], 'metadata_matched')
        self.assertEqual(json.loads(observation['payload_json'])['map'], self.chorus)
        self.assertEqual(self.db.execute('SELECT count(*) FROM segments').fetchone()[0], 3)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(client.calls[-1]).query)
        self.assertEqual(query['url'], ['www.youtube.com/watch?v=example'])
        self.assertEqual(summary(self.db)['chorusIntervals'], 2)
        self.assertEqual(collect_target(self.db, client, target), 'collected')
        self.assertEqual(self.db.execute('SELECT count(*) FROM observations').fetchone()[0], 1)
        self.assertEqual(self.db.execute('SELECT count(*) FROM target_observations').fetchone()[0], 1)

    def test_cover_and_different_version_are_not_matched(self):
        target = self.target()
        cover = {**self.entry, 'artist': {'name': 'King Gnu / Cover Singer'}}
        live = {**self.entry, 'title': '白日 (Live)'}
        client = FakeClient([cover, live], self.chorus)
        self.assertEqual(collect_target(self.db, client, target), 'no_exact_match')
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(self.db.execute('SELECT count(*) FROM observations').fetchone()[0], 0)

    def test_title_only_candidates_are_saved_for_review(self):
        target = self.target('')
        self.assertEqual(collect_target(self.db, FakeClient([self.entry], self.chorus), target), 'needs_review')
        self.assertEqual(self.db.execute('SELECT status FROM observations').fetchone()[0], 'needs_review')
        self.assertEqual(self.db.execute('SELECT count(*) FROM preferred_chorus').fetchone()[0], 0)

    def test_repeating_verse_is_not_a_chorus(self):
        chorus = copy.deepcopy(self.chorus)
        chorus['chorusSegments'][0]['isChorus'] = False
        self.assertEqual(collect_target(self.db, FakeClient([self.entry], chorus), self.target()), 'no_chorus')
        self.assertEqual(self.db.execute('SELECT count(*) FROM observations').fetchone()[0], 0)

    def test_invalid_time_is_not_saved(self):
        chorus = copy.deepcopy(self.chorus)
        chorus['chorusSegments'][0]['repeats'][0]['start'] = -1
        with self.assertRaises(ValueError):
            collect_target(self.db, FakeClient([self.entry], chorus), self.target())
        self.assertEqual(self.db.execute('SELECT count(*) FROM observations').fetchone()[0], 0)

    def test_outside_repeat_is_preserved_raw_and_flagged_for_review(self):
        target = self.target()
        self.assertEqual(collect_target(self.db, FakeClient([self.entry], self.chorus), target), 'collected')
        chorus = copy.deepcopy(self.chorus)
        chorus['repeatSegments'][0]['repeats'][0] = {'start': 270000, 'duration': 20000}
        self.assertEqual(collect_target(self.db, FakeClient([self.entry], chorus), target), 'needs_review')
        observation = self.db.execute('SELECT * FROM observations').fetchone()
        self.assertEqual(observation['chorus_start_ms'], 69940)
        self.assertEqual(observation['status'], 'needs_review')
        payload = json.loads(observation['payload_json'])
        self.assertEqual(payload['map'], chorus)
        self.assertEqual(len(payload['validationWarnings']), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM segments WHERE kind='repeat'").fetchone()[0], 0)
        self.assertEqual(self.db.execute('SELECT count(*) FROM preferred_chorus').fetchone()[0], 0)

    def test_manual_seed_skips_requests_and_retains_pending_targets(self):
        migrate_manual(self.db, self.manual)
        from collect_songle_chorus import normalize
        titles = {normalize(title) for path in (ROOT / 'server/corpus').glob('*.json')
                  for title in json.loads(path.read_text())}
        manual_titles = {normalize(record['title']) for record in self.records}
        self.assertEqual(seed_targets(self.db), len(titles))
        states = dict(self.db.execute('SELECT status,count(*) FROM targets GROUP BY status'))
        self.assertEqual(states['manual_available'], len(titles & manual_titles))
        self.assertEqual(states['pending'], len(titles - manual_titles))
        with self.db:
            self.db.execute("UPDATE targets SET status='collected' WHERE id=(SELECT min(id) FROM targets WHERE status='pending')")
        seed_targets(self.db)
        self.assertEqual(self.db.execute('SELECT count(*) FROM targets').fetchone()[0], len(titles))
        self.assertEqual(self.db.execute("SELECT count(*) FROM targets WHERE status='collected'").fetchone()[0], 1)

    def test_empty_search_404_is_a_resumable_miss(self):
        class MissingClient:
            def get(self, url, refresh=False):
                raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
        target = self.target()
        self.assertEqual(collect_target(self.db, MissingClient(), target), 'not_found')
        self.assertEqual(self.db.execute('SELECT search_json FROM targets').fetchone()[0], '[]')

    def test_official_title_wrapper_is_matched_but_short_version_is_not(self):
        wrapped = {**self.entry, 'title': 'King Gnu「白日」'}
        target = self.target()
        self.assertEqual(collect_target(self.db, FakeClient([wrapped], self.chorus), target), 'collected')
        self.assertEqual(self.db.execute('SELECT title FROM tracks').fetchone()[0], '白日')
        short = {**self.entry, 'title': 'King Gnu「白日」MVショートver.'}
        self.assertEqual(collect_target(self.db, FakeClient([short], self.chorus), target), 'no_exact_match')

    def test_official_channel_suffix_is_matched(self):
        entry = {**self.entry, 'title': 'King Gnu - 白日',
                 'artist': {'name': 'King Gnu Official YouTube Channel'}}
        self.assertEqual(collect_target(self.db, FakeClient([entry], self.chorus), self.target()), 'collected')

    def test_official_prefix_is_matched(self):
        entry = {**self.entry, 'title': '[Official Music Video] King Gnu 「白日」'}
        self.assertEqual(collect_target(self.db, FakeClient([entry], self.chorus), self.target()), 'collected')

    def test_encoded_songle_url_resolves_to_source(self):
        self.assertEqual(source_url({'url': self.entry['url']}), 'https://www.youtube.com/watch?v=example')


if __name__ == '__main__':
    unittest.main()
