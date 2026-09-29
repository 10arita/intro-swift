// Only metadata and provider URLs are proxied. Audio remains on the provider's CDN.
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
export function clean(value) {
  return String(value || '').normalize('NFKC').toLocaleLowerCase('ja-JP').replace(/[\s\p{P}\p{S}]/gu, '');
}
function baseTitle(value) {
  return clean(String(value || '').replace(/\([^)]*\)|（[^）]*）/g, '')
    .replace(/\s+(?:feat\.?|featuring)\s+.*$/i, '').replace(/\s+-\s+.*$/, ''));
}
function itunesSong(item) {
  if (!item?.trackName || !item.previewUrl?.startsWith('https://')) return null;
  return {
    id: `itunes:${item.trackId}`, title: item.trackName, artist: item.artistName || '',
    artworkURL: item.artworkUrl100?.replace('100x100', '600x600') || null,
    previewURL: item.previewUrl, trackURL: item.trackViewUrl || null,
    durationMS: item.trackTimeMillis || 30_000, genre: item.primaryGenreName || 'その他'
  };
}
export async function searchItunes(term, limit = 25) {
  if (!String(term).trim() || String(term).length > 100) return [];
  const url = new URL('https://itunes.apple.com/search');
  url.search = new URLSearchParams({ term, country: 'JP', media: 'music', entity: 'song', limit: String(Math.min(50, limit)) }).toString();
  return (await json(url)).results.map(itunesSong).filter(Boolean);
}
export async function matchItunes(song) {
  const candidates = await searchItunes(`${song.title} ${song.artist}`, 20);
  const title = baseTitle(song.title), artist = clean(String(song.artist || '').split(',')[0]);
  const exact = candidates.find(s => baseTitle(s.title) === title && clean(s.artist) === artist);
  const close = candidates.find(s => baseTitle(s.title) === title && artist &&
    (clean(s.artist).includes(artist) || artist.includes(clean(s.artist))));
  return exact || close || null;
}
export async function topSongs() {
  const feed = await json('https://rss.applemarketingtools.com/api/v2/jp/music/most-played/100/songs.json', 6 * 60 * 60_000);
  return (feed.feed?.results || []).map(item => item.name).filter(Boolean);
}
export function fallbackChorus(durationMS) {
  const duration = Number(durationMS);
  const playableDuration = Number.isFinite(duration) && duration > 0 ? duration : 180_000;
  return Math.max(0, Math.round(Math.min(90_000, Math.max(30_000, playableDuration * .32)) - 1500));
}
export async function chorusPosition(song) {
  if (!song?.songleURL && song?.title) {
    try {
      const search = new URL('https://widget.songle.jp/api/v1/songs/search.json');
      search.searchParams.set('q', `${song.title} ${song.artist || ''}`.trim());
      const result = await json(search, 24 * 60 * 60_000);
      const entries = Array.isArray(result) ? result : result.songs || result.results || [];
      const matches = entries.filter(entry => baseTitle(entry.title || entry.name) === baseTitle(song.title) &&
        (!song.artist || clean(String(entry.artist?.name || entry.artist || '')).includes(clean(String(song.artist).split(',')[0]))));
      const duration = Number(song.durationMS);
      const distance = entry => Math.abs((Number(entry.duration) || duration) - duration);
      const matched = Number.isFinite(duration) && duration > 0 ? matches.sort((a, b) => distance(a) - distance(b))[0] : matches[0];
      song = { ...song, songleURL: matched?.permalink || matched?.source?.url || matched?.url || null };
    } catch { /* The client chooses an audio fallback. */ }
  }
  if (!song?.songleURL) return null;
  let source;
  try {
    const raw = String(song.songleURL);
    source = new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`);
    if (source.hostname === 'songle.jp' || source.hostname === 'www.songle.jp') {
      const encodedSource = source.pathname.match(/^\/songs\/(.+)$/)?.[1];
      if (!encodedSource) return null;
      source = new URL(`https://${decodeURIComponent(encodedSource)}`);
    }
  } catch { return null; }
  if (!['http:', 'https:'].includes(source.protocol) || !['www.youtube.com', 'youtube.com', 'youtu.be', 'www.nicovideo.jp', 'www.niconico.jp'].includes(source.hostname)) {
    return null;
  }
  const url = new URL('https://widget.songle.jp/api/v1/song/chorus.json');
  url.searchParams.set('url', `${source.host}${source.pathname}${source.search}`);
  try {
    const data = await json(url, 24 * 60 * 60_000);
    const start = data.chorusSegments?.find(s => s.isChorus)?.repeats?.[0]?.start;
    if (Number.isFinite(start)) return Math.max(0, Math.min(Math.max(0, Number(song.durationMS || 180_000) - 5000), Math.round(start - 1500)));
  } catch { /* The client chooses an audio fallback. */ }
  return null;
}
