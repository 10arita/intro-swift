import { createServer } from 'node:http';
import { randomUUID, randomInt } from 'node:crypto';
import { createReadStream, readFileSync, statSync, existsSync, mkdirSync, writeFileSync, renameSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { searchItunes, matchItunes, topSongs, chorusPosition } from './external.mjs';

const rooms = new Map();
const profiles = new Map();
const DATA_DIR = process.env.DATA_DIR ? resolve(process.env.DATA_DIR) : null;
const DATA_FILE = DATA_DIR ? join(DATA_DIR, 'state.json') : null;
if (DATA_FILE && existsSync(DATA_FILE)) {
  try {
    const saved = JSON.parse(readFileSync(DATA_FILE, 'utf8'));
    for (const room of saved.rooms || []) {
      room.pushed = new Set(room.pushed || []); room.skipped = new Set(room.skipped || []);
      room.readyIds = new Set(room.readyIds || []);
      rooms.set(room.id, room);
    }
    for (const profile of saved.profiles || []) profiles.set(profile.id, profile);
  } catch (error) { console.error('Saved state could not be loaded:', error); }
}
let saveTimer;
export function saveStateNow() {
  if (!DATA_FILE) return;
  mkdirSync(DATA_DIR, { recursive: true });
  const temporary = `${DATA_FILE}.tmp`;
  writeFileSync(temporary, JSON.stringify({ rooms: [...rooms.values()].map(room => ({ ...room, pushed: [...room.pushed], skipped: [...room.skipped], readyIds: [...room.readyIds] })), profiles: [...profiles.values()] }));
  renameSync(temporary, DATA_FILE);
}
function persist() {
  if (!DATA_FILE || saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try { saveStateNow(); } catch (error) { console.error('State save failed:', error); }
  }, 500);
  saveTimer.unref();
}
const catalog = JSON.parse(readFileSync(new URL('./catalog.json', import.meta.url), 'utf8'));
const seedTitles = ['famousSongs.json', 'famousSongsJapaneseExpansion.json', 'famousSongsJpop2015Plus.json']
  .flatMap(file => JSON.parse(readFileSync(new URL(`./corpus/${file}`, import.meta.url), 'utf8')));
