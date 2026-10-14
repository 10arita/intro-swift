import { manualChorusPosition } from './manual-chorus.mjs';
import { sqliteChorusStore } from './sqlite-chorus.mjs';

// This proxy only supplies song-title metadata for answer choices.
const cache = new Map();
async function json(url, ttl = 60_000) {
  const key = url.toString();
  const saved = cache.get(key);
  if (saved && saved.until > Date.now()) return saved.value;
  const response = await fetch(url, { signal: AbortSignal.timeout(8000), headers: { 'User-Agent': 'IntoL-learning/1.0' } });
  if (!response.ok) throw new Error(`外部サービスが応答しません (${response.status})`);
  const value = await response.json();
  cache.set(key, { value, until: Date.now() + ttl });
  return value;
}
export async function topSongs() {
  const feed = await json('https://rss.applemarketingtools.com/api/v2/jp/music/most-played/100/songs.json', 6 * 60 * 60_000);
  return (feed.feed?.results || []).map(item => item.name).filter(Boolean);
}
export function fallbackChorus(durationMS) {
  const duration = Number(durationMS);
  const playableDuration = Number.isFinite(duration) && duration > 0 ? duration : 180_000;
  const estimated = Math.min(90_000, Math.max(30_000, playableDuration * .32)) - 1500;
  return Math.max(0, Math.round(Math.min(estimated, playableDuration - 5000)));
}
export async function chorusPosition(song) {
  return (await chorusResult(song)).positionMS;
}
export async function chorusResult(song) {
  const stored = sqliteChorusStore.lookup(song);
  if (stored.positionMS !== null) return stored;
  const manual = stored.databaseConfigured ? null : manualChorusPosition(song);
  if (manual !== null) return { positionMS: manual, source: 'manual_database', databaseConfigured: false };
  return { positionMS: null, source: null, databaseConfigured: stored.databaseConfigured };
}
