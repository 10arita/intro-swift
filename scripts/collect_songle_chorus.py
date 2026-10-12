#!/usr/bin/env python3
"""Collect Songle metadata into an owner-only, local SQLite database.

This tool uses Songle Widget's documented public JSON APIs. It never downloads
audio, exports a public catalog, or connects the private database to the app.
"""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / '.private/chorus/chorus.sqlite3'
TERMS_URL = 'https://api.songle.jp/terms_of_use'
CREDIT = 'Songle / AIST — https://songle.jp/ — Songle Widget API'
API = 'https://widget.songle.jp/api/v1/'


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def normalize(value):
    return ''.join(unicodedata.normalize('NFKC', str(value)).upper().split())


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def integer_ms(value, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('Invalid millisecond value')
    result = round(value)
    if result < (1 if positive else 0):
        raise ValueError('Negative/empty millisecond value')
    return result


def open_database(path):
    path = Path(path).absolute()
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError('Database paths must not be symlinks')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Restrict the dedicated private tree, without changing arbitrary user folders.
    for directory in (ROOT / '.private', ROOT / '.private/chorus'):
        if directory.exists():
            directory.chmod(0o700)
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    os.close(fd)
    path.chmod(0o600)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys=ON')
    db.execute('PRAGMA busy_timeout=5000')
    version = db.execute('PRAGMA user_version').fetchone()[0]
    if version not in (0, 1):
        db.close()
        raise ValueError(f'Unsupported database version: {version}')
    db.executescript('''
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS imports (
            sha256 TEXT PRIMARY KEY, source_path TEXT NOT NULL, record_count INTEGER NOT NULL,
            imported_at TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tracks (
            id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL,
            title_key TEXT NOT NULL, artist_key TEXT NOT NULL, UNIQUE(title_key, artist_key)
        );
        CREATE TABLE IF NOT EXISTS observations (
            id INTEGER PRIMARY KEY, track_id INTEGER NOT NULL REFERENCES tracks(id),
            source TEXT NOT NULL CHECK(source IN ('manual', 'songle')),
            source_key TEXT NOT NULL, chorus_start_ms INTEGER NOT NULL CHECK(chorus_start_ms >= 0),
            duration_ms INTEGER NOT NULL CHECK(duration_ms > chorus_start_ms),
            status TEXT NOT NULL CHECK(status IN ('manually_confirmed', 'metadata_matched', 'needs_review')),
            checked_at TEXT, fetched_at TEXT NOT NULL, source_url TEXT, songle_url TEXT,
            payload_json TEXT NOT NULL, UNIQUE(source, source_key)
        );
        CREATE TABLE IF NOT EXISTS segments (
            observation_id INTEGER NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, group_index INTEGER NOT NULL, repeat_index INTEGER NOT NULL,
            is_chorus INTEGER NOT NULL, start_ms INTEGER NOT NULL CHECK(start_ms >= 0),
            duration_ms INTEGER NOT NULL CHECK(duration_ms > 0),
            PRIMARY KEY(observation_id, kind, group_index, repeat_index)
        );
        CREATE TABLE IF NOT EXISTS targets (
            id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL,
            title_key TEXT NOT NULL, artist_key TEXT NOT NULL, sources_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT, error TEXT, search_json TEXT, UNIQUE(title_key, artist_key)
        );
        CREATE TABLE IF NOT EXISTS target_observations (
            target_id INTEGER REFERENCES targets(id), observation_id INTEGER REFERENCES observations(id),
            PRIMARY KEY(target_id, observation_id)
        );
        CREATE TABLE IF NOT EXISTS http_cache (
            url TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        CREATE VIEW IF NOT EXISTS preferred_chorus AS
            SELECT * FROM (
                SELECT observations.*, tracks.title, tracks.artist,
                    ROW_NUMBER() OVER (PARTITION BY track_id ORDER BY
                        CASE source WHEN 'manual' THEN 0 ELSE 1 END,
                        COALESCE(checked_at, fetched_at) DESC, observations.id DESC) AS priority
                FROM observations JOIN tracks ON tracks.id = observations.track_id
                WHERE status IN ('manually_confirmed', 'metadata_matched')
            ) WHERE priority = 1;
        PRAGMA user_version=1;
    ''')
    with db:
        for key, value in {'usage': 'noncommercial-local-private', 'songle_credit': CREDIT,
                           'songle_terms_url': TERMS_URL, 'schema_version': '1'}.items():
            db.execute('INSERT OR REPLACE INTO metadata VALUES (?, ?)', (key, value))
    return db


def track_id(db, title, artist):
    db.execute('INSERT OR IGNORE INTO tracks(title,artist,title_key,artist_key) VALUES(?,?,?,?)',
               (title, artist, normalize(title), normalize(artist)))
    return db.execute('SELECT id FROM tracks WHERE title_key=? AND artist_key=?',
                      (normalize(title), normalize(artist))).fetchone()[0]


def migrate_manual(db, path):
    raw = Path(path).read_text(encoding='utf-8')
    catalog = json.loads(raw)
    records = catalog.get('records', [])
    if catalog.get('schemaVersion') != 1 or catalog.get('recordCount') != len(records) or not records:
        raise ValueError('Invalid manual catalog')
    seen = set()
    for record in records:
        key = (normalize(record['title']), normalize(record['artist']))
        start, duration = record['chorusStartMS'], record['durationMS']
        if not all(key) or key in seen or integer_ms(start) != start or integer_ms(duration, True) != duration:
            raise ValueError('Empty/duplicate identity or invalid manual timestamp')
        if start >= duration or record.get('method') != 'manual-apple-music':
            raise ValueError('Invalid manual observation')
        seen.add(key)
    stamp = now()
    with db:
        for record in records:
            identity = encoded([normalize(record['title']), normalize(record['artist'])])
            db.execute('''INSERT INTO observations
                (track_id,source,source_key,chorus_start_ms,duration_ms,status,checked_at,fetched_at,payload_json)
                VALUES(?,'manual',?,?,?,'manually_confirmed',?,?,?)
                ON CONFLICT(source,source_key) DO UPDATE SET
                    chorus_start_ms=excluded.chorus_start_ms, duration_ms=excluded.duration_ms,
                    checked_at=excluded.checked_at, payload_json=excluded.payload_json
                WHERE COALESCE(excluded.checked_at,'') >= COALESCE(observations.checked_at,'')''',
                (track_id(db, record['title'], record['artist']), identity,
                 record['chorusStartMS'], record['durationMS'], record.get('checkedAt'), stamp, encoded(record)))
        db.execute('INSERT OR IGNORE INTO imports VALUES(?,?,?,?,?)',
                   (hashlib.sha256(Path(path).read_bytes()).hexdigest(), str(Path(path).absolute()),
                    len(records), stamp, raw))
    return len(records)


class Client:
    def __init__(self, db, interval=0.5, timeout=15):
        self.db, self.interval, self.timeout = db, interval, timeout
        self.last_request = 0

    def get(self, url, refresh=False):
        saved = self.db.execute('SELECT payload_json FROM http_cache WHERE url=?', (url,)).fetchone()
        if saved and not refresh:
            return json.loads(saved[0])
        for attempt in range(3):
            time.sleep(max(0, self.last_request + self.interval - time.monotonic()))
            self.last_request = time.monotonic()
            request = urllib.request.Request(url, headers={'User-Agent': 'IntoL-local-noncommercial/1.0',
                                                          'Accept': 'application/json, text/html'})
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    raw = response.read(4_000_001)
                    if len(raw) > 4_000_000:
                        raise ValueError('Response too large')
                    body = raw.decode('utf-8')
                    data = json.loads(body) if 'json' in response.headers.get('Content-Type', '') else body
                with self.db:
                    self.db.execute('INSERT OR REPLACE INTO http_cache VALUES(?,?,?)', (url, now(), encoded(data)))
                return data
            except urllib.error.HTTPError as error:
                if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                    raise
                retry = error.headers.get('Retry-After', '')
                try:
                    delay = float(retry)
                except ValueError:
                    try:
                        from email.utils import parsedate_to_datetime
                        delay = parsedate_to_datetime(retry).timestamp() - time.time()
                    except (ValueError, TypeError):
                        delay = 2 ** (attempt + 1)
                if delay > 60:
                    raise RuntimeError(f'Songle requested a pause of {delay:.0f}s; resume later') from error
                time.sleep(max(1, delay))
            except (urllib.error.URLError, TimeoutError):
                if attempt == 2:
                    raise
                time.sleep(2 ** (attempt + 1))


def seed_targets(db, client=None):
    """Use the existing corpus; recover artists from its original chart sources."""
    titles = list(dict.fromkeys(title for path in sorted((ROOT / 'server/corpus').glob('*.json'))
                               for title in json.loads(path.read_text())))
    wanted = {normalize(title) for title in titles}
    seeds = {}
    if client:
        from build_jpop_corpus import entries, monday, BASE
        sources = [f'{BASE}hot100_year&year={year}' for year in range(2015, 2026)]
        for year in range(2015, 2027):
            for month in ((1, 4, 7, 10) if year < 2026 else (1, 3, 5, 7, 9)):
                day = monday(year, month)
                sources.append(f'{BASE}hot100&year={day.year}&month={day.month:02d}&day={day.day:02d}')
        sources.append(f'{BASE}hot100')
        for index, url in enumerate(sources, 1):
            rows = list(entries(client.get(url)))
            if len(rows) < 50:
                raise ValueError(f'Chart source returned only {len(rows)} rows: {url}')
            for _, title, artist in rows:
                if normalize(title) in wanted:
                    key = (normalize(title), normalize(artist))
                    seeds.setdefault(key, [title, artist, set()])[2].add(url)
            if index % 10 == 0:
                print(f'Artist source charts: {index}/{len(sources)}', flush=True)
    covered = {key[0] for key in seeds}
    for title in titles:
        if normalize(title) not in covered:
            seeds[(normalize(title), '')] = [title, '', {'existing-title-corpus'}]
    with db:
        # Replace unprocessed title-only seeds once their artists are available.
        # Keep any collected candidates and their audit history.
        for title_key in covered:
            db.execute('''DELETE FROM targets WHERE title_key=? AND artist_key=''
                AND NOT EXISTS (SELECT 1 FROM target_observations WHERE target_id=targets.id)''',
                (title_key,))
        for (title_key, artist_key), (title, artist, sources) in seeds.items():
            # Confirmed manual songs already have a boundary, so avoid unnecessary requests.
            manual = db.execute('''SELECT 1 FROM observations JOIN tracks ON tracks.id=track_id
                WHERE source='manual' AND title_key=? AND (?='' OR artist_key=?)''',
                (title_key, artist_key, artist_key)).fetchone()
            db.execute('''INSERT INTO targets(title,artist,title_key,artist_key,sources_json,status)
                VALUES(?,?,?,?,?,?) ON CONFLICT(title_key,artist_key) DO UPDATE SET
                sources_json=excluded.sources_json''',
                (title, artist, title_key, artist_key, encoded(sorted(sources)),
                 'manual_available' if manual else 'pending'))
    return len(seeds)


def source_url(entry):
    raw = entry.get('permalink') or entry.get('source', {}).get('url') or entry.get('url') or ''
    url = urllib.parse.urlsplit(raw if '://' in raw else 'https://' + raw)
    if url.hostname in ('songle.jp', 'www.songle.jp'):
        if not url.path.startswith('/songs/'):
            raise ValueError('Invalid Songle permalink')
        raw = urllib.parse.unquote(url.path[len('/songs/'):])
        url = urllib.parse.urlsplit(raw if '://' in raw else 'https://' + raw)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password:
        raise ValueError('Invalid source URL')
    return urllib.parse.urlunsplit((url.scheme, url.netloc, url.path, url.query, ''))


def artist_name(entry):
    artist = entry.get('artist', '')
    return artist.get('name', '') if isinstance(artist, dict) else str(artist)


def artist_key(value):
    # An explicit channel label is metadata decoration, not another performer.
    value = re.sub(r'\s+(?:Official YouTube Channel|公式チャンネル)$', '', str(value), flags=re.I)
    return normalize(value)


def title_matches(entry, target):
    title = normalize(entry.get('title', ''))
    expected = target['title']
    artist = artist_name(entry)
    forms = [expected, f'「{expected}」', f'『{expected}』']
    if target['artist_key']:
        for label in {artist, target['artist']}:
            forms += [f'{label}「{expected}」', f'{label}『{expected}』',
                      f'{label} "{expected}"', f'{label} MV「{expected}」', f'{label} - {expected}',
                      f'{label} / {expected}', f'{expected} / {label}']
    # Match only complete presentation wrappers; preserve Live/Remix/short version suffixes.
    suffixes = ['', ' Official Music Video', ' (Official Music Video)', ' [Official Music Video]',
                ' NHKオフィシャル・ミュージックビデオ',
                ' 【Official Music Video】', ' - Official Music Video']
    prefixes = ['', '[Official Music Video] ', '【Official Music Video】 ']
    return title in {normalize(prefix + form + suffix)
                     for prefix in prefixes for form in forms for suffix in suffixes}


def segments(data, duration, warnings=None):
    result = []
    for kind, field in (('chorus', 'chorusSegments'), ('repeat', 'repeatSegments')):
        for group_index, group in enumerate(data.get(field, [])):
            is_chorus = group.get('isChorus') is True
            for repeat_index, repeat in enumerate(group.get('repeats', [])):
                start = integer_ms(repeat.get('start'))
                length = integer_ms(repeat.get('duration'), True)
                if start >= duration or start + length > duration + 1000:
                    if kind == 'repeat' and warnings is not None:
                        warnings.append({'kind': kind, 'groupIndex': group_index, 'repeatIndex': repeat_index,
                                         'reason': 'Repeat segment is outside source recording', 'segment': repeat})
                        continue
                    raise ValueError('Songle segment is outside source recording')
                result.append((kind, group_index, repeat_index, int(is_chorus), start, length))
    return result


def store_songle(db, target, entry, data):
    duration = integer_ms(entry.get('duration'), True)
    warnings = []
    rows = segments(data, duration, warnings)
    starts = [row[4] for row in rows if row[0] == 'chorus' and row[3]]
    if not starts:
        return None
    artist = artist_name(entry)
    status = 'metadata_matched' if target['artist_key'] and not warnings else 'needs_review'
    original_url = source_url(entry)
    songle_url = entry.get('url') or 'https://songle.jp/songs/' + urllib.parse.quote(
        urllib.parse.urlunsplit(('', urllib.parse.urlsplit(original_url).netloc,
                               urllib.parse.urlsplit(original_url).path,
                               urllib.parse.urlsplit(original_url).query, '')).lstrip('//'), safe='')
    payload = {'song': entry, 'map': data, 'match': status, 'targetTitle': target['title'],
               'targetArtist': target['artist'], 'credit': CREDIT, 'termsURL': TERMS_URL,
               'validationWarnings': warnings}
    key = str(entry.get('id') or original_url)
    db.execute('''INSERT INTO observations
        (track_id,source,source_key,chorus_start_ms,duration_ms,status,fetched_at,source_url,songle_url,payload_json)
        VALUES(?,'songle',?,?,?,?,?,?,?,?) ON CONFLICT(source,source_key) DO UPDATE SET
            track_id=CASE WHEN excluded.status='metadata_matched' THEN excluded.track_id ELSE observations.track_id END,
            chorus_start_ms=excluded.chorus_start_ms, duration_ms=excluded.duration_ms,
            status=CASE WHEN excluded.status='needs_review' AND json_array_length(excluded.payload_json,'$.validationWarnings')>0
                THEN 'needs_review' WHEN observations.status='metadata_matched' THEN observations.status ELSE excluded.status END,
            fetched_at=excluded.fetched_at,
            payload_json=CASE WHEN observations.status='metadata_matched' AND excluded.status='needs_review'
                AND COALESCE(json_array_length(excluded.payload_json,'$.validationWarnings'),0)=0
                THEN observations.payload_json ELSE excluded.payload_json END''',
        (track_id(db, target['title'], target['artist'] or artist), key, min(starts), duration, status, now(),
         original_url, songle_url, encoded(payload)))
    observation = db.execute("SELECT id FROM observations WHERE source='songle' AND source_key=?", (key,)).fetchone()[0]
    db.execute('DELETE FROM segments WHERE observation_id=?', (observation,))
    db.executemany('INSERT INTO segments VALUES(?,?,?,?,?,?,?)', [(observation, *row) for row in rows])
    db.execute('INSERT OR IGNORE INTO target_observations VALUES(?,?)', (target['id'], observation))
    return observation


def collect_target(db, client, target, refresh=False):
    query = ' '.join(filter(None, (target['title'], target['artist'])))
    try:
        result = client.get(API + 'songs/search.json?' + urllib.parse.urlencode({'q': query}), refresh)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            with db:
                db.execute('UPDATE targets SET search_json=? WHERE id=?', ('[]', target['id']))
            return 'not_found'
        raise
    if not isinstance(result, (list, dict)):
        raise ValueError('Invalid Songle search response')
    entries = result if isinstance(result, list) else result.get('songs', result.get('results', []))
    exact = [entry for entry in entries if title_matches(entry, target)
             and artist_name(entry) and (not target['artist_key'] or artist_key(artist_name(entry)) == target['artist_key'])]
    with db:
        db.execute('UPDATE targets SET search_json=? WHERE id=?', (encoded(result), target['id']))
    if not exact:
        return 'not_found' if not entries else 'no_exact_match'
    # Keep a few distinct recordings; the source URL/duration remains part of each observation.
    # Never pick a cover or another artist by a fuzzy substring match.
    exact = sorted(exact, key=lambda entry: (entry.get('url', ''), str(entry.get('id', ''))))[:3]
    found = 0
    for entry in exact:
        original = source_url(entry)
        parsed = urllib.parse.urlsplit(original)
        api_source = urllib.parse.urlunsplit(('', parsed.netloc, parsed.path, parsed.query, '')).lstrip('//')
        try:
            data = client.get(API + 'song/chorus.json?' + urllib.parse.urlencode({'url': api_source}), refresh)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                continue
            raise
        if not isinstance(data, dict):
            raise ValueError('Invalid Songle chorus response')
        with db:
            found += store_songle(db, target, entry, data) is not None
    if not found:
        return 'no_chorus'
    matched = db.execute('''SELECT 1 FROM target_observations JOIN observations ON observations.id=observation_id
        WHERE target_id=? AND status='metadata_matched' LIMIT 1''', (target['id'],)).fetchone()
    return 'collected' if target['artist_key'] and matched else 'needs_review'


def summary(db):
    count = lambda sql: db.execute(sql).fetchone()[0]
    return {'schemaVersion': 1, 'usage': 'noncommercial-local-private', 'updatedAt': now(),
            'manualRecords': count("SELECT count(*) FROM observations WHERE source='manual'"),
            'songleRecordings': count("SELECT count(*) FROM observations WHERE source='songle'"),
            'songleTracks': count("SELECT count(DISTINCT track_id) FROM observations WHERE source='songle'"),
            'totalTracksWithChorus': count('SELECT count(DISTINCT track_id) FROM observations'),
            'songleMetadataMatched': count("SELECT count(*) FROM observations WHERE source='songle' AND status='metadata_matched'"),
            'songleMetadataMatchedTracks': count("SELECT count(DISTINCT track_id) FROM observations WHERE source='songle' AND status='metadata_matched'"),
            'songleNeedsReview': count("SELECT count(*) FROM observations WHERE source='songle' AND status='needs_review'"),
            'songleValidationWarnings': count("SELECT count(*) FROM observations WHERE source='songle' AND json_array_length(payload_json,'$.validationWarnings')>0"),
            'chorusIntervals': count("SELECT count(*) FROM segments WHERE kind='chorus' AND is_chorus=1"),
            'targets': dict(db.execute('SELECT status,count(*) FROM targets GROUP BY status').fetchall()),
            'credit': CREDIT, 'termsURL': TERMS_URL}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=DEFAULT_DB)
    parser.add_argument('--manual-catalog', type=Path, default=ROOT / 'server/manual-chorus.json')
    parser.add_argument('--collect', action='store_true', help='Read Songle public metadata APIs')
    parser.add_argument('--charts', action='store_true', help='Resolve corpus artists from the original Billboard charts')
    parser.add_argument('--limit', type=int, help='Maximum targets this run; omitted means all pending targets')
    parser.add_argument('--retry-errors', action='store_true')
    parser.add_argument('--retry-unmatched', action='store_true', help='Recheck nonmatching search results, using saved responses')
    parser.add_argument('--refresh', action='store_true', help='Refresh completed targets and successful HTTP cache')
    parser.add_argument('--interval', type=float, default=0.5, help='Minimum seconds between network requests (>=0.5)')
    args = parser.parse_args()
    if args.interval < 0.5 or (args.limit is not None and args.limit < 1):
        parser.error('interval must be >=0.5 and limit must be positive')
    previous_umask = os.umask(0o077)
    db = None
    try:
        db = open_database(args.db)
        print(f'Migrated {migrate_manual(db, args.manual_catalog)} manual records; database: {args.db}', flush=True)
        client = Client(db, args.interval)
        if args.charts or not db.execute('SELECT 1 FROM targets LIMIT 1').fetchone():
            print(f'Seeded {seed_targets(db, client if args.charts else None)} corpus targets', flush=True)
        if args.collect:
            print(f'{CREDIT}\nNoncommercial, local private storage. Terms: {TERMS_URL}', flush=True)
            states = ['pending'] + (['error'] if args.retry_errors else [])
            if args.retry_unmatched:
                states += ['no_exact_match']
            if args.refresh:
                states += ['collected', 'needs_review', 'not_found', 'no_exact_match', 'no_chorus']
            marks = ','.join('?' for _ in states)
            targets = db.execute(f'SELECT * FROM targets WHERE status IN ({marks}) ORDER BY id', states).fetchall()
            targets = targets[:args.limit] if args.limit else targets
            consecutive_errors = 0
            for index, target in enumerate(targets, 1):
                error = None
                try:
                    status = collect_target(db, client, target, args.refresh)
                    consecutive_errors = 0
                except (urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as problem:
                    status, error = 'error', f'{type(problem).__name__}: {problem}'
                    consecutive_errors += 1
                with db:
                    db.execute('UPDATE targets SET status=?,attempts=attempts+1,updated_at=?,error=? WHERE id=?',
                               (status, now(), error, target['id']))
                print(f'{index}/{len(targets)} {status}: {target["title"]} / {target["artist"]}', flush=True)
                if consecutive_errors >= 3:
                    print('Stopped after 3 consecutive errors; rerun with --retry-errors to resume.', flush=True)
                    break
        report = summary(db)
        report_path = args.db.with_suffix('.summary.json')
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        report_path.chmod(0o600)
        print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
        if db.execute("SELECT 1 FROM targets WHERE status='error' LIMIT 1").fetchone():
            return 2
        return 0
    finally:
        if db:
            db.close()
        os.umask(previous_umask)


if __name__ == '__main__':
    raise SystemExit(main())
