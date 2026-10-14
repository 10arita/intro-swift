import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { SQLiteChorusStore } from './sqlite-chorus.mjs';

const song = { id: 'applemusic:another-album', title: 'Ｓｏｎｇ', artist: 'Singer', durationMS: 180000 };
const record = (start = 60000) => ({ title: 'Song', artist: 'Singer', source: 'manual', sourceKey: 'record-1',
  chorusStartMS: start, durationMS: 180000, status: 'manually_confirmed', checkedAt: '2026-10-12T00:00:00Z' });
const catalog = (...records) => ({ schemaVersion: 1, recordCount: records.length, records });
const empty = { databaseConfigured: true, positionMS: null, source: null };

function source(path) {
  const db = new DatabaseSync(path);
  db.exec(`CREATE TABLE tracks(id INTEGER PRIMARY KEY,title TEXT,artist TEXT,title_key TEXT,artist_key TEXT);
    CREATE TABLE observations(id INTEGER PRIMARY KEY,track_id INTEGER,source TEXT,source_key TEXT,
      chorus_start_ms INTEGER,duration_ms INTEGER,status TEXT,checked_at TEXT);
    INSERT INTO tracks VALUES(1,'Song','Singer','SONG','SINGER');
    INSERT INTO observations VALUES(1,1,'manual','original-1',60000,180000,'manually_confirmed','2026-10-12T00:00:00Z');`);
  return db;
}

test('committed SQLite edits, WAL writes and file replacement are visible without restarting', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-live-chorus-'));
  const path = join(directory, 'source.sqlite3');
  const writer = source(path);
  const store = new SQLiteChorusStore(path);
  try {
    writer.exec('PRAGMA journal_mode=WAL');
    assert.equal(store.lookup(song).positionMS, 58500);
    writer.exec('BEGIN; UPDATE observations SET chorus_start_ms=80000 WHERE id=1;');
    assert.equal(store.lookup(song).positionMS, 58500, 'uncommitted edits must not leak');
    writer.exec('COMMIT');
    assert.equal(store.lookup(song).positionMS, 78500);
    assert.throws(() => store.replace(catalog(record())), /source database is read-only/);
    assert.equal(store.lookup(song).positionMS, 78500);
    writer.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    writer.close(); store.close();
    const replacement = join(directory, 'replacement.sqlite3');
    const next = source(replacement);
    next.exec('UPDATE observations SET chorus_start_ms=90000 WHERE id=1;'); next.close();
    assert.equal(store.lookup(song).positionMS, 78500);
    renameSync(replacement, path);
    assert.equal(store.lookup(song).positionMS, 88500);
  } finally {
    store.close(); if (writer.isOpen) writer.close(); rmSync(directory, { recursive: true, force: true });
  }
});