const PORT = Number(process.env.PORT ?? 3000);
const MAX_BODY = 256_000;
const GRACE = 5 * 60_000;
const forbidden = new Set([...'っゃゅょぁぃぅぇぉゎッャュョァィゥェォヮー']);
const pools = [
  [...'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん'],
  [...'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン'],
  [...'愛光音海風春夏秋冬君夢星夜花青空雨雪月道心時人世界日明白山川新未来恋歌声虹'],
  [...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'], [...'0123456789']
];
const visualGroups = [
  '日目白田','未末朱本','大犬太天','土士王工','人入八','青清晴静','花華芽草','歌唄謡語','空突穹室','夜液衣夢',
  '木本末未','口日目四','山出岳岩','川州順','水永氷泉','火灯炎災','金針銀鉄','月用明朋','雨雪雲雷','心必思忘',
  '春奏泰','夏復憂','秋愁愈','冬寒終','朝潮嘲','風鳳凰','海毎梅','光先元','星屋室','恋変愛',
  '道導首','音暗韻','声聖聞','新親薪','時待持','間問門','夢薫募','愛受優','君群郡','花化華',
  '高髙亮','島鳥嶋','楽薬栗','白自百','赤赦赫','青責清','黒墨黙','深探採','遠運達','近折所',
  '笑咲啖','泣涙流','走起赴','飛非悲','舞無夢','知和矢','手毛才','足是定','目貝見','耳取聞',
  '思恩忠','空室窓','石右岩','林森木','糸系紫','魚漁鮮','言計詩','女好妥','子字学','力刀功',
  '夜液掖','友反双','雪雲雷','花草葉','地池他','声唄歌','虹紅江','春椿秋','時詩持','道運遠'
];
const similar = {};
for (const group of visualGroups) for (const char of group) {
  similar[char] ||= [];
  similar[char].push(...[...group].filter(other => other !== char));
}

export function normalize(title) {
  return String(title).replace(/\([^)]*\)|（[^）]*）/g, '')
    .replace(/\s+(?:feat\.?|featuring)\s+.*$/i, '')
    .replace(/\s+-\s+.*$/, '')
    .normalize('NFKC').toUpperCase()
    .replace(/[^0-9A-Z\u3040-\u30ff\u3400-\u9fff\u3005\u3006]/g, '');
}
function kind(char) {
  const n = char.codePointAt(0);
  if (n >= 0x3040 && n <= 0x309f) return 0;
  if (n >= 0x30a0 && n <= 0x30ff) return 1;
  if (n >= 0x3400 && n <= 0x9fff || n === 0x3005 || n === 0x3006) return 2;
  if (n >= 65 && n <= 90) return 3;
  return 4;
}
function shuffled(array) {
  const copy = [...array];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = randomInt(i + 1); [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}
export function choices(answer, prefix, titles) {
  const type = kind(answer);
  const chars = titles.map(normalize).map(title => [...title]);
  const candidates = prefix ? [ ...(similar[answer] || []),
    ...chars.filter(c => c.join('').startsWith(prefix) && c.length > [...prefix].length).map(c => c[[...prefix].length]),
    ...chars.flatMap(c => c.slice(1).filter((_, i) => c[i] === [...prefix].at(-1)))
  ] : chars.map(c => c[0]);
  if (type === 2) candidates.push(...shuffled([...Array(1200)].map((_, index) => String.fromCodePoint(0x4e00 + index))));
  candidates.push(...shuffled(pools[type]));
  const unique = [...new Set(candidates)].filter(c => c && c !== answer && kind(c) === type && !forbidden.has(c));
  return shuffled([answer, ...unique.slice(0, 3)]);
}
function clamp(value, min, max, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(min, Math.min(max, Math.round(number))) : fallback;
}
function settings(input = {}) {
  return {
    questionCount: clamp(input.questionCount, 1, 50, 10), answerSlots: clamp(input.answerSlots, 1, 4, 2),
    targetScore: clamp(input.targetScore, 0, 500, 50), correctPoints: clamp(input.correctPoints, 1, 50, 10),
    firstBonus: clamp(input.firstBonus, 0, 50, 10), wrongPenalty: clamp(input.wrongPenalty, 0, 50, 10),
    firstWrongPenalty: clamp(input.firstWrongPenalty, 0, 50, 10), lives: clamp(input.lives, 0, 10, 3),
    endless: Boolean(input.endless)
  };
}
function catalogSongs(origin) {
  return catalog.filter(song => typeof song.title === 'string' && normalize(song.title)
    && /^[A-Za-z0-9_-]+\.wav$/.test(song.audioFile))
    .map(({ audioFile, ...song }) => ({ ...song, artworkURL: song.artworkURL || null,
      previewURL: `${origin.replace(/\/$/, '')}/media/${encodeURIComponent(audioFile)}`,
      trackURL: song.trackURL || null }));
}
function publicPlayer(player, room) {
  return { id: player.id, name: player.name, score: player.score, lives: player.lives,
    disqualified: player.disqualified, connected: Date.now() - player.lastSeen < GRACE,
    isHost: player.id === room.hostId, joinedAt: player.joinedAt, badge: player.badge || null };
}
function currentSong(room) { return room.songs[room.round]; }
function reveal(room) {
  room.phase = 'reveal'; room.answeringPlayerID = null; room.answerDeadline = null;
  room.revealAt = Date.now();
}
function beginRound(room) {
  if (room.round + 1 >= room.songs.length || room.settings.targetScore > 0 && room.players.some(p => p.score >= room.settings.targetScore) || room.players.every(p => p.disqualified)) {
    room.phase = 'finished'; return;
  }
  room.round++;
  room.phase = 'preparing';
  room.prepareAt = Date.now();
  room.readyIds = new Set();
  room.startAt = null;
  room.roundDeadline = null;
  room.answeringPlayerID = null;
  room.answerDeadline = null;
  room.letterIndex = 0;
  room.answerProgress = '';
  room.options = [];
  room.pushed = new Set();
  room.skipped = new Set();
  room.correctPlayerID = null;
  room.firstWrongDone = false;
}
function wrong(room, player) {
  const s = room.settings;
  player.score = Math.max(0, player.score - s.wrongPenalty - (room.firstWrongDone ? 0 : s.firstWrongPenalty));
  room.firstWrongDone = true;
  if (s.lives > 0) {
    player.lives = Math.max(0, player.lives - 1);
    player.disqualified = player.lives === 0;
  }
  room.answeringPlayerID = null;
  room.answerDeadline = null;
  room.answerProgress = '';
  room.options = [];
  const eligible = room.players.some(p => !p.disqualified && !room.pushed.has(p.id) && Date.now() - p.lastSeen < GRACE);
  if (room.pushed.size >= s.answerSlots || !eligible || Date.now() >= room.roundDeadline) reveal(room);
  else room.phase = 'listening';
}
function refresh(room) {
  const now = Date.now();
  room.players = room.players.filter(p => p.id === room.hostId || now - p.lastSeen < GRACE);
  const host = room.players.find(p => p.id === room.hostId);
  if (!host || now - host.lastSeen >= GRACE) {
    const next = room.players.filter(p => now - p.lastSeen < GRACE).sort((a,b) => a.joinedAt - b.joinedAt)[0];
    if (next) room.hostId = next.id;
  }
  if (room.phase === 'preparing') {
    const active = room.players.filter(p => now - p.lastSeen < GRACE);
    if (active.every(p => room.readyIds.has(p.id)) || now - room.prepareAt >= 8000) {
      room.phase = 'countdown'; room.startAt = now + 3000; room.roundDeadline = room.startAt + 30_000;
    }
  }
  if (room.phase === 'countdown' && now >= room.startAt) room.phase = 'listening';
  if (room.phase === 'answering' && now >= room.answerDeadline) {
    const player = room.players.find(p => p.id === room.answeringPlayerID);
    if (player) wrong(room, player); else reveal(room);
  }
  if (room.phase === 'listening' && now >= room.roundDeadline) reveal(room);
  if (room.phase !== 'lobby' && room.phase !== 'finished' && room.players.every(p => p.disqualified)) room.phase = 'finished';
}
function snapshot(room, playerId) {
  refresh(room);
  const song = room.round >= 0 ? currentSong(room) : null;
  const disclosed = room.phase === 'reveal' || room.phase === 'finished';
  return {
    id: room.id, mode: room.mode, hostId: room.hostId, phase: room.phase, round: room.round,
    totalRounds: room.songs.length,
    settings: room.settings, players: room.players.map(p => publicPlayer(p, room)),
    serverNow: Date.now(), startAt: room.startAt, roundDeadline: room.roundDeadline,
    answerDeadline: room.answeringPlayerID === playerId ? room.answerDeadline : null,
    answeringPlayerID: room.answeringPlayerID, answerProgress: room.answeringPlayerID === playerId ? room.answerProgress : '',
    options: room.answeringPlayerID === playerId ? room.options : [],
    pushedIds: [...room.pushed], skippedIds: [...room.skipped], readyIds: [...room.readyIds], correctPlayerID: room.correctPlayerID,
    current: song ? {
      id: song.id, previewURL: song.previewURL,
      ...(disclosed ? { title: song.title, artist: song.artist, artworkURL: song.artworkURL,
        trackURL: song.trackURL, durationMS: song.durationMS, genre: song.genre,
        songleURL: song.songleURL || null, chorusMS: song.chorusMS ?? null } : {})
    } : null
  };
}
function fail(status, message) { return { status, body: { error: message } }; }
export function handle(method, path, body, query, authorization, origin = 'https://example.com') {
  if (method === 'GET' && path === '/health') return { status: 200, body: { ok: true } };
  if (method === 'POST' && path === '/profile') {
    const id = String(body.id || '');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(id)) return fail(400, 'プロフィールIDが無効です');
    if (profiles.has(id)) return fail(409, '既存プロフィールです');
    const profile = { id, secret: randomUUID(), reviews: [], history: [], stats: null };
    profiles.set(id, profile);
    return { status: 201, body: { ...profile, token: profile.secret, secret: undefined } };
  }
  if ((method === 'GET' || method === 'PUT') && path === '/profile') {
    const id = String(method === 'GET' ? query.get('id') || '' : body.id || '');
    const profile = profiles.get(id);
    if (!profile || authorization?.replace(/^Bearer /, '') !== profile.secret) return fail(403, 'プロフィールを確認できません');
    if (method === 'PUT') {
      if (Array.isArray(body.history)) profile.history = body.history.slice(0, 5);
      if (Array.isArray(body.reviews)) {
        const items = body.reviews.filter(item => item && typeof item === 'object' && item.song?.id)
          .sort((a, b) => Number(b.savedAt || 0) - Number(a.savedAt || 0));
        profile.reviews = [...items.filter(item => !item.learned).slice(0, 50),
          ...items.filter(item => item.learned).slice(0, 50)];
      }
      if (body.stats && typeof body.stats === 'object') profile.stats = body.stats;
    }
    const { secret, ...safe } = profile;
    return { status: 200, body: safe };
  }
  if (method === 'GET' && path === '/catalog') {
    return { status: 200, body: { songs: catalogSongs(origin) } };
  }
  if (method === 'POST' && path === '/rooms') {
    if (rooms.size >= 500) return fail(503, 'ルーム数の上限に達しました');
    const mode = ['shared', 'spotify', 'sabitro'].includes(body.mode) ? body.mode : 'shared';
    const supplied = Array.isArray(body.songs) ? body.songs.slice(0, 50).filter(song =>
      song && typeof song.title === 'string' && normalize(song.title) && typeof song.artist === 'string' &&
      ((mode === 'spotify' && /^spotify:[A-Za-z0-9]{22}$/.test(song.id)) ||
       (mode === 'sabitro' && /^itunes:\d+$/.test(song.id) && /^https:\/\//.test(song.previewURL || ''))))
      .map(song => ({ id: song.id, title: song.title.slice(0, 150), artist: song.artist.slice(0, 100),
        artworkURL: song.artworkURL || null, previewURL: mode === 'spotify' ? null : song.previewURL,
        trackURL: song.trackURL || null, durationMS: Number(song.durationMS) || 180_000,
        genre: song.genre || 'その他', songleURL: song.songleURL || null, chorusMS: song.chorusMS || null })) : [];
    const songs = mode === 'shared' ? catalogSongs(origin) : supplied;
    if (!songs.length) return fail(400, '再生できる曲がありません');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(String(body.playerId || '')) || !String(body.name || '').trim()) return fail(400, 'プレイヤー情報が必要です');
    let id; do { id = Array.from({length: 6}, () => 'ABCDEFGHJKLMNPQRSTUVWXYZ'[randomInt(24)]).join(''); } while (rooms.has(id));
    const s = settings(body.settings);
    const room = { id, mode, settings: s, songs: shuffled(songs).slice(0, s.questionCount), corpus: [...new Set([...songs.map(song => song.title), ...seedTitles, ...(Array.isArray(body.corpus) ? body.corpus.filter(s => typeof s === 'string').slice(0, 500) : [])])], phase: 'lobby', round: -1,
      hostId: String(body.playerId), players: [{ id: String(body.playerId), secret: randomUUID(), name: String(body.name).trim().slice(0, 24),
        badge: String(body.badge || '').slice(0, 24), score: 0, lives: s.lives, disqualified: false, joinedAt: Date.now(), lastSeen: Date.now() }],
      pushed: new Set(), skipped: new Set(), readyIds: new Set(), startAt: null, roundDeadline: null, answerDeadline: null,
      answeringPlayerID: null, answerProgress: '', options: [], correctPlayerID: null, firstWrongDone: false };
    rooms.set(id, room);
    return { status: 201, body: { ...snapshot(room, String(body.playerId)), sessionToken: room.players[0].secret } };
  }
  const match = path.match(/^\/rooms\/([A-Z]{6})(?:\/(join|heartbeat|ready|start|push|choose|skip|next|leave|transfer))?$/);
  if (!match) return fail(404, '見つかりません');
  const room = rooms.get(match[1]); if (!room) return fail(404, 'ルームが見つかりません');
  refresh(room);
  const action = match[2];
  const playerId = String(method === 'GET' ? query.get('playerId') || '' : body.playerId || '');
  let player = room.players.find(p => p.id === playerId);
  let newlyJoined = false;
  if (action === 'join' && method === 'POST') {
    if (!player) {
      if (room.phase !== 'lobby') return fail(409, '開始後は参加できません');
      if (room.players.length >= 4) return fail(409, '満員です');
      if (!/^[A-Za-z0-9-]{1,64}$/.test(playerId)) return fail(400, 'プレイヤー情報が無効です');
      player = { id: playerId, secret: randomUUID(), name: String(body.name || 'プレイヤー').trim().slice(0, 24),
        badge: String(body.badge || '').slice(0, 24), score: 0,
        lives: room.settings.lives, disqualified: false, joinedAt: Date.now(), lastSeen: Date.now() };
      room.players.push(player);
      newlyJoined = true;
    }
  }
  if (!player) return fail(403, '参加していません');
  if (!newlyJoined && player.secret !== authorization?.replace(/^Bearer /, '')) return fail(403, 'セッションを確認できません');
  player.lastSeen = Date.now();
  if (action === 'start') {
    if (room.hostId !== playerId || room.phase !== 'lobby') return fail(403, 'ホストのみ開始できます');
    beginRound(room);
  } else if (action === 'ready') {
    if (room.phase !== 'preparing') return fail(409, '準備中ではありません');
    room.readyIds.add(playerId);
  } else if (action === 'transfer') {
    const target = room.players.find(p => p.id === body.targetId);
    if (room.phase !== 'lobby' || room.hostId !== playerId || !target) return fail(403, 'ホスト変更は待機中のホストのみ行えます');
    room.hostId = target.id;
  } else if (action === 'push') {
    if (room.phase !== 'listening' || player.disqualified || room.pushed.has(playerId) || room.pushed.size >= room.settings.answerSlots) return fail(409, '解答権を取得できません');
    room.pushed.add(playerId); room.skipped.delete(playerId); room.answeringPlayerID = playerId;
    room.answerProgress = ''; room.letterIndex = 0; room.answerDeadline = Date.now() + 5000;
    room.options = choices([...normalize(currentSong(room).title)][0], '', room.corpus || room.songs.map(s => s.title));
    room.phase = 'answering';
  } else if (action === 'choose') {
    if (room.phase !== 'answering' || room.answeringPlayerID !== playerId) return fail(409, '解答権がありません');
    if (Date.now() >= room.answerDeadline) wrong(room, player);
    else {
      const answer = [...normalize(currentSong(room).title)];
      if (String(body.choice) !== answer[room.letterIndex]) wrong(room, player);
      else {
        room.answerProgress += answer[room.letterIndex]; room.letterIndex++;
        if (room.letterIndex === answer.length) {
          player.score += room.settings.correctPoints + (room.pushed.size === 1 ? room.settings.firstBonus : 0);
          room.correctPlayerID = playerId; reveal(room);
        } else {
          room.options = choices(answer[room.letterIndex], room.answerProgress, room.corpus || room.songs.map(s => s.title));
          room.answerDeadline = Date.now() + 5000;
        }
      }
    }
  } else if (action === 'skip') {
    if (!['listening','answering'].includes(room.phase) || player.disqualified) return fail(409, '今はスキップできません');
    room.skipped.add(playerId);
    if (room.players.filter(p => !p.disqualified && Date.now() - p.lastSeen < GRACE).every(p => room.skipped.has(p.id))) reveal(room);
  } else if (action === 'next') {
    if (room.hostId !== playerId || room.phase !== 'reveal') return fail(403, 'ホストのみ進められます');
    beginRound(room);
  } else if (action === 'leave') {
    room.players = room.players.filter(p => p.id !== playerId);
    if (!room.players.length) rooms.delete(room.id);
    else if (room.hostId === playerId) room.hostId = room.players.sort((a,b) => a.joinedAt - b.joinedAt)[0].id;
    return { status: 200, body: { left: true } };
  } else if (action && action !== 'join' && action !== 'heartbeat') return fail(404, '見つかりません');
  return { status: 200, body: { ...snapshot(room, playerId), ...(action === 'join' ? { sessionToken: player.secret } : {}) } };
}
function send(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}
export const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (request.method === 'GET' && url.pathname === '/spotify/callback') {
    const deepLink = new URL('intol://callback');
    for (const key of ['code', 'state', 'error']) if (url.searchParams.has(key)) deepLink.searchParams.set(key, url.searchParams.get(key));
    response.writeHead(302, { Location: deepLink.toString(), 'Cache-Control': 'no-store' }); response.end(); return;
  }
  if (!['GET', 'POST', 'PUT'].includes(request.method)) { send(response, 405, { error: 'Method not allowed' }); return; }
  const media = url.pathname.match(/^\/media\/([A-Za-z0-9_-]+\.wav)$/);
  if (request.method === 'GET' && media && catalog.some(song => song.audioFile === media[1])) {
    const path = new URL(`./public/audio/${media[1]}`, import.meta.url);
    try {
      const size = statSync(path).size;
      const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range || '');
      const start = range ? Number(range[1]) : 0;
      const end = range && range[2] ? Math.min(size - 1, Number(range[2])) : size - 1;
      if (start >= size || start > end) {
        response.writeHead(416, { 'Content-Range': `bytes */${size}` }); response.end(); return;
      }
      const headers = {
        'Content-Type': 'audio/wav', 'Content-Length': end - start + 1,
        'Accept-Ranges': 'bytes', 'Cache-Control': 'public, max-age=86400'
      };
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
      response.writeHead(range ? 206 : 200, headers);
      createReadStream(path, { start, end }).pipe(response);
    } catch { send(response, 404, { error: 'Audio not found' }); }
    return;
  }
  try {
    const chunks = [];
    let bytes = 0;
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > MAX_BODY) { send(response, 413, { error: 'Too large' }); return; }
      chunks.push(chunk);
    }
    const input = Buffer.concat(chunks).toString('utf8');
    const body = input ? JSON.parse(input) : {};
    if (request.method === 'GET' && url.pathname === '/itunes/search') {
      send(response, 200, { songs: await searchItunes(url.searchParams.get('term') || '') }); return;
    }
    if (request.method === 'POST' && url.pathname === '/itunes/match') {
      send(response, 200, { song: await matchItunes(body) }); return;
    }
    if (request.method === 'GET' && url.pathname === '/itunes/top') {
      send(response, 200, { titles: await topSongs() }); return;
    }
    if (request.method === 'POST' && url.pathname === '/chorus') {
      send(response, 200, { positionMS: await chorusPosition(body) }); return;
    }
    if (request.method === 'POST' && url.pathname === '/profile/link') {
      const access = request.headers.authorization?.replace(/^Bearer /, '');
      if (!access) { send(response, 401, { error: 'Spotify 認証が必要です' }); return; }
      const verification = await fetch('https://api.spotify.com/v1/me', {
        headers: { Authorization: `Bearer ${access}` }, signal: AbortSignal.timeout(8000)
      });
      if (!verification.ok) { send(response, 403, { error: 'Spotify アカウントを確認できません' }); return; }
      const account = await verification.json();
      const accountID = account.account_id || account.id;
      if (!accountID || !/^[A-Za-z0-9_-]+$/.test(accountID)) { send(response, 403, { error: 'アカウントIDが無効です' }); return; }
      const id = `spotify:${accountID}`;
      let profile = profiles.get(id);
      if (!profile) {
        profile = { id, secret: randomUUID(), reviews: [], history: [], stats: null };
        profiles.set(id, profile); persist();
      }
      const { secret, ...safe } = profile;
      send(response, 200, { ...safe, token: secret }); return;
    }
    if (request.method === 'POST' && url.pathname === '/rooms' && Array.isArray(body.songs) && body.songs.length) {
      const artists = [...new Set(body.songs.map(song => song.artist).filter(Boolean))].slice(0, 3);
      const additions = await Promise.allSettled([topSongs(), ...artists.map(artist => searchItunes(artist, 25))]);
      body.corpus = [...(Array.isArray(body.corpus) ? body.corpus : []),
        ...additions.flatMap(item => item.status === 'fulfilled' ?
          item.value.map(song => typeof song === 'string' ? song : song.title) : [])].slice(0, 500);
    }
    const origin = process.env.PUBLIC_BASE_URL || `${request.headers['x-forwarded-proto'] || 'http'}://${request.headers.host}`;
    const result = handle(request.method, url.pathname, body, url.searchParams, request.headers.authorization, origin);
    send(response, result.status, result.body);
    if (result.status === 200 && request.method === 'POST' && /\/rooms\/[A-Z]{6}\/(start|next)$/.test(url.pathname)) {
      const room = rooms.get(url.pathname.split('/')[2]);
      const song = room && currentSong(room);
      if (room?.mode === 'spotify' && song) {
        chorusPosition(song).then(position => { song.chorusMS = position; persist(); }).catch(() => {});
      }
    }
    if (request.method !== 'GET' || url.pathname.startsWith('/rooms/')) persist();
  } catch (error) { send(response, 400, { error: error instanceof Error ? error.message : 'Bad request' }); }
});

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  server.listen(PORT, '0.0.0.0', () => console.log(`IntoL room server listening on ${server.address().port}`));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    try { saveStateNow(); } catch (error) { console.error('Final state save failed:', error); }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}

setInterval(() => {
  const now = Date.now();
  for (const [id, room] of rooms) {
    if (room.players.every(player => now - player.lastSeen >= GRACE)) rooms.delete(id);
  }
  persist();
}, 60_000).unref();
