import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdirSync, statSync, chmodSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { normalizeChorusIdentity } from './manual-chorus.mjs';

const validPosition = row => Number.isSafeInteger(row.chorus_start_ms) &&
  Number.isSafeInteger(row.duration_ms) && row.chorus_start_ms >= 0 && row.chorus_start_ms < row.duration_ms;

export class SQLiteChorusStore {
  constructor(path = null) { this.path = path ? resolve(path) : null; }
  close() { this.database?.close(); this.database = null; this.identity = null; }
  connection() {
    if (!this.path || !existsSync(this.path)) { this.close(); return null; }
    const stat = statSync(this.path);
    const identity = `${stat.dev}:${stat.ino}`;
    if (!this.database || this.identity !== identity) {
      this.close();
      this.database = new DatabaseSync(this.path, { readOnly: true });
      this.database.exec('PRAGMA busy_timeout=1000; PRAGMA query_only=ON');
      this.managed = Boolean(this.database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='chorus_records'").get());
      this.identity = identity;
    }
    return this.database;
  }
  lookup(song) {
    const database = this.connection();
    if (!database) return { databaseConfigured: false, positionMS: null, source: null };
    const empty = { databaseConfigured: true, positionMS: null, source: null };
    if (String(song?.id || '').startsWith('itunes:')) return empty;
    if (typeof song?.title !== 'string' || typeof song?.artist !== 'string' ||
        song.title.length > 512 || song.artist.length > 512) return empty;
    const title = normalizeChorusIdentity(song.title), artist = normalizeChorusIdentity(song.artist);
    if (!title || !artist) return empty;
    const from = this.managed ? 'chorus_records' : 'observations JOIN tracks ON tracks.id=observations.track_id';
    const rows = database.prepare(`SELECT source, chorus_start_ms, duration_ms, checked_at
      FROM ${from} WHERE title_key=? AND artist_key=?
      AND ((source='manual' AND status='manually_confirmed') OR (source='songle' AND status='metadata_matched'))
      ORDER BY CASE source WHEN 'manual' THEN 0 ELSE 1 END, checked_at DESC`).all(title, artist);
    const duration = Number(song.durationMS);
    const row = rows.filter(row => validPosition(row) && (!(duration > 0) || row.chorus_start_ms < duration) &&
      (row.source === 'manual' || !(duration > 0) || Math.abs(row.duration_ms - duration) <= 3000))
      .sort((a, b) => a.source === b.source && a.source === 'songle' && duration > 0
        ? Math.abs(a.duration_ms - duration) - Math.abs(b.duration_ms - duration) : 0)[0];
    if (!row) return empty;
    const position = Math.max(0, row.chorus_start_ms - 1500);
    return { databaseConfigured: true,
      positionMS: row.source === 'songle' && duration > 0 ? Math.min(position, Math.max(0, duration - 5000)) : position,
      source: row.source === 'manual' ? 'manual_database' : 'songle_database' };
  }
  replace(catalog) {
    if (!this.path) throw new Error('CHORUS_DB_PATH or DATA_DIR is required for database synchronization');
    if (catalog?.schemaVersion !== 1 || !Array.isArray(catalog.records) ||
        catalog.recordCount !== catalog.records.length || catalog.recordCount > 20000) throw new Error('Invalid chorus snapshot');
    const seen = new Set();
    const rows = catalog.records.map(record => {
      if (typeof record.title !== 'string' || typeof record.artist !== 'string' ||
          record.title.length > 512 || record.artist.length > 512 ||
          !normalizeChorusIdentity(record.title) || !normalizeChorusIdentity(record.artist) ||
          !['manual', 'songle'].includes(record.source) || typeof record.sourceKey !== 'string' ||
          !record.sourceKey || record.sourceKey.length > 2048 ||
          !validPosition({ chorus_start_ms: record.chorusStartMS, duration_ms: record.durationMS }) ||
          record.status !== (record.source === 'manual' ? 'manually_confirmed' : 'metadata_matched') ||
          (record.checkedAt !== null && (typeof record.checkedAt !== 'string' || record.checkedAt.length > 64)))
        throw new Error('Invalid chorus snapshot record');
      const key = `${record.source}\0${record.sourceKey}`;
      if (seen.has(key)) throw new Error('Duplicate chorus snapshot record');
      seen.add(key);
      return record;
    });
    // The source DB includes evidence, raw API maps and import history. Never replace it with a replica.
    const original = this.connection();
    if (original && !this.managed) throw new Error('The source database is read-only; synchronize to a separate server replica');
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const writer = new DatabaseSync(this.path);
    chmodSync(this.path, 0o600);
    try {
      writer.exec(`PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS chorus_records (
          source TEXT NOT NULL, source_key TEXT NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL,
          title_key TEXT NOT NULL, artist_key TEXT NOT NULL, chorus_start_ms INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL, status TEXT NOT NULL, checked_at TEXT,
          PRIMARY KEY(source,source_key));
        CREATE INDEX IF NOT EXISTS chorus_identity ON chorus_records(title_key,artist_key);
        BEGIN IMMEDIATE; DELETE FROM chorus_records;`);
      const insert = writer.prepare('INSERT INTO chorus_records VALUES(?,?,?,?,?,?,?,?,?,?)');
      for (const row of rows) insert.run(row.source, row.sourceKey, row.title, row.artist,
        normalizeChorusIdentity(row.title), normalizeChorusIdentity(row.artist),
        row.chorusStartMS, row.durationMS, row.status, row.checkedAt);
      writer.exec('COMMIT');
    } catch (error) {
      try { writer.exec('ROLLBACK'); } catch { }
      throw error;
    } finally { writer.close(); }
    return { recordCount: rows.length,
      sha256: createHash('sha256').update(JSON.stringify(rows)).digest('hex') };
  }
}

const path = process.env.CHORUS_DB_PATH ||
  (process.env.DATA_DIR ? join(process.env.DATA_DIR, 'chorus', 'catalog.sqlite3') : null);
export const sqliteChorusStore = new SQLiteChorusStore(path);