test('manual precedence, preview exclusion, playback bounds and unreviewed candidates', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-chorus-policy-'));
  const path = join(directory, 'source.sqlite3');
  const writer = source(path), store = new SQLiteChorusStore(path);
  try {
    writer.exec(`INSERT INTO observations VALUES(2,1,'songle','songle-1',70000,181000,'metadata_matched',NULL)`);
    assert.deepEqual(store.lookup(song), { databaseConfigured: true, positionMS: 58500, source: 'manual_database' });
    assert.deepEqual(store.lookup({ ...song, id: 'itunes:123' }), empty);
    assert.deepEqual(store.lookup({ ...song, title: 'Song (Live)' }), empty);
    assert.deepEqual(store.lookup({ ...song, artist: 'Another Singer' }), empty);
    writer.exec('DELETE FROM observations WHERE id=1');
    assert.deepEqual(store.lookup(song), { databaseConfigured: true, positionMS: 68500, source: 'songle_database' });
    assert.deepEqual(store.lookup({ ...song, durationMS: 160000 }),
      { databaseConfigured: true, positionMS: 68500, source: 'songle_database' });
    assert.deepEqual(store.lookup({ ...song, durationMS: 70000 }), empty);
    writer.exec("UPDATE observations SET status='needs_review'");
    assert.deepEqual(store.lookup(song), empty);
    writer.exec("UPDATE observations SET status='metadata_matched',chorus_start_ms=0");
    assert.equal(store.lookup(song).positionMS, 0);
  } finally { store.close(); writer.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('君がくれた夏 uses the same stored chorus across singles and albums with different durations', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-chorus-albums-'));
  const store = new SQLiteChorusStore(join(directory, 'replica.sqlite3'));
  try {
    store.replace(catalog({ ...record(75987), title: '君がくれた夏', artist: '家入レオ',
      source: 'songle', sourceKey: '1919809', durationMS: 279840, status: 'metadata_matched' }));
    for (const [id, album, durationMS] of [
      ['1026711118', '君がくれた夏 - Single', 258360],
      ['1124863475', 'WE', 258680],
      ['1198925442', '5th Anniversary Best', 259600],
      ['i.ZOMr4Q3uvDz5Q9K', 'Library release', 259600]
    ]) {
      const release = { id: `applemusic:${id}`, title: '君がくれた夏', artist: '家入レオ', album, durationMS };
      assert.deepEqual(store.lookup(release),
        { databaseConfigured: true, positionMS: 74487, source: 'songle_database' }, album);
      for (const title of ['君がくれた夏 (LIVE)', '君がくれた夏 (Piano Version)', '君がくれた夏 (10th Anniversary Version)'])
        assert.deepEqual(store.lookup({ ...release, title }), empty);
      assert.deepEqual(store.lookup({ ...release, artist: '別のアーティスト' }), empty);
      assert.deepEqual(store.lookup({ ...release, durationMS: 75987 }), empty);
    }
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('authenticated snapshot replacement retains prior data on invalid input and applies deletions', () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-chorus-replica-'));
  const path = join(directory, 'replica.sqlite3');
  const store = new SQLiteChorusStore(path);
  try {
    assert.equal(store.lookup(song).databaseConfigured, false);
    assert.equal(store.replace(catalog(record())).recordCount, 1);
    assert.equal(store.lookup(song).positionMS, 58500);
    assert.equal(statSync(path).mode & 0o777, 0o600);
    for (const bad of [{ ...record(), chorusStartMS: -1 }, { ...record(), chorusStartMS: 180000 },
      { ...record(), status: 'needs_review' }, { ...record(), title: '' }]) {
      assert.throws(() => store.replace(catalog(record(80000), bad)));
      assert.equal(store.lookup(song).positionMS, 58500);
    }
    assert.throws(() => store.replace(catalog(record(), record())), /Duplicate/);
    store.replace(catalog(record(80000)));
    assert.equal(store.lookup(song).positionMS, 78500);
    store.replace(catalog({ ...record(70000), source: 'songle', status: 'metadata_matched' }));
    assert.deepEqual(store.lookup(song), { databaseConfigured: true, positionMS: 68500, source: 'songle_database' });
    store.replace(catalog());
    assert.deepEqual(store.lookup(song), empty);
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('a local DB edit reaches the private server replica and HTTP lookup while the processes keep running', { timeout: 15000 }, async () => {
  const directory = mkdtempSync(join(tmpdir(), 'intol-chorus-http-'));
  const path = join(directory, 'replica.sqlite3'), original = join(directory, 'source.sqlite3');
  const writer = source(original);
  const token = 'test-only-chorus-sync-token-1234567890';
  const processServer = spawn(process.execPath, ['--input-type=module', '-e',
    "import {server} from './index.mjs'; server.listen(0,'127.0.0.1',()=>console.log(server.address().port));"],
    { cwd: import.meta.dirname, env: { ...process.env, DATA_DIR: directory, CHORUS_DB_PATH: path, CHORUS_SYNC_TOKEN: token } });
  let watcher;
  let serverError = '';
  processServer.stderr.on('data', chunk => { serverError += chunk; });
  try {
    const [chunk] = await Promise.race([once(processServer.stdout, 'data'),
      once(processServer, 'exit').then(() => { throw new Error(serverError || 'Server exited before listening'); })]);
    const origin = `http://127.0.0.1:${Number(String(chunk).trim())}`;
    const query = () => fetch(origin + '/chorus/database', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(song) });
    const unauthorized = await fetch(origin + '/admin/chorus-sync', { method: 'PUT',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(catalog(record())) });
    assert.equal(unauthorized.status, 403);
    const config = join(directory, 'sync.env');
    writeFileSync(config, `CHORUS_SYNC_URL=${origin}\nCHORUS_SYNC_TOKEN=${token}\n`, { mode: 0o600 });
    watcher = spawn('python3', [join(import.meta.dirname, '../scripts/sync_chorus_database.py'),
      '--db', original, '--config', config, '--watch', '--interval', '1'], { stdio: ['ignore', 'pipe', 'pipe'] });
    const first = await once(watcher.stdout, 'data');
    assert.match(String(first[0]), /Synchronized 1/);
    const response = await query();
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), { databaseConfigured: true, positionMS: 58500, source: 'manual_database' });
    writer.exec('UPDATE observations SET chorus_start_ms=95000 WHERE id=1');
    const second = await once(watcher.stdout, 'data');
    assert.match(String(second[0]), /Synchronized 1/);
    assert.equal((await (await query()).json()).positionMS, 93500);
    assert.equal((await fetch(origin + '/data/chorus/catalog.sqlite3')).status, 404);
    assert.equal((await fetch(origin + '/.private/chorus/chorus.sqlite3')).status, 404);
    const bad = await fetch(origin + '/admin/chorus-sync', { method: 'PUT',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(catalog({ ...record(), chorusStartMS: -1 })) });
    assert.equal(bad.status, 400);
    assert.equal((await (await query()).json()).positionMS, 93500);
    writer.exec("UPDATE observations SET source='songle',status='metadata_matched' WHERE id=1");
    const third = await once(watcher.stdout, 'data');
    assert.match(String(third[0]), /Synchronized 1/);
    const storedSongle = { databaseConfigured: true, positionMS: 93500, source: 'songle_database' };
    assert.deepEqual(await (await query()).json(), storedSongle);
    const chorus = await fetch(origin + '/chorus', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(song) });
    assert.deepEqual(await chorus.json(), storedSongle);
    const otherAlbum = { ...song, id: 'applemusic:another-release', album: 'Compilation', durationMS: 160000 };
    for (const route of ['/chorus/database', '/chorus']) {
      const response = await fetch(origin + route, { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(otherAlbum) });
      assert.deepEqual(await response.json(), storedSongle, `${route} must use stored DB positions across albums`);
    }
  } finally {
    watcher?.kill();
    if (processServer.exitCode === null && processServer.signalCode === null) {
      const exited = once(processServer, 'exit'); processServer.kill(); await exited;
    }
    writer.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
