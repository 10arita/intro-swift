import { readFileSync } from 'node:fs';

export const normalizeChorusIdentity = value => String(value || '').normalize('NFKC').toUpperCase().replace(/\s/gu, '');
const key = (title, artist) => `${normalizeChorusIdentity(title)}\0${normalizeChorusIdentity(artist)}`;

export function createChorusIndex(catalog) {
  if (catalog.schemaVersion !== 1 || catalog.recordCount !== catalog.records?.length) throw new Error('Invalid chorus catalog');
  const entries = new Map();
  for (const entry of catalog.records) {
    if (!normalizeChorusIdentity(entry.title) || !normalizeChorusIdentity(entry.artist) ||
        !Number.isSafeInteger(entry.chorusStartMS) || !Number.isSafeInteger(entry.durationMS) ||
        entry.chorusStartMS < 0 || entry.chorusStartMS >= entry.durationMS) throw new Error('Invalid chorus entry');
    const identity = key(entry.title, entry.artist);
    if (!entries.has(identity) || entries.get(identity).checkedAt <= entry.checkedAt) entries.set(identity, entry);
  }
  return entries;
}

export const manualChorusIndex = createChorusIndex(JSON.parse(readFileSync(new URL('./manual-chorus.json', import.meta.url), 'utf8')));

export function manualChorusPosition(song, entries = manualChorusIndex) {
  if (String(song?.id || '').startsWith('itunes:')) return null;
  const entry = entries.get(key(song?.title, song?.artist));
  if (!entry || (song.durationMS > 0 && entry.chorusStartMS >= song.durationMS)) return null;
  return Math.max(0, entry.chorusStartMS - 1500);
}
