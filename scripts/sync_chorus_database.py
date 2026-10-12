#!/usr/bin/env python3
"""Send only usable chorus metadata from a private SQLite DB to the private server replica.

Run --watch to propagate committed DB edits without a rebuild or server restart.
The administration token is read from a private env file, never from iOS config.
"""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def snapshot(path):
    with closing(sqlite3.connect(Path(path).absolute().as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        # A single SELECT is a consistent SQLite snapshot, including committed WAL edits.
        rows = db.execute('''SELECT t.title,t.artist,o.source,o.source_key,o.chorus_start_ms,
            o.duration_ms,o.status,o.checked_at FROM observations o JOIN tracks t ON t.id=o.track_id
            WHERE (o.source='manual' AND o.status='manually_confirmed')
               OR (o.source='songle' AND o.status='metadata_matched')
            ORDER BY o.source,o.source_key''').fetchall()
    fields = ('title', 'artist', 'source', 'sourceKey', 'chorusStartMS', 'durationMS', 'status', 'checkedAt')
    records = [dict(zip(fields, row)) for row in rows]
    return {'schemaVersion': 1, 'recordCount': len(records), 'records': records}


def read_config(path):
    values = {}
    if path.exists():
        if path.stat().st_mode & 0o077:
            raise ValueError('Sync credentials file must have permissions 0600')
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith('#'):
                key, separator, value = line.partition('=')
                if separator:
                    values[key.strip()] = value.strip().strip('\"\'')
    return {key: os.environ.get(key, values.get(key, '')) for key in ('CHORUS_SYNC_URL', 'CHORUS_SYNC_TOKEN')}


def synchronize(catalog, config):
    url = urllib.parse.urlsplit(config['CHORUS_SYNC_URL'])
    if (not url.hostname or url.username or url.password or url.query or url.fragment
            or url.path not in ('', '/') or
            (url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ('127.0.0.1', 'localhost')))):
        raise ValueError('CHORUS_SYNC_URL must be an HTTPS origin (HTTP localhost is allowed for testing)')
    token = config['CHORUS_SYNC_TOKEN']
    if len(token) < 32:
        raise ValueError('CHORUS_SYNC_TOKEN must contain at least 32 characters')
    body = json.dumps(catalog, ensure_ascii=False, separators=(',', ':')).encode()
    request = urllib.request.Request(config['CHORUS_SYNC_URL'].rstrip('/') + '/admin/chorus-sync', data=body,
        method='PUT', headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
    # An admin credential must never follow a redirect to another origin.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, message, headers, newurl):
            return None
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
        result = json.load(response)
    if result.get('recordCount') != catalog['recordCount'] or not isinstance(result.get('sha256'), str):
        raise ValueError('Server did not confirm the uploaded record count')
    return result


def digest(catalog):
    return hashlib.sha256(json.dumps(catalog, ensure_ascii=False, sort_keys=True,
                                    separators=(',', ':')).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=ROOT / '.private/chorus/chorus.sqlite3')
    parser.add_argument('--config', type=Path, default=ROOT / '.private/chorus/sync.env')
    parser.add_argument('--watch', action='store_true')
    parser.add_argument('--interval', type=float, default=5)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.interval < 1:
        parser.error('interval must be at least one second')
    previous = None
    try:
        while True:
            try:
                catalog = snapshot(args.db)
                current = digest(catalog)
                if current != previous:
                    if args.dry_run:
                        print(f'Ready: {catalog["recordCount"]} usable observations, SHA-256 {current}', flush=True)
                    else:
                        result = synchronize(catalog, read_config(args.config))
                        print(f'Synchronized {result["recordCount"]} observations; SHA-256 {result["sha256"]}', flush=True)
                    previous = current
                if not args.watch:
                    return 0
            except (sqlite3.Error, OSError, ValueError) as error:
                # Do not print request headers, tokens, response bodies or full credential-bearing URLs.
                print(f'Synchronization failed ({type(error).__name__}); check private configuration and server availability.', flush=True)
                if not args.watch:
                    return 1
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
